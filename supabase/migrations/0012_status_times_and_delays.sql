-- =====================================================================
-- OPS-V2 — start/finish handling
--  * Decoy legs follow their real leg automatically (the lead driver has no
--    access): when the real leg starts / finishes, its decoy gets the same
--    status and times.
--  * Admins can start / finish any leg and correct the times
--    (admin_set_status); such times are flagged times_by_admin.
--  * A leg that lasted more than 90 minutes can only be closed with a delay
--    reason: forgot / road_delay / factory_wait / other (+ free text).
--    "forgot" requires the actual return time, which replaces the click time.
-- Run after 0001–0011. Adds columns only; no existing data is changed.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

-- ---------------------------------------------------------------------
-- Columns (+ refresh the view so it exposes them)
-- ---------------------------------------------------------------------

alter table public.trips_all add column delay_reason text
  check (delay_reason in ('forgot', 'road_delay', 'factory_wait', 'other'));
alter table public.trips_all add column delay_note text;
alter table public.trips_all add column times_by_admin boolean not null default false;

create or replace view public.trips as
  select * from public.trips_all where status <> 'cancelled_refresh';
revoke all on public.trips from anon, authenticated;

-- ---------------------------------------------------------------------
-- Decoys mirror their real leg
-- ---------------------------------------------------------------------

create function app_private.mirror_decoy_status() returns trigger
language plpgsql as $$
begin
  if (new.status, new.actual_start_at, new.actual_done_at)
     is distinct from (old.status, old.actual_start_at, old.actual_done_at) then
    update public.trips_all d
       set status = case when new.status in ('active', 'done') then new.status else d.status end,
           actual_start_at = new.actual_start_at,
           actual_done_at = new.actual_done_at
     where d.id = new.decoy_trip_id and d.trip_type = 'decoy' and d.status <> 'cancelled_refresh';
  end if;
  return null;
end $$;

create trigger trips_mirror_decoy
  after update on public.trips_all
  for each row
  when (new.trip_type = 'real' and new.decoy_trip_id is not null and new.status <> 'cancelled_refresh')
  execute function app_private.mirror_decoy_status();

-- ---------------------------------------------------------------------
-- Closing rule: > 90 minutes needs a reason; "forgot" needs the real time
-- ---------------------------------------------------------------------

-- Returns {done_at, reason, note} or raises DELAY_REASON_REQUIRED /
-- NOTE_REQUIRED / ACTUAL_TIME_REQUIRED / BAD_TIME.
create function app_private.close_check(p_start timestamptz, p_end timestamptz, p_reason text,
                                        p_note text, p_actual timestamptz)
returns jsonb
language plpgsql immutable as $$
declare
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
begin
  if p_start is null or p_end - p_start <= interval '90 minutes' then
    return jsonb_build_object('done_at', p_end, 'reason', null, 'note', null);
  end if;
  if coalesce(p_reason, '') not in ('forgot', 'road_delay', 'factory_wait', 'other') then
    raise exception 'DELAY_REASON_REQUIRED';
  end if;
  if p_reason = 'other' and v_note is null then
    raise exception 'NOTE_REQUIRED';
  end if;
  if p_reason = 'forgot' then
    if p_actual is null then
      raise exception 'ACTUAL_TIME_REQUIRED';
    end if;
    if p_actual <= p_start or p_actual > p_end then
      raise exception 'BAD_TIME';
    end if;
    return jsonb_build_object('done_at', p_actual, 'reason', p_reason, 'note', v_note);
  end if;
  return jsonb_build_object('done_at', p_end, 'reason', p_reason, 'note', v_note);
end $$;

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Worker status (own leg, today) — new optional parameters
-- ---------------------------------------------------------------------

drop function public.worker_set_status(text, uuid, text, text);

create function public.worker_set_status(p_token text, p_trip_id uuid, p_action text,
                                         p_note text default null, p_reason text default null,
                                         p_actual_time timestamptz default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_trip public.trips;
  v_note text := left(btrim(coalesce(p_note, '')), 1000);
  v_close jsonb;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and date = app_private.today() and v_emp.id = any(assigned_workers)
  for update;
  if not found then
    raise exception 'NOT_FOUND';
  end if;

  if p_action = 'start' then
    if v_trip.status <> 'planned' then raise exception 'BAD_TRANSITION'; end if;
    update public.trips set status = 'active', actual_start_at = now() where id = v_trip.id;
  elsif p_action = 'done' then
    if v_trip.status not in ('active', 'problem') then raise exception 'BAD_TRANSITION'; end if;
    v_close := app_private.close_check(v_trip.actual_start_at, now(), p_reason, p_note, p_actual_time);
    update public.trips
       set status = 'done',
           actual_done_at = (v_close->>'done_at')::timestamptz,
           delay_reason = v_close->>'reason',
           delay_note = v_close->>'note'
     where id = v_trip.id;
  elsif p_action = 'problem' then
    if v_trip.status = 'done' then raise exception 'BAD_TRANSITION'; end if;
    if v_note = '' then raise exception 'NOTE_REQUIRED'; end if;
    update public.trips set status = 'problem', problem_note = v_note where id = v_trip.id;
  elsif p_action = 'note' then
    if v_note = '' then raise exception 'NOTE_REQUIRED'; end if;
    update public.trips
       set problem_note = left(concat_ws(E'\n', problem_note, v_emp.name || ': ' || v_note), 2000)
     where id = v_trip.id;
  else
    raise exception 'BAD_INPUT';
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Admin: start / finish any leg, any day, with an optional corrected time
-- ---------------------------------------------------------------------

create function public.admin_set_status(p_token text, p_trip_id uuid, p_action text,
                                        p_time timestamptz default null, p_reason text default null,
                                        p_note text default null, p_actual_time timestamptz default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_trip public.trips;
  v_time timestamptz := coalesce(p_time, now());
  v_close jsonb;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'NOT_FOUND';
  end if;
  if v_time > now() + interval '5 minutes' then
    raise exception 'BAD_TIME';
  end if;

  if p_action = 'start' then
    if v_trip.actual_done_at is not null and v_time >= v_trip.actual_done_at then
      raise exception 'BAD_TIME';
    end if;
    update public.trips
       set actual_start_at = v_time,
           status = case when status = 'planned' then 'active' else status end,
           times_by_admin = true
     where id = v_trip.id;
  elsif p_action = 'done' then
    if v_trip.actual_start_at is null then
      raise exception 'NOT_STARTED';
    end if;
    if v_time <= v_trip.actual_start_at then
      raise exception 'BAD_TIME';
    end if;
    v_close := app_private.close_check(v_trip.actual_start_at, v_time, p_reason, p_note, p_actual_time);
    update public.trips
       set status = 'done',
           actual_done_at = (v_close->>'done_at')::timestamptz,
           delay_reason = v_close->>'reason',
           delay_note = v_close->>'note',
           times_by_admin = true
     where id = v_trip.id;
  else
    raise exception 'BAD_INPUT';
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Worker detail: include delay info (replaces 0010 version)
-- ---------------------------------------------------------------------

create or replace function public.worker_trip_detail(p_token text, p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_trip public.trips;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and v_emp.id = any(assigned_workers);
  if not found then
    raise exception 'NOT_FOUND';
  end if;

  update public.refresh_notices set seen_at = now()
   where employee_id = v_emp.id and date = v_trip.date and seen_at is null;

  return jsonb_build_object(
    'id', v_trip.id,
    'label', app_private.trip_label(v_trip.asset_id, v_trip.departure_slot),
    'date', v_trip.date,
    'is_today', v_trip.date = app_private.today(),
    'asset_id', v_trip.asset_id,
    'leg', v_trip.leg,
    'departure_slot', v_trip.departure_slot,
    'vehicle_type', v_trip.vehicle_type,
    'worker_position', v_trip.worker_position,
    'exit_point', v_trip.exit_point,
    'outbound_route', v_trip.outbound_route,
    'factory_entry', v_trip.factory_entry,
    'factory_exit', v_trip.factory_exit,
    'return_route', v_trip.return_route,
    'is_custodian', v_trip.custodian_id = v_emp.id,
    'partners', coalesce((
      select jsonb_agg(jsonb_build_object('name', e.name, 'is_custodian', e.id = v_trip.custodian_id)
                       order by e.name)
      from public.employees e
      where e.id = any(v_trip.assigned_workers) and e.id <> v_emp.id), '[]'::jsonb),
    'status', v_trip.status,
    'problem_note', v_trip.problem_note,
    'actual_start_at', v_trip.actual_start_at,
    'actual_done_at', v_trip.actual_done_at,
    'delay_reason', v_trip.delay_reason,
    'delay_note', v_trip.delay_note,
    'times_by_admin', v_trip.times_by_admin
  );
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

revoke execute on function
  public.worker_set_status(text, uuid, text, text, text, timestamptz),
  public.admin_set_status(text, uuid, text, timestamptz, text, text, timestamptz)
from public;
grant execute on function
  public.worker_set_status(text, uuid, text, text, text, timestamptz),
  public.admin_set_status(text, uuid, text, timestamptz, text, text, timestamptz)
to anon, authenticated;

-- Re-define functions that use public.trips so row types bind to the widened view.
do $$
declare
  f record;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app_private') and p.prokind = 'f'
      and p.prosrc like '%public.trips%'
  loop
    execute pg_get_functiondef(f.oid);
  end loop;
end $$;

commit;

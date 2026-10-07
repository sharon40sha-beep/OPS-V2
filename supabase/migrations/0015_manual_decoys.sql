-- =====================================================================
-- OPS-V2 — manual decoys
--  * The admin can attach a decoy to a manual task or to a regular leg that
--    has none (admin_save_decoy). It runs at the same time, opens and closes
--    together with the task it is linked to (lead driver needs no access).
--  * Manual decoys carry origin → destination and free text like manual tasks.
--    Their warehouse / factory points must be "allowed in decoy", and so must
--    the linked task's (enforced by the existing trips_decoy_options trigger).
--  * Decoys stay out of the pattern analysis; the regular decoy cap
--    (5 per 10 legs) is shown as a warning.
--  * Deleting a planned task marks it 'deleted' instead of removing the row
--    (history is kept; fixes deleting legs created by "refresh week").
-- Run after 0001–0014. Adds a column / relaxes checks; no data is changed.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

-- Rows with origin/destination (manual tasks and manual decoys) follow the
-- manual-task shape instead of the fixed outbound / return one.
alter table public.trips_all drop constraint trips_leg_slot;
alter table public.trips_all add constraint trips_leg_slot
  check (trip_type = 'manual' or origin is not null
         or leg = 'outbound' and departure_slot = 'morning'
         or leg = 'return' and departure_slot = 'noon');

alter table public.trips_all drop constraint trips_leg_fields;
alter table public.trips_all add constraint trips_leg_fields
  check (trip_type = 'manual' or origin is not null
         or leg = 'outbound' and exit_point is not null and outbound_route is not null
            and factory_entry is not null and factory_exit is null and return_route is null
         or leg = 'return' and factory_exit is not null and return_route is not null
            and exit_point is null and outbound_route is null and factory_entry is null);

alter table public.trips_all add constraint trips_manual_decoy_fields
  check (trip_type <> 'decoy' or origin is null
         or destination is not null and origin <> destination and cardinality(assigned_workers) > 0
            and decoy_trip_id is not null);

create or replace function app_private.trip_title(p_trip public.trips) returns text
language sql stable as $$
  select case when p_trip.origin is not null then
    case when p_trip.trip_type = 'manual' then 'משימה מיוחדת ' else 'משימה ' end
      || p_trip.asset_id || ' · '
      || app_private.place_label(p_trip.origin) || ' ← ' || app_private.place_label(p_trip.destination)
      || ' (' || case p_trip.departure_slot when 'morning' then 'בוקר' when 'noon' then 'צהריים'
                                          else 'אחה"צ/ערב' end
      || coalesce(' ' || to_char(p_trip.planned_time, 'HH24:MI'), '') || ')'
  else app_private.trip_label(p_trip.asset_id, p_trip.departure_slot) end
$$;

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Deleting a planned task keeps it in history (status 'deleted')
-- ---------------------------------------------------------------------
-- A hard delete failed for legs created by "refresh week" (the cancelled plan
-- points at them) and lost history. Deleted rows leave every screen and
-- calculation (the view hides them) and are immutable, like cancelled ones.

alter table public.trips_all add column deleted_at timestamptz;

alter table public.trips_all drop constraint trips_status_check;
alter table public.trips_all add constraint trips_status_check
  check (status in ('planned', 'active', 'done', 'problem', 'cancelled_refresh', 'deleted'));

create or replace view public.trips as
  select * from public.trips_all where status not in ('cancelled_refresh', 'deleted');
revoke all on public.trips from anon, authenticated;

drop index public.trips_one_real_per_leg;
create unique index trips_one_real_per_leg on public.trips_all (asset_id, date, leg)
  where trip_type = 'real' and status not in ('cancelled_refresh', 'deleted');

create or replace function app_private.protect_cancelled_trips() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status in ('cancelled_refresh', 'deleted') then
      raise exception 'CANCELLED_TRIP_IMMUTABLE';
    end if;
    return old;
  end if;
  if old.status = 'cancelled_refresh' then
    if old.replaced_by is null
       and (to_jsonb(new) - 'replaced_by') = (to_jsonb(old) - 'replaced_by') then
      return new;
    end if;
    raise exception 'CANCELLED_TRIP_IMMUTABLE';
  end if;
  if old.status = 'deleted' then
    raise exception 'CANCELLED_TRIP_IMMUTABLE';
  end if;
  return new;
end $$;

create or replace function app_private.mirror_decoy_status() returns trigger
language plpgsql as $$
begin
  if (new.status, new.actual_start_at, new.actual_done_at)
     is distinct from (old.status, old.actual_start_at, old.actual_done_at) then
    update public.trips_all d
       set status = case when new.status in ('active', 'done') then new.status else d.status end,
           actual_start_at = new.actual_start_at,
           actual_done_at = new.actual_done_at
     where d.id = new.decoy_trip_id and d.trip_type = 'decoy' and d.status not in ('cancelled_refresh', 'deleted');
  end if;
  return null;
end $$;

drop trigger trips_mirror_decoy on public.trips_all;
create trigger trips_mirror_decoy
  after update on public.trips_all
  for each row
  when (new.trip_type in ('real', 'manual') and new.decoy_trip_id is not null
        and new.status not in ('cancelled_refresh', 'deleted'))
  execute function app_private.mirror_decoy_status();

revoke all on all functions in schema app_private from public;

create or replace function public.admin_delete_trip(p_token text, p_pin text, p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
  v_trip public.trips;
begin
  v_check := app_private.check_pin(v_admin.id, p_pin);
  if v_check <> 'ok' then
    return app_private.stepup_error(v_check);
  end if;

  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'NOT_FOUND';
  end if;
  if v_trip.status <> 'planned' then
    raise exception 'NOT_PLANNED';
  end if;

  if v_trip.trip_type in ('real', 'manual') and v_trip.decoy_trip_id is not null then
    -- The task goes, so does its decoy.
    update public.trips_all set status = 'deleted', deleted_at = now()
     where id = v_trip.decoy_trip_id and status = 'planned';
  elsif v_trip.trip_type = 'decoy' then
    -- Only the decoy goes: unlink it from its task.
    update public.trips_all set decoy_trip_id = null
     where decoy_trip_id = v_trip.id and trip_type in ('real', 'manual') and status not in ('cancelled_refresh', 'deleted');
  end if;
  update public.trips_all set status = 'deleted', deleted_at = now() where id = v_trip.id;

  perform app_private.sync_budget();
  return jsonb_build_object('ok', true);
end $$;

-- Regular editor: manual decoys only toggle the analysis flag
CREATE OR REPLACE FUNCTION public.admin_update_trip(p_token text, p_trip_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_trip public.trips;
  v_sibling public.trips;
  v_key text;
  v_leads int;
  v_new_custodian uuid;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'NOT_FOUND';
  end if;
  -- Manual tasks / decoys are edited with admin_save_manual_trip / admin_save_decoy (only the analysis flag here).
  if (v_trip.trip_type = 'manual' or v_trip.origin is not null)
     and exists (select 1 from jsonb_object_keys(p_data) k where k <> 'excluded_from_analysis') then
    raise exception 'BAD_INPUT';
  end if;
  if v_trip.status = 'done'
     and exists (select 1 from jsonb_object_keys(p_data) k where k <> 'excluded_from_analysis') then
    raise exception 'NOT_PLANNED';
  end if;

  -- Only the fields of this leg may be set.
  foreach v_key in array case v_trip.leg
      when 'outbound' then array['exit_point', 'outbound_route', 'factory_entry']
      else array['factory_exit', 'return_route'] end
      || array['vehicle_type'] loop
    if p_data ? v_key and not app_private.is_valid_option(v_key, p_data->>v_key) then
      raise exception 'BAD_VALUE:%', v_key;
    end if;
  end loop;
  if exists (select 1 from jsonb_object_keys(p_data) k
             where k = any(case v_trip.leg when 'outbound' then array['factory_exit', 'return_route']
                                else array['exit_point', 'outbound_route', 'factory_entry'] end)
                or k = 'departure_slot') then
    raise exception 'BAD_VALUE:leg';
  end if;

  -- Custodian change (real legs): applied to both legs of the day, which must
  -- both still be planned, so one person stays responsible all day.
  v_new_custodian := nullif(p_data->>'custodian_id', '')::uuid;
  if v_new_custodian is not null and v_new_custodian is distinct from v_trip.custodian_id then
    if v_trip.trip_type <> 'real' then
      raise exception 'BAD_VALUE:custodian_id';
    end if;
    if not exists (select 1 from public.employees where id = v_new_custodian and is_active and not is_lead_driver) then
      raise exception 'BAD_VALUE:custodian_id';
    end if;
    select * into v_sibling from public.trips
    where asset_id = v_trip.asset_id and date = v_trip.date and trip_type = 'real' and leg <> v_trip.leg
    for update;
    if found then
      if v_sibling.status = 'done' then
        raise exception 'CUSTODIAN_LOCKED';
      end if;
      update public.trips
         set custodian_id = v_new_custodian,
             assigned_workers = array(select distinct unnest(
               array_replace(assigned_workers, v_sibling.custodian_id, v_new_custodian)))
       where id = v_sibling.id;
    end if;
    update public.trips
       set custodian_id = v_new_custodian,
           assigned_workers = array(select distinct unnest(
             array_replace(assigned_workers, v_trip.custodian_id, v_new_custodian)))
     where id = v_trip.id;
  end if;

  update public.trips set
    vehicle_type    = coalesce(p_data->>'vehicle_type', vehicle_type),
    exit_point      = coalesce(p_data->>'exit_point', exit_point),
    outbound_route  = coalesce(p_data->>'outbound_route', outbound_route),
    factory_entry   = coalesce(p_data->>'factory_entry', factory_entry),
    factory_exit    = coalesce(p_data->>'factory_exit', factory_exit),
    return_route    = coalesce(p_data->>'return_route', return_route),
    worker_position = coalesce(p_data->>'worker_position', worker_position),
    assigned_workers = case when p_data ? 'assigned_workers'
      then array(select distinct x::uuid from jsonb_array_elements_text(p_data->'assigned_workers') x)
      else assigned_workers end,
    excluded_from_analysis = coalesce((p_data->>'excluded_from_analysis')::boolean, excluded_from_analysis)
  where id = p_trip_id
  returning * into v_trip;

  if v_trip.status <> 'done' then
    if v_trip.trip_type = 'real' and not (v_trip.custodian_id = any(v_trip.assigned_workers)) then
      raise exception 'CUSTODIAN_REQUIRED';
    end if;
    if v_trip.vehicle_type <> 'company' then
      update public.trips set worker_position = 'none' where id = v_trip.id
      returning * into v_trip;
      if exists (select 1 from public.config_options c
                 where c.company_only and (c.category, c.value) in (
                   ('exit_point', v_trip.exit_point), ('outbound_route', v_trip.outbound_route),
                   ('factory_entry', v_trip.factory_entry), ('factory_exit', v_trip.factory_exit),
                   ('return_route', v_trip.return_route))) then
        raise exception 'COMPANY_ONLY_OPTION';
      end if;
    elsif v_trip.trip_type = 'real' and v_trip.worker_position not in ('front', 'back', 'escort') then
      raise exception 'POSITION_REQUIRED';
    end if;

    if cardinality(v_trip.assigned_workers) = 0 then
      raise exception 'WORKERS_REQUIRED';
    end if;
    if exists (select 1 from unnest(v_trip.assigned_workers) w
               left join public.employees e on e.id = w
               where e.id is null or not e.is_active) then
      raise exception 'BAD_VALUE:assigned_workers';
    end if;

    select count(*) into v_leads from public.employees
    where id = any(v_trip.assigned_workers) and is_lead_driver;
    if v_leads > 0 and v_trip.vehicle_type <> 'company' then
      raise exception 'LEAD_COMPANY_ONLY';
    end if;
    if v_leads > 0 and v_trip.trip_type = 'real' and cardinality(v_trip.assigned_workers) < 2 then
      raise exception 'LEAD_NOT_ALONE';
    end if;
    if v_trip.trip_type = 'decoy' and cardinality(v_trip.assigned_workers) > 1 then
      raise exception 'DECOY_SOLO';
    end if;

    if p_data ? 'vehicle_type' then
      if app_private.vehicle_blocked(v_trip.vehicle_type, v_trip.date) then
        raise exception 'VEHICLE_BLOCKED';
      end if;
      if app_private.month_usage(v_trip.vehicle_type, v_trip.date) > coalesce(
           (select max_per_month from public.vehicle_budget where vehicle_type = v_trip.vehicle_type),
           2147483647) then
        raise exception 'BUDGET_EXHAUSTED';
      end if;
    end if;
  end if;

  perform app_private.sync_budget();
  return jsonb_build_object('ok', true, 'trip', app_private.trip_admin_json(v_trip));
end $function$;


-- ---------------------------------------------------------------------
-- Admin: add / edit a manual decoy linked to a planned task
-- ---------------------------------------------------------------------

-- Returns {ok, id, warnings: [{code, detail}]}; warnings never block:
--   DECOY_CAP (5 of the last 10 regular legs already had a decoy),
--   VEHICLE_BUSY, WORKER_BUSY, BUDGET_EXHAUSTED.
create function public.admin_save_decoy(
  p_token text, p_parent_id uuid, p_time time, p_origin text, p_destination text,
  p_vehicle text, p_workers uuid[], p_exit_point text, p_factory_entry text, p_factory_exit text,
  p_route_note text, p_note text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_parent public.trips;
  v_decoy public.trips;
  v_origin text := btrim(coalesce(p_origin, ''));
  v_dest text := btrim(coalesce(p_destination, ''));
  v_workers uuid[] := array(select distinct w from unnest(coalesce(p_workers, '{}')) w where w is not null);
  v_company boolean := p_vehicle = 'company';
  v_id uuid;
  v_place text;
  v_recent int;
  v_warnings jsonb := '[]'::jsonb;
begin
  select * into v_parent from public.trips where id = p_parent_id for update;
  if not found or v_parent.trip_type not in ('real', 'manual') then
    raise exception 'NOT_FOUND';
  end if;
  if v_parent.status <> 'planned' then
    raise exception 'NOT_PLANNED';
  end if;
  if v_parent.decoy_trip_id is not null then
    select * into v_decoy from public.trips where id = v_parent.decoy_trip_id for update;
    -- Decoys drawn by the engine are edited in the regular editor.
    if v_decoy.origin is null then
      raise exception 'DECOY_EXISTS';
    end if;
    if v_decoy.status <> 'planned' then
      raise exception 'NOT_PLANNED';
    end if;
  end if;

  if v_origin = '' or v_dest = '' or v_origin = v_dest
     or char_length(v_origin) > 80 or char_length(v_dest) > 80 then
    raise exception 'BAD_VALUE:place';
  end if;
  if not app_private.is_valid_option('vehicle_type', p_vehicle) then
    raise exception 'BAD_VALUE:vehicle_type';
  end if;
  if app_private.vehicle_blocked(p_vehicle, v_parent.date) then
    raise exception 'VEHICLE_BLOCKED';
  end if;
  if cardinality(v_workers) = 0
     or exists (select 1 from unnest(v_workers) w
                where not exists (select 1 from public.employees e where e.id = w and e.is_active)) then
    raise exception 'BAD_VALUE:workers';
  end if;

  -- Points: from the lists, allowed in decoy, company-only only with the company car.
  if (v_origin = 'warehouse') <> (p_exit_point is not null)
     or (v_dest = 'factory') <> (p_factory_entry is not null)
     or (v_origin = 'factory') <> (p_factory_exit is not null) then
    raise exception 'BAD_VALUE:points';
  end if;
  if exists (select 1 from (values ('exit_point', p_exit_point), ('factory_entry', p_factory_entry),
                                   ('factory_exit', p_factory_exit)) v(cat, val)
             where val is not null and not exists (
               select 1 from public.config_options c
               where c.category = v.cat and c.value = v.val and c.is_active and c.decoy_ok
                 and (v_company or not c.company_only))) then
    raise exception 'BAD_VALUE:points';
  end if;

  foreach v_place in array array[v_origin, v_dest] loop
    if v_place not in ('warehouse', 'factory') then
      insert into public.config_options (category, value, is_active, company_only, decoy_ok)
      values ('external_site', v_place, true, false, true)
      on conflict (category, value) do nothing;
    end if;
  end loop;

  if v_decoy.id is null then
    insert into public.trips (asset_id, date, trip_type, leg, departure_slot, planned_time, origin, destination,
                              vehicle_type, worker_position, exit_point, factory_entry, factory_exit,
                              assigned_workers, route_note, manual_note, decoy_trip_id)
    values (v_parent.asset_id, v_parent.date, 'decoy', v_parent.leg, v_parent.departure_slot,
            coalesce(p_time, v_parent.planned_time), v_origin, v_dest, p_vehicle, 'none',
            p_exit_point, p_factory_entry, p_factory_exit, v_workers,
            nullif(left(btrim(coalesce(p_route_note, '')), 500), ''),
            nullif(left(btrim(coalesce(p_note, '')), 1000), ''), v_parent.id)
    returning id into v_id;
    -- Linking checks the task's own points are allowed in decoy (DECOY_UNSAFE_OPTION).
    update public.trips set decoy_trip_id = v_id where id = v_parent.id;
  else
    update public.trips
       set planned_time = coalesce(p_time, v_parent.planned_time), origin = v_origin, destination = v_dest,
           vehicle_type = p_vehicle, exit_point = p_exit_point, factory_entry = p_factory_entry,
           factory_exit = p_factory_exit, assigned_workers = v_workers,
           route_note = nullif(left(btrim(coalesce(p_route_note, '')), 500), ''),
           manual_note = nullif(left(btrim(coalesce(p_note, '')), 1000), '')
     where id = v_decoy.id
    returning id into v_id;
  end if;

  perform app_private.sync_budget();

  if v_parent.trip_type = 'real' then
    select count(*) filter (where decoy_trip_id is not null) into v_recent
    from (select decoy_trip_id from public.trips
          where asset_id = v_parent.asset_id and leg = v_parent.leg and trip_type = 'real'
            and not excluded_from_analysis and date < v_parent.date
          order by date desc limit 10) r;
    if v_recent >= 5 then
      v_warnings := v_warnings || jsonb_build_object('code', 'DECOY_CAP', 'detail', v_recent::text);
    end if;
  end if;
  if exists (select 1 from public.trips t
             where t.date = v_parent.date and t.departure_slot = v_parent.departure_slot
               and t.id not in (v_id, v_parent.id) and t.vehicle_type = p_vehicle) then
    v_warnings := v_warnings || jsonb_build_object('code', 'VEHICLE_BUSY', 'detail', null);
  end if;
  v_warnings := v_warnings || coalesce((
    select jsonb_agg(jsonb_build_object('code', 'WORKER_BUSY', 'detail', e.name) order by e.name)
    from public.employees e
    where e.id = any(v_workers)
      and exists (select 1 from public.trips t
                  where t.date = v_parent.date and t.departure_slot = v_parent.departure_slot
                    and t.id <> v_id and e.id = any(t.assigned_workers))), '[]'::jsonb);
  if exists (select 1 from public.vehicle_budget b
             where b.vehicle_type = p_vehicle and b.max_per_month is not null
               and app_private.month_usage(p_vehicle, v_parent.date) > b.max_per_month) then
    v_warnings := v_warnings || jsonb_build_object('code', 'BUDGET_EXHAUSTED', 'detail', null);
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'warnings', v_warnings);
end $$;

revoke execute on function public.admin_save_decoy(text, uuid, time, text, text, text, uuid[], text, text, text,
  text, text) from public;
grant execute on function public.admin_save_decoy(text, uuid, time, text, text, text, uuid[], text, text, text,
  text, text) to anon, authenticated;

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

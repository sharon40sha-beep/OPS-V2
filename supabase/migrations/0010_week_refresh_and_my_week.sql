-- =====================================================================
-- OPS-V2 — "refresh week" (admin) + full read-only week view (workers)
--
-- Runs on a live pilot: NO existing row is deleted or modified (except the
-- status-check constraint widening). Verified: row counts before == after.
--
--  * trips → trips_all (all history, incl. 'cancelled_refresh').
--    View public.trips = trips_all without cancelled rows, so every existing
--    function (anti-pattern history, correlations, budgets, worker screens)
--    ignores a cancelled plan automatically. Cancelled rows are protected:
--    they can't be deleted or changed (except linking replaced_by once).
--  * refresh_log: append-only (no UPDATE / DELETE / TRUNCATE, even for admins).
--  * Engine refactored into plan_asset_day (whole day per asset, both legs),
--    shared by admin_generate_week and admin_refresh_week.
--  * admin_refresh_preview / admin_refresh_week (step-up, one transaction):
--    planned legs are cancelled and redrawn; a started outbound keeps the
--    return's vehicle and crew (only factory exit + return route redrawn);
--    a fully redrawn day must differ from the cancelled one in ≥ 4 of the 7
--    variables; decoys are re-decided; any day without a legal plan aborts
--    the whole refresh with the day and the blocking rule.
--  * Workers: worker_my_week + worker_trip_detail (any own leg, read-only,
--    with partners/times/notes); status buttons stay limited to today
--    (worker_set_status). "Updated" marker per day via refresh_notices.
--    team_week becomes admin-only (decoy isolation).
-- Run after 0001–0009.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

-- ---------------------------------------------------------------------
-- Refresh log (append-only)
-- ---------------------------------------------------------------------

create table public.refresh_log (
  id                 uuid primary key,
  created_at         timestamptz not null default now(),
  admin_id           uuid not null references public.employees(id),
  include_today      boolean not null,
  include_next_week  boolean not null,
  range_from         date,
  range_to           date,
  days               jsonb not null default '[]'::jsonb,
  replaced_count     int not null,
  created_count      int not null,
  reason             text
);
alter table public.refresh_log enable row level security;
revoke all on public.refresh_log from anon, authenticated;

create function app_private.refresh_log_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'REFRESH_LOG_IMMUTABLE';
end $$;

create trigger refresh_log_no_change
  before update or delete on public.refresh_log
  for each row execute function app_private.refresh_log_immutable();
create trigger refresh_log_no_truncate
  before truncate on public.refresh_log
  for each statement execute function app_private.refresh_log_immutable();

-- ---------------------------------------------------------------------
-- trips → trips_all + view
-- ---------------------------------------------------------------------

alter table public.trips drop constraint trips_status_check;
alter table public.trips add constraint trips_status_check
  check (status in ('planned', 'active', 'done', 'problem', 'cancelled_refresh'));

alter table public.trips add column cancelled_at timestamptz;
alter table public.trips add column replaced_by uuid references public.trips(id);
alter table public.trips add column refresh_id uuid
  references public.refresh_log(id) deferrable initially deferred;

drop index public.trips_one_real_per_leg;
create unique index trips_one_real_per_leg on public.trips (asset_id, date, leg)
  where trip_type = 'real' and status <> 'cancelled_refresh';

alter table public.trips rename to trips_all;

create view public.trips as
  select * from public.trips_all where status <> 'cancelled_refresh';
revoke all on public.trips from anon, authenticated;

-- Cancelled rows are history: no delete, no change (except linking the
-- replacement once, inside the refresh transaction).
create function app_private.protect_cancelled_trips() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'cancelled_refresh' then
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
  return new;
end $$;

create trigger trips_protect_cancelled
  before update or delete on public.trips_all
  for each row execute function app_private.protect_cancelled_trips();

-- History can't be wiped in bulk either (also blocks TRUNCATE ... CASCADE via refresh_log).
create function app_private.no_truncate() returns trigger
language plpgsql as $$
begin
  raise exception 'HISTORY_IMMUTABLE';
end $$;

create trigger trips_no_truncate
  before truncate on public.trips_all
  for each statement execute function app_private.no_truncate();

-- trip_admin_json takes the view's row type now.
drop function app_private.trip_admin_json(public.trips_all);
create function app_private.trip_admin_json(p_trip public.trips) returns jsonb
language sql stable as $$
  select to_jsonb(p_trip) || jsonb_build_object(
    'label', app_private.trip_label(p_trip.asset_id, p_trip.departure_slot),
    'custodian_name', (select name from public.employees where id = p_trip.custodian_id),
    'workers', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) order by e.name)
      from public.employees e where e.id = any(p_trip.assigned_workers)
    ), '[]'::jsonb)
  )
$$;

-- ---------------------------------------------------------------------
-- "Updated" notices for workers after a refresh
-- ---------------------------------------------------------------------

create table public.refresh_notices (
  id           uuid primary key default gen_random_uuid(),
  refresh_id   uuid not null references public.refresh_log(id) deferrable initially deferred,
  employee_id  uuid not null references public.employees(id) on delete cascade,
  date         date not null,
  seen_at      timestamptz
);
create index refresh_notices_emp_idx on public.refresh_notices (employee_id, date);
alter table public.refresh_notices enable row level security;
revoke all on public.refresh_notices from anon, authenticated;

-- ---------------------------------------------------------------------
-- Engine building blocks
-- ---------------------------------------------------------------------

-- Remaining monthly budget for a vehicle (null = unlimited). Done + planned count;
-- cancelled plans don't (they are outside the view).
create function app_private.budget_room(p_vehicle text, p_day date) returns int
language sql stable as $$
  select b.max_per_month - app_private.month_usage(p_vehicle, p_day)
  from public.vehicle_budget b
  where b.vehicle_type = p_vehicle and b.max_per_month is not null
$$;

create function app_private.lead_for_day(p_day date) returns uuid
language sql volatile as $$
  select id from public.employees
  where role = 'operator' and is_active and is_lead_driver
    and not app_private.is_absent(id, p_day)
  order by random() limit 1
$$;

-- Which vehicles a leg may use, and whether it must run with a decoy.
-- p_fixed_vehicle: the vehicle is kept (return leg after a started outbound).
create function app_private.leg_vehicles(p_asset text, p_day date, p_leg text, p_lead uuid,
                                         p_fixed_vehicle text default null)
returns jsonb
language plpgsql volatile as $$
declare
  v_slot text := case p_leg when 'outbound' then 'morning' else 'noon' end;
  v_lead_free boolean;
  v_decoy_ok boolean := false;
  v_recent int;
  v_allowed text[];
  v_must boolean;
  v_warn text;
begin
  v_lead_free := p_lead is not null and not exists (
    select 1 from public.trips
    where date = p_day and departure_slot = v_slot and p_lead = any(assigned_workers));

  if v_lead_free and not app_private.vehicle_blocked('company', p_day)
     and not app_private.budget_exhausted('company', p_day)
     and (case p_leg
            when 'outbound' then
              cardinality(app_private.options_for('exit_point', true, true)) > 0
              and cardinality(app_private.options_for('outbound_route', true, true)) > 1
              and cardinality(app_private.options_for('factory_entry', true, true)) > 1
              and cardinality(app_private.options_for('exit_point', false, true)) > 0
              and cardinality(app_private.options_for('outbound_route', false, true)) > 0
              and cardinality(app_private.options_for('factory_entry', false, true)) > 0
            else
              cardinality(app_private.options_for('factory_exit', true, true)) > 1
              and cardinality(app_private.options_for('return_route', true, true)) > 1
              and cardinality(app_private.options_for('factory_exit', false, true)) > 0
              and cardinality(app_private.options_for('return_route', false, true)) > 0
          end) then
    select count(*) filter (where decoy_trip_id is not null) into v_recent
    from (select decoy_trip_id from public.trips
          where asset_id = p_asset and leg = p_leg and trip_type = 'real'
            and not excluded_from_analysis and date < p_day
          order by date desc limit 10) r;
    v_decoy_ok := v_recent < 5;
  end if;

  if p_fixed_vehicle is not null then
    v_must := p_fixed_vehicle <> 'company' and v_decoy_ok;
    if p_fixed_vehicle <> 'company' and v_lead_free and not v_decoy_ok then
      v_warn := 'LEAD_UNASSIGNED';
    end if;
    return jsonb_build_object('allowed', jsonb_build_array(p_fixed_vehicle), 'must_decoy', v_must, 'warning', v_warn);
  end if;

  v_allowed := array(
    select v from unnest(app_private.options('vehicle_type')) v
    where not app_private.vehicle_blocked(v, p_day)
      and not app_private.budget_exhausted(v, p_day)
      and case when v = 'company' then v_lead_free
               else v_decoy_ok or not v_lead_free end);
  v_must := v_lead_free;
  if cardinality(v_allowed) = 0 and v_lead_free then
    v_allowed := array(
      select v from unnest(app_private.options('vehicle_type')) v
      where v <> 'company' and not app_private.vehicle_blocked(v, p_day)
        and not app_private.budget_exhausted(v, p_day));
    v_must := false;
    if cardinality(v_allowed) > 0 then
      v_warn := 'LEAD_UNASSIGNED';
    end if;
  end if;
  return jsonb_build_object('allowed', to_jsonb(v_allowed), 'must_decoy', v_must, 'warning', v_warn);
end $$;

-- Best of p_tries random candidates for one leg (lowest leg_score).
-- Non-company legs that run with a decoy draw decoy-safe options only.
create function app_private.pick_leg(p_asset text, p_day date, p_leg text, p_allowed text[],
                                     p_must_decoy boolean, p_out_vehicle text, p_tries int)
returns jsonb
language plpgsql volatile as $$
declare
  v_best jsonb;
  v_score numeric;
  c_vehicle text; c_a text; c_b text; c_c text;
  v_company boolean;
  v_safe boolean;
begin
  for v_try in 1..p_tries loop
    c_vehicle := app_private.pick(p_allowed);
    v_company := c_vehicle = 'company';
    v_safe := not v_company and p_must_decoy;
    if p_leg = 'outbound' then
      c_a := app_private.pick(app_private.options_for('exit_point', v_company, v_safe));
      c_b := app_private.pick(app_private.options_for('outbound_route', v_company, v_safe));
      c_c := app_private.pick(app_private.options_for('factory_entry', v_company, v_safe));
    else
      c_a := app_private.pick(app_private.options_for('factory_exit', v_company, v_safe));
      c_b := app_private.pick(app_private.options_for('return_route', v_company, v_safe));
      c_c := null;
    end if;
    continue when c_vehicle is null or c_a is null or c_b is null or (p_leg = 'outbound' and c_c is null);
    v_score := app_private.leg_score(p_asset, p_day, p_leg, c_vehicle, c_a, c_b, c_c, p_out_vehicle);
    if v_best is null or v_score < (v_best->>'score')::numeric then
      v_best := jsonb_build_object('vehicle', c_vehicle, 'a', c_a, 'b', c_b, 'c', c_c, 'score', v_score);
    end if;
  end loop;
  return v_best;
end $$;

-- Inserts one real leg (+ its same-time decoy when required). Returns the number of decoys created.
create function app_private.insert_leg(p_asset text, p_day date, p_leg text, p_pick jsonb,
                                       p_position text, p_workers uuid[], p_custodian uuid,
                                       p_must_decoy boolean, p_lead uuid)
returns int
language plpgsql volatile as $$
declare
  v_slot text := case p_leg when 'outbound' then 'morning' else 'noon' end;
  v_vehicle text := p_pick->>'vehicle';
  v_real uuid;
  v_decoy uuid;
begin
  insert into public.trips (asset_id, date, leg, trip_type, departure_slot, vehicle_type,
    worker_position, exit_point, outbound_route, factory_entry, factory_exit, return_route,
    assigned_workers, custodian_id)
  values (p_asset, p_day, p_leg, 'real', v_slot, v_vehicle, p_position,
    case p_leg when 'outbound' then p_pick->>'a' end,
    case p_leg when 'outbound' then p_pick->>'b' end,
    case p_leg when 'outbound' then p_pick->>'c' end,
    case p_leg when 'return' then p_pick->>'a' end,
    case p_leg when 'return' then p_pick->>'b' end,
    p_workers, p_custodian)
  returning id into v_real;

  if v_vehicle <> 'company' and p_must_decoy and p_lead is not null then
    insert into public.trips (asset_id, date, leg, trip_type, departure_slot, vehicle_type,
      worker_position, exit_point, outbound_route, factory_entry, factory_exit, return_route,
      assigned_workers, decoy_trip_id)
    values (p_asset, p_day, p_leg, 'decoy', v_slot, 'company', 'none',
      case p_leg when 'outbound' then app_private.pick(app_private.prefer_other(app_private.options_for('exit_point', true, true), p_pick->>'a')) end,
      case p_leg when 'outbound' then app_private.pick(array_remove(app_private.options_for('outbound_route', true, true), p_pick->>'b')) end,
      case p_leg when 'outbound' then app_private.pick(array_remove(app_private.options_for('factory_entry', true, true), p_pick->>'c')) end,
      case p_leg when 'return' then app_private.pick(array_remove(app_private.options_for('factory_exit', true, true), p_pick->>'a')) end,
      case p_leg when 'return' then app_private.pick(array_remove(app_private.options_for('return_route', true, true), p_pick->>'b')) end,
      array[p_lead], v_real)
    returning id into v_decoy;
    update public.trips set decoy_trip_id = v_decoy where id = v_real;
    return 1;
  end if;
  return 0;
end $$;

-- Plans one asset/day (both legs, or only the return when p_fixed_return is given).
--  p_burned: the cancelled day's variables; a full redraw must differ in ≥ 4 of 7.
--  p_strict: abort with REFRESH_BLOCKED instead of skipping with a warning.
create function app_private.plan_asset_day(p_asset text, p_day date, p_burned jsonb,
                                           p_strict boolean, p_fixed_return jsonb)
returns jsonb
language plpgsql volatile as $$
declare
  v_lead uuid := app_private.lead_for_day(p_day);
  v_pool uuid[];
  v_positions text[];
  v_custodian uuid;
  v_lo jsonb; v_lr jsonb;
  v_allowed_o text[]; v_allowed_r text[];
  v_do_out boolean; v_do_ret boolean;
  v_out jsonb; v_ret jsonb; v_pos_o text; v_pos_r text;
  b_out jsonb; b_ret jsonb; b_pos_o text; b_pos_r text;
  v_score numeric; v_best numeric;
  v_diff int; v_best_diff int;
  v_valid int := 0;
  v_burned_seen boolean := false;
  v_tries int; v_attempts int;
  v_workers uuid[];
  v_slot text;
  v_created int := 0; v_decoys int := 0; v_fallbacks int := 0;
  v_warnings jsonb := '[]'::jsonb;
  v_where text := 'יום ' || to_char(p_day, 'DD/MM') || ' · ' || p_asset || ' · ';
begin
  v_pool := array(select id from public.employees
                  where is_active and not is_lead_driver and not app_private.is_absent(id, p_day));
  v_positions := array(select unnest(app_private.options('worker_position'))
                       intersect select unnest(array['front', 'back', 'escort']));
  if cardinality(v_positions) = 0 then
    v_positions := array['front', 'back'];
  end if;

  -- ---- return leg only (outbound already started): keep vehicle + crew ----
  if p_fixed_return is not null then
    v_lr := app_private.leg_vehicles(p_asset, p_day, 'return', v_lead, p_fixed_return->>'vehicle');
    if v_lr->>'warning' is not null then
      v_warnings := v_warnings || jsonb_build_object('asset', p_asset, 'date', p_day, 'reason', 'LEAD_UNASSIGNED',
        'message', v_where || 'חזרה · נהג ראשי לא שובץ (אין אפשרות לפיתוי)');
    end if;
    -- Prefer a factory exit and return route that both differ from the cancelled ones.
    for v_try in 1..20 loop
      v_ret := app_private.pick_leg(p_asset, p_day, 'return', array[p_fixed_return->>'vehicle'],
                                    (v_lr->>'must_decoy')::boolean, p_fixed_return->>'out_vehicle', 3);
      continue when v_ret is null;
      v_diff := ((v_ret->>'a') is distinct from (p_burned->>'factory_exit'))::int
              + ((v_ret->>'b') is distinct from (p_burned->>'return_route'))::int;
      if b_ret is null or v_diff > v_best_diff
         or (v_diff = v_best_diff and (v_ret->>'score')::numeric < (b_ret->>'score')::numeric) then
        b_ret := v_ret; v_best_diff := v_diff;
      end if;
      exit when v_best_diff = 2 and v_try >= 5;
    end loop;
    if b_ret is null then
      raise exception 'REFRESH_BLOCKED:%', v_where || 'חזרה · אין ציר/יציאה חוקיים לרכב הקיים';
    end if;
    v_workers := array(select (jsonb_array_elements_text(p_fixed_return->'workers'))::uuid);
    v_decoys := app_private.insert_leg(p_asset, p_day, 'return', b_ret, p_fixed_return->>'position',
                                       v_workers, (p_fixed_return->>'custodian')::uuid,
                                       (v_lr->>'must_decoy')::boolean, v_lead);
    return jsonb_build_object('created', 1, 'decoys', v_decoys,
                              'fallbacks', ((b_ret->>'score')::numeric >= 100)::int, 'warnings', v_warnings);
  end if;

  -- ---- full day ----
  -- Custodian: free (not custodian of another asset today), least-used first with jitter.
  select w into v_custodian
  from unnest(v_pool) w
  where not exists (select 1 from public.trips t
                    where t.date = p_day and t.trip_type = 'real' and t.custodian_id = w)
  order by (select count(distinct t.date) from public.trips t
            where t.custodian_id = w and t.trip_type = 'real'
              and t.date >= coalesce(app_private.pilot_start_date(), '-infinity'::date))
           + random() * 6
  limit 1;

  if v_custodian is null then
    if p_strict then
      raise exception 'REFRESH_BLOCKED:%', v_where || 'אין עובד פנוי (נהג ראשי לא יוצא לבד עם המוצר)';
    end if;
    return jsonb_build_object('created', 0, 'decoys', 0, 'fallbacks', 0, 'warnings', jsonb_build_array(
      jsonb_build_object('asset', p_asset, 'date', p_day, 'reason', 'NO_WORKER',
        'message', 'אין עובד פנוי ל-' || p_asset || ' ב-' || to_char(p_day, 'DD/MM/YYYY') || ' - נדרשת התערבות ידנית')));
  end if;

  v_lo := app_private.leg_vehicles(p_asset, p_day, 'outbound', v_lead);
  v_lr := app_private.leg_vehicles(p_asset, p_day, 'return', v_lead);
  v_allowed_o := array(select jsonb_array_elements_text(v_lo->'allowed'));
  v_allowed_r := array(select jsonb_array_elements_text(v_lr->'allowed'));
  v_do_out := cardinality(v_allowed_o) > 0;
  v_do_ret := cardinality(v_allowed_r) > 0;

  if not v_do_out or not v_do_ret then
    if p_strict then
      raise exception 'REFRESH_BLOCKED:%', v_where || 'אין רכב זמין ('
        || case when not v_do_out then 'יציאה' else 'חזרה' end || ') — רכב לא זמין או מכסה מוצתה';
    end if;
    if not v_do_out then
      v_warnings := v_warnings || jsonb_build_object('asset', p_asset, 'date', p_day, 'reason', 'NO_VEHICLE',
        'message', 'אין רכב זמין ל-' || p_asset || ' ב-' || to_char(p_day, 'DD/MM/YYYY') || ' (יציאה) - נדרשת התערבות ידנית');
    end if;
    if not v_do_ret then
      v_warnings := v_warnings || jsonb_build_object('asset', p_asset, 'date', p_day, 'reason', 'NO_VEHICLE',
        'message', 'אין רכב זמין ל-' || p_asset || ' ב-' || to_char(p_day, 'DD/MM/YYYY') || ' (חזרה) - נדרשת התערבות ידנית');
    end if;
  end if;
  if v_lo->>'warning' is not null then
    v_warnings := v_warnings || jsonb_build_object('asset', p_asset, 'date', p_day, 'reason', 'LEAD_UNASSIGNED',
      'message', 'נהג ראשי לא שובץ ל-' || p_asset || ' ב-' || to_char(p_day, 'DD/MM/YYYY')
                 || ' (יציאה) - רכב החברה לא זמין או שמכסת הפיתויים מוצתה');
  end if;
  if v_lr->>'warning' is not null then
    v_warnings := v_warnings || jsonb_build_object('asset', p_asset, 'date', p_day, 'reason', 'LEAD_UNASSIGNED',
      'message', 'נהג ראשי לא שובץ ל-' || p_asset || ' ב-' || to_char(p_day, 'DD/MM/YYYY')
                 || ' (חזרה) - רכב החברה לא זמין או שמכסת הפיתויים מוצתה');
  end if;
  if not v_do_out and not v_do_ret then
    return jsonb_build_object('created', 0, 'decoys', 0, 'fallbacks', 0, 'warnings', v_warnings);
  end if;

  v_attempts := case when p_burned is null then 1 else 40 end;
  v_tries := case when p_burned is null then 10 else 3 end;

  for v_att in 1..v_attempts loop
    v_out := case when v_do_out then app_private.pick_leg(p_asset, p_day, 'outbound', v_allowed_o,
                                                          (v_lo->>'must_decoy')::boolean, null, v_tries) end;
    v_ret := case when v_do_ret then app_private.pick_leg(p_asset, p_day, 'return', v_allowed_r,
                                                          (v_lr->>'must_decoy')::boolean, v_out->>'vehicle', v_tries) end;
    continue when (v_do_out and v_out is null) or (v_do_ret and v_ret is null);
    -- Both legs in the same budgeted vehicle need room for two uses.
    continue when v_do_out and v_do_ret and v_out->>'vehicle' = v_ret->>'vehicle'
                  and coalesce(app_private.budget_room(v_out->>'vehicle', p_day), 99) < 2;
    v_pos_o := case when v_out->>'vehicle' = 'company' then app_private.pick(v_positions) else 'none' end;
    v_pos_r := case when v_ret->>'vehicle' = 'company' then app_private.pick(v_positions) else 'none' end;

    if p_burned is not null then
      v_burned_seen := true;
      v_diff := ((v_out->>'vehicle') is distinct from (p_burned->>'vehicle'))::int
              + (v_pos_o is distinct from (p_burned->>'position'))::int
              + ((v_out->>'a') is distinct from (p_burned->>'exit_point'))::int
              + ((v_out->>'b') is distinct from (p_burned->>'outbound_route'))::int
              + ((v_out->>'c') is distinct from (p_burned->>'factory_entry'))::int
              + ((v_ret->>'a') is distinct from (p_burned->>'factory_exit'))::int
              + ((v_ret->>'b') is distinct from (p_burned->>'return_route'))::int;
      continue when v_diff < 4;
    end if;

    v_score := coalesce((v_out->>'score')::numeric, 0) + coalesce((v_ret->>'score')::numeric, 0);
    if v_best is null or v_score < v_best then
      v_best := v_score;
      b_out := v_out; b_ret := v_ret; b_pos_o := v_pos_o; b_pos_r := v_pos_r;
    end if;
    v_valid := v_valid + 1;
    exit when p_burned is null or v_valid >= 6;
  end loop;

  if v_best is null then
    if p_strict or p_burned is not null then
      raise exception 'REFRESH_BLOCKED:%', v_where || case when v_burned_seen
        then 'לא נמצא שילוב השונה ב-4 משתנים לפחות מהתוכנית שבוטלה'
        else 'לא נמצא שילוב חוקי (מכסה / אפשרויות מותרות)' end;
    end if;
    return jsonb_build_object('created', 0, 'decoys', 0, 'fallbacks', 0, 'warnings', v_warnings);
  end if;

  foreach v_slot in array array['outbound', 'return'] loop
    continue when (v_slot = 'outbound' and not v_do_out) or (v_slot = 'return' and not v_do_ret);
    if (case v_slot when 'outbound' then b_out else b_ret end)->>'vehicle' = 'company' then
      v_workers := array[v_lead, v_custodian];
    else
      -- custodian + sometimes one more worker who is free at that time
      v_workers := array[v_custodian] || array(
        select w from unnest(v_pool) w
        where w <> v_custodian
          and not exists (select 1 from public.trips t
                          where t.date = p_day and t.trip_type = 'real'
                            and t.departure_slot = case v_slot when 'outbound' then 'morning' else 'noon' end
                            and w = any(t.assigned_workers))
        order by random() limit (random() < 0.5)::int);
    end if;
    v_decoys := v_decoys + app_private.insert_leg(
      p_asset, p_day, v_slot,
      case v_slot when 'outbound' then b_out else b_ret end,
      case v_slot when 'outbound' then b_pos_o else b_pos_r end,
      v_workers, v_custodian,
      (case v_slot when 'outbound' then v_lo else v_lr end->>'must_decoy')::boolean, v_lead);
    v_created := v_created + 1;
    v_fallbacks := v_fallbacks
      + (((case v_slot when 'outbound' then b_out else b_ret end)->>'score')::numeric >= 100)::int;
  end loop;

  return jsonb_build_object('created', v_created, 'decoys', v_decoys, 'fallbacks', v_fallbacks,
                            'warnings', v_warnings);
end $$;

-- ---------------------------------------------------------------------
-- Week generation on top of plan_asset_day (same rules and output as before)
-- ---------------------------------------------------------------------

create or replace function public.admin_generate_week(p_token text, p_pin text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
  v_monday date;
  v_day date;
  v_asset record;
  v_res jsonb;
  v_created int := 0; v_decoys int := 0; v_fallbacks int := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
begin
  v_check := app_private.check_pin(v_admin.id, p_pin);
  if v_check <> 'ok' then
    return app_private.stepup_error(v_check);
  end if;
  if p_week_start is null then
    raise exception 'BAD_INPUT';
  end if;
  if cardinality(app_private.options('vehicle_type')) = 0 then raise exception 'CONFIG_MISSING:vehicle_type'; end if;
  if cardinality(app_private.options_for('exit_point', false)) = 0 then raise exception 'CONFIG_MISSING:exit_point'; end if;
  if cardinality(app_private.options_for('outbound_route', false)) = 0 then raise exception 'CONFIG_MISSING:outbound_route'; end if;
  if cardinality(app_private.options_for('factory_entry', false)) = 0 then raise exception 'CONFIG_MISSING:factory_entry'; end if;
  if cardinality(app_private.options_for('factory_exit', false)) = 0 then raise exception 'CONFIG_MISSING:factory_exit'; end if;
  if cardinality(app_private.options_for('return_route', false)) = 0 then raise exception 'CONFIG_MISSING:return_route'; end if;

  v_monday := app_private.week_monday(p_week_start);
  for i in 0..4 loop
    v_day := v_monday + i;
    for v_asset in select id from public.assets where is_active order by id loop
      if exists (select 1 from public.trips
                 where asset_id = v_asset.id and date = v_day and trip_type = 'real') then
        v_skipped := v_skipped || jsonb_build_object('asset', v_asset.id, 'date', v_day, 'reason', 'EXISTS');
        continue;
      end if;
      v_res := app_private.plan_asset_day(v_asset.id, v_day, null, false, null);
      v_created := v_created + (v_res->>'created')::int;
      v_decoys := v_decoys + (v_res->>'decoys')::int;
      v_fallbacks := v_fallbacks + (v_res->>'fallbacks')::int;
      v_warnings := v_warnings || (v_res->'warnings');
    end loop;
  end loop;

  perform app_private.sync_budget();
  return jsonb_build_object('ok', true, 'week_start', v_monday, 'created', v_created,
                            'decoys', v_decoys, 'fallbacks', v_fallbacks,
                            'skipped', v_skipped, 'warnings', v_warnings);
end $$;

-- ---------------------------------------------------------------------
-- Refresh: what would be redrawn
-- ---------------------------------------------------------------------

-- action: 'full' (both legs redrawn) | 'return_only' (outbound started) |
--         'create' (no trips yet) | 'locked' (nothing left to change)
create function app_private.refresh_targets(p_include_today boolean, p_include_next_week boolean)
returns table (r_day date, r_asset text, r_action text, r_old_ids uuid[], r_burned jsonb, r_fixed jsonb)
language plpgsql volatile as $$
declare
  v_today date := app_private.today();
  v_monday date := app_private.week_monday(app_private.today());
  v_from date;
  v_to date;
  v_day date;
  v_asset record;
  o public.trips; od public.trips; r public.trips; rd public.trips;
  o_started boolean; r_started boolean;
begin
  v_from := greatest(case when coalesce(p_include_today, false) then v_today else v_today + 1 end, v_monday);
  v_to := v_monday + 4 + case when coalesce(p_include_next_week, false) then 7 else 0 end;

  for v_day in select g::date from generate_series(v_from, v_to, interval '1 day') g
               where extract(isodow from g) <= 5 loop
    for v_asset in select id from public.assets where is_active order by id loop
      o := null; od := null; r := null; rd := null;
      select * into o from public.trips t
      where t.asset_id = v_asset.id and t.date = v_day and t.leg = 'outbound' and t.trip_type = 'real';
      select * into r from public.trips t
      where t.asset_id = v_asset.id and t.date = v_day and t.leg = 'return' and t.trip_type = 'real';
      if o.decoy_trip_id is not null then
        select * into od from public.trips t where t.id = o.decoy_trip_id;
      end if;
      if r.decoy_trip_id is not null then
        select * into rd from public.trips t where t.id = r.decoy_trip_id;
      end if;
      o_started := o.id is not null and (o.status <> 'planned' or coalesce(od.status, 'planned') <> 'planned');
      r_started := r.id is not null and (r.status <> 'planned' or coalesce(rd.status, 'planned') <> 'planned');

      r_day := v_day; r_asset := v_asset.id; r_burned := null; r_fixed := null; r_old_ids := '{}';
      if o.id is null and r.id is null then
        r_action := 'create';
      elsif not o_started and not r_started then
        r_action := 'full';
        r_old_ids := array_remove(array[o.id, od.id, r.id, rd.id], null);
        r_burned := jsonb_build_object(
          'vehicle', o.vehicle_type, 'position', o.worker_position, 'exit_point', o.exit_point,
          'outbound_route', o.outbound_route, 'factory_entry', o.factory_entry,
          'factory_exit', r.factory_exit, 'return_route', r.return_route);
      elsif o_started and r.id is not null and not r_started then
        r_action := 'return_only';
        r_old_ids := array_remove(array[r.id, rd.id], null);
        r_burned := jsonb_build_object('factory_exit', r.factory_exit, 'return_route', r.return_route);
        r_fixed := jsonb_build_object('vehicle', r.vehicle_type, 'workers', to_jsonb(r.assigned_workers),
                                      'custodian', r.custodian_id, 'position', r.worker_position,
                                      'out_vehicle', o.vehicle_type);
      else
        r_action := 'locked';
      end if;
      return next;
    end loop;
  end loop;
end $$;

revoke all on all functions in schema app_private from public;

create function public.admin_refresh_preview(p_token text, p_include_today boolean, p_include_next_week boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  return jsonb_build_object(
    'today', app_private.today(),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('date', r_day, 'asset', r_asset, 'action', r_action,
                                          'legs', cardinality(r_old_ids))
                       order by r_day, r_asset)
      from app_private.refresh_targets(p_include_today, p_include_next_week)), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- Refresh: execute (step-up, one transaction, all-or-nothing)
-- ---------------------------------------------------------------------

create function public.admin_refresh_week(p_token text, p_pin text, p_include_today boolean,
                                          p_include_next_week boolean, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
  v_log uuid := gen_random_uuid();
  v_t record;
  v_res jsonb;
  v_replaced int := 0;
  v_created int := 0; v_decoys int := 0; v_fallbacks int := 0;
  v_warnings jsonb := '[]'::jsonb;
begin
  v_check := app_private.check_pin(v_admin.id, p_pin);
  if v_check <> 'ok' then
    return app_private.stepup_error(v_check);
  end if;

  drop table if exists refresh_run;
  create temp table refresh_run on commit drop as
    select * from app_private.refresh_targets(p_include_today, p_include_next_week);
  if not exists (select 1 from refresh_run where r_action <> 'locked') then
    raise exception 'REFRESH_EMPTY';
  end if;

  -- 1. Cancel the old plan first, so the planner, budgets and history ignore it.
  update public.trips_all
     set status = 'cancelled_refresh', cancelled_at = now(), refresh_id = v_log
   where id in (select unnest(r_old_ids) from refresh_run);
  get diagnostics v_replaced = row_count;

  -- 2. Redraw day by day (strict: any day without a legal plan aborts everything).
  for v_t in select * from refresh_run where r_action <> 'locked' order by r_day, r_asset loop
    v_res := app_private.plan_asset_day(v_t.r_asset, v_t.r_day, v_t.r_burned, true,
                                        case when v_t.r_action = 'return_only' then v_t.r_fixed end);
    v_created := v_created + (v_res->>'created')::int;
    v_decoys := v_decoys + (v_res->>'decoys')::int;
    v_fallbacks := v_fallbacks + (v_res->>'fallbacks')::int;
    v_warnings := v_warnings || (v_res->'warnings');
  end loop;

  -- 3. Link each cancelled leg to its replacement (same leg and type, else the real leg).
  update public.trips_all c
     set replaced_by = coalesce(
       (select n.id from public.trips n
         where n.asset_id = c.asset_id and n.date = c.date and n.leg = c.leg
           and n.trip_type = c.trip_type and n.created_at = now()
         limit 1),
       (select n.id from public.trips n
         where n.asset_id = c.asset_id and n.date = c.date and n.leg = c.leg
           and n.trip_type = 'real' and n.created_at = now()
         limit 1))
   where c.refresh_id = v_log;

  -- 4. "Updated" notices: only employees on the old or the new legs of a day that
  --    had a plan before (newly created days are not "changes").
  insert into public.refresh_notices (refresh_id, employee_id, date)
  select distinct v_log, x.w, x.d
  from (
    select c.date d, unnest(c.assigned_workers) w from public.trips_all c where c.refresh_id = v_log
    union
    select n.date, unnest(n.assigned_workers)
    from public.trips n
    join refresh_run rr on rr.r_asset = n.asset_id and rr.r_day = n.date
                       and rr.r_action in ('full', 'return_only')
    where n.created_at = now()
  ) x;

  -- 5. Append-only log.
  insert into public.refresh_log (id, admin_id, include_today, include_next_week, range_from, range_to,
                                  days, replaced_count, created_count, reason)
  values (v_log, v_admin.id, coalesce(p_include_today, false), coalesce(p_include_next_week, false),
          (select min(r_day) from refresh_run where r_action <> 'locked'),
          (select max(r_day) from refresh_run where r_action <> 'locked'),
          (select jsonb_agg(jsonb_build_object('date', r_day, 'asset', r_asset, 'action', r_action)
                            order by r_day, r_asset) from refresh_run),
          v_replaced, v_created, nullif(btrim(coalesce(p_reason, '')), ''));

  perform app_private.sync_budget();

  return jsonb_build_object('ok', true, 'refresh_id', v_log, 'replaced', v_replaced,
                            'created', v_created, 'decoys', v_decoys, 'fallbacks', v_fallbacks,
                            'warnings', v_warnings);
end $$;

create function public.admin_refresh_log(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'created_at', l.created_at, 'admin', e.name,
             'range_from', l.range_from, 'range_to', l.range_to,
             'include_today', l.include_today, 'include_next_week', l.include_next_week,
             'replaced', l.replaced_count, 'created', l.created_count, 'reason', l.reason)
           order by l.created_at desc)
    from (select * from public.refresh_log order by created_at desc limit 20) l
    join public.employees e on e.id = l.admin_id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- Workers: own week, read-only details (isolated: own legs only)
-- ---------------------------------------------------------------------

create function public.worker_my_week(p_token text, p_week_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_monday date;
begin
  if coalesce(p_week_offset, 0) not in (0, 1) then
    raise exception 'FORBIDDEN';
  end if;
  v_monday := app_private.week_monday(app_private.today()) + 7 * coalesce(p_week_offset, 0);
  return jsonb_build_object(
    'week_start', v_monday,
    'today', app_private.today(),
    'days', (
      select jsonb_agg(jsonb_build_object(
               'date', d::date,
               'is_today', d::date = app_private.today(),
               'updated', exists (select 1 from public.refresh_notices n
                                  where n.employee_id = v_emp.id and n.date = d::date and n.seen_at is null),
               'trips', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', t.id,
                          'label', app_private.trip_label(t.asset_id, t.departure_slot),
                          'leg', t.leg,
                          'vehicle_type', t.vehicle_type,
                          'status', t.status)
                        order by t.departure_slot, t.asset_id)
                 from public.trips t
                 where t.date = d::date and v_emp.id = any(t.assigned_workers)), '[]'::jsonb))
             order by d)
      from generate_series(v_monday, v_monday + 4, interval '1 day') d));
end $$;

-- Read-only details of one of the caller's own legs, any day. Status changes
-- remain in worker_set_status (today only); edits only through admin RPCs.
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
    'actual_done_at', v_trip.actual_done_at
  );
end $$;

create function public.worker_mark_day_seen(p_token text, p_date date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
begin
  update public.refresh_notices set seen_at = now()
   where employee_id = v_emp.id and date = p_date and seen_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Team schedule: admins only (workers see their own legs — decoy isolation).
create or replace function public.team_week(p_token text, p_week_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.require_admin(p_token);
  v_monday date := app_private.week_monday(app_private.today()) + 7 * coalesce(p_week_offset, 0);
begin
  return jsonb_build_object(
    'week_start', v_monday,
    'today', app_private.today(),
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'date', t.date, 'leg', t.leg, 'asset_id', t.asset_id,
               'vehicle_type', t.vehicle_type, 'status', t.status,
               'is_mine', v_emp.id = any(t.assigned_workers),
               'crew', coalesce((
                 select jsonb_agg(jsonb_build_object('name', e.name, 'is_custodian', e.id = t.custodian_id)
                                  order by (e.id = t.custodian_id) desc, e.name)
                 from public.employees e where e.id = any(t.assigned_workers)), '[]'::jsonb))
             order by t.date, t.departure_slot, t.asset_id, t.vehicle_type)
      from public.trips t
      where t.date between v_monday and v_monday + 4
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

revoke all on all functions in schema app_private from public;

revoke execute on function
  public.admin_refresh_preview(text, boolean, boolean),
  public.admin_refresh_week(text, text, boolean, boolean, text),
  public.admin_refresh_log(text),
  public.worker_my_week(text, int),
  public.worker_mark_day_seen(text, date)
from public;

grant execute on function
  public.admin_refresh_preview(text, boolean, boolean),
  public.admin_refresh_week(text, text, boolean, boolean, text),
  public.admin_refresh_log(text),
  public.worker_my_week(text, int),
  public.worker_mark_day_seen(text, date)
to anon, authenticated;

-- Re-define every function that refers to public.trips so cached plans and
-- row-type variables bind to the new view in all open sessions.
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

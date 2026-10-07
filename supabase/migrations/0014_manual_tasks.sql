-- =====================================================================
-- OPS-V2 — manual tasks + free-text names
--  * Asset names: any text (Hebrew, spaces), up to 40 characters.
--  * Manual tasks (trip_type = 'manual'): the admin adds a movement on any
--    weekday — origin → destination (warehouse / factory / external site),
--    morning / noon / evening (+ optional exact time), vehicle, crew, and
--    free-text route and instructions. Workers get them like any task
--    (start / finish, times, delay reason).
--  * The regular week is unchanged: generation and "refresh week" ignore
--    manual tasks (never cancelled or redrawn), but the engine counts them:
--    vehicle use (budgets, weekday balance, recent combinations) and the
--    warehouse exit / factory entry / factory exit when the task uses them.
--  * External sites are kept as a list (config category 'external_site').
-- Run after 0001–0013. Adds columns / relaxes checks; no data is changed.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

-- ---------------------------------------------------------------------
-- Free-text asset names
-- ---------------------------------------------------------------------

alter table public.assets drop constraint assets_id_check;
alter table public.assets add constraint assets_id_check
  check (btrim(id) <> '' and id = btrim(id) and char_length(id) <= 40);

-- ---------------------------------------------------------------------
-- External sites list
-- ---------------------------------------------------------------------

alter table public.config_options drop constraint config_options_category_check;
alter table public.config_options add constraint config_options_category_check
  check (category in ('exit_point', 'vehicle_type', 'outbound_route', 'factory_entry',
                      'factory_exit', 'return_route', 'worker_position', 'external_site'));

-- ---------------------------------------------------------------------
-- Manual tasks
-- ---------------------------------------------------------------------

alter table public.trips_all add column origin text;          -- 'warehouse' | 'factory' | external site name
alter table public.trips_all add column destination text;
alter table public.trips_all add column planned_time time;    -- optional exact time
alter table public.trips_all add column route_note text;      -- free-text route
alter table public.trips_all add column manual_note text;     -- instructions to the crew

alter table public.trips_all drop constraint trips_trip_type_check;
alter table public.trips_all add constraint trips_trip_type_check
  check (trip_type in ('real', 'decoy', 'manual'));

alter table public.trips_all drop constraint trips_departure_slot_check;
alter table public.trips_all add constraint trips_departure_slot_check
  check (departure_slot in ('morning', 'noon', 'evening'));

alter table public.trips_all drop constraint trips_leg_slot;
alter table public.trips_all add constraint trips_leg_slot
  check (trip_type = 'manual'
         or leg = 'outbound' and departure_slot = 'morning'
         or leg = 'return' and departure_slot = 'noon');

alter table public.trips_all drop constraint trips_leg_fields;
alter table public.trips_all add constraint trips_leg_fields
  check (trip_type = 'manual'
         or leg = 'outbound' and exit_point is not null and outbound_route is not null
            and factory_entry is not null and factory_exit is null and return_route is null
         or leg = 'return' and factory_exit is not null and return_route is not null
            and exit_point is null and outbound_route is null and factory_entry is null);

alter table public.trips_all drop constraint trips_custodian_on_real;
alter table public.trips_all add constraint trips_custodian_on_real
  check (trip_type = 'decoy'
         or trip_type = 'real' and custodian_id is not null and custodian_id = any(assigned_workers)
         or trip_type = 'manual' and (custodian_id is null or custodian_id = any(assigned_workers)));

alter table public.trips_all add constraint trips_manual_fields
  check (trip_type <> 'manual'
         or origin is not null and destination is not null and origin <> destination
            and cardinality(assigned_workers) > 0);

create or replace view public.trips as
  select * from public.trips_all where status <> 'cancelled_refresh';
revoke all on public.trips from anon, authenticated;

-- ---------------------------------------------------------------------
-- Labels and ordering
-- ---------------------------------------------------------------------

create or replace function app_private.trip_label(p_asset text, p_slot text) returns text
language sql immutable as $$
  select 'משימה ' || p_asset || ' · '
         || case p_slot when 'morning' then 'יציאה (בוקר)' when 'noon' then 'חזרה (צהריים)'
                        when 'evening' then 'אחה"צ/ערב' else p_slot end
$$;

create function app_private.place_label(p_place text) returns text
language sql immutable as $$
  select case p_place when 'warehouse' then 'מחסן' when 'factory' then 'מפעל' else p_place end
$$;

-- Sort key: morning < noon < evening, then the exact time when given.
create function app_private.slot_rank(p_slot text, p_time time) returns text
language sql immutable as $$
  select case p_slot when 'morning' then '1' when 'noon' then '2' else '3' end
         || coalesce(to_char(p_time, 'HH24MI'), '9999')
$$;

create function app_private.trip_title(p_trip public.trips) returns text
language sql stable as $$
  select case when p_trip.trip_type = 'manual' then
    'משימה מיוחדת ' || p_trip.asset_id || ' · '
      || app_private.place_label(p_trip.origin) || ' ← ' || app_private.place_label(p_trip.destination)
      || ' (' || case p_trip.departure_slot when 'morning' then 'בוקר' when 'noon' then 'צהריים'
                                          else 'אחה"צ/ערב' end
      || coalesce(' ' || to_char(p_trip.planned_time, 'HH24:MI'), '') || ')'
  else app_private.trip_label(p_trip.asset_id, p_trip.departure_slot) end
$$;

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Updated functions
-- ---------------------------------------------------------------------

-- Engine: manual tasks count in the history (vehicle + the warehouse/factory points they use).
-- Point balances are measured only over legs that have that point.
CREATE OR REPLACE FUNCTION app_private.leg_score(p_asset text, p_day date, p_leg text, p_vehicle text, p_a text, p_b text, p_c text, p_out_vehicle text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_since date := coalesce(app_private.pilot_start_date(), '-infinity'::date);
  v_hard numeric := 0;
  v_soft numeric := 0;
  v_n int; v_same int;
  v_kv int := greatest(cardinality(app_private.options('vehicle_type')), 1);
  r record;
begin
  -- hard: exact combination repeat in the last 10 legs of this direction
  select count(*) * 10 into v_n
  from (select vehicle_type, exit_point, outbound_route, factory_entry, factory_exit, return_route
        from public.trips
        where asset_id = p_asset and leg = p_leg and trip_type in ('real', 'manual')
          and not excluded_from_analysis and date < p_day
        order by date desc limit 10) t
  where t.vehicle_type = p_vehicle
    and case when p_leg = 'outbound'
             then (t.exit_point, t.outbound_route, t.factory_entry) = (p_a, p_b, p_c)
             else (t.factory_exit, t.return_route) = (p_a, p_b) end;
  v_hard := v_n;

  -- hard: same vehicle > 60% on this weekday (last 10 same-weekday legs)
  select count(*), count(*) filter (where vehicle_type = p_vehicle) into v_n, v_same
  from (select vehicle_type from public.trips
        where asset_id = p_asset and leg = p_leg and trip_type in ('real', 'manual')
          and not excluded_from_analysis and date < p_day
          and extract(isodow from date) = extract(isodow from p_day)
        order by date desc limit 10) t;
  if v_n + 1 >= 4 and (v_same + 1)::numeric / (v_n + 1) > 0.6 then
    v_hard := v_hard + (v_same + 1) - floor(0.6 * (v_n + 1));
  end if;

  -- soft: long-term balance
  select
    count(*)::int                                                       as total,
    count(*) filter (where vehicle_type = p_vehicle)::int               as veh,
    count(*) filter (where extract(isodow from date) = extract(isodow from p_day))::int as dow_total,
    count(*) filter (where extract(isodow from date) = extract(isodow from p_day)
                       and vehicle_type = p_vehicle)::int                as dow_veh,
    count(*) filter (where coalesce(exit_point, factory_exit) = p_a)::int        as a_cnt,
    count(*) filter (where coalesce(outbound_route, return_route) = p_b)::int    as b_cnt,
    count(*) filter (where factory_entry = p_c)::int                             as c_cnt,
    count(*) filter (where coalesce(exit_point, factory_exit) is not null)::int  as a_total,
    count(*) filter (where coalesce(outbound_route, return_route) is not null)::int as b_total,
    count(*) filter (where factory_entry is not null)::int                       as c_total
  into r
  from public.trips
  where asset_id = p_asset and leg = p_leg and trip_type in ('real', 'manual')
    and not excluded_from_analysis and date >= v_since and date < p_day;

  v_soft := 2 * app_private.overuse(r.veh, r.total, v_kv)
          + 2 * app_private.overuse(r.dow_veh, r.dow_total, v_kv)
          + app_private.overuse(r.a_cnt, r.a_total, cardinality(app_private.options(
              case p_leg when 'outbound' then 'exit_point' else 'factory_exit' end)))
          + app_private.overuse(r.b_cnt, r.b_total, cardinality(app_private.options(
              case p_leg when 'outbound' then 'outbound_route' else 'return_route' end)));
  if p_leg = 'outbound' then
    v_soft := v_soft + app_private.overuse(r.c_cnt, r.c_total, cardinality(app_private.options('factory_entry')));
  end if;

  -- soft: return vehicle predictable from the morning vehicle?
  if p_leg = 'return' and p_out_vehicle is not null then
    select count(*)::int, count(*) filter (where ret.vehicle_type = p_vehicle)::int into v_n, v_same
    from public.trips ret
    join public.trips o on o.asset_id = ret.asset_id and o.date = ret.date
                       and o.leg = 'outbound' and o.trip_type = 'real'
    where ret.asset_id = p_asset and ret.leg = 'return' and ret.trip_type = 'real'
      and not ret.excluded_from_analysis and ret.date >= v_since and ret.date < p_day
      and o.vehicle_type = p_out_vehicle;
    v_soft := v_soft + 2 * app_private.overuse(v_same, v_n, v_kv);
  end if;

  return 100 * v_hard + v_soft;
end $function$;

-- Pattern report: manual tasks included (the morning→return correlation stays on regular legs).
CREATE OR REPLACE FUNCTION public.admin_pattern_report(p_token text, p_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_from date := greatest(
    coalesce(app_private.pilot_start_date(), '-infinity'::date),
    case when p_days is null then '-infinity'::date else app_private.today() - p_days end);
  v_result jsonb := '{}'::jsonb;
  v_leg text;
begin
  drop table if exists rpt;
  create temp table rpt on commit drop as
  select t.*, extract(isodow from t.date)::int as dow
  from public.trips t
  where t.trip_type in ('real', 'manual') and not t.excluded_from_analysis and t.date >= v_from;

  foreach v_leg in array array['outbound', 'return'] loop
    v_result := v_result || jsonb_build_object(v_leg, (
      select jsonb_build_object(
        'n', (select count(*) from rpt where leg = v_leg),
        'decoy_rate', (select round(avg((decoy_trip_id is not null)::int), 3) from rpt where leg = v_leg),
        'vehicle', coalesce((select jsonb_agg(jsonb_build_object('value', vehicle_type, 'count', c) order by c desc)
                             from (select vehicle_type, count(*) c from rpt where leg = v_leg group by 1) x), '[]'),
        -- Adversary guessing the vehicle blind (most common overall) vs. knowing the weekday.
        'guess_blind', (select round(max(c)::numeric / nullif(sum(c), 0), 3)
                        from (select count(*) c from rpt where leg = v_leg group by vehicle_type) x),
        'guess_by_weekday', (select round(sum(top)::numeric / nullif(sum(n), 0), 3)
                             from (select max(c) top, sum(c) n
                                   from (select dow, vehicle_type, count(*) c from rpt where leg = v_leg group by 1, 2) a
                                   group by dow) b),
        'by_weekday', coalesce((
          select jsonb_agg(jsonb_build_object('dow', dow, 'n', n, 'top', top_v, 'top_share', round(top::numeric / n, 3))
                           order by dow)
          from (select dow, sum(c) n, max(c) top,
                       (array_agg(vehicle_type order by c desc))[1] top_v
                from (select dow, vehicle_type, count(*) c from rpt where leg = v_leg group by 1, 2) a
                group by dow) b), '[]'),
        'params', jsonb_build_object(
          'a', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', c) order by c desc)
                         from (select coalesce(exit_point, factory_exit) v, count(*) c from rpt where leg = v_leg group by 1) x), '[]'),
          'b', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', c) order by c desc)
                         from (select coalesce(outbound_route, return_route) v, count(*) c from rpt where leg = v_leg group by 1) x), '[]'),
          'c', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', c) order by c desc)
                         from (select factory_entry v, count(*) c from rpt where leg = v_leg and factory_entry is not null group by 1) x), '[]'))
      )));
  end loop;

  -- Return vehicle guessable from the morning vehicle?
  v_result := v_result || jsonb_build_object('return_given_outbound', (
    select jsonb_build_object(
      'guess', round(sum(top)::numeric / nullif(sum(n), 0), 3),
      'rows', coalesce(jsonb_agg(jsonb_build_object('out', out_v, 'n', n, 'top', top_v,
                                                    'top_share', round(top::numeric / n, 3)) order by out_v), '[]'))
    from (select o.vehicle_type out_v, sum(c) n, max(c) top, (array_agg(r_v order by c desc))[1] top_v
          from (select o.vehicle_type, r.vehicle_type r_v, count(*) c
                from rpt r join rpt o on o.asset_id = r.asset_id and o.date = r.date and o.leg = 'outbound' and o.trip_type = 'real'
                where r.leg = 'return' and r.trip_type = 'real' group by 1, 2) o
          group by 1) x));

  v_result := v_result || jsonb_build_object(
    'from', case when v_from = '-infinity'::date then null else v_from end,
    'pilot_start_date', app_private.pilot_start_date(),
    'days', (select count(distinct date) from rpt),
    'custodians', coalesce((
      select jsonb_agg(jsonb_build_object('name', e.name, 'days', c) order by c desc)
      from (select custodian_id, count(distinct (asset_id, date)) c from rpt group by 1) x
      join public.employees e on e.id = x.custodian_id), '[]'));

  return v_result;
end $function$;

-- Titles for manual tasks
CREATE OR REPLACE FUNCTION app_private.trip_admin_json(p_trip trips)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select to_jsonb(p_trip) || jsonb_build_object(
    'label', app_private.trip_title(p_trip),
    'custodian_name', (select name from public.employees where id = p_trip.custodian_id),
    'workers', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) order by e.name)
      from public.employees e where e.id = any(p_trip.assigned_workers)
    ), '[]'::jsonb)
  )
$function$;

-- Worker today: manual titles, slot order
CREATE OR REPLACE FUNCTION public.worker_today(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_emp public.employees := app_private.session(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id,
             'label', app_private.trip_title(t),
             'status', t.status,
             'problem_note', t.problem_note)
           order by app_private.slot_rank(t.departure_slot, t.planned_time), t.asset_id)
    from public.trips t
    where t.date = app_private.today() and v_emp.id = any(t.assigned_workers)
  ), '[]'::jsonb);
end $function$;

-- Worker week (legacy): manual titles, slot order
CREATE OR REPLACE FUNCTION public.worker_week(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_emp public.employees := app_private.session(p_token);
  v_monday date := app_private.week_monday(app_private.today());
begin
  return (
    select jsonb_agg(jsonb_build_object(
             'date', d::date,
             'is_today', d::date = app_private.today(),
             'labels', coalesce((
               select jsonb_agg(app_private.trip_title(t)
                                order by app_private.slot_rank(t.departure_slot, t.planned_time), t.asset_id)
               from public.trips t
               where t.date = d::date and v_emp.id = any(t.assigned_workers)
             ), '[]'::jsonb))
           order by d)
    from generate_series(v_monday, v_monday + 4, interval '1 day') d
  );
end $function$;

-- Worker my week: manual titles, slot order
CREATE OR REPLACE FUNCTION public.worker_my_week(p_token text, p_week_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
                          'label', app_private.trip_title(t),
                          'leg', t.leg,
                          'vehicle_type', t.vehicle_type,
                          'status', t.status)
                        order by app_private.slot_rank(t.departure_slot, t.planned_time), t.asset_id)
                 from public.trips t
                 where t.date = d::date and v_emp.id = any(t.assigned_workers)), '[]'::jsonb))
             order by d)
      from generate_series(v_monday, v_monday + 4, interval '1 day') d));
end $function$;

-- Team week: slot order
CREATE OR REPLACE FUNCTION public.team_week(p_token text, p_week_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_emp public.employees := app_private.session(p_token);
  v_monday date;
begin
  if v_emp.role <> 'admin' and coalesce(p_week_offset, 0) not in (0, 1) then
    raise exception 'FORBIDDEN';
  end if;
  v_monday := app_private.week_monday(app_private.today()) + 7 * coalesce(p_week_offset, 0);

  return jsonb_build_object(
    'week_start', v_monday,
    'today', app_private.today(),
    'updated_dates', coalesce((
      select jsonb_agg(distinct n.date)
      from public.refresh_notices n
      where n.employee_id = v_emp.id and n.seen_at is null
        and n.date between v_monday and v_monday + 4), '[]'::jsonb),
    'trips', coalesce((
      select jsonb_agg(app_private.trip_admin_json(t)
                       || jsonb_build_object('is_mine', v_emp.id = any(t.assigned_workers))
                       order by t.date, app_private.slot_rank(t.departure_slot, t.planned_time), t.asset_id, t.trip_type)
      from public.trips t
      where t.date between v_monday and v_monday + 4
    ), '[]'::jsonb)
  );
end $function$;

-- Admin week: slot order
CREATE OR REPLACE FUNCTION public.admin_week(p_token text, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_monday date := app_private.week_monday(coalesce(p_date, app_private.today()));
begin
  return jsonb_build_object(
    'week_start', v_monday,
    'today', app_private.today(),
    'trips', coalesce((
      select jsonb_agg(app_private.trip_admin_json(t)
                       order by t.date, t.asset_id, app_private.slot_rank(t.departure_slot, t.planned_time), t.trip_type)
      from public.trips t
      where t.date between v_monday and v_monday + 4
    ), '[]'::jsonb),
    'stats', (
      select jsonb_build_object(
        'total',   count(*),
        'done',    count(*) filter (where status = 'done'),
        'open',    count(*) filter (where status in ('planned', 'active')),
        'problem', count(*) filter (where status = 'problem'))
      from public.trips
      where date between v_monday and v_monday + 4
    ),
    'absences', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', a.employee_id, 'name', e.name, 'date', a.date)
                       order by a.date, e.name)
      from public.employee_absences a join public.employees e on e.id = a.employee_id
      where a.date between v_monday and v_monday + 4
    ), '[]'::jsonb),
    'vehicle_blocks', coalesce((
      select jsonb_agg(jsonb_build_object('vehicle_type', vehicle_type, 'date', date) order by date)
      from public.vehicle_unavailability
      where date between v_monday and v_monday + 4
    ), '[]'::jsonb),
    'lead_ids', coalesce((
      select jsonb_agg(id) from public.employees where is_lead_driver and is_active
    ), '[]'::jsonb)
  );
end $function$;

-- Regular editor: manual tasks only toggle the analysis flag
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
  -- Manual tasks are edited with admin_save_manual_trip (only the analysis flag here).
  if v_trip.trip_type = 'manual'
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

-- Worker detail: manual task fields
CREATE OR REPLACE FUNCTION public.worker_trip_detail(p_token text, p_trip_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
    'label', app_private.trip_title(v_trip),
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
    'times_by_admin', v_trip.times_by_admin,
    'trip_type', v_trip.trip_type,
    'origin', v_trip.origin,
    'destination', v_trip.destination,
    'planned_time', to_char(v_trip.planned_time, 'HH24:MI'),
    'route_note', v_trip.route_note,
    'manual_note', v_trip.manual_note
  );
end $function$;

-- Assets: any name up to 40 characters
CREATE OR REPLACE FUNCTION public.admin_save_asset(p_token text, p_id text, p_home_warehouse text, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  if coalesce(btrim(p_id), '') = '' or char_length(btrim(p_id)) > 40 or btrim(coalesce(p_home_warehouse, '')) = '' then
    raise exception 'BAD_INPUT';
  end if;
  insert into public.assets (id, home_warehouse, is_active)
  values (btrim(p_id), btrim(p_home_warehouse), coalesce(p_is_active, true))
  on conflict (id) do update
    set home_warehouse = excluded.home_warehouse, is_active = excluded.is_active;
  return jsonb_build_object('ok', true);
end $function$;

-- ---------------------------------------------------------------------
-- Admin: add / edit a manual task
-- ---------------------------------------------------------------------

-- Creates (p_trip_id null) or edits a planned manual task. Returns
-- {ok, id, warnings: [{code, detail}]}; warnings never block saving:
--   LEAD_NOT_ASSIGNED, VEHICLE_BUSY (same vehicle, same slot), WORKER_BUSY,
--   BUDGET_EXHAUSTED.
create function public.admin_save_manual_trip(
  p_token text, p_trip_id uuid, p_asset text, p_date date, p_slot text, p_time time,
  p_origin text, p_destination text, p_vehicle text, p_workers uuid[], p_custodian uuid,
  p_position text, p_exit_point text, p_factory_entry text, p_factory_exit text,
  p_route_note text, p_note text, p_excluded boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_trip public.trips;
  v_origin text := btrim(coalesce(p_origin, ''));
  v_dest text := btrim(coalesce(p_destination, ''));
  v_workers uuid[] := array(select distinct w from unnest(coalesce(p_workers, '{}')) w where w is not null);
  v_company boolean := p_vehicle = 'company';
  v_leg text;
  v_id uuid;
  v_place text;
  v_warnings jsonb := '[]'::jsonb;
begin
  if p_trip_id is not null then
    select * into v_trip from public.trips where id = p_trip_id for update;
    if not found or v_trip.trip_type <> 'manual' then
      raise exception 'NOT_FOUND';
    end if;
    if v_trip.status <> 'planned' then
      raise exception 'NOT_PLANNED';
    end if;
  end if;

  if not exists (select 1 from public.assets where id = p_asset) then
    raise exception 'BAD_VALUE:asset';
  end if;
  if p_date is null or extract(isodow from p_date) > 5 then
    raise exception 'BAD_VALUE:date';
  end if;
  if coalesce(p_slot, '') not in ('morning', 'noon', 'evening') then
    raise exception 'BAD_VALUE:slot';
  end if;
  if v_origin = '' or v_dest = '' or v_origin = v_dest
     or char_length(v_origin) > 80 or char_length(v_dest) > 80 then
    raise exception 'BAD_VALUE:place';
  end if;
  if not app_private.is_valid_option('vehicle_type', p_vehicle) then
    raise exception 'BAD_VALUE:vehicle_type';
  end if;
  if app_private.vehicle_blocked(p_vehicle, p_date) then
    raise exception 'VEHICLE_BLOCKED';
  end if;
  if cardinality(v_workers) = 0
     or exists (select 1 from unnest(v_workers) w
                where not exists (select 1 from public.employees e where e.id = w and e.is_active)) then
    raise exception 'BAD_VALUE:workers';
  end if;
  if p_custodian is not null and not p_custodian = any(v_workers) then
    raise exception 'CUSTODIAN_REQUIRED';
  end if;
  if coalesce(p_position, 'none') not in ('front', 'back', 'escort', 'none') then
    raise exception 'BAD_VALUE:worker_position';
  end if;

  -- Warehouse / factory points come from the lists (they are measured);
  -- company-only options need the company car.
  if (v_origin = 'warehouse') <> (p_exit_point is not null)
     or (v_dest = 'factory') <> (p_factory_entry is not null)
     or (v_origin = 'factory') <> (p_factory_exit is not null) then
    raise exception 'BAD_VALUE:points';
  end if;
  if exists (select 1 from (values ('exit_point', p_exit_point), ('factory_entry', p_factory_entry),
                                   ('factory_exit', p_factory_exit)) v(cat, val)
             where val is not null and not exists (
               select 1 from public.config_options c
               where c.category = v.cat and c.value = v.val and c.is_active
                 and (v_company or not c.company_only))) then
    raise exception 'BAD_VALUE:points';
  end if;

  -- Direction used by the engine's history: leaving the factory or heading to
  -- the warehouse counts with the return legs, everything else with outbound.
  v_leg := case when v_origin <> 'warehouse' and (v_origin = 'factory' or v_dest = 'warehouse')
                then 'return' else 'outbound' end;

  -- Remember new external sites for next time.
  foreach v_place in array array[v_origin, v_dest] loop
    if v_place not in ('warehouse', 'factory') then
      insert into public.config_options (category, value, is_active, company_only, decoy_ok)
      values ('external_site', v_place, true, false, true)
      on conflict (category, value) do nothing;
    end if;
  end loop;

  if p_trip_id is null then
    insert into public.trips (asset_id, date, trip_type, leg, departure_slot, planned_time, origin, destination,
                              vehicle_type, worker_position, exit_point, factory_entry, factory_exit,
                              assigned_workers, custodian_id, route_note, manual_note, excluded_from_analysis)
    values (p_asset, p_date, 'manual', v_leg, p_slot, p_time, v_origin, v_dest,
            p_vehicle, case when v_company then coalesce(p_position, 'none') else 'none' end,
            p_exit_point, p_factory_entry, p_factory_exit, v_workers, p_custodian,
            nullif(left(btrim(coalesce(p_route_note, '')), 500), ''),
            nullif(left(btrim(coalesce(p_note, '')), 1000), ''), coalesce(p_excluded, false))
    returning id into v_id;
  else
    update public.trips
       set asset_id = p_asset, date = p_date, leg = v_leg, departure_slot = p_slot, planned_time = p_time,
           origin = v_origin, destination = v_dest, vehicle_type = p_vehicle,
           worker_position = case when v_company then coalesce(p_position, 'none') else 'none' end,
           exit_point = p_exit_point, factory_entry = p_factory_entry, factory_exit = p_factory_exit,
           assigned_workers = v_workers, custodian_id = p_custodian,
           route_note = nullif(left(btrim(coalesce(p_route_note, '')), 500), ''),
           manual_note = nullif(left(btrim(coalesce(p_note, '')), 1000), ''),
           excluded_from_analysis = coalesce(p_excluded, false)
     where id = p_trip_id
    returning id into v_id;
  end if;

  perform app_private.sync_budget();

  -- Warnings (the admin decides)
  if not exists (select 1 from public.employees e where e.id = any(v_workers) and e.is_lead_driver) then
    v_warnings := v_warnings || jsonb_build_object('code', 'LEAD_NOT_ASSIGNED', 'detail', null);
  end if;
  if exists (select 1 from public.trips t
             where t.date = p_date and t.departure_slot = p_slot and t.id <> v_id
               and t.vehicle_type = p_vehicle) then
    v_warnings := v_warnings || jsonb_build_object('code', 'VEHICLE_BUSY', 'detail', null);
  end if;
  v_warnings := v_warnings || coalesce((
    select jsonb_agg(jsonb_build_object('code', 'WORKER_BUSY', 'detail', e.name) order by e.name)
    from public.employees e
    where e.id = any(v_workers)
      and exists (select 1 from public.trips t
                  where t.date = p_date and t.departure_slot = p_slot and t.id <> v_id
                    and e.id = any(t.assigned_workers))), '[]'::jsonb);
  if exists (select 1 from public.vehicle_budget b
             where b.vehicle_type = p_vehicle and b.max_per_month is not null
               and app_private.month_usage(p_vehicle, p_date) > b.max_per_month) then
    v_warnings := v_warnings || jsonb_build_object('code', 'BUDGET_EXHAUSTED', 'detail', null);
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'warnings', v_warnings);
end $$;

revoke execute on function public.admin_save_manual_trip(text, uuid, text, date, text, time, text, text, text,
  uuid[], uuid, text, text, text, text, text, text, boolean) from public;
grant execute on function public.admin_save_manual_trip(text, uuid, text, date, text, time, text, text, text,
  uuid[], uuid, text, text, text, text, text, text, boolean) to anon, authenticated;

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

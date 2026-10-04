-- =====================================================================
-- OPS-V2 — two legs per day, product custodian, long-term balance
--
--  * Each asset/day has two legs at fixed times:
--      outbound (morning): warehouse → factory   (exit_point, outbound_route, factory_entry)
--      return   (noon):    factory → warehouse   (factory_exit, return_route)
--    Vehicle and route are drawn per leg.
--  * One custodian (custodian_id) is responsible for the product all day and is
--    on both legs; other crew may differ between legs.
--  * The lead driver is part of every leg: driver of the company vehicle (with
--    the custodian), or alone in the company vehicle as a decoy at the same
--    time when the leg uses another vehicle.
--  * Pre-generation constraints: employee absences (existing) + vehicle
--    unavailability per day.
--  * Anti-pattern scoring adds long-term balance over the full history since
--    the pilot start; admin_pattern_report measures adversary guessability.
-- Run after 0001–0005.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Vehicle unavailability (+ include it in the pre-pilot reset)
-- ---------------------------------------------------------------------

create table public.vehicle_unavailability (
  id            uuid primary key default gen_random_uuid(),
  vehicle_type  text not null,
  date          date not null,
  note          text,
  created_at    timestamptz not null default now(),
  unique (vehicle_type, date)
);
alter table public.vehicle_unavailability enable row level security;
revoke all on public.vehicle_unavailability from anon, authenticated;

create or replace function app_private.reset_data_if_pre_pilot() returns text
language plpgsql as $$
begin
  if app_private.pilot_start_date() is not null then
    return 'pilot started ' || app_private.pilot_start_date() || ' — data kept';
  end if;
  delete from public.trips where true;
  delete from public.employee_absences where true;
  delete from public.vehicle_unavailability where true;
  perform app_private.sync_budget();
  return 'pre-pilot — trips, absences and vehicle blocks wiped';
end $$;

select app_private.reset_data_if_pre_pilot();

-- The trips table changes shape; existing rows can't be converted automatically.
do $$
begin
  if exists (select 1 from public.trips) then
    raise exception 'trips is not empty (pilot already started) — convert existing trips manually before applying 0006';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Trips: legs + custodian
-- ---------------------------------------------------------------------

alter table public.trips add column leg text not null check (leg in ('outbound', 'return'));
alter table public.trips add column custodian_id uuid references public.employees(id);
alter table public.trips
  alter column exit_point drop not null,
  alter column outbound_route drop not null,
  alter column factory_entry drop not null,
  alter column factory_exit drop not null,
  alter column return_route drop not null;

alter table public.trips add constraint trips_leg_fields check (
  (leg = 'outbound' and exit_point is not null and outbound_route is not null and factory_entry is not null
                    and factory_exit is null and return_route is null)
  or
  (leg = 'return' and factory_exit is not null and return_route is not null
                  and exit_point is null and outbound_route is null and factory_entry is null));
alter table public.trips add constraint trips_leg_slot check (
  (leg = 'outbound' and departure_slot = 'morning') or (leg = 'return' and departure_slot = 'noon'));
alter table public.trips add constraint trips_custodian_on_real check (
  trip_type = 'decoy' or (custodian_id is not null and custodian_id = any(assigned_workers)));

drop index public.trips_one_real_per_day;
create unique index trips_one_real_per_leg on public.trips (asset_id, date, leg) where trip_type = 'real';

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

create or replace function app_private.trip_label(p_asset text, p_slot text) returns text
language sql immutable as $$
  select 'משימה ' || p_asset || ' · '
         || case p_slot when 'morning' then 'יציאה (בוקר)' when 'noon' then 'חזרה (צהריים)' else p_slot end
$$;

create function app_private.vehicle_blocked(p_vehicle text, p_day date) returns boolean
language sql stable as $$
  select exists (select 1 from public.vehicle_unavailability where vehicle_type = p_vehicle and date = p_day)
$$;

-- Over-use of a value in a bucket: how far (count+1) exceeds an even share,
-- relative to that share. 0 when the value is at or below its fair share.
create function app_private.overuse(p_count int, p_total int, p_k int) returns numeric
language sql immutable as $$
  select greatest(0, (p_count + 1) - (p_total + 1)::numeric / greatest(p_k, 1))
         / greatest((p_total + 1)::numeric / greatest(p_k, 1), 1)
$$;

-- Score of a candidate leg (lower is better) = 100 × hard + soft.
--  hard (short-term, last 10 legs of this direction):
--    +10 per exact repeat of the combination
--    + excess when the vehicle would exceed 60% on this weekday (≥4 samples)
--  soft (long-term, full history since the pilot start):
--    over-use of the vehicle overall, per weekday, and (return leg) given the
--    morning vehicle; over-use of each route/entry/exit value.
create function app_private.leg_score(
  p_asset text, p_day date, p_leg text, p_vehicle text,
  p_a text, p_b text, p_c text, p_out_vehicle text
) returns numeric
language plpgsql stable as $$
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
        where asset_id = p_asset and leg = p_leg and trip_type = 'real'
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
        where asset_id = p_asset and leg = p_leg and trip_type = 'real'
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
    count(*) filter (where factory_entry = p_c)::int                             as c_cnt
  into r
  from public.trips
  where asset_id = p_asset and leg = p_leg and trip_type = 'real'
    and not excluded_from_analysis and date >= v_since and date < p_day;

  v_soft := 2 * app_private.overuse(r.veh, r.total, v_kv)
          + 2 * app_private.overuse(r.dow_veh, r.dow_total, v_kv)
          + app_private.overuse(r.a_cnt, r.total, cardinality(app_private.options(
              case p_leg when 'outbound' then 'exit_point' else 'factory_exit' end)))
          + app_private.overuse(r.b_cnt, r.total, cardinality(app_private.options(
              case p_leg when 'outbound' then 'outbound_route' else 'return_route' end)));
  if p_leg = 'outbound' then
    v_soft := v_soft + app_private.overuse(r.c_cnt, r.total, cardinality(app_private.options('factory_entry')));
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
end $$;

create or replace function app_private.trip_admin_json(p_trip public.trips) returns jsonb
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

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Week generation (replaces 0005 version)
-- ---------------------------------------------------------------------

create or replace function public.admin_generate_week(p_token text, p_pin text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
  v_monday date;
  v_day date;
  v_asset record;
  v_vehicles text[];
  -- per category: _c = usable with company vehicle, _n = with other vehicles
  v_exits_c text[]; v_exits_n text[]; v_outs_c text[]; v_outs_n text[];
  v_fent_c text[]; v_fent_n text[]; v_fexit_c text[]; v_fexit_n text[];
  v_ret_c text[]; v_ret_n text[];
  v_positions text[];
  v_lead uuid;
  v_pool uuid[];
  v_custodian uuid;
  v_leg text;
  v_slot text;
  v_out_vehicle text;
  v_lead_free boolean;
  v_decoy_ok boolean;
  v_must_decoy boolean;
  v_recent_decoys int;
  v_allowed text[];
  v_is_company boolean;
  v_score numeric; v_best numeric;
  c_vehicle text; c_a text; c_b text; c_c text;
  b_vehicle text; b_a text; b_b text; b_c text;
  v_extra uuid[];
  v_workers uuid[];
  v_real_id uuid; v_decoy_id uuid;
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

  v_monday   := app_private.week_monday(p_week_start);
  v_vehicles := app_private.options('vehicle_type');
  v_exits_c  := app_private.options_for('exit_point', true);
  v_exits_n  := app_private.options_for('exit_point', false);
  v_outs_c   := app_private.options_for('outbound_route', true);
  v_outs_n   := app_private.options_for('outbound_route', false);
  v_fent_c   := app_private.options_for('factory_entry', true);
  v_fent_n   := app_private.options_for('factory_entry', false);
  v_fexit_c  := app_private.options_for('factory_exit', true);
  v_fexit_n  := app_private.options_for('factory_exit', false);
  v_ret_c    := app_private.options_for('return_route', true);
  v_ret_n    := app_private.options_for('return_route', false);
  v_positions := array(select unnest(app_private.options('worker_position'))
                       intersect select unnest(array['front', 'back']));
  if cardinality(v_positions) = 0 then
    v_positions := array['front', 'back'];
  end if;

  if cardinality(v_vehicles) = 0 then raise exception 'CONFIG_MISSING:vehicle_type'; end if;
  if cardinality(v_exits_n)  = 0 then raise exception 'CONFIG_MISSING:exit_point'; end if;
  if cardinality(v_outs_n)   = 0 then raise exception 'CONFIG_MISSING:outbound_route'; end if;
  if cardinality(v_fent_n)   = 0 then raise exception 'CONFIG_MISSING:factory_entry'; end if;
  if cardinality(v_fexit_n)  = 0 then raise exception 'CONFIG_MISSING:factory_exit'; end if;
  if cardinality(v_ret_n)    = 0 then raise exception 'CONFIG_MISSING:return_route'; end if;

  for i in 0..4 loop
    v_day := v_monday + i;

    -- Lead driver for the day (skips anyone marked absent).
    v_lead := null;
    select id into v_lead from public.employees
    where role = 'operator' and is_active and is_lead_driver
      and not app_private.is_absent(id, v_day)
    order by random() limit 1;

    -- Assignment pool: every active non-lead employee (admins included), not absent.
    v_pool := array(select id from public.employees
                    where is_active and not is_lead_driver
                      and not app_private.is_absent(id, v_day));

    for v_asset in select id from public.assets where is_active order by id loop
      if exists (select 1 from public.trips
                 where asset_id = v_asset.id and date = v_day and trip_type = 'real') then
        v_skipped := v_skipped || jsonb_build_object('asset', v_asset.id, 'date', v_day, 'reason', 'EXISTS');
        continue;
      end if;

      -- Custodian for the day: free (not custodian of another asset today),
      -- preferring whoever has carried the product least since the pilot start.
      v_custodian := null;
      select w into v_custodian
      from unnest(v_pool) w
      where not exists (select 1 from public.trips t
                        where t.date = v_day and t.trip_type = 'real' and t.custodian_id = w)
      order by (select count(distinct t.date) from public.trips t
                where t.custodian_id = w and t.trip_type = 'real'
                  and t.date >= coalesce(app_private.pilot_start_date(), '-infinity'::date))
               + random() * 6
      limit 1;

      if v_custodian is null then
        v_warnings := v_warnings || jsonb_build_object(
          'asset', v_asset.id, 'date', v_day, 'reason', 'NO_WORKER',
          'message', 'אין עובד פנוי ל-' || v_asset.id || ' ב-' || to_char(v_day, 'DD/MM/YYYY')
                     || ' - נדרשת התערבות ידנית');
        continue;
      end if;

      v_out_vehicle := null;

      foreach v_leg in array array['outbound', 'return'] loop
        v_slot := case v_leg when 'outbound' then 'morning' else 'noon' end;

        -- The lead is on at most one leg per time slot (across assets).
        v_lead_free := v_lead is not null and not exists (
          select 1 from public.trips
          where date = v_day and departure_slot = v_slot and v_lead = any(assigned_workers));

        -- Decoy possible on this leg? (company vehicle available, ≤5 decoys in
        -- the last 10 legs of this direction, alternatives to differ from the real leg)
        v_decoy_ok := false;
        if v_lead_free and not app_private.vehicle_blocked('company', v_day)
           and not app_private.budget_exhausted('company', v_day)
           and (case v_leg when 'outbound' then cardinality(v_outs_c) > 1 and cardinality(v_fent_c) > 1
                           else cardinality(v_fexit_c) > 1 and cardinality(v_ret_c) > 1 end) then
          select count(*) filter (where decoy_trip_id is not null) into v_recent_decoys
          from (select decoy_trip_id from public.trips
                where asset_id = v_asset.id and leg = v_leg and trip_type = 'real'
                  and not excluded_from_analysis and date < v_day
                order by date desc limit 10) r;
          v_decoy_ok := v_recent_decoys < 5;
        end if;

        -- Vehicles: available that day, within budget. Company needs the free lead;
        -- other vehicles need a decoy while the lead is free (lead is part of every leg).
        v_allowed := array(
          select v from unnest(v_vehicles) v
          where not app_private.vehicle_blocked(v, v_day)
            and not app_private.budget_exhausted(v, v_day)
            and case when v = 'company' then v_lead_free
                     else v_decoy_ok or not v_lead_free end);

        v_must_decoy := v_lead_free;
        if cardinality(v_allowed) = 0 and v_lead_free then
          v_allowed := array(
            select v from unnest(v_vehicles) v
            where v <> 'company' and not app_private.vehicle_blocked(v, v_day)
              and not app_private.budget_exhausted(v, v_day));
          v_must_decoy := false;
          if cardinality(v_allowed) > 0 then
            v_warnings := v_warnings || jsonb_build_object(
              'asset', v_asset.id, 'date', v_day, 'reason', 'LEAD_UNASSIGNED',
              'message', 'נהג ראשי לא שובץ ל-' || v_asset.id || ' ב-' || to_char(v_day, 'DD/MM/YYYY')
                         || case v_leg when 'outbound' then ' (יציאה)' else ' (חזרה)' end
                         || ' - רכב החברה לא זמין או שמכסת הפיתויים מוצתה');
          end if;
        end if;
        if cardinality(v_allowed) = 0 then
          v_warnings := v_warnings || jsonb_build_object(
            'asset', v_asset.id, 'date', v_day, 'reason', 'NO_VEHICLE',
            'message', 'אין רכב זמין ל-' || v_asset.id || ' ב-' || to_char(v_day, 'DD/MM/YYYY')
                       || case v_leg when 'outbound' then ' (יציאה)' else ' (חזרה)' end
                       || ' - נדרשת התערבות ידנית');
          continue;
        end if;

        -- Draw 10 candidates, keep the lowest score.
        v_best := null;
        for v_try in 1..10 loop
          c_vehicle := app_private.pick(v_allowed);
          v_is_company := c_vehicle = 'company';
          if v_leg = 'outbound' then
            c_a := app_private.pick(case when v_is_company then v_exits_c else v_exits_n end);
            c_b := app_private.pick(case when v_is_company then v_outs_c else v_outs_n end);
            c_c := app_private.pick(case when v_is_company then v_fent_c else v_fent_n end);
          else
            c_a := app_private.pick(case when v_is_company then v_fexit_c else v_fexit_n end);
            c_b := app_private.pick(case when v_is_company then v_ret_c else v_ret_n end);
            c_c := null;
          end if;
          v_score := app_private.leg_score(v_asset.id, v_day, v_leg, c_vehicle, c_a, c_b, c_c, v_out_vehicle);
          if v_best is null or v_score < v_best then
            v_best := v_score;
            b_vehicle := c_vehicle; b_a := c_a; b_b := c_b; b_c := c_c;
          end if;
        end loop;
        if v_best >= 100 then
          v_fallbacks := v_fallbacks + 1;
        end if;
        v_is_company := b_vehicle = 'company';

        -- Crew: custodian always. Company: lead + custodian (never lead alone with
        -- the product). Other vehicle: custodian + sometimes one more free worker.
        if v_is_company then
          v_workers := array[v_lead, v_custodian];
        else
          v_extra := array(
            select w from unnest(v_pool) w
            where w <> v_custodian
              and not exists (select 1 from public.trips t
                              where t.date = v_day and t.departure_slot = v_slot
                                and t.trip_type = 'real' and w = any(t.assigned_workers))
            order by random() limit (random() < 0.5)::int);
          v_workers := array[v_custodian] || v_extra;
        end if;

        insert into public.trips (asset_id, date, leg, trip_type, departure_slot, vehicle_type,
          worker_position, exit_point, outbound_route, factory_entry, factory_exit, return_route,
          assigned_workers, custodian_id)
        values (v_asset.id, v_day, v_leg, 'real', v_slot, b_vehicle,
          case when v_is_company then app_private.pick(v_positions) else 'none' end,
          case v_leg when 'outbound' then b_a end,
          case v_leg when 'outbound' then b_b end,
          case v_leg when 'outbound' then b_c end,
          case v_leg when 'return' then b_a end,
          case v_leg when 'return' then b_b end,
          v_workers, v_custodian)
        returning id into v_real_id;
        v_created := v_created + 1;

        -- Decoy at the same time: lead alone in the company vehicle, different
        -- route and entry/exit than the real leg.
        if not v_is_company and v_must_decoy then
          insert into public.trips (asset_id, date, leg, trip_type, departure_slot, vehicle_type,
            worker_position, exit_point, outbound_route, factory_entry, factory_exit, return_route,
            assigned_workers, decoy_trip_id)
          values (v_asset.id, v_day, v_leg, 'decoy', v_slot, 'company', 'none',
            case v_leg when 'outbound' then app_private.pick(app_private.prefer_other(v_exits_c, b_a)) end,
            case v_leg when 'outbound' then app_private.pick(array_remove(v_outs_c, b_b)) end,
            case v_leg when 'outbound' then app_private.pick(array_remove(v_fent_c, b_c)) end,
            case v_leg when 'return' then app_private.pick(array_remove(v_fexit_c, b_a)) end,
            case v_leg when 'return' then app_private.pick(array_remove(v_ret_c, b_b)) end,
            array[v_lead], v_real_id)
          returning id into v_decoy_id;
          update public.trips set decoy_trip_id = v_decoy_id where id = v_real_id;
          v_decoys := v_decoys + 1;
        end if;

        if v_leg = 'outbound' then
          v_out_vehicle := b_vehicle;
        end if;
      end loop;
    end loop;
  end loop;

  perform app_private.sync_budget();

  return jsonb_build_object('ok', true, 'week_start', v_monday, 'created', v_created,
                            'decoys', v_decoys, 'fallbacks', v_fallbacks,
                            'skipped', v_skipped, 'warnings', v_warnings);
end $$;

-- ---------------------------------------------------------------------
-- Trip edit (replaces 0003 version)
-- ---------------------------------------------------------------------

create or replace function public.admin_update_trip(p_token text, p_trip_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
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
  if v_trip.status <> 'planned'
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
      if v_sibling.status <> 'planned' then
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

  if v_trip.status = 'planned' then
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
    elsif v_trip.trip_type = 'real' and v_trip.worker_position not in ('front', 'back') then
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
end $$;

-- ---------------------------------------------------------------------
-- Worker detail: include the leg (replaces 0001 version)
-- ---------------------------------------------------------------------

create or replace function public.worker_trip_detail(p_token text, p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_trip public.trips;
begin
  select * into v_trip from public.trips
  where id = p_trip_id and date = app_private.today() and v_emp.id = any(assigned_workers);
  if not found then
    raise exception 'NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_trip.id,
    'label', app_private.trip_label(v_trip.asset_id, v_trip.departure_slot),
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
    'status', v_trip.status,
    'problem_note', v_trip.problem_note,
    'actual_start_at', v_trip.actual_start_at,
    'actual_done_at', v_trip.actual_done_at
  );
end $$;

-- ---------------------------------------------------------------------
-- Constraints: vehicle unavailability
-- ---------------------------------------------------------------------

create function public.admin_set_vehicle_block(p_token text, p_vehicle_type text, p_date date,
                                               p_blocked boolean, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  if p_date is null or not exists (select 1 from public.config_options
                                   where category = 'vehicle_type' and value = p_vehicle_type) then
    raise exception 'BAD_INPUT';
  end if;
  if coalesce(p_blocked, true) then
    insert into public.vehicle_unavailability (vehicle_type, date, note)
    values (p_vehicle_type, p_date, nullif(btrim(p_note), ''))
    on conflict (vehicle_type, date) do update set note = excluded.note;
  else
    delete from public.vehicle_unavailability where vehicle_type = p_vehicle_type and date = p_date;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Admin week: add vehicle blocks (replaces 0003 version)
-- ---------------------------------------------------------------------

create or replace function public.admin_week(p_token text, p_date date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_monday date := app_private.week_monday(coalesce(p_date, app_private.today()));
begin
  return jsonb_build_object(
    'week_start', v_monday,
    'today', app_private.today(),
    'trips', coalesce((
      select jsonb_agg(app_private.trip_admin_json(t)
                       order by t.date, t.asset_id, t.departure_slot, t.trip_type)
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
end $$;

-- ---------------------------------------------------------------------
-- Pattern report: what could an adversary learn from the history?
-- ---------------------------------------------------------------------

create function public.admin_pattern_report(p_token text, p_days int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
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
  where t.trip_type = 'real' and not t.excluded_from_analysis and t.date >= v_from;

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
                from rpt r join rpt o on o.asset_id = r.asset_id and o.date = r.date and o.leg = 'outbound'
                where r.leg = 'return' group by 1, 2) o
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
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

revoke execute on function
  public.admin_set_vehicle_block(text, text, date, boolean, text),
  public.admin_pattern_report(text, int)
from public;

grant execute on function
  public.admin_set_vehicle_block(text, text, date, boolean, text),
  public.admin_pattern_report(text, int)
to anon, authenticated;

commit;

-- =====================================================================
-- OPS-V2 — pilot flag + crew availability
--  1. Pre-pilot data reset: until the admin declares the pilot start,
--     every migration wipes operational data (trips, absences).
--     After the declaration, app_settings.pilot_start_date is set
--     (immutable) and migrations leave data untouched.
--  2. Lead driver never travels with the product without a co-worker.
--     A worker is "free" if active, not absent and not already on another
--     real trip that day. No free worker → no trip for that asset/day, and
--     the admin gets "אין עובד פנוי ל-A1 ב-[תאריך] - נדרשת התערבות ידנית".
--
-- CONVENTION for every future migration: first statement inside the
-- transaction must be
--     select app_private.reset_data_if_pre_pilot();
-- Run after 0001–0004.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- App settings + pilot flag
-- ---------------------------------------------------------------------

create table public.app_settings (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.employees(id) on delete set null
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

-- Once set, the pilot flag can never be changed or removed.
create function app_private.protect_pilot_flag() returns trigger
language plpgsql as $$
begin
  if old.key = 'pilot_start_date' then
    raise exception 'PILOT_FLAG_LOCKED';
  end if;
  return coalesce(new, old);
end $$;

create trigger app_settings_protect_pilot
  before update or delete on public.app_settings
  for each row execute function app_private.protect_pilot_flag();

create function app_private.pilot_start_date() returns date
language sql stable as $$
  select value::date from public.app_settings where key = 'pilot_start_date'
$$;

-- Wipes operational data unless the pilot has started. Called at the top of
-- every migration. Configuration (employees, assets, options, budgets) is kept.
create function app_private.reset_data_if_pre_pilot() returns text
language plpgsql as $$
begin
  if app_private.pilot_start_date() is not null then
    return 'pilot started ' || app_private.pilot_start_date() || ' — data kept';
  end if;
  delete from public.trips where true;
  delete from public.employee_absences where true;
  perform app_private.sync_budget();
  return 'pre-pilot — trips and absences wiped';
end $$;

revoke all on all functions in schema app_private from public;

create function public.admin_declare_pilot(p_token text, p_pin text, p_wipe_test_data boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
begin
  v_check := app_private.check_pin(v_admin.id, p_pin);
  if v_check <> 'ok' then
    return app_private.stepup_error(v_check);
  end if;
  if app_private.pilot_start_date() is not null then
    raise exception 'PILOT_ALREADY_STARTED';
  end if;

  if coalesce(p_wipe_test_data, false) then
    delete from public.trips where true;
    perform app_private.sync_budget();
  end if;

  insert into public.app_settings (key, value, updated_by)
  values ('pilot_start_date', app_private.today()::text, v_admin.id);

  return jsonb_build_object('ok', true, 'pilot_start_date', app_private.today());
end $$;

-- ---------------------------------------------------------------------
-- Week generation (replaces 0003/0004 version)
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
  v_lead_free boolean;
  v_pool uuid[];
  v_free uuid[];
  v_allowed text[];
  v_decoy_ok boolean;
  v_must_decoy boolean;
  v_recent_decoys int;
  v_is_company boolean;
  v_score int; v_best int;
  c_vehicle text; c_exit text; c_out text; c_fentry text;
  b_vehicle text; b_exit text; b_out text; b_fentry text;
  v_slot text; v_position text; v_workers uuid[];
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

      -- Free workers: not already on another real (product) trip today.
      v_free := array(
        select w from unnest(v_pool) w
        where not exists (select 1 from public.trips t
                          where t.date = v_day and t.trip_type = 'real' and w = any(t.assigned_workers)));

      -- No free worker → the lead would be alone with the product. Never create
      -- such a trip; ask the admin to intervene.
      if cardinality(v_free) = 0 then
        v_warnings := v_warnings || jsonb_build_object(
          'asset', v_asset.id, 'date', v_day, 'reason', 'NO_WORKER',
          'message', 'אין עובד פנוי ל-' || v_asset.id || ' ב-' || to_char(v_day, 'DD/MM/YYYY')
                     || ' - נדרשת התערבות ידנית');
        continue;
      end if;

      -- The lead takes at most one trip per day.
      v_lead_free := v_lead is not null and not exists (
        select 1 from public.trips where date = v_day and v_lead = any(assigned_workers));

      -- Can a decoy be produced today? (lead free, ≤5 decoys in last 10 real trips,
      -- company budget left, an alternative outbound route and factory entry exist)
      v_decoy_ok := false;
      if v_lead_free and not app_private.budget_exhausted('company', v_day)
         and cardinality(v_outs_c) > 1 and cardinality(v_fent_c) > 1 then
        select count(*) filter (where decoy_trip_id is not null) into v_recent_decoys
        from (select decoy_trip_id from public.trips
              where asset_id = v_asset.id and trip_type = 'real'
                and not excluded_from_analysis and date < v_day
              order by date desc, created_at desc
              limit 10) r;
        v_decoy_ok := v_recent_decoys < 5;
      end if;

      -- Vehicles: company needs the free lead (+ a free worker, guaranteed above).
      -- Other vehicles need — while the lead is free — a decoy, so the lead is on
      -- a trip every day.
      v_allowed := array(
        select v from unnest(v_vehicles) v
        where not app_private.budget_exhausted(v, v_day)
          and case when v = 'company' then v_lead_free
                   else v_decoy_ok or not v_lead_free end);

      v_must_decoy := v_lead_free;
      if cardinality(v_allowed) = 0 and v_lead_free then
        -- Lead can't be placed today (e.g. company budget exhausted): fall back to
        -- other vehicles without a decoy and report it.
        v_allowed := array(
          select v from unnest(v_vehicles) v
          where v <> 'company' and not app_private.budget_exhausted(v, v_day));
        v_must_decoy := false;
        if cardinality(v_allowed) > 0 then
          v_warnings := v_warnings || jsonb_build_object(
            'asset', v_asset.id, 'date', v_day, 'reason', 'LEAD_UNASSIGNED',
            'message', 'נהג ראשי לא שובץ ל-' || v_asset.id || ' ב-' || to_char(v_day, 'DD/MM/YYYY')
                       || ' (אין אפשרות לפיתוי או מכסת רכב חברה מוצתה)');
        end if;
      end if;
      if cardinality(v_allowed) = 0 then
        v_skipped := v_skipped || jsonb_build_object('asset', v_asset.id, 'date', v_day, 'reason', 'NO_VEHICLE');
        continue;
      end if;

      -- Draw, score against history, retry up to 10 times, keep the best.
      v_best := null;
      for v_try in 1..10 loop
        c_vehicle := app_private.pick(v_allowed);
        v_is_company := c_vehicle = 'company';
        c_exit   := app_private.pick(case when v_is_company then v_exits_c else v_exits_n end);
        c_out    := app_private.pick(case when v_is_company then v_outs_c else v_outs_n end);
        c_fentry := app_private.pick(case when v_is_company then v_fent_c else v_fent_n end);
        v_score := app_private.pattern_score(v_asset.id, v_day, c_vehicle, c_exit, c_out, c_fentry);
        if v_best is null or v_score < v_best then
          v_best := v_score;
          b_vehicle := c_vehicle; b_exit := c_exit; b_out := c_out; b_fentry := c_fentry;
        end if;
        exit when v_score = 0;
      end loop;
      if v_best > 0 then
        v_fallbacks := v_fallbacks + 1;
      end if;

      v_is_company := b_vehicle = 'company';
      v_slot := app_private.pick(array['morning', 'noon']);

      -- One crew for the whole round trip (out + factory + back).
      if v_is_company then
        v_position := app_private.pick(v_positions);
        v_workers := array[v_lead]
          || array(select w from unnest(v_free) w order by random() limit 1);
      else
        v_position := 'none';
        v_workers := array(select w from unnest(v_free) w order by random()
                           limit 1 + floor(random() * 2)::int);
      end if;

      insert into public.trips (asset_id, date, trip_type, departure_slot, vehicle_type,
        worker_position, exit_point, outbound_route, factory_entry, factory_exit,
        return_route, assigned_workers)
      values (v_asset.id, v_day, 'real', v_slot, b_vehicle, v_position, b_exit, b_out, b_fentry,
        app_private.pick(case when v_is_company then v_fexit_c else v_fexit_n end),
        app_private.pick(case when v_is_company then v_ret_c else v_ret_n end),
        v_workers)
      returning id into v_real_id;
      v_created := v_created + 1;

      -- Decoy: lead alone in the company vehicle (no product), opposite time
      -- slot, different outbound route and factory entry (exit point too, if
      -- more than one is active), cross-linked to the real trip.
      if not v_is_company and v_must_decoy then
        insert into public.trips (asset_id, date, trip_type, departure_slot, vehicle_type,
          worker_position, exit_point, outbound_route, factory_entry, factory_exit,
          return_route, assigned_workers, decoy_trip_id)
        values (v_asset.id, v_day, 'decoy',
          case v_slot when 'morning' then 'noon' else 'morning' end,
          'company', 'none',
          app_private.pick(app_private.prefer_other(v_exits_c, b_exit)),
          app_private.pick(array_remove(v_outs_c, b_out)),
          app_private.pick(array_remove(v_fent_c, b_fentry)),
          app_private.pick(v_fexit_c),
          app_private.pick(v_ret_c),
          array[v_lead], v_real_id)
        returning id into v_decoy_id;
        update public.trips set decoy_trip_id = v_decoy_id where id = v_real_id;
        v_decoys := v_decoys + 1;
      end if;
    end loop;
  end loop;

  perform app_private.sync_budget();

  return jsonb_build_object('ok', true, 'week_start', v_monday, 'created', v_created,
                            'decoys', v_decoys, 'fallbacks', v_fallbacks,
                            'skipped', v_skipped, 'warnings', v_warnings);
end $$;

-- ---------------------------------------------------------------------
-- Settings read: expose pilot status (replaces 0003 version)
-- ---------------------------------------------------------------------

create or replace function public.admin_settings(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  perform app_private.sync_budget();
  return jsonb_build_object(
    'me', v_admin.id,
    'pilot_start_date', app_private.pilot_start_date(),
    'employees', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'name', name, 'role', role, 'is_lead_driver', is_lead_driver,
               'is_active', is_active,
               'locked_until', case when locked_until > now() then locked_until end)
             order by is_active desc, role, name)
      from public.employees), '[]'::jsonb),
    'assets', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.id) from public.assets a), '[]'::jsonb),
    'config', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.category, c.value) from public.config_options c), '[]'::jsonb),
    'budget', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.vehicle_type) from public.vehicle_budget b), '[]'::jsonb),
    'absences', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', employee_id, 'date', date, 'note', note)
                       order by date)
      from public.employee_absences where date >= app_private.today() - 7), '[]'::jsonb)
  );
end $$;

revoke execute on function public.admin_declare_pilot(text, text, boolean) from public;
grant execute on function public.admin_declare_pilot(text, text, boolean) to anon, authenticated;

-- Pre-pilot: start this version from clean data.
select app_private.reset_data_if_pre_pilot();

commit;

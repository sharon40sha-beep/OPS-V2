-- =====================================================================
-- OPS-V2 — rules update
--  1. PIN policy (server-side): ≥6 chars, uppercase, digit, symbol.
--  2. Lead driver: never alone on a real trip; on a trip every weekday
--     (real company trip or decoy) unless marked absent; alone on decoys.
--  3. Exit always from the covered parking; company-only options
--     (factory_exit 'כניסה ראשית' only for company vehicle).
--  4. Admins are part of the assignment pool.
--  5. Workers can add a note without changing status
--     (e.g. "בוצע במקום המנהל").
-- Run after 0001 + 0002.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------

create table public.employee_absences (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.employees(id) on delete cascade,
  date         date not null,
  note         text,
  created_at   timestamptz not null default now(),
  unique (employee_id, date)
);
alter table public.employee_absences enable row level security;
revoke all on public.employee_absences from anon, authenticated;

-- An option flagged company_only is drawn/allowed only for the company vehicle.
alter table public.config_options add column company_only boolean not null default false;

update public.config_options set company_only = true
 where category = 'factory_exit' and value = 'כניסה ראשית';
update public.config_options set is_active = false
 where category = 'exit_point' and value = 'כניסה ראשית';

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

create function app_private.pin_policy_ok(p_pin text) returns boolean
language sql immutable as $$
  select length(p_pin) >= 6
     and p_pin ~ '[A-Z]'
     and p_pin ~ '[0-9]'
     and p_pin ~ '[^[:alnum:][:space:]]'
$$;

-- Active values of a category usable with the given vehicle class.
create function app_private.options_for(p_category text, p_company boolean) returns text[]
language sql stable as $$
  select coalesce(array_agg(value order by value), '{}')
  from public.config_options
  where category = p_category and is_active and (p_company or not company_only)
$$;

create function app_private.is_absent(p_employee uuid, p_day date) returns boolean
language sql stable as $$
  select exists (select 1 from public.employee_absences
                 where employee_id = p_employee and date = p_day)
$$;

-- Removes p_exclude from p_arr unless that would leave it empty.
create function app_private.prefer_other(p_arr text[], p_exclude text) returns text[]
language sql immutable as $$
  select case when cardinality(array_remove(p_arr, p_exclude)) > 0
              then array_remove(p_arr, p_exclude) else p_arr end
$$;

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Week generation (replaces 0001 version)
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

      -- The lead takes at most one trip per day.
      v_lead_free := v_lead is not null and not exists (
        select 1 from public.trips where date = v_day and v_lead = any(assigned_workers));

      -- Can a decoy be produced today? (lead free, ≤3 decoys in last 10 real trips,
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
        v_decoy_ok := v_recent_decoys < 3;
      end if;

      -- Vehicles: company needs the free lead + one more worker (lead never alone
      -- with the product). Other vehicles need a worker, and — while the lead is
      -- free — a decoy, so the lead is on a trip every day.
      v_allowed := array(
        select v from unnest(v_vehicles) v
        where not app_private.budget_exhausted(v, v_day)
          and cardinality(v_pool) > 0
          and case when v = 'company' then v_lead_free
                   else v_decoy_ok or not v_lead_free end);

      v_must_decoy := v_lead_free;
      if cardinality(v_allowed) = 0 and v_lead_free then
        -- Lead can't be placed today (e.g. company budget exhausted): fall back to
        -- other vehicles without a decoy and report it.
        v_allowed := array(
          select v from unnest(v_vehicles) v
          where v <> 'company' and not app_private.budget_exhausted(v, v_day)
            and cardinality(v_pool) > 0);
        v_must_decoy := false;
        if cardinality(v_allowed) > 0 then
          v_warnings := v_warnings || jsonb_build_object('asset', v_asset.id, 'date', v_day, 'reason', 'LEAD_UNASSIGNED');
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

      if v_is_company then
        v_position := app_private.pick(v_positions);
        v_workers := array[v_lead]
          || array(select w from unnest(v_pool) w order by random() limit 1);
      else
        v_position := 'none';
        v_workers := array(select w from unnest(v_pool) w order by random()
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

      -- Decoy: lead alone in the company vehicle, opposite time slot,
      -- different outbound route and factory entry (exit point too, if
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
-- Trip edit validation (replaces 0001 version)
-- ---------------------------------------------------------------------

create or replace function public.admin_update_trip(p_token text, p_trip_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_trip public.trips;
  v_key text;
  v_leads int;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    raise exception 'NOT_FOUND';
  end if;
  if v_trip.status <> 'planned'
     and exists (select 1 from jsonb_object_keys(p_data) k where k <> 'excluded_from_analysis') then
    raise exception 'NOT_PLANNED';
  end if;

  foreach v_key in array array['vehicle_type', 'exit_point', 'outbound_route',
                               'factory_entry', 'factory_exit', 'return_route'] loop
    if p_data ? v_key and not app_private.is_valid_option(v_key, p_data->>v_key) then
      raise exception 'BAD_VALUE:%', v_key;
    end if;
  end loop;
  if p_data ? 'departure_slot' and p_data->>'departure_slot' not in ('morning', 'noon') then
    raise exception 'BAD_VALUE:departure_slot';
  end if;

  update public.trips set
    vehicle_type    = coalesce(p_data->>'vehicle_type', vehicle_type),
    exit_point      = coalesce(p_data->>'exit_point', exit_point),
    outbound_route  = coalesce(p_data->>'outbound_route', outbound_route),
    factory_entry   = coalesce(p_data->>'factory_entry', factory_entry),
    factory_exit    = coalesce(p_data->>'factory_exit', factory_exit),
    return_route    = coalesce(p_data->>'return_route', return_route),
    departure_slot  = coalesce(p_data->>'departure_slot', departure_slot),
    worker_position = coalesce(p_data->>'worker_position', worker_position),
    assigned_workers = case when p_data ? 'assigned_workers'
      then array(select distinct x::uuid from jsonb_array_elements_text(p_data->'assigned_workers') x)
      else assigned_workers end,
    excluded_from_analysis = coalesce((p_data->>'excluded_from_analysis')::boolean, excluded_from_analysis)
  where id = p_trip_id
  returning * into v_trip;

  -- Business rules on the resulting row (raising rolls the update back).
  if v_trip.status = 'planned' then
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

    if p_data ? 'vehicle_type' and app_private.month_usage(v_trip.vehicle_type, v_trip.date) > coalesce(
         (select max_per_month from public.vehicle_budget where vehicle_type = v_trip.vehicle_type),
         2147483647) then
      raise exception 'BUDGET_EXHAUSTED';
    end if;
  end if;

  perform app_private.sync_budget();
  return jsonb_build_object('ok', true, 'trip', app_private.trip_admin_json(v_trip));
end $$;

-- ---------------------------------------------------------------------
-- Worker status: new 'note' action (appends a note, status unchanged)
-- ---------------------------------------------------------------------

create or replace function public.worker_set_status(p_token text, p_trip_id uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_trip public.trips;
  v_note text := left(btrim(coalesce(p_note, '')), 1000);
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
    update public.trips set status = 'done', actual_done_at = now() where id = v_trip.id;
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
-- Employees: PIN policy (replaces 0001 version)
-- ---------------------------------------------------------------------

create or replace function public.admin_save_employee(
  p_token text, p_id uuid, p_name text, p_role text, p_is_lead_driver boolean,
  p_is_active boolean, p_pin text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_pin text := nullif(p_pin, '');
  v_id uuid;
begin
  if btrim(coalesce(p_name, '')) = '' or p_role not in ('admin', 'operator') then
    raise exception 'BAD_INPUT';
  end if;
  if v_pin is not null and not app_private.pin_policy_ok(v_pin) then
    raise exception 'PIN_POLICY';
  end if;
  if exists (select 1 from public.employees
             where lower(btrim(name)) = lower(btrim(p_name)) and id is distinct from p_id) then
    raise exception 'NAME_TAKEN';
  end if;

  if p_id is null then
    if v_pin is null then
      raise exception 'PIN_REQUIRED';
    end if;
    insert into public.employees (name, pin_hash, role, is_lead_driver, is_active)
    values (btrim(p_name), crypt(v_pin, gen_salt('bf', 10)), p_role,
            p_role = 'operator' and coalesce(p_is_lead_driver, false), coalesce(p_is_active, true))
    returning id into v_id;
  else
    if p_id = v_admin.id and (p_role <> 'admin' or not coalesce(p_is_active, true)) then
      raise exception 'CANNOT_DEMOTE_SELF';
    end if;
    update public.employees set
      name = btrim(p_name),
      role = p_role,
      is_lead_driver = p_role = 'operator' and coalesce(p_is_lead_driver, false),
      is_active = coalesce(p_is_active, true),
      pin_hash = case when v_pin is null then pin_hash else crypt(v_pin, gen_salt('bf', 10)) end,
      failed_attempts = case when v_pin is null then failed_attempts else 0 end,
      locked_until = case when v_pin is null then locked_until end
    where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'NOT_FOUND';
    end if;
    if v_pin is not null or not coalesce(p_is_active, true) then
      delete from public.sessions where employee_id = v_id and v_id <> v_admin.id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- Absences
-- ---------------------------------------------------------------------

create function public.admin_set_absence(p_token text, p_employee_id uuid, p_date date,
                                         p_absent boolean, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  if p_employee_id is null or p_date is null then
    raise exception 'BAD_INPUT';
  end if;
  if not exists (select 1 from public.employees where id = p_employee_id) then
    raise exception 'NOT_FOUND';
  end if;
  if coalesce(p_absent, true) then
    insert into public.employee_absences (employee_id, date, note)
    values (p_employee_id, p_date, nullif(btrim(p_note), ''))
    on conflict (employee_id, date) do update set note = excluded.note;
  else
    delete from public.employee_absences where employee_id = p_employee_id and date = p_date;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Config: company_only flag (signature change → drop + create)
-- ---------------------------------------------------------------------

drop function public.admin_save_config(text, uuid, text, text, boolean);

create function public.admin_save_config(p_token text, p_id uuid, p_category text, p_value text,
                                         p_is_active boolean, p_company_only boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_id uuid;
begin
  if btrim(coalesce(p_value, '')) = '' then
    raise exception 'BAD_INPUT';
  end if;
  if exists (select 1 from public.config_options
             where category = p_category and value = btrim(p_value) and id is distinct from p_id) then
    raise exception 'VALUE_TAKEN';
  end if;
  if p_id is null then
    insert into public.config_options (category, value, is_active, company_only)
    values (p_category, btrim(p_value), coalesce(p_is_active, true), coalesce(p_company_only, false))
    returning id into v_id;
  else
    update public.config_options
       set value = btrim(p_value), is_active = coalesce(p_is_active, true),
           company_only = coalesce(p_company_only, false)
     where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'NOT_FOUND';
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- Read RPCs: expose absences and lead ids
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
    'lead_ids', coalesce((
      select jsonb_agg(id) from public.employees where is_lead_driver and is_active
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.admin_settings(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  perform app_private.sync_budget();
  return jsonb_build_object(
    'me', v_admin.id,
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

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

revoke execute on function
  public.admin_set_absence(text, uuid, date, boolean, text),
  public.admin_save_config(text, uuid, text, text, boolean, boolean)
from public;

grant execute on function
  public.admin_set_absence(text, uuid, date, boolean, text),
  public.admin_save_config(text, uuid, text, text, boolean, boolean)
to anon, authenticated;

commit;

-- =====================================================================
-- OPS-V2 — initial schema
-- Tables + RLS (deny-all) + SECURITY DEFINER RPCs + seed data.
-- Run once on a fresh Supabase project (SQL Editor → paste → Run).
--
-- Security model: the browser uses only the publishable (anon) key.
-- Every table has RLS enabled with NO policies, and anon/authenticated
-- have no table privileges. All access goes through the RPCs below,
-- which validate a session token issued by public.login().
-- =====================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

create schema if not exists app_private;
revoke all on schema app_private from public;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table public.employees (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (btrim(name) <> ''),
  pin_hash        text not null,
  role            text not null default 'operator' check (role in ('admin', 'operator')),
  is_lead_driver  boolean not null default false,
  is_active       boolean not null default true,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now(),
  check (not (role = 'admin' and is_lead_driver))
);
create unique index employees_name_uq on public.employees (lower(btrim(name)));

create table public.sessions (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.employees(id) on delete cascade,
  token_hash   text not null unique,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null
);
create index sessions_employee_idx on public.sessions (employee_id);

create table public.assets (
  id              text primary key check (id ~ '^[A-Za-z0-9_-]{1,20}$'),
  home_warehouse  text not null,
  is_active       boolean not null default true
);

create table public.config_options (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (category in (
               'exit_point', 'vehicle_type', 'outbound_route', 'factory_entry',
               'factory_exit', 'return_route', 'worker_position')),
  value      text not null check (btrim(value) <> ''),
  is_active  boolean not null default true,
  unique (category, value),
  check (category <> 'worker_position' or value in ('front', 'back', 'none'))
);

-- reset_month is stored as YYYYMM (e.g. 202610).
create table public.vehicle_budget (
  id                   uuid primary key default gen_random_uuid(),
  vehicle_type         text not null unique,
  max_per_month        int check (max_per_month is null or max_per_month >= 0),
  current_month_count  int not null default 0,
  reset_month          int not null default (to_char(now() at time zone 'Asia/Jerusalem', 'YYYYMM')::int)
);

create table public.trips (
  id                      uuid primary key default gen_random_uuid(),
  asset_id                text not null references public.assets(id),
  date                    date not null,
  trip_type               text not null check (trip_type in ('real', 'decoy')),
  departure_slot          text not null check (departure_slot in ('morning', 'noon')),
  vehicle_type            text not null,
  worker_position         text not null default 'none' check (worker_position in ('front', 'back', 'none')),
  exit_point              text not null,
  outbound_route          text not null,
  factory_entry           text not null,
  factory_exit            text not null,
  return_route            text not null,
  assigned_workers        uuid[] not null default '{}',
  status                  text not null default 'planned' check (status in ('planned', 'active', 'done', 'problem')),
  problem_note            text,
  actual_start_at         timestamptz,
  actual_done_at          timestamptz,
  decoy_trip_id           uuid references public.trips(id) on delete set null,
  created_at              timestamptz not null default now(),
  excluded_from_analysis  boolean not null default false
);
create index trips_asset_date_idx on public.trips (asset_id, date desc);
create index trips_date_idx on public.trips (date);
create index trips_workers_idx on public.trips using gin (assigned_workers);
-- One real trip per asset per day (makes week generation idempotent).
create unique index trips_one_real_per_day on public.trips (asset_id, date) where trip_type = 'real';

-- ---------------------------------------------------------------------
-- RLS: enabled, no policies → no direct access with the publishable key.
-- ---------------------------------------------------------------------

alter table public.employees      enable row level security;
alter table public.sessions       enable row level security;
alter table public.assets         enable row level security;
alter table public.config_options enable row level security;
alter table public.vehicle_budget enable row level security;
alter table public.trips          enable row level security;

revoke all on public.employees, public.sessions, public.assets,
              public.config_options, public.vehicle_budget, public.trips
  from anon, authenticated;

-- ---------------------------------------------------------------------
-- Private helpers (schema not exposed by the API, no grants)
-- ---------------------------------------------------------------------

create function app_private.today() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Jerusalem')::date
$$;

-- Monday of the Sun–Sat week containing p_d. Saturday maps to the next week.
create function app_private.week_monday(p_d date) returns date
language sql immutable as $$
  select p_d - extract(dow from p_d)::int + 1
         + case when extract(dow from p_d) = 6 then 7 else 0 end
$$;

create function app_private.hash_token(p_token text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

create function app_private.pick(p_arr text[]) returns text
language sql volatile as $$
  select p_arr[1 + floor(random() * cardinality(p_arr))::int]
$$;

create function app_private.options(p_category text) returns text[]
language sql stable as $$
  select coalesce(array_agg(value order by value), '{}')
  from public.config_options
  where category = p_category and is_active
$$;

create function app_private.is_valid_option(p_category text, p_value text) returns boolean
language sql stable as $$
  select exists (select 1 from public.config_options
                 where category = p_category and value = p_value and is_active)
$$;

create function app_private.slot_label(p_slot text) returns text
language sql immutable as $$
  select case p_slot when 'morning' then 'בוקר' when 'noon' then 'צהריים' else p_slot end
$$;

create function app_private.trip_label(p_asset text, p_slot text) returns text
language sql immutable as $$
  select 'משימה ' || p_asset || ' · ' || app_private.slot_label(p_slot)
$$;

-- Resolves a session token to its employee, sliding the idle timeout.
create function app_private.session(p_token text) returns public.employees
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees;
  v_sid uuid;
begin
  select s.id into v_sid
  from public.sessions s
  join public.employees e on e.id = s.employee_id
  where s.token_hash = app_private.hash_token(p_token)
    and s.expires_at > now()
    and e.is_active
    and (e.locked_until is null or e.locked_until <= now());
  if v_sid is null then
    raise exception 'SESSION_INVALID';
  end if;

  update public.sessions set expires_at = now() + interval '2 hours'
  where id = v_sid
  returning employee_id into v_emp.id;

  select * into v_emp from public.employees where id = v_emp.id;
  return v_emp;
end $$;

create function app_private.require_admin(p_token text) returns public.employees
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
begin
  if v_emp.role <> 'admin' then
    raise exception 'FORBIDDEN';
  end if;
  return v_emp;
end $$;

-- Verifies a PIN and maintains the lockout counter.
-- Returns 'ok' | 'bad' | 'locked'. Never raises, so counter updates are
-- committed even when the caller reports a failure.
create function app_private.check_pin(p_employee_id uuid, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees;
begin
  select * into v_emp from public.employees where id = p_employee_id for update;
  if not found then
    return 'bad';
  end if;
  if v_emp.locked_until is not null and v_emp.locked_until > now() then
    return 'locked';
  end if;

  if v_emp.pin_hash = crypt(coalesce(p_pin, ''), v_emp.pin_hash) then
    update public.employees set failed_attempts = 0, locked_until = null where id = v_emp.id;
    return 'ok';
  end if;

  if v_emp.failed_attempts + 1 >= 3 then
    update public.employees
       set failed_attempts = 0, locked_until = now() + interval '30 minutes'
     where id = v_emp.id;
    delete from public.sessions where employee_id = v_emp.id;
    return 'locked';
  end if;

  update public.employees set failed_attempts = failed_attempts + 1 where id = v_emp.id;
  return 'bad';
end $$;

create function app_private.stepup_error(p_result text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', false,
           'error', case p_result when 'locked' then 'LOCKED' else 'STEPUP_FAILED' end)
$$;

-- Usage of a vehicle type in the calendar month of p_day (all assets, real + decoy).
create function app_private.month_usage(p_vehicle text, p_day date) returns int
language sql stable as $$
  select count(*)::int from public.trips
  where vehicle_type = p_vehicle
    and date >= date_trunc('month', p_day)::date
    and date <  (date_trunc('month', p_day) + interval '1 month')::date
$$;

create function app_private.budget_exhausted(p_vehicle text, p_day date) returns boolean
language sql stable as $$
  select coalesce((
    select b.max_per_month is not null
       and app_private.month_usage(p_vehicle, p_day) >= b.max_per_month
    from public.vehicle_budget b where b.vehicle_type = p_vehicle
  ), false)
$$;

-- Keeps vehicle_budget.current_month_count in sync with the trips table
-- for the current month (trips are the source of truth).
create function app_private.sync_budget() returns void
language sql volatile as $$
  update public.vehicle_budget
     set current_month_count = app_private.month_usage(vehicle_type, app_private.today()),
         reset_month = to_char(app_private.today(), 'YYYYMM')::int
$$;

-- Anti-pattern score for a candidate real trip (0 = clean, higher = worse).
--  * +10 for each exact repeat of (vehicle, exit, outbound, factory_entry)
--    within the asset's last 10 real trips.
--  * +N when the vehicle would exceed 60% of the asset's trips on that
--    weekday (last 10 same-weekday trips, needs ≥ 4 samples incl. candidate).
create function app_private.pattern_score(
  p_asset text, p_day date, p_vehicle text, p_exit text, p_out text, p_fentry text
) returns int
language sql stable as $$
  with recent as (
    select vehicle_type, exit_point, outbound_route, factory_entry
    from public.trips
    where asset_id = p_asset and trip_type = 'real'
      and not excluded_from_analysis and date < p_day
    order by date desc, created_at desc
    limit 10
  ), same_dow as (
    select vehicle_type
    from public.trips
    where asset_id = p_asset and trip_type = 'real'
      and not excluded_from_analysis and date < p_day
      and extract(isodow from date) = extract(isodow from p_day)
    order by date desc
    limit 10
  ), s as (
    select count(*)::int as n,
           count(*) filter (where vehicle_type = p_vehicle)::int as same
    from same_dow
  )
  select
    (select count(*)::int * 10 from recent
      where vehicle_type = p_vehicle and exit_point = p_exit
        and outbound_route = p_out and factory_entry = p_fentry)
    +
    (select case
              when n + 1 >= 4 and (same + 1)::numeric / (n + 1) > 0.6
              then (same + 1) - floor(0.6 * (n + 1))::int
              else 0
            end
       from s)
$$;

create function app_private.trip_admin_json(p_trip public.trips) returns jsonb
language sql stable as $$
  select to_jsonb(p_trip) || jsonb_build_object(
    'label', app_private.trip_label(p_trip.asset_id, p_trip.departure_slot),
    'workers', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) order by e.name)
      from public.employees e where e.id = any(p_trip.assigned_workers)
    ), '[]'::jsonb)
  )
$$;

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Auth RPCs
-- ---------------------------------------------------------------------

create function public.login(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees;
  v_result text;
  v_token text;
begin
  select * into v_emp from public.employees
  where lower(btrim(name)) = lower(btrim(coalesce(p_name, ''))) and is_active;

  if not found then
    perform crypt('timing-equalizer', gen_salt('bf', 10));
    return jsonb_build_object('ok', false, 'error', 'INVALID_CREDENTIALS');
  end if;

  v_result := app_private.check_pin(v_emp.id, p_pin);
  if v_result = 'locked' then
    return jsonb_build_object('ok', false, 'error', 'LOCKED');
  elsif v_result <> 'ok' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_CREDENTIALS');
  end if;

  delete from public.sessions where expires_at < now();

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.sessions (employee_id, token_hash, expires_at)
  values (v_emp.id, app_private.hash_token(v_token), now() + interval '2 hours');

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'employee', jsonb_build_object('id', v_emp.id, 'name', v_emp.name, 'role', v_emp.role,
                                   'is_lead_driver', v_emp.is_lead_driver)
  );
end $$;

create function public.logout(p_token text) returns jsonb
language sql security definer set search_path = public, extensions as $$
  delete from public.sessions where token_hash = app_private.hash_token(p_token);
  select jsonb_build_object('ok', true);
$$;

create function public.me(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
begin
  return jsonb_build_object('id', v_emp.id, 'name', v_emp.name, 'role', v_emp.role,
                            'is_lead_driver', v_emp.is_lead_driver);
end $$;

-- ---------------------------------------------------------------------
-- Worker RPCs — only own trips, only today's details, never trip_type.
-- ---------------------------------------------------------------------

create function public.worker_today(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id,
             'label', app_private.trip_label(t.asset_id, t.departure_slot),
             'status', t.status,
             'problem_note', t.problem_note)
           order by t.departure_slot, t.asset_id)
    from public.trips t
    where t.date = app_private.today() and v_emp.id = any(t.assigned_workers)
  ), '[]'::jsonb);
end $$;

create function public.worker_trip_detail(p_token text, p_trip_id uuid) returns jsonb
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
    'departure_slot', v_trip.departure_slot,
    'vehicle_type', v_trip.vehicle_type,
    'worker_position', v_trip.worker_position,
    'exit_point', v_trip.exit_point,
    'outbound_route', v_trip.outbound_route,
    'factory_entry', v_trip.factory_entry,
    'factory_exit', v_trip.factory_exit,
    'return_route', v_trip.return_route,
    'status', v_trip.status,
    'problem_note', v_trip.problem_note,
    'actual_start_at', v_trip.actual_start_at,
    'actual_done_at', v_trip.actual_done_at
  );
end $$;

-- p_action: 'start' | 'done' | 'problem'
create function public.worker_set_status(p_token text, p_trip_id uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_trip public.trips;
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
    if btrim(coalesce(p_note, '')) = '' then raise exception 'NOTE_REQUIRED'; end if;
    update public.trips set status = 'problem', problem_note = left(btrim(p_note), 1000)
    where id = v_trip.id;
  else
    raise exception 'BAD_INPUT';
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- Mon–Fri of the current week: has-task + labels only.
create function public.worker_week(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_monday date := app_private.week_monday(app_private.today());
begin
  return (
    select jsonb_agg(jsonb_build_object(
             'date', d::date,
             'is_today', d::date = app_private.today(),
             'labels', coalesce((
               select jsonb_agg(app_private.trip_label(t.asset_id, t.departure_slot)
                                order by t.departure_slot, t.asset_id)
               from public.trips t
               where t.date = d::date and v_emp.id = any(t.assigned_workers)
             ), '[]'::jsonb))
           order by d)
    from generate_series(v_monday, v_monday + 4, interval '1 day') d
  );
end $$;

-- ---------------------------------------------------------------------
-- Admin RPCs — trips
-- ---------------------------------------------------------------------

create function public.admin_week(p_token text, p_date date) returns jsonb
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
    )
  );
end $$;

create function public.admin_generate_week(p_token text, p_pin text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
  v_monday date;
  v_day date;
  v_asset record;
  v_vehicles text[]; v_exits text[]; v_outs text[]; v_fentries text[]; v_fexits text[];
  v_returns text[]; v_positions text[];
  v_lead uuid;
  v_others uuid[];
  v_allowed text[];
  v_score int; v_best int;
  c_vehicle text; c_exit text; c_out text; c_fentry text;
  b_vehicle text; b_exit text; b_out text; b_fentry text;
  v_slot text; v_position text; v_workers uuid[];
  v_recent_decoys int;
  v_make_decoy boolean;
  d_exits text[]; d_outs text[]; d_fentries text[];
  v_real_id uuid; v_decoy_id uuid;
  v_created int := 0; v_decoys int := 0; v_fallbacks int := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  v_check := app_private.check_pin(v_admin.id, p_pin);
  if v_check <> 'ok' then
    return app_private.stepup_error(v_check);
  end if;
  if p_week_start is null then
    raise exception 'BAD_INPUT';
  end if;

  v_monday    := app_private.week_monday(p_week_start);
  v_vehicles  := app_private.options('vehicle_type');
  v_exits     := app_private.options('exit_point');
  v_outs      := app_private.options('outbound_route');
  v_fentries  := app_private.options('factory_entry');
  v_fexits    := app_private.options('factory_exit');
  v_returns   := app_private.options('return_route');
  v_positions := array(select unnest(app_private.options('worker_position'))
                       intersect select unnest(array['front', 'back']));
  if cardinality(v_positions) = 0 then
    v_positions := array['front', 'back'];
  end if;

  if cardinality(v_vehicles) = 0 then raise exception 'CONFIG_MISSING:vehicle_type'; end if;
  if cardinality(v_exits)    = 0 then raise exception 'CONFIG_MISSING:exit_point'; end if;
  if cardinality(v_outs)     = 0 then raise exception 'CONFIG_MISSING:outbound_route'; end if;
  if cardinality(v_fentries) = 0 then raise exception 'CONFIG_MISSING:factory_entry'; end if;
  if cardinality(v_fexits)   = 0 then raise exception 'CONFIG_MISSING:factory_exit'; end if;
  if cardinality(v_returns)  = 0 then raise exception 'CONFIG_MISSING:return_route'; end if;

  select id into v_lead from public.employees
  where role = 'operator' and is_active and is_lead_driver
  order by random() limit 1;
  v_others := array(select id from public.employees
                    where role = 'operator' and is_active and not is_lead_driver);

  for i in 0..4 loop
    v_day := v_monday + i;

    for v_asset in select id from public.assets where is_active order by id loop
      if exists (select 1 from public.trips
                 where asset_id = v_asset.id and date = v_day and trip_type = 'real') then
        v_skipped := v_skipped || jsonb_build_object('asset', v_asset.id, 'date', v_day, 'reason', 'EXISTS');
        continue;
      end if;

      -- Step 2: vehicles still within monthly budget and staffable.
      -- company needs the lead driver; other vehicles need a non-lead operator.
      v_allowed := array(
        select v from unnest(v_vehicles) v
        where (v <> 'company' or v_lead is not null)
          and (v = 'company' or cardinality(v_others) > 0)
          and not app_private.budget_exhausted(v, v_day));
      if cardinality(v_allowed) = 0 then
        v_skipped := v_skipped || jsonb_build_object('asset', v_asset.id, 'date', v_day, 'reason', 'NO_VEHICLE');
        continue;
      end if;

      -- Steps 3–4: draw, score against history, retry up to 10 times, keep the best.
      v_best := null;
      for v_try in 1..10 loop
        c_vehicle := app_private.pick(v_allowed);
        c_exit    := app_private.pick(v_exits);
        c_out     := app_private.pick(v_outs);
        c_fentry  := app_private.pick(v_fentries);
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

      v_slot := app_private.pick(array['morning', 'noon']);

      if b_vehicle = 'company' then
        v_position := app_private.pick(v_positions);
        v_workers := array[v_lead]
          || array(select w from unnest(v_others) w order by random() limit 1);
      else
        v_position := 'none';
        v_workers := array(select w from unnest(v_others) w order by random()
                           limit 1 + floor(random() * 2)::int);
      end if;

      -- Step 1 (needs the drawn vehicle): decoy only for non-company trips,
      -- 50% chance, and at most 3 decoys in the asset's last 10 real trips.
      v_make_decoy := false;
      if b_vehicle <> 'company' and v_lead is not null and random() < 0.5
         and not app_private.budget_exhausted('company', v_day) then
        select count(*) filter (where decoy_trip_id is not null) into v_recent_decoys
        from (select decoy_trip_id from public.trips
              where asset_id = v_asset.id and trip_type = 'real'
                and not excluded_from_analysis and date < v_day
              order by date desc, created_at desc
              limit 10) r;
        if v_recent_decoys < 3 then
          d_exits    := array_remove(v_exits, b_exit);
          d_outs     := array_remove(v_outs, b_out);
          d_fentries := array_remove(v_fentries, b_fentry);
          v_make_decoy := cardinality(d_exits) > 0 and cardinality(d_outs) > 0
                          and cardinality(d_fentries) > 0;
        end if;
      end if;

      insert into public.trips (asset_id, date, trip_type, departure_slot, vehicle_type,
        worker_position, exit_point, outbound_route, factory_entry, factory_exit,
        return_route, assigned_workers)
      values (v_asset.id, v_day, 'real', v_slot, b_vehicle, v_position, b_exit, b_out,
        b_fentry, app_private.pick(v_fexits), app_private.pick(v_returns), v_workers)
      returning id into v_real_id;
      v_created := v_created + 1;

      -- Step 5: decoy — company vehicle, lead driver, different exit/route/entry,
      -- opposite time slot, cross-linked to the real trip.
      if v_make_decoy then
        insert into public.trips (asset_id, date, trip_type, departure_slot, vehicle_type,
          worker_position, exit_point, outbound_route, factory_entry, factory_exit,
          return_route, assigned_workers, decoy_trip_id)
        values (v_asset.id, v_day, 'decoy',
          case v_slot when 'morning' then 'noon' else 'morning' end,
          'company', 'none',
          app_private.pick(d_exits), app_private.pick(d_outs), app_private.pick(d_fentries),
          app_private.pick(v_fexits), app_private.pick(v_returns),
          array[v_lead], v_real_id)
        returning id into v_decoy_id;
        update public.trips set decoy_trip_id = v_decoy_id where id = v_real_id;
        v_decoys := v_decoys + 1;
      end if;
    end loop;
  end loop;

  -- Step 6: budget counters.
  perform app_private.sync_budget();

  return jsonb_build_object('ok', true, 'week_start', v_monday, 'created', v_created,
                            'decoys', v_decoys, 'fallbacks', v_fallbacks, 'skipped', v_skipped);
end $$;

-- Edits a planned trip. Non-planned trips accept only excluded_from_analysis.
create function public.admin_update_trip(p_token text, p_trip_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_trip public.trips;
  v_key text;
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
  if v_trip.vehicle_type <> 'company' then
    update public.trips set worker_position = 'none' where id = v_trip.id
    returning * into v_trip;
  elsif v_trip.worker_position not in ('front', 'back') then
    raise exception 'POSITION_REQUIRED';
  end if;
  if cardinality(v_trip.assigned_workers) = 0 then
    raise exception 'WORKERS_REQUIRED';
  end if;
  if exists (select 1 from unnest(v_trip.assigned_workers) w
             left join public.employees e on e.id = w
             where e.id is null or not e.is_active or e.role <> 'operator') then
    raise exception 'BAD_VALUE:assigned_workers';
  end if;
  if v_trip.vehicle_type <> 'company' and exists (
       select 1 from public.employees
       where id = any(v_trip.assigned_workers) and is_lead_driver) then
    raise exception 'LEAD_COMPANY_ONLY';
  end if;
  if p_data ? 'vehicle_type' and app_private.month_usage(v_trip.vehicle_type, v_trip.date) > coalesce(
       (select max_per_month from public.vehicle_budget where vehicle_type = v_trip.vehicle_type),
       2147483647) then
    raise exception 'BUDGET_EXHAUSTED';
  end if;

  perform app_private.sync_budget();
  return jsonb_build_object('ok', true, 'trip', app_private.trip_admin_json(v_trip));
end $$;

-- Deletes a planned trip. Deleting a real trip also deletes its planned decoy.
create function public.admin_delete_trip(p_token text, p_pin text, p_trip_id uuid) returns jsonb
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

  if v_trip.trip_type = 'real' and v_trip.decoy_trip_id is not null then
    delete from public.trips where id = v_trip.decoy_trip_id and status = 'planned';
  end if;
  delete from public.trips where id = v_trip.id;

  perform app_private.sync_budget();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Admin RPCs — settings
-- ---------------------------------------------------------------------

create function public.admin_settings(p_token text) returns jsonb
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
      select jsonb_agg(to_jsonb(b) order by b.vehicle_type) from public.vehicle_budget b), '[]'::jsonb)
  );
end $$;

-- p_id null → create (p_pin required). p_pin null/empty on update → keep PIN.
create function public.admin_save_employee(
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
  if v_pin is not null and length(v_pin) < 6 then
    raise exception 'PIN_TOO_SHORT';
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
    -- Deactivation or PIN change ends the employee's other sessions.
    if v_pin is not null or not coalesce(p_is_active, true) then
      delete from public.sessions where employee_id = v_id and v_id <> v_admin.id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create function public.admin_unlock_account(p_token text, p_pin text, p_employee_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
  v_check text;
begin
  v_check := app_private.check_pin(v_admin.id, p_pin);
  if v_check <> 'ok' then
    return app_private.stepup_error(v_check);
  end if;
  update public.employees set failed_attempts = 0, locked_until = null where id = p_employee_id;
  if not found then
    raise exception 'NOT_FOUND';
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_save_asset(p_token text, p_id text, p_home_warehouse text, p_is_active boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  if coalesce(btrim(p_id), '') !~ '^[A-Za-z0-9_-]{1,20}$' or btrim(coalesce(p_home_warehouse, '')) = '' then
    raise exception 'BAD_INPUT';
  end if;
  insert into public.assets (id, home_warehouse, is_active)
  values (btrim(p_id), btrim(p_home_warehouse), coalesce(p_is_active, true))
  on conflict (id) do update
    set home_warehouse = excluded.home_warehouse, is_active = excluded.is_active;
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_save_config(p_token text, p_id uuid, p_category text, p_value text, p_is_active boolean)
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
    insert into public.config_options (category, value, is_active)
    values (p_category, btrim(p_value), coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.config_options
       set value = btrim(p_value), is_active = coalesce(p_is_active, true)
     where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'NOT_FOUND';
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- p_max null → unlimited.
create function public.admin_save_budget(p_token text, p_vehicle_type text, p_max int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_admin public.employees := app_private.require_admin(p_token);
begin
  if btrim(coalesce(p_vehicle_type, '')) = '' or (p_max is not null and p_max < 0) then
    raise exception 'BAD_INPUT';
  end if;
  insert into public.vehicle_budget (vehicle_type, max_per_month)
  values (btrim(p_vehicle_type), p_max)
  on conflict (vehicle_type) do update set max_per_month = excluded.max_per_month;
  perform app_private.sync_budget();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Grants: only the API functions are callable by the publishable key.
-- ---------------------------------------------------------------------

revoke execute on function
  public.login(text, text),
  public.logout(text),
  public.me(text),
  public.worker_today(text),
  public.worker_trip_detail(text, uuid),
  public.worker_set_status(text, uuid, text, text),
  public.worker_week(text),
  public.admin_week(text, date),
  public.admin_generate_week(text, text, date),
  public.admin_update_trip(text, uuid, jsonb),
  public.admin_delete_trip(text, text, uuid),
  public.admin_settings(text),
  public.admin_save_employee(text, uuid, text, text, boolean, boolean, text),
  public.admin_unlock_account(text, text, uuid),
  public.admin_save_asset(text, text, text, boolean),
  public.admin_save_config(text, uuid, text, text, boolean),
  public.admin_save_budget(text, text, int)
from public;

grant execute on function
  public.login(text, text),
  public.logout(text),
  public.me(text),
  public.worker_today(text),
  public.worker_trip_detail(text, uuid),
  public.worker_set_status(text, uuid, text, text),
  public.worker_week(text),
  public.admin_week(text, date),
  public.admin_generate_week(text, text, date),
  public.admin_update_trip(text, uuid, jsonb),
  public.admin_delete_trip(text, text, uuid),
  public.admin_settings(text),
  public.admin_save_employee(text, uuid, text, text, boolean, boolean, text),
  public.admin_unlock_account(text, text, uuid),
  public.admin_save_asset(text, text, text, boolean),
  public.admin_save_config(text, uuid, text, text, boolean),
  public.admin_save_budget(text, text, int)
to anon, authenticated;

-- ---------------------------------------------------------------------
-- Seed data (temporary PINs — change them in Settings after first login)
-- ---------------------------------------------------------------------

insert into public.employees (name, pin_hash, role, is_lead_driver) values
  ('מנהל',     extensions.crypt('Admin1!', extensions.gen_salt('bf', 10)), 'admin',    false),
  ('נהג ראשי', extensions.crypt('Driver1!', extensions.gen_salt('bf', 10)), 'operator', true),
  ('עובד 1',   extensions.crypt('Worker1!', extensions.gen_salt('bf', 10)), 'operator', false),
  ('עובד 2',   extensions.crypt('Worker2!', extensions.gen_salt('bf', 10)), 'operator', false);

insert into public.assets (id, home_warehouse) values ('A1', 'מחסן ראשי');

insert into public.config_options (category, value)
select c, v from (values
  ('exit_point', 'חניה מקורה'),
  ('exit_point', 'כניסה ראשית'),
  ('vehicle_type', 'company'),
  ('vehicle_type', 'rental'),
  ('vehicle_type', 'delivery'),
  ('outbound_route', 'ימין בצומת'),
  ('outbound_route', 'שמאל בצומת'),
  ('outbound_route', 'קיצור לפני הצומת'),
  ('return_route', 'ציר ראשי'),
  ('return_route', 'ציר אחורי'),
  ('worker_position', 'front'),
  ('worker_position', 'back')
) s(c, v)
union all
select cat, v from unnest(array['factory_entry', 'factory_exit']) cat
cross join unnest(array['כניסה ראשית', 'כניסה צידית', 'חניון תת-קרקעי מכניסה ראשית',
                        'חניון תת-קרקעי מרחוב אחורי', 'סימטה']) v;

insert into public.vehicle_budget (vehicle_type, max_per_month) values ('delivery', 6);

commit;

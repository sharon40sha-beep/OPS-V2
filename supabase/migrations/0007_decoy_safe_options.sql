-- =====================================================================
-- OPS-V2 — decoy-safe options
--  Whenever a leg runs with a decoy, both vehicles (real and decoy) use only
--  options flagged decoy_ok:
--    * warehouse exit: covered parking only
--    * factory entry: underground parking (from main / back street) or the
--      alley — not the side or main entrance
--    * factory exit: from the underground parking (to the main or the back
--      street) — a split between the two vehicles is fine
--  The flag is editable in Settings; a trigger enforces it on every write.
-- Run after 0001–0006.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

-- ---------------------------------------------------------------------
-- decoy_ok flag on options
-- ---------------------------------------------------------------------

alter table public.config_options add column decoy_ok boolean not null default true;

update public.config_options set decoy_ok = false
 where (category, value) in (
   ('exit_point', 'כניסה ראשית'),
   ('factory_entry', 'כניסה ראשית'),
   ('factory_entry', 'כניסה צידית'),
   ('factory_exit', 'כניסה ראשית'),
   ('factory_exit', 'כניסה צידית'),
   ('factory_exit', 'סימטה'));

-- Active values usable with the vehicle class, optionally only decoy-safe ones.
create function app_private.options_for(p_category text, p_company boolean, p_decoy boolean) returns text[]
language sql stable as $$
  select coalesce(array_agg(value order by value), '{}')
  from public.config_options
  where category = p_category and is_active
    and (p_company or not company_only)
    and (not p_decoy or decoy_ok)
$$;

-- Legs that run with a decoy (the decoy itself or the real leg linked to one)
-- may only use decoy-safe options.
create function app_private.enforce_decoy_options() returns trigger
language plpgsql as $$
declare
  v_bad text;
begin
  if new.trip_type <> 'decoy' and new.decoy_trip_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and (new.exit_point, new.outbound_route, new.factory_entry, new.factory_exit,
          new.return_route, new.decoy_trip_id, new.trip_type)
         is not distinct from
         (old.exit_point, old.outbound_route, old.factory_entry, old.factory_exit,
          old.return_route, old.decoy_trip_id, old.trip_type) then
    return new;
  end if;
  select c.category into v_bad
  from public.config_options c
  where not c.decoy_ok and (c.category, c.value) in (
    ('exit_point', new.exit_point), ('outbound_route', new.outbound_route),
    ('factory_entry', new.factory_entry), ('factory_exit', new.factory_exit),
    ('return_route', new.return_route))
  limit 1;
  if v_bad is not null then
    raise exception 'DECOY_UNSAFE_OPTION:%', v_bad;
  end if;
  return new;
end $$;

create trigger trips_decoy_options
  before insert or update on public.trips
  for each row execute function app_private.enforce_decoy_options();

revoke all on all functions in schema app_private from public;

-- ---------------------------------------------------------------------
-- Week generation (replaces 0006 version)
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
  -- decoy-safe subsets (legs that run with a decoy): _d = company, _nd = other vehicles
  v_exits_d text[]; v_exits_nd text[]; v_outs_d text[]; v_outs_nd text[];
  v_fent_d text[]; v_fent_nd text[]; v_fexit_d text[]; v_fexit_nd text[];
  v_ret_d text[]; v_ret_nd text[];
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
  v_exits_d  := app_private.options_for('exit_point', true, true);
  v_exits_nd := app_private.options_for('exit_point', false, true);
  v_outs_d   := app_private.options_for('outbound_route', true, true);
  v_outs_nd  := app_private.options_for('outbound_route', false, true);
  v_fent_d   := app_private.options_for('factory_entry', true, true);
  v_fent_nd  := app_private.options_for('factory_entry', false, true);
  v_fexit_d  := app_private.options_for('factory_exit', true, true);
  v_fexit_nd := app_private.options_for('factory_exit', false, true);
  v_ret_d    := app_private.options_for('return_route', true, true);
  v_ret_nd   := app_private.options_for('return_route', false, true);
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
        -- the last 10 legs of this direction, decoy-safe options for both vehicles,
        -- with alternatives so the decoy differs from the real leg)
        v_decoy_ok := false;
        if v_lead_free and not app_private.vehicle_blocked('company', v_day)
           and not app_private.budget_exhausted('company', v_day)
           and (case v_leg
                  when 'outbound' then cardinality(v_exits_d) > 0 and cardinality(v_outs_d) > 1
                                   and cardinality(v_fent_d) > 1 and cardinality(v_exits_nd) > 0
                                   and cardinality(v_outs_nd) > 0 and cardinality(v_fent_nd) > 0
                  else cardinality(v_fexit_d) > 1 and cardinality(v_ret_d) > 1
                   and cardinality(v_fexit_nd) > 0 and cardinality(v_ret_nd) > 0 end) then
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

        -- Draw 10 candidates, keep the lowest score. A non-company leg with a decoy
        -- draws only decoy-safe options (covered parking in and out).
        v_best := null;
        for v_try in 1..10 loop
          c_vehicle := app_private.pick(v_allowed);
          v_is_company := c_vehicle = 'company';
          if v_leg = 'outbound' then
            c_a := app_private.pick(case when v_is_company then v_exits_c when v_must_decoy then v_exits_nd else v_exits_n end);
            c_b := app_private.pick(case when v_is_company then v_outs_c when v_must_decoy then v_outs_nd else v_outs_n end);
            c_c := app_private.pick(case when v_is_company then v_fent_c when v_must_decoy then v_fent_nd else v_fent_n end);
          else
            c_a := app_private.pick(case when v_is_company then v_fexit_c when v_must_decoy then v_fexit_nd else v_fexit_n end);
            c_b := app_private.pick(case when v_is_company then v_ret_c when v_must_decoy then v_ret_nd else v_ret_n end);
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

        -- Decoy at the same time: lead alone in the company vehicle, decoy-safe
        -- options, different route and entry/exit than the real leg.
        if not v_is_company and v_must_decoy then
          insert into public.trips (asset_id, date, leg, trip_type, departure_slot, vehicle_type,
            worker_position, exit_point, outbound_route, factory_entry, factory_exit, return_route,
            assigned_workers, decoy_trip_id)
          values (v_asset.id, v_day, v_leg, 'decoy', v_slot, 'company', 'none',
            case v_leg when 'outbound' then app_private.pick(app_private.prefer_other(v_exits_d, b_a)) end,
            case v_leg when 'outbound' then app_private.pick(array_remove(v_outs_d, b_b)) end,
            case v_leg when 'outbound' then app_private.pick(array_remove(v_fent_d, b_c)) end,
            case v_leg when 'return' then app_private.pick(array_remove(v_fexit_d, b_a)) end,
            case v_leg when 'return' then app_private.pick(array_remove(v_ret_d, b_b)) end,
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
-- Config: decoy_ok flag (signature change → drop + create)
-- ---------------------------------------------------------------------

drop function public.admin_save_config(text, uuid, text, text, boolean, boolean);

create function public.admin_save_config(p_token text, p_id uuid, p_category text, p_value text,
                                         p_is_active boolean, p_company_only boolean default false,
                                         p_decoy_ok boolean default true)
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
    insert into public.config_options (category, value, is_active, company_only, decoy_ok)
    values (p_category, btrim(p_value), coalesce(p_is_active, true), coalesce(p_company_only, false),
            coalesce(p_decoy_ok, true))
    returning id into v_id;
  else
    update public.config_options
       set value = btrim(p_value), is_active = coalesce(p_is_active, true),
           company_only = coalesce(p_company_only, false), decoy_ok = coalesce(p_decoy_ok, true)
     where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'NOT_FOUND';
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

revoke execute on function public.admin_save_config(text, uuid, text, text, boolean, boolean, boolean) from public;
grant execute on function public.admin_save_config(text, uuid, text, text, boolean, boolean, boolean) to anon, authenticated;

commit;

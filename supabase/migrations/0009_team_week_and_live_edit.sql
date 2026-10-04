-- =====================================================================
-- OPS-V2 — team week view + editing of legs not yet done
--  * team_week: every signed-in employee sees the whole team's schedule
--    for the current or next week — day, leg, asset, vehicle, crew,
--    custodian, status. Routes / entry / exit points are NOT included
--    (admins see them in admin_week; workers only for their own leg today).
--  * admin_update_trip: admins may edit any leg that is not done
--    (planned, active or problem), not only planned ones.
-- Run after 0001–0008. Safe after the pilot start (no data changes).
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

create function public.team_week(p_token text, p_week_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp public.employees := app_private.session(p_token);
  v_monday date;
begin
  -- Non-admins may look at this week and next week only.
  if v_emp.role <> 'admin' and coalesce(p_week_offset, 0) not in (0, 1) then
    raise exception 'FORBIDDEN';
  end if;
  v_monday := app_private.week_monday(app_private.today()) + 7 * coalesce(p_week_offset, 0);

  return jsonb_build_object(
    'week_start', v_monday,
    'today', app_private.today(),
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id,
               'date', t.date,
               'leg', t.leg,
               'asset_id', t.asset_id,
               'vehicle_type', t.vehicle_type,
               'status', t.status,
               'is_mine', v_emp.id = any(t.assigned_workers),
               'crew', coalesce((
                 select jsonb_agg(jsonb_build_object('name', e.name,
                                                     'is_custodian', e.id = t.custodian_id)
                                  order by (e.id = t.custodian_id) desc, e.name)
                 from public.employees e where e.id = any(t.assigned_workers)), '[]'::jsonb))
             order by t.date, t.departure_slot, t.asset_id, t.vehicle_type)
      from public.trips t
      where t.date between v_monday and v_monday + 4
    ), '[]'::jsonb)
  );
end $$;

revoke execute on function public.team_week(text, int) from public;
grant execute on function public.team_week(text, int) to anon, authenticated;

-- Allow admins to edit legs that are planned, active or flagged with a problem.
do $$
declare
  v_def text := pg_get_functiondef('public.admin_update_trip(text, uuid, jsonb)'::regprocedure);
begin
  if position('v_trip.status <> ''planned''' in v_def) = 0
     or position('v_sibling.status <> ''planned''' in v_def) = 0
     or position('if v_trip.status = ''planned'' then' in v_def) = 0 then
    raise exception 'admin_update_trip: expected status checks not found — run 0006 first';
  end if;
  v_def := replace(v_def, 'v_trip.status <> ''planned''', 'v_trip.status = ''done''');
  v_def := replace(v_def, 'v_sibling.status <> ''planned''', 'v_sibling.status = ''done''');
  v_def := replace(v_def, 'if v_trip.status = ''planned'' then', 'if v_trip.status <> ''done'' then');
  execute v_def;
end $$;

commit;

-- =====================================================================
-- OPS-V2 — full team visibility (owner's decision: workers are trusted)
--  team_week: every signed-in employee sees all legs of the team for this
--  week and next week (admins: any week) with full details — routes,
--  entries/exits, crew, custodian, decoys, status, notes. Read-only:
--  changes stay in admin RPCs; status buttons stay in worker_set_status
--  (own leg, today). Also returns the caller's "updated" days.
-- Run after 0001–0010. No data changes.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

create or replace function public.team_week(p_token text, p_week_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
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
                       order by t.date, t.departure_slot, t.asset_id, t.trip_type)
      from public.trips t
      where t.date between v_monday and v_monday + 4
    ), '[]'::jsonb)
  );
end $$;

commit;

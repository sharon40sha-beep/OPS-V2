-- Supabase runs API requests with pg-safeupdate, which rejects UPDATE/DELETE
-- statements without a WHERE clause ("UPDATE requires a WHERE clause").
-- sync_budget() intentionally updates every row, so it needs an explicit WHERE.
create or replace function app_private.sync_budget() returns void
language sql volatile as $$
  update public.vehicle_budget
     set current_month_count = app_private.month_usage(vehicle_type, app_private.today()),
         reset_month = to_char(app_private.today(), 'YYYYMM')::int
   where true
$$;
revoke all on function app_private.sync_budget() from public;

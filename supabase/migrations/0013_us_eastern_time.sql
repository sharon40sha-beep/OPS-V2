-- =====================================================================
-- OPS-V2 — operations run on US Eastern time
--  * "Today" (worker status buttons, week boundaries, budget month) is the
--    date in America/New_York instead of Asia/Jerusalem. DST is handled by
--    Postgres.
--  * Stored timestamps are UTC and unchanged; only the calendar day changes.
-- Run after 0001–0012. No data is changed.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

create or replace function app_private.today() returns date
language sql stable as $$
  select (now() at time zone 'America/New_York')::date
$$;

alter table public.vehicle_budget
  alter column reset_month set default (to_char(now() at time zone 'America/New_York', 'YYYYMM')::int);

revoke all on all functions in schema app_private from public;

select app_private.today() as today_us_eastern;

commit;

-- =====================================================================
-- OPS-V2 — worker position "escort" (ברכב אחר / מלווה)
--  A briefing value only: drawn like front/back for the custodian on
--  company-vehicle legs. It does not change who travels with the product.
-- Run after 0001–0007.
-- =====================================================================

begin;

select app_private.reset_data_if_pre_pilot();

alter table public.config_options drop constraint config_options_check;
alter table public.config_options add constraint config_options_worker_position_check
  check (category <> 'worker_position' or value in ('front', 'back', 'escort', 'none'));

alter table public.trips drop constraint trips_worker_position_check;
alter table public.trips add constraint trips_worker_position_check
  check (worker_position in ('front', 'back', 'escort', 'none'));

insert into public.config_options (category, value)
values ('worker_position', 'escort')
on conflict (category, value) do nothing;

-- Accept 'escort' wherever front/back are accepted (generation + trip edit).
do $$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.admin_generate_week(text, text, date)'::regprocedure);
  if position('intersect select unnest(array[''front'', ''back'']))' in v_def) = 0 then
    raise exception 'admin_generate_week: expected position list not found — run 0007 first';
  end if;
  execute replace(v_def,
    'intersect select unnest(array[''front'', ''back'']))',
    'intersect select unnest(array[''front'', ''back'', ''escort'']))');

  v_def := pg_get_functiondef('public.admin_update_trip(text, uuid, jsonb)'::regprocedure);
  if position('worker_position not in (''front'', ''back'')' in v_def) = 0 then
    raise exception 'admin_update_trip: expected position check not found — run 0006 first';
  end if;
  execute replace(v_def,
    'worker_position not in (''front'', ''back'')',
    'worker_position not in (''front'', ''back'', ''escort'')');
end $$;

commit;

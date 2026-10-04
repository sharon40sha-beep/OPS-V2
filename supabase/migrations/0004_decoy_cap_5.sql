-- Raise the decoy cap from 3 to 5 per the asset's last 10 real trips.
-- With the lead driver scheduled every weekday, the cap bounds how often a
-- non-company vehicle can carry the product; at 3/10 the company vehicle
-- carried it ~72% of days and the 60%-per-weekday rule could rarely be met.
-- Patches only that comparison in admin_generate_week (from 0003).
do $$
declare
  v_def text := pg_get_functiondef('public.admin_generate_week(text, text, date)'::regprocedure);
begin
  if position('v_decoy_ok := v_recent_decoys < 3;' in v_def) = 0 then
    raise exception 'admin_generate_week does not contain the expected decoy cap — run 0003 first';
  end if;
  execute replace(replace(v_def,
    'v_decoy_ok := v_recent_decoys < 3;', 'v_decoy_ok := v_recent_decoys < 5;'),
    '≤3 decoys in last 10', '≤5 decoys in last 10');
end $$;

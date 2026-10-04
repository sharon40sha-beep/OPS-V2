export type Role = 'admin' | 'operator';
export type TripStatus = 'planned' | 'active' | 'done' | 'problem';
export type Slot = 'morning' | 'noon';
export type Leg = 'outbound' | 'return';
export type Position = 'front' | 'back' | 'escort' | 'none';
export type Category =
  | 'exit_point'
  | 'vehicle_type'
  | 'outbound_route'
  | 'factory_entry'
  | 'factory_exit'
  | 'return_route'
  | 'worker_position';

export interface Me {
  id: string;
  name: string;
  role: Role;
  is_lead_driver: boolean;
}

export interface WorkerTask {
  id: string;
  label: string;
  status: TripStatus;
  problem_note: string | null;
}

/** Outbound legs carry exit/outbound/entry; return legs carry factory_exit/return_route. */
export interface TripParams {
  leg: Leg;
  departure_slot: Slot;
  vehicle_type: string;
  worker_position: Position;
  exit_point: string | null;
  outbound_route: string | null;
  factory_entry: string | null;
  factory_exit: string | null;
  return_route: string | null;
}

export interface WorkerTripDetail extends TripParams {
  id: string;
  label: string;
  asset_id: string;
  status: TripStatus;
  problem_note: string | null;
  actual_start_at: string | null;
  actual_done_at: string | null;
  is_custodian: boolean;
  date: string;
  is_today: boolean;
  partners: { name: string; is_custodian: boolean }[];
}

export interface WorkerWeekDay {
  date: string;
  is_today: boolean;
  labels: string[];
}

export interface AdminTrip extends TripParams {
  id: string;
  label: string;
  asset_id: string;
  date: string;
  trip_type: 'real' | 'decoy';
  assigned_workers: string[];
  workers: { id: string; name: string }[];
  custodian_id: string | null;
  custodian_name: string | null;
  status: TripStatus;
  problem_note: string | null;
  actual_start_at: string | null;
  actual_done_at: string | null;
  decoy_trip_id: string | null;
  excluded_from_analysis: boolean;
}

export interface Absence {
  employee_id: string;
  date: string;
  name?: string;
  note?: string | null;
}

export interface AdminWeek {
  week_start: string;
  today: string;
  trips: AdminTrip[];
  stats: { total: number; done: number; open: number; problem: number };
  absences: Absence[];
  vehicle_blocks: { vehicle_type: string; date: string }[];
  lead_ids: string[];
}

export interface Count {
  value: string;
  count: number;
}

export interface LegReport {
  n: number;
  decoy_rate: number | null;
  vehicle: Count[];
  guess_blind: number | null;
  guess_by_weekday: number | null;
  by_weekday: { dow: number; n: number; top: string; top_share: number }[];
  params: { a: Count[]; b: Count[]; c: Count[] };
}

export interface PatternReport {
  from: string | null;
  pilot_start_date: string | null;
  days: number;
  outbound: LegReport;
  return: LegReport;
  return_given_outbound: {
    guess: number | null;
    rows: { out: string; n: number; top: string; top_share: number }[];
  };
  custodians: { name: string; days: number }[];
}

export interface GenerateResult {
  week_start: string;
  created: number;
  decoys: number;
  fallbacks: number;
  skipped: { asset: string; date: string; reason: string }[];
  warnings: { asset: string; date: string; reason: string; message: string }[];
}

export interface EmployeeRow {
  id: string;
  name: string;
  role: Role;
  is_lead_driver: boolean;
  is_active: boolean;
  locked_until: string | null;
}

export interface AssetRow {
  id: string;
  home_warehouse: string;
  is_active: boolean;
}

export interface ConfigRow {
  id: string;
  category: Category;
  value: string;
  is_active: boolean;
  company_only: boolean;
  decoy_ok: boolean;
}

export interface BudgetRow {
  id: string;
  vehicle_type: string;
  max_per_month: number | null;
  current_month_count: number;
  reset_month: number;
}

export interface Settings {
  me: string;
  pilot_start_date: string | null;
  employees: EmployeeRow[];
  assets: AssetRow[];
  config: ConfigRow[];
  budget: BudgetRow[];
  absences: Absence[];
}

export type TeamTrip = AdminTrip & { is_mine: boolean };

export interface TeamWeek {
  week_start: string;
  today: string;
  updated_dates: string[];
  trips: TeamTrip[];
}

export interface MyWeekDay {
  date: string;
  is_today: boolean;
  updated: boolean;
  trips: { id: string; label: string; leg: Leg; vehicle_type: string; status: TripStatus }[];
}

export interface MyWeek {
  week_start: string;
  today: string;
  days: MyWeekDay[];
}

export type RefreshAction = 'full' | 'return_only' | 'create' | 'locked';

export interface RefreshPreview {
  today: string;
  items: { date: string; asset: string; action: RefreshAction; legs: number }[];
}

export interface RefreshResult {
  replaced: number;
  created: number;
  decoys: number;
  fallbacks: number;
  warnings: { asset: string; date: string; reason: string; message: string }[];
}

export interface RefreshLogEntry {
  id: string;
  created_at: string;
  admin: string;
  range_from: string | null;
  range_to: string | null;
  include_today: boolean;
  include_next_week: boolean;
  replaced: number;
  created: number;
  reason: string | null;
}

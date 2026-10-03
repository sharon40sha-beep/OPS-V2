export type Role = 'admin' | 'operator';
export type TripStatus = 'planned' | 'active' | 'done' | 'problem';
export type Slot = 'morning' | 'noon';
export type Position = 'front' | 'back' | 'none';
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

export interface TripParams {
  departure_slot: Slot;
  vehicle_type: string;
  worker_position: Position;
  exit_point: string;
  outbound_route: string;
  factory_entry: string;
  factory_exit: string;
  return_route: string;
}

export interface WorkerTripDetail extends TripParams {
  id: string;
  label: string;
  asset_id: string;
  status: TripStatus;
  problem_note: string | null;
  actual_start_at: string | null;
  actual_done_at: string | null;
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
  status: TripStatus;
  problem_note: string | null;
  actual_start_at: string | null;
  actual_done_at: string | null;
  decoy_trip_id: string | null;
  excluded_from_analysis: boolean;
}

export interface AdminWeek {
  week_start: string;
  today: string;
  trips: AdminTrip[];
  stats: { total: number; done: number; open: number; problem: number };
}

export interface GenerateResult {
  week_start: string;
  created: number;
  decoys: number;
  fallbacks: number;
  skipped: { asset: string; date: string; reason: string }[];
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
  employees: EmployeeRow[];
  assets: AssetRow[];
  config: ConfigRow[];
  budget: BudgetRow[];
}

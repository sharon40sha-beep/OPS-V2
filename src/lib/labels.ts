import type { Category, Leg, Position, Slot, TripStatus } from './types';

const VEHICLES: Record<string, string> = {
  company: 'רכב חברה',
  rental: 'רכב שכור',
  delivery: 'רכב משלוחים',
};

const POSITIONS: Record<Position, string> = {
  front: 'מקדימה',
  back: 'מאחור',
  escort: 'ברכב אחר / מלווה',
  none: '—',
};

const SLOTS: Record<Slot, string> = {
  morning: 'בוקר',
  noon: 'צהריים',
};

const LEGS: Record<Leg, string> = {
  outbound: 'יציאה',
  return: 'חזרה',
};

export const legLabel = (l: string) => LEGS[l as Leg] ?? l;

export const STATUS_LABEL: Record<TripStatus, string> = {
  planned: 'מתוכנן',
  active: 'בדרך',
  done: 'הושלם',
  problem: 'בעיה',
};

export const CATEGORY_LABEL: Record<Category, string> = {
  exit_point: 'נקודת יציאה',
  vehicle_type: 'סוג רכב',
  outbound_route: 'ציר יציאה',
  factory_entry: 'כניסה למפעל',
  factory_exit: 'יציאה מהמפעל',
  return_route: 'ציר חזרה',
  worker_position: 'מיקום עובד',
};

/** Fixed codes the draw engine understands for worker_position. */
export const POSITION_CODES: Position[] = ['front', 'back', 'escort'];

export const CATEGORIES = Object.keys(CATEGORY_LABEL) as Category[];

export const vehicleLabel = (v: string) => VEHICLES[v] ?? v;
export const positionLabel = (p: string) => POSITIONS[p as Position] ?? p;
export const slotLabel = (s: string) => SLOTS[s as Slot] ?? s;

/** Display label for a config value (vehicle/position codes are stored in English). */
export function optionLabel(category: Category, value: string): string {
  if (category === 'vehicle_type') return vehicleLabel(value);
  if (category === 'worker_position') return positionLabel(value);
  return value;
}

/** Mirrors app_private.pin_policy_ok in the DB. */
export const PIN_POLICY_TEXT = 'לפחות 6 תווים, אות גדולה באנגלית, ספרה וסימן (למשל Abc12!)';
export function pinPolicyOk(pin: string): boolean {
  return pin.length >= 6 && /[A-Z]/.test(pin) && /[0-9]/.test(pin) && /[^\p{L}\p{N}\s]/u.test(pin);
}

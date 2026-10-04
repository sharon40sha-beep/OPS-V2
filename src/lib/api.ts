import { supabase } from './supabase';
import type {
  AdminTrip,
  AdminWeek,
  GenerateResult,
  PatternReport,
  TeamWeek,
  Me,
  Settings,
  TripParams,
  WorkerTask,
  WorkerTripDetail,
  WorkerWeekDay,
} from './types';

const MESSAGES: Record<string, string> = {
  INVALID_CREDENTIALS: 'שם או קוד שגויים',
  LOCKED: 'החשבון נעול ל-30 דקות לאחר 3 ניסיונות כושלים',
  SESSION_INVALID: 'הסשן הסתיים, יש להתחבר מחדש',
  FORBIDDEN: 'אין הרשאה',
  STEPUP_FAILED: 'קוד אימות שגוי',
  NOT_FOUND: 'הפריט לא נמצא',
  NOT_PLANNED: 'לא ניתן לשנות משימה שכבר בוצעה (מחיקה — רק לפני יציאה)',
  BAD_TRANSITION: 'פעולה לא אפשרית במצב הנוכחי',
  NOTE_REQUIRED: 'יש לתאר את הבעיה',
  BAD_INPUT: 'נתונים לא תקינים',
  BAD_VALUE: 'ערך לא תקין',
  POSITION_REQUIRED: 'ברכב חברה יש לבחור מיקום עובד',
  WORKERS_REQUIRED: 'יש לשבץ לפחות עובד אחד',
  LEAD_COMPANY_ONLY: 'נהג ראשי נוהג רק ברכב חברה',
  BUDGET_EXHAUSTED: 'המכסה החודשית לסוג רכב זה מוצתה',
  CONFIG_MISSING: 'חסרות אפשרויות פעילות בקטגוריה',
  PIN_TOO_SHORT: 'קוד חייב להכיל לפחות 6 תווים',
  PIN_POLICY: 'הקוד חייב להכיל לפחות 6 תווים, אות גדולה באנגלית, ספרה וסימן',
  LEAD_NOT_ALONE: 'נהג ראשי לא יוצא לבד עם המוצר — יש לשבץ עובד נוסף',
  DECOY_SOLO: 'בנסיעת פיתוי הנהג הראשי יוצא לבד',
  COMPANY_ONLY_OPTION: 'אחת האפשרויות שנבחרו מותרת רק ברכב חברה',
  PILOT_ALREADY_STARTED: 'הפיילוט כבר הוכרז',
  CUSTODIAN_LOCKED: 'לא ניתן להחליף אחראי מוצר — אחד הקטעים כבר יצא לדרך',
  CUSTODIAN_REQUIRED: 'אחראי המוצר חייב להיות משובץ בקטע',
  VEHICLE_BLOCKED: 'הרכב סומן כלא זמין ביום זה',
  DECOY_UNSAFE_OPTION: 'בקטע עם פיתוי מותרות רק אפשרויות שמסומנות "מותר בפיתוי" (חניון מקורה)',
  PIN_REQUIRED: 'יש להגדיר קוד לעובד חדש',
  NAME_TAKEN: 'השם כבר קיים',
  VALUE_TAKEN: 'הערך כבר קיים בקטגוריה',
  CANNOT_DEMOTE_SELF: 'לא ניתן להשבית או להוריד הרשאה לעצמך',
};

export class ApiError extends Error {
  readonly code: string;
  readonly detail?: string;
  constructor(code: string, detail?: string) {
    super(MESSAGES[code] ? MESSAGES[code] + (detail ? ` (${detail})` : '') : code);
    this.code = code;
    this.detail = detail;
  }
}

let onSessionInvalid: (() => void) | null = null;
export function setSessionInvalidHandler(fn: (() => void) | null) {
  onSessionInvalid = fn;
}

async function call<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    // RPCs raise bare codes, optionally "CODE:detail".
    const [code, detail] = (error.message ?? '').split(':');
    const err = MESSAGES[code]
      ? new ApiError(code, detail)
      : /check constraint/.test(error.message ?? '')
        ? new ApiError('BAD_VALUE')
        : new ApiError('NETWORK', error.message);
    if (err.code === 'SESSION_INVALID') onSessionInvalid?.();
    throw err;
  }
  if (data && typeof data === 'object' && (data as { ok?: boolean }).ok === false) {
    const code = (data as { error: string }).error;
    if (code === 'LOCKED' && args.p_token) onSessionInvalid?.();
    throw new ApiError(code);
  }
  return data as T;
}

export const api = {
  login: (name: string, pin: string) =>
    call<{ token: string; employee: Me }>('login', { p_name: name, p_pin: pin }),
  logout: (token: string) => call<void>('logout', { p_token: token }),
  me: (token: string) => call<Me>('me', { p_token: token }),

  workerToday: (token: string) => call<WorkerTask[]>('worker_today', { p_token: token }),
  workerTripDetail: (token: string, tripId: string) =>
    call<WorkerTripDetail>('worker_trip_detail', { p_token: token, p_trip_id: tripId }),
  workerSetStatus: (token: string, tripId: string, action: 'start' | 'done' | 'problem' | 'note', note?: string) =>
    call<void>('worker_set_status', { p_token: token, p_trip_id: tripId, p_action: action, p_note: note ?? null }),
  workerWeek: (token: string) => call<WorkerWeekDay[]>('worker_week', { p_token: token }),
  teamWeek: (token: string, weekOffset: number) =>
    call<TeamWeek>('team_week', { p_token: token, p_week_offset: weekOffset }),

  adminWeek: (token: string, date: string) => call<AdminWeek>('admin_week', { p_token: token, p_date: date }),
  generateWeek: (token: string, pin: string, weekStart: string) =>
    call<GenerateResult>('admin_generate_week', { p_token: token, p_pin: pin, p_week_start: weekStart }),
  updateTrip: (
    token: string,
    tripId: string,
    data: Partial<TripParams> & { assigned_workers?: string[]; custodian_id?: string; excluded_from_analysis?: boolean },
  ) => call<{ trip: AdminTrip }>('admin_update_trip', { p_token: token, p_trip_id: tripId, p_data: data }),
  deleteTrip: (token: string, pin: string, tripId: string) =>
    call<void>('admin_delete_trip', { p_token: token, p_pin: pin, p_trip_id: tripId }),

  settings: (token: string) => call<Settings>('admin_settings', { p_token: token }),
  saveEmployee: (
    token: string,
    e: { id: string | null; name: string; role: string; is_lead_driver: boolean; is_active: boolean; pin: string },
  ) =>
    call<void>('admin_save_employee', {
      p_token: token,
      p_id: e.id,
      p_name: e.name,
      p_role: e.role,
      p_is_lead_driver: e.is_lead_driver,
      p_is_active: e.is_active,
      p_pin: e.pin || null,
    }),
  unlockAccount: (token: string, pin: string, employeeId: string) =>
    call<void>('admin_unlock_account', { p_token: token, p_pin: pin, p_employee_id: employeeId }),
  saveAsset: (token: string, id: string, homeWarehouse: string, isActive: boolean) =>
    call<void>('admin_save_asset', { p_token: token, p_id: id, p_home_warehouse: homeWarehouse, p_is_active: isActive }),
  saveConfig: (
    token: string, id: string | null, category: string, value: string,
    isActive: boolean, companyOnly: boolean, decoyOk: boolean,
  ) =>
    call<void>('admin_save_config', {
      p_token: token,
      p_id: id,
      p_category: category,
      p_value: value,
      p_is_active: isActive,
      p_company_only: companyOnly,
      p_decoy_ok: decoyOk,
    }),
  declarePilot: (token: string, pin: string, wipeTestData: boolean) =>
    call<{ pilot_start_date: string }>('admin_declare_pilot', { p_token: token, p_pin: pin, p_wipe_test_data: wipeTestData }),
  setVehicleBlock: (token: string, vehicleType: string, date: string, blocked: boolean) =>
    call<void>('admin_set_vehicle_block', { p_token: token, p_vehicle_type: vehicleType, p_date: date, p_blocked: blocked }),
  patternReport: (token: string, days: number | null) =>
    call<PatternReport>('admin_pattern_report', { p_token: token, p_days: days }),
  setAbsence: (token: string, employeeId: string, date: string, absent: boolean, note?: string) =>
    call<void>('admin_set_absence', {
      p_token: token,
      p_employee_id: employeeId,
      p_date: date,
      p_absent: absent,
      p_note: note ?? null,
    }),
  saveBudget: (token: string, vehicleType: string, max: number | null) =>
    call<void>('admin_save_budget', { p_token: token, p_vehicle_type: vehicleType, p_max: max }),
};

export function errorText(e: unknown): string {
  if (e instanceof ApiError) return e.code === 'NETWORK' ? `שגיאת שרת: ${e.detail ?? 'לא ידועה'}` : e.message;
  return 'שגיאה לא צפויה';
}

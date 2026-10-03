const DAY_NAMES = ['ראשון', 'שני', 'שלישי', 'רביעי', 'חמישי', 'שישי', 'שבת'];

/** Parses a YYYY-MM-DD string as a local calendar date. */
export function parseDate(iso: string): Date {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d);
}

export function toIso(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function addDays(iso: string, days: number): string {
  const d = parseDate(iso);
  d.setDate(d.getDate() + days);
  return toIso(d);
}

export const todayIso = () => toIso(new Date());

export function dayName(iso: string): string {
  return DAY_NAMES[parseDate(iso).getDay()];
}

export function shortDate(iso: string): string {
  const d = parseDate(iso);
  return `${d.getDate()}/${d.getMonth() + 1}`;
}

export function timeOf(ts: string | null): string {
  if (!ts) return '';
  return new Date(ts).toLocaleTimeString('he-IL', { hour: '2-digit', minute: '2-digit' });
}

/** Monday of the Sun–Sat week containing iso; Saturday maps to next week (mirrors the DB). */
export function weekMonday(iso: string): string {
  const dow = parseDate(iso).getDay();
  return addDays(iso, 1 - dow + (dow === 6 ? 7 : 0));
}

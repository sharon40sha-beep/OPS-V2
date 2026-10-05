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

/**
 * All clock times are Israel time, whatever the device's time-zone setting is
 * (a phone or laptop set to another zone would otherwise shift every time).
 */
export const TZ = 'Asia/Jerusalem';

function israelParts(d: Date): Record<'year' | 'month' | 'day' | 'hour' | 'minute' | 'second', number> {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(d);
  const get = (t: string) => Number(parts.find((x) => x.type === t)?.value);
  return { year: get('year'), month: get('month'), day: get('day'), hour: get('hour'), minute: get('minute'), second: get('second') };
}

const pad = (n: number) => String(n).padStart(2, '0');

/** Today's date in Israel (YYYY-MM-DD). */
export const todayIso = () => {
  const p = israelParts(new Date());
  return `${p.year}-${pad(p.month)}-${pad(p.day)}`;
};

/** Value for <input type="datetime-local">, in Israel time. */
export function toLocalInput(d: Date): string {
  const p = israelParts(d);
  return `${p.year}-${pad(p.month)}-${pad(p.day)}T${pad(p.hour)}:${pad(p.minute)}`;
}

/** Israel wall time from <input type="datetime-local"> → ISO timestamp (handles DST). */
export function fromLocalInput(value: string): string {
  const [date, time] = value.split('T');
  const [y, mo, d] = date.split('-').map(Number);
  const [h, mi] = time.split(':').map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi);
  const offsetAt = (ms: number) => {
    const p = israelParts(new Date(ms));
    return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - ms;
  };
  let ms = wall - offsetAt(wall);
  ms = wall - offsetAt(ms);
  return new Date(ms).toISOString();
}

export function dayName(iso: string): string {
  return DAY_NAMES[parseDate(iso).getDay()];
}

export function shortDate(iso: string): string {
  const d = parseDate(iso);
  return `${d.getDate()}/${d.getMonth() + 1}`;
}

export function timeOf(ts: string | null): string {
  if (!ts) return '';
  return new Date(ts).toLocaleTimeString('he-IL', { hour: '2-digit', minute: '2-digit', timeZone: TZ });
}

/** Monday of the Sun–Sat week containing iso; Saturday maps to next week (mirrors the DB). */
export function weekMonday(iso: string): string {
  const dow = parseDate(iso).getDay();
  return addDays(iso, 1 - dow + (dow === 6 ? 7 : 0));
}

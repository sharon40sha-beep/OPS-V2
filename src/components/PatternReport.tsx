import { useState } from 'react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { shortDate } from '../lib/dates';
import { legLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { Count, LegReport } from '../lib/types';
import { Modal } from './Modal';

const PERIODS: [string, number | null][] = [
  ['30 יום', 30],
  ['90 יום', 90],
  ['שנה', 365],
  ['הכול', null],
];
const DOW = ['', 'ב׳', 'ג׳', 'ד׳', 'ה׳', 'ו׳', 'ש׳', 'א׳'];
const MIN_SAMPLES = 20;
const pct = (x: number | null | undefined) => (x == null ? '—' : `${Math.round(x * 100)}%`);

/**
 * What an adversary could learn from the history: how well the vehicle can be
 * guessed blind vs. knowing the weekday (or the morning vehicle, for returns).
 */
export function PatternReport({ onClose }: { onClose: () => void }) {
  const { token } = useAuth();
  const [days, setDays] = useState<number | null>(null);
  const { data, error } = useAsync(() => api.patternReport(token, days), [token, days]);

  return (
    <Modal title="ניתוח דפוסים" onClose={onClose}>
      <div className="segmented">
        {PERIODS.map(([label, value]) => (
          <button key={label} className={days === value ? 'active' : ''} onClick={() => setDays(value)}>{label}</button>
        ))}
      </div>
      {error && <p className="error">{error}</p>}
      {data && (
        <div className="stack">
          <p className="muted small">
            {data.days} ימים בניתוח
            {data.pilot_start_date ? ` · מתחילת הפיילוט (${shortDate(data.pilot_start_date)})` : ' · לפני פיילוט (נתוני ניסיון)'}
            {' '}· כולל נסיעות מתוכננות
          </p>
          <p className="hint">
            "יכולת ניחוש" = כמה פעמים יריב היה צודק אם היה מנחש את הרכב לפי הדפוס. ככל שהניחוש עם מידע
            (יום בשבוע / רכב הבוקר) קרוב לניחוש העיוור — אין דפוס שאפשר ללמוד. מעל 60% מסומן באדום.
          </p>
          {(['outbound', 'return'] as const).map((leg) => (
            <LegSection key={leg} title={legLabel(leg)} r={data[leg]}
              extra={leg === 'return' ? data.return_given_outbound : undefined} />
          ))}
          <div className="card stack">
            <strong>אחראי מוצר — ימים</strong>
            <Bars items={data.custodians.map((c) => ({ value: c.name, count: c.days }))} />
          </div>
        </div>
      )}
    </Modal>
  );
}

function LegSection({ title, r, extra }: {
  title: string;
  r: LegReport;
  extra?: { guess: number | null; rows: { out: string; n: number; top: string; top_share: number }[] };
}) {
  if (!r.n) return <div className="card"><strong>{title}</strong> <span className="muted small">אין נתונים</span></div>;
  // Below ~4 samples per weekday the shares are noise, not a pattern.
  const enough = r.n >= MIN_SAMPLES;
  const bad = (share: number | null | undefined) => enough && (share ?? 0) > 0.6;
  return (
    <div className="card stack">
      <strong>{title} · {r.n} קטעים · פיתוי ב-{pct(r.decoy_rate)}</strong>
      {!enough && <p className="hint">מעט נתונים (פחות מ-{MIN_SAMPLES} קטעים) — האחוזים עדיין לא מעידים על דפוס.</p>}
      <Bars items={r.vehicle} label={vehicleLabel} />
      <div className="guess">
        <span>ניחוש עיוור: <b>{pct(r.guess_blind)}</b></span>
        <span className={bad(r.guess_by_weekday) ? 'bad' : ''}>לפי יום בשבוע: <b>{pct(r.guess_by_weekday)}</b></span>
        {extra && (
          <span className={bad(extra.guess) ? 'bad' : ''}>לפי רכב הבוקר: <b>{pct(extra.guess)}</b></span>
        )}
      </div>
      <table className="mini">
        <tbody>
          {r.by_weekday.map((d) => (
            <tr key={d.dow} className={enough && d.top_share > 0.6 && d.n >= 4 ? 'bad' : ''}>
              <td>{DOW[d.dow]}</td><td>{d.n}</td><td>{vehicleLabel(d.top)}</td><td>{pct(d.top_share)}</td>
            </tr>
          ))}
          {extra?.rows.map((x) => (
            <tr key={x.out} className={enough && x.top_share > 0.6 && x.n >= 4 ? 'bad' : ''}>
              <td>בוקר: {vehicleLabel(x.out)}</td><td>{x.n}</td><td>{vehicleLabel(x.top)}</td><td>{pct(x.top_share)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <Bars items={r.params.a} />
      <Bars items={r.params.b} />
      {r.params.c.length > 0 && <Bars items={r.params.c} />}
    </div>
  );
}

function Bars({ items, label = (v: string) => v }: { items: Count[]; label?: (v: string) => string }) {
  const total = items.reduce((s, i) => s + i.count, 0) || 1;
  return (
    <div className="bars">
      {items.map((i) => (
        <div key={i.value} className="bar-row">
          <span className="bar-label">{label(i.value)}</span>
          <span className="bar"><span style={{ width: `${(i.count / total) * 100}%` }} /></span>
          <span className="bar-value">{Math.round((i.count / total) * 100)}%</span>
        </div>
      ))}
    </div>
  );
}

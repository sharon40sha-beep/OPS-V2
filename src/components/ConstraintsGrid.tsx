import { useState } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { addDays, dayName, parseDate, shortDate } from '../lib/dates';
import { vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';

const DAY_LETTERS = ['א', 'ב', 'ג', 'ד', 'ה', 'ו', 'ש'];

/**
 * Week constraints entered before generation: who is unavailable and which
 * vehicle is unavailable on each day. Each toggle is saved immediately.
 */
export function ConstraintsGrid({ monday }: { monday: string }) {
  const { token } = useAuth();
  const { data, error, reload } = useAsync(
    () => Promise.all([api.settings(token), api.adminWeek(token, monday)]),
    [token, monday],
  );
  const [busy, setBusy] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const days = [0, 1, 2, 3, 4].map((i) => addDays(monday, i));

  if (error) return <p className="error">{error}</p>;
  if (!data) return <p className="muted small">טוען מגבלות…</p>;
  const [settings, week] = data;

  const people = settings.employees.filter((e) => e.is_active);
  const vehicles = settings.config.filter((c) => c.category === 'vehicle_type' && c.is_active).map((c) => c.value);
  const absent = new Set(week.absences.map((a) => `${a.employee_id}|${a.date}`));
  const blocked = new Set(week.vehicle_blocks.map((b) => `${b.vehicle_type}|${b.date}`));

  const toggle = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setSaveError(null);
    try {
      await fn();
      await reload();
    } catch (e) {
      setSaveError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const header = (
    <tr>
      <th />
      {days.map((d) => (
        <th key={d} title={`${dayName(d)} ${shortDate(d)}`}>
          {DAY_LETTERS[parseDate(d).getDay()]}<br /><span className="muted">{shortDate(d)}</span>
        </th>
      ))}
    </tr>
  );

  return (
    <div className="stack">
      <p className="hint">סמן ✕ למי/מה שלא זמין. המגבלות נשמרות מיד ונלקחות בחשבון בהגרלה.</p>
      {saveError && <p className="error">{saveError}</p>}
      <table className="grid">
        <thead>{header}</thead>
        <tbody>
          <tr className="grid-section"><td colSpan={6}>עובדים</td></tr>
          {people.map((e) => (
            <tr key={e.id}>
              <th>{e.name}{e.is_lead_driver && <span className="chip small">נהג</span>}</th>
              {days.map((d) => {
                const off = absent.has(`${e.id}|${d}`);
                return (
                  <td key={d}>
                    <button className={`cell ${off ? 'off' : ''}`} disabled={busy}
                      aria-label={`${e.name} ${dayName(d)} ${off ? 'לא זמין' : 'זמין'}`}
                      onClick={() => toggle(() => api.setAbsence(token, e.id, d, !off))}>
                      {off ? '✕' : ''}
                    </button>
                  </td>
                );
              })}
            </tr>
          ))}
          <tr className="grid-section"><td colSpan={6}>רכבים</td></tr>
          {vehicles.map((v) => (
            <tr key={v}>
              <th>{vehicleLabel(v)}</th>
              {days.map((d) => {
                const off = blocked.has(`${v}|${d}`);
                return (
                  <td key={d}>
                    <button className={`cell ${off ? 'off' : ''}`} disabled={busy}
                      aria-label={`${vehicleLabel(v)} ${dayName(d)} ${off ? 'לא זמין' : 'זמין'}`}
                      onClick={() => toggle(() => api.setVehicleBlock(token, v, d, !off))}>
                      {off ? '✕' : ''}
                    </button>
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

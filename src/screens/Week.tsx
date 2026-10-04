import { useMemo, useState } from 'react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { addDays, dayName, shortDate } from '../lib/dates';
import { legLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { TeamTrip } from '../lib/types';
import { StatusChip } from '../components/StatusChip';

/**
 * Team schedule for the week, read-only for everyone: who goes, which leg,
 * which vehicle, status. Routes are not shown here (own trip details are in
 * "היום"; admins edit in "בקרה").
 */
export function Week() {
  const { token, me } = useAuth();
  const [offset, setOffset] = useState(0);
  const { data, error, loading } = useAsync(() => api.teamWeek(token, offset), [token, offset]);
  const isAdmin = me.role === 'admin';
  const canPrev = isAdmin || offset > 0;
  const canNext = isAdmin || offset < 1;

  const days = useMemo(() => {
    if (!data) return [];
    const byDay = new Map<string, TeamTrip[]>();
    for (let i = 0; i < 5; i++) byDay.set(addDays(data.week_start, i), []);
    data.trips.forEach((t) => byDay.get(t.date)?.push(t));
    return [...byDay.entries()];
  }, [data]);

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>השבוע</h1>
      </header>

      <div className="week-nav">
        <button className="icon-btn" disabled={!canPrev} onClick={() => setOffset(offset - 1)} aria-label="שבוע קודם">›</button>
        <div className="week-nav-label">
          {data && <strong>{shortDate(data.week_start)} – {shortDate(addDays(data.week_start, 4))}</strong>}
          <span className="muted small">{offset === 0 ? 'השבוע' : offset === 1 ? 'שבוע הבא' : ''}</span>
        </div>
        <button className="icon-btn" disabled={!canNext} onClick={() => setOffset(offset + 1)} aria-label="שבוע הבא">‹</button>
      </div>

      {!isAdmin && <p className="hint">תצוגה בלבד. פרטי המסלול של המשימה שלך מופיעים במסך "היום".</p>}
      {error && <p className="error">{error}</p>}
      {loading && !data && <p className="muted">טוען…</p>}

      {data && days.map(([date, trips]) => (
        <div key={date} className={`day-group ${date === data.today ? 'today' : ''}`}>
          <h3>{dayName(date)} <span className="muted">{shortDate(date)}</span></h3>
          {trips.length === 0 && <p className="muted small">אין משימות</p>}
          <div className="stack">
            {trips.map((t) => (
              <div key={t.id} className={`card team-row ${t.is_mine ? 'mine' : ''}`}>
                <div className="list-main">
                  <strong>{t.asset_id} · {legLabel(t.leg)} · {vehicleLabel(t.vehicle_type)}</strong>
                  <span className="muted small">
                    {t.crew.map((c) => (c.is_custodian ? `${c.name} (אחראי)` : c.name)).join(', ') || '—'}
                  </span>
                </div>
                <div className="team-row-side">
                  {t.is_mine && <span className="chip gold small">שלי</span>}
                  <StatusChip status={t.status} />
                </div>
              </div>
            ))}
          </div>
        </div>
      ))}
    </section>
  );
}

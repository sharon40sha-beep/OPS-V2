import { useMemo, useState } from 'react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { addDays, dayName, shortDate, timeOf } from '../lib/dates';
import { legLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { TeamTrip } from '../lib/types';
import { StatusChip } from '../components/StatusChip';
import { TripParams } from '../components/TripParams';

/**
 * "השבוע": the whole team's legs with full details, read-only for everyone.
 * Changes are made by the admin in "בקרה"; status buttons are in "היום".
 */
export function Week() {
  const { token, me } = useAuth();
  const isAdmin = me.role === 'admin';
  const [offset, setOffset] = useState(0);
  const [openId, setOpenId] = useState<string | null>(null);
  const { data, error, loading, reload } = useAsync(() => api.teamWeek(token, offset), [token, offset]);

  const days = useMemo(() => {
    if (!data) return [];
    const byDay = new Map<string, TeamTrip[]>();
    for (let i = 0; i < 5; i++) byDay.set(addDays(data.week_start, i), []);
    data.trips.forEach((t) => byDay.get(t.date)?.push(t));
    return [...byDay.entries()];
  }, [data]);

  const updated = new Set(data?.updated_dates ?? []);

  const markSeen = async (date: string) => {
    if (!updated.has(date)) return;
    try {
      await api.workerMarkDaySeen(token, date);
      await reload();
    } catch {
      // marker stays; not critical
    }
  };

  const toggle = (t: TeamTrip) => {
    setOpenId(openId === t.id ? null : t.id);
    void markSeen(t.date);
  };

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>השבוע</h1>
      </header>

      <div className="week-nav">
        <button className="icon-btn" disabled={!isAdmin && offset <= 0} onClick={() => setOffset(offset - 1)} aria-label="שבוע קודם">›</button>
        <div className="week-nav-label">
          {data && <strong>{shortDate(data.week_start)} – {shortDate(addDays(data.week_start, 4))}</strong>}
          <span className="muted small">{offset === 0 ? 'השבוע' : offset === 1 ? 'שבוע הבא' : ''}</span>
        </div>
        <button className="icon-btn" disabled={!isAdmin && offset >= 1} onClick={() => setOffset(offset + 1)} aria-label="שבוע הבא">‹</button>
      </div>

      <p className="hint">
        צפייה בלבד. לחיצה על משימה מציגה את כל הפרטים. {isAdmin ? 'שינויים — בלשונית "בקרה".' : 'כפתורי "יצאתי / חזרתי / יש בעיה" — במסך "היום".'}
      </p>
      {error && <p className="error">{error}</p>}
      {loading && !data && <p className="muted">טוען…</p>}

      {data && days.map(([date, trips]) => (
        <div key={date} className={`day-group ${date === data.today ? 'today' : ''}`}>
          <h3 className={updated.has(date) ? 'clickable' : ''} onClick={() => markSeen(date)}>
            {dayName(date)} <span className="muted">{shortDate(date)}</span>
            {updated.has(date) && <span className="chip updated-tag">עודכן</span>}
          </h3>
          {trips.length === 0 && <p className="muted small">אין משימות</p>}
          <div className="stack">
            {trips.map((t) => {
              const decoy = t.trip_type === 'decoy';
              const open = openId === t.id;
              return (
                <article key={t.id} className={`card trip ${decoy ? 'decoy' : ''} ${t.is_mine ? 'mine' : ''}`}>
                  <button className="task-head" onClick={() => toggle(t)} aria-expanded={open}>
                    <span className="trip-title">
                      {decoy && <span className="chip decoy-tag">פיתוי</span>}
                      <span>{t.asset_id} · {legLabel(t.leg)} · {vehicleLabel(t.vehicle_type)}</span>
                    </span>
                    <span className="team-row-side">
                      {t.is_mine && <span className="chip gold small">שלי</span>}
                      <StatusChip status={t.status} />
                    </span>
                  </button>
                  <p className="muted small workers">
                    {t.workers.map((w) => (w.id === t.custodian_id ? `${w.name} (אחראי)` : w.name)).join(', ') || '—'}
                  </p>
                  {open && (
                    <div className="task-body stack">
                      <TripParams trip={t} />
                      {(t.actual_start_at || t.actual_done_at) && (
                        <p className="muted small">
                          {t.actual_start_at && `יציאה בפועל ${timeOf(t.actual_start_at)}`}
                          {t.actual_done_at && ` · חזרה בפועל ${timeOf(t.actual_done_at)}`}
                        </p>
                      )}
                      {t.problem_note && (
                        <p className={t.status === 'problem' ? 'problem-note' : 'note'}>
                          {t.status === 'problem' ? 'בעיה' : 'הערה'}: {t.problem_note}
                        </p>
                      )}
                    </div>
                  )}
                </article>
              );
            })}
          </div>
        </div>
      ))}
    </section>
  );
}

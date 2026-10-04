import { useState } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { addDays, dayName, shortDate } from '../lib/dates';
import { useAsync } from '../lib/useAsync';
import type { MyWeekDay, WorkerTripDetail } from '../lib/types';
import { StatusChip } from '../components/StatusChip';
import { TripDetail } from '../components/TripDetail';

/**
 * The worker's own legs for this week / next week. Every leg opens read-only
 * (for preparation); status buttons live only in "היום" on the day itself.
 */
export function MyWeek() {
  const { token } = useAuth();
  const [offset, setOffset] = useState(0);
  const { data, error, loading, reload } = useAsync(() => api.workerMyWeek(token, offset), [token, offset]);

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>השבוע שלי</h1>
      </header>
      <div className="week-nav">
        <button className="icon-btn" disabled={offset === 0} onClick={() => setOffset(0)} aria-label="השבוע">›</button>
        <div className="week-nav-label">
          {data && <strong>{shortDate(data.week_start)} – {shortDate(addDays(data.week_start, 4))}</strong>}
          <span className="muted small">{offset === 0 ? 'השבוע' : 'שבוע הבא'}</span>
        </div>
        <button className="icon-btn" disabled={offset === 1} onClick={() => setOffset(1)} aria-label="שבוע הבא">‹</button>
      </div>
      <p className="hint">צפייה בלבד, לצורך הכנה. הכפתורים "יצאתי / חזרתי / יש בעיה" — במסך "היום", ביום המשימה.</p>
      {error && <p className="error">{error}</p>}
      {loading && !data && <p className="muted">טוען…</p>}
      {data?.days.map((d) => <Day key={d.date} day={d} onSeen={reload} />)}
    </section>
  );
}

function Day({ day, onSeen }: { day: MyWeekDay; onSeen: () => Promise<void> }) {
  const { token } = useAuth();
  const [openId, setOpenId] = useState<string | null>(null);
  const [detail, setDetail] = useState<WorkerTripDetail | null>(null);
  const [error, setError] = useState<string | null>(null);

  const markSeen = async () => {
    if (!day.updated) return;
    try {
      await api.workerMarkDaySeen(token, day.date);
      await onSeen();
    } catch {
      // marker stays; not critical
    }
  };

  const open = async (id: string) => {
    if (openId === id) {
      setOpenId(null);
      return;
    }
    setOpenId(id);
    setDetail(null);
    setError(null);
    try {
      setDetail(await api.workerTripDetail(token, id)); // also clears the "updated" marker
      if (day.updated) await onSeen();
    } catch (e) {
      setError(errorText(e));
    }
  };

  return (
    <div className={`day-group ${day.is_today ? 'today' : ''}`}>
      <h3 onClick={markSeen} className={day.updated ? 'clickable' : ''}>
        {dayName(day.date)} <span className="muted">{shortDate(day.date)}</span>
        {day.updated && <span className="chip updated-tag">עודכן</span>}
      </h3>
      {day.trips.length === 0 && (
        <p className="muted small">{day.updated ? 'אין לך משימה ביום זה (עודכן)' : 'אין משימה'}</p>
      )}
      <div className="stack">
        {day.trips.map((t) => (
          <article key={t.id} className={`card task ${openId === t.id ? 'open' : ''}`}>
            <button className="task-head" onClick={() => open(t.id)} aria-expanded={openId === t.id}>
              <span className="task-label">{t.label}</span>
              <StatusChip status={t.status} />
            </button>
            {openId === t.id && (
              <div className="task-body">
                {error && <p className="error">{error}</p>}
                {!detail && !error && <p className="muted">טוען…</p>}
                {detail && detail.id === t.id && <TripDetail detail={detail} />}
              </div>
            )}
          </article>
        ))}
      </div>
    </div>
  );
}

import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate } from '../lib/dates';
import { useAsync } from '../lib/useAsync';

export function Week() {
  const { token } = useAuth();
  const { data: days, error, loading } = useAsync(() => api.workerWeek(token), [token]);

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>השבוע שלי</h1>
      </header>
      {error && <p className="error">{error}</p>}
      {loading && !days && <p className="muted">טוען…</p>}
      <ul className="week-list">
        {days?.map((d) => (
          <li key={d.date} className={`card week-day ${d.is_today ? 'today' : ''}`}>
            <div className="week-date">
              <strong>{dayName(d.date)}</strong>
              <span className="muted">{shortDate(d.date)}</span>
            </div>
            <div className="week-tasks">
              {d.labels.length === 0 ? (
                <span className="muted">אין משימה</span>
              ) : (
                d.labels.map((l, i) => <span key={i} className="chip gold">{l}</span>)
              )}
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

import { useMemo, useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { addDays, dayName, shortDate, timeOf, todayIso, weekMonday } from '../lib/dates';
import { slotLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { Absence, AdminTrip, GenerateResult } from '../lib/types';
import { Modal } from '../components/Modal';
import { StatusChip } from '../components/StatusChip';
import { TripParams } from '../components/TripParams';
import { useStepUp } from '../components/StepUp';
import { TripEditor } from '../components/TripEditor';

export function Dashboard() {
  const { token } = useAuth();
  const [weekStart, setWeekStart] = useState(() => weekMonday(todayIso()));
  const { data, error, loading, reload } = useAsync(() => api.adminWeek(token, weekStart), [token, weekStart]);
  const [generateOpen, setGenerateOpen] = useState(false);
  const [editing, setEditing] = useState<AdminTrip | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const stepUp = useStepUp();

  const days = useMemo(() => {
    const byDay = new Map<string, AdminTrip[]>();
    for (let i = 0; i < 5; i++) byDay.set(addDays(weekStart, i), []);
    data?.trips.forEach((t) => byDay.get(t.date)?.push(t));
    return [...byDay.entries()];
  }, [data, weekStart]);

  const remove = async (trip: AdminTrip) => {
    const extra = trip.trip_type === 'real' && trip.decoy_trip_id ? ' (כולל הפיתוי המקושר)' : '';
    const pin = await stepUp.ask(`מחיקת ${trip.label} ביום ${dayName(trip.date)}${extra}`);
    if (!pin) return;
    setActionError(null);
    try {
      await api.deleteTrip(token, pin, trip.id);
      await reload();
    } catch (e) {
      setActionError(errorText(e));
    }
  };

  const stats = data?.stats;
  const isCurrentWeek = weekStart === weekMonday(todayIso());

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>לוח בקרה</h1>
      </header>

      <button className="btn primary block big" onClick={() => setGenerateOpen(true)}>בנה שבוע</button>

      <div className="week-nav">
        <button className="icon-btn" onClick={() => setWeekStart(addDays(weekStart, -7))} aria-label="שבוע קודם">›</button>
        <div className="week-nav-label">
          <strong>{shortDate(weekStart)} – {shortDate(addDays(weekStart, 4))}</strong>
          {isCurrentWeek ? <span className="muted small">השבוע</span> : (
            <button className="link" onClick={() => setWeekStart(weekMonday(todayIso()))}>חזרה לשבוע הנוכחי</button>
          )}
        </div>
        <button className="icon-btn" onClick={() => setWeekStart(addDays(weekStart, 7))} aria-label="שבוע הבא">‹</button>
      </div>

      {stats && (
        <div className="stats">
          <div className="stat"><b>{stats.done}</b><span>הושלמו</span></div>
          <div className="stat"><b>{stats.open}</b><span>פתוחות</span></div>
          <div className={`stat ${stats.problem ? 'bad' : ''}`}><b>{stats.problem}</b><span>בעיות</span></div>
        </div>
      )}

      {error && <p className="error">{error}</p>}
      {actionError && <p className="error">{actionError}</p>}
      {loading && !data && <p className="muted">טוען…</p>}

      {data && days.map(([date, trips]) => (
        <div key={date} className={`day-group ${date === data.today ? 'today' : ''}`}>
          <h3>{dayName(date)} <span className="muted">{shortDate(date)}</span></h3>
          <DayNotes date={date} trips={trips} absences={data.absences} leadIds={data.lead_ids} />
          {trips.length === 0 && <p className="muted small">אין נסיעות</p>}
          <div className="stack">
            {trips.map((t) => (
              <AdminTripCard key={t.id} trip={t} open={openId === t.id}
                onToggle={() => setOpenId(openId === t.id ? null : t.id)}
                onEdit={() => setEditing(t)} onDelete={() => remove(t)} />
            ))}
          </div>
        </div>
      ))}

      {generateOpen && (
        <GenerateModal defaultDate={weekStart} onClose={() => setGenerateOpen(false)}
          onDone={(res) => {
            setWeekStart(res.week_start);
            if (res.week_start === weekStart) void reload();
          }} />
      )}
      {editing && (
        <TripEditor trip={editing} onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); void reload(); }} />
      )}
      {stepUp.element}
    </section>
  );
}

function AdminTripCard({ trip, open, onToggle, onEdit, onDelete }: {
  trip: AdminTrip; open: boolean; onToggle: () => void; onEdit: () => void; onDelete: () => void;
}) {
  const decoy = trip.trip_type === 'decoy';
  return (
    <article className={`card trip ${decoy ? 'decoy' : ''}`}>
      <button className="task-head" onClick={onToggle} aria-expanded={open}>
        <span className="trip-title">
          {decoy && <span className="chip decoy-tag">פיתוי</span>}
          <span>{trip.asset_id} · {slotLabel(trip.departure_slot)} · {vehicleLabel(trip.vehicle_type)}</span>
        </span>
        <StatusChip status={trip.status} />
      </button>
      <p className="muted small workers">{trip.workers.map((w) => w.name).join(', ') || '—'}</p>
      {open && (
        <div className="task-body stack">
          <TripParams trip={trip} />
          {trip.decoy_trip_id && (
            <p className="muted small">{decoy ? 'פיתוי לנסיעה אמיתית באותו יום' : 'יש פיתוי מקושר באותו יום'}</p>
          )}
          {(trip.actual_start_at || trip.actual_done_at) && (
            <p className="muted small">
              {trip.actual_start_at && `יציאה ${timeOf(trip.actual_start_at)}`}
              {trip.actual_done_at && ` · חזרה ${timeOf(trip.actual_done_at)}`}
            </p>
          )}
          {trip.problem_note && (
            <p className={trip.status === 'problem' ? 'problem-note' : 'note'}>
              {trip.status === 'problem' ? 'בעיה' : 'הערה'}: {trip.problem_note}
            </p>
          )}
          {trip.excluded_from_analysis && <p className="muted small">מוחרג מניתוח הדפוסים</p>}
          <div className="row">
            <button className="btn" onClick={onEdit}>{trip.status === 'planned' ? 'ערוך' : 'הגדרות ניתוח'}</button>
            {trip.status === 'planned' && <button className="btn danger" onClick={onDelete}>מחק</button>}
          </div>
        </div>
      )}
    </article>
  );
}

/** Absences for the day + warning when no lead driver is scheduled. */
function DayNotes({ date, trips, absences, leadIds }: {
  date: string; trips: AdminTrip[]; absences: Absence[]; leadIds: string[];
}) {
  const absent = absences.filter((a) => a.date === date);
  const leadAbsent = absent.some((a) => leadIds.includes(a.employee_id));
  const leadScheduled = trips.some((t) => t.assigned_workers.some((w) => leadIds.includes(w)));
  return (
    <>
      {absent.length > 0 && <p className="muted small">נעדרים: {absent.map((a) => a.name).join(', ')}</p>}
      {trips.length > 0 && leadIds.length > 0 && !leadScheduled && !leadAbsent && (
        <p className="error small">⚠ נהג ראשי לא משובץ ביום זה</p>
      )}
    </>
  );
}

function GenerateModal({ defaultDate, onClose, onDone }: {
  defaultDate: string; onClose: () => void; onDone: (r: GenerateResult) => void;
}) {
  const { token } = useAuth();
  const [date, setDate] = useState(defaultDate);
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<GenerateResult | null>(null);
  const monday = date ? weekMonday(date) : null;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!monday) return;
    setBusy(true);
    setError(null);
    try {
      const res = await api.generateWeek(token, pin, monday);
      setResult(res);
      onDone(res);
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
      setPin('');
    }
  };

  return (
    <Modal title="בניית שבוע" onClose={onClose}>
      {result ? (
        <div className="stack">
          <p>נוצרו <b>{result.created}</b> נסיעות, מתוכן <b>{result.decoys}</b> עם פיתוי.</p>
          {result.fallbacks > 0 && (
            <p className="muted small">{result.fallbacks} נסיעות נבחרו כ"הכי פחות חוזרות" (לא נמצא שילוב נקי ב-10 ניסיונות).</p>
          )}
          {result.warnings.length > 0 && (
            <p className="error small">
              נהג ראשי לא שובץ ב: {result.warnings.map((w) => `${dayName(w.date)} ${shortDate(w.date)}`).join(', ')}
              {' '}(אין אפשרות לפיתוי או מכסת רכב חברה מוצתה)
            </p>
          )}
          {result.skipped.length > 0 && (
            <p className="muted small">
              דולגו {result.skipped.length}:{' '}
              {result.skipped.map((s) => `${s.asset} ${shortDate(s.date)} (${s.reason === 'EXISTS' ? 'קיים' : 'אין רכב זמין'})`).join(', ')}
            </p>
          )}
          <button className="btn primary block" onClick={onClose}>סגור</button>
        </div>
      ) : (
        <form className="stack" onSubmit={submit}>
          <label className="field">
            <span>תאריך בשבוע</span>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
          </label>
          {monday && <p className="muted small">ייבנו ימים ב'–ו': {shortDate(monday)} – {shortDate(addDays(monday, 4))}. ימים שכבר קיימים ידולגו.</p>}
          <label className="field">
            <span>הקוד שלך (אימות נוסף)</span>
            <input type="password" value={pin} onChange={(e) => setPin(e.target.value)} autoComplete="current-password" required />
          </label>
          {error && <p className="error">{error}</p>}
          <button className="btn primary block" disabled={busy || !pin || !monday}>{busy ? 'מגריל…' : 'הגרל ובנה'}</button>
        </form>
      )}
    </Modal>
  );
}

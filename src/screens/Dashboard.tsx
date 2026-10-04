import { useMemo, useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { addDays, dayName, shortDate, timeOf, todayIso, weekMonday } from '../lib/dates';
import { legLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { AdminTrip, AdminWeek, GenerateResult } from '../lib/types';
import { Modal } from '../components/Modal';
import { StatusChip } from '../components/StatusChip';
import { TripParams } from '../components/TripParams';
import { useStepUp } from '../components/StepUp';
import { TripEditor } from '../components/TripEditor';
import { ConstraintsGrid } from '../components/ConstraintsGrid';
import { PatternReport } from '../components/PatternReport';

export function Dashboard() {
  const { token } = useAuth();
  const [weekStart, setWeekStart] = useState(() => weekMonday(todayIso()));
  const { data, error, loading, reload } = useAsync(() => api.adminWeek(token, weekStart), [token, weekStart]);
  const [generateOpen, setGenerateOpen] = useState(false);
  const [reportOpen, setReportOpen] = useState(false);
  const [editing, setEditing] = useState<AdminTrip | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [expandAll, setExpandAll] = useState(false);
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
      <button className="btn block" onClick={() => setReportOpen(true)}>ניתוח דפוסים</button>

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

      {data && data.trips.length > 0 && (
        <button className="link align-start" onClick={() => setExpandAll((x) => !x)}>
          {expandAll ? 'כווץ את כל המשימות' : 'הצג את כל הפרטים של כל המשימות'}
        </button>
      )}

      {error && <p className="error">{error}</p>}
      {actionError && <p className="error">{actionError}</p>}
      {loading && !data && <p className="muted">טוען…</p>}

      {data && days.map(([date, trips]) => (
        <div key={date} className={`day-group ${date === data.today ? 'today' : ''}`}>
          <h3>{dayName(date)} <span className="muted">{shortDate(date)}</span></h3>
          <DayNotes date={date} trips={trips} week={data} />
          {trips.length === 0 && <p className="muted small">אין נסיעות</p>}
          <div className="stack">
            {trips.map((t) => (
              <AdminTripCard key={t.id} trip={t} open={expandAll || openId === t.id}
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
      {reportOpen && <PatternReport onClose={() => setReportOpen(false)} />}
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
          <span>{trip.asset_id} · {legLabel(trip.leg)} · {vehicleLabel(trip.vehicle_type)}</span>
        </span>
        <StatusChip status={trip.status} />
      </button>
      <p className="muted small workers">
        {trip.workers.map((w) => (w.id === trip.custodian_id ? `${w.name} (אחראי)` : w.name)).join(', ') || '—'}
      </p>
      {open && (
        <div className="task-body stack">
          <TripParams trip={trip} />
          {trip.decoy_trip_id && (
            <p className="muted small">{decoy ? 'פיתוי לקטע אמיתי באותה שעה' : 'יש פיתוי מקושר באותה שעה'}</p>
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
            <button className="btn" onClick={onEdit}>{trip.status !== 'done' ? 'ערוך' : 'הגדרות ניתוח'}</button>
            {trip.status === 'planned' && <button className="btn danger" onClick={onDelete}>מחק</button>}
          </div>
        </div>
      )}
    </article>
  );
}

/** Constraints for the day + warning when a leg runs without the lead driver. */
function DayNotes({ date, trips, week }: { date: string; trips: AdminTrip[]; week: AdminWeek }) {
  const absent = week.absences.filter((a) => a.date === date);
  const blocked = week.vehicle_blocks.filter((b) => b.date === date);
  const leadAbsent = absent.some((a) => week.lead_ids.includes(a.employee_id));
  const legsWithoutLead = trips.filter((t) => t.trip_type === 'real' && !t.decoy_trip_id
    && !t.assigned_workers.some((w) => week.lead_ids.includes(w)));
  return (
    <>
      {absent.length > 0 && <p className="muted small">לא זמינים: {absent.map((a) => a.name).join(', ')}</p>}
      {blocked.length > 0 && <p className="muted small">רכב לא זמין: {blocked.map((b) => vehicleLabel(b.vehicle_type)).join(', ')}</p>}
      {week.lead_ids.length > 0 && !leadAbsent && legsWithoutLead.length > 0 && (
        <p className="error small">⚠ נהג ראשי לא חלק מ: {legsWithoutLead.map((t) => `${t.asset_id} ${legLabel(t.leg)}`).join(', ')}</p>
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
          <p>נוצרו <b>{result.created}</b> קטעים (יציאה/חזרה), ו-<b>{result.decoys}</b> פיתויים.</p>
          {result.fallbacks > 0 && (
            <p className="muted small">{result.fallbacks} קטעים נבחרו כ"הכי פחות חוזרים" (לא נמצא שילוב נקי ב-10 ניסיונות).</p>
          )}
          {result.warnings.length > 0 && (
            <div className="alert stack">
              <strong>⚠ נדרשת תשומת לב</strong>
              {result.warnings.map((w) => <p key={`${w.asset}-${w.date}-${w.reason}`}>{w.message}</p>)}
            </div>
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
          {monday && (
            <section className="constraints stack">
              <h3>מגבלות לשבוע — מי ומה לא זמין</h3>
              <ConstraintsGrid monday={monday} />
            </section>
          )}
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

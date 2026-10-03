import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate } from '../lib/dates';
import { CATEGORY_LABEL, optionLabel, positionLabel, slotLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { AdminTrip, Category, Position, Slot, TripParams } from '../lib/types';
import { Modal } from './Modal';

const SELECT_FIELDS: Category[] = ['vehicle_type', 'exit_point', 'outbound_route', 'factory_entry', 'factory_exit', 'return_route'];

export function TripEditor({ trip, onClose, onSaved }: { trip: AdminTrip; onClose: () => void; onSaved: () => void }) {
  const { token } = useAuth();
  const planned = trip.status === 'planned';
  const { data: settings, error: loadError } = useAsync(() => api.settings(token), [token]);
  const [form, setForm] = useState<TripParams>({
    departure_slot: trip.departure_slot,
    vehicle_type: trip.vehicle_type,
    worker_position: trip.worker_position,
    exit_point: trip.exit_point,
    outbound_route: trip.outbound_route,
    factory_entry: trip.factory_entry,
    factory_exit: trip.factory_exit,
    return_route: trip.return_route,
  });
  const [workers, setWorkers] = useState<string[]>(trip.assigned_workers);
  const [excluded, setExcluded] = useState(trip.excluded_from_analysis);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const set = <K extends keyof TripParams>(k: K, v: TripParams[K]) => setForm((f) => ({ ...f, [k]: v }));
  const isCompany = form.vehicle_type === 'company';

  const options = (cat: Category, current: string) => {
    const values = settings?.config.filter((c) => c.category === cat && c.is_active).map((c) => c.value) ?? [];
    return values.includes(current) ? values : [current, ...values];
  };

  const operators = settings?.employees.filter((e) => e.role === 'operator' && (e.is_active || workers.includes(e.id))) ?? [];

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const payload = planned
        ? { ...form, worker_position: (isCompany ? form.worker_position : 'none') as Position,
            assigned_workers: workers, excluded_from_analysis: excluded }
        : { excluded_from_analysis: excluded };
      await api.updateTrip(token, trip.id, payload);
      onSaved();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal title={`${trip.trip_type === 'decoy' ? 'פיתוי' : 'נסיעה'} ${trip.asset_id} · ${dayName(trip.date)} ${shortDate(trip.date)}`} onClose={onClose}>
      {loadError && <p className="error">{loadError}</p>}
      <form className="stack" onSubmit={submit}>
        {planned && settings && (
          <>
            <label className="field">
              <span>שעת יציאה</span>
              <select value={form.departure_slot} onChange={(e) => set('departure_slot', e.target.value as Slot)}>
                {(['morning', 'noon'] as Slot[]).map((s) => <option key={s} value={s}>{slotLabel(s)}</option>)}
              </select>
            </label>
            {SELECT_FIELDS.map((cat) => (
              <label key={cat} className="field">
                <span>{CATEGORY_LABEL[cat]}</span>
                <select value={form[cat as keyof TripParams]} onChange={(e) => {
                  set(cat as keyof TripParams, e.target.value);
                  // A lead driver only drives the company car: drop them when switching away.
                  if (cat === 'vehicle_type' && e.target.value !== 'company') {
                    const leads = new Set(settings.employees.filter((x) => x.is_lead_driver).map((x) => x.id));
                    setWorkers((w) => w.filter((id) => !leads.has(id)));
                  }
                }}>
                  {options(cat, form[cat as keyof TripParams]).map((v) => (
                    <option key={v} value={v}>{optionLabel(cat, v)}</option>
                  ))}
                </select>
              </label>
            ))}
            {isCompany && (
              <label className="field">
                <span>מיקום עובד</span>
                <select value={form.worker_position === 'none' ? '' : form.worker_position}
                  onChange={(e) => set('worker_position', e.target.value as Position)}>
                  <option value="" disabled>בחר…</option>
                  {(['front', 'back'] as Position[]).map((p) => <option key={p} value={p}>{positionLabel(p)}</option>)}
                </select>
              </label>
            )}
            <fieldset className="field">
              <span>עובדים משובצים</span>
              <div className="checks">
                {operators.map((e) => (
                  <label key={e.id} className="check">
                    <input type="checkbox" checked={workers.includes(e.id)}
                      onChange={(ev) => setWorkers((w) => ev.target.checked ? [...w, e.id] : w.filter((x) => x !== e.id))} />
                    {e.name}{e.is_lead_driver && <span className="chip small">נהג ראשי</span>}
                  </label>
                ))}
              </div>
              {!isCompany && <span className="hint">נהג ראשי נוהג רק ברכב חברה.</span>}
            </fieldset>
          </>
        )}
        {!planned && <p className="muted small">הנסיעה כבר יצאה לדרך — ניתן לשנות רק את ההחרגה מהניתוח.</p>}
        <label className="check">
          <input type="checkbox" checked={excluded} onChange={(e) => setExcluded(e.target.checked)} />
          החרג מניתוח דפוסים (לא תיספר בבדיקת אנטי-מדפסיות)
        </label>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={busy || (planned && !settings)}>{busy ? 'שומר…' : 'שמור'}</button>
      </form>
    </Modal>
  );
}

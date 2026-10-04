import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate } from '../lib/dates';
import { CATEGORY_LABEL, legLabel, optionLabel, positionLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { AdminTrip, Category, Position } from '../lib/types';
import { Modal } from './Modal';

type LegField = 'exit_point' | 'outbound_route' | 'factory_entry' | 'factory_exit' | 'return_route';

const LEG_FIELDS: Record<AdminTrip['leg'], LegField[]> = {
  outbound: ['exit_point', 'outbound_route', 'factory_entry'],
  return: ['factory_exit', 'return_route'],
};

export function TripEditor({ trip, onClose, onSaved }: { trip: AdminTrip; onClose: () => void; onSaved: () => void }) {
  const { token } = useAuth();
  const planned = trip.status === 'planned';
  const isDecoy = trip.trip_type === 'decoy';
  const fields = LEG_FIELDS[trip.leg];
  const { data: settings, error: loadError } = useAsync(() => api.settings(token), [token]);

  const [vehicle, setVehicle] = useState(trip.vehicle_type);
  const [values, setValues] = useState<Record<LegField, string>>(() =>
    Object.fromEntries(fields.map((f) => [f, trip[f] ?? ''])) as Record<LegField, string>);
  const [position, setPosition] = useState<Position>(trip.worker_position);
  const [workers, setWorkers] = useState<string[]>(trip.assigned_workers);
  const [custodian, setCustodian] = useState(trip.custodian_id ?? '');
  const [excluded, setExcluded] = useState(trip.excluded_from_analysis);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isCompany = vehicle === 'company';
  // Legs that run with a decoy (the decoy, or the real leg linked to one) use decoy-safe options only.
  const decoyLeg = isDecoy || !!trip.decoy_trip_id;

  // Options usable with the given vehicle class (company-only values are hidden for other vehicles).
  const allowed = (cat: Category, company: boolean) =>
    settings?.config
      .filter((c) => c.category === cat && c.is_active && (company || !c.company_only)
        && (cat === 'vehicle_type' || !decoyLeg || c.decoy_ok))
      .map((c) => c.value) ?? [];

  const options = (cat: Category, current: string) => {
    const list = cat === 'vehicle_type' ? allowed(cat, true) : allowed(cat, isCompany);
    return list.includes(current) ? list : [current, ...list];
  };

  const changeVehicle = (next: string) => {
    const company = next === 'company';
    setVehicle(next);
    // Replace values that are not allowed for the new vehicle class.
    setValues((v) => {
      const out = { ...v };
      for (const f of fields) {
        const ok = allowed(f, company);
        if (ok.length && !ok.includes(out[f])) out[f] = ok[0];
      }
      return out;
    });
    // A lead driver only drives the company car: drop them when switching away.
    if (!company && settings) {
      const leads = new Set(settings.employees.filter((x) => x.is_lead_driver).map((x) => x.id));
      setWorkers((w) => w.filter((id) => !leads.has(id)));
    }
  };

  // Changing the custodian swaps them in this leg (the server also updates the other leg).
  const changeCustodian = (next: string) => {
    setWorkers((w) => [...new Set(w.map((id) => (id === custodian ? next : id)).concat(next))]);
    setCustodian(next);
  };

  const people = settings?.employees.filter((e) => e.is_active || workers.includes(e.id)) ?? [];
  const custodianOptions = settings?.employees.filter((e) => e.is_active && !e.is_lead_driver) ?? [];

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const payload = planned
        ? {
            vehicle_type: vehicle,
            ...values,
            worker_position: isCompany ? position : ('none' as Position),
            assigned_workers: workers,
            ...(isDecoy || custodian === trip.custodian_id ? {} : { custodian_id: custodian }),
            excluded_from_analysis: excluded,
          }
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
    <Modal
      title={`${isDecoy ? 'פיתוי' : legLabel(trip.leg)} ${trip.asset_id} · ${dayName(trip.date)} ${shortDate(trip.date)}`}
      onClose={onClose}
    >
      {loadError && <p className="error">{loadError}</p>}
      <form className="stack" onSubmit={submit}>
        {planned && settings && (
          <>
            <label className="field">
              <span>{CATEGORY_LABEL.vehicle_type}</span>
              <select value={vehicle} onChange={(e) => changeVehicle(e.target.value)}>
                {options('vehicle_type', vehicle).map((v) => (
                  <option key={v} value={v}>{optionLabel('vehicle_type', v)}</option>
                ))}
              </select>
            </label>
            {fields.map((f) => (
              <label key={f} className="field">
                <span>{CATEGORY_LABEL[f]}</span>
                <select value={values[f]} onChange={(e) => setValues((v) => ({ ...v, [f]: e.target.value }))}>
                  {options(f, values[f]).map((v) => <option key={v} value={v}>{v}</option>)}
                </select>
              </label>
            ))}
            {!isDecoy && (
              <label className="field">
                <span>אחראי מוצר (לכל היום — מתעדכן גם בקטע השני)</span>
                <select value={custodian} onChange={(e) => changeCustodian(e.target.value)}>
                  {custodianOptions.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
                </select>
              </label>
            )}
            {isCompany && !isDecoy && (
              <label className="field">
                <span>מיקום עובד</span>
                <select value={position === 'none' ? '' : position} onChange={(e) => setPosition(e.target.value as Position)}>
                  <option value="" disabled>בחר…</option>
                  {(['front', 'back'] as Position[]).map((p) => <option key={p} value={p}>{positionLabel(p)}</option>)}
                </select>
              </label>
            )}
            <fieldset className="field">
              <span>משובצים בקטע</span>
              <div className="checks">
                {people.map((e) => (
                  <label key={e.id} className="check">
                    <input type="checkbox" checked={workers.includes(e.id)} disabled={e.id === custodian && !isDecoy}
                      onChange={(ev) => setWorkers((w) => ev.target.checked ? [...w, e.id] : w.filter((x) => x !== e.id))} />
                    {e.name}
                    {e.id === custodian && !isDecoy && <span className="chip small gold">אחראי</span>}
                    {e.is_lead_driver && <span className="chip small">נהג ראשי</span>}
                    {e.role === 'admin' && <span className="chip small">מנהל</span>}
                  </label>
                ))}
              </div>
              <span className="hint">
                {isDecoy
                  ? 'בפיתוי הנהג הראשי יוצא לבד.'
                  : isCompany
                    ? 'נהג ראשי לא יוצא לבד עם המוצר — אחראי המוצר תמיד איתו.'
                    : 'נהג ראשי נוהג רק ברכב חברה.'}
              </span>
            </fieldset>
          </>
        )}
        {planned && decoyLeg && (
          <p className="hint">קטע עם פיתוי — מוצגות רק אפשרויות שמותרות בפיתוי (חניון מקורה בכניסה וביציאה).</p>
        )}
        {!planned && <p className="muted small">הקטע כבר יצא לדרך — ניתן לשנות רק את ההחרגה מהניתוח.</p>}
        <label className="check">
          <input type="checkbox" checked={excluded} onChange={(e) => setExcluded(e.target.checked)} />
          החרג מניתוח דפוסים (לא ייספר בבדיקת אנטי-מדפסיות)
        </label>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={busy || (planned && !settings)}>{busy ? 'שומר…' : 'שמור'}</button>
      </form>
    </Modal>
  );
}

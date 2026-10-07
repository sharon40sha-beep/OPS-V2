import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate } from '../lib/dates';
import { CATEGORY_LABEL, placeLabel, slotLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { AdminTrip, Category, DecoyParent } from '../lib/types';
import { Modal } from './Modal';
import { PlacePicker, PointSelect, WARNING_TEXT } from './ManualTripEditor';

const PARENT_POINTS = ['exit_point', 'outbound_route', 'factory_entry', 'factory_exit', 'return_route'] as const;

/**
 * Admin attaches a decoy to a planned task (manual or regular), or edits a
 * manual decoy. It leaves at the same time and opens / closes together with
 * the task. Only points marked "allowed in decoy" — for both vehicles.
 */
export function DecoyEditor({ parent, decoy, onClose, onSaved }: {
  parent: DecoyParent; decoy: AdminTrip | null; onClose: () => void; onSaved: () => void;
}) {
  const { token } = useAuth();
  const { data: settings, error: loadError } = useAsync(() => api.settings(token), [token]);

  const defaultFrom = parent.origin ?? (parent.leg === 'outbound' ? 'warehouse' : 'factory');
  const defaultTo = parent.destination ?? (parent.leg === 'outbound' ? 'factory' : 'warehouse');
  const [time, setTime] = useState((decoy?.planned_time ?? parent.planned_time)?.slice(0, 5) ?? '');
  const [origin, setOrigin] = useState(decoy?.origin ?? defaultFrom);
  const [destination, setDestination] = useState(decoy?.destination ?? defaultTo);
  const [vehicle, setVehicle] = useState(decoy?.vehicle_type ?? 'company');
  const [workers, setWorkers] = useState<string[] | null>(decoy?.assigned_workers ?? null);
  const [exitPoint, setExitPoint] = useState(decoy?.exit_point ?? '');
  const [factoryEntry, setFactoryEntry] = useState(decoy?.factory_entry ?? '');
  const [factoryExit, setFactoryExit] = useState(decoy?.factory_exit ?? '');
  const [routeNote, setRouteNote] = useState(decoy?.route_note ?? '');
  const [note, setNote] = useState(decoy?.manual_note ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [warnings, setWarnings] = useState<string[] | null>(null);

  // Default crew: the lead driver(s).
  const crew = workers ?? settings?.employees.filter((e) => e.is_active && e.is_lead_driver).map((e) => e.id) ?? [];
  const isCompany = vehicle === 'company';
  const options = (cat: Category) =>
    settings?.config.filter((c) => c.category === cat && c.is_active && c.decoy_ok && (isCompany || !c.company_only))
      .map((c) => c.value) ?? [];
  const sites = settings?.config.filter((c) => c.category === 'external_site' && c.is_active).map((c) => c.value) ?? [];
  const people = settings?.employees.filter((e) => e.is_active || crew.includes(e.id)) ?? [];

  // The task's own points must be allowed in decoy too (checked again in the server).
  const unsafe = settings
    ? PARENT_POINTS.filter((cat) => {
        const v = parent[cat];
        return v && settings.config.some((c) => c.category === cat && c.value === v && !c.decoy_ok);
      })
    : [];

  const needExit = origin === 'warehouse';
  const needEntry = destination === 'factory';
  const needFactoryExit = origin === 'factory';
  const valid = unsafe.length === 0 && origin.trim() && destination.trim() && origin.trim() !== destination.trim()
    && vehicle && crew.length > 0
    && (!needExit || exitPoint) && (!needEntry || factoryEntry) && (!needFactoryExit || factoryExit);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!valid) return;
    setBusy(true);
    setError(null);
    try {
      const res = await api.saveDecoy(token, parent.id, {
        time: time || null, origin: origin.trim(), destination: destination.trim(), vehicle, workers: crew,
        exitPoint: needExit ? exitPoint : null, factoryEntry: needEntry ? factoryEntry : null,
        factoryExit: needFactoryExit ? factoryExit : null, routeNote, note,
      });
      onSaved();
      if (res.warnings.length) setWarnings(res.warnings.map((w) => WARNING_TEXT[w.code](w.detail)));
      else onClose();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  if (warnings) {
    return (
      <Modal title="הפיתוי נשמר" onClose={onClose}>
        <div className="stack">
          <p className="small">שים לב:</p>
          <ul className="warnings">{warnings.map((w) => <li key={w}>⚠ {w}</li>)}</ul>
          <button className="btn primary block" onClick={onClose}>הבנתי</button>
        </div>
      </Modal>
    );
  }

  const parentWhen = `${slotLabel(parent.departure_slot)}${parent.planned_time ? ` ${parent.planned_time.slice(0, 5)}` : ''}`;
  const parentRoute = parent.origin
    ? `${placeLabel(parent.origin)} ← ${placeLabel(parent.destination)}`
    : parent.leg === 'outbound' ? 'יציאה (מחסן ← מפעל)' : 'חזרה (מפעל ← מחסן)';

  return (
    <Modal title={decoy ? 'עריכת פיתוי' : 'פיתוי חדש'} onClose={onClose}>
      <p className="hint">
        למשימה {parent.asset_id} · {parentRoute} · {dayName(parent.date)} {shortDate(parent.date)} · {parentWhen}.
        הפיתוי נפתח ונסגר אוטומטית יחד איתה.
      </p>
      {loadError && <p className="error">{loadError}</p>}
      {!settings && !loadError && <p className="muted">טוען…</p>}
      {settings && unsafe.length > 0 && (
        <p className="error">
          למשימה יש אפשרויות שאסורות בפיתוי: {unsafe.map((c) => `${CATEGORY_LABEL[c]} "${parent[c]}"`).join(', ')}.
          שנה אותן במשימה (ערוך) ואז הוסף פיתוי.
        </p>
      )}
      {settings && (
        <form className="stack" onSubmit={submit}>
          <label className="field">
            <span>שעה מדויקת (רשות — ברירת מחדל כמו המשימה)</span>
            <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
          </label>
          <div className="row">
            <PlacePicker label="מ-" value={origin} sites={sites} onChange={setOrigin} />
            <PlacePicker label="ל-" value={destination} sites={sites} onChange={setDestination} />
          </div>
          {origin.trim() && origin.trim() === destination.trim() && <p className="error small">המוצא והיעד זהים</p>}
          <label className="field">
            <span>סוג רכב</span>
            <select value={vehicle} onChange={(e) => {
              setVehicle(e.target.value);
              setExitPoint(''); setFactoryEntry(''); setFactoryExit('');
            }}>
              {settings.config.filter((c) => c.category === 'vehicle_type' && c.is_active).map((c) => (
                <option key={c.value} value={c.value}>{vehicleLabel(c.value)}</option>
              ))}
            </select>
          </label>
          {needExit && <PointSelect label="יציאה מהמחסן" value={exitPoint} values={options('exit_point')} onChange={setExitPoint} />}
          {needFactoryExit && <PointSelect label="יציאה מהמפעל" value={factoryExit} values={options('factory_exit')} onChange={setFactoryExit} />}
          {needEntry && <PointSelect label="כניסה למפעל" value={factoryEntry} values={options('factory_entry')} onChange={setFactoryEntry} />}
          <fieldset className="field">
            <span>צוות הפיתוי</span>
            <div className="checks">
              {people.map((e) => (
                <label key={e.id} className="check">
                  <input type="checkbox" checked={crew.includes(e.id)}
                    onChange={(ev) => setWorkers(ev.target.checked ? [...crew, e.id] : crew.filter((x) => x !== e.id))} />
                  {e.name}
                  {e.is_lead_driver && <span className="chip small">נהג ראשי</span>}
                </label>
              ))}
            </div>
          </fieldset>
          <label className="field">
            <span>מסלול (רשות)</span>
            <input value={routeNote} maxLength={500} onChange={(e) => setRouteNote(e.target.value)} />
          </label>
          <label className="field">
            <span>הנחיות (רשות)</span>
            <textarea rows={2} value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
          </label>
          <p className="hint">מוצגות רק נקודות שמסומנות "מותר בפיתוי". פיתויים לא נכנסים לניתוח הדפוסים.</p>
          {error && <p className="error">{error}</p>}
          <button className="btn primary block" disabled={busy || !valid}>{busy ? 'שומר…' : 'שמור פיתוי'}</button>
        </form>
      )}
    </Modal>
  );
}

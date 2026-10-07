import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, parseDate, shortDate } from '../lib/dates';
import { POSITION_CODES, placeLabel, positionLabel, slotLabel, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { AdminTrip, Category, DecoyParent, Position, SaveManualResult, Slot } from '../lib/types';
import { Modal } from './Modal';

const SLOTS: Slot[] = ['morning', 'noon', 'evening'];
const NEW_PLACE = '__new__';

export const WARNING_TEXT: Record<SaveManualResult['warnings'][number]['code'], (d: string | null) => string> = {
  LEAD_NOT_ASSIGNED: () => 'הנהג הראשי לא משובץ במשימה',
  VEHICLE_BUSY: () => 'הרכב כבר משובץ למשימה אחרת באותו זמן',
  WORKER_BUSY: (d) => `${d} כבר משובץ למשימה אחרת באותו זמן`,
  BUDGET_EXHAUSTED: () => 'מכסת הרכב לחודש נוצלה',
  DECOY_CAP: (d) => `כבר היו ${d} פיתויים ב-10 הקטעים האחרונים של הנכס (המכסה: 5)`,
};

/**
 * Admin adds / edits a manual task: any origin → destination (warehouse,
 * factory or an external site), crew and free-text route. Warehouse and
 * factory points are picked from the lists so the engine can count them.
 */
export function ManualTripEditor({ trip, defaultDate, onClose, onSaved, onAddDecoy }: {
  trip: AdminTrip | null; defaultDate: string; onClose: () => void; onSaved: () => void;
  /** Called when the admin chooses to attach a decoy to the task just created. */
  onAddDecoy: (parent: DecoyParent) => void;
}) {
  const { token } = useAuth();
  const { data: settings, error: loadError } = useAsync(() => api.settings(token), [token]);

  const [asset, setAsset] = useState(trip?.asset_id ?? '');
  const [date, setDate] = useState(trip?.date ?? defaultDate);
  const [slot, setSlot] = useState<Slot>(trip?.departure_slot ?? 'morning');
  const [time, setTime] = useState(trip?.planned_time?.slice(0, 5) ?? '');
  const [origin, setOrigin] = useState(trip?.origin ?? 'warehouse');
  const [destination, setDestination] = useState(trip?.destination ?? '');
  const [vehicle, setVehicle] = useState(trip?.vehicle_type ?? '');
  const [workers, setWorkers] = useState<string[]>(trip?.assigned_workers ?? []);
  const [custodian, setCustodian] = useState(trip?.custodian_id ?? '');
  const [position, setPosition] = useState<Position>(trip?.worker_position ?? 'none');
  const [exitPoint, setExitPoint] = useState(trip?.exit_point ?? '');
  const [factoryEntry, setFactoryEntry] = useState(trip?.factory_entry ?? '');
  const [factoryExit, setFactoryExit] = useState(trip?.factory_exit ?? '');
  const [routeNote, setRouteNote] = useState(trip?.route_note ?? '');
  const [note, setNote] = useState(trip?.manual_note ?? '');
  const [excluded, setExcluded] = useState(trip?.excluded_from_analysis ?? false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [warnings, setWarnings] = useState<string[] | null>(null);
  // Set after creating a task: asks whether to attach a decoy.
  const [created, setCreated] = useState<DecoyParent | null>(null);

  const isCompany = vehicle === 'company';
  const options = (cat: Category) =>
    settings?.config.filter((c) => c.category === cat && c.is_active && (isCompany || !c.company_only)).map((c) => c.value) ?? [];
  const sites = options('external_site');
  const assets = settings?.assets.filter((a) => a.is_active || a.id === asset) ?? [];
  const people = settings?.employees.filter((e) => e.is_active || workers.includes(e.id)) ?? [];
  const weekday = date ? parseDate(date).getDay() : 0;
  const weekdayOk = weekday >= 1 && weekday <= 5;

  const needExit = origin === 'warehouse';
  const needEntry = destination === 'factory';
  const needFactoryExit = origin === 'factory';

  const valid = asset && date && weekdayOk && origin.trim() && destination.trim() && origin.trim() !== destination.trim()
    && vehicle && workers.length > 0
    && (!needExit || exitPoint) && (!needEntry || factoryEntry) && (!needFactoryExit || factoryExit);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!valid) return;
    setBusy(true);
    setError(null);
    try {
      const res = await api.saveManualTrip(token, trip?.id ?? null, {
        asset, date, slot, time: time || null, origin: origin.trim(), destination: destination.trim(), vehicle, workers,
        custodian: custodian && workers.includes(custodian) ? custodian : null,
        position: isCompany ? position : 'none',
        exitPoint: needExit ? exitPoint : null,
        factoryEntry: needEntry ? factoryEntry : null,
        factoryExit: needFactoryExit ? factoryExit : null,
        routeNote, note, excluded,
      });
      onSaved();
      const list = res.warnings.map((w) => WARNING_TEXT[w.code](w.detail));
      if (!trip) {
        setWarnings(list);
        setCreated({
          id: res.id, asset_id: asset, date, leg: origin === 'factory' || (origin !== 'warehouse' && destination === 'warehouse') ? 'return' : 'outbound',
          departure_slot: slot, planned_time: time || null, trip_type: 'manual', origin, destination,
          exit_point: needExit ? exitPoint : null, outbound_route: null, factory_entry: needEntry ? factoryEntry : null,
          factory_exit: needFactoryExit ? factoryExit : null, return_route: null,
        });
      } else if (list.length) setWarnings(list);
      else onClose();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  const changeVehicle = (v: string) => {
    setVehicle(v);
    if (v !== 'company') {
      // Company-only points are not allowed for other vehicles.
      const ok = (cat: Category, val: string) =>
        settings?.config.some((c) => c.category === cat && c.value === val && c.is_active && !c.company_only);
      if (exitPoint && !ok('exit_point', exitPoint)) setExitPoint('');
      if (factoryEntry && !ok('factory_entry', factoryEntry)) setFactoryEntry('');
      if (factoryExit && !ok('factory_exit', factoryExit)) setFactoryExit('');
    }
  };

  if (warnings) {
    return (
      <Modal title="המשימה נשמרה" onClose={onClose}>
        <div className="stack">
          {warnings.length > 0 && (
            <>
              <p className="small">שים לב:</p>
              <ul className="warnings">{warnings.map((w) => <li key={w}>⚠ {w}</li>)}</ul>
            </>
          )}
          {created ? (
            <>
              <p><b>לשייך משימת פיתוי?</b></p>
              <p className="hint">הפיתוי יוצא באותו זמן ונפתח ונסגר אוטומטית יחד עם המשימה.</p>
              <div className="row">
                <button className="btn primary grow" onClick={() => onAddDecoy(created)}>כן, הוסף פיתוי</button>
                <button className="btn grow" onClick={onClose}>לא</button>
              </div>
            </>
          ) : (
            <button className="btn primary block" onClick={onClose}>הבנתי</button>
          )}
        </div>
      </Modal>
    );
  }

  return (
    <Modal title={trip ? 'עריכת משימה מיוחדת' : 'משימה מיוחדת חדשה'} onClose={onClose}>
      {loadError && <p className="error">{loadError}</p>}
      {!settings && !loadError && <p className="muted">טוען…</p>}
      {settings && (
        <form className="stack" onSubmit={submit}>
          <div className="row">
            <label className="field grow">
              <span>נכס</span>
              <select value={asset} onChange={(e) => setAsset(e.target.value)} required>
                <option value="" disabled>בחר…</option>
                {assets.map((a) => <option key={a.id} value={a.id}>{a.id}</option>)}
              </select>
            </label>
            <label className="field grow">
              <span>תאריך {date && weekdayOk && <span className="muted">({dayName(date)} {shortDate(date)})</span>}</span>
              <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
            </label>
          </div>
          {date && !weekdayOk && <p className="error small">רק ימים ב'–ו'</p>}

          <div className="row">
            <label className="field grow">
              <span>זמן</span>
              <select value={slot} onChange={(e) => setSlot(e.target.value as Slot)}>
                {SLOTS.map((s) => <option key={s} value={s}>{slotLabel(s)}</option>)}
              </select>
            </label>
            <label className="field grow">
              <span>שעה מדויקת (רשות)</span>
              <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
            </label>
          </div>

          <div className="row">
            <PlacePicker label="מ-" value={origin} sites={sites} onChange={setOrigin} />
            <PlacePicker label="ל-" value={destination} sites={sites} onChange={setDestination} />
          </div>
          {origin.trim() && origin.trim() === destination.trim() && <p className="error small">המוצא והיעד זהים</p>}

          <label className="field">
            <span>סוג רכב</span>
            <select value={vehicle} onChange={(e) => changeVehicle(e.target.value)} required>
              <option value="" disabled>בחר…</option>
              {options('vehicle_type').map((v) => <option key={v} value={v}>{vehicleLabel(v)}</option>)}
            </select>
          </label>

          {needExit && (
            <PointSelect label="יציאה מהמחסן" value={exitPoint} values={options('exit_point')} onChange={setExitPoint} />
          )}
          {needFactoryExit && (
            <PointSelect label="יציאה מהמפעל" value={factoryExit} values={options('factory_exit')} onChange={setFactoryExit} />
          )}
          {needEntry && (
            <PointSelect label="כניסה למפעל" value={factoryEntry} values={options('factory_entry')} onChange={setFactoryEntry} />
          )}

          <fieldset className="field">
            <span>צוות</span>
            <div className="checks">
              {people.map((e) => (
                <label key={e.id} className="check">
                  <input type="checkbox" checked={workers.includes(e.id)}
                    onChange={(ev) => setWorkers((w) => ev.target.checked ? [...w, e.id] : w.filter((x) => x !== e.id))} />
                  {e.name}
                  {e.is_lead_driver && <span className="chip small">נהג ראשי</span>}
                  {e.role === 'admin' && <span className="chip small">מנהל</span>}
                </label>
              ))}
            </div>
          </fieldset>

          <div className="row">
            <label className="field grow">
              <span>אחראי מוצר (רשות)</span>
              <select value={workers.includes(custodian) ? custodian : ''} onChange={(e) => setCustodian(e.target.value)}>
                <option value="">ללא</option>
                {people.filter((e) => workers.includes(e.id)).map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
              </select>
            </label>
            {isCompany && (
              <label className="field grow">
                <span>מיקום עובד</span>
                <select value={position} onChange={(e) => setPosition(e.target.value as Position)}>
                  <option value="none">—</option>
                  {POSITION_CODES.map((p) => <option key={p} value={p}>{positionLabel(p)}</option>)}
                </select>
              </label>
            )}
          </div>

          <label className="field">
            <span>מסלול (רשות)</span>
            <input value={routeNote} maxLength={500} onChange={(e) => setRouteNote(e.target.value)} />
          </label>
          <label className="field">
            <span>הנחיות לצוות (רשות)</span>
            <textarea rows={2} value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
          </label>
          <label className="check">
            <input type="checkbox" checked={excluded} onChange={(e) => setExcluded(e.target.checked)} />
            החרג מניתוח דפוסים
          </label>
          <p className="hint">
            הרכב, היציאה מהמחסן והכניסה/יציאה מהמפעל נספרים בשקלול נגד מדפסיות. הצד של מתקן החוץ נשמר להיסטוריה בלבד.
            "רענן שבוע" לא משנה משימות מיוחדות.
          </p>
          {error && <p className="error">{error}</p>}
          <button className="btn primary block" disabled={busy || !valid}>{busy ? 'שומר…' : 'שמור'}</button>
        </form>
      )}
    </Modal>
  );
}

export function PlacePicker({ label, value, sites, onChange }: {
  label: string; value: string; sites: string[]; onChange: (v: string) => void;
}) {
  const known = value === '' || value === 'warehouse' || value === 'factory' || sites.includes(value);
  const [typing, setTyping] = useState(!known);
  return (
    <label className="field grow">
      <span>{label}</span>
      {typing ? (
        <div className="row">
          <input className="grow" value={value} autoFocus maxLength={80} placeholder="שם המתקן"
            onChange={(e) => onChange(e.target.value)} />
          <button type="button" className="btn small ghost" onClick={() => { setTyping(false); onChange(''); }}>רשימה</button>
        </div>
      ) : (
        <select value={value} required onChange={(e) => {
          if (e.target.value === NEW_PLACE) { setTyping(true); onChange(''); } else onChange(e.target.value);
        }}>
          <option value="" disabled>בחר…</option>
          <option value="warehouse">{placeLabel('warehouse')}</option>
          <option value="factory">{placeLabel('factory')}</option>
          {sites.map((s) => <option key={s} value={s}>{s}</option>)}
          <option value={NEW_PLACE}>+ מתקן חוץ חדש…</option>
        </select>
      )}
    </label>
  );
}

export function PointSelect({ label, value, values, onChange }: {
  label: string; value: string; values: string[]; onChange: (v: string) => void;
}) {
  return (
    <label className="field">
      <span>{label}</span>
      <select value={value} required onChange={(e) => onChange(e.target.value)}>
        <option value="" disabled>בחר…</option>
        {values.map((v) => <option key={v} value={v}>{v}</option>)}
      </select>
    </label>
  );
}

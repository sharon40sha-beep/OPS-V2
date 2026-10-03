import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { shortDate, dayName, timeOf, todayIso } from '../lib/dates';
import { CATEGORIES, CATEGORY_LABEL, PIN_POLICY_TEXT, optionLabel, pinPolicyOk, vehicleLabel } from '../lib/labels';
import { useAsync } from '../lib/useAsync';
import type { Category, EmployeeRow, Settings as SettingsData } from '../lib/types';
import { Modal } from '../components/Modal';
import { useStepUp } from '../components/StepUp';

type Section = 'employees' | 'assets' | 'config' | 'budget';
const SECTIONS: [Section, string][] = [
  ['employees', 'עובדים'],
  ['assets', 'נכסים'],
  ['config', 'אפשרויות'],
  ['budget', 'מכסות'],
];

export function Settings() {
  const { token } = useAuth();
  const { data, error, reload } = useAsync(() => api.settings(token), [token]);
  const [section, setSection] = useState<Section>('employees');

  return (
    <section className="screen">
      <header className="screen-head"><h1>הגדרות</h1></header>
      <div className="segmented" role="tablist">
        {SECTIONS.map(([key, label]) => (
          <button key={key} role="tab" aria-selected={section === key}
            className={section === key ? 'active' : ''} onClick={() => setSection(key)}>{label}</button>
        ))}
      </div>
      {error && <p className="error">{error}</p>}
      {data && section === 'employees' && <Employees data={data} reload={reload} />}
      {data && section === 'assets' && <Assets data={data} reload={reload} />}
      {data && section === 'config' && <Config data={data} reload={reload} />}
      {data && section === 'budget' && <Budget data={data} reload={reload} />}
    </section>
  );
}

interface SectionProps {
  data: SettingsData;
  reload: () => Promise<void>;
}

/** Runs a mutation, reloads settings, and reports errors. */
function useMutation(reload: () => Promise<void>) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      await reload();
      return true;
    } catch (e) {
      setError(errorText(e));
      return false;
    } finally {
      setBusy(false);
    }
  };
  return { run, error, busy };
}

// ---------------------------------------------------------------- employees

function Employees({ data, reload }: SectionProps) {
  const { token } = useAuth();
  const [editing, setEditing] = useState<EmployeeRow | 'new' | null>(null);
  const [absencesFor, setAbsencesFor] = useState<EmployeeRow | null>(null);
  const { run, error } = useMutation(reload);
  const stepUp = useStepUp();

  const unlock = async (e: EmployeeRow) => {
    const pin = await stepUp.ask(`שחרור נעילה עבור ${e.name}`);
    if (pin) await run(() => api.unlockAccount(token, pin, e.id));
  };

  return (
    <div className="stack">
      <button className="btn primary" onClick={() => setEditing('new')}>+ עובד חדש</button>
      {error && <p className="error">{error}</p>}
      {data.employees.map((e) => (
        <div key={e.id} className={`card list-row ${e.is_active ? '' : 'inactive'}`}>
          <div className="list-main">
            <strong>{e.name}</strong>
            <div className="tags">
              <span className="chip">{e.role === 'admin' ? 'מנהל' : 'מפעיל'}</span>
              {e.is_lead_driver && <span className="chip gold">נהג ראשי</span>}
              {!e.is_active && <span className="chip">מושבת</span>}
              {e.locked_until && <span className="chip status-problem">נעול עד {timeOf(e.locked_until)}</span>}
            </div>
          </div>
          <div className="row">
            {e.locked_until && <button className="btn small" onClick={() => unlock(e)}>שחרר</button>}
            <button className="btn small" onClick={() => setAbsencesFor(e)}>
              היעדרויות{countUpcoming(data, e.id) ? ` (${countUpcoming(data, e.id)})` : ''}
            </button>
            <button className="btn small" onClick={() => setEditing(e)}>ערוך</button>
          </div>
        </div>
      ))}
      {editing && (
        <EmployeeForm employee={editing === 'new' ? null : editing} isSelf={editing !== 'new' && editing.id === data.me}
          onClose={() => setEditing(null)} onSaved={() => { setEditing(null); void reload(); }} />
      )}
      {absencesFor && (
        <AbsencesModal employee={absencesFor} data={data} reload={reload} onClose={() => setAbsencesFor(null)} />
      )}
      {stepUp.element}
    </div>
  );
}

const countUpcoming = (data: SettingsData, employeeId: string) =>
  data.absences.filter((a) => a.employee_id === employeeId && a.date >= todayIso()).length;

function AbsencesModal({ employee, data, reload, onClose }: SectionProps & { employee: EmployeeRow; onClose: () => void }) {
  const { token } = useAuth();
  const { run, error, busy } = useMutation(reload);
  const [date, setDate] = useState(todayIso());
  const [note, setNote] = useState('');
  const list = data.absences.filter((a) => a.employee_id === employee.id);

  const add = async (e: FormEvent) => {
    e.preventDefault();
    if (await run(() => api.setAbsence(token, employee.id, date, true, note))) setNote('');
  };

  return (
    <Modal title={`היעדרויות · ${employee.name}`} onClose={onClose}>
      <p className="hint">
        עובד שמסומן כנעדר לא ישובץ בהגרלה לאותו יום. סמן לפני "בנה שבוע" —
        נסיעות שכבר נבנו יש לערוך ידנית.
      </p>
      {error && <p className="error">{error}</p>}
      {list.length === 0 && <p className="muted small">אין היעדרויות מתוכננות</p>}
      {list.map((a) => (
        <div key={a.date} className="card list-row">
          <span className="grow">יום {dayName(a.date)} {shortDate(a.date)}{a.note ? ` · ${a.note}` : ''}</span>
          <button className="btn small" disabled={busy}
            onClick={() => run(() => api.setAbsence(token, employee.id, a.date, false))}>הסר</button>
        </div>
      ))}
      <form className="stack" onSubmit={add}>
        <div className="row">
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required className="grow" />
          <input placeholder="סיבה (רשות)" value={note} onChange={(e) => setNote(e.target.value)} className="grow" />
        </div>
        <button className="btn primary" disabled={busy || !date}>סמן היעדרות</button>
      </form>
    </Modal>
  );
}

function EmployeeForm({ employee, isSelf, onClose, onSaved }: {
  employee: EmployeeRow | null; isSelf: boolean; onClose: () => void; onSaved: () => void;
}) {
  const { token } = useAuth();
  const [name, setName] = useState(employee?.name ?? '');
  const [role, setRole] = useState(employee?.role ?? 'operator');
  const [lead, setLead] = useState(employee?.is_lead_driver ?? false);
  const [active, setActive] = useState(employee?.is_active ?? true);
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (pin && !pinPolicyOk(pin)) {
      setError(`הקוד לא עומד במדיניות: ${PIN_POLICY_TEXT}`);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.saveEmployee(token, { id: employee?.id ?? null, name, role, is_lead_driver: lead, is_active: active, pin });
      onSaved();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal title={employee ? `עריכת ${employee.name}` : 'עובד חדש'} onClose={onClose}>
      <form className="stack" onSubmit={submit}>
        <label className="field"><span>שם (משמש להתחברות)</span>
          <input value={name} onChange={(e) => setName(e.target.value)} required />
        </label>
        <label className="field"><span>תפקיד</span>
          <select value={role} disabled={isSelf} onChange={(e) => setRole(e.target.value as EmployeeRow['role'])}>
            <option value="operator">מפעיל</option>
            <option value="admin">מנהל</option>
          </select>
        </label>
        {role === 'operator' && (
          <label className="check">
            <input type="checkbox" checked={lead} onChange={(e) => setLead(e.target.checked)} />
            נהג ראשי (נוהג רק ברכב חברה)
          </label>
        )}
        {!isSelf && (
          <label className="check">
            <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />
            פעיל
          </label>
        )}
        <label className="field"><span>{employee ? 'קוד חדש (ריק = ללא שינוי)' : 'קוד'}</span>
          <input type="password" value={pin} onChange={(e) => setPin(e.target.value)} autoComplete="new-password"
            minLength={6} required={!employee} />
          <span className="hint">{PIN_POLICY_TEXT}</span>
        </label>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={busy}>{busy ? 'שומר…' : 'שמור'}</button>
      </form>
    </Modal>
  );
}

// ---------------------------------------------------------------- assets

function Assets({ data, reload }: SectionProps) {
  const { token } = useAuth();
  const { run, error, busy } = useMutation(reload);
  const [id, setId] = useState('');
  const [warehouse, setWarehouse] = useState('');
  const [edits, setEdits] = useState<Record<string, string>>({});

  const add = async (e: FormEvent) => {
    e.preventDefault();
    if (data.assets.some((a) => a.id === id.trim())) return;
    if (await run(() => api.saveAsset(token, id.trim(), warehouse, true))) {
      setId('');
      setWarehouse('');
    }
  };

  return (
    <div className="stack">
      {error && <p className="error">{error}</p>}
      {data.assets.map((a) => {
        const value = edits[a.id] ?? a.home_warehouse;
        return (
          <div key={a.id} className={`card list-row ${a.is_active ? '' : 'inactive'}`}>
            <strong className="asset-id">{a.id}</strong>
            <input className="grow" value={value} aria-label="מחסן בית"
              onChange={(e) => setEdits({ ...edits, [a.id]: e.target.value })} />
            <div className="row">
              {value !== a.home_warehouse && (
                <button className="btn small primary" disabled={busy}
                  onClick={() => run(() => api.saveAsset(token, a.id, value, a.is_active))}>שמור</button>
              )}
              <button className="btn small" disabled={busy}
                onClick={() => run(() => api.saveAsset(token, a.id, a.home_warehouse, !a.is_active))}>
                {a.is_active ? 'השבת' : 'הפעל'}
              </button>
            </div>
          </div>
        );
      })}
      <form className="card stack" onSubmit={add}>
        <h3>נכס חדש</h3>
        <div className="row">
          <input placeholder="מזהה (A2)" value={id} onChange={(e) => setId(e.target.value)}
            pattern="[A-Za-z0-9_\-]{1,20}" required className="narrow" dir="ltr" />
          <input placeholder="מחסן בית" value={warehouse} onChange={(e) => setWarehouse(e.target.value)} required className="grow" />
        </div>
        <button className="btn primary" disabled={busy}>הוסף</button>
      </form>
    </div>
  );
}

// ---------------------------------------------------------------- config options

function Config({ data, reload }: SectionProps) {
  const [category, setCategory] = useState<Category>('exit_point');
  return (
    <div className="stack">
      <label className="field">
        <span>קטגוריה</span>
        <select value={category} onChange={(e) => setCategory(e.target.value as Category)}>
          {CATEGORIES.map((c) => <option key={c} value={c}>{CATEGORY_LABEL[c]}</option>)}
        </select>
      </label>
      <ConfigCategory key={category} category={category} data={data} reload={reload} />
    </div>
  );
}

function ConfigCategory({ category, data, reload }: SectionProps & { category: Category }) {
  const { token } = useAuth();
  const { run, error, busy } = useMutation(reload);
  const [newValue, setNewValue] = useState('');
  const [edits, setEdits] = useState<Record<string, string>>({});
  const rows = data.config.filter((c) => c.category === category);
  // Codes with fixed meaning in the algorithm must not be renamed.
  const fixedCodes = category === 'vehicle_type' || category === 'worker_position';

  const add = async (e: FormEvent) => {
    e.preventDefault();
    if (await run(() => api.saveConfig(token, null, category, newValue, true, false))) setNewValue('');
  };

  return (
    <>
      {fixedCodes && (
        <p className="hint">
          {category === 'vehicle_type'
            ? 'הקודים company / rental / delivery משמשים את מנוע ההגרלה. ניתן להשבית; קוד חדש יוגרל כרכב רגיל.'
            : 'ערכים אפשריים: front / back.'}
        </p>
      )}
      {error && <p className="error">{error}</p>}
      {rows.map((c) => {
        const value = edits[c.id] ?? c.value;
        return (
          <div key={c.id} className={`card list-row ${c.is_active ? '' : 'inactive'}`}>
            {fixedCodes ? (
              <span className="grow">{optionLabel(category, c.value)} <span className="muted small" dir="ltr">({c.value})</span></span>
            ) : (
              <input className="grow" value={value} aria-label="ערך"
                onChange={(e) => setEdits({ ...edits, [c.id]: e.target.value })} />
            )}
            <div className="row">
              {value !== c.value && (
                <button className="btn small primary" disabled={busy}
                  onClick={() => run(() => api.saveConfig(token, c.id, category, value, c.is_active, c.company_only))}>שמור</button>
              )}
              {!fixedCodes && (
                <button className={`btn small ${c.company_only ? 'primary' : ''}`} disabled={busy}
                  title="אפשרות זו תוגרל/תותר רק ברכב חברה"
                  onClick={() => run(() => api.saveConfig(token, c.id, category, c.value, c.is_active, !c.company_only))}>
                  {c.company_only ? 'רק רכב חברה ✓' : 'רק רכב חברה'}
                </button>
              )}
              <button className="btn small" disabled={busy}
                onClick={() => run(() => api.saveConfig(token, c.id, category, c.value, !c.is_active, c.company_only))}>
                {c.is_active ? 'השבת' : 'הפעל'}
              </button>
            </div>
          </div>
        );
      })}
      <form className="row" onSubmit={add}>
        <input className="grow" placeholder="ערך חדש" value={newValue} onChange={(e) => setNewValue(e.target.value)} required />
        <button className="btn primary" disabled={busy}>הוסף</button>
      </form>
    </>
  );
}

// ---------------------------------------------------------------- vehicle budget

function Budget({ data, reload }: SectionProps) {
  const { token } = useAuth();
  const { run, error, busy } = useMutation(reload);
  const vehicles = data.config.filter((c) => c.category === 'vehicle_type').map((c) => c.value);
  const [edits, setEdits] = useState<Record<string, string>>({});

  return (
    <div className="stack">
      <p className="hint">מכסה חודשית לכל סוג רכב (כולל פיתויים). ריק = ללא הגבלה. כשהמכסה מוצתה, הרכב לא יוגרל עד סוף החודש.</p>
      {error && <p className="error">{error}</p>}
      {vehicles.map((v) => {
        const row = data.budget.find((b) => b.vehicle_type === v);
        const saved = row?.max_per_month == null ? '' : String(row.max_per_month);
        const value = edits[v] ?? saved;
        return (
          <div key={v} className="card list-row">
            <div className="list-main">
              <strong>{vehicleLabel(v)}</strong>
              <span className="muted small">החודש: {row?.current_month_count ?? 0}{row?.max_per_month != null && ` / ${row.max_per_month}`}</span>
            </div>
            <input type="number" min={0} inputMode="numeric" className="narrow" placeholder="∞" value={value}
              onChange={(e) => setEdits({ ...edits, [v]: e.target.value })} aria-label="מכסה חודשית" />
            {value !== saved && (
              <button className="btn small primary" disabled={busy}
                onClick={() => run(() => api.saveBudget(token, v, value === '' ? null : Number(value)))}>שמור</button>
            )}
          </div>
        );
      })}
    </div>
  );
}

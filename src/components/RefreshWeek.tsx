import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate, TZ } from '../lib/dates';
import { useAsync } from '../lib/useAsync';
import type { RefreshAction, RefreshResult } from '../lib/types';
import { Modal } from './Modal';

const ACTION_LABEL: Record<RefreshAction, string> = {
  full: 'יוגרל מחדש במלואו',
  return_only: 'רק החזרה: ציר + יציאה מהמפעל (רכב וצוות נשארים)',
  create: 'ייווצר (אין עדיין משימות)',
  locked: 'לא ישתנה (כבר התחיל / בוצע)',
};

/**
 * Admin "refresh week": shows exactly which days/legs will be redrawn, then
 * runs the refresh after re-entering the admin PIN. All-or-nothing on the server.
 */
export function RefreshWeekModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { token } = useAuth();
  const [includeToday, setIncludeToday] = useState(false);
  const [includeNext, setIncludeNext] = useState(false);
  const [reason, setReason] = useState('');
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<RefreshResult | null>(null);
  const preview = useAsync(() => api.refreshPreview(token, includeToday, includeNext), [token, includeToday, includeNext]);

  const items = preview.data?.items ?? [];
  const changing = items.filter((i) => i.action !== 'locked');

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      setResult(await api.refreshWeek(token, pin, includeToday, includeNext, reason));
      onDone();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
      setPin('');
    }
  };

  if (result) {
    return (
      <Modal title="רענון שבוע — בוצע" onClose={onClose}>
        <div className="stack">
          <p>הוחלפו <b>{result.replaced}</b> משימות (נשמרו בהיסטוריה), נוצרו <b>{result.created}</b> קטעים ו-<b>{result.decoys}</b> פיתויים.</p>
          {result.warnings.length > 0 && (
            <div className="alert stack">
              <strong>⚠ נדרשת תשומת לב</strong>
              {result.warnings.map((w, i) => <p key={i}>{w.message}</p>)}
            </div>
          )}
          <p className="muted small">העובדים שהמשימות שלהם השתנו יראו סימון "עודכן" על הימים האלה.</p>
          <button className="btn primary block" onClick={onClose}>סגור</button>
        </div>
      </Modal>
    );
  }

  return (
    <Modal title="רענון שבוע" onClose={onClose}>
      <form className="stack" onSubmit={submit}>
        <p className="hint">
          ברירת מחדל: מחר עד סוף השבוע. משימות שהתחילו או בוצעו לא משתנות. התוכנית שבוטלה נשמרת בהיסטוריה,
          וכל יום שמוגרל מחדש יהיה שונה ממנה ב-4 משתנים לפחות.
        </p>
        <label className="check">
          <input type="checkbox" checked={includeToday} onChange={(e) => setIncludeToday(e.target.checked)} />
          כולל היום (רק משימות שעוד לא התחילו)
        </label>
        <label className="check">
          <input type="checkbox" checked={includeNext} onChange={(e) => setIncludeNext(e.target.checked)} />
          צור / רענן גם את השבוע הבא
        </label>

        <div className="card stack">
          <strong>מה ישתנה</strong>
          {preview.loading && !preview.data && <p className="muted small">טוען…</p>}
          {preview.error && <p className="error">{preview.error}</p>}
          {preview.data && items.length === 0 && <p className="muted small">אין ימים בטווח.</p>}
          <table className="mini">
            <tbody>
              {items.map((i) => (
                <tr key={`${i.date}-${i.asset}`} className={i.action === 'locked' ? 'muted' : ''}>
                  <td>{dayName(i.date)} {shortDate(i.date)}</td>
                  <td>{i.asset}</td>
                  <td>{ACTION_LABEL[i.action]}{i.legs > 0 ? ` · ${i.legs} משימות יוחלפו` : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <label className="field">
          <span>סיבה (רשות — נשמרת ביומן)</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} />
        </label>
        <label className="field">
          <span>הקוד שלך (אימות נוסף)</span>
          <input type="password" value={pin} onChange={(e) => setPin(e.target.value)} autoComplete="current-password" required />
        </label>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={busy || !pin || changing.length === 0}>
          {busy ? 'מרענן…' : `אשר ורענן (${changing.length} ימים/נכסים)`}
        </button>
      </form>
    </Modal>
  );
}

/** Append-only refresh history. */
export function RefreshLog({ version }: { version: number }) {
  const { token } = useAuth();
  const { data, error } = useAsync(() => api.refreshLog(token), [token, version]);
  if (error) return <p className="error">{error}</p>;
  if (!data || data.length === 0) return null;
  return (
    <details className="card refresh-log">
      <summary>יומן רענונים ({data.length})</summary>
      <table className="mini">
        <tbody>
          {data.map((l) => (
            <tr key={l.id}>
              <td>{new Date(l.created_at).toLocaleString('he-IL', { dateStyle: 'short', timeStyle: 'short', timeZone: TZ })}</td>
              <td>{l.admin}</td>
              <td>
                {l.range_from && l.range_to ? `${shortDate(l.range_from)}–${shortDate(l.range_to)}` : ''}
                {' · '}הוחלפו {l.replaced}
                {l.reason ? ` · ${l.reason}` : ''}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </details>
  );
}

import { useState } from 'react';
import { fromLocalInput, toLocalInput } from '../lib/dates';
import { DELAY_REASON_LABEL } from '../lib/labels';
import type { DelayReason } from '../lib/types';

export interface CloseDetails {
  reason: DelayReason | null;
  note: string;
  /** ISO time, only for "forgot" */
  actualTime: string | null;
}

const REASONS = Object.keys(DELAY_REASON_LABEL) as DelayReason[];


/**
 * Delay reason for a leg that ran over 90 minutes. "שכחתי לסגור" asks for the
 * real return time, which is saved instead of the click time.
 */
export function CloseLegForm({ startAt, busy, onSubmit, onCancel, askActualTime = true, submitLabel = 'סיום משימה' }: {
  startAt: string;
  busy: boolean;
  /** Admin enters the finish time directly, so there is no separate "actual time" question. */
  askActualTime?: boolean;
  submitLabel?: string;
  onSubmit: (d: CloseDetails) => void;
  onCancel: () => void;
}) {
  const [reason, setReason] = useState<DelayReason | null>(null);
  const [note, setNote] = useState('');
  const [actual, setActual] = useState(() => toLocalInput(new Date()));
  const valid = reason !== null && (reason !== 'other' || note.trim() !== '') && (reason !== 'forgot' || !askActualTime || actual !== '');

  return (
    <div className="stack close-form">
      <p className="small"><b>המשימה נמשכה מעל שעה וחצי.</b> מה הסיבה?</p>
      <div className="checks">
        {REASONS.map((r) => (
          <label key={r} className="check">
            <input type="radio" name="delay" checked={reason === r} onChange={() => setReason(r)} />
            {DELAY_REASON_LABEL[r]}
          </label>
        ))}
      </div>
      {reason === 'forgot' && askActualTime && (
        <label className="field">
          <span>מתי חזרתם בפועל?</span>
          <input type="datetime-local" value={actual} min={toLocalInput(new Date(startAt))} max={toLocalInput(new Date())}
            onChange={(e) => setActual(e.target.value)} />
        </label>
      )}
      <label className="field">
        <span>{reason === 'other' ? 'פירוט (חובה)' : 'פירוט (רשות)'}</span>
        <textarea rows={2} value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
      </label>
      <div className="row">
        <button className="btn primary" disabled={busy || !valid}
          onClick={() => onSubmit({
            reason, note,
            actualTime: reason === 'forgot' && askActualTime ? fromLocalInput(actual) : null,
          })}>
          {submitLabel}
        </button>
        <button className="btn ghost" onClick={onCancel}>ביטול</button>
      </div>
    </div>
  );
}

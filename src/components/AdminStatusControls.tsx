import { useState } from 'react';
import { ApiError, api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { LONG_LEG_MINUTES } from '../lib/labels';
import type { AdminTrip } from '../lib/types';
import { fromLocalInput, toLocalInput } from '../lib/dates';
import { CloseLegForm, type CloseDetails } from './CloseLegForm';

/**
 * Admin: start / finish any leg, or correct its times. A finish more than 90
 * minutes after the start needs a reason (same rule as for workers).
 * A decoy follows its real leg, so only real legs get controls.
 */
export function AdminStatusControls({ trip, onChanged }: { trip: AdminTrip; onChanged: () => void }) {
  const { token } = useAuth();
  const [start, setStart] = useState(() => toLocalInput(trip.actual_start_at ? new Date(trip.actual_start_at) : new Date()));
  const [end, setEnd] = useState(() => toLocalInput(trip.actual_done_at ? new Date(trip.actual_done_at) : new Date()));
  const [askReason, setAskReason] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (trip.trip_type === 'decoy') {
    return <p className="hint">הפיתוי נפתח ונסגר אוטומטית יחד עם הקטע האמיתי.</p>;
  }

  const started = !!trip.actual_start_at;
  const send = async (action: 'start' | 'done', local: string, close?: CloseDetails) => {
    setBusy(true);
    setError(null);
    try {
      const time = fromLocalInput(local);
      await api.adminSetStatus(token, trip.id, action, time, close?.reason, close?.note,
        close?.reason === 'forgot' ? time : null);
      setAskReason(false);
      onChanged();
    } catch (e) {
      if (e instanceof ApiError && e.code === 'DELAY_REASON_REQUIRED') setAskReason(true);
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const finish = () => {
    const long = trip.actual_start_at
      && new Date(fromLocalInput(end)).getTime() - new Date(trip.actual_start_at).getTime() > LONG_LEG_MINUTES * 60000;
    if (long) setAskReason(true);
    else void send('done', end);
  };

  return (
    <div className="stack admin-status">
      <div className="row time-row">
        <label className="field">
          <span>{started ? 'שעת יציאה' : 'פתיחת משימה'}</span>
          <input type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} />
        </label>
        <button className="btn" disabled={busy || !start} onClick={() => send('start', start)}>
          {started ? 'עדכן יציאה' : 'התחל משימה'}
        </button>
      </div>
      {started && (
        <div className="row time-row">
          <label className="field">
            <span>{trip.actual_done_at ? 'שעת חזרה' : 'סגירת משימה'}</span>
            <input type="datetime-local" value={end} onChange={(e) => { setEnd(e.target.value); setAskReason(false); }} />
          </label>
          <button className="btn primary" disabled={busy || !end || askReason} onClick={finish}>
            {trip.actual_done_at ? 'עדכן חזרה' : 'סיים משימה'}
          </button>
        </div>
      )}
      {askReason && trip.actual_start_at && (
        <CloseLegForm startAt={trip.actual_start_at} busy={busy} askActualTime={false} submitLabel="שמור סיום"
          onSubmit={(d) => send('done', end, d)} onCancel={() => setAskReason(false)} />
      )}
      {error && <p className="error">{error}</p>}
    </div>
  );
}

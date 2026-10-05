import { timeOf } from '../lib/dates';
import { DELAY_REASON_LABEL, durationLabel } from '../lib/labels';
import type { LegTimes } from '../lib/types';

/** "יצא 07:42 · חזר 09:10 · 1:28" + delay reason + admin-correction flag. */
export function LegTimesLine({ times }: { times: LegTimes }) {
  if (!times.actual_start_at && !times.actual_done_at) return null;
  return (
    <p className="times-line small">
      {times.actual_start_at && <span>יצא {timeOf(times.actual_start_at)}</span>}
      {times.actual_done_at && <span> · חזר {timeOf(times.actual_done_at)}</span>}
      {times.actual_start_at && times.actual_done_at && (
        <span className="muted"> · {durationLabel(times.actual_start_at, times.actual_done_at)} שעות</span>
      )}
      {times.delay_reason && (
        <span className="chip delay-chip">
          {DELAY_REASON_LABEL[times.delay_reason]}{times.delay_note ? `: ${times.delay_note}` : ''}
        </span>
      )}
      {times.times_by_admin && <span className="muted"> · עודכן ע״י מנהל</span>}
    </p>
  );
}

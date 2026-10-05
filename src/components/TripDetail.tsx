import type { WorkerTripDetail } from '../lib/types';
import { LegTimesLine } from './LegTimesLine';
import { TripParams } from './TripParams';

/** Read-only view of one of the worker's own legs: route, partners, times, notes. */
export function TripDetail({ detail }: { detail: WorkerTripDetail }) {
  return (
    <div className="stack">
      {detail.is_custodian && <p className="note">אתה אחראי המוצר ביום הזה — יציאה וחזרה.</p>}
      <TripParams trip={detail} />
      <p className="small">
        <span className="muted">שותפים לנסיעה: </span>
        {detail.partners.length === 0
          ? 'אין'
          : detail.partners.map((p) => (p.is_custodian ? `${p.name} (אחראי)` : p.name)).join(', ')}
      </p>
      <LegTimesLine times={detail} />
      {detail.problem_note && (
        <p className={detail.status === 'problem' ? 'problem-note' : 'note'}>
          {detail.status === 'problem' ? 'בעיה' : 'הערה'}: {detail.problem_note}
        </p>
      )}
    </div>
  );
}

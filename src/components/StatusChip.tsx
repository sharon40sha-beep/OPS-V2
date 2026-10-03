import { STATUS_LABEL } from '../lib/labels';
import type { TripStatus } from '../lib/types';

export function StatusChip({ status }: { status: TripStatus }) {
  return <span className={`chip status-${status}`}>{STATUS_LABEL[status]}</span>;
}

import type { TripParams as Params } from '../lib/types';
import { positionLabel, slotLabel, vehicleLabel } from '../lib/labels';

export function TripParams({ trip }: { trip: Params }) {
  const rows: [string, string][] = [
    ['שעת יציאה', slotLabel(trip.departure_slot)],
    ['סוג רכב', vehicleLabel(trip.vehicle_type)],
    ['נקודת יציאה', trip.exit_point],
    ['ציר יציאה', trip.outbound_route],
    ['כניסה למפעל', trip.factory_entry],
    ['יציאה מהמפעל', trip.factory_exit],
    ['ציר חזרה', trip.return_route],
  ];
  if (trip.vehicle_type === 'company' && trip.worker_position !== 'none') {
    rows.splice(2, 0, ['מיקום עובד', positionLabel(trip.worker_position)]);
  }
  return (
    <dl className="params">
      {rows.map(([k, v]) => (
        <div key={k}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

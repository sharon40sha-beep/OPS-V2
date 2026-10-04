import type { TripParams as Params } from '../lib/types';
import { legLabel, positionLabel, slotLabel, vehicleLabel } from '../lib/labels';

export function TripParams({ trip }: { trip: Params }) {
  const rows: [string, string | null][] = [
    ['קטע', `${legLabel(trip.leg)} (${slotLabel(trip.departure_slot)})`],
    ['סוג רכב', vehicleLabel(trip.vehicle_type)],
    ['מיקום עובד', trip.vehicle_type === 'company' && trip.worker_position !== 'none' ? positionLabel(trip.worker_position) : null],
    ['נקודת יציאה', trip.exit_point],
    ['ציר יציאה', trip.outbound_route],
    ['כניסה למפעל', trip.factory_entry],
    ['יציאה מהמפעל', trip.factory_exit],
    ['ציר חזרה', trip.return_route],
  ];
  return (
    <dl className="params">
      {rows.filter((r): r is [string, string] => r[1] !== null).map(([k, v]) => (
        <div key={k}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

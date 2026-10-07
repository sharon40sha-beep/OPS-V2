import type { TripParams as Params } from '../lib/types';
import { legLabel, placeLabel, positionLabel, slotLabel, vehicleLabel } from '../lib/labels';

export function TripParams({ trip }: { trip: Params }) {
  // Manual tasks and manual decoys carry origin → destination.
  const manual = !!trip.origin;
  const when = `${slotLabel(trip.departure_slot)}${trip.planned_time ? ` ${trip.planned_time.slice(0, 5)}` : ''}`;
  const rows: [string, string | null][] = manual ? [
    ['משימה', `${placeLabel(trip.origin)} ← ${placeLabel(trip.destination)}`],
    ['שעה', when],
    ['סוג רכב', vehicleLabel(trip.vehicle_type)],
    ['מיקום עובד', trip.vehicle_type === 'company' && trip.worker_position !== 'none' ? positionLabel(trip.worker_position) : null],
    ['יציאה מהמחסן', trip.exit_point],
    ['כניסה למפעל', trip.factory_entry],
    ['יציאה מהמפעל', trip.factory_exit],
    ['מסלול', trip.route_note ?? null],
    ['הנחיות', trip.manual_note ?? null],
  ] : [
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

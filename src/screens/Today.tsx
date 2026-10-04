import { useState } from 'react';
import { api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate, timeOf, todayIso } from '../lib/dates';
import { useAsync } from '../lib/useAsync';
import type { WorkerTask, WorkerTripDetail } from '../lib/types';
import { StatusChip } from '../components/StatusChip';
import { TripParams } from '../components/TripParams';

export function Today() {
  const { token } = useAuth();
  const { data: tasks, error, loading, reload } = useAsync(() => api.workerToday(token), [token]);
  const [openId, setOpenId] = useState<string | null>(null);
  const today = todayIso();

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>היום שלי</h1>
        <span className="muted">יום {dayName(today)} · {shortDate(today)}</span>
      </header>
      {error && <p className="error">{error}</p>}
      {loading && !tasks && <p className="muted">טוען…</p>}
      {tasks && tasks.length === 0 && <div className="empty card">אין משימה היום</div>}
      <div className="stack">
        {tasks?.map((t) => (
          <TaskCard key={t.id} task={t} open={openId === t.id}
            onToggle={() => setOpenId(openId === t.id ? null : t.id)} onChanged={reload} />
        ))}
      </div>
    </section>
  );
}

function TaskCard({ task, open, onToggle, onChanged }: {
  task: WorkerTask; open: boolean; onToggle: () => void; onChanged: () => Promise<void>;
}) {
  const { token } = useAuth();
  const [detail, setDetail] = useState<WorkerTripDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<'problem' | 'note' | null>(null);
  const [note, setNote] = useState('');

  const loadDetail = async () => {
    try {
      setDetail(await api.workerTripDetail(token, task.id));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  };

  const toggle = () => {
    if (!open) void loadDetail();
    onToggle();
  };

  const act = async (action: 'start' | 'done' | 'problem' | 'note') => {
    setBusy(true);
    setError(null);
    try {
      await api.workerSetStatus(token, task.id, action, action === 'problem' || action === 'note' ? note : undefined);
      setMode(null);
      setNote('');
      await Promise.all([onChanged(), loadDetail()]);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const status = detail?.status ?? task.status;

  return (
    <article className={`card task ${open ? 'open' : ''}`}>
      <button className="task-head" onClick={toggle} aria-expanded={open}>
        <span className="task-label">{task.label}</span>
        <StatusChip status={status} />
      </button>

      {open && (
        <div className="task-body stack">
          {error && <p className="error">{error}</p>}
          {!detail && !error && <p className="muted">טוען…</p>}
          {detail && (
            <>
              {detail.is_custodian && <p className="note">אתה אחראי המוצר היום — יציאה וחזרה.</p>}
              <TripParams trip={detail} />
              {(detail.actual_start_at || detail.actual_done_at) && (
                <p className="muted small">
                  {detail.actual_start_at && `יציאה ${timeOf(detail.actual_start_at)}`}
                  {detail.actual_done_at && ` · חזרה ${timeOf(detail.actual_done_at)}`}
                </p>
              )}
              {detail.problem_note && (
                <p className={status === 'problem' ? 'problem-note' : 'note'}>
                  {status === 'problem' ? 'בעיה' : 'הערה'}: {detail.problem_note}
                </p>
              )}

              {status !== 'done' && !mode && (
                <div className="actions">
                  {status === 'planned' && (
                    <button className="btn primary big" disabled={busy} onClick={() => act('start')}>יצאתי</button>
                  )}
                  {(status === 'active' || status === 'problem') && (
                    <button className="btn primary big" disabled={busy} onClick={() => act('done')}>חזרתי</button>
                  )}
                  <button className="btn danger" disabled={busy} onClick={() => setMode('problem')}>יש בעיה</button>
                </div>
              )}

              {!mode && (
                <button className="link align-start" onClick={() => setMode('note')}>+ הוסף הערה</button>
              )}

              {mode && (
                <div className="stack">
                  <label className="field">
                    <span>{mode === 'problem' ? 'מה הבעיה?' : 'הערה (הסטטוס לא ישתנה)'}</span>
                    <textarea rows={3} value={note} autoFocus maxLength={1000}
                      onChange={(e) => setNote(e.target.value)} />
                  </label>
                  {mode === 'note' && !note && (
                    <button className="chip gold align-start" onClick={() => setNote('בוצע במקום המנהל – ')}>
                      בוצע במקום המנהל
                    </button>
                  )}
                  <div className="row">
                    <button className={`btn ${mode === 'problem' ? 'danger' : 'primary'}`} disabled={busy || !note.trim()}
                      onClick={() => act(mode)}>
                      {mode === 'problem' ? 'שלח דיווח' : 'שמור הערה'}
                    </button>
                    <button className="btn ghost" onClick={() => { setMode(null); setNote(''); }}>ביטול</button>
                  </div>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </article>
  );
}

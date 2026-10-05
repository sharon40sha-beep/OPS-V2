import { useState } from 'react';
import { ApiError, api, errorText } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dayName, shortDate, todayIso } from '../lib/dates';
import { useAsync } from '../lib/useAsync';
import type { WorkerTask, WorkerTripDetail } from '../lib/types';
import { StatusChip } from '../components/StatusChip';
import { TripDetail } from '../components/TripDetail';
import { CloseLegForm, type CloseDetails } from '../components/CloseLegForm';
import { LONG_LEG_MINUTES } from '../lib/labels';

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
  const [mode, setMode] = useState<'problem' | 'note' | 'close' | null>(null);
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

  const act = async (action: 'start' | 'done' | 'problem' | 'note', close?: CloseDetails) => {
    setBusy(true);
    setError(null);
    try {
      await api.workerSetStatus(token, task.id, action,
        action === 'problem' || action === 'note' ? note : close?.note,
        close?.reason, close?.actualTime);
      setMode(null);
      setNote('');
      await Promise.all([onChanged(), loadDetail()]);
    } catch (e) {
      // Server clock says the leg is long even though the device did not: ask for the reason.
      if (e instanceof ApiError && e.code === 'DELAY_REASON_REQUIRED' && !close) setMode('close');
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const status = detail?.status ?? task.status;

  // Over 90 minutes since leaving → ask for the reason before closing (enforced again in the server).
  const finish = () => {
    const start = detail?.actual_start_at;
    if (start && Date.now() - new Date(start).getTime() > LONG_LEG_MINUTES * 60000) setMode('close');
    else void act('done');
  };

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
              <TripDetail detail={detail} />

              {status !== 'done' && !mode && (
                <div className="actions">
                  {status === 'planned' && (
                    <button className="btn primary big" disabled={busy} onClick={() => act('start')}>יצאתי</button>
                  )}
                  {(status === 'active' || status === 'problem') && (
                    <button className="btn primary big" disabled={busy} onClick={finish}>חזרתי</button>
                  )}
                  <button className="btn danger" disabled={busy} onClick={() => setMode('problem')}>יש בעיה</button>
                </div>
              )}

              {!mode && (
                <button className="link align-start" onClick={() => setMode('note')}>+ הוסף הערה</button>
              )}

              {mode === 'close' && detail.actual_start_at && (
                <CloseLegForm startAt={detail.actual_start_at} busy={busy}
                  onSubmit={(d) => act('done', d)} onCancel={() => setMode(null)} />
              )}

              {(mode === 'problem' || mode === 'note') && (
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

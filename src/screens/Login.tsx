import { useState, type FormEvent } from 'react';
import { api, errorText } from '../lib/api';
import type { StoredSession } from '../lib/session';

export function Login({ onLogin, notice }: { onLogin: (s: StoredSession) => void; notice: string | null }) {
  const [name, setName] = useState('');
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const res = await api.login(name, pin);
      onLogin({ token: res.token, me: res.employee });
    } catch (err) {
      setError(errorText(err));
      setPin('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login">
      <div className="brand">
        <div className="brand-mark" aria-hidden />
        <h1>OPS</h1>
      </div>
      <form className="card stack" onSubmit={submit}>
        {notice && <p className="notice">{notice}</p>}
        <label className="field">
          <span>שם</span>
          <input value={name} onChange={(e) => setName(e.target.value)} autoComplete="username" required />
        </label>
        <label className="field">
          <span>קוד</span>
          <input type="password" value={pin} onChange={(e) => setPin(e.target.value)}
            autoComplete="current-password" required />
        </label>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={busy || !name || !pin}>
          {busy ? 'מתחבר…' : 'כניסה'}
        </button>
      </form>
    </div>
  );
}

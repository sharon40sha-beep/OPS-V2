import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { api, setSessionInvalidHandler } from './lib/api';
import { AuthContext, type Auth } from './lib/auth';
import { clearSession, loadSession, saveSession, type StoredSession } from './lib/session';
import { Login } from './screens/Login';
import { Today } from './screens/Today';
import { Week } from './screens/Week';
import { Dashboard } from './screens/Dashboard';
import { Settings } from './screens/Settings';

type Tab = 'today' | 'week' | 'dashboard' | 'settings';

const TABS: { key: Tab; label: string; icon: string; admin: boolean }[] = [
  { key: 'today', label: 'היום', icon: '◉', admin: false },
  { key: 'week', label: 'השבוע', icon: '▦', admin: false },
  { key: 'dashboard', label: 'בקרה', icon: '◈', admin: true },
  { key: 'settings', label: 'הגדרות', icon: '⚙', admin: true },
];

/**
 * How long the app may stay hidden before the session is cleared.
 * Safari on iOS fires spurious visibilitychange events (keyboard, share sheet,
 * password autofill), so we only log out after a sustained hide.
 */
const HIDDEN_GRACE_MS = 3000;

export function App() {
  const [session, setSession] = useState<StoredSession | null>(loadSession);
  const [notice, setNotice] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>(() => (loadSession()?.me.role === 'admin' ? 'dashboard' : 'today'));

  const sessionRef = useRef(session);
  sessionRef.current = session;

  const endSession = useCallback((message: string | null) => {
    const current = sessionRef.current;
    if (current) void api.logout(current.token).catch(() => undefined);
    sessionRef.current = null;
    clearSession();
    setSession(null);
    setNotice(message);
  }, []);

  const login = (s: StoredSession) => {
    saveSession(s);
    setSession(s);
    setNotice(null);
    setTab(s.me.role === 'admin' ? 'dashboard' : 'today');
  };

  useEffect(() => {
    setSessionInvalidHandler(() => endSession('הסשן הסתיים, יש להתחבר מחדש'));
    return () => setSessionInvalidHandler(null);
  }, [endSession]);

  // Re-validate a restored session once (e.g. after a reload).
  const token = session?.token;
  useEffect(() => {
    if (token) void api.me(token).catch(() => undefined);
  }, [token]);

  // Clear the session when the app is backgrounded, debounced for Safari mobile.
  // Timers are frozen while iOS suspends the page, so the elapsed time is also
  // checked when the page becomes visible again.
  useEffect(() => {
    if (!token) return;
    let hiddenAt: number | null = null;
    let timer: number | undefined;
    const expire = () => endSession('התנתקת אוטומטית כי האפליקציה עברה לרקע');

    const onVisibility = () => {
      if (document.visibilityState === 'hidden') {
        hiddenAt = Date.now();
        window.clearTimeout(timer);
        timer = window.setTimeout(expire, HIDDEN_GRACE_MS);
      } else {
        window.clearTimeout(timer);
        if (hiddenAt !== null && Date.now() - hiddenAt >= HIDDEN_GRACE_MS) expire();
        hiddenAt = null;
      }
    };
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      window.clearTimeout(timer);
    };
  }, [token, endSession]);

  const auth = useMemo<Auth | null>(
    () => (session ? { token: session.token, me: session.me, logout: () => endSession(null) } : null),
    [session, endSession],
  );

  if (!auth) return <Login onLogin={login} notice={notice} />;

  const isAdmin = auth.me.role === 'admin';
  const tabs = TABS.filter((t) => isAdmin || !t.admin);
  const active = tabs.some((t) => t.key === tab) ? tab : 'today';

  return (
    <AuthContext.Provider value={auth}>
      <div className="app">
        <div className="topbar">
          <span className="who">{auth.me.name}</span>
          <button className="link" onClick={auth.logout}>יציאה</button>
        </div>
        <main>
          {active === 'today' && <Today />}
          {active === 'week' && <Week />}
          {active === 'dashboard' && <Dashboard />}
          {active === 'settings' && <Settings />}
        </main>
        <nav className="bottom-nav" style={{ gridTemplateColumns: `repeat(${tabs.length}, 1fr)` }}>
          {tabs.map((t) => (
            <button key={t.key} className={active === t.key ? 'active' : ''} onClick={() => setTab(t.key)}>
              <span className="nav-icon" aria-hidden>{t.icon}</span>
              <span>{t.label}</span>
            </button>
          ))}
        </nav>
      </div>
    </AuthContext.Provider>
  );
}

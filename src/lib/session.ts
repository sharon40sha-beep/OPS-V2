import type { Me } from './types';

// sessionStorage: survives a reload of the same tab, dies with the tab.
const KEY = 'ops2.session';

export interface StoredSession {
  token: string;
  me: Me;
}

export function loadSession(): StoredSession | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as StoredSession) : null;
  } catch {
    return null;
  }
}

export function saveSession(s: StoredSession): void {
  try {
    sessionStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    // Private mode: the session simply won't survive a reload.
  }
}

export function clearSession(): void {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}

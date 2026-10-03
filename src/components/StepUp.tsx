import { useCallback, useRef, useState, type FormEvent } from 'react';
import { Modal } from './Modal';

/**
 * Step-up PIN prompt for sensitive admin actions.
 * `ask(title)` resolves with the PIN, or null if cancelled.
 */
export function useStepUp() {
  const [title, setTitle] = useState<string | null>(null);
  const [pin, setPin] = useState('');
  const resolver = useRef<((pin: string | null) => void) | null>(null);

  const ask = useCallback((t: string) => {
    setPin('');
    setTitle(t);
    return new Promise<string | null>((resolve) => {
      resolver.current = resolve;
    });
  }, []);

  const finish = (value: string | null) => {
    resolver.current?.(value);
    resolver.current = null;
    setTitle(null);
    setPin('');
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (pin) finish(pin);
  };

  const element = title ? (
    <Modal title="אימות נוסף" onClose={() => finish(null)}>
      <form onSubmit={submit} className="stack">
        <p className="muted">{title}</p>
        <label className="field">
          <span>הקוד שלך</span>
          <input type="password" autoFocus autoComplete="current-password" value={pin}
            onChange={(e) => setPin(e.target.value)} />
        </label>
        <p className="hint">3 ניסיונות שגויים ינעלו את החשבון ל-30 דקות.</p>
        <div className="row">
          <button type="submit" className="btn primary" disabled={!pin}>אישור</button>
          <button type="button" className="btn ghost" onClick={() => finish(null)}>ביטול</button>
        </div>
      </form>
    </Modal>
  ) : null;

  return { ask, element };
}

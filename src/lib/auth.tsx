import { createContext, useContext } from 'react';
import type { Me } from './types';

export interface Auth {
  token: string;
  me: Me;
  logout: () => void;
}

export const AuthContext = createContext<Auth | null>(null);

export function useAuth(): Auth {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth outside AuthContext');
  return ctx;
}

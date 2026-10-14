'use client';

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

const STORAGE_KEY = 'moppity_global_month';

export type YearMonth = string; // 'YYYY-MM'

function pad(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

export function previousMonthIso(now: Date = new Date()): YearMonth {
  // JC-337: default = previous complete calendar month
  const d = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`;
}

export function formatYearMonth(ym: YearMonth): string {
  // 'mmm-yy' e.g. '2026-03' → 'Mar-26'
  const [y, m] = ym.split('-').map(Number);
  if (!y || !m) return ym;
  const d = new Date(y, m - 1, 1);
  const month = d.toLocaleString('en-AU', { month: 'short' });
  const yy = String(y).slice(-2);
  return `${month}-${yy}`;
}

export function listRecentMonths(count: number = 24, anchor: Date = new Date()): YearMonth[] {
  const out: YearMonth[] = [];
  for (let i = 1; i <= count; i++) {
    const d = new Date(anchor.getFullYear(), anchor.getMonth() - i, 1);
    out.push(`${d.getFullYear()}-${pad(d.getMonth() + 1)}`);
  }
  return out;
}

interface GlobalMonthContextValue {
  month: YearMonth;
  setMonth: (m: YearMonth) => void;
  resetToDefault: () => void;
  isDefault: boolean;
  hydrated: boolean;
}

const GlobalMonthContext = createContext<GlobalMonthContextValue | null>(null);

export function GlobalMonthProvider({ children }: { children: React.ReactNode }) {
  // REACT-HYDRATION-CLEANUP-P1.5: do NOT seed `defaultMonth` from `new Date()`
  // at render time — that value differs between server (Node UTC at build/SSR)
  // and client (browser local TZ at request), causing #425/#418 hydration
  // mismatches in any descendant that renders `month` (e.g. <select value=...>).
  // Instead, start with empty string on both sides, then compute the real
  // default + load localStorage in useEffect after mount.
  const [month, setMonthState] = useState<YearMonth>('');
  const [defaultMonth, setDefaultMonth] = useState<YearMonth>('');
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    const computedDefault = previousMonthIso();
    setDefaultMonth(computedDefault);
    let initial = computedDefault;
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored && /^\d{4}-\d{2}$/.test(stored)) {
        initial = stored;
      }
    } catch {
      // ignore — privacy mode
    }
    setMonthState(initial);
    setHydrated(true);
  }, []);

  const setMonth = useCallback((m: YearMonth) => {
    setMonthState(m);
    try {
      localStorage.setItem(STORAGE_KEY, m);
    } catch {
      // ignore
    }
  }, []);

  const resetToDefault = useCallback(() => {
    setMonth(defaultMonth);
  }, [defaultMonth, setMonth]);

  const value = useMemo<GlobalMonthContextValue>(
    () => ({
      month,
      setMonth,
      resetToDefault,
      isDefault: month === defaultMonth,
      hydrated,
    }),
    [month, defaultMonth, setMonth, resetToDefault, hydrated]
  );

  return <GlobalMonthContext.Provider value={value}>{children}</GlobalMonthContext.Provider>;
}

export function useGlobalMonth(): GlobalMonthContextValue {
  const ctx = useContext(GlobalMonthContext);
  if (!ctx) {
    // Tolerant fallback — pages outside the provider still get a default.
    // Note: this still uses `new Date()` at render time but is only hit when
    // the provider is missing entirely (test/dev oddities). Production has the
    // provider mounted in `app/layout.tsx`.
    const m = previousMonthIso();
    return {
      month: m,
      setMonth: () => {},
      resetToDefault: () => {},
      isDefault: true,
      hydrated: true,
    };
  }
  return ctx;
}

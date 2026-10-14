'use client';

import { useMemo } from 'react';
import { RotateCcw } from 'lucide-react';
import {
  formatYearMonth,
  listRecentMonths,
  useGlobalMonth,
} from '@/lib/globalMonth';

/**
 * JC-382: Global month selector — "Reports as at mmm-yy".
 * Mounted in AppLayout so every page sees it. Defaults to the previous
 * complete calendar month (JC-337). Pages opt-in by reading useGlobalMonth().
 */
export default function GlobalMonthSelector() {
  const { month, setMonth, resetToDefault, isDefault, hydrated } = useGlobalMonth();
  // REACT-HYDRATION-CLEANUP-P1.5: defer date-derived option list until after
  // hydration. `listRecentMonths` calls `new Date()` and would otherwise
  // produce a different list on server vs client (TZ + month-boundary diffs),
  // causing a #425 mismatch on every <option> in the <select>.
  const options = useMemo<string[]>(() => (hydrated ? listRecentMonths(24) : []), [hydrated]);

  // Render a layout-stable shell on the server / before hydration so React
  // doesn't reconcile date-dependent text. The select gets its real children
  // after mount.
  if (!hydrated) {
    return (
      <div
        className="flex items-center gap-2 text-xs text-[#505052]"
        style={{ fontFamily: 'Inter, sans-serif' }}
        data-testid="global-month-selector"
        suppressHydrationWarning
      >
        <label htmlFor="global-month-selector-input" className="font-medium text-[#1F1F1F]">
          Reports as at
        </label>
        <select
          id="global-month-selector-input"
          value=""
          onChange={() => {}}
          disabled
          className="rounded-md border border-[#D8D9DA] bg-white px-2 py-1 text-xs text-[#1F1F1F] focus:outline-none"
          aria-label="Reports as-at month"
        >
          <option value=""></option>
        </select>
      </div>
    );
  }

  return (
    <div
      className="flex items-center gap-2 text-xs text-[#505052]"
      style={{ fontFamily: 'Inter, sans-serif' }}
      data-testid="global-month-selector"
    >
      <label htmlFor="global-month-selector-input" className="font-medium text-[#1F1F1F]">
        Reports as at
      </label>
      <select
        id="global-month-selector-input"
        value={month}
        onChange={(e) => setMonth(e.target.value)}
        className="rounded-md border border-[#D8D9DA] bg-white px-2 py-1 text-xs text-[#1F1F1F] focus:outline-none focus:border-[#931220] focus:ring-1 focus:ring-[#931220]/20"
        aria-label="Reports as-at month"
      >
        {options.map((ym) => (
          <option key={ym} value={ym}>
            {formatYearMonth(ym)}
          </option>
        ))}
      </select>
      {!isDefault && (
        <button
          type="button"
          onClick={resetToDefault}
          className="flex items-center gap-1 text-[10px] text-[#505052] hover:text-[#931220]"
          title="Reset to previous month (default)"
        >
          <RotateCcw size={11} />
          Reset
        </button>
      )}
    </div>
  );
}

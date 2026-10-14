'use client';

import { useState, useRef, useEffect, useMemo } from 'react';
import { ChevronLeft, ChevronRight, Calendar } from 'lucide-react';

// ─── Types ───────────────────────────────────────────────────────────────

interface MonthPickerProps {
  /** Selected month in YYYY-MM format, or empty string if nothing selected */
  value: string;
  /** Called with YYYY-MM when a month is selected */
  onChange: (value: string) => void;
  /** Earliest available month in YYYY-MM format (e.g. "2019-01") */
  minMonth: string;
  /** Latest available month in YYYY-MM format (e.g. "2026-03") */
  maxMonth: string;
  /** Label shown on input button when nothing is selected (e.g. "--") */
  placeholder?: string;
  /** Optional small label shown before the button (e.g. "From:", "To:") */
  label?: string;
  /** Highlight the button border in Moppity red when true */
  active?: boolean;
}

// ─── Helpers ─────────────────────────────────────────────────────────────

const MONTH_NAMES_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function parseYearMonth(ym: string): { year: number; month: number } | null {
  if (!ym || !/^\d{4}-\d{2}$/.test(ym)) return null;
  const [y, m] = ym.split('-').map(Number);
  return { year: y, month: m };
}

function formatYearMonth(year: number, month: number): string {
  return `${year}-${String(month).padStart(2, '0')}`;
}

function formatLabel(ym: string): string {
  const parsed = parseYearMonth(ym);
  if (!parsed) return '';
  return `${MONTH_NAMES_SHORT[parsed.month - 1]} ${parsed.year}`;
}

// ─── Component ───────────────────────────────────────────────────────────

export default function MonthPicker({
  value,
  onChange,
  minMonth,
  maxMonth,
  placeholder = '--',
  label,
  active = false,
}: MonthPickerProps) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  // Derive min/max years for the year-nav bounds
  const bounds = useMemo(() => {
    const min = parseYearMonth(minMonth);
    const max = parseYearMonth(maxMonth);
    return {
      minYear: min?.year ?? new Date().getFullYear(),
      minMonth: min?.month ?? 1,
      maxYear: max?.year ?? new Date().getFullYear(),
      maxMonth: max?.month ?? 12,
    };
  }, [minMonth, maxMonth]);

  // Year currently displayed in the picker panel.
  // Defaults to the selected year → else the latest year with data.
  const [viewYear, setViewYear] = useState<number>(() => {
    const sel = parseYearMonth(value);
    return sel?.year ?? bounds.maxYear;
  });

  // If the value changes externally (e.g. clearing), sync the view year.
  useEffect(() => {
    const sel = parseYearMonth(value);
    if (sel) setViewYear(sel.year);
  }, [value]);

  // Click-outside handler to close the popover
  useEffect(() => {
    if (!open) return;
    function onDocClick(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const canGoPrevYear = viewYear > bounds.minYear;
  const canGoNextYear = viewYear < bounds.maxYear;

  function handleMonthClick(month: number) {
    // Block clicks on months outside data bounds (Apr-Dec 2026 etc.)
    if (!isMonthAvailable(viewYear, month)) return;
    onChange(formatYearMonth(viewYear, month));
    setOpen(false);
  }

  function isMonthAvailable(year: number, month: number): boolean {
    // Before the first available month → disabled
    if (year < bounds.minYear) return false;
    if (year === bounds.minYear && month < bounds.minMonth) return false;
    // After the last available month → disabled (handles partial 2026)
    if (year > bounds.maxYear) return false;
    if (year === bounds.maxYear && month > bounds.maxMonth) return false;
    return true;
  }

  const selected = parseYearMonth(value);
  const displayLabel = value ? formatLabel(value) : placeholder;

  return (
    <div ref={containerRef} className="relative inline-flex items-center">
      {label && (
        <span className="text-[10px] text-[#505052] mr-1" style={{ fontFamily: 'Inter, sans-serif' }}>
          {label}
        </span>
      )}
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className={`inline-flex items-center gap-1 px-2 py-1 rounded-md border text-[11px] bg-white transition-colors ${
          active
            ? 'border-[#931220] text-[#1F1F1F]'
            : 'border-[#D8D9DA] text-[#505052] hover:border-[#931220]/40 hover:text-[#1F1F1F]'
        }`}
        style={{ fontFamily: 'Inter, sans-serif' }}
        aria-haspopup="dialog"
        aria-expanded={open}
      >
        <Calendar size={11} className="opacity-60" />
        <span className="font-medium">{displayLabel}</span>
      </button>

      {open && (
        <div
          className="absolute left-0 top-full z-50 mt-1.5 w-56 rounded-lg border border-[#D8D9DA] bg-white shadow-lg p-3"
          style={{ fontFamily: 'Inter, sans-serif' }}
          role="dialog"
        >
          {/* Year selector header */}
          <div className="flex items-center justify-between mb-3">
            <button
              type="button"
              onClick={() => canGoPrevYear && setViewYear(y => y - 1)}
              disabled={!canGoPrevYear}
              className={`h-6 w-6 rounded flex items-center justify-center transition-colors ${
                canGoPrevYear
                  ? 'text-[#505052] hover:bg-[#FAF9F7] hover:text-[#1F1F1F]'
                  : 'text-[#D8D9DA] cursor-not-allowed'
              }`}
              aria-label="Previous year"
            >
              <ChevronLeft size={14} />
            </button>
            <span className="text-[13px] font-semibold text-[#1F1F1F] tabular-nums">{viewYear}</span>
            <button
              type="button"
              onClick={() => canGoNextYear && setViewYear(y => y + 1)}
              disabled={!canGoNextYear}
              className={`h-6 w-6 rounded flex items-center justify-center transition-colors ${
                canGoNextYear
                  ? 'text-[#505052] hover:bg-[#FAF9F7] hover:text-[#1F1F1F]'
                  : 'text-[#D8D9DA] cursor-not-allowed'
              }`}
              aria-label="Next year"
            >
              <ChevronRight size={14} />
            </button>
          </div>

          {/* 4-column × 3-row month grid */}
          <div className="grid grid-cols-4 gap-1">
            {MONTH_NAMES_SHORT.map((name, idx) => {
              const month = idx + 1;
              const available = isMonthAvailable(viewYear, month);
              const isSelected =
                selected && selected.year === viewYear && selected.month === month;
              return (
                <button
                  key={name}
                  type="button"
                  onClick={() => handleMonthClick(month)}
                  disabled={!available}
                  className={`h-7 rounded text-[11px] font-medium transition-colors ${
                    isSelected
                      ? 'bg-[#931220] text-white shadow-sm'
                      : available
                        ? 'text-[#1F1F1F] hover:bg-[#FAF9F7]'
                        : 'text-[#D8D9DA] cursor-not-allowed'
                  }`}
                >
                  {name}
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

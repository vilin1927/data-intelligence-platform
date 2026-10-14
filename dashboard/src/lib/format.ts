/**
 * Display formatters used across grids and KPI cards.
 *
 * JC-399 (WE_PROPOSE, 2026-04-27): when a delta cell has no prior
 * period to compare against (e.g. first month of data), show an
 * em-dash with a tooltip explaining why — instead of "0%" (which
 * implies parity) or "-100%" (which implies a crash).
 */

export interface DeltaDisplay {
  text: string;
  tooltip?: string;
  signed?: boolean;
}

export function formatDelta(
  pct: number | null | undefined,
  options?: { decimals?: number },
): DeltaDisplay {
  if (pct === null || pct === undefined || Number.isNaN(pct)) {
    return {
      text: '—',
      tooltip: 'no prior period to compare',
    };
  }
  const decimals = options?.decimals ?? 1;
  const rounded = Number(pct.toFixed(decimals));
  const signed = rounded > 0 ? `+${rounded}%` : `${rounded}%`;
  return { text: signed, signed: true };
}

export function formatCount(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  return n.toLocaleString('en-AU');
}

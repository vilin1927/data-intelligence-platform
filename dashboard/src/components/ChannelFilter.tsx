'use client';

import { useEffect, useState } from 'react';

/**
 * B11 — ChannelFilter (JC-076 + JC-078)
 *
 * Controlled dropdown for the D2 venue axis (DIRECT, HOFFICE, HYBRID,
 * OFF PREMISE, ON PREMISE, WHOLESALE). Strictly 6 options — no DWS/ALM/Y&R
 * (those are D1 warehouse identities and live on a separate filter).
 *
 * Reads from `/api/channels`; falls back to the canonical 6 if the API
 * fails so the dropdown is never empty.
 *
 * Designed to be wired into /sales, /margin, /reports as a venue-type
 * filter. Wiring lives in B12 (upload pipeline + sales-page hardening) per
 * the B11 plan; this component ships compile-clean and read-tested.
 */
export interface ChannelFilterProps {
  value: string;
  onChange: (next: string) => void;
  /** Label to show for the "no filter" option. Defaults to 'All channels'. */
  allLabel?: string;
  /** Optional class for the wrapping <select>. */
  className?: string;
}

const CANONICAL_FALLBACK = [
  'DIRECT',
  'HOFFICE',
  'HYBRID',
  'OFF PREMISE',
  'ON PREMISE',
  'WHOLESALE',
] as const;

export default function ChannelFilter({
  value,
  onChange,
  allLabel = 'All channels',
  className,
}: ChannelFilterProps) {
  const [options, setOptions] = useState<string[]>([...CANONICAL_FALLBACK]);

  useEffect(() => {
    let cancelled = false;
    fetch('/api/channels')
      .then((r) => (r.ok ? r.json() : Promise.reject(r.statusText)))
      .then((j: { channels?: string[] }) => {
        if (cancelled) return;
        if (Array.isArray(j.channels) && j.channels.length > 0) {
          setOptions(j.channels);
        }
      })
      .catch((err) => {
        // Stay on canonical fallback — never break the page.
        // eslint-disable-next-line no-console
        console.warn('[ChannelFilter] /api/channels failed, using fallback', err);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className={className}
      aria-label="Channel filter"
    >
      <option value="all">{allLabel}</option>
      {options.map((c) => (
        <option key={c} value={c}>
          {c}
        </option>
      ))}
    </select>
  );
}

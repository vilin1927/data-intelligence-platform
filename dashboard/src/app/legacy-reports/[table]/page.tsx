'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import { ChevronLeft, FileSpreadsheet } from 'lucide-react';

/**
 *
 * Renders the first 200 rows of a single legacy Access reporting table.
 * The `[table]` segment is forwarded to `/api/legacy-reports/[table]`
 * which validates against the 14-table allowlist before any SQL runs.
 *
 * Pagination is intentionally minimal (LIMIT-only); polish is Phase-2.
 */

interface DrillResponse {
  table: string;
  accessName: string | null;
  displayName: string;
  description: string | null;
  columns: { name: string }[];
  rows: Record<string, unknown>[];
  total: number;
  limit: number;
}

const formatCell = (v: unknown): string => {
  if (v === null || v === undefined) return '';
  if (v instanceof Date) return v.toISOString();
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
};

export default function LegacyReportDrillPage({
  params,
}: {
  params: { table: string };
}) {
  // Next.js 14 hands params as a plain object to client components.
  const { table } = params;

  const [data, setData] = useState<DrillResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const fetchData = async () => {
      try {
        setLoading(true);
        setError(null);
        const res = await apiGet(`/api/legacy-reports/${table}?limit=200`);
        if (!res.ok) {
          if (res.status === 404) {
            throw new Error(`Unknown legacy report: ${table}`);
          }
          throw new Error(`HTTP ${res.status}`);
        }
        const json: DrillResponse = await res.json();
        if (!cancelled) setData(json);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    fetchData();
    return () => {
      cancelled = true;
    };
  }, [table]);

  return (
    <AppLayout>
      <div className="space-y-5">
        {/* Back link */}
        <Link
          href="/legacy-reports"
          className="inline-flex items-center gap-1 text-xs text-[#707070] hover:text-[#1F1F1F]"
        >
          <ChevronLeft size={14} /> All legacy reports
        </Link>

        {/* Header */}
        <div className="flex items-center justify-between">
          <div className="flex items-start gap-2">
            <FileSpreadsheet size={20} className="mt-0.5 text-[#931220]" />
            <div>
              <h1 className="text-xl font-semibold text-[#1F1F1F]">
                {data?.displayName ?? table}
              </h1>
              <p className="text-xs text-[#707070] mt-0.5">
                {data?.description ?? 'Legacy Access report (read-only).'}
              </p>
              {data?.accessName && (
                <p className="text-[10px] text-[#B0B1B3] mt-1 font-mono">
                  Access: {data.accessName} · Postgres: {data.table}
                </p>
              )}
            </div>
          </div>
          {data && (
            <div className="text-right">
              <div className="text-xs text-[#707070]">Total rows</div>
              <div className="text-lg font-semibold text-[#1F1F1F]">
                {data.total.toLocaleString()}
              </div>
              {data.total > data.limit && (
                <div className="text-[10px] text-[#B0B1B3] mt-0.5">
                  showing first {data.limit}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Error state */}
        {error && (
          <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-2.5 text-xs text-red-900">
            {error}
          </div>
        )}

        {/* Data table */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
          {loading ? (
            <div className="px-4 py-8 text-center text-xs text-[#707070]">
              Loading…
            </div>
          ) : data && data.rows.length === 0 ? (
            <div className="px-4 py-8 text-center text-xs text-[#707070]">
              This Access report is empty (no rows imported).
            </div>
          ) : data ? (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-[#F8F8F8] border-b border-[#E8E8E8]">
                    {data.columns.map((c) => (
                      <th
                        key={c.name}
                        className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap"
                      >
                        {c.name}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {data.rows.map((row, i) => (
                    <tr
                      key={i}
                      className={`border-b border-[#F0F0F0] hover:bg-[#FDF2F3] ${
                        i % 2 === 1 ? 'bg-[#FAFAFA]' : ''
                      }`}
                    >
                      {data.columns.map((c) => (
                        <td
                          key={c.name}
                          className="px-3 py-1.5 text-[#1F1F1F] whitespace-nowrap"
                          title={formatCell(row[c.name])}
                        >
                          {formatCell(row[c.name])}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : null}
        </div>
      </div>
    </AppLayout>
  );
}

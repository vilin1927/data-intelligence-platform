'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import { FileSpreadsheet, ChevronRight, Database } from 'lucide-react';

/**
 * `/legacy-reports` index page.
 *
 * Lists the 14 preserved Access reporting tables. Each row shows the
 * table's display name, row count, and last-imported timestamp; clicking
 * navigates to `/legacy-reports/<table>` for the drill view.
 *
 * Read-only — no edit / delete actions. Tailwind styling matches the
 * `/legacy-data` precedent.
 */

interface LegacyReportSummary {
  name: string;
  accessName: string;
  displayName: string;
  description: string;
  rowCount: number | null;
  lastImported: string | null;
}

const fmtDate = (iso: string | null): string => {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-AU', {
    year: 'numeric',
    month: 'short',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
};

const fmtNum = (n: number | null): string => {
  if (n === null || n === undefined) return '—';
  return n.toLocaleString();
};

export default function LegacyReportsIndexPage() {
  const [reports, setReports] = useState<LegacyReportSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const fetchData = async () => {
      try {
        setLoading(true);
        const res = await apiGet('/api/legacy-reports');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data: LegacyReportSummary[] = await res.json();
        if (!cancelled) setReports(data);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    fetchData();
    return () => { cancelled = true; };
  }, []);

  return (
    <AppLayout>
      <div className="space-y-5">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold text-[#1F1F1F]">Legacy Reports</h1>
            <p className="text-xs text-[#707070] mt-0.5">
              {reports.length || 14} pre-built reports preserved from the Access
              database · read-only
            </p>
          </div>
        </div>

        {/* Info banner */}
        <div
          className="flex items-start gap-2 rounded-xl border border-blue-200 bg-blue-50 px-4 py-2.5 text-xs text-blue-900"
          style={{ fontFamily: 'Inter, sans-serif' }}
        >
          <Database size={14} className="mt-0.5 flex-shrink-0" />
          <span>
            These reports were imported verbatim from the legacy Access
            database. They reflect Access&apos;s data as of the last import
            and are not refreshed by live sync — re-run the Access import
            against the latest Access file to refresh.
          </span>
        </div>

        {/* Error state */}
        {error && (
          <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-2.5 text-xs text-red-900">
            Failed to load legacy reports: {error}
          </div>
        )}

        {/* Reports table */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
          <div className="px-4 py-3 border-b border-[#E8E8E8]">
            <h2 className="text-sm font-semibold text-[#1F1F1F]">
              Available Reports
            </h2>
          </div>

          {loading ? (
            <div className="px-4 py-8 text-center text-xs text-[#707070]">
              Loading…
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-[#F8F8F8] border-b border-[#E8E8E8]">
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">
                      Report
                    </th>
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">
                      Access table
                    </th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">
                      Rows
                    </th>
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">
                      Last imported
                    </th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]" />
                  </tr>
                </thead>
                <tbody>
                  {reports.map((r, i) => (
                    <tr
                      key={r.name}
                      className={`border-b border-[#F0F0F0] hover:bg-[#FDF2F3] transition-colors ${
                        i % 2 === 1 ? 'bg-[#FAFAFA]' : ''
                      }`}
                    >
                      <td className="px-4 py-2.5">
                        <Link
                          href={`/legacy-reports/${r.name}`}
                          className="flex items-start gap-2 group"
                        >
                          <FileSpreadsheet
                            size={14}
                            className="mt-0.5 flex-shrink-0 text-[#931220]"
                          />
                          <div>
                            <div className="font-medium text-[#931220] group-hover:text-[#7a0e1a]">
                              {r.displayName}
                            </div>
                            <div className="text-[10px] text-[#707070] mt-0.5">
                              {r.description}
                            </div>
                          </div>
                        </Link>
                      </td>
                      <td className="px-4 py-2.5 text-[#505052] font-mono text-[10px]">
                        {r.accessName}
                      </td>
                      <td className="px-4 py-2.5 text-right text-[#1F1F1F]">
                        {fmtNum(r.rowCount)}
                      </td>
                      <td className="px-4 py-2.5 text-[#707070]">
                        {fmtDate(r.lastImported)}
                      </td>
                      <td className="px-4 py-2.5 text-right">
                        <Link
                          href={`/legacy-reports/${r.name}`}
                          className="text-[#931220] hover:text-[#7a0e1a]"
                          aria-label={`Open ${r.displayName}`}
                        >
                          <ChevronRight size={14} />
                        </Link>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </AppLayout>
  );
}

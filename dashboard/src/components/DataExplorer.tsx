'use client';

import { useState } from 'react';
import { apiPost } from '@/lib/api';

interface QueryOption {
  id: string;
  label: string;
}

const QUERY_OPTIONS: QueryOption[] = [
  { id: 'top_wines', label: 'Top Wines' },
  { id: 'channel_breakdown', label: 'Channel Breakdown' },
  { id: 'code_mappings', label: 'Code Mappings' },
  { id: 'xero_summary', label: 'Xero Summary' },
  { id: 'recent_invoices', label: 'Recent Invoices' },
];

interface QueryResult {
  columns: string[];
  rows: (string | number | null)[][];
  queryName: string;
}

export default function DataExplorer() {
  const [activeQuery, setActiveQuery] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<QueryResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function runQuery(queryId: string) {
    setActiveQuery(queryId);
    setLoading(true);
    setError(null);
    setResult(null);

    try {
      const res = await apiPost('/api/query', { queryId });

      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || `Request failed (${res.status})`);
      }

      const data: QueryResult = await res.json();
      setResult(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setLoading(false);
    }
  }

  function formatCell(value: string | number | null): string {
    if (value === null || value === undefined) return '\u2014';
    if (typeof value === 'number') {
      // Format large numbers with commas; keep decimals for currency-like values
      if (Number.isInteger(value)) {
        return value.toLocaleString('en-AU');
      }
      return value.toLocaleString('en-AU', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      });
    }
    return String(value);
  }

  function formatColumnHeader(col: string): string {
    // Convert snake_case to Title Case
    return col
      .split('_')
      .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
      .join(' ');
  }

  return (
    <div>
      <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-4">
        Data Explorer
      </h2>

      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-5">
        {/* Query buttons */}
        <div className="flex flex-wrap gap-2 mb-5">
          {QUERY_OPTIONS.map((q) => (
            <button
              key={q.id}
              onClick={() => runQuery(q.id)}
              disabled={loading}
              className={`
                px-4 py-2 text-sm font-medium rounded-lg transition-all
                ${
                  activeQuery === q.id
                    ? 'bg-slate-700 text-slate-100 ring-2 ring-emerald-600 ring-offset-1 ring-offset-slate-800'
                    : 'bg-slate-700 text-slate-300 hover:bg-slate-600 hover:text-slate-100'
                }
                disabled:opacity-50 disabled:cursor-not-allowed
              `}
            >
              {q.label}
            </button>
          ))}
        </div>

        {/* Loading state */}
        {loading && (
          <div className="flex items-center justify-center py-12">
            <div className="flex items-center gap-3 text-slate-400">
              <svg
                className="animate-spin h-5 w-5 text-emerald-500"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  className="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  strokeWidth="4"
                />
                <path
                  className="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              <span className="text-sm">Running query...</span>
            </div>
          </div>
        )}

        {/* Error state */}
        {error && !loading && (
          <div className="rounded-lg bg-red-900/20 border border-red-800/50 px-4 py-3">
            <p className="text-sm text-red-400">{error}</p>
          </div>
        )}

        {/* Results table */}
        {result && !loading && (
          <div>
            <div className="flex items-center justify-between mb-3">
              <h3 className="text-sm font-medium text-slate-300">
                {result.queryName}
              </h3>
              <span className="text-xs text-slate-500">
                {result.rows.length} row{result.rows.length !== 1 ? 's' : ''}
              </span>
            </div>

            {result.rows.length === 0 ? (
              <p className="text-sm text-slate-500 py-4 text-center">
                No data found. This data source may not be loaded yet.
              </p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-slate-700/50">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-slate-700/50 bg-slate-800">
                      {result.columns.map((col) => (
                        <th
                          key={col}
                          className="px-4 py-2.5 text-left text-xs font-semibold text-slate-400 uppercase tracking-wider"
                        >
                          {formatColumnHeader(col)}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-700/30">
                    {result.rows.map((row, rowIdx) => (
                      <tr
                        key={rowIdx}
                        className="hover:bg-slate-700/20 transition-colors"
                      >
                        {row.map((cell, cellIdx) => (
                          <td
                            key={cellIdx}
                            className={`px-4 py-2 text-slate-300 whitespace-nowrap ${
                              typeof cell === 'number' ? 'text-right font-mono' : ''
                            }`}
                          >
                            {formatCell(cell)}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {/* Empty state — no query selected yet */}
        {!activeQuery && !loading && (
          <p className="text-sm text-slate-500 text-center py-8">
            Select a query above to explore the data.
          </p>
        )}
      </div>
    </div>
  );
}

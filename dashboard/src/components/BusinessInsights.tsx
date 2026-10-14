'use client';

import { useState } from 'react';
import { apiGet } from '@/lib/api';

interface InsightQuery {
  id: string;
  title: string;
  description: string;
}

const INSIGHT_QUERIES: InsightQuery[] = [
  {
    id: 'revenue_by_channel',
    title: 'Revenue by Warehouse',
    description: 'See how sales split across DWS, ALM, and Direct warehouses',
  },
  {
    id: 'top_customers',
    title: 'Top 10 Customers',
    description: 'Identify highest-value accounts across all warehouses',
  },
  {
    id: 'monthly_trend',
    title: 'Monthly Trend',
    description: 'Track sales momentum month over month',
  },
  {
    id: 'top_wines_revenue',
    title: 'Top Wines by Revenue',
    description: 'Which SKUs drive the most revenue',
  },
  {
    id: 'territory_performance',
    title: 'Territory Performance',
    description: 'Compare sales rep territories',
  },
  {
    id: 'code_mapping_coverage',
    title: 'Code Mapping Coverage',
    description: 'How well are SKU codes matched across systems',
  },
];

interface InsightResult {
  columns: string[];
  rows: (string | number | null)[][];
  queryName: string;
}

const audFormatter = new Intl.NumberFormat('en-AU', {
  style: 'currency',
  currency: 'AUD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/** Columns whose values should be formatted as AUD currency */
const REVENUE_COLUMNS = new Set([
  'revenue',
  'total_revenue',
  'total',
  'total_value',
  'amount',
  'sales',
  'avg_revenue',
  'avg_order_value',
]);

function isRevenueColumn(colName: string): boolean {
  return REVENUE_COLUMNS.has(colName.toLowerCase());
}

function formatColumnHeader(col: string): string {
  return col
    .split('_')
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

function formatCell(value: string | number | null, columnName: string): string {
  if (value === null || value === undefined) return '\u2014';

  if (typeof value === 'number') {
    if (isRevenueColumn(columnName)) {
      return audFormatter.format(value);
    }
    if (Number.isInteger(value)) {
      return value.toLocaleString('en-AU');
    }
    return value.toLocaleString('en-AU', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  // Try to detect numeric strings that look like currency
  if (typeof value === 'string' && isRevenueColumn(columnName)) {
    const parsed = parseFloat(value);
    if (!isNaN(parsed)) {
      return audFormatter.format(parsed);
    }
  }

  return String(value);
}

export default function BusinessInsights() {
  const [activeQuery, setActiveQuery] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<InsightResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function runInsight(queryId: string) {
    setActiveQuery(queryId);
    setLoading(true);
    setError(null);
    setResult(null);

    try {
      const res = await apiGet(`/api/insights?query=${encodeURIComponent(queryId)}`);

      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || `Request failed (${res.status})`);
      }

      const data: InsightResult = await res.json();
      setResult(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div>
      <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-4">
        Business Insights
      </h2>

      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-5">
        {/* Query buttons grid */}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 mb-5">
          {INSIGHT_QUERIES.map((q) => (
            <button
              key={q.id}
              onClick={() => runInsight(q.id)}
              disabled={loading}
              className={`
                text-left px-4 py-3 rounded-lg transition-all
                ${
                  activeQuery === q.id
                    ? 'bg-indigo-600 text-white ring-1 ring-indigo-400/50'
                    : 'bg-slate-700/50 text-slate-300 hover:bg-slate-700 hover:text-slate-100'
                }
                disabled:opacity-50 disabled:cursor-not-allowed
              `}
            >
              <span className="block text-sm font-medium">{q.title}</span>
              <span
                className={`block text-xs mt-0.5 ${
                  activeQuery === q.id ? 'text-indigo-200' : 'text-slate-500'
                }`}
              >
                {q.description}
              </span>
            </button>
          ))}
        </div>

        {/* Loading state */}
        {loading && (
          <div className="flex items-center justify-center py-12">
            <div className="flex items-center gap-3 text-slate-400">
              <svg
                className="animate-spin h-5 w-5 text-indigo-500"
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
                        className={`transition-colors hover:bg-slate-700/20 ${
                          rowIdx % 2 === 1 ? 'bg-slate-800/30' : ''
                        }`}
                      >
                        {row.map((cell, cellIdx) => (
                          <td
                            key={cellIdx}
                            className={`px-4 py-2 text-slate-300 whitespace-nowrap ${
                              typeof cell === 'number' || isRevenueColumn(result.columns[cellIdx])
                                ? 'text-right font-mono'
                                : ''
                            }`}
                          >
                            {formatCell(cell, result.columns[cellIdx])}
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

        {/* Empty state */}
        {!activeQuery && !loading && (
          <p className="text-sm text-slate-500 text-center py-8">
            Select an insight above to explore your business data.
          </p>
        )}
      </div>
    </div>
  );
}

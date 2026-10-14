'use client';

import { useState, useCallback } from 'react';
import { apiGet } from '@/lib/api';

interface TableInfo {
  table_name: string;
  row_count: number;
}

interface BrowseResult {
  table: string;
  columns: string[];
  rows: unknown[][];
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}

function formatHeader(col: string): string {
  return col
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function formatCell(value: unknown): string {
  if (value === null || value === undefined) return '-';
  if (typeof value === 'number') {
    return value.toLocaleString('en-AU');
  }
  if (typeof value === 'object') {
    const json = JSON.stringify(value);
    if (json.length > 200) return json.slice(0, 200) + '...';
    return json;
  }
  const str = String(value);
  if (str.length > 200) return str.slice(0, 200) + '...';
  return str;
}

export default function TableBrowser({
  tables,
  loading: tablesLoading,
}: {
  tables: TableInfo[];
  loading: boolean;
}) {
  const [selectedTable, setSelectedTable] = useState<string | null>(null);
  const [data, setData] = useState<BrowseResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const browse = useCallback(
    async (table: string, page = 1) => {
      setLoading(true);
      setError(null);
      setSelectedTable(table);

      try {
        const res = await apiGet(`/api/browse?table=${table}&page=${page}&limit=50`);
        if (!res.ok) {
          const err = await res.json();
          throw new Error(err.error || 'Failed to load');
        }
        const result: BrowseResult = await res.json();
        setData(result);
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Unknown error');
        setData(null);
      } finally {
        setLoading(false);
      }
    },
    []
  );

  // Sort tables: core tables first (no access_ prefix), then staging
  const sortedTables = [...tables].sort((a, b) => {
    const aStaging = a.table_name.startsWith('access_') ? 1 : 0;
    const bStaging = b.table_name.startsWith('access_') ? 1 : 0;
    if (aStaging !== bStaging) return aStaging - bStaging;
    return a.table_name.localeCompare(b.table_name);
  });

  return (
    <div>
      <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-4">
        Data Explorer
      </h2>
      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
        {/* Table selector */}
        <div className="flex flex-wrap gap-2 mb-6">
          {tablesLoading ? (
            <div className="h-8 bg-slate-700/50 rounded w-48 animate-pulse" />
          ) : (
            sortedTables.map((t) => (
              <button
                key={t.table_name}
                onClick={() => browse(t.table_name)}
                className={`text-xs px-3 py-1.5 rounded-lg border transition-colors ${
                  selectedTable === t.table_name
                    ? 'bg-indigo-600 border-indigo-500 text-white'
                    : t.table_name.startsWith('access_')
                    ? 'border-slate-700 text-slate-500 hover:bg-slate-700/50 hover:text-slate-300'
                    : 'border-slate-600 text-slate-300 hover:bg-slate-700 hover:text-slate-100'
                }`}
              >
                {t.table_name}
                <span className="ml-1.5 text-slate-500">
                  {t.row_count.toLocaleString()}
                </span>
              </button>
            ))
          )}
        </div>

        {/* No table selected */}
        {!selectedTable && !loading && (
          <p className="text-slate-500 text-sm text-center py-8">
            Select a table above to browse its data
          </p>
        )}

        {/* Loading */}
        {loading && (
          <div className="text-center py-8">
            <div className="inline-block w-5 h-5 border-2 border-slate-500 border-t-indigo-400 rounded-full animate-spin" />
            <p className="text-slate-400 text-sm mt-2">Loading...</p>
          </div>
        )}

        {/* Error */}
        {error && (
          <p className="text-red-400 text-sm text-center py-4">{error}</p>
        )}

        {/* Results */}
        {data && !loading && (
          <div>
            {/* Header info */}
            <div className="flex items-center justify-between mb-3">
              <h3 className="text-sm font-medium text-slate-200">
                {data.table}
                <span className="text-slate-500 font-normal ml-2">
                  {data.total.toLocaleString()} rows
                </span>
              </h3>
              <span className="text-xs text-slate-500">
                Page {data.page} of {data.totalPages}
              </span>
            </div>

            {/* Table */}
            <div className="overflow-x-auto rounded-lg border border-slate-700/50">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-slate-900/60">
                    {data.columns.map((col) => (
                      <th
                        key={col}
                        className="px-3 py-2 text-left text-slate-400 font-medium uppercase tracking-wider whitespace-nowrap"
                      >
                        {formatHeader(col)}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {data.rows.map((row, i) => (
                    <tr
                      key={i}
                      className={
                        i % 2 === 0
                          ? 'bg-slate-800/30'
                          : 'bg-slate-800/60'
                      }
                    >
                      {row.map((cell, j) => (
                        <td
                          key={j}
                          className="px-3 py-2 text-slate-300 whitespace-nowrap max-w-[300px] truncate"
                          title={cell !== null ? (typeof cell === 'object' ? JSON.stringify(cell) : String(cell)) : ''}
                        >
                          {formatCell(cell)}
                        </td>
                      ))}
                    </tr>
                  ))}
                  {data.rows.length === 0 && (
                    <tr>
                      <td
                        colSpan={data.columns.length}
                        className="px-3 py-8 text-center text-slate-500"
                      >
                        No rows in this table
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            {/* Pagination */}
            {data.totalPages > 1 && (
              <div className="flex items-center justify-center gap-2 mt-4">
                <button
                  onClick={() => browse(data.table, data.page - 1)}
                  disabled={data.page <= 1}
                  className="text-xs px-3 py-1.5 rounded-lg border border-slate-600 text-slate-300 hover:bg-slate-700 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                >
                  Previous
                </button>
                <span className="text-xs text-slate-500">
                  {data.page} / {data.totalPages}
                </span>
                <button
                  onClick={() => browse(data.table, data.page + 1)}
                  disabled={data.page >= data.totalPages}
                  className="text-xs px-3 py-1.5 rounded-lg border border-slate-600 text-slate-300 hover:bg-slate-700 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                >
                  Next
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

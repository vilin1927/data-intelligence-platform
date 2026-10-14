'use client';

import { useEffect, useState, useCallback } from 'react';
import { apiGet } from '@/lib/api';
import StatusCard from '@/components/StatusCard';
import DataArchitecture from '@/components/DataArchitecture';
import TableCounts from '@/components/TableCounts';
import BusinessInsights from '@/components/BusinessInsights';
import SchemaOverview from '@/components/SchemaOverview';
import ERDiagram from '@/components/ERDiagram';
import EtlRunLog from '@/components/EtlRunLog';
import TableBrowser from '@/components/TableBrowser';
import FileUpload from '@/components/FileUpload';

interface SourceStatus {
  source: string;
  display_name: string;
  status: 'green' | 'yellow' | 'red';
  last_sync: string | null;
  rows_total: number;
  error: string | null;
}

interface TableInfo {
  table_name: string;
  row_count: number;
}

interface EtlRun {
  run_id: number;
  source: string;
  endpoint: string | null;
  status: string;
  rows_processed: number;
  rows_skipped: number;
  error_count: number;
  error_detail: string | null;
  started_at: string;
  completed_at: string | null;
}

export default function DashboardPage() {
  // Status cards
  const [statuses, setStatuses] = useState<SourceStatus[]>([]);
  const [statusLoading, setStatusLoading] = useState(true);

  // Table counts
  const [tables, setTables] = useState<TableInfo[]>([]);
  const [tablesLoading, setTablesLoading] = useState(true);
  const [tablesError, setTablesError] = useState<string | null>(null);

  // ETL runs
  const [etlRuns, setEtlRuns] = useState<EtlRun[]>([]);
  const [etlLoading, setEtlLoading] = useState(true);
  const [etlError, setEtlError] = useState<string | null>(null);

  // Last refresh time — initialize as null to avoid hydration mismatch
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null);
  const [mounted, setMounted] = useState(false);

  const fetchAll = useCallback(async () => {
    setLastRefresh(new Date());

    // Fetch all three endpoints in parallel (with auth)
    const [statusRes, tablesRes, etlRes] = await Promise.allSettled([
      apiGet('/api/status'),
      apiGet('/api/tables'),
      apiGet('/api/etl'),
    ]);

    // Process status response
    if (statusRes.status === 'fulfilled' && statusRes.value.ok) {
      const data = await statusRes.value.json();
      setStatuses(data);
    } else {
      // Show all sources as red if fetch failed
      setStatuses([
        { source: 'vinsight', display_name: 'Vinsight', status: 'red', last_sync: null, rows_total: 0, error: 'Dashboard cannot reach API' },
        { source: 'xero_trust', display_name: 'Xero (Trust)', status: 'red', last_sync: null, rows_total: 0, error: 'Dashboard cannot reach API' },
        { source: 'xero_wines', display_name: 'Xero (Wines Pty Ltd)', status: 'red', last_sync: null, rows_total: 0, error: 'Dashboard cannot reach API' },
        { source: 'google_sheets', display_name: 'Google Sheets', status: 'red', last_sync: null, rows_total: 0, error: 'Dashboard cannot reach API' },
      ]);
    }
    setStatusLoading(false);

    // Process tables response
    if (tablesRes.status === 'fulfilled' && tablesRes.value.ok) {
      const data = await tablesRes.value.json();
      setTables(data);
      setTablesError(null);
    } else {
      setTablesError('Failed to load table data');
    }
    setTablesLoading(false);

    // Process ETL response
    if (etlRes.status === 'fulfilled' && etlRes.value.ok) {
      const data = await etlRes.value.json();
      setEtlRuns(data);
      setEtlError(null);
    } else {
      setEtlError('Failed to load ETL run log');
    }
    setEtlLoading(false);
  }, []);

  useEffect(() => {
    setMounted(true);
    fetchAll();

    // Auto-refresh every 60 seconds
    const interval = setInterval(fetchAll, 60000);
    return () => clearInterval(interval);
  }, [fetchAll]);

  return (
    <div className="min-h-screen bg-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700/50 bg-slate-900/80 backdrop-blur-sm sticky top-0 z-10">
        <div className="max-w-7xl mx-auto px-6 py-4">
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-xl font-bold text-slate-100">
                Moppity Vineyards
                <span className="text-slate-500 font-normal ml-2">
                  Data Platform
                </span>
              </h1>
              <p className="text-xs text-slate-500 mt-0.5">
                {mounted
                  ? new Date().toLocaleDateString('en-AU', {
                      weekday: 'long',
                      day: 'numeric',
                      month: 'long',
                      year: 'numeric',
                    })
                  : '\u00A0'}
              </p>
            </div>
            <div className="flex items-center gap-4">
              <span className="text-xs text-slate-500">
                Last refresh:{' '}
                {lastRefresh
                  ? lastRefresh.toLocaleTimeString('en-AU', {
                      hour: '2-digit',
                      minute: '2-digit',
                      second: '2-digit',
                      hour12: false,
                    })
                  : '--:--:--'}
              </span>
              <button
                onClick={fetchAll}
                className="text-xs px-3 py-1.5 rounded-lg border border-slate-600 text-slate-300 hover:bg-slate-700 hover:text-slate-100 transition-colors"
              >
                Refresh
              </button>
              <button
                onClick={async () => {
                  await fetch('/api/auth/logout', { method: 'POST' });
                  window.location.href = '/login';
                }}
                className="text-xs px-3 py-1.5 rounded-lg border border-slate-600 text-slate-400 hover:bg-red-900/30 hover:text-red-400 hover:border-red-800 transition-colors"
              >
                Sign Out
              </button>
            </div>
          </div>
        </div>
      </header>

      {/* Main content */}
      <main className="max-w-7xl mx-auto px-6 py-8 space-y-8">
        {/* Source Status Section */}
        <section>
          <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-4">
            Source Connections
          </h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {statusLoading
              ? // Loading skeletons
                [...Array(4)].map((_, i) => (
                  <div
                    key={i}
                    className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-5 animate-pulse"
                  >
                    <div className="h-4 bg-slate-700/50 rounded w-24 mb-4" />
                    <div className="space-y-3">
                      <div className="h-3 bg-slate-700/50 rounded w-full" />
                      <div className="h-3 bg-slate-700/50 rounded w-20" />
                    </div>
                  </div>
                ))
              : statuses.map((s) => (
                  <StatusCard key={s.source} {...s} />
                ))}
          </div>
        </section>

        {/* Data Architecture Visual */}
        <section>
          <DataArchitecture tables={tables} loading={tablesLoading} />
        </section>

        {/* Table Counts */}
        <section>
          <TableCounts
            tables={tables}
            loading={tablesLoading}
            error={tablesError}
          />
        </section>

        {/* Data Explorer - browse any table */}
        <section>
          <TableBrowser tables={tables} loading={tablesLoading} />
        </section>

        {/* Business Insights */}
        <section>
          <BusinessInsights />
        </section>

        {/* Entity Relationship Diagram */}
        <section>
          <ERDiagram tables={tables} loading={tablesLoading} />
        </section>

        {/* Schema Overview */}
        <section>
          <SchemaOverview tables={tables} loading={tablesLoading} />
        </section>

        {/* File Upload */}
        <section>
          <FileUpload />
        </section>

        {/* ETL Run Log */}
        <section>
          <EtlRunLog
            runs={etlRuns}
            loading={etlLoading}
            error={etlError}
          />
        </section>

        {/* Footer */}
        <footer className="border-t border-slate-700/30 pt-4 pb-8">
          <p className="text-xs text-slate-600 text-center">
            Moppity Vineyards Data Intelligence Platform — Milestone 1
          </p>
        </footer>
      </main>
    </div>
  );
}

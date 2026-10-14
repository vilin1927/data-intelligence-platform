'use client';

import { useEffect, useState, useCallback } from 'react';
import { apiGet, apiPost } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import FileUpload from '@/components/FileUpload';
import Badge from '@/components/Badge';
import Link from 'next/link';
import {
  Settings,
  RefreshCw,
  Upload,
  CheckCircle,
  AlertTriangle,
  XCircle,
  Database,
  FileSpreadsheet,
  Cloud,
  Calculator,
  Wine,
  Download,
  Users,
  ShieldCheck,
  ChevronDown,
  ChevronRight,
  Package,
} from 'lucide-react';
import InfoTooltip from '@/components/InfoTooltip';

// ─── Types ───────────────────────────────────────────────────────────────

interface SourceStatus {
  source: string;
  display_name: string;
  description: string;
  status: 'green' | 'yellow' | 'red';
  last_sync: string | null;
  rows_total: number;
  error: string | null;
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
  duration: string | null;
}

interface SkuMapping {
  moppity_code: string;
  dws_code: string | null;
}

interface ChannelAssignment {
  customer_name: string;
  channel: string;
}

interface BottlingActivity {
  stock_item_code: string;
  description: string;
  units_in_stock: number | null;
  last_modified: string | null;
}

interface DataQuality {
  total_transactions: number;
  unmatched_skus: number;
  unmatched_customers: number;
}

interface VinsightSyncSource {
  source: string;
  display_name: string;
  last_sync: string | null;
  rows: number;
  status: 'fresh' | 'stale' | 'error';
}

interface AdminData {
  sources: SourceStatus[];
  etl_runs: EtlRun[];
  sku_mapping: SkuMapping[];
  sku_mapping_summary: {
    total: number;
    mapped: number;
    unmapped: number;
  };
  channel_assignments: ChannelAssignment[];
  bottling_activity: BottlingActivity[];
  data_quality: DataQuality;
}

// ─── Helpers ─────────────────────────────────────────────────────────────

const font = { fontFamily: 'Inter, sans-serif' };

const SOURCE_ICONS: Record<string, React.ReactNode> = {
  vinsight: <Database size={20} />,
  xero_trust: <Calculator size={20} />,
  xero_wines: <Calculator size={20} />,
  google_sheets: <FileSpreadsheet size={20} />,
};

const SYNC_KEY_MAP: Record<string, string> = {
  vinsight: 'vinsight',
  xero_trust: 'xero',
  xero_wines: 'xero',
  google_sheets: 'sheets',
};

const STATUS_CONFIG = {
  green: { label: 'Connected', variant: 'success' as const, icon: <CheckCircle size={12} /> },
  yellow: { label: 'Stale', variant: 'warning' as const, icon: <AlertTriangle size={12} /> },
  red: { label: 'Error', variant: 'error' as const, icon: <XCircle size={12} /> },
};

function formatTimestamp(ts: string): string {
  const d = new Date(ts);
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffH = Math.floor(diffMs / (1000 * 60 * 60));

  if (diffH < 1) return 'Just now';
  if (diffH < 24) return `${diffH}h ago`;
  const diffD = Math.floor(diffH / 24);
  if (diffD === 1) return 'Yesterday';
  if (diffD < 7) return `${diffD}d ago`;
  return d.toLocaleDateString('en-AU', { day: 'numeric', month: 'short', year: 'numeric' });
}

// AUD-02: Client-only timestamp to prevent hydration mismatch
function RelativeTime({ ts }: { ts: string | null }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!ts) return <span>Never</span>;
  if (!mounted) return <span>—</span>;
  return <span>{formatTimestamp(ts)}</span>;
}

function FormattedTimestamp({ ts }: { ts: string }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!mounted) return <span suppressHydrationWarning>—</span>;
  return <span>{formatFullTimestamp(ts)}</span>;
}

function formatFullTimestamp(ts: string): string {
  return new Date(ts).toLocaleString('en-AU', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
}

const SOURCE_DISPLAY: Record<string, string> = {
  vinsight: 'Vinsight',
  xero_trust: 'Xero (Trust)',
  xero_wines: 'Xero (Wines)',
  google_sheets: 'Google Sheets',
};

// ─── Component ───────────────────────────────────────────────────────────

export default function AdminPage() {
  const [mounted, setMounted] = useState(false);
  const [data, setData] = useState<AdminData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [syncing, setSyncing] = useState<string | null>(null);
  const [syncResult, setSyncResult] = useState<{ source: string; success: boolean; message: string } | null>(null);
  const [showUpload, setShowUpload] = useState(false);
  const [uploadChannel, setUploadChannel] = useState<string>('dws');
  const [uploading, setUploading] = useState(false);
  const [uploadResult, setUploadResult] = useState<string | null>(null);
  const [showBottling, setShowBottling] = useState(false);
  const [bottlingForm, setBottlingForm] = useState({ sku_search: '', sku_id: '', bottling_date: '', cases_produced: '', lock_cogs: false });
  const [bottlingResult, setBottlingResult] = useState<string | null>(null);
  const [bottlingSubmitting, setBottlingSubmitting] = useState(false);
  const [skuResults, setSkuResults] = useState<{ sku_id: number; sku_code: string; item_description: string }[]>([]);
  const [exporting, setExporting] = useState(false);
  const [showChannelAssign, setShowChannelAssign] = useState(false);
  const [showBottlingActivity, setShowBottlingActivity] = useState(false);
  const [syncSources, setSyncSources] = useState<VinsightSyncSource[]>([]);
  const [syncStatusLoading, setSyncStatusLoading] = useState(true);
  // JC-395: visible "Last refreshed" timestamp on the admin header.
  // Mirrors the pattern from the legacy admin page (admin-legacy.tsx).
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null);

  const handleCsvExport = async () => {
    setExporting(true);
    try {
      const res = await apiGet('/api/admin?action=export_csv');
      if (!res.ok) {
        const errJson = await res.json().catch(() => null);
        alert(errJson?.error || 'Export failed');
        return;
      }
      const blob = await res.blob();
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `moppity_combined_data_${new Date().toISOString().slice(0, 10)}.csv`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      window.URL.revokeObjectURL(url);
    } catch {
      alert('Network error during export');
    } finally {
      setExporting(false);
    }
  };

  const [skuFilter, setSkuFilter] = useState<'all' | 'dws-eligible'>('dws-eligible');
  const [skuMapPage, setSkuMapPage] = useState(1);
  const SKU_MAP_PAGE_SIZE = 25;

  const fetchData = useCallback(async () => {
    try {
      const url = skuFilter === 'dws-eligible'
        ? '/api/admin?sku_filter=dws-eligible'
        : '/api/admin';
      const res = await apiGet(url);
      if (res.ok) {
        const json = await res.json();
        setData(json);
        setError(null);
        setLastRefresh(new Date());
      } else {
        setError('Failed to load admin data');
      }
    } catch {
      setError('Network error');
    } finally {
      setLoading(false);
    }
  }, [skuFilter]);

  const fetchSyncStatus = useCallback(async () => {
    setSyncStatusLoading(true);
    try {
      const res = await apiGet('/api/sync-status');
      if (res.ok) {
        const json = await res.json();
        setSyncSources(json.sources || []);
      }
    } catch {
      // Silently fail — sync status is informational
    } finally {
      setSyncStatusLoading(false);
    }
  }, []);

  useEffect(() => { setMounted(true); fetchData(); fetchSyncStatus(); }, [fetchData, fetchSyncStatus]);

  const handleSync = async (source: string) => {
    const syncKey = SYNC_KEY_MAP[source];
    if (!syncKey || syncing) return;

    setSyncing(source);
    setSyncResult(null);
    try {
      const res = await apiPost('/api/sync', { source: syncKey });
      const json = await res.json();
      setSyncResult({
        source,
        success: json.success,
        message: json.success ? 'Sync completed' : (json.error || 'Sync failed'),
      });
      if (json.success) fetchData();
    } catch {
      setSyncResult({ source, success: false, message: 'Network error' });
    } finally {
      setSyncing(null);
    }
  };

  const handleUpload = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = e.currentTarget;
    const fileInput = form.querySelector('input[type="file"]') as HTMLInputElement;
    const file = fileInput?.files?.[0];
    if (!file) return;

    setUploading(true);
    setUploadResult(null);
    const formData = new FormData();
    formData.append('channel', uploadChannel);
    formData.append('file', file);

    try {
      const res = await fetch('/api/upload', { method: 'POST', body: formData, credentials: 'same-origin' });
      const json = await res.json();
      setUploadResult(json.success ? `Uploaded ${file.name} to ${uploadChannel.toUpperCase()}` : (json.error || 'Upload failed'));
      if (json.success) {
        fetchData();
        fileInput.value = '';
      }
    } catch {
      setUploadResult('Network error');
    } finally {
      setUploading(false);
    }
  };

  if (!mounted) {
    return (
      <AppLayout>
        <div className="flex items-center justify-center min-h-[60vh]">
          <div className="w-6 h-6 border-2 border-[#931220] border-t-transparent rounded-full animate-spin" />
        </div>
      </AppLayout>
    );
  }

  return (
    <AppLayout>
      {/* Header */}
      <div className="flex items-start justify-between mb-6">
        <div>
          <h1 className="text-2xl text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
            Admin Panel
          </h1>
          <p className="text-[#8A8A8D] text-sm mt-1" style={font}>
            Data source status, ETL monitoring & system health
            <InfoTooltip text="This page shows the health of all 4 data source connections (Vinsight, Xero Trust, Xero Wines, Google Sheets), recent ETL sync history, and the DWS SKU code mapping status." size={10} className="inline-flex ml-1.5 align-middle" />
          </p>
        </div>
        <div className="flex items-center gap-2">
          {/* JC-395: Last refreshed timestamp (Access UX parity). */}
          <span className="text-[10px] text-[#8A8A8D]" style={font}>
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
            onClick={() => { setLoading(true); fetchData(); }}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-[#FAF9F7] border border-[#D8D9DA] text-[#1F1F1F] hover:bg-white transition-colors"
            style={font}
          >
            <RefreshCw size={14} />
            Refresh
          </button>
          <button
            onClick={() => setShowUpload(!showUpload)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors"
            style={font}
          >
            <Upload size={14} />
            Upload Data
          </button>
        </div>
      </div>

      {/* Data Import Wizard (collapsible) */}
      {showUpload && (
        <div className="bg-white rounded-xl border border-[#EBEBEC] p-5 mb-6 shadow-sm">
          <FileUpload />
        </div>
      )}

      {loading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          {[...Array(4)].map((_, i) => (
            <div key={i} className="bg-white rounded-xl border border-[#D8D9DA] p-5 animate-pulse">
              <div className="h-4 bg-gray-200 rounded w-24 mb-3" />
              <div className="h-3 bg-gray-200 rounded w-32 mb-4" />
              <div className="h-3 bg-gray-200 rounded w-20" />
            </div>
          ))}
        </div>
      ) : error ? (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-red-700">{error}</div>
      ) : data ? (
        <div className="space-y-6">
          {/* Source Status Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {data.sources.map(src => {
              const cfg = STATUS_CONFIG[src.status];
              const isSyncing = syncing === src.source;
              const result = syncResult?.source === src.source ? syncResult : null;

              return (
                <div key={src.source} className="bg-white rounded-xl border border-[#EBEBEC] p-5 shadow-sm">
                  {/* Header: name + badge */}
                  <div className="flex items-center justify-between mb-1">
                    <div className="flex items-center gap-2">
                      <span className="text-[#931220]">{SOURCE_ICONS[src.source] || <Cloud size={20} />}</span>
                      <h3 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                        {src.display_name}
                      </h3>
                    </div>
                    <Badge variant={cfg.variant}>
                      {cfg.icon}
                      <span className="ml-1">{cfg.label}</span>
                    </Badge>
                  </div>
                  <p className="text-xs text-[#8A8A8D] mb-3" style={font}>{src.description}</p>

                  {/* Data rows */}
                  <div className="space-y-1.5 text-xs" style={font}>
                    <div className="flex justify-between">
                      <span className="text-[#505052]">Last sync</span>
                      <span className="text-[#1F1F1F] font-medium">
                        <RelativeTime ts={src.last_sync} />
                      </span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-[#505052]">Rows synced</span>
                      <span className="text-[#1F1F1F] font-medium">{src.rows_total.toLocaleString()}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-[#505052]">Errors</span>
                      <span className={src.error ? 'text-[#B42318] font-medium' : 'text-[#1B7A3D] font-medium'}>
                        {src.error ? 'Yes' : '0'}
                      </span>
                    </div>
                  </div>

                  {/* Sync button */}
                  <button
                    onClick={() => handleSync(src.source)}
                    disabled={!!syncing}
                    className="mt-3 w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-lg text-[10px] font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors disabled:opacity-50"
                    style={font}
                  >
                    <RefreshCw size={10} className={isSyncing ? 'animate-spin' : ''} />
                    {isSyncing ? 'Syncing...' : 'Run Sync'}
                  </button>

                  {/* Sync result */}
                  {result && (
                    <p className={`text-[10px] mt-1.5 text-center ${result.success ? 'text-[#1B7A3D]' : 'text-[#B42318]'}`} style={font}>
                      {result.message}
                    </p>
                  )}
                </div>
              );
            })}
          </div>

          {/* Vinsight Sync Status */}
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5">
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-2">
                <span className="text-[#931220]"><Database size={18} /></span>
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Vinsight Sync Status
                  <InfoTooltip text="Shows the freshness of each Vinsight staging table. Green = synced within 48h. Yellow/Red = stale or never synced. Row counts reflect the current data volume in each table." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
              </div>
              <button
                onClick={() => { fetchSyncStatus(); }}
                className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-[10px] font-medium bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] hover:bg-white transition-colors"
                style={font}
              >
                <RefreshCw size={10} className={syncStatusLoading ? 'animate-spin' : ''} />
                Refresh
              </button>
            </div>
            {syncStatusLoading && syncSources.length === 0 ? (
              <div className="space-y-2">
                {[...Array(7)].map((_, i) => (
                  <div key={i} className="flex items-center justify-between py-1.5 animate-pulse">
                    <div className="h-3 bg-gray-200 rounded w-28" />
                    <div className="flex items-center gap-4">
                      <div className="h-3 bg-gray-200 rounded w-16" />
                      <div className="h-3 bg-gray-200 rounded w-20" />
                    </div>
                  </div>
                ))}
              </div>
            ) : syncSources.length > 0 ? (
              <div className="overflow-hidden rounded-lg border border-[#EBEBEC]">
                <table className="w-full text-xs" style={font}>
                  <thead>
                    <tr className="bg-[#F5F4F2] border-b border-[#D8D9DA]">
                      <th className="py-1.5 px-3 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Source</th>
                      <th className="py-1.5 px-3 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Status</th>
                      <th className="py-1.5 px-3 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Last Sync</th>
                      <th className="py-1.5 px-3 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Rows</th>
                    </tr>
                  </thead>
                  <tbody>
                    {syncSources.map((src) => {
                      const isFresh = src.status === 'fresh';
                      const isStale = src.status === 'stale';
                      // Differentiate >7 days as warning vs >48h as stale
                      const daysAgo = src.last_sync
                        ? Math.floor((Date.now() - new Date(src.last_sync).getTime()) / (1000 * 60 * 60 * 24))
                        : null;
                      const isWarning = isStale && daysAgo !== null && daysAgo >= 7;

                      let statusIcon: React.ReactNode;
                      let statusColor: string;
                      if (isFresh) {
                        statusIcon = <CheckCircle size={14} />;
                        statusColor = 'text-[#1B7A3D]';
                      } else if (isWarning) {
                        statusIcon = <AlertTriangle size={14} />;
                        statusColor = 'text-[#D97706]';
                      } else if (isStale) {
                        statusIcon = <XCircle size={14} />;
                        statusColor = 'text-[#B42318]';
                      } else {
                        statusIcon = <XCircle size={14} />;
                        statusColor = 'text-[#B42318]';
                      }

                      return (
                        <tr key={src.source} className="border-b border-[#EBEBEC] last:border-0 hover:bg-[#FAF9F7]">
                          <td className="py-2 px-3 text-[#1F1F1F] font-medium">{src.display_name}</td>
                          <td className="py-2 px-3">
                            <span className={`inline-flex items-center gap-1 ${statusColor}`}>
                              {statusIcon}
                              <span className="text-[11px] font-medium capitalize">
                                {isFresh ? 'Fresh' : isWarning ? 'Warning' : isStale ? 'Stale' : 'Error'}
                              </span>
                            </span>
                          </td>
                          <td className="py-2 px-3 text-right text-[#505052]">
                            <RelativeTime ts={src.last_sync} />
                          </td>
                          <td className="py-2 px-3 text-right text-[#1F1F1F] font-medium tabular-nums">
                            {src.rows.toLocaleString()}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            ) : (
              <p className="text-xs text-[#8A8A8D]" style={font}>
                No sync status data available
              </p>
            )}
          </div>

          {/* Bottling Run Entry */}
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5">
            <div className="flex items-center justify-between mb-3">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  <Wine size={16} className="inline mr-1.5 text-[#931220]" />
                  Record Bottling Run
                  <InfoTooltip text="Manually record a bottling run when bulk wine is packaged into cases. Optionally lock COGS at the current rate — once locked, the economic cost won't change for that wine." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
              </div>
              <button
                onClick={() => setShowBottling(!showBottling)}
                className="text-xs text-[#931220] hover:underline"
                style={font}
              >
                {showBottling ? 'Hide' : 'New Run'}
              </button>
            </div>
            {showBottling && (
              <div className="space-y-3">
                <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
                  <div className="sm:col-span-2">
                    <label className="text-xs text-[#505052] block mb-1" style={font}>Wine (search by name or code)</label>
                    <input
                      type="text"
                      value={bottlingForm.sku_search}
                      onChange={async (e) => {
                        const q = e.target.value;
                        setBottlingForm(f => ({ ...f, sku_search: q, sku_id: '' }));
                        if (q.length >= 2) {
                          const res = await apiGet(`/api/wines?search=${encodeURIComponent(q)}&limit=5`);
                          if (res.ok) {
                            const json = await res.json();
                            setSkuResults(json.wines || json.results || []);
                          }
                        } else {
                          setSkuResults([]);
                        }
                      }}
                      placeholder="e.g. Lock & Key Shiraz..."
                      className="w-full px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F]"
                      style={font}
                    />
                    {skuResults.length > 0 && !bottlingForm.sku_id && (
                      <div className="mt-1 border border-[#D8D9DA] rounded-lg bg-white shadow-md max-h-32 overflow-y-auto">
                        {skuResults.map(s => (
                          <button
                            key={s.sku_id}
                            onClick={() => {
                              setBottlingForm(f => ({ ...f, sku_id: String(s.sku_id), sku_search: `${s.item_description} (${s.sku_code})` }));
                              setSkuResults([]);
                            }}
                            className="w-full text-left px-3 py-1.5 text-xs hover:bg-[#FAF9F7] border-b border-[#F3F4F6] last:border-0"
                            style={font}
                          >
                            <span className="font-medium text-[#1F1F1F]">{s.item_description}</span>
                            <span className="text-[#505052] ml-2 font-mono">{s.sku_code}</span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                  <div>
                    <label className="text-xs text-[#505052] block mb-1" style={font}>Bottling Date</label>
                    <input
                      type="date"
                      value={bottlingForm.bottling_date}
                      onChange={e => setBottlingForm(f => ({ ...f, bottling_date: e.target.value }))}
                      className="w-full px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F]"
                      style={font}
                    />
                  </div>
                  <div>
                    <label className="text-xs text-[#505052] block mb-1" style={font}>Cases Produced</label>
                    <input
                      type="number"
                      value={bottlingForm.cases_produced}
                      onChange={e => setBottlingForm(f => ({ ...f, cases_produced: e.target.value }))}
                      placeholder="e.g. 500"
                      className="w-full px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F]"
                      style={font}
                    />
                  </div>
                </div>
                <div className="flex items-center justify-between">
                  <label className="flex items-center gap-2 text-xs text-[#505052] cursor-pointer" style={font}>
                    <input
                      type="checkbox"
                      checked={bottlingForm.lock_cogs}
                      onChange={e => setBottlingForm(f => ({ ...f, lock_cogs: e.target.checked }))}
                      className="rounded border-[#D8D9DA]"
                    />
                    Lock COGS at current rate (prevents future changes)
                  </label>
                  <button
                    disabled={!bottlingForm.sku_id || !bottlingForm.bottling_date || !bottlingForm.cases_produced || bottlingSubmitting}
                    onClick={async () => {
                      setBottlingSubmitting(true);
                      setBottlingResult(null);
                      try {
                        const res = await apiPost('/api/bottling', {
                          sku_id: parseInt(bottlingForm.sku_id),
                          bottling_date: bottlingForm.bottling_date,
                          cases_produced: parseInt(bottlingForm.cases_produced),
                          lock_cogs: bottlingForm.lock_cogs,
                        });
                        const json = await res.json();
                        if (json.success) {
                          setBottlingResult(`Recorded: ${bottlingForm.cases_produced} cases${json.cogs_locked ? ' (COGS locked)' : ''}`);
                          setBottlingForm({ sku_search: '', sku_id: '', bottling_date: '', cases_produced: '', lock_cogs: false });
                        } else {
                          setBottlingResult(json.error || 'Failed');
                        }
                      } catch {
                        setBottlingResult('Network error');
                      } finally {
                        setBottlingSubmitting(false);
                      }
                    }}
                    className="px-3 py-1.5 rounded-lg text-xs font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors disabled:opacity-50"
                    style={font}
                  >
                    {bottlingSubmitting ? 'Saving...' : 'Record Bottling Run'}
                  </button>
                </div>
                {bottlingResult && (
                  <p className={`text-xs ${bottlingResult.startsWith('Recorded') ? 'text-[#1B7A3D]' : 'text-[#B42318]'}`} style={font}>
                    {bottlingResult}
                  </p>
                )}
              </div>
            )}
          </div>

          {/* Data Export + Data Quality row */}
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
            {/* Data Export Card */}
            <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5">
              <div className="flex items-center gap-2 mb-1">
                <span className="text-[#931220]"><Download size={18} /></span>
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Data Export
                  <InfoTooltip text="Download all combined sales data as CSV for pivot tables and offline analysis. Includes customer, channel, territory, SKU, revenue, deductions, and COGS columns." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
              </div>
              <p className="text-xs text-[#8A8A8D] mb-4" style={font}>
                Export combined sales data for Excel analysis
              </p>
              <button
                onClick={handleCsvExport}
                disabled={exporting}
                className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-lg text-sm font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors disabled:opacity-50"
                style={font}
              >
                <Download size={16} />
                {exporting ? 'Exporting...' : 'Export Combined Data (CSV)'}
              </button>
              <p className="text-[10px] text-[#8A8A8D] mt-2 text-center" style={font}>
                Includes: date, customer, channel, territory, SKU, revenue, COGS, GP
              </p>
            </div>

            {/* Data Quality Card */}
            <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5">
              <div className="flex items-center gap-2 mb-1">
                <span className="text-[#931220]"><ShieldCheck size={18} /></span>
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Data Quality
                  <InfoTooltip text="Shows counts of sales transactions with missing SKU or customer mappings. These records exist in the database but can't be fully attributed. Interactive matching is planned for Phase 2." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
              </div>
              <p className="text-xs text-[#8A8A8D] mb-4" style={font}>
                Unmatched records from ETL imports
              </p>
              {data.data_quality ? (
                <div className="space-y-3">
                  <div className="flex items-center justify-between py-2 px-3 rounded-lg bg-[#FAF9F7]">
                    <span className="text-xs text-[#505052]" style={font}>Total transactions</span>
                    <span className="text-sm font-semibold text-[#1F1F1F]" style={font}>
                      {data.data_quality.total_transactions.toLocaleString()}
                    </span>
                  </div>
                  <div className="flex items-center justify-between py-2 px-3 rounded-lg bg-[#FAF9F7]">
                    <span className="text-xs text-[#505052]" style={font}>Unmatched SKUs</span>
                    <span className={`text-sm font-semibold ${data.data_quality.unmatched_skus > 0 ? 'text-[#B42318]' : 'text-[#1B7A3D]'}`} style={font}>
                      {data.data_quality.unmatched_skus.toLocaleString()}
                    </span>
                  </div>
                  <div className="flex items-center justify-between py-2 px-3 rounded-lg bg-[#FAF9F7]">
                    <span className="text-xs text-[#505052]" style={font}>Unmatched Customers</span>
                    <span className={`text-sm font-semibold ${data.data_quality.unmatched_customers > 0 ? 'text-[#B42318]' : 'text-[#1B7A3D]'}`} style={font}>
                      {data.data_quality.unmatched_customers.toLocaleString()}
                    </span>
                  </div>
                  {(data.data_quality.unmatched_skus > 0 || data.data_quality.unmatched_customers > 0) && (
                    <p className="text-[10px] text-[#8A8A8D] text-center pt-1" style={font}>
                      Interactive matching coming in Phase 2
                    </p>
                  )}
                </div>
              ) : (
                <p className="text-xs text-[#8A8A8D]" style={font}>No data quality info available</p>
              )}
            </div>

            {/* Channel Assignments Card */}
            <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5 flex flex-col">
              <div className="flex items-center justify-between mb-1">
                <div className="flex items-center gap-2">
                  <span className="text-[#931220]"><Users size={18} /></span>
                  <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                    Channel Assignments
                    <InfoTooltip text="Customers flagged as DWS or ALM are excluded from Direct imports. This prevents double-counting when the same sale appears in both a channel report and a Vinsight invoice." size={10} className="inline-flex ml-1.5 align-middle" />
                  </h2>
                </div>
                <button
                  onClick={() => setShowChannelAssign(!showChannelAssign)}
                  className="text-[#505052] hover:text-[#1F1F1F] transition-colors"
                >
                  {showChannelAssign ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                </button>
              </div>
              <p className="text-xs text-[#8A8A8D] mb-3" style={font}>
                DWS/ALM customers excluded from Direct
              </p>
              {showChannelAssign && data.channel_assignments && (
                <div className="overflow-y-auto max-h-48 flex-1 -mx-5 px-0">
                  <table className="w-full text-xs" style={font}>
                    <thead>
                      <tr className="border-y border-[#D8D9DA] bg-[#F5F4F2]">
                        <th className="py-1.5 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Customer</th>
                        <th className="py-1.5 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Warehouse</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.channel_assignments.map((ca, i) => (
                        <tr key={i} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                          <td className="py-1.5 px-5 text-[#1F1F1F]">{ca.customer_name}</td>
                          <td className="py-1.5 px-5 text-right">
                            <Badge variant={ca.channel === 'DWS' ? 'info' : 'warning'}>{ca.channel}</Badge>
                          </td>
                        </tr>
                      ))}
                      {data.channel_assignments.length === 0 && (
                        <tr>
                          <td colSpan={2} className="py-4 text-center text-[#8A8A8D]">No channel assignments found</td>
                        </tr>
                      )}
                    </tbody>
                  </table>
                </div>
              )}
              {!showChannelAssign && data.channel_assignments && (
                <p className="text-xs text-[#505052]" style={font}>
                  {data.channel_assignments.filter(c => c.channel === 'DWS').length} DWS &middot; {data.channel_assignments.filter(c => c.channel === 'ALM').length} ALM customers
                </p>
              )}
            </div>
          </div>

          {/* Match Unmatched — nav to fuzzy-match approver pages */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Link
              href="/admin/unmatched-customers"
              className="block bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5 hover:bg-[#FAF9F7] transition-colors"
            >
              <div className="flex items-center justify-between mb-1">
                <div className="flex items-center gap-2">
                  <span className="text-[#931220]"><Users size={18} /></span>
                  <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                    Unmatched Customers
                  </h2>
                </div>
                {data.data_quality && (
                  <span
                    className={`inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold ${
                      data.data_quality.unmatched_customers > 0
                        ? 'bg-[#931220]/10 text-[#931220]'
                        : 'bg-[#E6F4EA] text-[#1B7A3D]'
                    }`}
                    style={font}
                  >
                    {data.data_quality.unmatched_customers.toLocaleString()} unmatched
                  </span>
                )}
              </div>
              <p className="text-xs text-[#8A8A8D] mb-3" style={font}>
                Approve fuzzy matches for customers with sales but no master link
              </p>
              <div
                className="w-full flex items-center justify-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors"
                style={font}
              >
                Open matcher
                <ChevronRight size={14} />
              </div>
            </Link>

            <Link
              href="/admin/unmatched-skus"
              className="block bg-white rounded-xl border border-[#EBEBEC] shadow-sm p-5 hover:bg-[#FAF9F7] transition-colors"
            >
              <div className="flex items-center justify-between mb-1">
                <div className="flex items-center gap-2">
                  <span className="text-[#931220]"><Package size={18} /></span>
                  <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                    Unmatched SKUs
                  </h2>
                </div>
                {data.data_quality && (
                  <span
                    className={`inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold ${
                      data.data_quality.unmatched_skus > 0
                        ? 'bg-[#931220]/10 text-[#931220]'
                        : 'bg-[#E6F4EA] text-[#1B7A3D]'
                    }`}
                    style={font}
                  >
                    {data.data_quality.unmatched_skus.toLocaleString()} unmatched
                  </span>
                )}
              </div>
              <p className="text-xs text-[#8A8A8D] mb-3" style={font}>
                Approve fuzzy matches for products with sales but no master link
              </p>
              <div
                className="w-full flex items-center justify-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors"
                style={font}
              >
                Open matcher
                <ChevronRight size={14} />
              </div>
            </Link>
          </div>

          {/* Recent Bottling Activity */}
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            <div className="p-5 pb-0 flex items-center justify-between">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  <Package size={16} className="inline mr-1.5 text-[#931220]" />
                  Recent Bottling Activity
                  <InfoTooltip text="Bottled wine stock items from Vinsight, sorted by last modification date. This shows recent activity in the bottling pipeline — the most recently modified items appear first." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  From Vinsight stock items &middot; Last 20 modified
                </p>
              </div>
              <button
                onClick={() => setShowBottlingActivity(!showBottlingActivity)}
                className="flex items-center gap-1 text-xs text-[#931220] hover:underline"
                style={font}
              >
                {showBottlingActivity ? 'Hide' : 'Show'}
                {showBottlingActivity ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              </button>
            </div>
            {showBottlingActivity && data.bottling_activity && (
              <div className="overflow-x-auto mt-4">
                <table className="w-full text-xs" style={font}>
                  <thead>
                    <tr className="border-y border-[#D8D9DA] bg-[#F5F4F2]">
                      <th className="py-2 px-4 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Code</th>
                      <th className="py-2 px-4 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Description</th>
                      <th className="py-2 px-4 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Units in Stock</th>
                      <th className="py-2 px-4 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Last Modified</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.bottling_activity.map((item, i) => (
                      <tr key={i} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                        <td className="py-2 px-4 text-[#1F1F1F] font-mono text-[11px]">{item.stock_item_code}</td>
                        <td className="py-2 px-4 text-[#1F1F1F]">{item.description}</td>
                        <td className="py-2 px-4 text-right text-[#1F1F1F] font-medium">
                          {item.units_in_stock != null ? Number(item.units_in_stock).toLocaleString() : '\u2014'}
                        </td>
                        <td className="py-2 px-4 text-right text-[#505052] whitespace-nowrap">
                          {item.last_modified ? <RelativeTime ts={item.last_modified} /> : '\u2014'}
                        </td>
                      </tr>
                    ))}
                    {data.bottling_activity.length === 0 && (
                      <tr>
                        <td colSpan={4} className="py-8 text-center text-[#505052]">
                          No bottling activity data available
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
            )}
            {!showBottlingActivity && data.bottling_activity && (
              <p className="px-5 py-3 text-xs text-[#505052]" style={font}>
                {data.bottling_activity.length} items &middot; Click &ldquo;Show&rdquo; to view details
              </p>
            )}
          </div>

          {/* Bottom row: ETL Log + SKU Mapping */}
          <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
            {/* ETL Run Log — 3 cols */}
            <div className="lg:col-span-3 bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
              <div className="p-5 pb-0">
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Recent ETL Runs
                  <InfoTooltip text="History of data sync operations. Each row is one ETL run pulling data from a source into Postgres. Failed runs show error count — hover the row for details." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  Sync history & error log
                </p>
              </div>
              <div className="overflow-x-auto mt-4">
                <table className="w-full text-xs" style={font}>
                  <thead>
                    <tr className="border-y border-[#D8D9DA] bg-[#F5F4F2]">
                      <th className="py-2 px-4 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Timestamp</th>
                      <th className="py-2 px-4 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Source</th>
                      <th className="py-2 px-4 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Rows</th>
                      <th className="py-2 px-4 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Duration</th>
                      <th className="py-2 px-4 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.etl_runs.map(run => (
                      <tr
                        key={run.run_id}
                        className={`border-b border-[#EBEBEC] hover:bg-[#FAF9F7] ${run.error_count > 0 ? 'text-[#505052]' : ''}`}
                        title={run.error_detail || undefined}
                      >
                        <td className="py-2.5 px-4 text-[#1F1F1F] whitespace-nowrap">
                          <FormattedTimestamp ts={run.started_at} />
                        </td>
                        <td className="py-2.5 px-4 text-[#1F1F1F]">
                          {SOURCE_DISPLAY[run.source] || run.source}
                        </td>
                        <td className="py-2.5 px-4 text-right text-[#1F1F1F]">
                          {run.rows_processed.toLocaleString()}
                        </td>
                        <td className="py-2.5 px-4 text-right text-[#505052]">
                          {run.duration || '—'}
                        </td>
                        <td className="py-2.5 px-4 text-right">
                          {run.status === 'success' ? (
                            <Badge variant="success">Success</Badge>
                          ) : run.status === 'failed' ? (
                            <Badge variant="error">{run.error_count} errors</Badge>
                          ) : run.status === 'running' ? (
                            <Badge variant="info">Running</Badge>
                          ) : (
                            <Badge variant="warning">{run.status}</Badge>
                          )}
                        </td>
                      </tr>
                    ))}
                    {data.etl_runs.length === 0 && (
                      <tr>
                        <td colSpan={5} className="py-8 text-center text-[#505052]">No ETL runs recorded</td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
            </div>

            {/* SKU Code Mapping — 2 cols */}
            <div className="lg:col-span-2 bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden flex flex-col">
              <div className="p-5 pb-0">
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  SKU Code Mapping
                  <InfoTooltip text="Maps Moppity codes to DWS warehouse codes for ~70 SKUs that DWS resells (Lock & Key, Coppabella, Twelve Signs, Atrius core). 'Unmapped' = SKU has no DWS counterpart — by design for non-DWS lines (Chalice Bridge, internal-only Atrius, discontinued vintages)." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  DWS resells ~70 Moppity SKUs. The full Moppity catalogue (744 wines) includes
                  many non-DWS lines, so &ldquo;Unmapped&rdquo; rows are expected and not a data gap.
                </p>
                <div className="mt-2 flex items-center gap-2 text-xs" style={font}>
                  <label className="inline-flex items-center gap-1.5 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={skuFilter === 'dws-eligible'}
                      onChange={(e) => { setSkuFilter(e.target.checked ? 'dws-eligible' : 'all'); setSkuMapPage(1); }}
                      className="rounded border-[#D8D9DA]"
                    />
                    <span className="text-[#505052]">Show DWS-eligible only</span>
                  </label>
                  <span className="text-[#8A8A8D]">(hides expected-unmapped non-DWS lines)</span>
                </div>
              </div>
              <div className="overflow-x-auto mt-4 flex-1">
                <table className="w-full text-xs" style={font}>
                  <thead>
                    <tr className="border-y border-[#D8D9DA] bg-[#F5F4F2]">
                      <th className="py-2 px-4 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Moppity Code</th>
                      <th className="py-2 px-4 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">DWS Code</th>
                      <th className="py-2 px-4 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.sku_mapping
                      .slice((skuMapPage - 1) * SKU_MAP_PAGE_SIZE, skuMapPage * SKU_MAP_PAGE_SIZE)
                      .map((m, i) => (
                      <tr key={i} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                        <td className="py-2 px-4 text-[#1F1F1F] font-mono text-[11px]">{m.moppity_code}</td>
                        <td className="py-2 px-4 text-[#1F1F1F] font-mono text-[11px]">
                          {m.dws_code || <span className="text-[#8A8A8D]">&mdash;</span>}
                        </td>
                        <td className="py-2 px-4 text-right">
                          {m.dws_code ? (
                            <Badge variant="success">Mapped</Badge>
                          ) : (
                            <Badge variant="error">Unmapped</Badge>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              {/* Summary + pagination footer */}
              <div className="bg-[#F5F4F2] px-5 py-3 flex items-center justify-between border-t border-[#D8D9DA] gap-3 flex-wrap">
                <div className="flex items-center gap-3 text-xs" style={font}>
                  <span className="font-semibold text-[#1F1F1F]">Total: {data.sku_mapping_summary.total}</span>
                  <span className="text-[#1B7A3D]">Mapped: {data.sku_mapping_summary.mapped}</span>
                  <span className="text-[#B42318]">Unmapped: {data.sku_mapping_summary.unmapped}</span>
                </div>
                {data.sku_mapping.length > SKU_MAP_PAGE_SIZE && (
                  <div className="flex items-center gap-2 text-xs" style={font}>
                    <button
                      type="button"
                      onClick={() => setSkuMapPage(p => Math.max(1, p - 1))}
                      disabled={skuMapPage === 1}
                      className="px-2 py-1 rounded border border-[#D8D9DA] hover:bg-white disabled:opacity-40 disabled:cursor-not-allowed"
                    >
                      Prev
                    </button>
                    <span className="text-[#505052]">
                      Page {skuMapPage} of {Math.max(1, Math.ceil(data.sku_mapping.length / SKU_MAP_PAGE_SIZE))}
                    </span>
                    <button
                      type="button"
                      onClick={() => setSkuMapPage(p => Math.min(Math.ceil(data.sku_mapping.length / SKU_MAP_PAGE_SIZE), p + 1))}
                      disabled={skuMapPage >= Math.ceil(data.sku_mapping.length / SKU_MAP_PAGE_SIZE)}
                      className="px-2 py-1 rounded border border-[#D8D9DA] hover:bg-white disabled:opacity-40 disabled:cursor-not-allowed"
                    >
                      Next
                    </button>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </AppLayout>
  );
}

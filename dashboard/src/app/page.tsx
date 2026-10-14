'use client';

import { useEffect, useState, useCallback } from 'react';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import { StackedBarChart } from '@/components/Charts';
import Badge from '@/components/Badge';
import ExecutiveSummaryModal from '@/components/ExecutiveSummaryModal';
import {
  DollarSign,
  TrendingUp,
  Package,
  Wine,
  AlertTriangle,
  CheckCircle,
  Clock,
  FileText,
} from 'lucide-react';
import InfoTooltip from '@/components/InfoTooltip';

const KPI_TOOLTIPS: Record<string, string> = {
  'Revenue (Prev Month)': 'Total net revenue for the previous complete month from all warehouses (DWS, ALM, Direct). Current month excluded because data arrives mid following month.',
  'Gross Profit (Prev Month)': 'Revenue minus cost of goods sold (COGS) for the previous complete month.',
  'Active SKUs': 'Number of distinct wines with at least one sale in the last 90 days.',
  'Catalog Value': 'Sum of base wholesale price × units per case across all SKUs. Not actual inventory — shows total catalog value.',
};

const COLUMN_TOOLTIPS: Record<string, string> = {
  'Wine': 'Product name and SKU code',
  'Variety': 'Grape variety (e.g., Shiraz, Chardonnay)',
  'Region': 'Wine region (e.g., Hilltops, Tumbarumba)',
  'Revenue': 'Total net revenue from this SKU in the last 12 months',
  'Qty': 'Total quantity sold (cases) in the last 12 months',
  'GP%': 'Gross profit percentage: (revenue - cost) / revenue. Uses accounting COGS.',
};

interface OverviewData {
  kpis: {
    revenue_mtd: number;
    revenue_trend: number | null;
    gross_profit_mtd: number;
    active_skus: number;
    total_skus: number;
    inventory_value: number;
  };
  revenue_by_channel: Array<{
    month: string;
    dws: number;
    alm: number;
    direct: number;
    yoy_total?: number;
  }>;
  top_wines: Array<{
    sku_code: string;
    item_description: string;
    variety: string;
    region: string;
    total_revenue: number;
    total_qty: number;
    gp_pct: number;
  }>;
  alerts: {
    recent_errors: number;
    last_sync: string | null;
    recent_dead_letters: number;
  };
}

function formatCurrency(value: number): string {
  // B4 fix: use Math.abs for threshold check so negatives also abbreviate to K/M.
  // Previously e.g. -2151 fell through to `$-2151` while ExecutiveSummary showed `$-2.2K`.
  // Sign placement matches ExecutiveSummaryModal (e.g. "$-2.2K") for consistency.
  if (!Number.isFinite(value)) return '—';
  if (Math.abs(value) >= 1_000_000) return `$${(value / 1_000_000).toFixed(1)}M`;
  if (Math.abs(value) >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  return `$${value.toFixed(0)}`;
}

function formatTimeAgo(dateStr: string | null): string {
  if (!dateStr) return 'Never';
  const date = new Date(dateStr);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
  if (diffHours < 1) return 'Just now';
  if (diffHours < 24) return `${diffHours}h ago`;
  const diffDays = Math.floor(diffHours / 24);
  return `${diffDays}d ago`;
}

export default function OverviewPage() {
  const [data, setData] = useState<OverviewData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [execSummaryOpen, setExecSummaryOpen] = useState(false);
  // REACT-HYDRATION-CLEANUP-P1.5: greeting + dateLabel derive from `new Date()`
  // which differs between server (Node UTC) and client (browser local TZ).
  // Start empty (matching SSR), then populate in useEffect after mount so the
  // initial hydration sees identical strings on both sides.
  const [greeting, setGreeting] = useState<string>('');
  const [dateLabel, setDateLabel] = useState<string>('');

  const fetchData = useCallback(async () => {
    try {
      const res = await apiGet('/api/overview');
      if (res.ok) {
        const json = await res.json();
        setData(json);
        setError(null);
      } else {
        setError('Failed to load dashboard data');
      }
    } catch {
      setError('Network error');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  useEffect(() => {
    const now = new Date();
    setGreeting(
      now.getHours() < 12 ? 'Good morning' : now.getHours() < 18 ? 'Good afternoon' : 'Good evening'
    );
    setDateLabel(
      now.toLocaleDateString('en-AU', {
        weekday: 'long',
        day: 'numeric',
        month: 'long',
        year: 'numeric',
      })
    );
  }, []);

  return (
    <AppLayout>
      {/* Header */}
      <div className="mb-8 flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1
            className="text-2xl text-[#1F1F1F] font-semibold"
            style={{ fontFamily: 'Cardo, serif' }}
            suppressHydrationWarning
          >
            {greeting || ' '}
          </h1>
          <p
            className="text-[#505052] text-sm mt-1"
            style={{ fontFamily: 'Inter, sans-serif' }}
            suppressHydrationWarning
          >
            {dateLabel || ' '}
          </p>
        </div>
        {/* JC-332/JC-367 — 1-click Executive Summary */}
        <button
          type="button"
          onClick={() => setExecSummaryOpen(true)}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-[#931220] text-white text-sm font-medium hover:bg-[#7a0f1b] transition-colors shadow-sm"
          style={{ fontFamily: 'Inter, sans-serif' }}
          data-testid="run-executive-summary"
        >
          <FileText size={16} />
          Run Executive Summary
        </button>
      </div>

      <ExecutiveSummaryModal isOpen={execSummaryOpen} onClose={() => setExecSummaryOpen(false)} />

      {loading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
          {[...Array(4)].map((_, i) => (
            <div key={i} className="bg-white rounded-xl border border-[#D8D9DA] p-6 animate-pulse">
              <div className="h-4 bg-gray-200 rounded w-24 mb-4" />
              <div className="h-8 bg-gray-200 rounded w-32" />
            </div>
          ))}
        </div>
      ) : error ? (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-red-700">
          {error}
        </div>
      ) : data ? (
        <div className="space-y-8">
          {/* Alerts */}
          {data.alerts.recent_errors > 0 && (
            <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 flex items-center gap-3">
              <AlertTriangle size={20} className="text-amber-600 flex-shrink-0" />
              <p className="text-amber-800 text-sm" style={{ fontFamily: 'Inter, sans-serif' }}>
                {`${data.alerts.recent_errors} sync error(s) in last 24h. Check Admin for details.`}
              </p>
            </div>
          )}

          {/* Sync status bar */}
          {(() => {
            // Derive status from same 24h error window as the banner above,
            // plus a 12h staleness threshold on last_sync.
            const hasRecentErrors = data.alerts.recent_errors > 0;
            const lastSyncDate = data.alerts.last_sync ? new Date(data.alerts.last_sync) : null;
            const hoursSinceLastSync = lastSyncDate
              ? (Date.now() - lastSyncDate.getTime()) / (1000 * 60 * 60)
              : Infinity;
            const isStale = !hasRecentErrors && hoursSinceLastSync > 12;
            const isHealthy = !hasRecentErrors && !isStale;

            const label = hasRecentErrors
              ? 'Recent sync errors'
              : isStale
                ? 'Last sync stale'
                : 'All systems synced';

            return (
              <div className="flex items-center gap-2 text-xs text-[#505052]" style={{ fontFamily: 'Inter, sans-serif' }}>
                {isHealthy ? (
                  <CheckCircle size={14} className="text-[#1B7A3D]" />
                ) : (
                  <AlertTriangle size={14} className="text-amber-500" />
                )}
                <span>{label}</span>
                <Clock size={14} className="ml-2" />
                <span>Last sync: {formatTimeAgo(data.alerts.last_sync)}</span>
              </div>
            );
          })()}

          {/* KPI Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
            <div className="relative h-full">
              <MetricCard
                label="Revenue (Prev Month)"
                value={data.kpis.revenue_mtd === 0 ? 'No data yet' : formatCurrency(data.kpis.revenue_mtd)}
                trend={data.kpis.revenue_trend != null && data.kpis.revenue_trend !== 0 ? {
                  value: Math.abs(data.kpis.revenue_trend),
                  isPositive: data.kpis.revenue_trend > 0,
                } : undefined}
                subtitle={data.kpis.revenue_mtd === 0 ? 'No complete month data' : 'vs month before'}
                icon={<DollarSign size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['Revenue (Prev Month)']} className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Gross Profit (Prev Month)"
                value={data.kpis.revenue_mtd === 0 ? 'No data yet' : formatCurrency(data.kpis.gross_profit_mtd)}
                subtitle={data.kpis.revenue_mtd === 0 ? 'No complete month data' : 'Economic basis'}
                icon={<TrendingUp size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['Gross Profit (Prev Month)']} className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Active SKUs"
                value={`${data.kpis.active_skus}`}
                subtitle={`of ${data.kpis.total_skus} total`}
                icon={<Wine size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['Active SKUs']} className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Catalog Value"
                value={formatCurrency(data.kpis.inventory_value)}
                subtitle="Total wholesale (all SKUs)"
                icon={<Package size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['Catalog Value']} className="absolute top-3 right-3" />
            </div>
          </div>

          {/* Revenue by Channel Chart */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2
              className="text-lg text-[#1F1F1F] font-semibold mb-1"
              style={{ fontFamily: 'Cardo, serif' }}
            >
              Revenue by Warehouse
              <InfoTooltip text="Net revenue by warehouse/partner over the last 13 months. DWS = consignment (sell-through revenue when customer buys). ALM = wholesale (revenue on invoice to ALM). Direct = invoiced sales via Vinsight." className="inline-flex ml-1.5 align-middle" />
            </h2>
            <p
              className="text-[#505052] text-sm mb-4"
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              Last 13 months — DWS, ALM, Direct
            </p>
            <StackedBarChart
              data={data.revenue_by_channel}
              xAxisKey="month"
              series={[
                { key: 'dws', name: 'DWS', color: '#931220' },
                { key: 'alm', name: 'ALM', color: '#BEB3AB' },
                { key: 'direct', name: 'Direct', color: '#1B7A3D' },
              ]}
              height={350}
            />
          </div>

          {/* Top 5 Wines */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2
              className="text-lg text-[#1F1F1F] font-semibold mb-4"
              style={{ fontFamily: 'Cardo, serif' }}
            >
              Top 5 Wines by Revenue
            </h2>
            <div className="overflow-x-auto">
              <table className="w-full text-sm" style={{ fontFamily: 'Inter, sans-serif' }}>
                <thead>
                  <tr className="border-b border-[#D8D9DA]">
                    <th className="text-left py-3 px-4 text-[#505052] font-medium">#</th>
                    <th className="text-left py-3 px-4 text-[#505052] font-medium">Wine <InfoTooltip text={COLUMN_TOOLTIPS['Wine']} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                    <th className="text-left py-3 px-4 text-[#505052] font-medium">Variety <InfoTooltip text={COLUMN_TOOLTIPS['Variety']} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                    <th className="text-left py-3 px-4 text-[#505052] font-medium">Region <InfoTooltip text={COLUMN_TOOLTIPS['Region']} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                    <th className="text-right py-3 px-4 text-[#505052] font-medium">Revenue <InfoTooltip text={COLUMN_TOOLTIPS['Revenue']} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                    <th className="text-right py-3 px-4 text-[#505052] font-medium">Qty <InfoTooltip text={COLUMN_TOOLTIPS['Qty']} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                    <th className="text-right py-3 px-4 text-[#505052] font-medium">GP% <InfoTooltip text={COLUMN_TOOLTIPS['GP%']} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  </tr>
                </thead>
                <tbody>
                  {data.top_wines.map((wine, idx) => (
                    <tr key={wine.sku_code} className="border-b border-[#D8D9DA]/50 hover:bg-[#FAF9F7]">
                      <td className="py-3 px-4 text-[#505052]">{idx + 1}</td>
                      <td className="py-3 px-4">
                        <div className="text-[#1F1F1F] font-medium">{wine.item_description}</div>
                        <div className="text-[#505052]/70 text-xs">{wine.sku_code}</div>
                      </td>
                      <td className="py-3 px-4 text-[#505052]">{wine.variety || '—'}</td>
                      <td className="py-3 px-4 text-[#505052]">{wine.region || '—'}</td>
                      <td className="py-3 px-4 text-right text-[#1F1F1F] font-medium">
                        {formatCurrency(parseFloat(String(wine.total_revenue)))}
                      </td>
                      <td className="py-3 px-4 text-right text-[#505052]">
                        {parseInt(String(wine.total_qty)).toLocaleString()}
                      </td>
                      <td className="py-3 px-4 text-right">
                        <Badge variant={
                          parseFloat(String(wine.gp_pct)) >= 40 ? 'success' :
                          parseFloat(String(wine.gp_pct)) >= 25 ? 'warning' : 'error'
                        }>
                          {wine.gp_pct}%
                        </Badge>
                      </td>
                    </tr>
                  ))}
                  {data.top_wines.length === 0 && (
                    <tr>
                      <td colSpan={7} className="py-8 text-center text-[#505052]">
                        No sales data available
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      ) : null}
    </AppLayout>
  );
}

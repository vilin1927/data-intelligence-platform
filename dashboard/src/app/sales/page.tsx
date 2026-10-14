'use client';

import { useEffect, useState, useMemo, useCallback } from 'react';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import Badge from '@/components/Badge';
import { StackedBarChart, MultiLineChart } from '@/components/Charts';
import {
  Package,
  DollarSign,
  Users,
  Filter,
  Download,
  BarChart3,
  UserPlus,
  UserMinus,
  UserCheck,
} from 'lucide-react';
import InfoTooltip from '@/components/InfoTooltip';

// ─── Types ───────────────────────────────────────────────────────────────

interface SalesKpis {
  total_cases: number;
  total_cases_yoy: number | null;
  total_revenue: number;
  total_revenue_yoy: number | null;
  active_customers: number;
  active_customers_prior: number;
  avg_wholesale_per_case: number;
  avg_wholesale_per_case_yoy: number | null;
  active_distributions: number;
  new_distributions: number;
  lost_distributions: number;
  new_customers: number;
  lost_customers: number;
  active_customers_window: number;
}

interface RevenueMonth {
  month: string;
  dws: number;
  alm: number;
  direct: number;
  total: number;
  yoy_total: number;
}

interface TerritoryRow {
  territory: string;
  cases: number;
  gross_revenue: number;
  total_discounts: number;
  total_rebates: number;
  total_fees: number;
  revenue: number;
  gp_pct: number;
  trend_pct: number | null;
  mqt_revenue: number;
  mqt_variance_pct: number | null;
}

interface RepRow {
  rep_name: string;
  territories: string;
  cases: number;
  revenue: number;
}

interface CustomerRow {
  customer_name: string;
  channel: string;
  territory: string;
  cases: number;
  revenue: number;
  since: number;
}

interface SalesData {
  kpis: SalesKpis;
  revenue_by_channel: RevenueMonth[];
  territory_performance: TerritoryRow[];
  rep_leaderboard: RepRow[];
  top_customers: CustomerRow[];
  filters: {
    channels: string[];
    territories: string[];
    suburbs: string[];
    territory_groups: string[];
  };
}

// ─── Helpers ─────────────────────────────────────────────────────────────

function formatCurrency(value: number): string {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  return `$${value.toFixed(0)}`;
}

function formatNumber(value: number): string {
  return value.toLocaleString('en-AU', { maximumFractionDigits: 0 });
}

const RANK_COLORS = ['#931220', '#BEB3AB', '#8A8A8D'];

const font = { fontFamily: 'Inter, sans-serif' };

// ─── Component ───────────────────────────────────────────────────────────

export default function SalesAnalyticsPage() {
  const [data, setData] = useState<SalesData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [channelFilter, setChannelFilter] = useState<string>('all');
  const [suburbFilter, setSuburbFilter] = useState<string>('all');
  const [territoryGroupFilter, setTerritoryGroupFilter] = useState<string>('all');
  const [showFilters, setShowFilters] = useState(false);
  const [period, setPeriod] = useState<number>(12);

  const fetchData = useCallback(async () => {
    try {
      // R-003: pass warehouse selector through to /api/sales so KPI/chart/leaderboard refilter
      const wh = channelFilter && channelFilter !== 'all' ? `&warehouse=${encodeURIComponent(channelFilter)}` : '';
      // JC-345-RPT: suburb + territory_group filters (schema/122 + sales/route.ts)
      const sb = suburbFilter && suburbFilter !== 'all' ? `&suburb=${encodeURIComponent(suburbFilter)}` : '';
      const tg = territoryGroupFilter && territoryGroupFilter !== 'all' ? `&territory_group=${encodeURIComponent(territoryGroupFilter)}` : '';
      const res = await apiGet(`/api/sales?period=${period}${wh}${sb}${tg}`);
      if (res.ok) {
        const json = await res.json();
        setData(json);
        setError(null);
      } else {
        setError('Failed to load sales data');
      }
    } catch {
      setError('Network error');
    } finally {
      setLoading(false);
    }
  }, [period, channelFilter, suburbFilter, territoryGroupFilter]);

  useEffect(() => { fetchData(); }, [fetchData]);

  // Prepare chart data for revenue by channel
  const chartData = useMemo(() => {
    if (!data) return [];
    return data.revenue_by_channel.map(r => ({
      month: r.month,
      DWS: Math.round(r.dws),
      ALM: Math.round(r.alm),
      Direct: Math.round(r.direct),
      'Last Year': Math.round(r.yoy_total),
    }));
  }, [data]);

  function exportCsv() {
    if (!data) return;
    const sections: string[] = [];

    // Territory data
    sections.push('Territory Performance');
    sections.push('Territory,Cases,Gross Revenue,Discounts,Rebates,Fees,Net Revenue,MQT Revenue,MQT Variance,GP%,Trend');
    for (const t of data.territory_performance) {
      sections.push(`${t.territory},${t.cases},${t.gross_revenue},${t.total_discounts},${t.total_rebates},${t.total_fees},${t.revenue},${t.mqt_revenue},${t.mqt_variance_pct !== null ? t.mqt_variance_pct + '%' : 'N/A'},${t.gp_pct}%,${t.trend_pct !== null ? t.trend_pct + '%' : 'N/A'}`);
    }
    sections.push('');

    // Rep data
    sections.push('Rep Leaderboard');
    sections.push('Rep,Territories,Cases,Revenue');
    for (const r of data.rep_leaderboard) {
      sections.push(`"${r.rep_name}","${r.territories}",${r.cases},${r.revenue}`);
    }
    sections.push('');

    // Customer data
    sections.push('Top Customers');
    sections.push('Customer,Channel,Territory,Cases,Revenue,Since');
    for (const c of data.top_customers) {
      sections.push(`"${c.customer_name}",${c.channel},"${c.territory}",${c.cases},${c.revenue},${c.since}`);
    }

    const csv = sections.join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `sales-analytics-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  return (
    <AppLayout>
      {/* Header */}
      <div className="flex items-start justify-between mb-6">
        <div>
          <h1 className="text-2xl text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
            Sales Analytics
          </h1>
          <p className="text-[#8A8A8D] text-sm mt-1" style={font}>
            Territory, rep, and customer performance across all warehouses
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center rounded-lg border border-[#D8D9DA] overflow-hidden">
            {[6, 12, 24].map((p) => (
              <button
                key={p}
                onClick={() => { setPeriod(p); setLoading(true); }}
                className={`px-3 py-1.5 text-xs font-medium transition-colors ${
                  period === p
                    ? 'bg-[#931220] text-white'
                    : 'bg-[#FAF9F7] text-[#505052] hover:bg-white'
                }`}
                style={font}
              >
                {p}m
              </button>
            ))}
          </div>
          <button
            onClick={() => setShowFilters(!showFilters)}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium border transition-colors ${
              showFilters
                ? 'bg-[#931220]/10 text-[#931220] border-[#931220]/20'
                : 'bg-[#FAF9F7] border-[#D8D9DA] text-[#505052] hover:bg-white'
            }`}
            style={font}
          >
            <Filter size={14} />
            {(() => {
              const active = [channelFilter, suburbFilter, territoryGroupFilter].filter(f => f !== 'all').length;
              return active === 0 ? 'Filters' : `${active} filter${active > 1 ? 's' : ''}`;
            })()}
          </button>
          <button
            onClick={exportCsv}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors"
            style={font}
          >
            <Download size={14} />
            Export
          </button>
        </div>
      </div>

      {/* Filters panel — warehouse + suburb (JC-345) + territory_group (JC-345) */}
      {showFilters && data && (
        <div className="bg-white rounded-xl border border-[#D8D9DA] p-4 mb-6 shadow-sm">
          <div className="flex flex-wrap items-center gap-x-6 gap-y-3">
            {/* Warehouse */}
            <div className="flex items-center gap-2">
              <label className="text-xs text-[#505052] font-medium" style={font}>Warehouse:</label>
              <select
                value={channelFilter}
                onChange={e => setChannelFilter(e.target.value)}
                className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                style={font}
              >
                <option value="all">All Warehouses</option>
                {data.filters.channels.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>

            {/* Territory Group (JC-345) */}
            <div className="flex items-center gap-2">
              <label className="text-xs text-[#505052] font-medium" style={font}>Territory Group:</label>
              <select
                value={territoryGroupFilter}
                onChange={e => setTerritoryGroupFilter(e.target.value)}
                className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                style={font}
              >
                <option value="all">All Territory Groups</option>
                {data.filters.territory_groups.map(g => <option key={g} value={g}>{g}</option>)}
              </select>
            </div>

            {/* Suburb (JC-345) — combobox via datalist (1k+ options, exact match) */}
            <div className="flex items-center gap-2">
              <label className="text-xs text-[#505052] font-medium" style={font}>Suburb:</label>
              <input
                type="text"
                list="suburb-options"
                value={suburbFilter === 'all' ? '' : suburbFilter}
                onChange={e => setSuburbFilter(e.target.value === '' ? 'all' : e.target.value)}
                placeholder="All Suburbs"
                className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white w-44"
                style={font}
              />
              <datalist id="suburb-options">
                {data.filters.suburbs.map(s => <option key={s} value={s} />)}
              </datalist>
            </div>

            {/* Clear all */}
            {[channelFilter, suburbFilter, territoryGroupFilter].some(f => f !== 'all') && (
              <button
                onClick={() => { setChannelFilter('all'); setSuburbFilter('all'); setTerritoryGroupFilter('all'); }}
                className="text-xs text-[#931220] hover:underline"
                style={font}
              >
                Clear all
              </button>
            )}
          </div>
        </div>
      )}

      {loading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-6">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="bg-white rounded-xl border border-[#D8D9DA] p-6 animate-pulse">
              <div className="h-4 bg-gray-200 rounded w-24 mb-4" />
              <div className="h-8 bg-gray-200 rounded w-32" />
            </div>
          ))}
        </div>
      ) : error ? (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-red-700">{error}</div>
      ) : data ? (
        <div className="space-y-6">
          {/* KPI Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4">
            <div className="relative h-full">
              <MetricCard
                label="Total Cases Sold"
                value={formatNumber(data.kpis.total_cases)}
                trend={data.kpis.total_cases_yoy !== null ? {
                  value: data.kpis.total_cases_yoy,
                  isPositive: data.kpis.total_cases_yoy >= 0,
                } : undefined}
                subtitle={`Last ${period} months`}
                icon={<Package size={20} />}
              />
              <InfoTooltip text="Total cases sold across all warehouses (DWS, ALM, Direct) in the last 12 months. YOY trend compares to same period last year." className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Revenue (All Warehouses)"
                value={formatCurrency(data.kpis.total_revenue)}
                trend={data.kpis.total_revenue_yoy !== null ? {
                  value: data.kpis.total_revenue_yoy,
                  isPositive: data.kpis.total_revenue_yoy >= 0,
                } : undefined}
                subtitle={`Last ${period} months`}
                icon={<DollarSign size={20} />}
              />
              <InfoTooltip text="Net revenue from all warehouses combined. DWS revenue = sell-through (consignment). ALM revenue = wholesale invoice. Direct = Vinsight invoices." className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Active Customers"
                value={formatNumber(data.kpis.active_customers)}
                subtitle={data.kpis.active_customers > data.kpis.active_customers_prior
                  ? `+${data.kpis.active_customers - data.kpis.active_customers_prior} new`
                  : `${data.kpis.active_customers - data.kpis.active_customers_prior} vs prior year`}
                icon={<Users size={20} />}
              />
              <InfoTooltip text="Distinct customers who placed at least one order in the last 12 months. Compared to the prior 12-month period." className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Avg Wholesale $/Case"
                value={`$${data.kpis.avg_wholesale_per_case.toFixed(2)}`}
                trend={data.kpis.avg_wholesale_per_case_yoy !== null ? {
                  value: data.kpis.avg_wholesale_per_case_yoy,
                  isPositive: data.kpis.avg_wholesale_per_case_yoy >= 0,
                } : undefined}
                subtitle="Net revenue / cases"
                icon={<DollarSign size={20} />}
              />
              <InfoTooltip text="Average wholesale price per case (total net revenue ÷ total cases sold). Measures pricing power across all channels." className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm h-full">
                <div className="flex items-start justify-between">
                  <div>
                    <p className="text-[#505052] text-sm font-medium" style={font}>
                      Distributions
                    </p>
                    <p className="text-[#1F1F1F] text-2xl font-semibold mt-1" style={{ fontFamily: 'Cardo, serif' }}>
                      {formatNumber(data.kpis.active_distributions)}
                    </p>
                    <div className="flex items-center gap-2 mt-2 flex-wrap">
                      <span className="text-[10px] px-1.5 py-0.5 rounded bg-[#1B7A3D]/10 text-[#1B7A3D] font-medium" style={font}>
                        +{formatNumber(data.kpis.new_distributions)} new
                      </span>
                      <span className="text-[10px] px-1.5 py-0.5 rounded bg-[#B42318]/10 text-[#B42318] font-medium" style={font}>
                        {'\u2212'}{formatNumber(data.kpis.lost_distributions)} lost
                      </span>
                    </div>
                    <p className="text-[#505052]/70 text-xs mt-2" style={font}>
                      Active SKU-customer pairs (6mo)
                    </p>
                  </div>
                  <div className="w-10 h-10 rounded-lg bg-[#931220]/10 flex items-center justify-center text-[#931220]">
                    <BarChart3 size={20} />
                  </div>
                </div>
              </div>
              <InfoTooltip text="Active: distinct (customer, SKU) pairs with a sale in last 6 months. New: pairs with a sale in last 6 months but none in months 7-12. Lost: pairs with sales in months 7-12 but none in last 6 months." className="absolute top-3 right-3" />
            </div>
          </div>

          {/* Customer Activity Trio (BUG-51 / JR-060) — the owner Mar 25 definitions */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div className="relative h-full">
              <MetricCard
                label="Active Customers (6mo)"
                value={formatNumber(data.kpis.active_customers_window)}
                subtitle="Ordered in last 6 months"
                icon={<UserCheck size={20} />}
              />
              <InfoTooltip text="Customers who placed at least one order in the last 6 months." className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="New Customers"
                value={formatNumber(data.kpis.new_customers)}
                subtitle="First ever order in last 12 months"
                icon={<UserPlus size={20} />}
              />
              <InfoTooltip text="Customers whose earliest order is within the last 12 months — no prior order history." className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Lost Customers"
                value={formatNumber(data.kpis.lost_customers)}
                subtitle="Ordered 7-12mo ago, not since"
                icon={<UserMinus size={20} />}
              />
              <InfoTooltip text="Customers who ordered 7-12 months ago but have not ordered in the last 6 months." className="absolute top-3 right-3" />
            </div>
          </div>

          {/* JC-340 — MAT / MMT / MQT card trio */}
          {(() => {
            const months = data.revenue_by_channel || [];
            const monthTotal = (m: typeof months[number] | undefined) =>
              m ? Number(m.dws || 0) + Number(m.alm || 0) + Number(m.direct || 0) : 0;
            // Series ends with the last reported month (no partial-month exclusion in /api/sales).
            const lastIdx = months.length - 1;
            const matWindow = months.slice(Math.max(0, months.length - 12));
            const matTotal = matWindow.reduce((s, m) => s + monthTotal(m), 0);
            const current = months[lastIdx];
            const prev = months[lastIdx - 1];
            const currentTotal = monthTotal(current);
            const prevTotal = monthTotal(prev);
            const mmtPct = prevTotal > 0 ? Math.round(((currentTotal - prevTotal) / prevTotal) * 100) : null;
            const lastQ = months.slice(Math.max(0, lastIdx - 2), lastIdx + 1);
            const priorQ = months.slice(Math.max(0, lastIdx - 5), Math.max(0, lastIdx - 2));
            const lastQTotal = lastQ.reduce((s, m) => s + monthTotal(m), 0);
            const priorQTotal = priorQ.reduce((s, m) => s + monthTotal(m), 0);
            const mqtPct = priorQTotal > 0 ? Math.round(((lastQTotal - priorQTotal) / priorQTotal) * 100) : null;
            return (
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <div className="relative h-full">
                  <MetricCard
                    label="MAT — Moving Annual Total"
                    value={formatCurrency(matTotal)}
                    subtitle={`12 months ending ${current?.month ?? '—'}`}
                  />
                  <InfoTooltip text="MAT — sum of net revenue across the trailing 12 months." className="absolute top-3 right-3" />
                </div>
                <div className="relative h-full">
                  <MetricCard
                    label="MMT — Month-on-Month"
                    value={formatCurrency(currentTotal)}
                    trend={mmtPct !== null && mmtPct !== 0 ? { value: Math.abs(mmtPct), isPositive: mmtPct > 0 } : undefined}
                    subtitle={`${current?.month ?? '—'} vs ${prev?.month ?? '—'}`}
                    icon={<BarChart3 size={20} />}
                  />
                  <InfoTooltip text="MMT — most recent month with delta vs prior month." className="absolute top-3 right-3" />
                </div>
                <div className="relative h-full">
                  <MetricCard
                    label="MQT — Moving Quarterly Total"
                    value={formatCurrency(lastQTotal)}
                    trend={mqtPct !== null && mqtPct !== 0 ? { value: Math.abs(mqtPct), isPositive: mqtPct > 0 } : undefined}
                    subtitle="Last 3 mo vs prior 3 mo"
                  />
                  <InfoTooltip text="MQT — last 3 months total with delta vs prior 3 months." className="absolute top-3 right-3" />
                </div>
              </div>
            );
          })()}

          {/* Revenue by Warehouse Chart */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <div className="mb-4">
              <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                Revenue by Warehouse
                <InfoTooltip text="Stacked bars show revenue split by DWS (consignment), ALM (wholesale), and Direct channels. Line chart below overlays this year vs last year for trend comparison." size={10} className="inline-flex ml-1.5 align-middle" />
              </h2>
              <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                {period + 1}-month trend with year-over-year comparison
              </p>
            </div>
            <StackedBarChart
              data={chartData}
              xAxisKey="month"
              series={[
                { key: 'DWS', name: 'DWS', color: '#931220' },
                { key: 'ALM', name: 'ALM', color: '#BEB3AB' },
                { key: 'Direct', name: 'Direct', color: '#1B7A3D' },
              ]}
              height={320}
            />
            <div className="mt-4">
              <MultiLineChart
                data={chartData}
                xAxisKey="month"
                series={[
                  { key: 'DWS', name: 'This Year (DWS)', color: '#931220' },
                  { key: 'ALM', name: 'This Year (ALM)', color: '#BEB3AB' },
                  { key: 'Direct', name: 'This Year (Direct)', color: '#1B7A3D' },
                  { key: 'Last Year', name: 'Last Year (Total)', color: '#D8D9DA' },
                ]}
                height={200}
              />
            </div>
          </div>

          {/* Territory Performance + Rep Leaderboard + Top Customers */}
          <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
            {/* Territory Performance — spans 3 cols */}
            <div className="lg:col-span-3 bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
              <div className="p-5 pb-0">
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Territory Performance
                  <InfoTooltip text="Sales performance by geographic territory. Trend compares last 6 months to the prior 6 months. GP% is revenue-weighted accounting gross profit." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  Cases sold and revenue by region (last 6 months vs prior 6 months)
                </p>
              </div>
              <div className="overflow-x-auto mt-4">
                <table className="w-full text-xs" style={font}>
                  <thead>
                    <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                      <th className="py-2.5 px-5 text-left text-[#505052] font-medium">Territory</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">Cases</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">Gross Rev</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">Deductions</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">Net Rev</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">MQT Rev</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">MQT Var</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">GP%</th>
                      <th className="py-2.5 px-4 text-right text-[#505052] font-medium">Trend</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.territory_performance.map((t) => {
                      const totalDeductions = t.total_discounts + t.total_rebates + t.total_fees;
                      return (
                      <tr key={t.territory} className="border-b border-[#D8D9DA]/30 hover:bg-[#FAF9F7]">
                        <td className="py-3 px-5 text-[#1F1F1F] font-medium">
                          <a href={`/legacy-data?type=territory&territory=${encodeURIComponent(t.territory)}`} className="text-[#931220] hover:underline">{t.territory}</a>
                        </td>
                        <td className="py-3 px-4 text-right text-[#505052]">{formatNumber(t.cases)}</td>
                        <td className="py-3 px-4 text-right text-[#505052]">{formatCurrency(t.gross_revenue)}</td>
                        <td className="py-3 px-4 text-right text-[#B42318]">
                          {totalDeductions > 0 ? `-${formatCurrency(totalDeductions)}` : '$0'}
                        </td>
                        <td className="py-3 px-4 text-right text-[#1F1F1F] font-medium">{formatCurrency(t.revenue)}</td>
                        <td className="py-3 px-4 text-right text-[#505052]">{formatCurrency(t.mqt_revenue)}</td>
                        <td className="py-3 px-4 text-right">
                          {t.mqt_variance_pct !== null ? (() => {
                            // B5 fix: cap displayed MQT Var at \u00b1999% to suppress noisy outliers
                            // caused by tiny prior-period bases (e.g. +8169% for Head Office).
                            // Surface the raw value via tooltip when capped.
                            const raw = t.mqt_variance_pct;
                            const capped = Math.abs(raw) > 999;
                            const display = capped ? (raw >= 0 ? 999 : -999) : raw;
                            const tooltip = capped
                              ? `Raw value: ${raw >= 0 ? '+' : ''}${raw.toFixed(1)}% (capped \u2014 low prior-period base)`
                              : undefined;
                            return (
                              <span
                                className={display >= 0 ? 'text-[#1B7A3D]' : 'text-[#B42318]'}
                                title={tooltip}
                                style={tooltip ? { cursor: 'help', borderBottom: '1px dotted currentColor' } : undefined}
                              >
                                {display >= 0 ? '+' : '\u2212'}{Math.abs(display)}{capped ? '%+' : '%'}
                              </span>
                            );
                          })() : (
                            <span className="text-[#D8D9DA]">{'\u2014'}</span>
                          )}
                        </td>
                        <td className="py-3 px-4 text-right">
                          <Badge variant={t.gp_pct >= 35 ? 'success' : t.gp_pct >= 25 ? 'warning' : 'error'}>
                            {t.gp_pct.toFixed(1)}%
                          </Badge>
                        </td>
                        <td className="py-3 px-4 text-right">
                          {t.trend_pct !== null ? (
                            <span className={t.trend_pct >= 0 ? 'text-[#1B7A3D]' : 'text-[#B42318]'}>
                              {t.trend_pct >= 0 ? '+' : ''}{t.trend_pct}%
                            </span>
                          ) : (
                            <span className="text-[#D8D9DA]">{'\u2014'}</span>
                          )}
                        </td>
                      </tr>
                      );
                    })}
                    {data.territory_performance.length === 0 && (
                      <tr>
                        <td colSpan={9} className="py-8 text-center text-[#505052]">No territory data</td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
            </div>

            {/* Right column: Rep Leaderboard + Top Customers */}
            <div className="lg:col-span-2 space-y-6">
              {/* Rep Leaderboard */}
              <div className="bg-white rounded-xl border border-[#D8D9DA] p-5 shadow-sm">
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Rep Leaderboard
                  <InfoTooltip text="Sales representatives ranked by total revenue. Territory assignments come from the rep-territory mapping table. Shows top 5." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5 mb-4" style={font}>
                  Top performing sales reps by revenue
                </p>
                <div className="space-y-3">
                  {data.rep_leaderboard.slice(0, 5).map((rep, index) => (
                    <div key={rep.rep_name} className="flex items-center gap-3">
                      {/* Rank badge */}
                      <div
                        className="w-7 h-7 rounded-full flex items-center justify-center text-white text-xs font-bold shrink-0"
                        style={{ backgroundColor: RANK_COLORS[index] || '#D8D9DA' }}
                      >
                        {index + 1}
                      </div>
                      {/* Name + details */}
                      <div className="flex-1 min-w-0">
                        <p className="text-sm text-[#1F1F1F] font-medium truncate" style={font}>{rep.rep_name}</p>
                        <p className="text-[10px] text-[#8A8A8D]" style={font}>
                          {rep.territories || 'No territory'} &middot; {formatNumber(rep.cases)} cases
                        </p>
                      </div>
                      {/* Revenue */}
                      <p className="text-sm text-[#1F1F1F] font-semibold shrink-0" style={{ fontFamily: 'Cardo, serif' }}>
                        {formatCurrency(rep.revenue)}
                      </p>
                    </div>
                  ))}
                  {data.rep_leaderboard.length === 0 && (
                    <p className="text-xs text-[#505052] text-center py-4" style={font}>No rep data</p>
                  )}
                </div>
              </div>

              {/* Top Customers */}
              <div className="bg-white rounded-xl border border-[#D8D9DA] p-5 shadow-sm">
                <h2 className="text-base text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
                  Top Customers
                  <InfoTooltip text="Highest-revenue customers across all warehouses. Customer names are matched across DWS, ALM, and Direct systems. 'Since' shows first order year." size={10} className="inline-flex ml-1.5 align-middle" />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5 mb-4" style={font}>
                  By revenue — cross-system name matching
                </p>
                <div className="space-y-3">
                  {data.top_customers.slice(0, 5).map((cust) => (
                    <div key={`${cust.customer_name}-${cust.channel}`} className="flex items-center gap-3">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-1.5">
                          <p className="text-sm text-[#1F1F1F] font-medium truncate" style={font}>
                            {cust.customer_name}
                          </p>
                          {cust.channel && (
                            <span className="shrink-0 text-[10px] px-1.5 py-0.5 rounded bg-[#F5F4F2] text-[#505052] font-normal">
                              {cust.channel}
                            </span>
                          )}
                        </div>
                        <p className="text-[10px] text-[#8A8A8D]" style={font}>
                          {cust.territory || 'Unknown'} &middot; {formatNumber(cust.cases)} cases{cust.since ? ` \u00B7 since ${cust.since}` : ''}
                        </p>
                      </div>
                      <p className="text-sm text-[#1F1F1F] font-semibold shrink-0" style={{ fontFamily: 'Cardo, serif' }}>
                        {formatCurrency(cust.revenue)}
                      </p>
                    </div>
                  ))}
                  {data.top_customers.length === 0 && (
                    <p className="text-xs text-[#505052] text-center py-4" style={font}>No customer data</p>
                  )}
                </div>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </AppLayout>
  );
}

'use client';

import { useEffect, useState, useMemo, useCallback, useRef, Fragment } from 'react';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import Badge from '@/components/Badge';
import MonthPicker from '@/components/MonthPicker';
import {
  DollarSign,
  TrendingUp,
  AlertTriangle,
  Activity,
  Filter,
  Download,
  ChevronDown,
  ChevronRight,
  Database,
} from 'lucide-react';
import InfoTooltip, { InfoBanner } from '@/components/InfoTooltip';

// ─── Types ───────────────────────────────────────────────────────────────

interface GrapeComponent {
  variety: string;
  region: string;
  vintage: number;
  color: string;
  proportion: number;
}

interface GrapePriceRule {
  region: string | null;
  color: string | null;
  grade: number | null;
  variety: string | null;
  vintage: number;
  price_per_ton: number;
}

interface SkuData {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  sku_group: string | null;
  canonical_sku_id: number | null;
  canonical_sku_name: string | null;
  base_wholesale: number;
  transfer_cost: number;
  range_name: string | null;
  total_revenue: number;
  total_qty: number;
  velocity_12m: number;
  velocity_6m: number;
  velocity_3m: number;
  units_in_stock: number;
  stock_cover_months: number | null;
  channels: Record<string, { revenue: number; qty: number }>;
  economic_cogs_per_unit: number;
  grape_components: GrapeComponent[];
}

interface MarginData {
  skus: SkuData[];
  grape_price_rules: GrapePriceRule[];
  filters: {
    channels: string[];          // warehouse channels (DWS/ALM/Direct)
    ranges: string[];
    vintages: number[];
    territories: string[];
    reps: string[];
    customer_channels: string[]; // JF-05: on-prem/off-prem/wholesale/etc
  };
  date_range: {
    earliest_month: string | null;
    latest_month: string | null;
  };
}

interface CalculatedSku extends SkuData {
  accounting_cogs: number;
  economic_cogs: number;
  gp_pct_accounting: number;
  gp_pct_economic: number;
  gp_pct_avg: number;
  delta_gp_pct: number;
  has_economic_price: boolean;
  children?: CalculatedSku[];
  is_nv_parent?: boolean;
}

// ─── Economic COGS Cascade (same as What-If Calculator) ──────────────────

const RANGE_TO_GRADE: Record<string, number> = {
  'MOPPITY RESERVE': 1, 'COPPABELLA SIRIUS': 1, 'ATRIUS': 1,
  'COPPABELLA CREST': 2, 'BLOCK': 2, 'MOPPITY ESTATE': 2, 'MV EXCLUSIVE': 2,
  'LOCK & KEY': 3, 'Lock & Key': 3, 'COPPABELLA PROCELLA': 3,
  'OPPABELLA PROCELLA': 3, 'TWELVE SIGNS': 3, 'Cato': 3, 'Crafted': 3, 'OTHER': 3,
};

const TONNES_PER_CASE = 1 / 80;

function deriveGrade(rangeName: string | null): number | null {
  if (!rangeName) return null;
  for (const [key, grade] of Object.entries(RANGE_TO_GRADE)) {
    if (rangeName.toUpperCase().includes(key.toUpperCase())) return grade;
  }
  return null;
}

function findBestRule(
  rules: GrapePriceRule[], region: string, color: string,
  grade: number | null, variety: string, vintage: number,
): number {
  const matching = rules.filter(rule =>
    rule.vintage === vintage &&
    (rule.region === null || rule.region === region) &&
    (rule.color === null || rule.color === color) &&
    (rule.grade === null || rule.grade === grade) &&
    (rule.variety === null || rule.variety === variety)
  );
  matching.sort((a, b) => {
    const score = (r: GrapePriceRule) =>
      [r.region, r.color, r.grade, r.variety].filter(v => v !== null).length;
    return score(b) - score(a);
  });
  return matching.length > 0 ? matching[0].price_per_ton : 0;
}

function getEffectiveGrapePrice(
  rules: GrapePriceRule[], region: string, color: string,
  grade: number | null, variety: string, vintage: number,
): number {
  const exactMatch = findBestRule(rules, region, color, grade, variety, vintage);
  if (exactMatch > 0) return exactMatch;
  const allVintages = Array.from(new Set(rules.map(r => r.vintage)));
  for (const v of allVintages) {
    if (v === vintage) continue;
    const fallback = findBestRule(rules, region, color, grade, variety, v);
    if (fallback > 0) return fallback;
  }
  return 0;
}

function calculateEconomicCogs(
  rules: GrapePriceRule[], components: GrapeComponent[], grade: number | null,
): { cogs: number; hasPrice: boolean } {
  let weightedPrice = 0;
  let hasAnyPrice = false;
  for (const comp of components) {
    const price = getEffectiveGrapePrice(rules, comp.region, comp.color, grade, comp.variety, comp.vintage);
    if (price > 0) hasAnyPrice = true;
    weightedPrice += price * comp.proportion;
  }
  return { cogs: weightedPrice * TONNES_PER_CASE, hasPrice: hasAnyPrice };
}

// ─── Helpers ─────────────────────────────────────────────────────────────

const KPI_TOOLTIPS: Record<string, string> = {
  'Total Revenue (12m)': 'Sum of net revenue across all warehouses (DWS, ALM, Direct) for the last 12 months.',
  'Avg GP% (Accounting)': 'Revenue-weighted average gross profit using accounting COGS (transfer cost from Vinsight/Access DB).',
  'Avg GP% (Economic)': 'Revenue-weighted average gross profit using economic grape prices from the What-If calculator rules.',
  'GP% (Whl)': 'Gross profit based on base wholesale price: (wholesale - COGS) / wholesale.',
  'GP% (Avg)': 'Gross profit based on average actual selling price: (avg $/case - COGS) / avg $/case. Reflects real-world margins after discounts/premiums.',
  'Below 25% GP': 'Number of SKUs with gross profit below 25% — these may need pricing review.',
};

function formatCurrency(value: number): string {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  return `$${value.toFixed(0)}`;
}

function formatDollars(value: number): string {
  return `$${value.toFixed(2)}`;
}

const MONTH_NAMES = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// JC-215: returns the month BEFORE the current one as YYYY-MM (the format
// MonthPicker / customFrom / customTo expect). Used to default /margin to the
// previous full month at page mount.
function previousMonthYM(): string {
  const now = new Date();
  const y = now.getFullYear();
  const m = now.getMonth(); // 0..11; subtracting 1 in JS handles year rollover via Date constructor
  const prev = new Date(y, m - 1, 1);
  const yy = prev.getFullYear();
  const mm = String(prev.getMonth() + 1).padStart(2, '0');
  return `${yy}-${mm}`;
}

function formatRangeLabel(from: string, to: string): string {
  const [fy, fm] = from.split('-').map(Number);
  const [ty, tm] = to.split('-').map(Number);
  return `${MONTH_NAMES[fm - 1]} ${fy} — ${MONTH_NAMES[tm - 1]} ${ty}`;
}

// ─── Component ───────────────────────────────────────────────────────────

type CostBasis = 'accounting' | 'economic';
type SortKey = 'item_description' | 'total_revenue' | 'gp_pct' | 'velocity' | 'base_wholesale' | 'cogs' | 'delta_gp_pct';
type VelocityWindow = '3m' | '6m' | '12m';

export default function MarginAnalysisPage() {
  const [data, setData] = useState<MarginData | null>(null);
  // Initial page load skeleton (KPI + filters + table all hidden)
  const [initialLoading, setInitialLoading] = useState(true);
  // Subsequent refetches (e.g. date range change) only replace the table body
  const [tableLoading, setTableLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [costBasis, setCostBasis] = useState<CostBasis>('economic');
  const [channelFilter, setChannelFilter] = useState<string>('all');
  const [rangeFilter, setRangeFilter] = useState<string>('all');
  const [vintageFilter, setVintageFilter] = useState<string>('all');
  // JF-05: rep / territory / customer channel filters (applied server-side).
  const [repFilter, setRepFilter] = useState<string>('all');
  const [territoryFilter, setTerritoryFilter] = useState<string>('all');
  const [customerChannelFilter, setCustomerChannelFilter] = useState<string>('all');
  const [search, setSearch] = useState('');
  const [sortKey, setSortKey] = useState<SortKey>('total_revenue');
  const [sortDesc, setSortDesc] = useState(true);
  const [showFilters, setShowFilters] = useState(false);
  const [displayLimit, setDisplayLimit] = useState(100);
  const [showGuide, setShowGuide] = useState(true);
  const [velocityWindow, setVelocityWindow] = useState<VelocityWindow>('12m');
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set());
  // JC-328 — what-if price ±% slider. Read-only client-side recompute of GP%.
  // 0% = no scenario (table reflects real prices). Range -50% .. +50%.
  const [priceAdjPct, setPriceAdjPct] = useState<number>(0);
  // B7b JC-215: /margin defaults to the previous full month (e.g. lands on
  // "Mar 2026" while today is in Apr 2026), not the trailing 12m. Users keep
  // the picker for ad-hoc ranges.
  const [customFrom, setCustomFrom] = useState<string>(() => previousMonthYM());
  const [customTo, setCustomTo] = useState<string>(() => previousMonthYM());

  const fetchData = useCallback(async (
    from?: string,
    to?: string,
    isInitial = false,
    opts?: { rep?: string; territory?: string; channel?: string },
  ) => {
    try {
      if (isInitial) setInitialLoading(true);
      else setTableLoading(true);
      // Default to 12m period if no custom range is active.
      const qs = new URLSearchParams();
      if (from && to) {
        qs.set('from', from);
        qs.set('to', to);
      } else {
        qs.set('period', '12m');
      }
      if (opts?.rep && opts.rep !== 'all') qs.set('rep', opts.rep);
      if (opts?.territory && opts.territory !== 'all') qs.set('territory', opts.territory);
      if (opts?.channel && opts.channel !== 'all') qs.set('channel', opts.channel);
      const res = await apiGet(`/api/margins?${qs.toString()}`);
      if (res.ok) {
        const json = await res.json();
        setData(json);
        setError(null);
      } else {
        setError('Failed to load margin data');
      }
    } catch {
      setError('Network error');
    } finally {
      if (isInitial) setInitialLoading(false);
      else setTableLoading(false);
    }
  }, []);

  // Initial load runs once on mount. JC-215: seed with the prev-month custom
  // range that customFrom/customTo were initialised with, so the first fetch
  // already filters to the previous month (no 12m → prev-month flicker).
  useEffect(() => {
    fetchData(customFrom || undefined, customTo || undefined, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Track the last set of server-side params we actually fetched with so we can
  // decide whether a given state change warrants a refetch. This avoids the
  // JF-17 flicker from half-picked date ranges while still letting JF-05 attribute
  // filters trigger refetches (including when they're cleared back to "all").
  // JC-215: seed `from`/`to` with the prev-month default the initial fetch used,
  // so the post-mount effect doesn't immediately diff and refetch.
  const lastServerState = useRef<{
    from: string; to: string; rep: string; territory: string; channel: string;
  }>({
    from: customFrom && customTo ? customFrom : '',
    to: customFrom && customTo ? customTo : '',
    rep: 'all', territory: 'all', channel: 'all',
  });

  // Subsequent refetches: fire whenever the effective server-side params differ
  // from what we last requested. Single-date half-selection is ignored by
  // treating from/to as "" until both are picked.
  useEffect(() => {
    if (initialLoading) return;
    const bothDates = !!(customFrom && customTo);
    const effFrom = bothDates ? customFrom : '';
    const effTo = bothDates ? customTo : '';
    const prev = lastServerState.current;
    const unchanged =
      prev.from === effFrom &&
      prev.to === effTo &&
      prev.rep === repFilter &&
      prev.territory === territoryFilter &&
      prev.channel === customerChannelFilter;
    if (unchanged) return;
    lastServerState.current = {
      from: effFrom, to: effTo,
      rep: repFilter, territory: territoryFilter, channel: customerChannelFilter,
    };
    fetchData(
      bothDates ? customFrom : undefined,
      bothDates ? customTo : undefined,
      false,
      { rep: repFilter, territory: territoryFilter, channel: customerChannelFilter },
    );
  }, [
    customFrom, customTo,
    repFilter, territoryFilter, customerChannelFilter,
    fetchData, initialLoading,
  ]);

  const isCustomRange = customFrom !== '' && customTo !== '';

  // Date-range bounds for the MonthPicker popover.
  // Data confirmed: 2019-2025 complete, 2026 partial (Jan-Mar).
  // Fall back to sensible defaults if backend hasn't responded yet.
  const minMonth = data?.date_range?.earliest_month || '2019-01';
  const maxMonth = data?.date_range?.latest_month || '2026-03';

  // Calculate margins for all SKUs
  const calculatedSkus = useMemo<CalculatedSku[]>(() => {
    if (!data) return [];
    return data.skus.map(sku => {
      // M3-01 fix: Use Vinsight transfer_cost as primary COGS source.
      // The owner confirmed (Mar 25): "we're gonna be using those COGS numbers from Vinsight."
      // The grape_price_rule cascade was broken ($22.50 flat for all SKUs).
      // Grape price rules remain available in the What-If calculator for hypothetical modeling.
      const vinsightCogs = sku.transfer_cost || 0;

      // For economic view: always use economic_cogs_per_unit from API (actual market prices)
      // For accounting view: always use transfer_cost from Vinsight
      const grade = deriveGrade(sku.range_name);
      const { cogs: cascadeCogs, hasPrice: hasCascadePrice } = calculateEconomicCogs(data.grape_price_rules, sku.grape_components, grade);
      const economicCogs = sku.economic_cogs_per_unit || cascadeCogs || 0;
      const accountingCogs = vinsightCogs;
      // JC-328 — what-if scenario: scale price by user-set ±%. Read-only client-side.
      const priceAdjFactor = 1 + priceAdjPct / 100;
      const price = (sku.base_wholesale || 0) * priceAdjFactor;

      const gpPctAccounting = price > 0 ? ((price - accountingCogs) / price) * 100 : 0;
      const gpPctEconomic = price > 0 ? ((price - economicCogs) / price) * 100 : 0;

      // GP% (Avg): based on actual average selling price (revenue / cases) instead of base wholesale,
      // also scaled by the what-if price adjustment.
      const avgSellingPrice = sku.total_qty > 0 ? (sku.total_revenue / sku.total_qty) * priceAdjFactor : 0;
      const gpPctAvg = avgSellingPrice > 0 ? ((avgSellingPrice - economicCogs) / avgSellingPrice) * 100 : 0;

      return {
        ...sku,
        accounting_cogs: accountingCogs,
        economic_cogs: economicCogs,
        gp_pct_accounting: Math.round(gpPctAccounting * 10) / 10,
        gp_pct_economic: Math.round(gpPctEconomic * 10) / 10,
        gp_pct_avg: Math.round(gpPctAvg * 10) / 10,
        delta_gp_pct: Math.round((gpPctEconomic - gpPctAccounting) * 10) / 10,
        has_economic_price: vinsightCogs > 0 || hasCascadePrice,
      };
    });
  }, [data, priceAdjPct]);

  // ─── NV Grouping ────────────────────────────────────────────────────────
  // M3-07: Group by canonical_sku_id (76-99 products) instead of sku_group (242 products).
  // SKUs without canonical_sku_id fall back to sku_group, then item_description.
  const nvGroupedSkus = useMemo<CalculatedSku[]>(() => {
    const groups = new Map<string, CalculatedSku[]>();
    for (const sku of calculatedSkus) {
      const key = sku.canonical_sku_id ? String(sku.canonical_sku_id) : (sku.sku_group || sku.item_description);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key)!.push(sku);
    }

    const result: CalculatedSku[] = [];
    groups.forEach((children, groupKey) => {
      if (children.length === 1) {
        result.push(children[0]);
        return;
      }

      // Sort children by vintage desc
      children.sort((a: CalculatedSku, b: CalculatedSku) => (b.vintage || 0) - (a.vintage || 0));

      const totalRevenue = children.reduce((s: number, c: CalculatedSku) => s + c.total_revenue, 0);
      const totalQty = children.reduce((s: number, c: CalculatedSku) => s + c.total_qty, 0);
      const totalStock = children.reduce((s: number, c: CalculatedSku) => s + c.units_in_stock, 0);
      const vel3m = children.reduce((s: number, c: CalculatedSku) => s + c.velocity_3m, 0);
      const vel6m = children.reduce((s: number, c: CalculatedSku) => s + c.velocity_6m, 0);
      const vel12m = children.reduce((s: number, c: CalculatedSku) => s + c.velocity_12m, 0);

      // Revenue-weighted GP%
      const wGpAcct = totalRevenue > 0
        ? children.reduce((s: number, c: CalculatedSku) => s + c.gp_pct_accounting * c.total_revenue, 0) / totalRevenue : 0;
      const wGpEcon = totalRevenue > 0
        ? children.reduce((s: number, c: CalculatedSku) => s + c.gp_pct_economic * c.total_revenue, 0) / totalRevenue : 0;

      // GP% (Avg): based on actual average selling price across all vintages
      const groupAvgSellingPrice = totalQty > 0 ? totalRevenue / totalQty : 0;
      const groupAvgEconCogs = totalQty > 0
        ? children.reduce((s: number, c: CalculatedSku) => s + c.economic_cogs * c.total_qty, 0) / totalQty : 0;
      const wGpAvg = groupAvgSellingPrice > 0
        ? ((groupAvgSellingPrice - groupAvgEconCogs) / groupAvgSellingPrice) * 100 : 0;

      // Qty-weighted COGS
      const avgAcctCogs = totalQty > 0
        ? children.reduce((s: number, c: CalculatedSku) => s + c.accounting_cogs * c.total_qty, 0) / totalQty : 0;
      const avgEconCogs = totalQty > 0
        ? children.reduce((s: number, c: CalculatedSku) => s + c.economic_cogs * c.total_qty, 0) / totalQty : 0;

      // Revenue-weighted wholesale price
      const avgWholesale = totalRevenue > 0
        ? children.reduce((s: number, c: CalculatedSku) => s + c.base_wholesale * c.total_revenue, 0) / totalRevenue
        : children[0].base_wholesale;

      const stockCover = vel12m > 0 ? Math.round(totalStock / vel12m * 10) / 10 : null;

      // Merge channels
      const mergedChannels: Record<string, { revenue: number; qty: number }> = {};
      for (const child of children) {
        for (const [ch, chData] of Object.entries(child.channels)) {
          if (!mergedChannels[ch]) mergedChannels[ch] = { revenue: 0, qty: 0 };
          mergedChannels[ch].revenue += chData.revenue;
          mergedChannels[ch].qty += chData.qty;
        }
      }

      const rep = children[0]; // most recent vintage as representative
      // M3-07: Use canonical_sku_name as display name when available
      const displayName = rep.canonical_sku_name || rep.sku_group || rep.item_description;
      let hash = 0;
      for (let i = 0; i < groupKey.length; i++) {
        hash = (hash * 31 + groupKey.charCodeAt(i)) & 0x7fffffff;
      }

      result.push({
        ...rep,
        sku_id: -(hash || 1),
        item_description: displayName,
        sku_code: `${children.length} vintages`,
        vintage: null,
        base_wholesale: Math.round(avgWholesale * 100) / 100,
        total_revenue: totalRevenue,
        total_qty: totalQty,
        velocity_3m: Math.round(vel3m * 10) / 10,
        velocity_6m: Math.round(vel6m * 10) / 10,
        velocity_12m: Math.round(vel12m * 10) / 10,
        units_in_stock: totalStock,
        stock_cover_months: stockCover,
        accounting_cogs: Math.round(avgAcctCogs * 100) / 100,
        economic_cogs: Math.round(avgEconCogs * 100) / 100,
        gp_pct_accounting: Math.round(wGpAcct * 10) / 10,
        gp_pct_economic: Math.round(wGpEcon * 10) / 10,
        gp_pct_avg: Math.round(wGpAvg * 10) / 10,
        delta_gp_pct: Math.round((wGpEcon - wGpAcct) * 10) / 10,
        has_economic_price: children.some((c: CalculatedSku) => c.has_economic_price),
        channels: mergedChannels,
        grape_components: rep.grape_components,
        children,
        is_nv_parent: true,
      });
    });

    return result;
  }, [calculatedSkus]);

  // Apply filters + search + sort
  const filteredSkus = useMemo(() => {
    // When vintage filter is active, bypass NV grouping and show individual SKUs
    let result = vintageFilter !== 'all' ? calculatedSkus : nvGroupedSkus;

    if (channelFilter !== 'all') {
      result = result.filter(s => s.channels[channelFilter]);
    }
    if (rangeFilter !== 'all') {
      result = result.filter(s => s.range_name === rangeFilter);
    }
    if (vintageFilter !== 'all') {
      result = result.filter(s => s.vintage === parseInt(vintageFilter));
    }
    if (search) {
      const q = search.toLowerCase();
      result = result.filter(s =>
        s.item_description.toLowerCase().includes(q) ||
        s.sku_code.toLowerCase().includes(q) ||
        (s.variety && s.variety.toLowerCase().includes(q)) ||
        (s.children && s.children.some(c =>
          c.sku_code.toLowerCase().includes(q) ||
          c.item_description.toLowerCase().includes(q)
        ))
      );
    }

    // Sort: SKUs with no cost data always go to bottom regardless of sort direction
    result.sort((a, b) => {
      const aNoCost = !a.has_economic_price;
      const bNoCost = !b.has_economic_price;

      // No-cost SKUs sink to bottom
      if (aNoCost && !bNoCost) return 1;
      if (!aNoCost && bNoCost) return -1;

      let aVal: number, bVal: number;
      switch (sortKey) {
        case 'item_description':
          return sortDesc
            ? b.item_description.localeCompare(a.item_description)
            : a.item_description.localeCompare(b.item_description);
        case 'gp_pct':
          aVal = a.gp_pct_economic;
          bVal = b.gp_pct_economic;
          break;
        case 'cogs':
          aVal = a.economic_cogs;
          bVal = b.economic_cogs;
          break;
        case 'delta_gp_pct':
          aVal = a.delta_gp_pct; bVal = b.delta_gp_pct; break;
        case 'velocity':
          aVal = a[`velocity_${velocityWindow}` as keyof SkuData] as number;
          bVal = b[`velocity_${velocityWindow}` as keyof SkuData] as number;
          break;
        default:
          aVal = a[sortKey] as number; bVal = b[sortKey] as number;
      }
      return sortDesc ? bVal - aVal : aVal - bVal;
    });

    return result;
  }, [calculatedSkus, nvGroupedSkus, channelFilter, rangeFilter, vintageFilter, search, sortKey, sortDesc, costBasis, velocityWindow]);

  // KPI summaries
  const kpis = useMemo(() => {
    if (!filteredSkus.length) return { revenue: 0, avgGpAcct: 0, avgGpEcon: 0, avgGpAvg: 0, belowThreshold: 0 };
    const totalRevenue = filteredSkus.reduce((sum, s) => sum + s.total_revenue, 0);
    const totalQty = filteredSkus.reduce((sum, s) => sum + s.total_qty, 0);

    // Revenue-weighted GP%
    const weightedGpAcct = filteredSkus.reduce((sum, s) => sum + s.gp_pct_accounting * s.total_revenue, 0);
    const weightedGpEcon = filteredSkus.reduce((sum, s) => sum + s.gp_pct_economic * s.total_revenue, 0);

    const avgGpAcct = totalRevenue > 0 ? Math.round(weightedGpAcct / totalRevenue * 10) / 10 : 0;
    const avgGpEcon = totalRevenue > 0 ? Math.round(weightedGpEcon / totalRevenue * 10) / 10 : 0;

    // GP% (Avg): portfolio-level avg selling price vs weighted COGS
    const portfolioAvgPrice = totalQty > 0 ? totalRevenue / totalQty : 0;
    const weightedCogs = totalQty > 0 ? filteredSkus.reduce((sum, s) => sum + s.economic_cogs * s.total_qty, 0) / totalQty : 0;
    const avgGpAvg = portfolioAvgPrice > 0 ? Math.round(((portfolioAvgPrice - weightedCogs) / portfolioAvgPrice) * 1000) / 10 : 0;

    const currentGp = 'gp_pct_economic';
    const belowThreshold = filteredSkus.filter(s => s[currentGp] < 25 && s[currentGp] !== 0).length;

    return { revenue: totalRevenue, avgGpAcct, avgGpEcon, avgGpAvg, belowThreshold };
  }, [filteredSkus, costBasis]);

  function toggleSort(key: SortKey) {
    if (sortKey === key) {
      setSortDesc(!sortDesc);
    } else {
      setSortKey(key);
      setSortDesc(true);
    }
  }

  function toggleGroup(groupName: string) {
    setExpandedGroups(prev => {
      const next = new Set(prev);
      if (next.has(groupName)) next.delete(groupName);
      else next.add(groupName);
      return next;
    });
  }

  function exportCsv() {
    const headers = ['SKU Code', 'Wine', 'Variety', 'Region', 'Vintage', 'Range', 'Wholesale', 'Avg $/Case', 'Acct COGS', 'Econ COGS', 'GP% (Whl)', 'GP% (Avg)', 'GP% Econ', 'Delta', 'Revenue 12m', 'Qty 12m', 'Vel 3m', 'Vel 6m', 'Vel 12m', 'DWS Rev', 'ALM Rev', 'Direct Rev'];
    const rows = filteredSkus.map(s => [
      s.sku_code, s.item_description, s.variety, s.region, s.vintage, s.range_name,
      s.base_wholesale, s.total_qty > 0 ? (s.total_revenue / s.total_qty).toFixed(2) : 0,
      s.accounting_cogs.toFixed(2), s.economic_cogs.toFixed(2),
      s.gp_pct_accounting, s.gp_pct_avg, s.gp_pct_economic, s.delta_gp_pct,
      s.total_revenue, s.total_qty, s.velocity_3m, s.velocity_6m, s.velocity_12m,
      s.channels['DWS']?.revenue || 0, s.channels['ALM']?.revenue || 0, s.channels['Direct']?.revenue || 0,
    ]);
    const csv = [headers, ...rows].map(r => r.join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `margin-analysis-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  const font = { fontFamily: 'Inter, sans-serif' };

  return (
    <AppLayout>
      {/* Header */}
      <div className="flex items-start justify-between mb-6">
        <div>
          <h1 className="text-2xl text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
            Margin Analysis
          </h1>
          <p className="text-[#505052] text-sm mt-1" style={font}>
            SKU profitability across all warehouses — revenue: {isCustomRange ? formatRangeLabel(customFrom, customTo) : 'last 12m'}, velocity: {velocityWindow}
          </p>
        </div>
        <div className="flex items-center gap-3">
          {/* M3-04: Accounting toggle removed — Economic COGS only */}
          <button
            onClick={exportCsv}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium text-[#505052] hover:text-[#1F1F1F] hover:bg-[#F3F3F3] transition-colors"
            style={font}
          >
            <Download size={14} />
            Export CSV
          </button>
        </div>
      </div>

      {initialLoading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
          {[...Array(4)].map((_, i) => (
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
          {/* How it works guide */}
          {showGuide && (
            <div className="bg-[#FAF9F7] border border-[#D8D9DA] rounded-xl p-4 flex items-start justify-between" style={font}>
              <div className="flex gap-6 text-xs text-[#505052]">
                <div><span className="font-medium text-[#1F1F1F]">1. Toggle view</span><br />Switch Accounting ↔ Economic to compare cost bases</div>
                <div><span className="font-medium text-[#1F1F1F]">2. Filter</span><br />Narrow by warehouse, range, or vintage</div>
                <div><span className="font-medium text-[#1F1F1F]">3. Sort</span><br />Click any column header to sort</div>
                <div><span className="font-medium text-[#1F1F1F]">4. Export</span><br />Download filtered results as CSV</div>
              </div>
              <button onClick={() => setShowGuide(false)} className="text-[#505052]/50 hover:text-[#505052] ml-4 text-lg leading-none">&times;</button>
            </div>
          )}

          {/* KPI Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-6">
            <div className="relative h-full">
              <MetricCard
                label="Total Revenue (12m)"
                value={formatCurrency(kpis.revenue)}
                subtitle={`${filteredSkus.length} products`}
                icon={<DollarSign size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['Total Revenue (12m)']} className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="GP% (Whl)"
                value={`${kpis.avgGpEcon}%`}
                subtitle="Based on wholesale price"
                icon={<Activity size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['GP% (Whl)']} className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="GP% (Avg)"
                value={`${kpis.avgGpAvg}%`}
                subtitle="Based on avg selling price"
                icon={<TrendingUp size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['GP% (Avg)']} className="absolute top-3 right-3" />
            </div>
            <div className="relative h-full">
              <MetricCard
                label="Below 25% GP"
                value={`${kpis.belowThreshold}`}
                subtitle={`of ${filteredSkus.length} products`}
                icon={<AlertTriangle size={20} />}
              />
              <InfoTooltip text={KPI_TOOLTIPS['Below 25% GP']} className="absolute top-3 right-3" />
            </div>
          </div>

          {/* Filters + Search */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-4 shadow-sm">
            <div className="flex items-center gap-3 flex-wrap">
              <input
                type="text"
                placeholder="Search wines..."
                value={search}
                onChange={e => setSearch(e.target.value)}
                className="px-3 py-1.5 rounded-lg border border-[#D8D9DA] text-sm text-[#1F1F1F] placeholder-[#505052]/50 focus:outline-none focus:ring-1 focus:ring-[#931220]/30 w-64"
                style={font}
              />
              <button
                onClick={() => setShowFilters(!showFilters)}
                className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                  showFilters ? 'bg-[#931220]/10 text-[#931220]' : 'text-[#505052] hover:bg-[#F3F3F3]'
                }`}
                style={font}
              >
                <Filter size={14} />
                Filters
              </button>
              <div className="flex items-center gap-2 ml-auto flex-wrap" style={font}>
                <span className="text-[10px] text-[#505052] mr-1">Rev:</span>
                <MonthPicker
                  label="From:"
                  value={customFrom}
                  onChange={val => {
                    setCustomFrom(val);
                    // Guard: if new From is after existing To, clamp To up.
                    if (val && customTo && val > customTo) setCustomTo(val);
                  }}
                  minMonth={minMonth}
                  maxMonth={maxMonth}
                  active={isCustomRange}
                />
                <MonthPicker
                  label="To:"
                  value={customTo}
                  onChange={val => {
                    setCustomTo(val);
                    // Guard: if new To is before existing From, clamp From down.
                    if (val && customFrom && val < customFrom) setCustomFrom(val);
                  }}
                  minMonth={minMonth}
                  maxMonth={maxMonth}
                  active={isCustomRange}
                />
                {(customFrom || customTo) && (
                  <button
                    onClick={() => {
                      setCustomFrom('');
                      setCustomTo('');
                      // Preserve active attribute filters (rep/territory/channel) when clearing dates.
                      fetchData(undefined, undefined, false, {
                        rep: repFilter,
                        territory: territoryFilter,
                        channel: customerChannelFilter,
                      });
                    }}
                    className="px-1.5 py-0.5 rounded text-[10px] text-[#931220] hover:bg-[#931220]/10 transition-colors"
                    title="Clear custom range"
                  >
                    Clear
                  </button>
                )}
                <span className="text-[10px] text-[#505052] ml-2 mr-1">Vel:</span>
                <div className="flex bg-[#F3F3F3] rounded-md p-0.5">
                  {(['3m', '6m', '12m'] as VelocityWindow[]).map(w => (
                    <button key={w} onClick={() => setVelocityWindow(w)}
                      className={`px-2 py-1 rounded text-[10px] font-medium transition-colors ${
                        velocityWindow === w ? 'bg-white text-[#1F1F1F] shadow-sm' : 'text-[#505052] hover:text-[#1F1F1F]'
                      }`}>{w}</button>
                  ))}
                </div>
              </div>
              <span className="text-xs text-[#505052]" style={font}>
                {filteredSkus.length} of {nvGroupedSkus.length} products
              </span>
            </div>

            {showFilters && (
              <div className="flex items-center gap-3 mt-3 pt-3 border-t border-[#D8D9DA]/50">
                <select
                  value={channelFilter}
                  onChange={e => setChannelFilter(e.target.value)}
                  className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                  style={font}
                >
                  <option value="all">All Warehouses</option>
                  {data.filters.channels.map(c => <option key={c} value={c}>{c}</option>)}
                </select>
                <select
                  value={rangeFilter}
                  onChange={e => setRangeFilter(e.target.value)}
                  className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                  style={font}
                >
                  <option value="all">All Ranges</option>
                  {data.filters.ranges.map(r => <option key={r} value={r}>{r}</option>)}
                </select>
                <select
                  value={vintageFilter}
                  onChange={e => setVintageFilter(e.target.value)}
                  className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                  style={font}
                >
                  <option value="all">All Vintages</option>
                  {data.filters.vintages.map(v => <option key={v} value={String(v)}>{v}</option>)}
                </select>
                {data.filters.reps?.length > 0 && (
                  <select
                    value={repFilter}
                    onChange={e => setRepFilter(e.target.value)}
                    className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                    style={font}
                  >
                    <option value="all">All Reps</option>
                    {data.filters.reps.map(r => <option key={r} value={r}>{r}</option>)}
                  </select>
                )}
                {data.filters.territories?.length > 0 && (
                  <select
                    value={territoryFilter}
                    onChange={e => setTerritoryFilter(e.target.value)}
                    className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                    style={font}
                  >
                    <option value="all">All Territories</option>
                    {data.filters.territories.map(t => <option key={t} value={t}>{t}</option>)}
                  </select>
                )}
                {data.filters.customer_channels?.length > 0 && (
                  <select
                    value={customerChannelFilter}
                    onChange={e => setCustomerChannelFilter(e.target.value)}
                    className="px-2 py-1.5 rounded-lg border border-[#D8D9DA] text-xs text-[#1F1F1F] bg-white"
                    style={font}
                    title="Customer channel (on-premise / off-premise) — not warehouse"
                  >
                    <option value="all">All Channels</option>
                    {data.filters.customer_channels.map(c => <option key={c} value={c}>{c}</option>)}
                  </select>
                )}
                <button
                  onClick={() => {
                    setChannelFilter('all');
                    setRangeFilter('all');
                    setVintageFilter('all');
                    setRepFilter('all');
                    setTerritoryFilter('all');
                    setCustomerChannelFilter('all');
                    setSearch('');
                  }}
                  className="text-xs text-[#931220] hover:underline ml-2"
                  style={font}
                >
                  Clear all
                </button>
              </div>
            )}
          </div>

          {/* JC-328 — What-if scenario: price ±% slider. Recomputes GP% client-side. */}
          <div
            className={`rounded-xl border p-4 shadow-sm transition-colors ${priceAdjPct !== 0 ? 'bg-[#FFF7E6] border-amber-300' : 'bg-white border-[#D8D9DA]'}`}
            data-testid="what-if-scenario"
          >
            <div className="flex items-center gap-3 flex-wrap">
              <div className="flex items-center gap-2 text-xs font-medium text-[#1F1F1F]" style={font}>
                <Activity size={14} className="text-[#931220]" />
                What-if price adjustment
                <InfoTooltip
                  text="Read-only scenario: scales every SKU's wholesale price by the % below and recomputes GP% in the table. Does not write to the database."
                  size={12}
                  className="inline-flex"
                />
              </div>
              <input
                type="range"
                min={-50}
                max={50}
                step={1}
                value={priceAdjPct}
                onChange={(e) => setPriceAdjPct(Number(e.target.value))}
                className="flex-1 max-w-md accent-[#931220]"
                aria-label="Price adjustment percentage"
                data-testid="what-if-price-slider"
              />
              <div className="flex items-center gap-2 text-xs" style={font}>
                <input
                  type="number"
                  min={-50}
                  max={50}
                  step={1}
                  value={priceAdjPct}
                  onChange={(e) => {
                    const v = Number(e.target.value);
                    if (Number.isFinite(v)) setPriceAdjPct(Math.max(-50, Math.min(50, v)));
                  }}
                  className="w-16 px-2 py-1 rounded-md border border-[#D8D9DA] text-right text-xs"
                />
                <span className="text-[#505052]">%</span>
                {priceAdjPct !== 0 && (
                  <button
                    type="button"
                    onClick={() => setPriceAdjPct(0)}
                    className="text-[10px] text-[#931220] hover:underline"
                  >
                    Reset
                  </button>
                )}
              </div>
              {priceAdjPct !== 0 && (() => {
                const baseRevenue = filteredSkus.reduce((s, x) => s + x.total_revenue, 0);
                const baseGp = filteredSkus.reduce((s, x) => s + (x.economic_cogs * x.total_qty), 0);
                const adjFactor = 1 + priceAdjPct / 100;
                const adjRevenue = baseRevenue * adjFactor;
                const adjGpDollars = adjRevenue - baseGp;
                const adjGpPct = adjRevenue > 0 ? (adjGpDollars / adjRevenue) * 100 : 0;
                const baseGpPct = baseRevenue > 0 ? ((baseRevenue - baseGp) / baseRevenue) * 100 : 0;
                const deltaPct = adjGpPct - baseGpPct;
                return (
                  <div
                    className="text-[11px] text-[#505052] ml-auto whitespace-nowrap"
                    style={font}
                    data-testid="what-if-summary"
                  >
                    GP% scenario:{' '}
                    <span className="font-medium text-[#1F1F1F]">{adjGpPct.toFixed(1)}%</span>{' '}
                    <span className={deltaPct >= 0 ? 'text-[#1B7A3D]' : 'text-[#B42318]'}>
                      ({deltaPct >= 0 ? '+' : ''}{deltaPct.toFixed(1)}pp vs base)
                    </span>
                  </div>
                );
              })()}
            </div>
          </div>

          {/* SKU Margin Table */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#FAF9F7]">
                    {[
                      { label: 'Wine', key: 'item_description' as SortKey, align: 'left', tooltip: 'Product name, SKU code, variety and region' },
                      { label: 'Wholesale', key: 'base_wholesale' as SortKey, align: 'right', tooltip: 'Base wholesale price per case (AUD)' },
                      { label: 'Avg $/Case', key: 'total_revenue' as SortKey, align: 'right', tooltip: 'Average wholesale price per case sold = Revenue / Cases' },
                      { label: 'COGS', key: 'cogs' as SortKey, align: 'right', tooltip: 'Cost of goods sold per case (from Vinsight)' },
                      { label: 'GP% (Whl)', key: 'gp_pct' as SortKey, align: 'right', tooltip: 'Gross profit based on base wholesale price: (wholesale - COGS) / wholesale' },
                      { label: 'GP% (Avg)', key: 'gp_pct' as SortKey, align: 'right', tooltip: 'Gross profit based on avg selling price: (avg $/case - COGS) / avg $/case' },
                      { label: 'Cases', key: 'total_revenue' as SortKey, align: 'right', tooltip: 'Total cases sold in the last 12 months' },
                      { label: 'Revenue', key: 'total_revenue' as SortKey, align: 'right', tooltip: 'Total net revenue over the last 12 months' },
                      { label: 'Stock', key: 'velocity' as SortKey, align: 'right', tooltip: 'Cases on hand from Vinsight inventory' },
                      { label: 'Cover', key: 'velocity' as SortKey, align: 'right', tooltip: 'Months of stock cover at current sales velocity' },
                      { label: `Vel (${velocityWindow})`, key: 'velocity' as SortKey, align: 'right', tooltip: `Average cases sold per month (${velocityWindow} window). Click column header to sort.` },
                    ].map(col => (
                      <th
                        key={col.label}
                        className={`py-2.5 px-3 text-${col.align} text-[#505052] font-medium cursor-pointer hover:text-[#1F1F1F] select-none whitespace-nowrap`}
                        onClick={() => toggleSort(col.key)}
                      >
                        {col.label}
                        {col.key !== 'item_description' && (
                          <InfoTooltip text={col.tooltip} size={10} className="inline-flex ml-0.5 align-middle" />
                        )}
                        {sortKey === col.key && <span className="ml-0.5">{sortDesc ? '↓' : '↑'}</span>}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className={tableLoading ? 'opacity-60 transition-opacity' : 'transition-opacity'}>
                  {tableLoading && (
                    <>
                      {[...Array(8)].map((_, i) => (
                        <tr key={`skeleton-${i}`} className="border-b border-[#D8D9DA]/30 animate-pulse">
                          {[...Array(11)].map((__, j) => (
                            <td key={j} className="py-3 px-3">
                              <div className="h-3 bg-gray-200 rounded" style={{ width: j === 0 ? '70%' : '50%', marginLeft: j === 0 ? 0 : 'auto' }} />
                            </td>
                          ))}
                        </tr>
                      ))}
                    </>
                  )}
                  {!tableLoading && filteredSkus.slice(0, displayLimit).map(sku => {
                    const gpPct = sku.gp_pct_economic;
                    const cogs = sku.economic_cogs;
                    const noCost = !sku.has_economic_price;
                    const isParent = sku.is_nv_parent && sku.children && sku.children.length > 1;
                    const groupKey = sku.sku_group || sku.item_description;
                    const isExpanded = expandedGroups.has(groupKey);

                    return (
                      <Fragment key={sku.sku_id}>
                        <tr
                          className={`border-b border-[#D8D9DA]/30 hover:bg-[#FAF9F7] ${isParent ? 'cursor-pointer' : ''}`}
                          onClick={isParent ? () => toggleGroup(groupKey) : undefined}
                        >
                          <td className="py-2.5 px-3">
                            <div className="flex items-start gap-1.5">
                              {isParent && (
                                <span className="mt-0.5 text-[#505052] shrink-0">
                                  {isExpanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                                </span>
                              )}
                              <div>
                                {isParent ? (
                                  <span className="text-[#1F1F1F] font-medium" style={{ fontSize: '11px' }}>
                                    {sku.item_description}
                                  </span>
                                ) : (
                                  <a href={`/wines?sku_id=${sku.sku_id}`} className="text-[#1F1F1F] font-medium hover:text-[#931220] transition-colors" style={{ fontSize: '11px' }}>{sku.item_description}</a>
                                )}
                                <div className="text-[#505052]/60" style={{ fontSize: '10px' }}>
                                  {isParent
                                    ? <><span className="text-[#931220]/70 font-medium">{sku.children!.length} vintages</span> &middot; {sku.variety} &middot; {sku.region || '—'}</>
                                    : <>{sku.sku_code} &middot; {sku.variety} &middot; {sku.region || '—'}</>
                                  }
                                  {sku.range_name && <span className="ml-1 text-[#505052]/40">&middot; {sku.range_name}</span>}
                                  <a
                                    href={`/legacy-data?type=sku&sku=${encodeURIComponent(sku.item_description)}`}
                                    className="ml-2 inline-flex items-center gap-0.5 rounded-full bg-[#FCE7E9] px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide text-[#931220] hover:bg-[#F8D2D6] transition-colors"
                                    title="View raw source data for this SKU"
                                  >
                                    <Database size={9} strokeWidth={2.5} />
                                    Raw
                                  </a>
                                </div>
                              </div>
                            </div>
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#1F1F1F]">
                            {sku.base_wholesale > 0 ? formatDollars(sku.base_wholesale) : '—'}
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#505052]">
                            {sku.total_qty > 0 ? formatDollars(sku.total_revenue / sku.total_qty) : '—'}
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#505052]">
                            {noCost ? <span className="text-[#D8D9DA]">—</span> : formatDollars(cogs)}
                          </td>
                          <td className="py-2.5 px-3 text-right">
                            {noCost ? (
                              <span className="text-[#D8D9DA]">—</span>
                            ) : (
                              <Badge variant={gpPct >= 40 ? 'success' : gpPct >= 25 ? 'warning' : 'error'}>
                                {gpPct.toFixed(1)}%
                              </Badge>
                            )}
                          </td>
                          <td className="py-2.5 px-3 text-right">
                            {noCost || sku.total_qty <= 0 ? (
                              <span className="text-[#D8D9DA]">—</span>
                            ) : (
                              <Badge variant={sku.gp_pct_avg > 25 ? 'success' : sku.gp_pct_avg >= 15 ? 'warning' : 'error'}>
                                {sku.gp_pct_avg.toFixed(1)}%
                              </Badge>
                            )}
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#505052]">
                            {sku.total_qty > 0 ? Math.round(sku.total_qty).toLocaleString() : '—'}
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#1F1F1F] font-medium">
                            {formatCurrency(sku.total_revenue)}
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#505052]">
                            {sku.units_in_stock > 0 ? Math.round(sku.units_in_stock) : '—'}
                          </td>
                          <td className="py-2.5 px-3 text-right">
                            {sku.stock_cover_months && sku.stock_cover_months > 0 && sku.units_in_stock > 0 ? (
                              <span className={`text-xs ${sku.stock_cover_months < 3 ? 'text-[#B42318]' : sku.stock_cover_months < 6 ? 'text-[#B54708]' : 'text-[#1B7A3D]'}`}>
                                {sku.stock_cover_months.toFixed(1)}mo
                              </span>
                            ) : <span className="text-[#505052]">—</span>}
                          </td>
                          <td className="py-2.5 px-3 text-right text-[#505052]">
                            {(() => {
                              const vel = sku[`velocity_${velocityWindow}` as keyof SkuData] as number;
                              return vel > 0 ? `${vel}/mo` : '—';
                            })()}
                          </td>
                        </tr>
                        {isParent && isExpanded && sku.children!.map(child => {
                          const cGp = child.gp_pct_economic;
                          const cCogs = child.economic_cogs;
                          const cNoCost = !child.has_economic_price;
                          return (
                            <tr key={child.sku_id} className="border-b border-[#D8D9DA]/10 bg-[#FAF9F7]/50 text-[#505052]">
                              <td className="py-2 px-3 pl-9">
                                <a href={`/wines?sku_id=${child.sku_id}`} className="hover:text-[#931220] transition-colors" style={{ fontSize: '11px' }}>
                                  {child.vintage || 'NV'} &mdash; {child.item_description}
                                </a>
                                <div className="text-[#505052]/40" style={{ fontSize: '10px' }}>{child.sku_code}</div>
                              </td>
                              <td className="py-2 px-3 text-right">{child.base_wholesale > 0 ? formatDollars(child.base_wholesale) : '—'}</td>
                              <td className="py-2 px-3 text-right text-[#505052]">
                                {child.total_qty > 0 ? formatDollars(child.total_revenue / child.total_qty) : '—'}
                              </td>
                              <td className="py-2 px-3 text-right">{cNoCost ? <span className="text-[#D8D9DA]">—</span> : formatDollars(cCogs)}</td>
                              <td className="py-2 px-3 text-right">
                                {cNoCost ? <span className="text-[#D8D9DA]">—</span> : (
                                  <Badge variant={cGp >= 40 ? 'success' : cGp >= 25 ? 'warning' : 'error'}>{cGp.toFixed(1)}%</Badge>
                                )}
                              </td>
                              <td className="py-2 px-3 text-right">
                                {cNoCost || child.total_qty <= 0 ? (
                                  <span className="text-[#D8D9DA]">—</span>
                                ) : (
                                  <Badge variant={child.gp_pct_avg > 25 ? 'success' : child.gp_pct_avg >= 15 ? 'warning' : 'error'}>
                                    {child.gp_pct_avg.toFixed(1)}%
                                  </Badge>
                                )}
                              </td>
                              <td className="py-2 px-3 text-right text-[#505052]">
                                {child.total_qty > 0 ? Math.round(child.total_qty).toLocaleString() : '—'}
                              </td>
                              <td className="py-2 px-3 text-right font-medium">{formatCurrency(child.total_revenue)}</td>
                              <td className="py-2 px-3 text-right">{child.units_in_stock > 0 ? Math.round(child.units_in_stock) : '—'}</td>
                              <td className="py-2 px-3 text-right">
                                {child.stock_cover_months && child.stock_cover_months > 0 && child.units_in_stock > 0 ? (
                                  <span className={`text-xs ${child.stock_cover_months < 3 ? 'text-[#B42318]' : child.stock_cover_months < 6 ? 'text-[#B54708]' : 'text-[#1B7A3D]'}`}>
                                    {child.stock_cover_months.toFixed(1)}mo
                                  </span>
                                ) : <span className="text-[#505052]">—</span>}
                              </td>
                              <td className="py-2 px-3 text-right">
                                {(() => {
                                  const vel = child[`velocity_${velocityWindow}` as keyof SkuData] as number;
                                  return vel > 0 ? `${vel}/mo` : '—';
                                })()}
                              </td>
                            </tr>
                          );
                        })}
                      </Fragment>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {!tableLoading && filteredSkus.length > displayLimit && (
              <div className="text-center py-3 border-t border-[#D8D9DA]/50">
                <button
                  onClick={() => setDisplayLimit(9999)}
                  className="text-xs text-[#931220] hover:underline font-medium"
                  style={font}
                >
                  Show All {filteredSkus.length} Products
                </button>
                <span className="text-xs text-[#505052] ml-2" style={font}>
                  (showing {displayLimit} of {filteredSkus.length})
                </span>
              </div>
            )}
            {!tableLoading && displayLimit > 100 && filteredSkus.length > 100 && (
              <div className="text-center py-3 border-t border-[#D8D9DA]/50">
                <button
                  onClick={() => setDisplayLimit(100)}
                  className="text-xs text-[#505052] hover:underline"
                  style={font}
                >
                  Show Less
                </button>
              </div>
            )}
            {!tableLoading && filteredSkus.length === 0 && (
              <div className="text-center py-8 text-sm text-[#505052]" style={font}>
                No SKUs match your filters
              </div>
            )}
          </div>
        </div>
      ) : null}
    </AppLayout>
  );
}

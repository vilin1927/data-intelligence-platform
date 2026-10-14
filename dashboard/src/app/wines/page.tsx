'use client';

import { useEffect, useState, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import { StackedBarChart } from '@/components/Charts';
import Badge from '@/components/Badge';
import {
  DollarSign,
  TrendingUp,
  Package,
  ArrowLeft,
  Grape,
  Beaker,
  Wine,
  BarChart3,
  ChevronRight,
  Search,
  Users,
  Clock,
} from 'lucide-react';
import InfoTooltip from '@/components/InfoTooltip';
import Link from 'next/link';
import NextVintageBox from '@/components/wines/NextVintageBox';
import VintageBreakdownTable, {
  type VintageBreakdownRow,
} from '@/components/wines/VintageBreakdownTable';

// Demo mirror flag — genericize visible brand copy for prospects. Unset => live prod text.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

interface SkuDetail {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  base_wholesale: number;
  transfer_cost: number;
  economic_cogs_per_unit: number | null;
  units_per_case: number;
  sku_group: string | null;
  range_name: string | null;
  revenue_12m: number;
  qty_12m: number;
  orders_12m: number;
  gp_pct_accounting: number | null;
  gp_pct_economic: number | null;
  velocity_3m: number;
  velocity_6m: number;
  velocity_12m: number;
}

interface TraceabilityStep {
  packaging_desc: string;
  bottling_date: string | null;
  cases_produced: number | null;
  vessel_code: string;
  vessel_name: string;
  batch_code: string;
  batch_desc: string | null;
  batch_variety: string | null;
  batch_region: string | null;
  batch_vintage: number | null;
  batch_color: string | null;
  volume_litres: number;
}

interface ChannelData {
  channel: string;
  revenue: number;
  qty: number;
  transactions: number;
}

interface VintageAttribution {
  vintage: number;
  method: string;
  confidence: number;
  sales_count: number;
  revenue: number;
}

interface RelatedVintage {
  vintage: number;
  sku_codes: string;
  qty_dispatched: number;
  dispatch_count: number;
}

interface TopCustomer {
  customer_name: string;
  channel: string;
  cases: number;
  revenue: number;
  trend: 'growth' | 'decline' | 'stable';
}

interface WineData {
  sku: SkuDetail;
  sales_by_month: Array<{ month: string; dws: number; alm: number; direct: number; total_qty: number }>;
  traceability: TraceabilityStep[];
  channels: ChannelData[];
  vintage_attribution: VintageAttribution[];
  related_vintages: RelatedVintage[];
  top_customers: TopCustomer[];
  stock_cases: number;
}

const fmt = (n: number) => n >= 1000000 ? `$${(n/1000000).toFixed(1)}M` : n >= 1000 ? `$${(n/1000).toFixed(1)}K` : `$${n.toFixed(0)}`;

// ─── Empty State: Wine Search Page ──────────────────────────────────────

interface SearchResult {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  revenue_12m: number;
  vintage_count?: number;
  // OWNER-MAY8-B1: per-source codes from canonical_sku_code_map. Each list is
  // the deduped set of external codes mapped to this canonical for that
  // source_system. Empty array when there is no mapping in that source.
  alm_codes: string[];
  dws_codes: string[];
  access_codes: string[];
  vinsight_codes: string[];
  ilg_codes: string[];
}

// OWNER-MAY8-B1: split comma-separated STRING_AGG output and dedup across
// children. Empty/null cells -> empty array. Trims whitespace defensively.
function splitCodes(raw: unknown): string[] {
  if (raw === null || raw === undefined) return [];
  const s = typeof raw === 'string' ? raw : String(raw);
  if (!s) return [];
  return s.split(',').map(c => c.trim()).filter(c => c.length > 0);
}

// JC-117 (B6b): Style dropdown — exactly 5 values per APR13 lines 48-56.
// Order matters; "All" is the no-filter sentinel.
const STYLE_OPTIONS = ['All', 'Red', 'White', 'Rose', 'Sparkling'] as const;
type StyleOption = typeof STYLE_OPTIONS[number];

// Variety -> Style classifier. Conservative mapping: anything not clearly
// White / Rose / Sparkling falls back to Red, matching how the owner groups wines
// in the Access reports (Sparkling first by ABV, then White / Rose / Red).
function styleOf(variety: string | null | undefined): Exclude<StyleOption, 'All'> {
  const v = (variety || '').toLowerCase();
  if (!v) return 'Red';
  if (v.includes('rose') || v.includes('rosé')) return 'Rose';
  if (
    v.includes('sparkling') ||
    v.includes('prosecco') ||
    v.includes('cuvee') ||
    v.includes('cuvée') ||
    v.includes('champagne') ||
    v.includes('moscato') ||
    v.includes('piccolo')
  ) return 'Sparkling';
  if (
    v.includes('riesling') ||
    v.includes('chardonnay') ||
    v.includes('sauvignon blanc') ||
    v.includes('sauv blanc') ||
    v.includes('semillon') ||
    v.includes('pinot grigio') ||
    v.includes('pinot gris') ||
    v.includes('white') ||
    v.includes('viognier') ||
    v.includes('arneis') ||
    v.includes('albarino') ||
    v.includes('albariño') ||
    v.includes('gewurztraminer') ||
    v.includes('vermentino')
  ) return 'White';
  return 'Red';
}

// M3-07 + B6b JC-128/129/138: Group by canonical_sku_id; count DISTINCT
// vintages (not children) so that per-warehouse SKU duplicates don't inflate
// the vintage_count badge — fixes "LK Pinot Noir shows 9 vintages" (real=4).
function groupByNv(skus: Array<Record<string, unknown>>): SearchResult[] {
  const groups = new Map<string, Array<Record<string, unknown>>>();
  for (const s of skus) {
    const key = s.canonical_sku_id
      ? String(s.canonical_sku_id)
      : ((s.sku_group as string) || (s.item_description as string));
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(s);
  }

  type Sku = Record<string, unknown>;
  const result: SearchResult[] = [];
  groups.forEach((children: Sku[]) => {
    const totalRevenue = children.reduce((sum: number, c: Sku) => sum + (c.total_revenue as number || 0), 0);
    children.sort((a: Sku, b: Sku) => (b.total_revenue as number || 0) - (a.total_revenue as number || 0));
    const rep = children[0];
    const displayName = (rep.canonical_sku_name as string) || (rep.sku_group as string) || (rep.item_description as string);

    // Count DISTINCT real vintages (vintage is non-null, > 0), not raw row count.
    // Children with null vintage represent NV (Non-Vintage) rows and are
    // collapsed into a single bucket if any exist, per JC-125 (NV is a single
    // canonical vintage value used for sales/changeover).
    const vintageSet = new Set<number>();
    let hasNv = false;
    for (const c of children) {
      const v = c.vintage as number | null | undefined;
      if (v != null && Number(v) > 0) vintageSet.add(Number(v));
      else hasNv = true;
    }
    const distinctVintages = vintageSet.size + (hasNv ? 1 : 0);

    // OWNER-MAY8-B1: aggregate per-source codes across child rows (which all
    // share the same canonical_sku_id and therefore the same code set, but
    // we Set-dedup defensively in case of join fan-out or duplicate STRING_AGG
    // output across vintage-child rows).
    const almSet = new Set<string>();
    const dwsSet = new Set<string>();
    const accessSet = new Set<string>();
    const vinsightSet = new Set<string>();
    const ilgSet = new Set<string>();
    for (const c of children) {
      splitCodes(c.alm_code).forEach(v => almSet.add(v));
      splitCodes(c.dws_code).forEach(v => dwsSet.add(v));
      splitCodes(c.access_code).forEach(v => accessSet.add(v));
      splitCodes(c.vinsight_code).forEach(v => vinsightSet.add(v));
      splitCodes(c.ilg_code).forEach(v => ilgSet.add(v));
    }
    const sortedFromSet = (s: Set<string>) => Array.from(s).sort();

    result.push({
      sku_id: rep.sku_id as number,
      sku_code: distinctVintages > 1 ? `${distinctVintages} vintages` : (rep.sku_code as string),
      item_description: displayName,
      variety: rep.variety as string | null,
      region: rep.region as string | null,
      vintage: distinctVintages === 1
        ? (vintageSet.size === 1 ? Array.from(vintageSet)[0] : null)
        : null,
      revenue_12m: totalRevenue,
      vintage_count: distinctVintages,
      alm_codes: sortedFromSet(almSet),
      dws_codes: sortedFromSet(dwsSet),
      access_codes: sortedFromSet(accessSet),
      vinsight_codes: sortedFromSet(vinsightSet),
      ilg_codes: sortedFromSet(ilgSet),
    });
  });
  return result.sort((a, b) => b.revenue_12m - a.revenue_12m);
}

function WineSearchPage() {
  const [query, setQuery] = useState('');
  const [style, setStyle] = useState<StyleOption>('All'); // JC-117 / AC7
  const [results, setResults] = useState<SearchResult[]>([]);
  const [allWines, setAllWines] = useState<SearchResult[]>([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    apiGet('/api/margins').then(r => r.json()).then(d => {
      const wines = groupByNv(d.skus || []);
      setAllWines(wines);
      setResults(wines.slice(0, 20));
      setLoaded(true);
    });
  }, []);

  useEffect(() => {
    if (!loaded) return;
    const q = query.trim().toLowerCase();
    const filtered = allWines.filter(w => {
      // Style filter — JC-117. 'All' is the pass-through.
      if (style !== 'All' && styleOf(w.variety) !== style) return false;
      if (!q) return true;
      return (
        w.item_description.toLowerCase().includes(q) ||
        w.sku_code.toLowerCase().includes(q) ||
        (!!w.variety && w.variety.toLowerCase().includes(q)) ||
        (!!w.region && w.region.toLowerCase().includes(q))
      );
    });
    setResults(filtered.slice(0, 20));
  }, [query, style, allWines, loaded]);

  return (
    <AppLayout>
      <div className="max-w-3xl mx-auto py-12 px-4">
        {/* Explanation */}
        <div className="text-center mb-8">
          <div className="w-16 h-16 rounded-2xl bg-[#931220]/10 flex items-center justify-center mx-auto mb-4">
            <Wine size={32} className="text-[#931220]" />
          </div>
          <h1 className="text-2xl font-semibold text-[#1F1F1F] mb-2" style={{ fontFamily: 'Cardo, serif' }}>
            Wine Profile
          </h1>
          <p className="text-sm text-[#505052] max-w-md mx-auto" style={{ fontFamily: 'Inter, sans-serif' }}>
            Deep-dive into any wine — see real margins, full traceability from grape to bottle,
            sales velocity, inventory cover, and vintage history. All in one place.
          </p>
        </div>

        {/* Search + Style filter */}
        <div className="flex gap-3 mb-6">
          <div className="relative flex-1">
            <Search size={18} className="absolute left-4 top-1/2 -translate-y-1/2 text-[#D8D9DA]" />
            <input
              type="text"
              value={query}
              onChange={e => setQuery(e.target.value)}
              placeholder="Search by wine name, SKU code, variety, or region..."
              className="w-full pl-11 pr-4 py-3 text-sm border border-[#D8D9DA] rounded-xl focus:outline-none focus:border-[#931220] transition-colors"
              style={{ fontFamily: 'Inter, sans-serif' }}
              autoFocus
            />
          </div>
          {/* JC-117 / AC7: exactly 5 values — All, Red, White, Rose, Sparkling */}
          <select
            aria-label="Filter by style"
            value={style}
            onChange={e => setStyle(e.target.value as StyleOption)}
            className="px-3 py-3 text-sm border border-[#D8D9DA] rounded-xl bg-white text-[#1F1F1F] focus:outline-none focus:border-[#931220] transition-colors"
            style={{ fontFamily: 'Inter, sans-serif' }}
          >
            {STYLE_OPTIONS.map(opt => (
              <option key={opt} value={opt}>{opt}</option>
            ))}
          </select>
        </div>

        {/* Hint */}
        <p className="text-xs text-[#505052]/60 mb-4 text-center" style={{ fontFamily: 'Inter, sans-serif' }}>
          Or select a wine from{' '}
          <Link href="/margin" className="text-[#931220] hover:underline">Margin Analysis</Link>
          {' '}or{' '}
          <Link href="/inventory" className="text-[#931220] hover:underline">Inventory</Link>
          {' '}to view its profile.
        </p>

        {/* Results */}
        {!loaded ? (
          <div className="text-center text-[#505052] text-sm py-8">Loading wines...</div>
        ) : results.length === 0 ? (
          <div className="text-center text-[#505052] text-sm py-8">No wines found for &quot;{query}&quot;</div>
        ) : (
          <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm divide-y divide-[#F3F4F6]">
            {results.map(w => (
              <a
                key={`${w.item_description}-${w.sku_id}`}
                href={`/wines?sku_id=${w.sku_id}`}
                className="flex items-start justify-between px-4 py-3 hover:bg-[#FAF9F7] transition-colors first:rounded-t-xl last:rounded-b-xl"
              >
                <div className="min-w-0 flex-1">
                  <span className="text-sm font-medium text-[#1F1F1F]">{w.item_description}</span>
                  <div className="text-[10px] text-[#505052] mt-0.5">
                    {w.vintage_count && w.vintage_count > 1
                      ? <><span className="text-[#931220]/70 font-medium">{w.vintage_count} vintages</span> &middot; {w.variety} &middot; {w.region || ''}</>
                      : <><span className="font-mono">{w.sku_code}</span>{w.variety && <> &middot; {w.variety}</>}{w.region && <> &middot; {w.region}</>}{w.vintage && <> &middot; {w.vintage}</>}</>
                    }
                  </div>
                </div>
                <div className="flex items-center gap-3 ml-3 shrink-0">
                  <span className="text-xs text-[#505052]">{fmt(w.revenue_12m)}</span>
                  <ChevronRight size={14} className="text-[#D8D9DA]" />
                </div>
              </a>
            ))}
          </div>
        )}

        {results.length > 0 && (
          <p className="text-[10px] text-[#505052]/60 text-center mt-3">
            {query ? `${results.length} results` : `Top ${results.length} products by revenue · type to search`}
          </p>
        )}
      </div>
    </AppLayout>
  );
}
const fmtPct = (n: number) => `${n.toFixed(1)}%`;

function GpBadge({ value }: { value: number | null }) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return <span className="inline-flex px-2 py-0.5 rounded-full text-xs font-medium text-[#505052] bg-[#D8D9DA]/40">—</span>;
  }
  const color = value >= 50 ? 'text-[#1B7A3D] bg-[#1B7A3D]/10' : value >= 25 ? 'text-[#B54708] bg-[#B54708]/10' : 'text-[#B42318] bg-[#B42318]/10';
  return <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${color}`}>{fmtPct(value)}</span>;
}

function WineProfileContent() {
  const searchParams = useSearchParams();
  const skuId = searchParams.get('sku_id');
  const [data, setData] = useState<WineData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // B13-wp-polish — Wine Profile polish: next-vintage callout + vintage breakdown
  const [nextVintage, setNextVintage] = useState<string | null>(null);
  const [vintageBreakdown, setVintageBreakdown] = useState<VintageBreakdownRow[]>([]);

  useEffect(() => {
    if (!skuId) { setError('No SKU selected'); setLoading(false); return; }
    if (!/^\d+$/.test(skuId)) { setError('Invalid SKU ID'); setLoading(false); return; }
    setLoading(true);
    apiGet(`/api/wines?sku_id=${encodeURIComponent(skuId)}`).then(r => r.json()).then(d => {
      if (d.error) { setError(d.error); } else { setData(d); }
      setLoading(false);
    }).catch(() => { setError('Failed to load'); setLoading(false); });
  }, [skuId]);

  // B13-wp-polish — load vintage breakdown + next-vintage from the new endpoint.
  // Failure is non-fatal; the section just renders empty state.
  useEffect(() => {
    if (!skuId || !/^\d+$/.test(skuId)) return;
    apiGet(`/api/wines/vintage-breakdown?sku_id=${encodeURIComponent(skuId)}`)
      .then(r => r.json())
      .then(d => {
        if (d.error) return;
        setNextVintage(d.next_vintage ?? null);
        setVintageBreakdown(Array.isArray(d.breakdown) ? d.breakdown : []);
      })
      .catch(() => { /* non-fatal */ });
  }, [skuId]);

  if (loading) return <AppLayout><div className="flex items-center justify-center h-64"><div className="text-[#505052]">Loading...</div></div></AppLayout>;
  if (!skuId) return <WineSearchPage />;
  if (error || !data) return (
    <AppLayout>
      <div className="flex flex-col items-center justify-center h-64 gap-3">
        <div className="text-[#B42318]">{error || 'No data'}</div>
        <Link href="/wines" className="text-xs text-[#931220] hover:underline">Back to Wine Search</Link>
      </div>
    </AppLayout>
  );

  const { sku, sales_by_month, traceability, channels, vintage_attribution, related_vintages, top_customers, stock_cases } = data;
  const totalChannelRevenue = channels.reduce((sum, c) => sum + c.revenue, 0);

  // Compute expected runout date
  const monthlyVelocity = sku.velocity_12m;
  const runoutDate: string | null = (() => {
    if (stock_cases <= 0) return 'Out of stock';
    if (monthlyVelocity <= 0) return null; // no sales = can't project
    const monthsRemaining = stock_cases / monthlyVelocity;
    const d = new Date();
    d.setDate(d.getDate() + Math.round(monthsRemaining * 30));
    return d.toLocaleDateString('en-AU', { month: 'short', year: 'numeric' });
  })();

  return (
    <AppLayout>
      <div className="space-y-6">
        {/* Header */}
        <div>
          <Link href="/margin" className="inline-flex items-center gap-1 text-xs text-[#505052] hover:text-[#931220] mb-3 transition-colors">
            <ArrowLeft size={14} /> Back to Margin Analysis
          </Link>
          <div className="flex items-start justify-between">
            <div>
              <h1 className="text-2xl font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
                {sku.item_description}
              </h1>
              <div className="flex items-center gap-3 mt-1">
                <span className="text-xs text-[#505052] font-mono bg-[#F3F4F6] px-2 py-0.5 rounded">{sku.sku_code}</span>
                {sku.variety && <Badge variant="neutral">{sku.variety}</Badge>}
                {sku.region && <Badge variant="neutral">{sku.region}</Badge>}
                {sku.vintage && <Badge variant="neutral">{sku.vintage}</Badge>}
                {sku.range_name && <Badge variant="info">{sku.range_name}</Badge>}
              </div>
            </div>
            <div className="text-right">
              <p className="text-xs text-[#505052]">Wholesale</p>
              <p className="text-lg font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>${sku.base_wholesale.toFixed(2)}</p>
              <p className="text-[10px] text-[#505052]">{sku.units_per_case} per case</p>
            </div>
          </div>
        </div>

        {/* KPI Cards */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <div className="relative">
            <MetricCard
              label="Revenue (12m)"
              value={fmt(sku.revenue_12m)}
              subtitle={`${sku.orders_12m} orders · ${sku.qty_12m.toFixed(0)} cases`}
              icon={<DollarSign size={20} />}
            />
            <InfoTooltip text="Total net revenue from this wine across all warehouses (DWS, ALM, Direct) in the last 12 months." className="absolute top-3 right-3" />
          </div>
          <div className="relative bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <p className="text-[#505052] text-sm font-medium" style={{ fontFamily: 'Inter, sans-serif' }}>Dual GP%</p>
            <div className="flex items-baseline gap-3 mt-1">
              <div>
                <p className="text-[10px] text-[#505052]">Accounting</p>
                <GpBadge value={sku.gp_pct_accounting} />
              </div>
              <div>
                <p className="text-[10px] text-[#505052]">Economic</p>
                <GpBadge value={sku.gp_pct_economic} />
              </div>
            </div>
            <p className="text-[10px] text-[#505052]/70 mt-2">
              COGS: ${sku.transfer_cost.toFixed(2)} acct / {sku.economic_cogs_per_unit === null ? '—' : `$${sku.economic_cogs_per_unit.toFixed(2)}`} econ
            </p>
            <InfoTooltip text="Accounting GP% uses transfer cost from Vinsight. Economic GP% uses real market grape prices from the What-If Calculator. The gap between them shows how much margin is hidden by below-market grape pricing." className="absolute top-3 right-3" />
          </div>
          <div className="relative">
            <MetricCard
              label="Velocity"
              value={`${sku.velocity_12m} cases/mo`}
              subtitle={`3m: ${sku.velocity_3m} · 6m: ${sku.velocity_6m}`}
              icon={<TrendingUp size={20} />}
            />
            <InfoTooltip text="Average cases sold per month. 12m is the long-term average. Compare 3m vs 12m to spot acceleration or decline." className="absolute top-3 right-3" />
          </div>
          <div className="relative">
            <MetricCard
              label="Vintage"
              value={sku.vintage ? String(sku.vintage) : 'NV'}
              subtitle={sku.sku_group || 'No group'}
              icon={<Wine size={20} />}
            />
            <InfoTooltip text="Harvest year for this wine. NV = Non-Vintage or vintage not determined. See Vintage Attribution below for how vintage was assigned to sales." className="absolute top-3 right-3" />
          </div>
        </div>

        {/* B13-wp-polish — Next vintage callout + vintage breakdown */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-1">
            <NextVintageBox nextVintage={nextVintage} />
          </div>
          <div className="lg:col-span-2">
            <VintageBreakdownTable rows={vintageBreakdown} />
          </div>
        </div>

        {/* Sales Chart + Channel Breakdown */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Sales by Month */}
          <div className="lg:col-span-2 bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2 className="text-sm font-semibold text-[#1F1F1F] mb-1" style={{ fontFamily: 'Cardo, serif' }}>
              Sales by Month
              <InfoTooltip text="Monthly revenue breakdown by warehouse for this wine. DWS = consignment sell-through, ALM = wholesale, Direct = Vinsight invoices." size={10} className="inline-flex ml-1.5 align-middle" />
            </h2>
            <p className="text-[10px] text-[#505052] mb-4">Revenue by warehouse — last 13 months</p>
            <StackedBarChart
              data={sales_by_month.map(m => ({
                month: m.month,
                DWS: parseFloat(String(m.dws)),
                ALM: parseFloat(String(m.alm)),
                Direct: parseFloat(String(m.direct)),
              }))}
              xAxisKey="month"
              series={[
                { key: 'DWS', name: 'DWS', color: '#1B7A3D' },
                { key: 'ALM', name: 'ALM', color: '#BEB3AB' },
                { key: 'Direct', name: 'Direct', color: '#931220' },
              ]}
              height={250}
            />
          </div>

          {/* Warehouse Breakdown */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2 className="text-sm font-semibold text-[#1F1F1F] mb-4" style={{ fontFamily: 'Cardo, serif' }}>
              Warehouse Breakdown
              <InfoTooltip text={VIEW_ONLY ? 'Revenue and case volume per warehouse. DWS stock is on consignment (producer-owned until sold). ALM buys stock outright. Direct is invoiced via Vinsight.' : 'Revenue and case volume per warehouse. DWS stock is on consignment (Moppity-owned until sold). ALM buys stock outright. Direct is invoiced via Vinsight.'} size={10} className="inline-flex ml-1.5 align-middle" />
            </h2>
            {channels.length > 0 ? (
              <div className="space-y-4">
                {channels.map(ch => {
                  const pct = totalChannelRevenue > 0 ? (ch.revenue / totalChannelRevenue * 100) : 0;
                  return (
                    <div key={ch.channel}>
                      <div className="flex items-center justify-between text-xs mb-1">
                        <span className="font-medium text-[#1F1F1F]">{ch.channel}</span>
                        <span className="text-[#505052]">{fmt(ch.revenue)} ({pct.toFixed(0)}%)</span>
                      </div>
                      <div className="w-full bg-[#F3F4F6] rounded-full h-2">
                        <div
                          className="h-2 rounded-full"
                          style={{
                            width: `${pct}%`,
                            backgroundColor: ch.channel === 'Direct' ? '#931220' : ch.channel === 'ALM' ? '#BEB3AB' : '#1B7A3D',
                          }}
                        />
                      </div>
                      {/* BUG-DWS-UOM (the owner ask Apr 22): DWS reports are in BOTTLES,
                          not cases. Per-channel row label flipped to "bottles" for
                          DWS only; ALM/Direct stay "cases". Numeric value unchanged. */}
                      <p className="text-[10px] text-[#505052] mt-0.5">{ch.qty.toFixed(0)} {ch.channel === 'DWS' ? 'bottles' : 'cases'} &middot; {ch.transactions} transactions</p>
                    </div>
                  );
                })}
              </div>
            ) : (
              <p className="text-xs text-[#505052]">No sales data</p>
            )}
          </div>
        </div>

        {/* Traceability Chain */}
        {traceability.length > 0 && (
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2 className="text-sm font-semibold text-[#1F1F1F] mb-1" style={{ fontFamily: 'Cardo, serif' }}>
              Traceability Chain
              <InfoTooltip text="Full chain from grape batch through winemaking vessel to bottled product. Shows which batches, varieties, and regions went into this wine. Source: Vinsight packaging operations." size={10} className="inline-flex ml-1.5 align-middle" />
            </h2>
            <p className="text-[10px] text-[#505052] mb-4">Grape → Batch → Vessel → Packaging → SKU</p>
            <div className="flex items-center gap-2 flex-wrap">
              {traceability.map((step, i) => (
                <div key={i} className="flex items-center gap-2">
                  {i > 0 && <ChevronRight size={14} className="text-[#D8D9DA]" />}
                  <div className="border border-[#D8D9DA] rounded-lg p-3 text-xs min-w-[140px]">
                    <div className="flex items-center gap-1.5 mb-1">
                      <Grape size={12} className="text-[#931220]" />
                      <span className="font-medium text-[#1F1F1F]">{step.batch_variety || 'Unknown'}</span>
                    </div>
                    <p className="text-[10px] text-[#505052]">Batch: {step.batch_code}</p>
                    {step.batch_region && (
                      <p className="text-[10px] text-[#505052]">
                        {step.batch_region}
                        {step.batch_vintage ? ` ${step.batch_vintage}` : ''}
                      </p>
                    )}
                    <div className="flex items-center gap-1.5 mt-2 mb-1">
                      <Beaker size={12} className="text-[#931220]" />
                      <span className="font-medium text-[#1F1F1F]">{step.vessel_name}</span>
                    </div>
                    <p className="text-[10px] text-[#505052]">{Math.abs(step.volume_litres).toFixed(0)}L</p>
                    {step.bottling_date && (
                      <>
                        <div className="flex items-center gap-1.5 mt-2 mb-1">
                          <Package size={12} className="text-[#931220]" />
                          <span className="font-medium text-[#1F1F1F]">Bottled</span>
                        </div>
                        <p className="text-[10px] text-[#505052]">{new Date(step.bottling_date).toLocaleDateString('en-AU')}</p>
                      </>
                    )}
                  </div>
                </div>
              ))}
              <ChevronRight size={14} className="text-[#D8D9DA]" />
              <div className="border-2 border-[#931220] rounded-lg p-3 text-xs min-w-[140px] bg-[#931220]/5">
                <div className="flex items-center gap-1.5 mb-1">
                  <Wine size={12} className="text-[#931220]" />
                  <span className="font-medium text-[#931220]">{sku.sku_code}</span>
                </div>
                <p className="text-[10px] text-[#505052]">{sku.item_description}</p>
              </div>
            </div>
          </div>
        )}

        {/* Cases Sold & Expected Runout + Top Customers */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Cases Sold & Runout */}
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2 className="text-sm font-semibold text-[#1F1F1F] mb-4" style={{ fontFamily: 'Cardo, serif' }}>
              Cases Sold &amp; Stock
              <InfoTooltip text="Total cases sold in the last 12 months and projected stock runout based on 12-month average velocity." size={10} className="inline-flex ml-1.5 align-middle" />
            </h2>
            <div className="space-y-4">
              <div>
                <div className="flex items-center gap-2 mb-1">
                  <Package size={14} className="text-[#931220]" />
                  <span className="text-xs font-medium text-[#505052]">Cases Sold (12m)</span>
                </div>
                <p className="text-2xl font-semibold text-[#1F1F1F] ml-[22px]" style={{ fontFamily: 'Cardo, serif' }}>
                  {sku.qty_12m.toFixed(0)}
                </p>
              </div>
              <div>
                <div className="flex items-center gap-2 mb-1">
                  <BarChart3 size={14} className="text-[#931220]" />
                  <span className="text-xs font-medium text-[#505052]">Current Stock</span>
                </div>
                <p className="text-2xl font-semibold text-[#1F1F1F] ml-[22px]" style={{ fontFamily: 'Cardo, serif' }}>
                  {stock_cases > 0 ? `${stock_cases.toFixed(0)} cases` : 'None'}
                </p>
              </div>
              <div>
                <div className="flex items-center gap-2 mb-1">
                  <Clock size={14} className="text-[#931220]" />
                  <span className="text-xs font-medium text-[#505052]">Expected Runout</span>
                </div>
                <p className={`text-2xl font-semibold ml-[22px] ${
                  runoutDate === 'Out of stock' ? 'text-[#B42318]' : 'text-[#1F1F1F]'
                }`} style={{ fontFamily: 'Cardo, serif' }}>
                  {runoutDate || 'N/A'}
                </p>
                {monthlyVelocity > 0 && stock_cases > 0 && (
                  <p className="text-[10px] text-[#505052] ml-[22px] mt-0.5">
                    {(stock_cases / monthlyVelocity).toFixed(1)} months at {monthlyVelocity} cases/mo
                  </p>
                )}
              </div>
            </div>
          </div>

          {/* Top Customers */}
          <div className="lg:col-span-2 bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <h2 className="text-sm font-semibold text-[#1F1F1F] mb-1" style={{ fontFamily: 'Cardo, serif' }}>
              Top Customers
              <InfoTooltip text="Top 5 customers for this wine by revenue (last 12 months). Growth indicators compare the last 6 months vs the prior 6 months: green = >10% increase, red = >10% decrease." size={10} className="inline-flex ml-1.5 align-middle" />
            </h2>
            <p className="text-[10px] text-[#505052] mb-4">By revenue — last 12 months</p>
            {top_customers.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr className="bg-[#1F1F1F] text-white">
                      <th className="text-left px-3 py-2 rounded-tl-lg font-medium">Customer</th>
                      <th className="text-left px-3 py-2 font-medium">Channel</th>
                      <th className="text-right px-3 py-2 font-medium">Cases</th>
                      <th className="text-right px-3 py-2 font-medium">Revenue</th>
                      <th className="text-center px-3 py-2 rounded-tr-lg font-medium">Trend</th>
                    </tr>
                  </thead>
                  <tbody>
                    {top_customers.map((tc, i) => (
                      <tr key={tc.customer_name} className={`border-b border-[#F3F4F6] ${i % 2 === 1 ? 'bg-[#FAF9F7]' : ''}`}>
                        <td className="px-3 py-2 font-medium text-[#1F1F1F]">{tc.customer_name}</td>
                        <td className="px-3 py-2 text-[#505052]">
                          {/* B3 fix: show em-dash when channel is empty/null/'Unknown'.
                              Underlying combined_data_enriched has ~1,411 rows with empty
                              channel pending EMPTY-CHANNEL-BACKFILL-P1.5. */}
                          {!tc.channel || tc.channel === 'Unknown' ? '—' : tc.channel}
                        </td>
                        <td className="px-3 py-2 text-right text-[#1F1F1F] tabular-nums">{tc.cases.toFixed(0)}</td>
                        <td className="px-3 py-2 text-right text-[#1F1F1F] tabular-nums">{fmt(tc.revenue)}</td>
                        <td className="px-3 py-2 text-center">
                          {tc.trend === 'growth' && (
                            <span className="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full text-[10px] font-medium bg-[#1B7A3D]/10 text-[#1B7A3D]">
                              ↑ Growth
                            </span>
                          )}
                          {tc.trend === 'decline' && (
                            <span className="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full text-[10px] font-medium bg-[#B42318]/10 text-[#B42318]">
                              ↓ Decline
                            </span>
                          )}
                          {tc.trend === 'stable' && (
                            <span className="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full text-[10px] font-medium bg-[#505052]/10 text-[#505052]">
                              → Stable
                            </span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <p className="text-xs text-[#505052]">No customer data for this wine</p>
            )}
          </div>
        </div>

        {/* Vintage Attribution + Related Vintages */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Vintage Attribution */}
          {vintage_attribution.length > 0 && (
            <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
              <div className="flex items-center gap-1.5 mb-4">
                <h2 className="text-sm font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
                  Vintage Attribution
                </h2>
                <InfoTooltip text="How vintage was determined for each sale of this wine. Methods include: SKU code extraction, batch traceability, customer/invoice matching, and manual override. Higher confidence = more reliable attribution." />
              </div>
              <div className="space-y-2">
                {vintage_attribution.map((va, i) => (
                  <div key={i} className="flex items-center justify-between text-xs border-b border-[#F3F4F6] pb-2 last:border-0">
                    <div>
                      <span className="font-medium text-[#1F1F1F]">{va.vintage}</span>
                      <span className="text-[#505052] ml-2">{va.method.replace(/_/g, ' ')}</span>
                    </div>
                    <div className="text-right">
                      <span className="text-[#1F1F1F]">{fmt(va.revenue)}</span>
                      <span className="text-[#505052] ml-2">({va.sales_count} sales)</span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Related Vintages */}
          {related_vintages.length > 0 && (
            <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
              <h2 className="text-sm font-semibold text-[#1F1F1F] mb-4" style={{ fontFamily: 'Cardo, serif' }}>
                Vintages (from Vinsight dispatches)
              </h2>
              <div className="space-y-2">
                {related_vintages.map(rv => (
                  <div
                    key={rv.vintage}
                    className="flex items-center justify-between text-xs border-b border-[#F3F4F6] pb-2 last:border-0 -mx-2 px-2 py-1 rounded"
                  >
                    <div>
                      <span className="font-medium text-[#1F1F1F]">{rv.vintage}</span>
                      <span className="text-[#505052] ml-2 font-mono text-[10px]">{rv.sku_codes}</span>
                    </div>
                    <div className="text-right">
                      <span className="text-[#1F1F1F]">{rv.qty_dispatched.toFixed(0)} cases</span>
                      <span className="text-[#505052] ml-2">{rv.dispatch_count} dispatches</span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </AppLayout>
  );
}

export default function WineProfilePage() {
  return (
    <Suspense fallback={<AppLayout><div className="flex items-center justify-center h-64"><div className="text-[#505052]">Loading...</div></div></AppLayout>}>
      <WineProfileContent />
    </Suspense>
  );
}

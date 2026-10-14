'use client';

import { useEffect, useState, useMemo, Fragment } from 'react';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import Badge from '@/components/Badge';
import {
  Package,
  Wine,
  Beaker,
  AlertTriangle,
  CheckCircle,
  Clock,
  Search,
  ChevronDown,
  ChevronRight,
} from 'lucide-react';
import InfoTooltip from '@/components/InfoTooltip';
import Link from 'next/link';

// Demo mirror flag — genericize visible brand labels for prospects. Unset => live prod text.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

interface StockItem {
  sku_code: string;
  description: string;
  units_in_stock: number;
  uom: string;
  standard_cost: number;
  sku_id: number | null;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  base_wholesale: number;
  range_name: string | null;
  sku_group: string | null;
  canonical_sku_id: number | null;
  canonical_sku_name: string | null;
  velocity_12m: number;
  velocity_6m: number;
  velocity_3m: number;
  dws_cases: number;
  months_cover: number | null;
  projected_runout: string | null;
  children?: StockItem[];
  is_nv_parent?: boolean;
  group_key?: string;
}

interface Vessel {
  vessel_code: string;
  name: string;
  vessel_type: string | null;
  volume_litres: number;
  batch_code: string | null;
  batch_desc: string | null;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  color: string | null;
}

interface BottlingRun {
  description: string;
  bottling_date: string;
  cases_produced: number | null;
  status: string;
  sku_code: string | null;
  item_description: string | null;
}

interface InventoryData {
  kpis: {
    wines_in_stock: number;
    total_cases: number;
    total_stock_value: number;
    // JR-055 / JR-148: warehouse split (Moppity-held vs DWS consignment)
    moppity_cases: number;
    moppity_stock_value: number;
    dws_cases: number;
    dws_stock_value: number;
    active_vessels: number;
    bulk_litres: number;
  };
  stock: StockItem[];
  vessels: Vessel[];
  bottling_runs: BottlingRun[];
}

const fmt = (n: number) => n >= 1000000 ? `$${(n/1000000).toFixed(1)}M` : n >= 1000 ? `$${(n/1000).toFixed(1)}K` : `$${n.toFixed(0)}`;

// JC-274 / JC-398: rows with cover > 60 months ("dead-stock") get a distinct
// neutral-dark badge so they don't masquerade as "Healthy". 60mo is the
// The owner can override to a different threshold post-delivery.
const DEAD_STOCK_MONTHS = 60;

function CoverBadge({ months }: { months: number | null }) {
  if (months === null || months === undefined || Number.isNaN(months)) return <span className="text-xs text-[#505052]">--</span>;
  if (!Number.isFinite(months)) return <span className="text-xs text-[#505052]">--</span>;
  const rounded = Math.round(months);
  if (months > DEAD_STOCK_MONTHS) {
    return <Badge variant="neutral">{rounded}mo — Dead Stock</Badge>;
  }
  const color = months >= 6 ? 'success' : months >= 3 ? 'warning' : 'error';
  const label = months >= 6 ? 'Healthy' : months >= 3 ? 'Monitor' : 'Low';
  return <Badge variant={color}>{rounded}mo — {label}</Badge>;
}

export default function InventoryPage() {
  const [data, setData] = useState<InventoryData | null>(null);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [sortKey, setSortKey] = useState<'wine' | 'stock' | 'cover' | 'velocity' | 'runout' | 'value'>('stock');
  const [sortDesc, setSortDesc] = useState(true);
  const [showVessels, setShowVessels] = useState(false);
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set());
  const [velWindow, setVelWindow] = useState<'3m' | '6m' | '12m'>('12m');
  // BUG-73: client-side pagination for Stock-on-Hand (50 rows/page) so rows 51+
  // are reachable. Full dataset already arrives from /api/inventory.
  const [page, setPage] = useState(1);
  const PAGE_SIZE = 50;

  type InventorySortKey = 'wine' | 'stock' | 'cover' | 'velocity' | 'runout' | 'value';

  function toggleSort(key: InventorySortKey) {
    if (sortKey === key) {
      setSortDesc(!sortDesc);
    } else {
      setSortKey(key);
      setSortDesc(true);
    }
  }

  function getVel(item: StockItem): number {
    return velWindow === '3m' ? item.velocity_3m : velWindow === '6m' ? item.velocity_6m : item.velocity_12m;
  }

  function toggleGroup(groupName: string) {
    setExpandedGroups(prev => {
      const next = new Set(prev);
      if (next.has(groupName)) next.delete(groupName);
      else next.add(groupName);
      return next;
    });
  }

  useEffect(() => {
    apiGet('/api/inventory').then(r => r.json()).then(d => {
      setData(d);
      setLoading(false);
    }).catch(() => setLoading(false));
  }, []);

  // NV grouping for stock items
  // M3-07: Group by canonical_sku_id instead of sku_group for tighter product grouping
  // BUG-28: Use a stable group_key stored on parent to fix expand/collapse mismatch
  const nvGroupedStock = useMemo<StockItem[]>(() => {
    if (!data) return [];
    const groups = new Map<string, StockItem[]>();
    for (const item of data.stock) {
      const key = item.canonical_sku_id ? `csku_${item.canonical_sku_id}` : (item.sku_group || item.description);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key)!.push(item);
    }

    const result: StockItem[] = [];
    groups.forEach((children: StockItem[], groupKey: string) => {
      if (children.length === 1) {
        result.push(children[0]);
        return;
      }

      children.sort((a: StockItem, b: StockItem) => (b.vintage || 0) - (a.vintage || 0));

      const totalStock = children.reduce((s: number, c: StockItem) => s + c.units_in_stock, 0);
      const totalVel12 = children.reduce((s: number, c: StockItem) => s + c.velocity_12m, 0);
      const totalVel6 = children.reduce((s: number, c: StockItem) => s + c.velocity_6m, 0);
      const totalVel3 = children.reduce((s: number, c: StockItem) => s + c.velocity_3m, 0);
      const totalValue = children.reduce((s: number, c: StockItem) => s + c.units_in_stock * c.standard_cost, 0);
      const avgCost = totalStock > 0 ? totalValue / totalStock : children[0].standard_cost;
      const cover = totalVel12 > 0 ? Math.round(totalStock / totalVel12 * 10) / 10 : null;
      // Latest runout from children
      const runouts = children.filter((c: StockItem) => c.projected_runout).map((c: StockItem) => c.projected_runout!);
      const latestRunout = runouts.length > 0 ? runouts.sort().pop()! : null;

      // M3-07: Use canonical_sku_name as display name when available
      const displayName = children[0].canonical_sku_name || children[0].sku_group || children[0].description;
      result.push({
        ...children[0],
        description: displayName,
        sku_code: `${children.length} vintages`,
        vintage: null,
        units_in_stock: totalStock,
        standard_cost: avgCost,
        velocity_12m: Math.round(totalVel12 * 10) / 10,
        velocity_6m: Math.round(totalVel6 * 10) / 10,
        velocity_3m: Math.round(totalVel3 * 10) / 10,
        dws_cases: children.reduce((s: number, c: StockItem) => s + c.dws_cases, 0),
        months_cover: cover,
        projected_runout: latestRunout,
        children,
        is_nv_parent: true,
        group_key: groupKey,
      });
    });
    return result;
  }, [data]);

  const filteredStock = useMemo(() => {
    if (!data) return [];
    let items = nvGroupedStock;
    if (search) {
      const q = search.toLowerCase();
      items = items.filter(s =>
        s.description.toLowerCase().includes(q) ||
        s.sku_code.toLowerCase().includes(q) ||
        (s.variety && s.variety.toLowerCase().includes(q)) ||
        (s.region && s.region.toLowerCase().includes(q)) ||
        (s.children && s.children.some(c =>
          c.description.toLowerCase().includes(q) ||
          c.sku_code.toLowerCase().includes(q)
        ))
      );
    }
    items = [...items];
    items.sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case 'wine': cmp = a.description.localeCompare(b.description); break;
        case 'stock': cmp = b.units_in_stock - a.units_in_stock; break;
        case 'cover': cmp = (b.months_cover ?? -1) - (a.months_cover ?? -1); break;
        case 'velocity': cmp = getVel(b) - getVel(a); break;
        case 'runout': {
          const aDate = a.projected_runout ? new Date(a.projected_runout).getTime() : Infinity;
          const bDate = b.projected_runout ? new Date(b.projected_runout).getTime() : Infinity;
          cmp = aDate - bDate;
          break;
        }
        case 'value': cmp = (b.units_in_stock * b.standard_cost) - (a.units_in_stock * a.standard_cost); break;
      }
      return sortDesc ? cmp : -cmp;
    });
    return items;
  }, [data, nvGroupedStock, search, sortKey, sortDesc]);

  // BUG-73: reset to page 1 whenever filtered list changes (search, sort, vel window)
  useEffect(() => { setPage(1); }, [search, sortKey, sortDesc, velWindow]);

  const totalPages = Math.max(1, Math.ceil(filteredStock.length / PAGE_SIZE));
  const currentPage = Math.min(page, totalPages);
  const pageStart = (currentPage - 1) * PAGE_SIZE;
  const pagedStock = filteredStock.slice(pageStart, pageStart + PAGE_SIZE);

  if (loading) return <AppLayout><div className="flex items-center justify-center h-64 text-[#505052]">Loading...</div></AppLayout>;
  if (!data) return <AppLayout><div className="flex items-center justify-center h-64 text-[#B42318]">Failed to load</div></AppLayout>;

  const { kpis, vessels, bottling_runs } = data;
  const lowCoverCount = data.stock.filter(s => s.months_cover !== null && s.months_cover < 3).length;

  return (
    <AppLayout>
      <div className="space-y-6">
        {/* Header */}
        <div className="flex items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
              Inventory & Bottling
            </h1>
            <p className="text-sm text-[#505052]" style={{ fontFamily: 'Inter, sans-serif' }}>
              Stock on hand, projected run-out, bulk wine vessels, and bottling activity
            </p>
          </div>
        </div>

        {/* Warehouse Split (JR-055 / JR-148) — Moppity vs DWS vs Total */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div className="relative h-full">
            <MetricCard
              label={VIEW_ONLY ? 'Own Stock' : 'Moppity Stock'}
              value={kpis.moppity_cases.toLocaleString()}
              subtitle={`${fmt(kpis.moppity_stock_value)} at standard cost`}
              icon={<Package size={20} />}
            />
            <InfoTooltip text={VIEW_ONLY ? 'Cases held in own warehouses (excluding DWS consignment). Source: Vinsight stock on hand, filtered to SKUs not mapped to DWS.' : 'Cases held in Moppity warehouses (excluding DWS consignment). Source: Vinsight stock on hand, filtered to SKUs not mapped to DWS.'} className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard
              label="DWS Consignment"
              value={kpis.dws_cases.toLocaleString()}
              subtitle={`${fmt(kpis.dws_stock_value)} at standard cost`}
              icon={<Package size={20} />}
            />
            <InfoTooltip text={VIEW_ONLY ? 'Cases sitting at DWS on consignment. Stock remains producer-owned until sell-through. Classified via sku_code_map (source_system=dws).' : 'Cases sitting at DWS on consignment. Stock remains Moppity-owned until sell-through. Classified via sku_code_map (source_system=dws).'} className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard
              label={VIEW_ONLY ? 'Total (Own + DWS)' : 'Total (Moppity + DWS)'}
              value={kpis.total_cases.toLocaleString()}
              subtitle={`${fmt(kpis.total_stock_value)} at standard cost`}
              icon={<Package size={20} />}
            />
            <InfoTooltip text={VIEW_ONLY ? 'Total packaged cases across own warehouses plus DWS consignment. Consignment stock is producer-owned, so Total = Own + DWS.' : 'Total packaged cases across Moppity warehouses plus DWS consignment. Consignment stock is Moppity-owned, so Total = Moppity + DWS.'} className="absolute top-3 right-3" />
          </div>
        </div>

        {/* KPI Cards */}
        <div className="grid grid-cols-2 lg:grid-cols-5 gap-4">
          <div className="relative h-full">
            <MetricCard label="Wines in Stock" value={kpis.wines_in_stock} subtitle="packaged SKUs" icon={<Wine size={20} />} />
            <InfoTooltip text="Number of distinct packaged wines currently in Vinsight inventory with stock > 0." className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard label="Total Cases" value={kpis.total_cases.toLocaleString()} subtitle="across all SKUs" icon={<Package size={20} />} />
            <InfoTooltip text="Sum of all packaged cases on hand across all SKUs. Source: Vinsight stock on hand." className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard label="Stock Value" value={fmt(kpis.total_stock_value)} subtitle="at standard cost" icon={<Package size={20} />} />
            <InfoTooltip text="Total inventory value calculated as cases × standard cost per case. Standard cost comes from Vinsight transfer cost." className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard label="Bulk Wine" value={`${(kpis.bulk_litres / 1000).toFixed(0)}K L`} subtitle={`${kpis.active_vessels} active vessels`} icon={<Beaker size={20} />} />
            <InfoTooltip text="Total litres of unpackaged wine sitting in tanks/barrels. Active vessels = tanks/barrels with wine volume > 0. This wine hasn't been bottled yet." className="absolute top-3 right-3" />
          </div>
          <div className="relative bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <p className="text-[#505052] text-sm font-medium" style={{ fontFamily: 'Inter, sans-serif' }}>Low Cover Alert</p>
            <p className="text-2xl font-semibold mt-1" style={{ fontFamily: 'Cardo, serif', color: lowCoverCount > 0 ? '#B42318' : '#1B7A3D' }}>
              {lowCoverCount}
            </p>
            <p className="text-[#505052]/70 text-xs mt-2" style={{ fontFamily: 'Inter, sans-serif' }}>SKUs under 3 months cover</p>
            <InfoTooltip text="SKUs where stock ÷ monthly velocity < 3 months. These wines may run out soon and need bottling or reorder attention." className="absolute top-3 right-3" />
          </div>
        </div>

        {/* Stock Table */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm">
          <div className="p-4 border-b border-[#F3F4F6] flex items-center justify-between">
            <h2 className="text-sm font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
              Stock on Hand
            </h2>
            <div className="flex items-center gap-3">
              <div className="relative h-full">
                <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#D8D9DA]" />
                <input
                  type="text"
                  placeholder="Search wines..."
                  value={search}
                  onChange={e => setSearch(e.target.value)}
                  className="pl-8 pr-3 py-1.5 text-xs border border-[#D8D9DA] rounded-lg w-48"
                />
              </div>
              <select
                value={sortKey}
                onChange={e => { setSortKey(e.target.value as InventorySortKey); setSortDesc(true); }}
                className="text-xs border border-[#D8D9DA] rounded-lg px-2 py-1.5"
              >
                <option value="stock">Sort: Stock (high→low)</option>
                <option value="cover">Sort: Cover (high→low)</option>
                <option value="velocity">Sort: Velocity (high→low)</option>
                <option value="value">Sort: Value (high→low)</option>
              </select>
              <div className="flex items-center gap-1">
                <span className="text-[10px] text-[#505052]">Vel:</span>
                <div className="flex bg-[#F3F3F3] rounded-md p-0.5">
                  {(['3m', '6m', '12m'] as const).map(w => (
                    <button key={w} onClick={() => setVelWindow(w)}
                      className={`px-2 py-1 rounded text-[10px] font-medium transition-colors ${
                        velWindow === w ? 'bg-white text-[#1F1F1F] shadow-sm' : 'text-[#505052] hover:text-[#1F1F1F]'
                      }`}>{w === '3m' ? 'M' : w === '6m' ? 'Q' : 'Y'}</button>
                  ))}
                </div>
              </div>
              <span className="text-xs text-[#505052]">{filteredStock.length} of {nvGroupedStock.length} products</span>
            </div>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-xs" style={{ fontFamily: 'Inter, sans-serif' }}>
              <thead>
                <tr className="border-b border-[#F3F4F6] text-[#505052]">
                  {[
                    { label: 'Wine', key: 'wine' as InventorySortKey, align: 'left', tooltip: 'Product name, SKU code, variety and region' },
                    { label: 'Cases', key: 'stock' as InventorySortKey, align: 'right', tooltip: 'Packaged cases on hand from Vinsight inventory. Updated daily via sync.' },
                    { label: 'Velocity', key: 'velocity' as InventorySortKey, align: 'right', tooltip: 'Average cases sold per month over the last 12 months across all warehouses.' },
                    { label: 'Cover', key: 'cover' as InventorySortKey, align: 'center', tooltip: 'Months of stock remaining at current velocity. Green = 6+ months, Amber = 3-6 months, Red = under 3 months.' },
                    { label: 'Run-out', key: 'runout' as InventorySortKey, align: 'right', tooltip: 'Projected date when stock will reach zero at current sales velocity.' },
                    { label: 'Value', key: 'value' as InventorySortKey, align: 'right', tooltip: 'Cases on hand x standard cost per case.' },
                  ].map(col => (
                    <th
                      key={col.label}
                      className={`text-${col.align} px-4 py-3 font-medium cursor-pointer hover:text-[#1F1F1F] select-none whitespace-nowrap`}
                      onClick={() => toggleSort(col.key)}
                    >
                      {col.label}
                      {col.key !== 'wine' && (
                        <InfoTooltip text={col.tooltip} size={10} className="inline-flex ml-0.5 align-middle" />
                      )}
                      {sortKey === col.key && <span className="ml-0.5">{sortDesc ? '\u2193' : '\u2191'}</span>}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {pagedStock.map(item => {
                  const isParent = item.is_nv_parent && item.children && item.children.length > 1;
                  // BUG-28: Use the stable group_key assigned during grouping to ensure
                  // expand/collapse toggle matches the same key used for state tracking
                  const groupKey = item.group_key || item.sku_group || item.description;
                  const isExpanded = expandedGroups.has(groupKey);

                  return (
                    <Fragment key={isParent ? groupKey : item.sku_code}>
                      <tr
                        className={`border-b border-[#F3F4F6] hover:bg-[#FAF9F7] transition-colors ${isParent ? 'cursor-pointer' : ''}`}
                        onClick={isParent ? () => toggleGroup(groupKey) : undefined}
                      >
                        <td className="px-4 py-3">
                          <div className="flex items-start gap-1.5">
                            {isParent && (
                              <span className="mt-0.5 text-[#505052] shrink-0">
                                {isExpanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                              </span>
                            )}
                            <div>
                              {isParent ? (
                                <span className="font-medium text-[#1F1F1F]">{item.description}</span>
                              ) : item.sku_id ? (
                                <Link href={`/wines?sku_id=${item.sku_id}`} className="font-medium text-[#1F1F1F] hover:text-[#931220] transition-colors">
                                  {item.description}
                                </Link>
                              ) : (
                                <span className="font-medium text-[#1F1F1F]">{item.description}</span>
                              )}
                              <div className="text-[10px] text-[#505052] mt-0.5 flex items-center gap-1.5">
                                <span>{isParent
                                  ? <><span className="text-[#931220]/70 font-medium">{item.children!.length} vintages</span> &middot; {item.variety || ''} &middot; {item.region || ''}</>
                                  : <><span className="font-mono">{item.sku_code}</span>{item.variety && <> &middot; {item.variety}</>}{item.region && <> &middot; {item.region}</>}{item.vintage && <> &middot; {item.vintage}</>}</>
                                }</span>
                                {item.dws_cases > 0 && (
                                  // BUG-DWS-UOM (the owner ask Apr 22): DWS reports are in
                                  // BOTTLES, not cases. Display label flipped to "btl"
                                  // for DWS-channel rows. Numeric value unchanged
                                  // (sales_transaction_normalized.quantity_cases is
                                  // already case-equivalent post-ETL).
                                  <span className="px-1.5 py-0.5 rounded bg-blue-100 text-blue-700 text-[9px] font-medium">
                                    DWS {Math.round(item.dws_cases)}btl
                                  </span>
                                )}
                              </div>
                            </div>
                          </div>
                        </td>
                        <td className="text-right px-4 py-3 font-medium text-[#1F1F1F]">
                          {item.units_in_stock.toFixed(0)}
                        </td>
                        <td className="text-right px-4 py-3 text-[#505052]">
                          {getVel(item) > 0 ? `${getVel(item)}/mo` : '--'}
                        </td>
                        <td className="text-center px-4 py-3">
                          {getVel(item) === 0 && item.units_in_stock > 0 ? (
                            <Badge variant="info">New</Badge>
                          ) : (
                            <CoverBadge months={item.months_cover} />
                          )}
                        </td>
                        <td className="text-right px-4 py-3 text-[#505052]">
                          {item.projected_runout
                            ? new Date(item.projected_runout).toLocaleDateString('en-AU', { month: 'short', year: 'numeric' })
                            : '--'}
                        </td>
                        <td className="text-right px-4 py-3 text-[#1F1F1F]">
                          {fmt(item.units_in_stock * item.standard_cost)}
                        </td>
                      </tr>
                      {isParent && isExpanded && item.children!.map(child => (
                        <tr key={child.sku_code} className="border-b border-[#F3F4F6]/50 bg-[#FAF9F7]/50 text-[#505052]">
                          <td className="px-4 py-2 pl-10">
                            {child.sku_id ? (
                              <Link href={`/wines?sku_id=${child.sku_id}`} className="hover:text-[#931220] transition-colors text-xs">
                                {child.vintage || 'NV'} &mdash; {child.description}
                              </Link>
                            ) : (
                              <span className="text-xs">{child.vintage || 'NV'} &mdash; {child.description}</span>
                            )}
                            <div className="text-[10px] text-[#505052]/40 font-mono">{child.sku_code}</div>
                          </td>
                          <td className="text-right px-4 py-2 text-xs">{child.units_in_stock.toFixed(0)}</td>
                          <td className="text-right px-4 py-2 text-xs">{getVel(child) > 0 ? `${getVel(child)}/mo` : '--'}</td>
                          <td className="text-center px-4 py-2"><CoverBadge months={child.months_cover} /></td>
                          <td className="text-right px-4 py-2 text-xs">
                            {child.projected_runout
                              ? new Date(child.projected_runout).toLocaleDateString('en-AU', { month: 'short', year: 'numeric' })
                              : '--'}
                          </td>
                          <td className="text-right px-4 py-2 text-xs">{fmt(child.units_in_stock * child.standard_cost)}</td>
                        </tr>
                      ))}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
          {/* BUG-73: Prev/Next + numbered pagination (pattern mirrors /legacy-data). */}
          {filteredStock.length > PAGE_SIZE && (() => {
            const windowSize = 5;
            let winStart = Math.max(1, currentPage - Math.floor(windowSize / 2));
            const winEnd = Math.min(totalPages, winStart + windowSize - 1);
            winStart = Math.max(1, winEnd - windowSize + 1);
            const windowPages = Array.from({ length: winEnd - winStart + 1 }, (_, i) => winStart + i);
            const showingTo = Math.min(pageStart + PAGE_SIZE, filteredStock.length);
            return (
              <div className="flex items-center justify-between px-4 py-2.5 border-t border-[#F3F4F6] text-xs text-[#505052]">
                <span>Showing {pageStart + 1}-{showingTo} of {filteredStock.length}</span>
                <div className="flex gap-1 items-center">
                  <button onClick={() => setPage(Math.max(1, currentPage - 1))} disabled={currentPage <= 1}
                    className="px-2.5 py-1 rounded bg-[#F3F3F3] text-[#505052] disabled:text-[#B0B1B3] disabled:cursor-not-allowed hover:bg-[#E8E8E8]">
                    Prev
                  </button>
                  {winStart > 1 && (
                    <>
                      <button onClick={() => setPage(1)}
                        className="px-2 py-1 rounded min-w-[28px] bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]">1</button>
                      {winStart > 2 && <span className="px-1 py-1">…</span>}
                    </>
                  )}
                  {windowPages.map(p => (
                    <button key={p} onClick={() => setPage(p)}
                      className={`px-2 py-1 rounded min-w-[28px] ${currentPage === p ? 'bg-[#931220] text-white' : 'bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]'}`}>
                      {p}
                    </button>
                  ))}
                  {winEnd < totalPages && (
                    <>
                      {winEnd < totalPages - 1 && <span className="px-1 py-1">…</span>}
                      <button onClick={() => setPage(totalPages)}
                        className="px-2 py-1 rounded min-w-[28px] bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]">{totalPages}</button>
                    </>
                  )}
                  <button onClick={() => setPage(Math.min(totalPages, currentPage + 1))} disabled={currentPage >= totalPages}
                    className="px-2.5 py-1 rounded bg-[#F3F3F3] text-[#505052] disabled:text-[#B0B1B3] disabled:cursor-not-allowed hover:bg-[#E8E8E8]">
                    Next
                  </button>
                </div>
                <span>{PAGE_SIZE} rows per page</span>
              </div>
            );
          })()}
        </div>

        {/* Bulk Wine Vessels */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm">
          <button
            onClick={() => setShowVessels(!showVessels)}
            className="w-full p-4 flex items-center justify-between hover:bg-[#FAF9F7] transition-colors rounded-xl"
          >
            <h2 className="text-sm font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
              Bulk Wine Vessels ({vessels.length})
              <InfoTooltip text="Tanks and barrels containing unpackaged wine. Volume in litres. Each vessel is linked to a batch with variety, region, and vintage info from Vinsight." size={10} className="inline-flex ml-1.5 align-middle" />
            </h2>
            {showVessels ? <ChevronDown size={16} className="text-[#505052]" /> : <ChevronRight size={16} className="text-[#505052]" />}
          </button>
          {showVessels && (
            <div className="px-4 pb-4">
              <table className="w-full text-xs" style={{ fontFamily: 'Inter, sans-serif' }}>
                <thead>
                  <tr className="border-b border-[#F3F4F6] text-[#505052]">
                    <th className="text-left px-3 py-2 font-medium">Vessel</th>
                    <th className="text-left px-3 py-2 font-medium">Wine</th>
                    <th className="text-right px-3 py-2 font-medium">Volume (L)</th>
                    <th className="text-left px-3 py-2 font-medium">Vintage</th>
                  </tr>
                </thead>
                <tbody>
                  {vessels.map(v => (
                    <tr key={v.vessel_code} className="border-b border-[#F3F4F6]">
                      <td className="px-3 py-2 font-medium text-[#1F1F1F]">{v.name || v.vessel_code}</td>
                      <td className="px-3 py-2 text-[#505052]">
                        {v.batch_desc || v.variety || '--'}
                        {v.region && <span className="text-[#505052]/60"> · {v.region}</span>}
                      </td>
                      <td className="text-right px-3 py-2 text-[#1F1F1F]">{v.volume_litres.toLocaleString()}</td>
                      <td className="px-3 py-2 text-[#505052]">{v.vintage || '--'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Recent Bottling Runs */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm p-4">
          <h2 className="text-sm font-semibold text-[#1F1F1F] mb-3" style={{ fontFamily: 'Cardo, serif' }}>
            Recent Bottling Runs
            <InfoTooltip text="Recent packaging operations from Vinsight — when bulk wine was bottled into cases. 'Bulk To Pack' = completed bottling run." size={10} className="inline-flex ml-1.5 align-middle" />
          </h2>
          <div className="space-y-2">
            {bottling_runs.slice(0, 10).map((run, i) => (
              <div key={i} className="flex items-center justify-between text-xs border-b border-[#F3F4F6] pb-2 last:border-0">
                <div>
                  <span className="font-medium text-[#1F1F1F]">{run.description}</span>
                  {run.sku_code && <span className="text-[#505052] ml-2 font-mono">{run.sku_code}</span>}
                </div>
                <div className="flex items-center gap-4 text-[#505052]">
                  <span>{run.cases_produced ? `${run.cases_produced} cases` : '--'}</span>
                  <span>{new Date(run.bottling_date).toLocaleDateString('en-AU')}</span>
                  <Badge variant={run.status === 'Bulk To Pack' ? 'success' : 'neutral'}>{run.status}</Badge>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </AppLayout>
  );
}

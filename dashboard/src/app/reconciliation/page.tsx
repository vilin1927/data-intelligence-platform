'use client';

import { useEffect, useState, useMemo } from 'react';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import Badge from '@/components/Badge';
import {
  FileSpreadsheet,
  Package,
  AlertTriangle,
  CheckCircle,
  Search,
  Link2,
  DollarSign,
} from 'lucide-react';
import InfoTooltip, { InfoBanner } from '@/components/InfoTooltip';
import Link from 'next/link';

// Demo mirror flag — genericize visible brand copy for prospects. Unset => live prod text.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

interface InventoryItem {
  canonical_sku_id: number;
  sku_name: string;
  mv_codes: string | null;
  dws_codes: string | null;
  mv_stock: number;
  dws_soh: number; // DWS stock-on-hand from Vinsight keyed by DWS external_code
  dws_qty_3m: number;
  dws_revenue_3m: number;
  dws_qty_1m: number;
  dws_total_qty: number;
  dws_total_revenue: number;
  last_sale_date: string | null;
}

interface UnmappedItem {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  vintage: number | null;
  total_qty: number;
  total_revenue: number;
  last_sale_date: string | null;
}

interface MonthlySummary {
  month: string;
  cases: number;
  revenue: number;
  skus_sold: number;
  customers: number;
}

interface ReconciliationData {
  kpis: {
    total_dws_skus: number;
    mapped_skus: number;
    unmapped_skus: number;
    with_stock: number;
    dws_revenue_12m: number;
    dws_cases_12m: number;
  };
  inventory: InventoryItem[];
  unmapped: UnmappedItem[];
  monthly_summary: MonthlySummary[];
}

const fmt = (n: number) => n >= 1000000 ? `$${(n/1000000).toFixed(1)}M` : n >= 1000 ? `$${(n/1000).toFixed(1)}K` : `$${n.toFixed(0)}`;

type Tab = 'all' | 'with_stock' | 'unmapped';

export default function ReconciliationPage() {
  const [data, setData] = useState<ReconciliationData | null>(null);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [tab, setTab] = useState<Tab>('all');

  useEffect(() => {
    apiGet('/api/reconciliation').then(r => r.json()).then(d => {
      setData(d);
      setLoading(false);
    }).catch(() => setLoading(false));
  }, []);

  const filteredInventory = useMemo(() => {
    if (!data) return [];
    let items = data.inventory;
    if (tab === 'with_stock') items = items.filter(i => i.mv_stock > 0);
    if (search) {
      const q = search.toLowerCase();
      items = items.filter(i =>
        i.sku_name.toLowerCase().includes(q) ||
        (i.mv_codes && i.mv_codes.toLowerCase().includes(q)) ||
        (i.dws_codes && i.dws_codes.toLowerCase().includes(q))
      );
    }
    return items;
  }, [data, tab, search]);

  if (loading) return <AppLayout><div className="flex items-center justify-center h-64 text-[#505052]">Loading...</div></AppLayout>;
  if (!data) return <AppLayout><div className="flex items-center justify-center h-64 text-[#B42318]">Failed to load</div></AppLayout>;

  const { kpis, unmapped, monthly_summary } = data;

  return (
    <AppLayout>
      <div className="space-y-6">
        {/* Header */}
        <div>
          <h1 className="text-2xl font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
            DWS Reconciliation
          </h1>
          <p className="text-sm text-[#505052]" style={{ fontFamily: 'Inter, sans-serif' }}>
            {VIEW_ONLY
              ? 'Compare warehouse stock against DWS sell-through. Consignment inventory tracking.'
              : 'Compare Moppity warehouse stock against DWS sell-through. Consignment inventory tracking.'}
          </p>
        </div>

        {/* KPI Cards */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <div className="relative h-full">
            <MetricCard label="DWS Revenue (12m)" value={fmt(kpis.dws_revenue_12m)} subtitle={`${kpis.dws_cases_12m.toLocaleString()} cases`} icon={<DollarSign size={20} />} />
            <InfoTooltip text={VIEW_ONLY ? 'Total revenue from DWS consignment warehouse over last 12 months. DWS sells the wine on consignment — revenue is recognised when the end customer buys.' : 'Total revenue from DWS consignment warehouse over last 12 months. DWS sells Moppity wine on consignment — revenue is recognised when the end customer buys.'} className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard label="DWS SKUs" value={data.inventory.length} subtitle={`${kpis.mapped_skus} mapped codes`} icon={<Package size={20} />} />
            <InfoTooltip text={VIEW_ONLY ? "Total distinct wines sold through DWS. 'Mapped' means the DWS code (e.g. MOLKSH21F) has been linked to an internal code (e.g. MVLKSHZB21)." : "Total distinct wines sold through DWS. 'Mapped' means the DWS code (e.g. MOLKSH21F) has been linked to a Moppity code (e.g. MVLKSHZB21)."} className="absolute top-3 right-3" />
          </div>
          <div className="relative h-full">
            <MetricCard label="With Stock" value={kpis.with_stock} subtitle={VIEW_ONLY ? 'have warehouse stock' : 'have Moppity warehouse stock'} icon={<CheckCircle size={20} />} />
            <InfoTooltip text={VIEW_ONLY ? "DWS wines that also have stock in the producer's warehouse. If a wine sells through DWS but shows 0 warehouse stock, it may need restocking." : "DWS wines that also have stock in Moppity's warehouse. If a wine sells through DWS but shows 0 warehouse stock, it may need restocking."} className="absolute top-3 right-3" />
          </div>
          <div className="relative bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
            <p className="text-[#505052] text-sm font-medium" style={{ fontFamily: 'Inter, sans-serif' }}>Unmapped Codes</p>
            <p className="text-2xl font-semibold mt-1" style={{ fontFamily: 'Cardo, serif', color: kpis.unmapped_skus > 0 ? '#B54708' : '#1B7A3D' }}>
              {kpis.unmapped_skus}
            </p>
            <p className="text-[#505052]/70 text-xs mt-2" style={{ fontFamily: 'Inter, sans-serif' }}>SKUs without DWS code mapping</p>
            <InfoTooltip text={VIEW_ONLY ? "Wines sold through DWS that don't have a DWS↔internal code mapping yet. These can't be reconciled until mapped. Check the Unmapped tab for details." : "Wines sold through DWS that don't have a DWS↔Moppity code mapping yet. These can't be reconciled until mapped. Check the Unmapped tab for details."} className="absolute top-3 right-3" />
          </div>
        </div>

        {/* DWS Consignment explanation */}
        <InfoBanner
          title="DWS Consignment Model"
          text={VIEW_ONLY
            ? 'DWS holds the wine on consignment — stock stays producer-owned until sold to the end customer. DWS uses their own SKU codes (e.g. MOLKSH21F), which need mapping to internal codes for reconciliation.'
            : 'DWS holds Moppity wine on consignment — stock stays Moppity-owned until sold to the end customer. DWS uses their own SKU codes (e.g. MOLKSH21F), which need mapping to Moppity codes for reconciliation.'}
        />

        {/* Monthly Summary */}
        {monthly_summary.length > 0 && (
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-4 shadow-sm">
            <h2 className="text-sm font-semibold text-[#1F1F1F] mb-3" style={{ fontFamily: 'Cardo, serif' }}>DWS Monthly Activity</h2>
            <div className={`grid gap-3 ${monthly_summary.length <= 3 ? 'grid-cols-3' : monthly_summary.length <= 4 ? 'grid-cols-4' : monthly_summary.length <= 5 ? 'grid-cols-5' : 'grid-cols-6'}`}>
              {monthly_summary.map(m => (
                <div key={m.month} className="text-center border border-[#F3F4F6] rounded-lg p-3">
                  <p className="text-xs font-medium text-[#1F1F1F]">{m.month}</p>
                  <p className="text-sm font-semibold text-[#931220] mt-1">{fmt(m.revenue)}</p>
                  <p className="text-[10px] text-[#505052]">{m.cases.toFixed(0)} cases</p>
                  <p className="text-[10px] text-[#505052]">{m.skus_sold} SKUs · {m.customers} customers</p>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Tabs + Search */}
        <div className="flex items-center justify-between">
          <div className="flex gap-1 bg-[#F3F4F6] rounded-lg p-1">
            {([
              { key: 'all' as Tab, label: `All Items (${data.inventory.length})` },
              { key: 'with_stock' as Tab, label: `With Stock (${data.inventory.filter(i => i.mv_stock > 0).length})` },
              { key: 'unmapped' as Tab, label: `Unmapped (${unmapped.length})` },
            ]).map(t => (
              <button
                key={t.key}
                onClick={() => setTab(t.key)}
                className={`px-3 py-1.5 text-xs rounded-md transition-colors ${
                  tab === t.key ? 'bg-white text-[#1F1F1F] shadow-sm font-medium' : 'text-[#505052] hover:text-[#1F1F1F]'
                }`}
              >
                {t.label}
              </button>
            ))}
          </div>
          <div className="relative h-full">
            <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#D8D9DA]" />
            <input
              type="text"
              placeholder="Search..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="pl-8 pr-3 py-1.5 text-xs border border-[#D8D9DA] rounded-lg w-48"
            />
          </div>
        </div>

        {/* Main Table */}
        {tab !== 'unmapped' ? (
          <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-x-auto">
            <table className="w-full text-xs" style={{ fontFamily: 'Inter, sans-serif' }}>
              <thead>
                <tr className="border-b border-[#F3F4F6] text-[#505052]">
                  <th className="text-left px-4 py-3 font-medium">Wine</th>
                  <th className="text-left px-4 py-3 font-medium">MV Code <InfoTooltip text={VIEW_ONLY ? 'Internal SKU code from Vinsight.' : 'Moppity Vineyards internal SKU code from Vinsight.'} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-left px-4 py-3 font-medium">DWS Code <InfoTooltip text={VIEW_ONLY ? 'DWS warehouse SKU code. Different format from the internal codes — linked via the DWS code mapping.' : 'DWS warehouse SKU code. Different format from Moppity codes — linked via the DWS code mapping.'} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-right px-4 py-3 font-medium">MV Stock <InfoTooltip text={VIEW_ONLY ? 'Cases in own warehouse (Vinsight inventory). This is stock available to send to DWS.' : 'Cases in Moppity warehouse (Vinsight inventory). This is stock available to send to DWS.'} size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-right px-4 py-3 font-medium">DWS SOH <InfoTooltip text="DWS stock-on-hand — cases currently held at DWS on consignment. Sourced from Vinsight stock items, keyed by the DWS warehouse code." size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-right px-4 py-3 font-medium">DWS Sales (3m) <InfoTooltip text="Cases sold through DWS in the last 3 months." size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-right px-4 py-3 font-medium">DWS Rev (3m) <InfoTooltip text="Revenue from DWS sell-through in the last 3 months." size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-right px-4 py-3 font-medium">Cover <InfoTooltip text="Months of DWS stock cover based on 3-month sales velocity. Red = under 3 months." size={10} className="inline-flex ml-0.5 align-middle" /></th>
                  <th className="text-right px-4 py-3 font-medium">Last Sale</th>
                  <th className="text-center px-4 py-3 font-medium">Status <InfoTooltip text="Active = selling in last 3 months. Stale = has stock but no recent sales. No Map = DWS code not linked. No Stock = mapped but 0 warehouse stock." size={10} className="inline-flex ml-0.5 align-middle" /></th>
                </tr>
              </thead>
              <tbody>
                {filteredInventory.slice(0, 50).map(item => {
                  const hasMapping = !!item.dws_codes;
                  const hasStock = item.mv_stock > 0;
                  const isActive = item.dws_qty_3m > 0;
                  // Compute cover months client-side: MV stock / monthly DWS velocity
                  const monthlyVelocity = item.dws_qty_3m / 3;
                  const coverMonths = monthlyVelocity > 0 ? item.mv_stock / monthlyVelocity : null;
                  return (
                    <tr key={item.canonical_sku_id} className="border-b border-[#F3F4F6] hover:bg-[#FAF9F7] transition-colors">
                      <td className="px-4 py-3">
                        <a href={`/wines?canonical_sku_id=${item.canonical_sku_id}`} className="font-medium text-[#1F1F1F] hover:text-[#931220] transition-colors">
                          {item.sku_name}
                        </a>
                      </td>
                      <td className="px-4 py-3 font-mono text-[#505052]">{item.mv_codes || '—'}</td>
                      <td className="px-4 py-3 font-mono text-[#505052]">{item.dws_codes || <span className="text-[#B54708]">—</span>}</td>
                      <td className="text-right px-4 py-3 text-[#1F1F1F]">{hasStock ? item.mv_stock.toFixed(0) : '—'}</td>
                      <td className="text-right px-4 py-3 text-[#1F1F1F]">{item.dws_soh && item.dws_soh > 0 ? item.dws_soh.toFixed(0) : '—'}</td>
                      <td className="text-right px-4 py-3 text-[#1F1F1F]">{item.dws_qty_3m > 0 ? item.dws_qty_3m.toFixed(0) : '—'}</td>
                      <td className="text-right px-4 py-3 text-[#505052]">{item.dws_revenue_3m > 0 ? fmt(item.dws_revenue_3m) : '—'}</td>
                      <td className="text-right px-4 py-3">
                        {coverMonths ? (
                          <span className={`text-xs ${coverMonths < 3 ? 'text-[#B42318]' : coverMonths < 6 ? 'text-[#B54708]' : 'text-[#1B7A3D]'}`}>
                            {coverMonths.toFixed(1)}mo
                          </span>
                        ) : <span className="text-[#505052]">—</span>}
                      </td>
                      <td className="text-right px-4 py-3 text-[#505052]">
                        {item.last_sale_date
                          ? new Date(item.last_sale_date).toLocaleDateString('en-AU', { month: 'short', year: '2-digit' })
                          : '—'}
                      </td>
                      <td className="text-center px-4 py-3">
                        {!hasMapping ? (
                          <Badge variant="warning">No Map</Badge>
                        ) : !hasStock ? (
                          <Badge variant="neutral">No Stock</Badge>
                        ) : isActive ? (
                          <Badge variant="success">Active</Badge>
                        ) : (
                          <Badge variant="neutral">Stale</Badge>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {filteredInventory.length > 50 && (
              <div className="p-3 text-center border-t border-[#F3F4F6]">
                <span className="text-xs text-[#505052]">Showing 50 of {filteredInventory.length}</span>
              </div>
            )}
          </div>
        ) : (
          /* Unmapped Tab */
          <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm">
            <div className="p-4 border-b border-[#F3F4F6]">
              <div className="flex items-center gap-2">
                <AlertTriangle size={16} className="text-[#B54708]" />
                <p className="text-xs text-[#505052]">
                  These wines are sold via DWS but have no DWS code mapping in the system.
                  DWS uses different SKU codes (e.g. MOLKSH22F) than {VIEW_ONLY ? 'the internal codes' : 'Moppity'} (MVLKSHZB22).
                </p>
              </div>
            </div>
            <table className="w-full text-xs" style={{ fontFamily: 'Inter, sans-serif' }}>
              <thead>
                <tr className="border-b border-[#F3F4F6] text-[#505052]">
                  <th className="text-left px-4 py-3 font-medium">Wine</th>
                  <th className="text-left px-4 py-3 font-medium">Current Code</th>
                  <th className="text-right px-4 py-3 font-medium">Total Cases</th>
                  <th className="text-right px-4 py-3 font-medium">Total Revenue</th>
                  <th className="text-right px-4 py-3 font-medium">Last Sale</th>
                </tr>
              </thead>
              <tbody>
                {unmapped.map(item => (
                  <tr key={item.sku_id} className="border-b border-[#F3F4F6] hover:bg-[#FAF9F7]">
                    <td className="px-4 py-3">
                      <a href={`/wines?sku_id=${item.sku_id}`} className="font-medium text-[#1F1F1F] hover:text-[#931220]">
                        {item.item_description}
                      </a>
                      <div className="text-[10px] text-[#505052] mt-0.5">
                        {item.variety}{item.vintage ? ` · ${item.vintage}` : ''}
                      </div>
                    </td>
                    <td className="px-4 py-3 font-mono text-[#505052]">{item.sku_code}</td>
                    <td className="text-right px-4 py-3 text-[#1F1F1F]">{item.total_qty.toFixed(0)}</td>
                    <td className="text-right px-4 py-3 text-[#505052]">{fmt(item.total_revenue)}</td>
                    <td className="text-right px-4 py-3 text-[#505052]">
                      {item.last_sale_date
                        ? new Date(item.last_sale_date).toLocaleDateString('en-AU', { month: 'short', year: '2-digit' })
                        : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </AppLayout>
  );
}

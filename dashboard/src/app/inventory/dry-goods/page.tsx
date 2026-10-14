'use client';

// Phase R / BUG-149: Vinsight dry-goods surface (corks, cartons, labels, capsules).
// The owner Q11 / Q14 — these items still ship with Moppity's wines but BUG-91
// strips them from `sku`/`sales_transaction`. They need a home, and this is it.

import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MetricCard from '@/components/MetricCard';
import Badge from '@/components/Badge';
import InfoTooltip from '@/components/InfoTooltip';
import { Package, Search, Download, ArrowLeft } from 'lucide-react';

interface DryGoodRow {
  stock_item_code: string;
  description: string;
  category: string;
  units_in_stock: number;
  uom: string;
  standard_cost: number;
  stock_value: number;
}

interface CategoryStat {
  category: string;
  line_items: number;
  units: number;
  value: number;
}

interface DryGoodsResponse {
  kpis: {
    line_items: number;
    in_stock_items: number;
    total_units: number;
    total_value: number;
  };
  categories: CategoryStat[];
  rows: DryGoodRow[];
}

const font = { fontFamily: 'Inter, sans-serif' };
const headingFont = { fontFamily: 'Cardo, serif' };

const categoryBadge: Record<string, 'neutral' | 'success' | 'warning' | 'info' | 'error'> = {
  cork: 'info',
  capsule: 'neutral',
  label: 'success',
  carton: 'warning',
  bottle: 'neutral',
  other: 'neutral',
};

function fmtValue(n: number): string {
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `$${(n / 1_000).toFixed(1)}K`;
  return `$${n.toFixed(0)}`;
}

function downloadDryGoodsCsv(rows: DryGoodRow[]) {
  const header = ['stock_item_code', 'description', 'category', 'units_in_stock', 'uom', 'standard_cost', 'stock_value'];
  const escape = (val: string | number | null | undefined) => {
    if (val == null) return '';
    const s = String(val);
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [header.join(',')];
  for (const r of rows) {
    lines.push([r.stock_item_code, r.description, r.category, r.units_in_stock, r.uom, r.standard_cost.toFixed(2), r.stock_value.toFixed(2)].map(escape).join(','));
  }
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `dry-goods-${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

export default function DryGoodsPage() {
  const [data, setData] = useState<DryGoodsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState<string>('all');
  const [hideZeroStock, setHideZeroStock] = useState(true);

  useEffect(() => {
    apiGet('/api/inventory/dry-goods')
      .then(async r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((d: DryGoodsResponse) => {
        setData(d);
        setLoading(false);
      })
      .catch(err => {
        setError(err instanceof Error ? err.message : 'Failed to load dry-goods data');
        setLoading(false);
      });
  }, []);

  const filteredRows = useMemo<DryGoodRow[]>(() => {
    if (!data) return [];
    const needle = search.trim().toLowerCase();
    return data.rows.filter(r => {
      if (hideZeroStock && r.units_in_stock <= 0) return false;
      if (categoryFilter !== 'all' && r.category !== categoryFilter) return false;
      if (needle.length >= 2) {
        if (!r.stock_item_code.toLowerCase().includes(needle) && !r.description.toLowerCase().includes(needle)) return false;
      }
      return true;
    });
  }, [data, search, categoryFilter, hideZeroStock]);

  return (
    <AppLayout>
      <div className="p-6 space-y-6">
        {/* Header */}
        <div>
          <Link
            href="/inventory"
            className="text-xs text-[#8A8A8D] hover:text-[#505052] inline-flex items-center gap-1 mb-2"
            style={font}
          >
            <ArrowLeft size={12} /> Back to Inventory
          </Link>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-2xl text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                <Package size={22} className="text-[#931220]" />
                Dry Goods Inventory
                <InfoTooltip
                  size={11}
                  text="Vinsight stock items that are not packaged wine and not bulk wine — corks, cartons, labels, capsules. These items are excluded from the wine SKU table, so this is the only place they appear. Category is inferred from code and description."
                />
              </h1>
              <p className="text-sm text-[#8A8A8D] mt-1" style={font}>
                Corks, cartons, labels, capsules — sourced from Vinsight.
              </p>
            </div>
            <button
              onClick={() => downloadDryGoodsCsv(filteredRows)}
              disabled={filteredRows.length === 0}
              className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors disabled:opacity-50"
              style={font}
              title="Export the currently filtered view"
            >
              <Download size={14} />
              Export CSV
            </button>
          </div>
        </div>

        {error && (
          <div className="bg-[#FEF3F2] border border-[#FECACA] rounded-lg px-4 py-3 text-[#B42318] text-sm" style={font}>
            {error}
          </div>
        )}

        {/* KPIs */}
        <div className="grid grid-cols-4 gap-4">
          <MetricCard
            label="Line Items"
            value={loading ? '—' : String(data?.kpis.line_items ?? 0)}
            subtitle={loading ? '' : `${data?.kpis.in_stock_items ?? 0} in stock`}
          />
          <MetricCard
            label="Units on Hand"
            value={loading ? '—' : (data?.kpis.total_units ?? 0).toLocaleString()}
          />
          <MetricCard
            label="Total Stock Value"
            value={loading ? '—' : fmtValue(data?.kpis.total_value ?? 0)}
            subtitle="at Vinsight StandardCost"
          />
          <MetricCard
            label="Categories"
            value={loading ? '—' : String(data?.categories.length ?? 0)}
          />
        </div>

        {/* Category breakdown chips */}
        {!loading && data && data.categories.length > 0 && (
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-[#8A8A8D]" style={font}>Filter by category:</span>
            <button
              onClick={() => setCategoryFilter('all')}
              className={`text-xs px-2.5 py-1 rounded-full border transition-colors ${
                categoryFilter === 'all'
                  ? 'border-[#931220] text-[#931220] bg-[#931220]/5'
                  : 'border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7]'
              }`}
              style={font}
            >
              All
            </button>
            {data.categories.map(c => (
              <button
                key={c.category}
                onClick={() => setCategoryFilter(c.category)}
                className={`text-xs px-2.5 py-1 rounded-full border transition-colors ${
                  categoryFilter === c.category
                    ? 'border-[#931220] text-[#931220] bg-[#931220]/5'
                    : 'border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7]'
                }`}
                style={font}
              >
                {c.category} · {c.line_items} · {fmtValue(c.value)}
              </button>
            ))}
          </div>
        )}

        {/* Table */}
        <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
          <div className="p-4 border-b border-[#EBEBEC] flex items-center justify-between gap-4">
            <div className="relative flex-1 max-w-md">
              <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#8A8A8D]" />
              <input
                type="text"
                value={search}
                onChange={e => setSearch(e.target.value)}
                placeholder="Search code or description..."
                className="pl-9 pr-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220] w-full"
                style={font}
              />
            </div>
            <label className="text-xs text-[#505052] flex items-center gap-2 cursor-pointer" style={font}>
              <input
                type="checkbox"
                checked={hideZeroStock}
                onChange={e => setHideZeroStock(e.target.checked)}
                className="accent-[#931220]"
              />
              Hide zero-stock rows
            </label>
            <div className="text-xs text-[#8A8A8D]" style={font}>
              {filteredRows.length} row{filteredRows.length === 1 ? '' : 's'}
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs" style={font}>
              <thead>
                <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                  <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Stock Item Code</th>
                  <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Description</th>
                  <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Category</th>
                  <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Units</th>
                  <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">UOM</th>
                  <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Std Cost</th>
                  <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">Stock Value</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <tr>
                    <td colSpan={7} className="px-5 py-10 text-center text-[#8A8A8D]">Loading dry-goods inventory...</td>
                  </tr>
                ) : filteredRows.length === 0 ? (
                  <tr>
                    <td colSpan={7} className="px-5 py-10 text-center text-[#8A8A8D]">
                      {search || categoryFilter !== 'all' || hideZeroStock ? 'No rows match the current filters.' : 'No dry-goods rows found in Vinsight staging.'}
                    </td>
                  </tr>
                ) : (
                  filteredRows.map(r => (
                    <tr key={r.stock_item_code} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                      <td className="px-5 py-2 text-[#1F1F1F] font-mono font-medium">{r.stock_item_code || '—'}</td>
                      <td className="px-5 py-2 text-[#1F1F1F]">{r.description || '—'}</td>
                      <td className="px-5 py-2">
                        <Badge variant={categoryBadge[r.category] || 'neutral'}>{r.category}</Badge>
                      </td>
                      <td className="px-5 py-2 text-[#1F1F1F] text-right font-mono">{r.units_in_stock.toLocaleString(undefined, { maximumFractionDigits: 2 })}</td>
                      <td className="px-5 py-2 text-[#505052]">{r.uom || '—'}</td>
                      <td className="px-5 py-2 text-[#505052] text-right font-mono">{r.standard_cost > 0 ? `$${r.standard_cost.toFixed(2)}` : '—'}</td>
                      <td className="px-5 py-2 text-[#1F1F1F] text-right font-mono">{r.stock_value > 0 ? fmtValue(r.stock_value) : '—'}</td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>

          <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC]">
            <p className="text-[11px] text-[#8A8A8D]" style={font}>
              <strong>Read-only.</strong> Source: Vinsight stock items that are not packaged wine and not
              bulk wine. These items are excluded from the wine SKU table. Category is inferred from the
              stock item code and description — reclassification will be available in a later release.
            </p>
          </div>
        </div>
      </div>
    </AppLayout>
  );
}

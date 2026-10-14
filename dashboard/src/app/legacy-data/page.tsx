'use client';

import { useEffect, useRef, useState, useCallback, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import MonthPicker from '@/components/MonthPicker';
import { Download, ChevronDown, Search, X, Printer } from 'lucide-react';

interface Summary {
  total_rows: number;
  total_revenue: number;
  total_cases: number;
  avg_per_case: number;
}

interface MonthlyRow {
  month_key: string;
  cal_month: string;
  rows: number;
  revenue: number;
  cases: number;
}

interface PivotRow {
  name: string;
  rows: number;
  revenue: number;
  cases: number;
}

interface Transaction {
  upload_id: number;
  transaction_date: string;
  cal_month: string;
  customer_name: string;
  territory: string;
  warehouse: string;
  channel: string;
  sku: string;
  sku_vintage: string;
  item_code: string;
  item_description: string;
  invoice_no: string;
  qty: number;
  revenue: number;
  net_revenue: number;
  discount: number;
  rebate: number;
  fee: number;
  cogs: number;
  gp_pct: string;
  source_system: string;
  source_ref: string;
}

interface LegacyData {
  summary: Summary;
  monthly: MonthlyRow[];
  pivot: PivotRow[];
  transactions: {
    data: Transaction[];
    total: number;
    page: number;
    pages: number;
    limit: number;
  };
  vintages: { item_code: string; vintage?: string; rows: number; revenue: number; cases: number }[];
  reps: string[];
}

const fmt = (n: number) => n >= 1000000 ? `$${(n/1000000).toFixed(2)}M` : n >= 1000 ? `$${Math.round(n).toLocaleString()}` : `$${n.toFixed(2)}`;
const fmtK = (n: number) => n >= 1000 ? `${(n/1000).toFixed(1)}K` : n.toFixed(0);
const fmtNum = (n: number) => Math.round(n).toLocaleString();

const WH_COLORS: Record<string, string> = {
  'DWS': 'text-orange-600',
  'Y & R': 'text-orange-600',
  'ALM': 'text-purple-600',
  'Direct': 'text-green-600',
  'ILG': 'text-gray-400',
};

const CHANNEL_OPTIONS = ['ON PREMISE', 'OFF PREMISE', 'WHOLESALE', 'DIRECT', 'HYBRID'];

type PivotType = 'territory' | 'sku' | 'customer';

export default function LegacyDataPageWrapper() {
  return (
    <Suspense fallback={<AppLayout><div className="p-8 text-center text-[#707070]">Loading...</div></AppLayout>}>
      <LegacyDataPage />
    </Suspense>
  );
}

function LegacyDataPage() {
  const searchParams = useSearchParams();

  // Filters
  const [pivotType, setPivotType] = useState<PivotType>((searchParams.get('type') as PivotType) || 'territory');
  const [filterName, setFilterName] = useState(searchParams.get('territory') || searchParams.get('sku') || searchParams.get('customer') || '');
  const [fromMonth, setFromMonth] = useState(searchParams.get('from') || '2025-02');
  const [toMonth, setToMonth] = useState(searchParams.get('to') || '2026-02');
  const [warehouse, setWarehouse] = useState(searchParams.get('warehouse') || '');
  const [channel, setChannel] = useState(searchParams.get('channel') || '');
  const [rep, setRep] = useState(searchParams.get('rep') || '');
  const [searchText, setSearchText] = useState(searchParams.get('search') || '');
  const [page, setPage] = useState(1);
  // BUG-12: ref to Raw Transactions heading so pagination clicks scroll it
  // into view (prevents user getting lost when clicking Next on page 7+).
  const rawTransactionsRef = useRef<HTMLHeadingElement>(null);
  const scrollToRawTransactions = useCallback(() => {
    rawTransactionsRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }, []);
  // BUG-09/BUG-10: upload_id range filter (from post-import confirmation screen)
  const uploadIdMin = searchParams.get('upload_id_min');
  const uploadIdMax = searchParams.get('upload_id_max');
  const hasUploadIdFilter = !!(uploadIdMin && uploadIdMax);

  // Data
  const [data, setData] = useState<LegacyData | null>(null);
  const [loading, setLoading] = useState(true);
  const [expandedSku, setExpandedSku] = useState<string | null>(null);
  const [vintageData, setVintageData] = useState<Record<string, Transaction[]>>({});

  // Set initial type from URL params
  useEffect(() => {
    if (searchParams.get('territory')) {
      setPivotType('territory');
      setFilterName(searchParams.get('territory') || '');
    } else if (searchParams.get('sku')) {
      setPivotType('sku');
      setFilterName(searchParams.get('sku') || '');
    } else if (searchParams.get('customer')) {
      setPivotType('customer');
      setFilterName(searchParams.get('customer') || '');
    }
  }, [searchParams]);

  const fetchData = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams({
        type: pivotType,
        page: String(page),
        limit: '50',
      });
      // When upload_id filter is present, send it INSTEAD of date range — the API
      // skips period bounds so rows outside the default window are visible.
      if (hasUploadIdFilter) {
        params.set('upload_id_min', uploadIdMin!);
        params.set('upload_id_max', uploadIdMax!);
      } else {
        params.set('from', fromMonth);
        params.set('to', toMonth);
      }
      if (filterName) params.set('name', filterName);
      if (warehouse) params.set('warehouse', warehouse);
      if (channel) params.set('channel', channel);
      if (rep) params.set('rep', rep);
      if (searchText) params.set('search', searchText);

      const res = await apiGet(`/api/legacy-data?${params.toString()}`);
      const json = await res.json();
      setData(json);
    } catch (e) {
      console.error('Failed to fetch legacy data:', e);
    } finally {
      setLoading(false);
    }
  }, [pivotType, filterName, fromMonth, toMonth, warehouse, channel, rep, searchText, page, hasUploadIdFilter, uploadIdMin, uploadIdMax]);

  useEffect(() => { fetchData(); }, [fetchData]);

  const handlePivotRowClick = (name: string) => {
    setFilterName(filterName === name ? '' : name);
    setPage(1);
  };

  const clearFilters = () => {
    setFilterName('');
    setWarehouse('');
    setChannel('');
    setRep('');
    setSearchText('');
    setPage(1);
  };

  const exportCSV = () => {
    const params = new URLSearchParams({
      type: pivotType,
      from: fromMonth,
      to: toMonth,
      limit: '100000',
    });
    if (filterName) params.set('name', filterName);
    if (warehouse) params.set('warehouse', warehouse);
    if (channel) params.set('channel', channel);
    if (rep) params.set('rep', rep);
    if (searchText) params.set('search', searchText);
    window.open(`/api/legacy-data?${params.toString()}&format=csv`, '_blank');
  };

  return (
    <AppLayout>
      <div className="space-y-5">
        {/* BUG-09/BUG-10: Upload-scoped filter banner */}
        {hasUploadIdFilter && (
          <div className="flex items-center justify-between rounded-xl border border-amber-200 bg-amber-50 px-4 py-2.5 text-xs text-amber-900" style={{ fontFamily: 'Inter, sans-serif' }}>
            <span>
              Showing only transactions from your last import (upload_id <strong>{uploadIdMin}</strong>–<strong>{uploadIdMax}</strong>). Date range is ignored.
            </span>
            <a href="/legacy-data" className="underline hover:no-underline">Clear upload filter</a>
          </div>
        )}

        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold text-[#1F1F1F]">Combined Data</h1>
            <p className="text-xs text-[#707070] mt-0.5">All sales transactions · Jul 2019 – present</p>
          </div>
          <div className="flex items-center gap-2">
            <div className="flex items-center gap-2 flex-wrap" style={{ fontFamily: 'Inter, sans-serif' }}>
              <MonthPicker
                label="From:"
                value={fromMonth}
                onChange={val => {
                  setFromMonth(val);
                  // Guard: if new From is after existing To, clamp To up.
                  if (val && toMonth && val > toMonth) setToMonth(val);
                  setPage(1);
                }}
                minMonth="2019-07"
                maxMonth="2026-03"
                active
              />
              <MonthPicker
                label="To:"
                value={toMonth}
                onChange={val => {
                  setToMonth(val);
                  // Guard: if new To is before existing From, clamp From down.
                  if (val && fromMonth && val < fromMonth) setFromMonth(val);
                  setPage(1);
                }}
                minMonth="2019-07"
                maxMonth="2026-03"
                active
              />
            </div>
            <button onClick={exportCSV} className="flex items-center gap-1.5 px-3 py-1.5 rounded-md border border-[#D8D9DA] text-xs text-[#505052] hover:bg-gray-50">
              <Download size={14} /> Export CSV
            </button>
            {/* JC-393: Print mirrors the Access UX print button. Uses native
                window.print() so the browser dialog renders the current grid
                with active filters applied. */}
            <button
              onClick={() => window.print()}
              title="Print the current grid (browser print dialog)"
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-md border border-[#D8D9DA] text-xs text-[#505052] hover:bg-gray-50"
            >
              <Printer size={14} /> Print
            </button>
            <a
              href="/api/export/combined-data"
              download
              title="Full Access-mirror export — 50 columns × 120K rows. Unfiltered."
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-md border border-[#1F1F1F] bg-[#1F1F1F] text-xs text-white hover:bg-[#2F2F2F]"
            >
              <Download size={14} /> Download Full (50 cols)
            </a>
          </div>
        </div>

        {/* Filter bar */}
        <div className="flex items-center gap-3 bg-white rounded-xl border border-[#D8D9DA] p-3">
          <select value={warehouse} onChange={e => { setWarehouse(e.target.value); setPage(1); }}
            className="px-2.5 py-1.5 rounded-md bg-[#F3F3F3] text-xs text-[#505052] border-0 focus:outline-none"
            title="Warehouse = distribution channel (DWS / ALM / Direct)">
            <option value="">All Warehouses</option>
            <option value="DWS">DWS</option>
            <option value="ALM">ALM</option>
            <option value="Direct">Direct</option>
            <option value="ILG">ILG</option>
          </select>
          <select value={channel} onChange={e => { setChannel(e.target.value); setPage(1); }}
            className="px-2.5 py-1.5 rounded-md bg-[#F3F3F3] text-xs text-[#505052] border-0 focus:outline-none"
            title="Channel = customer attribute (on-premise / off-premise / wholesale / direct / hybrid)">
            <option value="">All Channels</option>
            {CHANNEL_OPTIONS.map(c => (
              <option key={c} value={c}>{c}</option>
            ))}
          </select>
          <select value={rep} onChange={e => { setRep(e.target.value); setPage(1); }}
            className="px-2.5 py-1.5 rounded-md bg-[#F3F3F3] text-xs text-[#505052] border-0 focus:outline-none"
            title="Sales representative">
            <option value="">All Reps</option>
            {(data?.reps || []).map(r => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
          <div className="relative flex-1">
            <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#B0B1B3]" />
            <input type="text" placeholder="Search customer, invoice, item code, SKU..."
              value={searchText} onChange={e => { setSearchText(e.target.value); setPage(1); }}
              className="w-full pl-8 pr-3 py-1.5 rounded-md bg-[#F3F3F3] text-xs text-[#1F1F1F] placeholder-[#B0B1B3] border-0 focus:outline-none focus:ring-1 focus:ring-[#931220]/30" />
          </div>
          {(filterName || warehouse || channel || rep || searchText) && (
            <button onClick={clearFilters} className="flex items-center gap-1 px-2 py-1 text-xs text-[#931220] hover:text-[#7a0e1a]">
              <X size={12} /> Clear
            </button>
          )}
        </div>

        {/* Summary strip */}
        {data && (
          <div className="flex items-center gap-6 text-xs px-1">
            <span className="text-[#1F1F1F] font-medium">
              {fmtNum(data.summary.total_rows)} transactions
            </span>
            <span className="text-[#B0B1B3]">·</span>
            <span className="text-[#1B7A3D] font-semibold">Revenue: {fmt(data.summary.total_revenue)}</span>
            <span className="text-[#B0B1B3]">·</span>
            <span className="text-[#1F1F1F] font-medium">Cases: {fmtNum(data.summary.total_cases)}</span>
            <span className="text-[#B0B1B3]">·</span>
            <span className="text-[#1F1F1F] font-medium">Avg $/case: ${data.summary.avg_per_case.toFixed(2)}</span>
            {filterName && (
              <>
                <span className="text-[#B0B1B3]">·</span>
                <span className="text-[#931220] font-medium">Filtered: {filterName}</span>
              </>
            )}
          </div>
        )}

        {/* Pivot table */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
          <div className="flex items-center gap-2 px-4 py-3 border-b border-[#E8E8E8]">
            <h2 className="text-sm font-semibold text-[#1F1F1F]">Summary</h2>
            <div className="flex gap-1 ml-3">
              {(['territory', 'sku', 'customer'] as PivotType[]).map(t => (
                <button key={t} onClick={() => { setPivotType(t); setFilterName(''); setPage(1); }}
                  className={`px-2.5 py-1 rounded-md text-[11px] font-medium transition-colors ${
                    pivotType === t ? 'bg-[#931220] text-white' : 'bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]'
                  }`}>
                  By {t.charAt(0).toUpperCase() + t.slice(1)}
                </button>
              ))}
            </div>
          </div>

          {data && (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-[#F8F8F8] border-b border-[#E8E8E8]">
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">
                      {pivotType === 'territory' ? 'Territory' : pivotType === 'sku' ? 'SKU' : 'Customer'}
                    </th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Revenue</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Cases</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Txns</th>
                  </tr>
                </thead>
                <tbody>
                  {data.pivot.map((row, i) => (
                    <tr key={i}
                      onClick={() => handlePivotRowClick(row.name)}
                      className={`border-b border-[#F0F0F0] cursor-pointer hover:bg-[#FDF2F3] transition-colors ${i % 2 === 1 ? 'bg-[#FAFAFA]' : ''}`}>
                      <td className="px-4 py-2 font-medium text-[#931220]">{row.name}</td>
                      <td className="px-4 py-2 text-right text-[#1F1F1F]">{fmt(row.revenue)}</td>
                      <td className="px-4 py-2 text-right text-[#505052]">{fmtNum(row.cases)}</td>
                      <td className="px-4 py-2 text-right text-[#505052]">{fmtNum(row.rows)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Monthly breakdown (when filtered) */}
        {data && data.monthly.length > 0 && (
          <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
            <div className="px-4 py-3 border-b border-[#E8E8E8]">
              <h2 className="text-sm font-semibold text-[#1F1F1F]">Monthly Breakdown</h2>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-[#F8F8F8] border-b border-[#E8E8E8]">
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">Month</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Revenue</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Cases</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Txns</th>
                  </tr>
                </thead>
                <tbody>
                  {data.monthly.map((row, i) => (
                    <tr key={i} className={`border-b border-[#F0F0F0] ${i % 2 === 1 ? 'bg-[#FAFAFA]' : ''}`}>
                      <td className="px-4 py-2 text-[#1F1F1F] font-medium">{row.cal_month}</td>
                      <td className="px-4 py-2 text-right text-[#1F1F1F]">{fmt(row.revenue)}</td>
                      <td className="px-4 py-2 text-right text-[#505052]">{fmtNum(row.cases)}</td>
                      <td className="px-4 py-2 text-right text-[#505052]">{fmtNum(row.rows)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* Vintage breakdown (when filtered by SKU) */}
        {data && data.vintages && data.vintages.length > 0 && (
          <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
            <div className="px-4 py-3 border-b border-[#E8E8E8]">
              <h2 className="text-sm font-semibold text-[#1F1F1F]">Vintage / Item Code Breakdown</h2>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-[#F8F8F8] border-b border-[#E8E8E8]">
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">Vintage</th>
                    <th className="text-left px-4 py-2 font-semibold text-[#505052]">Item Code</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Revenue</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Cases</th>
                    <th className="text-right px-4 py-2 font-semibold text-[#505052]">Txns</th>
                  </tr>
                </thead>
                <tbody>
                  {data.vintages.map((v, i) => (
                    <tr key={i} className={`border-b border-[#F0F0F0] ${i % 2 === 1 ? 'bg-[#FAFAFA]' : ''}`}>
                      <td className="px-4 py-2 text-[#1F1F1F] font-medium">{v.vintage || 'NV'}</td>
                      <td className="px-4 py-2 text-[#1F1F1F] font-mono text-[11px]">{v.item_code}</td>
                      <td className="px-4 py-2 text-right text-[#1F1F1F]">{fmt(v.revenue)}</td>
                      <td className="px-4 py-2 text-right text-[#505052]">{fmtNum(v.cases)}</td>
                      <td className="px-4 py-2 text-right text-[#505052]">{fmtNum(v.rows)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* Raw transactions */}
        <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm overflow-hidden">
          <div className="flex items-center gap-3 px-4 py-3 border-b border-[#E8E8E8]">
            <h2 ref={rawTransactionsRef} className="text-sm font-semibold text-[#1F1F1F] scroll-mt-20">Raw Transactions</h2>
            <span className="text-xs text-[#707070]">{data ? fmtNum(data.transactions.total) : '...'} rows</span>
            <span className="ml-auto text-[10px] text-[#B0B1B3] italic hidden sm:inline">← scroll horizontally to see all 13 columns →</span>
          </div>
          <div className="relative">
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
              <thead>
                <tr className="bg-[#F8F8F8] border-b border-[#E8E8E8]">
                  <th className="text-right px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Upload ID</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Month</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Customer</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Territory</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap" title="Warehouse = DWS / ALM / Direct">WH</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap" title="Channel = on-premise / off-premise / wholesale / direct / hybrid">Channel</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">SKU</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">SKU-Vintage</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Item Code</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Item Description</th>
                  <th className="text-right px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Qty</th>
                  <th className="text-right px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Revenue</th>
                  <th className="text-left px-3 py-2 font-semibold text-[#505052] whitespace-nowrap">Invoice #</th>
                </tr>
              </thead>
              <tbody>
                {data?.transactions.data.map((row, i) => (
                  <tr key={i} className={`border-b border-[#F0F0F0] hover:bg-[#FDF2F3] ${i % 2 === 1 ? 'bg-[#FAFAFA]' : ''}`}>
                    <td className="px-3 py-1.5 text-right text-[#707070] font-mono text-[10px] whitespace-nowrap">{row.upload_id}</td>
                    <td className="px-3 py-1.5 text-[#505052] whitespace-nowrap">{row.cal_month}</td>
                    <td className="px-3 py-1.5 text-[#1F1F1F] max-w-[200px] truncate" title={row.customer_name}>{row.customer_name}</td>
                    <td className="px-3 py-1.5 text-[#505052] whitespace-nowrap">{row.territory}</td>
                    <td className={`px-3 py-1.5 font-medium whitespace-nowrap ${WH_COLORS[row.warehouse] || 'text-[#505052]'}`}>{row.warehouse === 'Y & R' ? 'DWS' : row.warehouse}</td>
                    <td className="px-3 py-1.5 text-[#505052] whitespace-nowrap">{row.channel}</td>
                    <td className="px-3 py-1.5 text-[#505052] max-w-[160px] truncate" title={row.sku}>{row.sku}</td>
                    <td className="px-3 py-1.5 text-[#505052] max-w-[180px] truncate" title={row.sku_vintage}>{row.sku_vintage}</td>
                    <td className="px-3 py-1.5 text-[#707070] font-mono text-[10px] whitespace-nowrap">{row.item_code}</td>
                    <td className="px-3 py-1.5 text-[#505052] max-w-[200px] truncate" title={row.item_description}>{row.item_description}</td>
                    <td className="px-3 py-1.5 text-right text-[#1F1F1F]">{Number(row.qty).toFixed(2)}</td>
                    <td className="px-3 py-1.5 text-right text-[#1B7A3D] font-medium">{fmt(Number(row.revenue))}</td>
                    <td className="px-3 py-1.5 text-[#707070] whitespace-nowrap font-mono text-[10px]">{row.invoice_no}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            </div>
            {/* Right-edge gradient fade to indicate horizontal scroll */}
            <div className="pointer-events-none absolute top-0 right-0 h-full w-10 bg-gradient-to-l from-white to-transparent" />
          </div>

          {/* Pagination — BUG-12: sliding window + scroll-to-top on change */}
          {data && data.transactions.pages > 1 && (() => {
            const totalPages = data.transactions.pages;
            const curr = data.transactions.page;
            const windowSize = 5;
            // Compute a sliding window of up to 5 page numbers centered on curr.
            let winStart = Math.max(1, curr - Math.floor(windowSize / 2));
            const winEnd = Math.min(totalPages, winStart + windowSize - 1);
            winStart = Math.max(1, winEnd - windowSize + 1);
            const windowPages = Array.from({ length: winEnd - winStart + 1 }, (_, i) => winStart + i);
            const goto = (p: number) => {
              setPage(p);
              scrollToRawTransactions();
            };
            return (
              <div className="flex items-center justify-between px-4 py-2.5 border-t border-[#E8E8E8] text-xs text-[#707070]">
                <span>Page {curr} of {totalPages}</span>
                <div className="flex gap-1 items-center">
                  <button onClick={() => goto(Math.max(1, curr - 1))} disabled={curr <= 1}
                    className="px-2.5 py-1 rounded bg-[#F3F3F3] text-[#505052] disabled:text-[#B0B1B3] disabled:cursor-not-allowed hover:bg-[#E8E8E8]">
                    Prev
                  </button>
                  {winStart > 1 && (
                    <>
                      <button onClick={() => goto(1)}
                        className="px-2 py-1 rounded min-w-[28px] bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]">1</button>
                      {winStart > 2 && <span className="px-1 py-1">…</span>}
                    </>
                  )}
                  {windowPages.map(p => (
                    <button key={p} onClick={() => goto(p)}
                      className={`px-2 py-1 rounded min-w-[28px] ${curr === p ? 'bg-[#931220] text-white' : 'bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]'}`}>
                      {p}
                    </button>
                  ))}
                  {winEnd < totalPages && (
                    <>
                      {winEnd < totalPages - 1 && <span className="px-1 py-1">…</span>}
                      <button onClick={() => goto(totalPages)}
                        className="px-2 py-1 rounded min-w-[28px] bg-[#F3F3F3] text-[#505052] hover:bg-[#E8E8E8]">{totalPages}</button>
                    </>
                  )}
                  <button onClick={() => goto(Math.min(totalPages, curr + 1))} disabled={curr >= totalPages}
                    className="px-2.5 py-1 rounded bg-[#F3F3F3] text-[#505052] disabled:text-[#B0B1B3] disabled:cursor-not-allowed hover:bg-[#E8E8E8]">
                    Next
                  </button>
                </div>
                <span>50 rows per page</span>
              </div>
            );
          })()}
        </div>
      </div>
    </AppLayout>
  );
}

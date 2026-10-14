'use client';

import { useState } from 'react';

interface TableInfo {
  table_name: string;
  row_count: number;
}

interface TableCountsProps {
  tables: TableInfo[];
  loading: boolean;
  error: string | null;
}

// Human-readable labels for core tables
const TABLE_LABELS: Record<string, string> = {
  entity: 'Entities',
  wine_range: 'Wine Ranges (VIEW)',
  channel: 'Sales Channels',
  territory: 'Territories',
  sku: 'SKUs',
  sku_code_map: 'SKU Code Mappings',
  customer: 'Customers',
  customer_code_map: 'Customer Code Mappings',
  representative: 'Sales Representatives',
  rep_territory: 'Rep-Territory Assignments',
  award: 'Awards',
  month_end_snapshot: 'Month-End Snapshots',
  sku_cogs: 'SKU COGS (Cost of Goods)',
  sales_transaction: 'Sales Transactions',
  etl_run_log: 'ETL Run Log',
  etl_dead_letter: 'ETL Dead Letters',
  v_customer_with_codes: 'Customers (All System Codes)',
};

// Data source for each table
const TABLE_SOURCES: Record<string, string> = {
  sales_transaction: 'Access DB + Vinsight + DWS/ALM',
  customer: 'Access DB + Vinsight + Xero',
  sku: 'Access DB + Vinsight',
  sku_code_map: 'Access DB + Vinsight (DWS codes)',
  customer_code_map: 'Access DB (ALM/DWS/Direct) + Vinsight + Xero',
  representative: 'Access DB',
  territory: 'Access DB',
  channel: 'Seed data (DWS/ALM/Direct)',
  entity: 'Seed data (Trust/Wines Pty Ltd)',
  wine_range: 'VIEW over canonical_sku (BUG-101 / ADR-010)',
  sku_cogs: 'Access DB (tbl_Master_COGS)',
  month_end_snapshot: 'System (period close)',
  award: 'Manual entry',
  v_customer_with_codes: 'VIEW — joins customer + customer_code_map',
  rep_territory: 'Derived (representative + sales_transaction)',
  etl_run_log: 'System (auto-logged)',
  etl_dead_letter: 'System (auto-logged)',
  access_combined_data: 'Access DB — CombinedData',
  access_customers: 'Access DB — Customers',
  access_sku: 'Access DB — SKU',
  access_territory: 'Access DB — tblNewTerritory',
  access_representative: 'Access DB — Representative',
  access_channel: 'Access DB — xtblChannel',
  access_customer_groups: 'Access DB — tblCustomerGroups',
  access_group_rebate: 'Access DB — tblGroupRebate',
  access_item_description: 'Access DB — ItemDescription',
  access_master_cogs: 'Access DB — tbl_Master_COGS',
  access_stocks_on_hand: 'Access DB — tbl_StocksONHand',
};

// Table categories for sorting: Core first, then System, then Staging
const CORE_TABLE_NAMES = [
  'sales_transaction', 'customer', 'sku', 'sku_code_map', 'customer_code_map',
  'representative', 'rep_territory', 'territory', 'channel', 'entity', 'wine_range',
  'sku_cogs', 'month_end_snapshot', 'award', 'v_customer_with_codes',
];
const SYSTEM_TABLE_NAMES = ['etl_run_log', 'etl_dead_letter'];

function getTableCategory(name: string): number {
  if (CORE_TABLE_NAMES.includes(name)) return 0;
  if (SYSTEM_TABLE_NAMES.includes(name)) return 1;
  return 2; // staging / access_*
}

function getDisplayName(tableName: string): string {
  return TABLE_LABELS[tableName] || tableName.replace(/_/g, ' ');
}

export default function TableCounts({ tables, loading, error }: TableCountsProps) {
  const [showStaging, setShowStaging] = useState(false);

  if (loading) {
    return (
      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
        <h2 className="text-lg font-semibold text-slate-200 mb-4">
          Database Tables
        </h2>
        <div className="animate-pulse space-y-3">
          {[...Array(6)].map((_, i) => (
            <div key={i} className="h-8 bg-slate-700/50 rounded" />
          ))}
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="rounded-xl border border-red-500/30 bg-red-500/5 p-6">
        <h2 className="text-lg font-semibold text-slate-200 mb-2">
          Database Tables
        </h2>
        <p className="text-sm text-red-400">{error}</p>
      </div>
    );
  }

  const sorted = [...tables].sort((a, b) => {
    const catDiff = getTableCategory(a.table_name) - getTableCategory(b.table_name);
    if (catDiff !== 0) return catDiff;
    return a.table_name.localeCompare(b.table_name);
  });

  const coreTables = sorted.filter(t => getTableCategory(t.table_name) === 0);
  const systemTables = sorted.filter(t => getTableCategory(t.table_name) === 1);
  const stagingTables = sorted.filter(t => getTableCategory(t.table_name) === 2);

  const coreRows = coreTables.reduce((s, t) => s + t.row_count, 0);
  const stagingRows = stagingTables.reduce((s, t) => s + t.row_count, 0);
  const totalRows = tables.reduce((sum, t) => sum + t.row_count, 0);

  const renderTableRows = (items: TableInfo[]) =>
    items.map((t) => (
      <tr
        key={t.table_name}
        className="hover:bg-slate-700/20 transition-colors"
      >
        <td className="py-2.5 px-4">
          <div>
            <span className="text-slate-200">
              {getDisplayName(t.table_name)}
            </span>
            <span className="ml-2 text-xs text-slate-500 font-mono">
              {t.table_name}
            </span>
          </div>
        </td>
        <td className="py-2.5 px-4">
          <span className="text-xs text-slate-400">
            {TABLE_SOURCES[t.table_name] || '\u2014'}
          </span>
        </td>
        <td className="py-2.5 px-4 text-right">
          <span
            className={`font-mono ${
              t.row_count > 0
                ? 'text-emerald-400'
                : 'text-slate-500'
            }`}
          >
            {t.row_count.toLocaleString()}
          </span>
        </td>
      </tr>
    ));

  return (
    <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-lg font-semibold text-slate-200">
          Database Tables
        </h2>
        <span className="text-xs text-slate-500 bg-slate-700/50 px-3 py-1 rounded-full">
          {tables.length} tables / {totalRows.toLocaleString()} total rows
        </span>
      </div>

      <p className="text-sm text-slate-400 mb-5">
        Data from all 4 source systems (Access DB, Vinsight, Xero, Google Sheets) is
        extracted, cleaned, and unified into these core tables. The Source column shows
        where each table&apos;s data originates.
      </p>

      <div className="overflow-hidden rounded-lg border border-slate-700/30">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-slate-700/30">
              <th className="text-left py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Table
              </th>
              <th className="text-left py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Source
              </th>
              <th className="text-right py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Rows
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-700/30">
            {/* CORE TABLES */}
            <tr className="bg-slate-700/40">
              <td colSpan={3} className="py-2 px-4 text-xs font-bold text-slate-400 uppercase tracking-widest">
                CORE TABLES
                <span className="ml-2 text-emerald-400/70 normal-case tracking-normal font-normal">
                  {coreTables.length} tables, {coreRows.toLocaleString()} rows unified from all sources
                </span>
              </td>
            </tr>
            {renderTableRows(coreTables)}

            {/* SYSTEM TABLES */}
            <tr className="bg-slate-700/40">
              <td colSpan={3} className="py-2 px-4 text-xs font-bold text-slate-400 uppercase tracking-widest">
                SYSTEM TABLES
              </td>
            </tr>
            {renderTableRows(systemTables)}

            {/* STAGING TABLES - collapsible */}
            <tr className="bg-slate-700/40">
              <td colSpan={3} className="py-2 px-4">
                <button
                  onClick={() => setShowStaging(!showStaging)}
                  className="flex items-center gap-2 text-xs font-bold text-slate-500 uppercase tracking-widest hover:text-slate-300 transition-colors"
                >
                  <span className="text-[10px]">{showStaging ? '\u25BC' : '\u25B6'}</span>
                  RAW STAGING DATA
                  <span className="normal-case tracking-normal font-normal">
                    {stagingTables.length} tables, {stagingRows.toLocaleString()} rows
                    {!showStaging && ' (click to expand)'}
                  </span>
                </button>
              </td>
            </tr>
            {showStaging && renderTableRows(stagingTables)}
          </tbody>
        </table>
      </div>
    </div>
  );
}

'use client';

interface SchemaOverviewProps {
  tables: { table_name: string; row_count: number }[];
  loading: boolean;
}

interface TableEntry {
  name: string;
  description: string;
}

const CORE_TABLES: TableEntry[] = [
  { name: 'entity', description: 'Legal entities (Trust, Wines Pty Ltd)' },
  { name: 'wine_range', description: 'VIEW over canonical_sku (Lock & Key, Reserve, etc. — ADR-010)' },
  { name: 'channel', description: 'Sales channels (DWS, ALM, Direct)' },
  { name: 'sku', description: 'Wine products with vintage tracking' },
  { name: 'sku_code_map', description: 'Maps DWS/ALM codes to Moppity codes' },
  { name: 'customer', description: 'Customer master across all channels' },
  { name: 'customer_code_map', description: 'Maps external customer names' },
  { name: 'representative', description: 'Sales representatives' },
  { name: 'territory', description: 'Sales territories/regions' },
  { name: 'sales_transaction', description: '5+ years of unified sales data' },
  { name: 'sku_cogs', description: 'Cost of goods (ready for M2 margin analysis)' },
  { name: 'month_end_snapshot', description: 'Period-locked reporting snapshots' },
];

const SYSTEM_TABLES: TableEntry[] = [
  { name: 'etl_run_log', description: 'ETL sync history and errors' },
  { name: 'etl_dead_letter', description: 'Failed records preserved for review' },
];

function getRowCount(
  tables: { table_name: string; row_count: number }[],
  name: string
): number | null {
  const found = tables.find((t) => t.table_name === name);
  return found ? found.row_count : null;
}

function getStagingTables(
  tables: { table_name: string; row_count: number }[]
): { table_name: string; row_count: number }[] {
  return tables.filter(
    (t) => t.table_name.startsWith('staging_') || t.table_name.startsWith('access_')
  );
}

function SkeletonCard() {
  return (
    <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
      <div className="animate-pulse">
        <div className="h-5 bg-slate-700/50 rounded w-32 mb-5" />
        <div className="space-y-3">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="h-7 bg-slate-700/50 rounded" />
          ))}
        </div>
      </div>
    </div>
  );
}

function TableRow({
  name,
  description,
  rowCount,
}: {
  name: string;
  description: string;
  rowCount: number | null;
}) {
  return (
    <div className="flex items-baseline justify-between py-2.5 px-4 hover:bg-slate-700/20 transition-colors">
      <div className="min-w-0 flex-1 mr-4">
        <span className="text-sm text-slate-200 font-medium">{name}</span>
        <p className="text-xs text-slate-500 mt-0.5 truncate">{description}</p>
      </div>
      <span
        className={`text-sm font-mono flex-shrink-0 ${
          rowCount !== null && rowCount > 0
            ? 'text-emerald-400'
            : 'text-slate-500'
        }`}
      >
        {rowCount !== null ? rowCount.toLocaleString() : '-'}
      </span>
    </div>
  );
}

function GroupCard({
  title,
  icon,
  entries,
  tables,
}: {
  title: string;
  icon: React.ReactNode;
  entries: TableEntry[];
  tables: { table_name: string; row_count: number }[];
}) {
  const totalRows = entries.reduce((sum, entry) => {
    const count = getRowCount(tables, entry.name);
    return sum + (count ?? 0);
  }, 0);

  return (
    <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2.5">
          <span className="text-slate-400">{icon}</span>
          <h3 className="text-sm font-semibold text-slate-300 uppercase tracking-wide">
            {title}
          </h3>
        </div>
        <span className="text-xs text-slate-500 bg-slate-700/50 px-2.5 py-1 rounded-full">
          {entries.length} tables / {totalRows.toLocaleString()} rows
        </span>
      </div>
      <div className="rounded-lg border border-slate-700/30 divide-y divide-slate-700/30">
        {entries.map((entry) => (
          <TableRow
            key={entry.name}
            name={entry.name}
            description={entry.description}
            rowCount={getRowCount(tables, entry.name)}
          />
        ))}
      </div>
    </div>
  );
}

function StagingCard({
  tables,
}: {
  tables: { table_name: string; row_count: number }[];
}) {
  const stagingTables = getStagingTables(tables);
  const totalRows = stagingTables.reduce((sum, t) => sum + t.row_count, 0);

  return (
    <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2.5">
          <span className="text-slate-400">
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4" />
            </svg>
          </span>
          <h3 className="text-sm font-semibold text-slate-300 uppercase tracking-wide">
            Staging Tables
          </h3>
        </div>
        <span className="text-xs text-slate-500 bg-slate-700/50 px-2.5 py-1 rounded-full">
          {stagingTables.length} tables / {totalRows.toLocaleString()} rows
        </span>
      </div>
      {stagingTables.length > 0 ? (
        <div className="rounded-lg border border-slate-700/30 divide-y divide-slate-700/30">
          {stagingTables.map((t) => (
            <TableRow
              key={t.table_name}
              name={t.table_name}
              description="Raw data from source systems before transformation"
              rowCount={t.row_count}
            />
          ))}
        </div>
      ) : (
        <p className="text-sm text-slate-500">
          No staging tables found. They will appear after the first ETL import.
        </p>
      )}
    </div>
  );
}

export default function SchemaOverview({ tables, loading }: SchemaOverviewProps) {
  if (loading) {
    return (
      <div>
        <h2 className="text-lg font-semibold text-slate-200 mb-5">
          Database Schema
        </h2>
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <SkeletonCard />
          <SkeletonCard />
          <SkeletonCard />
        </div>
      </div>
    );
  }

  return (
    <div>
      <h2 className="text-lg font-semibold text-slate-200 mb-5">
        Database Schema
      </h2>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Core Tables */}
        <GroupCard
          title="Core Tables"
          icon={
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
            </svg>
          }
          entries={CORE_TABLES}
          tables={tables}
        />

        {/* System Tables */}
        <GroupCard
          title="System Tables"
          icon={
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
          }
          entries={SYSTEM_TABLES}
          tables={tables}
        />

        {/* Staging Tables */}
        <StagingCard tables={tables} />
      </div>

      {/* M2 Preview Callout */}
      <div className="mt-6 rounded-lg border border-amber-500/30 bg-amber-500/5 px-5 py-4">
        <div className="flex items-start gap-3">
          <span className="text-amber-400 mt-0.5 flex-shrink-0">
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
          </span>
          <div>
            <p className="text-sm font-medium text-amber-300">
              Ready for Milestone 2
            </p>
            <p className="text-xs text-amber-400/70 mt-1">
              sku_cogs table enables economic vs accounting margin analysis with configurable grape prices
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

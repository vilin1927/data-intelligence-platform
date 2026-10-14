'use client';

interface DataArchitectureProps {
  tables: { table_name: string; row_count: number }[];
  loading: boolean;
}

const SOURCE_SYSTEMS = [
  {
    name: 'Vinsight',
    description: 'Wine operations',
    detail: 'Inventory, sales orders, contacts',
    color: 'text-purple-400',
    borderColor: 'border-purple-500/30',
    bgColor: 'bg-purple-500/5',
    dotColor: 'bg-purple-400',
    glowColor: 'rgba(168, 85, 247, 0.4)',
  },
  {
    name: 'Xero',
    description: 'Accounting (2 tenants)',
    detail: 'Trust + Wines Pty Ltd financials',
    color: 'text-sky-400',
    borderColor: 'border-sky-500/30',
    bgColor: 'bg-sky-500/5',
    dotColor: 'bg-sky-400',
    glowColor: 'rgba(56, 189, 248, 0.4)',
  },
  {
    name: 'Access DB',
    description: '5yr sales history',
    detail: '140MB legacy database migrated',
    color: 'text-amber-400',
    borderColor: 'border-amber-500/30',
    bgColor: 'bg-amber-500/5',
    dotColor: 'bg-amber-400',
    glowColor: 'rgba(251, 191, 36, 0.4)',
  },
  {
    name: 'Google Sheets',
    description: 'Planning layer',
    detail: 'Scheduling, cashflow, crop data',
    color: 'text-emerald-400',
    borderColor: 'border-emerald-500/30',
    bgColor: 'bg-emerald-500/5',
    dotColor: 'bg-emerald-400',
    glowColor: 'rgba(52, 211, 153, 0.4)',
  },
];

export default function DataArchitecture({ tables, loading }: DataArchitectureProps) {
  const totalRows = tables.reduce((sum, t) => sum + t.row_count, 0);
  const tableCount = tables.length;

  return (
    <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
      <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-6">
        Data Architecture
      </h2>

      {/* Main layout: Sources -> ETL -> Unified DB */}
      <div className="grid grid-cols-1 lg:grid-cols-[1fr_auto_1fr] gap-6 items-center">

        {/* Left: Source Systems */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          {SOURCE_SYSTEMS.map((sys) => (
            <div
              key={sys.name}
              className={`rounded-lg border ${sys.borderColor} ${sys.bgColor} px-4 py-3 transition-all hover:shadow-md`}
            >
              <div className="flex items-center gap-2 mb-1">
                <span
                  className={`inline-block h-2 w-2 rounded-full ${sys.dotColor}`}
                  style={{ boxShadow: `0 0 6px ${sys.glowColor}` }}
                />
                <span className={`text-sm font-semibold ${sys.color}`}>
                  {sys.name}
                </span>
              </div>
              <p className="text-xs text-slate-400 font-medium">
                {sys.description}
              </p>
              <p className="text-xs text-slate-500 mt-0.5">
                {sys.detail}
              </p>
            </div>
          ))}
        </div>

        {/* Center: ETL Pipeline Arrow */}
        <div className="flex lg:flex-col items-center justify-center gap-2 py-2">
          {/* Horizontal on mobile, vertical on desktop */}
          <div className="hidden lg:flex flex-col items-center gap-1.5">
            <div className="w-px h-6 bg-gradient-to-b from-slate-600/0 to-slate-500" />
            <div className="px-3 py-1.5 rounded-md border border-slate-600/50 bg-slate-700/50">
              <span className="text-xs font-semibold text-slate-300 uppercase tracking-wider">
                ETL
              </span>
            </div>
            <div className="flex flex-col items-center">
              <div className="w-px h-6 bg-gradient-to-b from-slate-500 to-emerald-500/60" />
              <svg
                className="w-3 h-3 text-emerald-500/60 -mt-px"
                fill="currentColor"
                viewBox="0 0 12 12"
              >
                <path d="M6 9L1 4h10L6 9z" />
              </svg>
            </div>
          </div>

          {/* Mobile: horizontal arrow */}
          <div className="flex lg:hidden items-center gap-1.5">
            <div className="h-px w-6 bg-gradient-to-r from-slate-600/0 to-slate-500" />
            <div className="px-3 py-1.5 rounded-md border border-slate-600/50 bg-slate-700/50">
              <span className="text-xs font-semibold text-slate-300 uppercase tracking-wider">
                ETL
              </span>
            </div>
            <div className="flex items-center">
              <div className="h-px w-6 bg-gradient-to-r from-slate-500 to-emerald-500/60" />
              <svg
                className="w-3 h-3 text-emerald-500/60 -ml-px"
                fill="currentColor"
                viewBox="0 0 12 12"
              >
                <path d="M9 6L4 1v10l5-5z" />
              </svg>
            </div>
          </div>
        </div>

        {/* Right: Unified Postgres Database */}
        <div className="rounded-lg border border-emerald-500/30 bg-emerald-500/5 p-5">
          <div className="flex items-center gap-2.5 mb-4">
            <div
              className="flex items-center justify-center w-8 h-8 rounded-lg bg-emerald-500/15 border border-emerald-500/20"
            >
              <svg
                className="w-4 h-4 text-emerald-400"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                viewBox="0 0 24 24"
              >
                <ellipse cx="12" cy="5" rx="9" ry="3" />
                <path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3" />
                <path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5" />
              </svg>
            </div>
            <div>
              <h3 className="text-sm font-semibold text-emerald-400">
                PostgreSQL
              </h3>
              <p className="text-xs text-slate-500">
                Unified data warehouse
              </p>
            </div>
          </div>

          {loading ? (
            <div className="animate-pulse space-y-2.5">
              <div className="h-4 bg-slate-700/50 rounded w-32" />
              <div className="h-4 bg-slate-700/50 rounded w-24" />
            </div>
          ) : (
            <div className="space-y-2">
              <div className="flex justify-between items-baseline">
                <span className="text-xs text-slate-500">Tables</span>
                <span className="text-sm text-slate-200 font-medium font-mono">
                  {tableCount}
                </span>
              </div>
              <div className="flex justify-between items-baseline">
                <span className="text-xs text-slate-500">Total records</span>
                <span className="text-sm text-emerald-400 font-medium font-mono">
                  {totalRows.toLocaleString()}
                </span>
              </div>
              <div className="flex justify-between items-baseline">
                <span className="text-xs text-slate-500">Sources unified</span>
                <span className="text-sm text-slate-200 font-medium font-mono">
                  4
                </span>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Summary bar */}
      <div className="mt-6 rounded-lg bg-slate-700/30 border border-slate-700/40 px-4 py-3 text-center">
        {loading ? (
          <div className="animate-pulse h-4 bg-slate-700/50 rounded w-64 mx-auto" />
        ) : (
          <p className="text-sm text-slate-300">
            <span className="font-semibold text-slate-200">4 systems</span>
            <span className="text-slate-500 mx-2">&rarr;</span>
            <span className="font-semibold text-slate-200">1 database</span>
            <span className="text-slate-500 mx-2">&rarr;</span>
            <span className="font-semibold text-emerald-400">
              {totalRows.toLocaleString()} records
            </span>
            <span className="text-slate-400"> unified</span>
          </p>
        )}
      </div>
    </div>
  );
}

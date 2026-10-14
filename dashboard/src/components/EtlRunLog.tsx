'use client';

interface EtlRun {
  run_id: number;
  source: string;
  endpoint: string | null;
  status: string;
  rows_processed: number;
  rows_skipped: number;
  error_count: number;
  error_detail: string | null;
  started_at: string;
  completed_at: string | null;
}

interface EtlRunLogProps {
  runs: EtlRun[];
  loading: boolean;
  error: string | null;
}

// Source display names
const SOURCE_LABELS: Record<string, string> = {
  vinsight: 'Vinsight',
  xero_trust: 'Xero Trust',
  xero_wines: 'Xero Wines',
  sheets: 'Google Sheets',
  access_db: 'Access DB',
  dws_upload: 'DWS Upload',
  alm_upload: 'ALM Upload',
  direct_upload: 'Direct Upload',
};

const STATUS_STYLES: Record<string, string> = {
  success: 'bg-emerald-500/15 text-emerald-400 border-emerald-500/30',
  running: 'bg-blue-500/15 text-blue-400 border-blue-500/30',
  partial: 'bg-amber-500/15 text-amber-400 border-amber-500/30',
  failed: 'bg-red-500/15 text-red-400 border-red-500/30',
};

function formatTimestamp(dateStr: string): string {
  const date = new Date(dateStr);
  return date.toLocaleString('en-AU', {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
}

function formatDuration(startStr: string, endStr: string | null): string {
  if (!endStr) return 'Running...';
  const start = new Date(startStr).getTime();
  const end = new Date(endStr).getTime();
  const diffSec = Math.round((end - start) / 1000);
  if (diffSec < 60) return `${diffSec}s`;
  const mins = Math.floor(diffSec / 60);
  const secs = diffSec % 60;
  return `${mins}m ${secs}s`;
}

export default function EtlRunLog({ runs, loading, error }: EtlRunLogProps) {
  if (loading) {
    return (
      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
        <h2 className="text-lg font-semibold text-slate-200 mb-4">
          Recent ETL Runs
        </h2>
        <div className="animate-pulse space-y-3">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="h-10 bg-slate-700/50 rounded" />
          ))}
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="rounded-xl border border-red-500/30 bg-red-500/5 p-6">
        <h2 className="text-lg font-semibold text-slate-200 mb-2">
          Recent ETL Runs
        </h2>
        <p className="text-sm text-red-400">{error}</p>
      </div>
    );
  }

  if (runs.length === 0) {
    return (
      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
        <h2 className="text-lg font-semibold text-slate-200 mb-4">
          Recent ETL Runs
        </h2>
        <p className="text-sm text-slate-500">
          No ETL runs recorded yet. Runs will appear here once connectors start syncing data.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-6">
      <h2 className="text-lg font-semibold text-slate-200 mb-5">
        Recent ETL Runs
      </h2>

      <div className="overflow-hidden rounded-lg border border-slate-700/30">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-slate-700/30">
              <th className="text-left py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Source
              </th>
              <th className="text-left py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Endpoint
              </th>
              <th className="text-center py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Status
              </th>
              <th className="text-right py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Rows
              </th>
              <th className="text-right py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Duration
              </th>
              <th className="text-right py-2.5 px-4 text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Time
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-700/30">
            {runs.map((run) => (
              <tr
                key={run.run_id}
                className="hover:bg-slate-700/20 transition-colors group"
              >
                <td className="py-2.5 px-4 text-slate-200">
                  {SOURCE_LABELS[run.source] || run.source}
                </td>
                <td className="py-2.5 px-4 text-slate-400 font-mono text-xs">
                  {run.endpoint || '-'}
                </td>
                <td className="py-2.5 px-4 text-center">
                  <span
                    className={`inline-block px-2.5 py-0.5 rounded-full text-xs font-medium border ${
                      STATUS_STYLES[run.status] ||
                      'bg-slate-500/15 text-slate-400 border-slate-500/30'
                    }`}
                  >
                    {run.status}
                  </span>
                </td>
                <td className="py-2.5 px-4 text-right font-mono text-slate-300">
                  {run.rows_processed.toLocaleString()}
                  {run.rows_skipped > 0 && (
                    <span className="text-amber-400 text-xs ml-1">
                      ({run.rows_skipped} skipped)
                    </span>
                  )}
                </td>
                <td className="py-2.5 px-4 text-right text-slate-400 text-xs">
                  {formatDuration(run.started_at, run.completed_at)}
                </td>
                <td className="py-2.5 px-4 text-right text-slate-400 text-xs">
                  {formatTimestamp(run.started_at)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {runs.some((r) => r.error_detail) && (
        <div className="mt-4 space-y-2">
          <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
            Error Details
          </h3>
          {runs
            .filter((r) => r.error_detail)
            .map((r) => (
              <div
                key={r.run_id}
                className="rounded-md bg-red-500/10 border border-red-500/20 px-3 py-2"
              >
                <span className="text-xs text-red-300 font-medium">
                  [{SOURCE_LABELS[r.source] || r.source}] Run #{r.run_id}:
                </span>
                <p className="text-xs text-red-300/80 mt-0.5">
                  {r.error_detail}
                </p>
              </div>
            ))}
        </div>
      )}
    </div>
  );
}

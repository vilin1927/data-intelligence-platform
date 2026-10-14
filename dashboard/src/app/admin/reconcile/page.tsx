/**
 * /admin/reconcile — Post-import reconciliation report.
 *
 * Lists every upload batch and its per-dimension reconcile status.
 * For each batch shows:
 *   - Channel, file name, period, started_at
 *   - Status counts (match / mismatch / unknown)
 *
 * Server component — queries DB directly via shared pool (no HTTP hop).
 */

import getPool from '@/lib/db';

export const dynamic = 'force-dynamic';

interface BatchSummary {
  upload_batch_id: number;
  channel: string;
  file_name: string;
  period_label: string | null;
  started_at: string;
  ended_at: string | null;
  status: string;
  row_count_seen: number | null;
  row_count_inserted: number | null;
  row_count_duplicates: number | null;
  status_counts: Record<string, number>;
}

async function fetchBatches(): Promise<BatchSummary[]> {
  try {
    const client = await getPool().connect();
    try {
      const res = await client.query(
        `SELECT b.upload_batch_id, b.channel, b.file_name, b.period_label,
                b.started_at, b.ended_at, b.status,
                b.row_count_seen, b.row_count_inserted, b.row_count_duplicates,
                COALESCE(jsonb_object_agg(r.status, r.cnt) FILTER (WHERE r.status IS NOT NULL),
                          '{}'::jsonb) AS status_counts
           FROM upload_batch b
      LEFT JOIN (SELECT upload_batch_id, status, COUNT(*) AS cnt
                   FROM upload_batch_reconcile
                  GROUP BY upload_batch_id, status) r
             ON r.upload_batch_id = b.upload_batch_id
          GROUP BY b.upload_batch_id
          ORDER BY b.upload_batch_id DESC
          LIMIT 200`,
      );
      return res.rows as BatchSummary[];
    } finally {
      client.release();
    }
  } catch (err) {
    console.error('[reconcile] fetchBatches failed:', err);
    return [];
  }
}

export default async function ReconcilePage() {
  const batches = await fetchBatches();
  return (
    <main style={{ padding: 16 }}>
      <h1>Post-import Reconciliation</h1>
      <p>
        Compare each uploaded file against the canonical sales totals. Every
        upload batch is grouped by SKU, customer, and territory, then matched
        to the live sales totals. Mismatches surface immediately
        (tolerance ± $1 / unit).
      </p>
      <table border={1} cellPadding={6} style={{ borderCollapse: 'collapse', marginTop: 16 }}>
        <thead>
          <tr>
            <th>#</th>
            <th>Warehouse</th>
            <th>File</th>
            <th>Period</th>
            <th>Started</th>
            <th>Status</th>
            <th>Rows seen</th>
            <th>Inserted</th>
            <th>Duplicates</th>
            <th>Match / Mismatch / Unknown</th>
          </tr>
        </thead>
        <tbody>
          {batches.length === 0 && (
            <tr>
              <td colSpan={10} style={{ textAlign: 'center' }}>
                No upload batches yet. Upload a file via{' '}
                <a href="/admin/upload">/admin/upload</a>.
              </td>
            </tr>
          )}
          {batches.map((b) => {
            const sc = b.status_counts ?? {};
            return (
              <tr key={b.upload_batch_id}>
                <td>{b.upload_batch_id}</td>
                <td>{b.channel.toUpperCase()}</td>
                <td>
                  <code>{b.file_name}</code>
                </td>
                <td>{b.period_label ?? '—'}</td>
                <td>{b.started_at ? new Date(b.started_at).toISOString().replace('T', ' ').slice(0, 19) : '—'}</td>
                <td>
                  <strong>{b.status}</strong>
                </td>
                <td>{b.row_count_seen ?? '—'}</td>
                <td>{b.row_count_inserted ?? '—'}</td>
                <td>{b.row_count_duplicates ?? '—'}</td>
                <td>
                  {sc.match ?? 0} / {sc.mismatch ?? 0} / {sc.unknown ?? 0}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </main>
  );
}

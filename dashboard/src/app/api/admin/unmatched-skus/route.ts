export const dynamic = 'force-dynamic';

/**
 * GET /api/admin/unmatched-skus
 *
 * B6b — JC-107 / JC-108 / JC-120: returns SKUs that have sales activity
 * but no canonical_sku_id link, with top-3 fuzzy suggestions against the
 * canonical_sku pool. Mirrors /api/admin/unmatched-customers (CLARIFY-12).
 *
 * For each unmatched SKU:
 *   - Revenue + transaction count from sales_transaction_normalized
 *   - Existing review status from sku_match_review (most recent)
 *   - Top-3 canonical_sku suggestions by pg_trgm word_similarity on sku_name
 *
 * JC-108: free-form create is INTENTIONALLY not exposed. The UI offers the
 * existing canonical_sku list only — new canonicals come from the accdb
 * import (etl/import_sku_from_access_first.py), never the modal.
 *
 * Returns 200 JSON: { rows: UnmatchedSkuRow[], total }
 *
 * Auth: protected by middleware.ts session cookie.
 *
 * Schema dependency: sku_match_review from schema/091_b6b_sku_match_review.sql
 * If table missing, all rows return review_status='pending'.
 */

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

interface CanonicalSkuSuggestion {
  canonical_sku_id: number;
  canonical_sku_name: string;
  range_name: string | null;
  range_group: string | null;
  similarity: number;
}

interface ReviewStatus {
  action: string;
  applied_canonical_sku_id: number | null;
  reviewer: string;
  reviewed_at: string;
  notes: string | null;
}

interface UnmatchedSkuRow {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  source_system: string | null;
  revenue_aud: string;
  txn_count: number;
  qty_cases: string;
  min_date: string | null;
  max_date: string | null;
  review_status: string;
  review: ReviewStatus | null;
  suggestions: CanonicalSkuSuggestion[];
}

export async function GET(_request: NextRequest): Promise<NextResponse> {
  const pool = getPool();

  try {
    // 1. Does the audit table exist?
    const tableCheckResult = await pool.query<{ exists: boolean }>(`
      SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'sku_match_review'
      ) AS exists
    `);
    const reviewTableExists = tableCheckResult.rows[0]?.exists ?? false;

    // 2. Unmatched SKUs (canonical_sku_id IS NULL) with sales activity.
    //    Joining sales_transaction_normalized so we surface only the SKUs
    //    that actually matter — orphan canonicals with zero sales are
    //    handled by the populator, not the human reviewer.
    const unmatchedResult = await pool.query<{
      sku_id: number;
      sku_code: string;
      item_description: string;
      variety: string | null;
      region: string | null;
      vintage: number | null;
      source_system: string | null;
      revenue_aud: string;
      txn_count: string;
      qty_cases: string;
      min_date: string | null;
      max_date: string | null;
    }>(`
      SELECT
        s.sku_id,
        s.sku_code,
        s.item_description,
        s.variety,
        COALESCE(mro.region, s.region) AS region,
        s.vintage,
        NULL::text                                AS source_system,
        COALESCE(SUM(stn.net_revenue), 0)::numeric(12,2)  AS revenue_aud,
        COUNT(stn.transaction_id)                 AS txn_count,
        COALESCE(SUM(stn.quantity_cases), 0)::numeric(12,1) AS qty_cases,
        MIN(stn.sale_date)::text                  AS min_date,
        MAX(stn.sale_date)::text                  AS max_date
      FROM sku s
      LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
      LEFT JOIN sales_transaction_normalized stn
        ON stn.sku_id = s.sku_id
       AND stn.quantity > 0
      WHERE s.canonical_sku_id IS NULL
      GROUP BY
        s.sku_id, s.sku_code, s.item_description, s.variety,
        COALESCE(mro.region, s.region), s.vintage
      HAVING COUNT(stn.transaction_id) > 0
      ORDER BY revenue_aud DESC
    `);

    if (unmatchedResult.rows.length === 0) {
      return NextResponse.json({ rows: [], total: 0 });
    }

    // 3. Latest review per sku_id (if audit table exists).
    const reviewMap = new Map<number, ReviewStatus>();
    if (reviewTableExists) {
      const skuIds = unmatchedResult.rows.map(r => r.sku_id);
      const reviewResult = await pool.query<{
        sku_id: number;
        action: string;
        applied_canonical_sku_id: number | null;
        reviewer: string;
        reviewed_at: string;
        notes: string | null;
      }>(`
        SELECT DISTINCT ON (sku_id)
          sku_id,
          action,
          applied_canonical_sku_id,
          reviewer,
          reviewed_at::text AS reviewed_at,
          notes
        FROM sku_match_review
        WHERE sku_id = ANY($1::int[])
        ORDER BY sku_id, reviewed_at DESC
      `, [skuIds]);

      for (const row of reviewResult.rows) {
        reviewMap.set(row.sku_id, {
          action: row.action,
          applied_canonical_sku_id: row.applied_canonical_sku_id,
          reviewer: row.reviewer,
          reviewed_at: row.reviewed_at,
          notes: row.notes,
        });
      }
    }

    // 4. Top-3 canonical_sku suggestions per source name (pg_trgm word_similarity
    //    on canonical_sku.sku_name + sku_code as a secondary signal).
    const sourceNames = unmatchedResult.rows.map(r =>
      // Use item_description if usefully populated; fall back to sku_code.
      (r.item_description && r.item_description.trim().length > 0)
        ? r.item_description
        : r.sku_code
    );
    const sourceCodes = unmatchedResult.rows.map(r => r.sku_code);

    const suggestionMap = new Map<number, CanonicalSkuSuggestion[]>();

    try {
      // Verify pg_trgm extension is loaded.
      await pool.query("SELECT 1 FROM pg_extension WHERE extname='pg_trgm'");

      const suggResult = await pool.query<{
        sku_id: number;
        canonical_sku_id: number;
        canonical_sku_name: string;
        range_name: string | null;
        range_group: string | null;
        similarity: string;
      }>(`
        WITH source_rows AS (
          SELECT
            unnest($1::int[])  AS sku_id,
            unnest($2::text[]) AS source_name,
            unnest($3::text[]) AS source_code
        ),
        ranked AS (
          SELECT
            sr.sku_id,
            cs.id           AS canonical_sku_id,
            cs.sku_name     AS canonical_sku_name,
            cs.range_name,
            cs.range_group,
            GREATEST(
              word_similarity(UPPER(sr.source_name), UPPER(cs.sku_name)),
              word_similarity(UPPER(sr.source_code), UPPER(cs.sku_name))
            ) AS similarity,
            ROW_NUMBER() OVER (
              PARTITION BY sr.sku_id
              ORDER BY GREATEST(
                word_similarity(UPPER(sr.source_name), UPPER(cs.sku_name)),
                word_similarity(UPPER(sr.source_code), UPPER(cs.sku_name))
              ) DESC
            ) AS rn
          FROM source_rows sr
          CROSS JOIN canonical_sku cs
        )
        SELECT sku_id, canonical_sku_id, canonical_sku_name,
               range_name, range_group,
               (similarity * 100)::numeric(5,1)::text AS similarity
        FROM ranked
        WHERE rn <= 3
        ORDER BY sku_id, similarity DESC
      `, [
        unmatchedResult.rows.map(r => r.sku_id),
        sourceNames,
        sourceCodes,
      ]);

      for (const row of suggResult.rows) {
        if (!suggestionMap.has(row.sku_id)) {
          suggestionMap.set(row.sku_id, []);
        }
        suggestionMap.get(row.sku_id)!.push({
          canonical_sku_id: row.canonical_sku_id,
          canonical_sku_name: row.canonical_sku_name,
          range_name: row.range_name,
          range_group: row.range_group,
          similarity: parseFloat(row.similarity),
        });
      }
    } catch {
      console.warn('[unmatched-skus] pg_trgm not available; suggestions will be empty');
    }

    // 5. Assemble response.
    const rows: UnmatchedSkuRow[] = unmatchedResult.rows.map(r => {
      const review = reviewMap.get(r.sku_id) ?? null;
      const reviewStatus = review ? review.action : 'pending';
      return {
        sku_id: r.sku_id,
        sku_code: r.sku_code,
        item_description: r.item_description ?? '',
        variety: r.variety,
        region: r.region,
        vintage: r.vintage,
        source_system: r.source_system,
        revenue_aud: r.revenue_aud,
        txn_count: parseInt(r.txn_count, 10),
        qty_cases: r.qty_cases,
        min_date: r.min_date,
        max_date: r.max_date,
        review_status: reviewStatus,
        review,
        suggestions: suggestionMap.get(r.sku_id) ?? [],
      };
    });

    return NextResponse.json({ rows, total: rows.length });
  } catch (err) {
    console.error('[/api/admin/unmatched-skus] GET error:', err);
    return NextResponse.json(
      { error: 'Failed to load unmatched SKUs' },
      { status: 500 }
    );
  }
}

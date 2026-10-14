export const dynamic = 'force-dynamic';

/**
 * GET /api/admin/unmatched-customers
 *
 * CLARIFY-12: Returns the list of customers with sales_transaction data
 * but no canonical_customer_id, joined live against the canonical_customer
 * pool so top-3 fuzzy suggestions stay current as the canonical pool grows.
 *
 * For each unmatched customer:
 *   - Revenue + transaction count from sales_transaction
 *   - Existing review status from customer_match_review (most recent)
 *   - Top-3 canonical suggestions by levenshtein similarity (name only)
 *     NOTE: the full fuzzy-match CSV from scripts/clarify12_fuzzy_match_customers.py
 *     is the authoritative scored source; this endpoint re-derives a live
 *     similarity ranking via pg_trgm for freshness.
 *
 * Returns 200 JSON: { rows: UnmatchedCustomerRow[], total: number }
 *
 * Auth: protected by middleware.ts session cookie (all /admin/* routes).
 *
 * Schema dependency: customer_match_review table from
 *   schema/080_clarify12_customer_match_audit.sql must be applied first.
 *   If table doesn't exist, returns rows with review_status='pending'.
 */

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

// The fuzzy bucket CSV values — kept in sync with Python script
type Bucket = 'HIGH_CONFIDENCE_AUTO' | 'REVIEW_NEEDED' | 'NO_MATCH' | 'pending';

interface CanonicalSuggestion {
  canonical_id: number;
  canonical_name: string;
  territory_name: string | null;
  channel: string | null;
  similarity: number;
}

interface ReviewStatus {
  action: string;
  applied_canonical_id: number | null;
  reviewer: string;
  reviewed_at: string;
  notes: string | null;
}

interface UnmatchedCustomerRow {
  customer_id: number;
  customer_name: string;
  source_system: string | null;
  suburb: string | null;
  postcode: string | null;
  state: string | null;  // F3 (schema/167): customer.state, backfilled from au_postcode JOIN
  warehouse_channel: string | null;  // F3: explicit channel field (also surfaced as source_system)
  address: string | null;  // D1 (schema/165): ALM EDI outlet_address — null on non-ALM rows
  territory_id: number | null;
  revenue_aud: string;
  txn_count: number;
  min_date: string | null;
  max_date: string | null;
  review_status: string;
  review: ReviewStatus | null;
  suggestions: CanonicalSuggestion[];
}

export async function GET(_request: NextRequest): Promise<NextResponse> {
  const pool = getPool();

  try {
    // 1. Check if customer_match_review table exists
    const tableCheckResult = await pool.query<{ exists: boolean }>(`
      SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'customer_match_review'
      ) AS exists
    `);
    const reviewTableExists = tableCheckResult.rows[0]?.exists ?? false;

    // 2. Fetch unmatched customers with revenue stats.
    // D1 (schema/165): LEFT JOIN LATERAL to alm_edi_segment_52 by outlet_name
    // (case-insensitive trim match) picks the most-recent ALM EDI outlet_address
    // for each customer. NULL on non-ALM rows OR ALM rows imported before
    // schema/165 (no historical backfill). Modal renders blank Address in
    // both cases — no regression vs current behaviour.
    //
    // ALM EDI 5|2 pads outlet_name to 30 chars + outlet_address to 25 chars
    // with trailing spaces — TRIM both sides to match canonical customer_name.
    // Latest row wins via ORDER BY inserted_at DESC LIMIT 1 (no segment 5|2
    // version conflict — the owner's EDI is append-only weekly).
    // F3 (schema/167): customer.state added + backfilled via au_postcode JOIN
    // on postcode. Unmatched-customer panel rows are all canonical_customer_id
    // IS NULL — schema/167 backfill SKIPS NULL-canonical rows (L6 CHECK guard
    // customer_must_have_canonical NOT VALID). So customer.state may be NULL
    // here. Fallback: LEFT JOIN LATERAL to au_postcode by postcode + suburb
    // gives the same answer the migration would have written had canonical
    // not been NULL. Both paths produce identical results once schema/161
    // BUG-165 dedup family lands and the NULL-canonical tail is backfilled.
    const unmatchedResult = await pool.query<{
      customer_id: number;
      customer_name: string;
      source_system: string | null;
      suburb: string | null;
      postcode: string | null;
      state: string | null;
      warehouse_channel: string | null;
      address: string | null;
      territory_id: number | null;
      revenue_aud: string;
      txn_count: string;
      min_date: string | null;
      max_date: string | null;
    }>(`
      SELECT
        c.customer_id,
        c.customer_name,
        c.warehouse_channel         AS source_system,
        c.suburb,
        c.postcode,
        COALESCE(c.state, ap.state) AS state,
        c.warehouse_channel,
        seg.outlet_address          AS address,
        c.territory_id,
        COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) AS revenue_aud,
        COUNT(st.transaction_id)    AS txn_count,
        MIN(st.sale_date)::text     AS min_date,
        MAX(st.sale_date)::text     AS max_date
      FROM customer c
      JOIN sales_transaction st ON st.customer_id = c.customer_id
      LEFT JOIN LATERAL (
        SELECT TRIM(outlet_address) AS outlet_address
        FROM alm_edi_segment_52
        WHERE UPPER(TRIM(outlet_name)) = UPPER(TRIM(c.customer_name))
          AND outlet_address IS NOT NULL
          AND TRIM(outlet_address) <> ''
        ORDER BY inserted_at DESC
        LIMIT 1
      ) seg ON TRUE
      LEFT JOIN LATERAL (
        SELECT state
        FROM au_postcode
        WHERE au_postcode.postcode = c.postcode
        ORDER BY
          CASE WHEN UPPER(au_postcode.locality) = UPPER(c.suburb) THEN 0 ELSE 1 END,
          state,
          locality
        LIMIT 1
      ) ap ON c.postcode IS NOT NULL
      WHERE c.canonical_customer_id IS NULL
      GROUP BY
        c.customer_id, c.customer_name, c.warehouse_channel,
        c.suburb, c.postcode, c.state, ap.state, seg.outlet_address, c.territory_id
      ORDER BY revenue_aud DESC
    `);

    if (unmatchedResult.rows.length === 0) {
      return NextResponse.json({ rows: [], total: 0 });
    }

    // 3. Fetch latest review for each unmatched customer (if table exists)
    let reviewMap = new Map<number, ReviewStatus>();
    if (reviewTableExists) {
      const customerIds = unmatchedResult.rows.map(r => r.customer_id);
      const reviewResult = await pool.query<{
        customer_id: number;
        action: string;
        applied_canonical_id: number | null;
        reviewer: string;
        reviewed_at: string;
        notes: string | null;
      }>(`
        SELECT DISTINCT ON (customer_id)
          customer_id,
          action,
          applied_canonical_id,
          reviewer,
          reviewed_at::text AS reviewed_at,
          notes
        FROM customer_match_review
        WHERE customer_id = ANY($1::int[])
        ORDER BY customer_id, reviewed_at DESC
      `, [customerIds]);

      for (const row of reviewResult.rows) {
        reviewMap.set(row.customer_id, {
          action: row.action,
          applied_canonical_id: row.applied_canonical_id,
          reviewer: row.reviewer,
          reviewed_at: row.reviewed_at,
          notes: row.notes,
        });
      }
    }

    // 4. For each unmatched customer, compute top-3 canonical suggestions
    //    via pg_trgm similarity on normalised name (live — canonical pool grows)
    //    We batch all customers in one query using a lateral join approach.
    const customerNames = unmatchedResult.rows.map(r => r.customer_name);
    const customerSuburbs = unmatchedResult.rows.map(r => r.suburb ?? '');

    // M15 (2026-05-14, Customer 106 incident): port suburb-boost from
    // etl/preview.py:439-458 into the suggestion SQL. Pure trigram on
    // "CUSTOMER 106" matched "CUSTOMER 17 @ WARRAGAMBA" (79%) over
    // "Customer 02 @ Coledale" because the "Fine Wines" token dominates
    // word_similarity. Suburb-exact boost (+0.20) flips the tie; DWS
    // implicit-suburb boost (+0.40) fires when the SOURCE name embeds the
    // canonical's suburb token. Capped at 1.0.
    // M15b (2026-05-17): predicate was lower(cc.customer_name) ~ cc.suburb
    // (canonical name contains its OWN suburb) — true for ~every "X @ SUBURB"
    // name, so the boost was universal and non-discriminating; Coledale stayed
    // buried. Flipped to lower(sn.source_name) ~ cc.suburb so the boost only
    // fires when the source string actually contains that suburb. See
    let suggestionMap = new Map<string, CanonicalSuggestion[]>();

    try {
      // Check if pg_trgm is available
      await pool.query("SELECT 1 FROM pg_extension WHERE extname='pg_trgm'");

      const suggResult = await pool.query<{
        source_name: string;
        canonical_id: number;
        canonical_name: string;
        territory_name: string | null;
        channel: string | null;
        similarity: string;
      }>(`
        WITH source_names AS (
          SELECT source_name, source_suburb
          FROM unnest($1::text[], $2::text[]) AS t(source_name, source_suburb)
        ),
        ranked AS (
          SELECT
            sn.source_name,
            cc.id           AS canonical_id,
            cc.customer_name AS canonical_name,
            cc.territory_name,
            cc.channel,
            LEAST(
              word_similarity(UPPER(sn.source_name), UPPER(cc.customer_name))
              + CASE
                  WHEN sn.source_suburb <> '' AND cc.suburb IS NOT NULL
                       AND lower(trim(sn.source_suburb)) = lower(trim(cc.suburb))
                    THEN 0.20
                  WHEN (sn.source_suburb IS NULL OR sn.source_suburb = '')
                       AND cc.suburb IS NOT NULL AND trim(cc.suburb) <> ''
                       AND lower(sn.source_name) ~ ('\m' || lower(trim(cc.suburb)) || '\M')
                    THEN 0.40
                  ELSE 0.0
                END,
              1.0
            ) AS similarity,
            ROW_NUMBER() OVER (
              PARTITION BY sn.source_name
              ORDER BY
                LEAST(
                  word_similarity(UPPER(sn.source_name), UPPER(cc.customer_name))
                  + CASE
                      WHEN sn.source_suburb <> '' AND cc.suburb IS NOT NULL
                           AND lower(trim(sn.source_suburb)) = lower(trim(cc.suburb))
                        THEN 0.20
                      WHEN (sn.source_suburb IS NULL OR sn.source_suburb = '')
                           AND cc.suburb IS NOT NULL AND trim(cc.suburb) <> ''
                           AND lower(sn.source_name) ~ ('\m' || lower(trim(cc.suburb)) || '\M')
                        THEN 0.40
                      ELSE 0.0
                    END,
                  1.0
                ) DESC
            ) AS rn
          FROM source_names sn
          CROSS JOIN canonical_customer cc
          WHERE cc.is_active = TRUE
        )
        SELECT source_name, canonical_id, canonical_name, territory_name, channel,
               (similarity * 100)::numeric(5,1)::text AS similarity
        FROM ranked
        WHERE rn <= 3
        ORDER BY source_name, similarity DESC
      `, [customerNames, customerSuburbs]);

      for (const row of suggResult.rows) {
        if (!suggestionMap.has(row.source_name)) {
          suggestionMap.set(row.source_name, []);
        }
        suggestionMap.get(row.source_name)!.push({
          canonical_id: row.canonical_id,
          canonical_name: row.canonical_name,
          territory_name: row.territory_name,
          channel: row.channel,
          similarity: parseFloat(row.similarity),
        });
      }
    } catch {
      // pg_trgm not available — fall back to empty suggestions
      // (admin can still use the typeahead search to pick manually)
      console.warn('[unmatched-customers] pg_trgm not available; suggestions will be empty');
    }

    // 5. Assemble response
    const rows: UnmatchedCustomerRow[] = unmatchedResult.rows.map(r => {
      const review = reviewMap.get(r.customer_id) ?? null;
      let reviewStatus = 'pending';
      if (review) {
        reviewStatus = review.action;
      }

      return {
        customer_id: r.customer_id,
        customer_name: r.customer_name,
        source_system: r.source_system,
        suburb: r.suburb,
        postcode: r.postcode,
        state: r.state,
        warehouse_channel: r.warehouse_channel,
        address: r.address,
        territory_id: r.territory_id,
        revenue_aud: r.revenue_aud,
        txn_count: parseInt(r.txn_count, 10),
        min_date: r.min_date,
        max_date: r.max_date,
        review_status: reviewStatus,
        review,
        suggestions: suggestionMap.get(r.customer_name) ?? [],
      };
    });

    return NextResponse.json({ rows, total: rows.length });
  } catch (err) {
    console.error('[/api/admin/unmatched-customers] GET error:', err);
    return NextResponse.json(
      { error: 'Failed to load unmatched customers' },
      { status: 500 }
    );
  }
}

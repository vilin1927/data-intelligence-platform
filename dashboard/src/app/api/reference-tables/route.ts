export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/reference-tables?table=customers|skus&search=term&page=1
 *
 * Read-only browse endpoint for post-import verification.
 * Returns rows from customer or sku table with joined lookup data.
 * Supports optional search filter and pagination (500 per page).
 *
 * JF-35: the owner needs to verify customer/SKU data after import.
 * Joins through canonical_customer for channel/territory/rep metadata.
 */
export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const table = request.nextUrl.searchParams.get('table') || 'customers';
    const search = request.nextUrl.searchParams.get('search') || '';
    const page = Math.max(1, parseInt(request.nextUrl.searchParams.get('page') || '1', 10));
    const PAGE_SIZE = 500;

    if (table === 'customers') {
      // BUG-79: group by canonical_customer_id so a business appearing across DWS +
      // ALM + Direct shows as ONE row with all 3 external codes visible, matching
      // The owner's Access DB structure. Schema (012_canonical_foundation + 001_initial
      // customer_code_map) already supports this — only the query was dumping raw
      // satellite rows. Unlinked customers (canonical_customer_id IS NULL) stay as
      // their own rows via the 'u:' grouping key.
      const params: (string | number)[] = [];
      // BUG-87 (v2): drive query FROM canonical_customer so orphan canonicals
      // (rows from the owner's Database reconciliation xlsx master with no DWS/ALM/
      // Vinsight activity yet) appear. 4,014 canonical rows = his Access count.
      // Satellite customer rows are LEFT JOINed — so orphans render with empty
      // code columns and satellite_count=0. Unlinked satellite rows
      // (customer.canonical_customer_id IS NULL) are excluded — tracked separately
      // under admin surfaces.
      let whereClause = '';

      if (search.length >= 2) {
        whereClause = `WHERE (
          LOWER(cc.customer_name) LIKE LOWER($1)
          OR LOWER(cc.customer_group) LIKE LOWER($1)
          OR LOWER(cc.channel) LIKE LOWER($1)
          OR LOWER(cc.territory_name) LIKE LOWER($1)
          OR LOWER(cc.rep_name) LIKE LOWER($1)
          OR EXISTS (
            SELECT 1 FROM customer c2
            WHERE c2.canonical_customer_id = cc.id
              AND (LOWER(c2.customer_name) LIKE LOWER($1)
                   OR LOWER(c2.suburb) LIKE LOWER($1)
                   OR LOWER(c2.postcode) LIKE LOWER($1))
          )
          OR EXISTS (
            SELECT 1 FROM customer_code_map cm
            JOIN customer c3 ON c3.customer_id = cm.customer_id
            WHERE c3.canonical_customer_id = cc.id
              AND LOWER(cm.external_name) LIKE LOWER($1)
          )
          OR EXISTS (
            SELECT 1 FROM customer_alias ca
            WHERE ca.canonical_customer_id = cc.id
              AND LOWER(ca.alias_name) LIKE LOWER($1)
          )
        )`;
        params.push(`%${search}%`);
      }

      // Count = canonical_customer rows matching search (canonical + satellite fields)
      const countResult = await pool.query(
        `SELECT count(*) FROM canonical_customer cc ${whereClause}`,
        params
      );
      const total = parseInt(countResult.rows[0].count, 10);
      const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
      const offset = (page - 1) * PAGE_SIZE;

      const limitParamIdx = params.length + 1;
      const offsetParamIdx = params.length + 2;
      params.push(PAGE_SIZE, offset);

      // BUG-135: surface customer.canonical_rep_id (Phase H / BUG-95) by joining
      // canonical_representative through the satellite customer rows. A canonical
      // customer can have multiple satellites with different canonical_rep_id
      // (rare in practice — 8,147/10,973 customers have non-NULL canonical_rep_id
      // as of 2026-04-23), so we string_agg distinct rep names per canonical.
      // B4 JC-003/004/005/006/007/008/028: surface the full Access 22-col
      // schema on the Customers tab. New cols (customer_code, ilg/ynr_alm
      // codes, territory_group, remark, notes, x_customer_name, edited_on,
      // added_on, max_id, is_deleted, contact_category) come from
      // canonical_customer directly — added in schema/060+061. This query
      // requires schema/060+061 to be applied; deploy code AFTER migration.
      const result = await pool.query(
        `WITH grouped AS (
          SELECT
            'c:' || cc.id::text AS group_key,
            cc.id AS canonical_id,
            MIN(c.customer_id) AS representative_customer_id,
            cc.customer_name,
            cc.customer_group,
            (array_agg(c.suburb) FILTER (WHERE c.suburb IS NOT NULL AND c.suburb <> ''))[1] AS suburb_satellite,
            (array_agg(c.postcode) FILTER (WHERE c.postcode IS NOT NULL AND c.postcode <> ''))[1] AS postcode_satellite,
            cc.suburb            AS suburb_canonical,
            cc.postcode          AS postcode_canonical,
            cc.channel,
            -- BUG-127 / ADR-017: warehouse channel — orthogonal to venue (cc.channel).
            -- Pick first non-NULL across satellites; NULL when no signal.
            (array_agg(c.warehouse_channel) FILTER (WHERE c.warehouse_channel IS NOT NULL))[1] AS warehouse_channel,
            cc.territory_name,
            cc.rep_name,
            cc.customer_code,
            cc.alm_customer_code,
            cc.dir_customer_code,
            cc.ilg_customer_code,
            cc.ynr_customer_code,
            cc.ynr_alm_customer_code,
            cc.territory_group,
            cc.remark,
            cc.notes,
            cc.x_customer_name,
            cc.edited_on,
            cc.added_on,
            cc.max_id,
            cc.is_deleted,
            cc.contact_category,
            count(DISTINCT c.customer_id) AS satellite_count,
            COALESCE(array_agg(DISTINCT c.customer_id) FILTER (WHERE c.customer_id IS NOT NULL), ARRAY[]::int[]) AS customer_ids
          FROM canonical_customer cc
          LEFT JOIN customer c ON c.canonical_customer_id = cc.id
          ${whereClause}
          GROUP BY cc.id, cc.customer_name, cc.customer_group, cc.suburb, cc.postcode, cc.channel, cc.territory_name, cc.rep_name,
                   cc.customer_code, cc.alm_customer_code, cc.dir_customer_code, cc.ilg_customer_code, cc.ynr_customer_code, cc.ynr_alm_customer_code,
                   cc.territory_group, cc.remark, cc.notes, cc.x_customer_name, cc.edited_on, cc.added_on, cc.max_id, cc.is_deleted, cc.contact_category
        ),
        -- BUG-171: dropped legacy customer_code_map aggregation. Channel codes
        -- are sourced ONLY from canonical_customer.{alm,dir,ilg,ynr,ynr_alm}_customer_code
        -- (the owner's Access master). The old code_map agg surfaced satellite import
        -- state polluted with NAMES (e.g. CUSTOMER 18 DWS slot showing
        -- 'CUSTOMER 19' from a botched DWS import match) and is
        -- reserved for /admin satellite hygiene surfaces.
        canonical_reps AS (
          SELECT
            g.group_key,
            string_agg(DISTINCT COALESCE(cr.full_rep_display, cr.rep_name), ', ' ORDER BY COALESCE(cr.full_rep_display, cr.rep_name)) AS canonical_rep_names,
            count(DISTINCT cr.id) AS canonical_rep_count
          FROM grouped g
          LEFT JOIN customer c2 ON c2.customer_id = ANY(g.customer_ids)
          LEFT JOIN canonical_representative cr ON cr.id = c2.canonical_rep_id
          GROUP BY g.group_key
        )
        SELECT
          g.representative_customer_id AS customer_id,
          g.canonical_id,
          g.customer_name,
          g.customer_group,
          -- B4: prefer canonical-side suburb/postcode (Access master) when set;
          -- fall back to satellite values for backward-compat with rows imported
          -- before schema/060 backfill.
          COALESCE(g.suburb_canonical,   g.suburb_satellite)   AS suburb,
          COALESCE(g.postcode_canonical, g.postcode_satellite) AS postcode,
          g.channel,
          g.warehouse_channel,
          g.territory_name,
          g.territory_group,
          g.rep_name,
          g.customer_code,
          g.alm_customer_code,
          g.dir_customer_code,
          g.ilg_customer_code,
          g.ynr_customer_code,
          g.ynr_alm_customer_code,
          g.remark,
          g.notes,
          g.x_customer_name,
          g.edited_on,
          g.added_on,
          g.max_id,
          g.is_deleted,
          g.contact_category,
          g.satellite_count,
          cr.canonical_rep_names,
          cr.canonical_rep_count
        FROM grouped g
        LEFT JOIN canonical_reps cr ON cr.group_key = g.group_key
        ORDER BY g.customer_name
        LIMIT $${limitParamIdx} OFFSET $${offsetParamIdx}`,
        params
      );

      return NextResponse.json({
        table: 'customers',
        rows: result.rows.map(r => ({
          id: r.customer_id,
          canonical_id: r.canonical_id,
          name: r.customer_name,
          group: r.customer_group || '',
          suburb: r.suburb || '',
          postcode: r.postcode || '',
          channel: r.channel || '',
          // BUG-127 / ADR-017: warehouse channel surface (DWS/ALM/Direct/null).
          warehouse_channel: r.warehouse_channel || '',
          territory: r.territory_name || '',
          // B4 JC-003: TerritoryGroup column from Access master.
          territory_group: r.territory_group || '',
          rep: r.rep_name || '',
          // BUG-135: Owner-master canonical rep (from customer.canonical_rep_id
          // joined to canonical_representative), distinct from the freetext
          // rep_name on canonical_customer (which is the Access-side label).
          canonical_rep: r.canonical_rep_names || '',
          canonical_rep_count: parseInt(r.canonical_rep_count, 10) || 0,
          // B4 JC-003: master CustomerCode (Access Customers.CustomerCode).
          customer_code: r.customer_code || '',
          // B4 JC-004: 5 channel cross-ref codes (Access master).
          alm_customer_code:     r.alm_customer_code     || '',
          dir_customer_code:     r.dir_customer_code     || '',
          ilg_customer_code:     r.ilg_customer_code     || '',
          ynr_customer_code:     r.ynr_customer_code     || '',
          ynr_alm_customer_code: r.ynr_alm_customer_code || '',
          // B4 JC-008: Notes + Remark distinct columns.
          remark: r.remark || '',
          notes:  r.notes  || '',
          // B4 JC-007: alternate xCustomerName.
          x_customer_name: r.x_customer_name || '',
          // B4 JC-006: audit timestamps + MaxID surrogate.
          edited_on: r.edited_on ? new Date(r.edited_on).toISOString() : '',
          added_on:  r.added_on  ? new Date(r.added_on).toISOString()  : '',
          max_id:    r.max_id ?? null,
          // B4 JC-005: soft-delete flag (Access IsDelete).
          is_deleted: r.is_deleted === true,
          // B4 JC-035 + JC-051: Vinsight Contact Category JSONB tag bag.
          contact_category: Array.isArray(r.contact_category) ? r.contact_category : [],
          // BUG-171: legacy dws_code / alm_code / vinsight_code (customer_code_map
          // aggregates) removed from /reference Customer surface. The 5 channel
          // codes above (alm/dir/ilg/ynr/ynr_alm_customer_code) are the Owner-master
          // source of truth.
          satellite_count: parseInt(r.satellite_count, 10) || 0,
        })),
        total,
        filtered: result.rows.length,
        page,
        totalPages,
      });
    }

    if (table === 'skus') {
      // Phase R / BUG-148: Parent > Vintage > Code hierarchy.
      // The owner call 03:59 — "Hierarchy would be: Parent SKU > Parent SKU/Vintage >
      // product codes for each vintage." Response shape:
      //   canonicals[].vintages[].codes[]  (3 levels)
      // Active canonicals only (matches Overview KPI). A canonical can own
      // zero vintages (orphan canonical — still rendered). A vintage groups the
      // sku rows whose sku.vintage = that year (plus an "NV" bucket for nulls).
      // A code row comes from sku_code_map (source_system + external_code) plus
      // the Moppity sku.sku_code itself surfaced as source_system='moppity'.

      // Pull every active canonical + its sku rows + all external code maps in
      // 3 round-trips, then assemble the tree in JS (cleaner than nesting
      // array_agg three deep in SQL).
      const [canonicalsRes, skusRes, codeMapRes] = await Promise.all([
        pool.query(`
          SELECT
            cs.id,
            cs.sku_name,
            cs.range_name,
            cs.range_group,
            cs.units_per_case
          FROM canonical_sku cs
          WHERE cs.is_active_canonical = TRUE
          ORDER BY cs.sku_name
        `),
        pool.query(`
          SELECT
            s.sku_id,
            s.canonical_sku_id,
            s.sku_code,
            s.item_description,
            s.variety,
            COALESCE(mro.region, s.region) AS region,
            s.vintage,
            s.units_per_case,
            cs.range_name
          FROM sku s
          INNER JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
          LEFT JOIN manual_region_override mro ON mro.sku_id = s.sku_id
          WHERE cs.is_active_canonical = TRUE
            -- BUG-175: filter out parent-shaped sku rows (sku_code is the
            -- canonical name, not a real per-vintage code). They exist only
            -- as a sales/packaging FK target and should not surface in the
            -- /reference SKU UI tree. See schema/129_bug175_sku_master_cleanup.sql
            AND s.sku_code <> cs.sku_name
          ORDER BY s.canonical_sku_id, s.vintage DESC NULLS LAST, s.sku_code
        `),
        pool.query(`
          -- PHASE1-CLOSE-E4-E5-DEDUPE-PRIORITY: same external_code can appear
          -- under multiple source_system rows for the same canonical+vintage
          -- (e.g. COPSICHA621 under access + dws; COCSCHAB22 under access +
          -- vinsight). The owner May 8 Slack flagged this on /reference SKU tab.
          -- Priority rule: vinsight > moppity > dws > access > alm > ilg.
          -- DISTINCT ON (canonical_sku_id, vintage, external_code) keeps the
          -- highest-priority source per logical (canonical, vintage, code).
          -- Display-time dedupe (Approach A) — no schema change, no destructive
          -- DELETE on canonical_sku_code_map. Pure SELECT projection.
          SELECT DISTINCT ON (s.canonical_sku_id, s.vintage, m.external_code)
            m.sku_id,
            m.source_system,
            m.external_code
          FROM sku_code_map m
          INNER JOIN sku s ON s.sku_id = m.sku_id
          INNER JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
          WHERE cs.is_active_canonical = TRUE
            -- BUG-175: same filter — code_map rows on parent-shaped sku rows
            -- are stale fan-in artefacts; if any survived schema/129 migration
            -- (e.g. on canonicals other than id=14) suppress here too.
            AND s.sku_code <> cs.sku_name
          ORDER BY s.canonical_sku_id, s.vintage, m.external_code,
                   CASE m.source_system
                     WHEN 'vinsight' THEN 1
                     WHEN 'moppity'  THEN 2
                     WHEN 'dws'      THEN 3
                     WHEN 'access'   THEN 4
                     WHEN 'alm'      THEN 5
                     WHEN 'ilg'      THEN 6
                     ELSE 7
                   END,
                   m.source_system,
                   m.sku_id
        `),
      ]);

      type CodeRow = { source: string; external_code: string };
      type VintageNode = {
        vintage: number | null;
        sku_ids: number[];
        moppity_codes: string[];
        descriptions: string[];
        codes: CodeRow[];
      };
      type CanonicalNode = {
        id: number;
        sku_name: string;
        range: string;
        range_group: string;
        units_per_case: number;
        variety: string;
        region: string;
        vintage_count: number;
        code_count: number;
        vintages: VintageNode[];
      };

      // Group sku rows by canonical_sku_id → vintage
      const canonicalMap = new Map<number, CanonicalNode>();
      for (const c of canonicalsRes.rows) {
        canonicalMap.set(c.id, {
          id: c.id,
          sku_name: c.sku_name,
          range: c.range_name || '',
          range_group: c.range_group || '',
          units_per_case: c.units_per_case || 12,
          variety: '',
          region: '',
          vintage_count: 0,
          code_count: 0,
          vintages: [],
        });
      }

      // Build vintage buckets keyed by canonical_id|vintage_year (null → 'NV')
      const vintageBuckets = new Map<string, VintageNode>();
      for (const s of skusRes.rows) {
        const parent = canonicalMap.get(s.canonical_sku_id);
        if (!parent) continue;
        const vintageKey = `${s.canonical_sku_id}|${s.vintage == null ? 'NV' : s.vintage}`;
        let bucket = vintageBuckets.get(vintageKey);
        if (!bucket) {
          bucket = {
            vintage: s.vintage == null ? null : parseInt(s.vintage, 10),
            sku_ids: [],
            moppity_codes: [],
            descriptions: [],
            codes: [],
          };
          vintageBuckets.set(vintageKey, bucket);
          parent.vintages.push(bucket);
        }
        bucket.sku_ids.push(s.sku_id);
        if (s.sku_code) bucket.moppity_codes.push(s.sku_code);
        if (s.item_description) bucket.descriptions.push(s.item_description);
        // Surface variety/region/range on the canonical from the first matching sku row
        if (!parent.variety && s.variety) parent.variety = s.variety;
        if (!parent.region && s.region) parent.region = s.region;
        if (!parent.range && s.range_name) parent.range = s.range_name;
      }

      // Attach Moppity sku_code as a 'moppity' source row, then external codes
      // from sku_code_map. One code row per (sku_id, source, external_code).
      const bucketList: VintageNode[] = Array.from(vintageBuckets.values());
      for (const bucket of bucketList) {
        for (const code of bucket.moppity_codes) {
          bucket.codes.push({ source: 'moppity', external_code: code });
        }
      }
      for (const m of codeMapRes.rows) {
        for (const bucket of bucketList) {
          if (bucket.sku_ids.includes(m.sku_id)) {
            bucket.codes.push({ source: m.source_system, external_code: m.external_code });
            break;
          }
        }
      }

      // PHASE1-CLOSE-E4-E5-DEDUPE-PRIORITY: final per-bucket dedup pass.
      // SQL DISTINCT ON in codeMapRes already deduped same external_code across
      // multiple source_system rows per (canonical, vintage). This pass also
      // collapses (a) the same external_code arriving via both `moppity` (from
      // sku.sku_code) AND a sku_code_map source row, and (b) any residual cross-
      // sku_id duplication within a vintage bucket. Priority rule:
      // vinsight > moppity > dws > access > alm > ilg.
      const SOURCE_PRIORITY: Record<string, number> = {
        vinsight: 1,
        moppity:  2,
        dws:      3,
        access:   4,
        alm:      5,
        ilg:      6,
      };
      const sourceRank = (src: string): number =>
        SOURCE_PRIORITY[src] ?? 99;
      for (const bucket of bucketList) {
        const winnerByCode = new Map<string, CodeRow>();
        for (const row of bucket.codes) {
          const existing = winnerByCode.get(row.external_code);
          if (!existing || sourceRank(row.source) < sourceRank(existing.source)) {
            winnerByCode.set(row.external_code, row);
          }
        }
        // Stable order: by source priority, then external_code.
        bucket.codes = Array.from(winnerByCode.values()).sort((a, b) => {
          const rankDiff = sourceRank(a.source) - sourceRank(b.source);
          if (rankDiff !== 0) return rankDiff;
          return a.external_code.localeCompare(b.external_code);
        });
      }

      // Sort vintages within each canonical (most recent first, NV last) and
      // compute rollup counts.
      const canonicals: CanonicalNode[] = Array.from(canonicalMap.values());
      for (const node of canonicals) {
        node.vintages.sort((a: VintageNode, b: VintageNode) => {
          if (a.vintage == null && b.vintage == null) return 0;
          if (a.vintage == null) return 1;
          if (b.vintage == null) return -1;
          return b.vintage - a.vintage;
        });
        node.vintage_count = node.vintages.length;
        node.code_count = node.vintages.reduce((sum: number, v: VintageNode) => sum + v.codes.length, 0);
      }

      // Apply search filter — match against canonical name, any Moppity code,
      // any external code, variety, region, description.
      const needle = search.trim().toLowerCase();
      const filtered = needle.length >= 2
        ? canonicals.filter(c => {
            if (c.sku_name.toLowerCase().includes(needle)) return true;
            if (c.variety.toLowerCase().includes(needle)) return true;
            if (c.region.toLowerCase().includes(needle)) return true;
            return c.vintages.some(v =>
              v.descriptions.some(d => d.toLowerCase().includes(needle)) ||
              v.codes.some(code => code.external_code.toLowerCase().includes(needle))
            );
          })
        : canonicals;

      return NextResponse.json({
        table: 'skus',
        rows: filtered.map(c => ({
          id: c.id,
          sku_name: c.sku_name,
          range: c.range,
          range_group: c.range_group,
          units_per_case: c.units_per_case,
          variety: c.variety,
          region: c.region,
          vintage_count: c.vintage_count,
          code_count: c.code_count,
          vintages: c.vintages.map(v => ({
            vintage: v.vintage,
            description: v.descriptions[0] || '',
            codes: v.codes,
          })),
        })),
        total: canonicals.length,
        filtered: filtered.length,
      });
    }

    return NextResponse.json(
      { error: 'Invalid table parameter. Use "customers" or "skus".' },
      { status: 400 }
    );
  } catch (err) {
    console.error('[/api/reference-tables] GET error:', err);
    return NextResponse.json(
      { error: 'Failed to load reference table data' },
      { status: 500 }
    );
  }
}

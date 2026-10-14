export const dynamic = 'force-dynamic';

import { NextRequest, NextResponse } from 'next/server';
import getPool from '@/lib/db';

/**
 * GET /api/customers?search=term
 * Returns matching customers for search dropdown (server-side search).
 *
 * POST /api/customers
 * Creates a new customer. Body: { name, territory_id, customer_group, channel_id }
 * Returns the new customer_id.
 */

export async function GET(request: NextRequest) {
  try {
    const pool = getPool();
    const search = request.nextUrl.searchParams.get('search') || '';

    if (search.length < 2) {
      return NextResponse.json({ customers: [] });
    }

    // First try exact substring match — join through canonical_customer for metadata
    const result = await pool.query(
      `SELECT c.customer_id, c.customer_name, COALESCE(cc.customer_group, c.customer_group) as customer_group,
              c.suburb, c.postcode,
              cc.territory_name, cc.channel, cc.rep_name,
              1.0::real as match_score, 'exact' as match_type
       FROM customer c
       LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
       WHERE LOWER(c.customer_name) LIKE LOWER($1)
       ORDER BY c.customer_name
       LIMIT 20`,
      [`%${search}%`]
    );

    let rows = result.rows;

    // If few exact matches, add fuzzy suggestions via pg_trgm
    // JF-10: Lowered threshold from 0.15 to 0.10 and added word_similarity for better
    // matching (e.g. "Cellarbrations Carnegie" -> "Customer 04")
    //
    // M15 (2026-05-14): suburb-boost from etl/preview.py:439-458 is NOT ported
    // here. This endpoint is the typeahead search box — caller passes only a
    // free-text `search` string, no suburb param in the contract. Adding a
    // suburb param would change the API surface every caller (CustomerSearch,
    // ImportWizard, admin pages) relies on. Suburb-boost lives in the
    // import-flow route /api/admin/unmatched-customers where source.suburb is
    // already plumbed. If typeahead ranking ever regresses on the
    // "Customer 106" class of bug, plumb suburb here as a second param.
    if (rows.length < 5 && search.length >= 3) {
      const existingIds = rows.map(r => r.customer_id);
      const excludeClause = existingIds.length > 0
        ? `AND c.customer_id NOT IN (${existingIds.map((_, i) => `$${i + 2}`).join(',')})`
        : '';
      const fuzzy = await pool.query(
        `SELECT c.customer_id, c.customer_name, COALESCE(cc.customer_group, c.customer_group) as customer_group,
                c.suburb, c.postcode,
                cc.territory_name, cc.channel, cc.rep_name,
                GREATEST(similarity(c.customer_name, $1), word_similarity($1, c.customer_name))::real as match_score,
                'fuzzy' as match_type
         FROM customer c
         LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
         WHERE GREATEST(similarity(c.customer_name, $1), word_similarity($1, c.customer_name)) > 0.10
           ${excludeClause}
         ORDER BY GREATEST(similarity(c.customer_name, $1), word_similarity($1, c.customer_name)) DESC
         LIMIT ${10 - rows.length}`,
        [search, ...existingIds]
      );
      rows = [...rows, ...fuzzy.rows];
    }

    return NextResponse.json({
      customers: rows.map(r => ({
        customer_id: r.customer_id,
        customer_name: r.customer_name,
        customer_group: r.customer_group || '',
        suburb: r.suburb || '',
        postcode: r.postcode || '',
        territory: r.territory_name || '',
        channel: r.channel || '',
        rep: r.rep_name || '',
        match_score: parseFloat(r.match_score) || 0,
        match_type: r.match_type || 'exact',
      })),
    });
  } catch (err) {
    console.error('[/api/customers] GET error:', err);
    return NextResponse.json({ error: 'Failed to search customers' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const pool = getPool();
    const body = await request.json();
    const { name, territory_id, customer_group, channel_id, suburb, postcode, rep_id, source_system, external_name, warehouse_channel } = body as {
      name: string;
      territory_id?: number | null;
      customer_group?: string | null;
      channel_id?: number | null;
      suburb?: string | null;
      postcode?: string | null;
      rep_id?: number | null;
      source_system?: string;
      external_name?: string;
      warehouse_channel?: 'DWS' | 'ALM' | 'Direct' | null;
    };

    // BUG-127: derive warehouse_channel from source_system when not explicitly
    // passed. Import Wizard "+ New Customer" calls this endpoint with
    // source_system={dws,alm,direct,vinsight,xero,...} — the first three map
    // to canonical warehouse channels. Other sources leave warehouse_channel
    // NULL until forward activity classifies them.
    const SOURCE_TO_WAREHOUSE: Record<string, 'DWS' | 'ALM' | 'Direct'> = {
      dws: 'DWS',
      alm: 'ALM',
      direct: 'Direct',
    };
    const resolvedWarehouseChannel: 'DWS' | 'ALM' | 'Direct' | null =
      warehouse_channel
      ?? (source_system ? SOURCE_TO_WAREHOUSE[source_system.toLowerCase()] ?? null : null);

    if (!name || !name.trim()) {
      return NextResponse.json({ error: 'Customer name is required' }, { status: 400 });
    }

    // BUG-165 (2026-05-12): embed NAME @ SUBURB form when suburb is provided.
    // Bare-name writes are a faucet that produces orphan customers + bare/at-form
    // twin pairs. Embedded form preserves uniqueness across cities + matches the
    // legacy access-DB convention (schema/060 line 107).
    const trimmedName = name.trim();
    const trimmedSuburb = suburb ? suburb.trim() : '';
    const embeddedName =
      trimmedSuburb.length > 0 && !trimmedName.includes(' @ ')
        ? `${trimmedName} @ ${trimmedSuburb.toUpperCase()}`
        : trimmedName;

    // Check for duplicate on embedded form
    const existing = await pool.query(
      'SELECT customer_id FROM customer WHERE LOWER(customer_name) = LOWER($1)',
      [embeddedName]
    );
    if (existing.rows.length > 0) {
      return NextResponse.json({
        error: `Customer "${embeddedName}" already exists`,
        customer_id: existing.rows[0].customer_id,
      }, { status: 409 });
    }

    // BUG-165 (2026-05-12): resolve canonical_customer_id via lookup-or-create
    // BEFORE the customer INSERT. L6 constraint customer_must_have_canonical
    // (schema/162, NOT VALID; future schema/163 VALIDATE) requires every new
    // customer row to carry a canonical link. Auto-create canonical when no
    // match — uses the same embedded NAME @ SUBURB form as customer_name so
    // canonical_customer.customer_name UNIQUE constraint (schema/012:71) holds.
    //
    // BUG-165 territory derive (2026-05-12): L6 constraint
    // canonical_customer_must_have_territory (schema/162:120, NOT VALID; future
    // schema/163 VALIDATE) REJECTS new inserts with territory_name IS NULL.
    // canonical_customer.territory_name is a STRING (schema/012:75) — derive it
    // from the territory_id input (customer.territory_id REFERENCES
    // territory(territory_id), schema/001:128). When territory_id is missing or
    // doesn't resolve, bake 'Unassigned' (conservative default per
    // review; do not block the write).
    let resolvedTerritoryName: string = 'Unassigned';
    if (territory_id) {
      const terrLookup = await pool.query<{ territory_name: string }>(
        'SELECT territory_name FROM territory WHERE territory_id = $1 LIMIT 1',
        [territory_id]
      );
      if (terrLookup.rows.length > 0 && terrLookup.rows[0].territory_name) {
        resolvedTerritoryName = terrLookup.rows[0].territory_name;
      } else {
        console.warn(
          `[/api/customers] POST: territory_id=${territory_id} not found in territory table — falling back to 'Unassigned' for canonical_customer.territory_name`
        );
      }
    }

    let canonicalCustomerId: number | null = null;
    const ccLookup = await pool.query<{ id: number }>(
      'SELECT id FROM canonical_customer WHERE LOWER(customer_name) = LOWER($1) LIMIT 1',
      [embeddedName]
    );
    if (ccLookup.rows.length > 0) {
      canonicalCustomerId = ccLookup.rows[0].id;
    } else {
      // Auto-create canonical_customer with the embedded name + any provided
      // metadata. Channel comes from resolvedWarehouseChannel (BUG-127 mapping).
      // territory_name set from resolvedTerritoryName to satisfy L6 NOT VALID.
      // ON CONFLICT no-op upsert fires RETURNING without overwriting an existing
      // row's territory_name — territory_name = EXCLUDED.territory_name is
      // deliberately omitted from the DO UPDATE SET clause so prior data wins.
      const ccInsert = await pool.query<{ id: number }>(
        `INSERT INTO canonical_customer (customer_name, channel, customer_group, territory_name)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (customer_name) DO UPDATE SET customer_name = EXCLUDED.customer_name
         RETURNING id`,
        [embeddedName, resolvedWarehouseChannel, customer_group || null, resolvedTerritoryName]
      );
      canonicalCustomerId = ccInsert.rows[0].id;
    }

    // Insert new customer (BUG-127: warehouse_channel preserves DWS/ALM/Direct
    // attribution at the explicit-source path; keeps customer.channel_id and
    // canonical_customer.channel as their orthogonal axes per ADR-017).
    // BUG-165 (2026-05-12): customer_name now embedded NAME @ SUBURB form +
    // canonical_customer_id SET — eliminates orphan-customer faucet.
    const result = await pool.query(
      `INSERT INTO customer (customer_name, canonical_customer_id, territory_id, customer_group, channel_id, suburb, postcode, rep_id, warehouse_channel)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       RETURNING customer_id, customer_name`,
      [embeddedName, canonicalCustomerId, territory_id || null, customer_group || null, channel_id || null, suburb || null, postcode || null, rep_id || null, resolvedWarehouseChannel]
    );

    const newCustomer = result.rows[0];

    // If source_system and external_name provided, create mapping
    if (source_system && external_name) {
      await pool.query(
        `INSERT INTO customer_code_map (customer_id, source_system, external_name)
         VALUES ($1, $2, $3)
         ON CONFLICT (source_system, external_name) DO UPDATE SET customer_id = $1`,
        [newCustomer.customer_id, source_system.toLowerCase(), external_name]
      );
    }

    return NextResponse.json({
      success: true,
      customer_id: newCustomer.customer_id,
      customer_name: newCustomer.customer_name,
    });
  } catch (err) {
    console.error('[/api/customers] POST error:', err);
    return NextResponse.json({ error: 'Failed to create customer' }, { status: 500 });
  }
}

import { tool } from 'ai';
import { z } from 'zod';
import getReadonlyPool from './db-readonly';

// Demo mirror: tool descriptions are sent to the model and must not name the
// real winery/ranges there — and the range examples must match the DB's
// (scrubbed) range names or the AI passes filters that match nothing.
const VIEW_ONLY = process.env.VIEW_ONLY === 'true';
const RANGE_EXAMPLES = VIEW_ONLY ? 'Ridgeview, Cellar Select, Ascent' : 'Moppity, Lock & Key, Escalier';

/**
 * 10 pre-built tool functions for Moppity AI Chat.
 * Each reuses SQL patterns from existing API routes.
 * All queries run against the read-only pool.
 */

// ─── 1. Margin Ranking ──────────────────────────────────────────────────

export const getMarginRanking = tool({
  description: 'Get wines ranked by gross profit percentage. Use for "highest margin wines", "most profitable wines", "best GP%". Can filter by range, channel, vintage, and choose economic vs accounting COGS.',
  inputSchema: z.object({
    limit: z.number().min(1).max(50).default(10).describe('Number of wines to return'),
    order: z.enum(['desc', 'asc']).default('desc').describe('desc = highest margin first, asc = lowest'),
    cogs_type: z.enum(['economic', 'accounting']).default('economic').describe('Which COGS to use for GP% calculation'),
    range_name: z.string().optional().describe(`Filter by wine range: ${RANGE_EXAMPLES}`),
    channel: z.string().optional().describe('Filter by channel: DWS, ALM, Direct'),
    vintage: z.number().optional().describe('Filter by vintage year'),
  }),
  execute: async ({ limit, order, cogs_type, range_name, channel, vintage }) => {
    const pool = getReadonlyPool();
    const conditions: string[] = ['s.variety IS NOT NULL', 'COALESCE(rev.total_revenue, 0) > 0'];
    const params: (string | number)[] = [];
    let paramIdx = 1;

    if (range_name) {
      conditions.push(`cs.range_name = $${paramIdx++}`);
      params.push(range_name);
    }
    if (vintage) {
      conditions.push(`s.vintage = $${paramIdx++}`);
      params.push(vintage);
    }

    const cogsExpr = cogs_type === 'economic'
      ? 'COALESCE(ecogs.avg_economic_cogs, s.transfer_cost, 0)'
      : 'COALESCE(s.transfer_cost, 0)';

    let channelJoin = '';
    if (channel) {
      channelJoin = `JOIN channel ch ON ch.channel_name = $${paramIdx++}`;
      params.push(channel);
      conditions.push(`EXISTS (
        SELECT 1 FROM sales_transaction st2
        JOIN channel c2 ON c2.channel_id = st2.channel_id
        WHERE st2.sku_id = s.sku_id AND c2.channel_name = $${paramIdx - 1}
        AND st2.sale_date >= CURRENT_DATE - interval '12 months'
      )`);
    }

    const result = await pool.query(`
      SELECT
        COALESCE(cs.sku_name, s.item_description) as wine_name,
        cs.range_name,
        s.variety,
        s.region,
        s.vintage,
        COALESCE(rev.total_revenue, 0)::numeric(12,2) as revenue,
        COALESCE(rev.total_qty, 0)::numeric(12,1) as cases,
        s.base_wholesale,
        ${cogsExpr} as cogs_per_unit,
        CASE WHEN COALESCE(rev.total_revenue, 0) > 0
          THEN ROUND(((rev.total_revenue - rev.total_qty * ${cogsExpr}) / rev.total_revenue * 100)::numeric, 1)
          ELSE 0
        END as gp_pct,
        (rev.total_revenue - rev.total_qty * ${cogsExpr})::numeric(12,2) as gross_profit
      FROM sku s
      LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
      LEFT JOIN LATERAL (
        SELECT SUM(st.net_revenue) as total_revenue, SUM(st.quantity) as total_qty
        FROM sales_transaction st
        WHERE st.sku_id = s.sku_id AND st.sale_date >= CURRENT_DATE - interval '12 months'
      ) rev ON true
      LEFT JOIN LATERAL (
        SELECT AVG(st.economic_cogs_per_unit) as avg_economic_cogs
        FROM sales_transaction st
        WHERE st.sku_id = s.sku_id AND st.sale_date >= CURRENT_DATE - interval '12 months'
          AND st.economic_cogs_per_unit IS NOT NULL
      ) ecogs ON true
      WHERE ${conditions.join(' AND ')}
      ORDER BY gp_pct ${order === 'desc' ? 'DESC' : 'ASC'}
      LIMIT ${limit}
    `, params);

    return {
      source: 'Margin Analysis',
      cogs_type,
      wines: result.rows.map(r => ({
        wine: r.wine_name,
        range: r.range_name,
        variety: r.variety,
        region: r.region,
        vintage: r.vintage,
        revenue: parseFloat(r.revenue),
        cases: parseFloat(r.cases),
        gp_pct: parseFloat(r.gp_pct),
        gross_profit: parseFloat(r.gross_profit),
        cogs_per_unit: parseFloat(r.cogs_per_unit),
      })),
    };
  },
});

// ─── 2. Sales Summary ────────────────────────────────────────────────────

export const getSalesSummary = tool({
  description: 'Get total sales metrics: revenue, cases sold, customer count, average order value. Use for "how are sales", "total revenue", "sales this year".',
  inputSchema: z.object({
    months: z.number().min(1).max(36).default(12).describe('Number of months to look back'),
    channel: z.string().optional().describe('Filter by channel: DWS, ALM, Direct'),
  }),
  execute: async ({ months, channel }) => {
    const pool = getReadonlyPool();
    const channelFilter = channel
      ? `AND EXISTS (SELECT 1 FROM channel c WHERE c.channel_id = st.channel_id AND c.channel_name = $1)`
      : '';
    const params = channel ? [channel] : [];

    const [current, prior] = await Promise.all([
      pool.query(`
        SELECT
          COALESCE(SUM(st.quantity), 0)::numeric(12,1) as total_cases,
          COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) as total_revenue,
          COUNT(DISTINCT st.customer_id) as active_customers,
          CASE WHEN COUNT(*) > 0
            THEN ROUND((SUM(st.net_revenue) / COUNT(*))::numeric, 2)
            ELSE 0 END as avg_order_value,
          COUNT(*) as total_transactions
        FROM sales_transaction st
        WHERE st.sale_date >= CURRENT_DATE - interval '${months} months'
        ${channelFilter}
      `, params),
      pool.query(`
        SELECT
          COALESCE(SUM(st.quantity), 0)::numeric(12,1) as total_cases,
          COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) as total_revenue,
          COUNT(DISTINCT st.customer_id) as active_customers
        FROM sales_transaction st
        WHERE st.sale_date >= CURRENT_DATE - interval '${months * 2} months'
          AND st.sale_date < CURRENT_DATE - interval '${months} months'
        ${channelFilter}
      `, params),
    ]);

    const c = current.rows[0];
    const p = prior.rows[0];
    const yoy = (curr: string, prev: string) => {
      const cv = parseFloat(curr) || 0;
      const pv = parseFloat(prev) || 0;
      return pv > 0 ? Math.round(((cv - pv) / pv) * 1000) / 10 : null;
    };

    return {
      source: 'Sales Analytics',
      period: `Last ${months} months`,
      channel: channel || 'All channels',
      total_revenue: parseFloat(c.total_revenue),
      revenue_yoy_pct: yoy(c.total_revenue, p.total_revenue),
      total_cases: parseFloat(c.total_cases),
      cases_yoy_pct: yoy(c.total_cases, p.total_cases),
      active_customers: parseInt(c.active_customers),
      avg_order_value: parseFloat(c.avg_order_value),
      total_transactions: parseInt(c.total_transactions),
    };
  },
});

// ─── 3. Sales by Customer ────────────────────────────────────────────────

export const getSalesByCustomer = tool({
  description: 'Get top customers by revenue or volume. Use for "best customers", "who buys the most", "top 10 customers".',
  inputSchema: z.object({
    limit: z.number().min(1).max(50).default(10),
    sort_by: z.enum(['revenue', 'cases']).default('revenue'),
    months: z.number().min(1).max(36).default(12),
    channel: z.string().optional().describe('Filter by channel: DWS, ALM, Direct'),
  }),
  execute: async ({ limit, sort_by, months, channel }) => {
    const pool = getReadonlyPool();
    const conditions = [`st.sale_date >= CURRENT_DATE - interval '${months} months'`];
    const params: string[] = [];
    let paramIdx = 1;

    if (channel) {
      conditions.push(`c.channel_name = $${paramIdx++}`);
      params.push(channel);
    }

    const result = await pool.query(`
      SELECT
        cu.customer_name,
        c.channel_name,
        COALESCE(t.territory_name, '') as territory,
        SUM(st.quantity)::numeric(10,1) as cases,
        SUM(st.net_revenue)::numeric(12,2) as revenue,
        COUNT(*) as transactions
      FROM sales_transaction st
      JOIN customer cu ON cu.customer_id = st.customer_id
      LEFT JOIN channel c ON c.channel_id = st.channel_id
      LEFT JOIN territory t ON t.territory_id = st.territory_id
      WHERE ${conditions.join(' AND ')}
      GROUP BY cu.customer_id, cu.customer_name, c.channel_name, COALESCE(t.territory_name, '')
      ORDER BY ${sort_by === 'revenue' ? 'SUM(st.net_revenue)' : 'SUM(st.quantity)'} DESC
      LIMIT ${limit}
    `, params);

    return {
      source: 'Sales Analytics — Customers',
      period: `Last ${months} months`,
      customers: result.rows.map(r => ({
        customer: r.customer_name,
        channel: r.channel_name,
        territory: r.territory,
        cases: parseFloat(r.cases),
        revenue: parseFloat(r.revenue),
        transactions: parseInt(r.transactions),
      })),
    };
  },
});

// ─── 4. Sales by Territory ───────────────────────────────────────────────

export const getSalesByTerritory = tool({
  description: 'Get territory performance with trend comparison. Use for "how is Sydney doing", "territory breakdown", "best performing regions".',
  inputSchema: z.object({
    months: z.number().min(1).max(24).default(6),
  }),
  execute: async ({ months }) => {
    const pool = getReadonlyPool();
    const result = await pool.query(`
      WITH current_period AS (
        SELECT
          COALESCE(t.territory_name, 'Unassigned') as territory,
          SUM(st.quantity)::numeric(10,1) as cases,
          SUM(st.net_revenue)::numeric(12,2) as revenue,
          CASE WHEN SUM(st.net_revenue) > 0
            THEN ROUND(((SUM(st.net_revenue) - COALESCE(SUM(
              COALESCE(st.economic_cogs_total, st.quantity * COALESCE(sk.transfer_cost, 0))
            ), 0)) / SUM(st.net_revenue) * 100)::numeric, 1)
            ELSE 0 END as gp_pct
        FROM sales_transaction st
        LEFT JOIN territory t ON t.territory_id = st.territory_id
        LEFT JOIN sku sk ON sk.sku_id = st.sku_id
        WHERE st.sale_date >= CURRENT_DATE - interval '${months} months'
        GROUP BY COALESCE(t.territory_name, 'Unassigned')
      ),
      prior_period AS (
        SELECT
          COALESCE(t.territory_name, 'Unassigned') as territory,
          SUM(st.net_revenue)::numeric(12,2) as revenue
        FROM sales_transaction st
        LEFT JOIN territory t ON t.territory_id = st.territory_id
        WHERE st.sale_date >= CURRENT_DATE - interval '${months * 2} months'
          AND st.sale_date < CURRENT_DATE - interval '${months} months'
        GROUP BY COALESCE(t.territory_name, 'Unassigned')
      )
      SELECT
        cp.territory, cp.cases, cp.revenue, cp.gp_pct,
        CASE WHEN COALESCE(pp.revenue, 0) > 0
          THEN ROUND(((cp.revenue - pp.revenue) / pp.revenue * 100)::numeric, 1)
          ELSE NULL END as trend_pct
      FROM current_period cp
      LEFT JOIN prior_period pp ON pp.territory = cp.territory
      ORDER BY cp.revenue DESC
    `);

    return {
      source: 'Sales Analytics — Territory',
      period: `Last ${months} months vs prior ${months} months`,
      territories: result.rows.map(r => ({
        territory: r.territory,
        cases: parseFloat(r.cases),
        revenue: parseFloat(r.revenue),
        gp_pct: parseFloat(r.gp_pct),
        trend_pct: r.trend_pct !== null ? parseFloat(r.trend_pct) : null,
      })),
    };
  },
});

// ─── 5. Inventory Status ─────────────────────────────────────────────────

export const getInventoryStatus = tool({
  description: 'Get current stock levels, velocity, and runout projections. Use for "what\'s running low", "stock levels", "inventory", "how much Shiraz do we have".',
  inputSchema: z.object({
    sort_by: z.enum(['stock', 'velocity', 'cover', 'runout']).default('stock').describe('Sort order: stock (units), velocity (sales rate), cover (months remaining), runout (earliest first)'),
    low_stock_only: z.boolean().default(false).describe('Only show wines with less than 3 months cover'),
    variety: z.string().optional().describe('Filter by grape variety'),
    limit: z.number().min(1).max(100).default(20),
  }),
  execute: async ({ sort_by, low_stock_only, variety, limit }) => {
    const pool = getReadonlyPool();
    // Bridge: staging.StockItemCode -> canonical_sku_code_map (vinsight) -> canonical_sku
    // Sales velocity comes from the canonical-level sku (sku_id = canonical_sku_id) where
    // sales_transaction.sku_id rows aggregate across all vintages of the same wine.
    const params: string[] = [];
    let paramIdx = 1;
    const varietyFilter = variety
      ? `AND s_canon.variety ILIKE $${paramIdx++}`
      : '';
    if (variety) params.push(`%${variety}%`);

    const result = await pool.query(`
      WITH inv AS (
        SELECT
          cs.id as canonical_sku_id,
          cs.sku_name as wine_name,
          cs.range_name,
          SUM((si.raw_data->>'UnitsInStock')::numeric) as units_in_stock,
          STRING_AGG(DISTINCT si.raw_data->>'StockItemCode', ', ' ORDER BY si.raw_data->>'StockItemCode') as sku_codes
        FROM staging_vinsight_stock_items si
        JOIN canonical_sku_code_map cscm
          ON cscm.external_code = si.raw_data->>'StockItemCode'
         AND cscm.source_system = 'vinsight'
        JOIN canonical_sku cs ON cs.id = cscm.canonical_sku_id
        WHERE (si.raw_data->>'IsPackagedWine')::boolean = true
          AND (si.raw_data->>'UnitsInStock')::numeric > 0
        GROUP BY cs.id, cs.sku_name, cs.range_name
      ),
      vel AS (
        SELECT
          s.canonical_sku_id,
          CASE WHEN COUNT(DISTINCT date_trunc('month', st.sale_date)) > 0
            THEN SUM(st.quantity) / COUNT(DISTINCT date_trunc('month', st.sale_date))
            ELSE 0 END as velocity_12m
        FROM sales_transaction st
        JOIN sku s ON s.sku_id = st.sku_id
        WHERE st.sale_date >= CURRENT_DATE - interval '12 months'
          AND s.canonical_sku_id IS NOT NULL
          AND s.sku_id = s.canonical_sku_id
        GROUP BY s.canonical_sku_id
      )
      SELECT
        inv.canonical_sku_id,
        inv.wine_name,
        inv.range_name,
        inv.sku_codes,
        s_canon.variety,
        s_canon.region,
        s_canon.vintage,
        inv.units_in_stock::numeric(12,1) as units_in_stock,
        COALESCE(vel.velocity_12m, 0)::numeric(10,1) as velocity_12m,
        CASE WHEN COALESCE(vel.velocity_12m, 0) > 0
          THEN ROUND((inv.units_in_stock / vel.velocity_12m)::numeric, 1)
          ELSE NULL END as months_cover,
        CASE WHEN COALESCE(vel.velocity_12m, 0) > 0
          THEN (CURRENT_DATE + ((inv.units_in_stock / vel.velocity_12m) * 30)::integer)
          ELSE NULL END as projected_runout
      FROM inv
      LEFT JOIN vel ON vel.canonical_sku_id = inv.canonical_sku_id
      LEFT JOIN sku s_canon ON s_canon.sku_id = inv.canonical_sku_id
      WHERE 1=1 ${varietyFilter}
      ${low_stock_only ? "AND COALESCE(vel.velocity_12m, 0) > 0 AND (inv.units_in_stock / vel.velocity_12m) < 3" : ''}
    `, params);

    const sorted = result.rows.sort((a, b) => {
      switch (sort_by) {
        case 'stock': return parseFloat(b.units_in_stock) - parseFloat(a.units_in_stock);
        case 'velocity': return (parseFloat(b.velocity_12m) || 0) - (parseFloat(a.velocity_12m) || 0);
        case 'cover': return (parseFloat(a.months_cover) || 999) - (parseFloat(b.months_cover) || 999);
        case 'runout': return (a.projected_runout || '9999').toString().localeCompare((b.projected_runout || '9999').toString());
        default: return 0;
      }
    }).slice(0, limit);

    return {
      source: 'Inventory & Bottling',
      total_items: result.rows.length,
      showing: sorted.length,
      stock: sorted.map(r => ({
        wine: r.wine_name,
        sku_codes: r.sku_codes,
        variety: r.variety,
        range: r.range_name,
        units_in_stock: parseFloat(r.units_in_stock),
        velocity_per_month: parseFloat(r.velocity_12m),
        months_cover: r.months_cover ? parseFloat(r.months_cover) : null,
        projected_runout: r.projected_runout,
      })),
    };
  },
});

// ─── 6. Wine Profile ─────────────────────────────────────────────────────

export const getWineProfile = tool({
  description: 'Get detailed information about a specific wine: COGS, composition, traceability, sales history. Use for "tell me about [wine]", "what\'s in the Shiraz", "details on Lock & Key Chardonnay". Sales are tracked per canonical wine (not per vintage), so a vintage in the query is informational — revenue/GP returned is blended across all vintages of that wine.',
  inputSchema: z.object({
    search: z.string().describe('Wine name, SKU code, or variety to search for'),
  }),
  execute: async ({ search }) => {
    const pool = getReadonlyPool();

    // Strip a 4-digit vintage out of the search so wine-name matching against the
    // canonical-level sku still works (canonical sku_name has no vintage suffix).
    const vintageMatch = search.match(/\b(19|20)\d{2}\b/);
    const requestedVintage = vintageMatch ? parseInt(vintageMatch[0], 10) : null;
    const cleanedSearch = search.replace(/\b(19|20)\d{2}\b/g, '').replace(/\s+/g, ' ').trim();
    const pattern = `%${cleanedSearch || search}%`;

    // Sales aggregate at canonical-level sku (sku_id = canonical_sku_id). All sales_transaction
    // rows reference these "rolled-up" skus, never the per-vintage sku rows (which carry
    // staging-side Vinsight item codes like MVLKSHZB16 but have 0 sales).
    const matchResult = await pool.query(`
      SELECT s.sku_id, s.sku_code, s.item_description, s.variety, s.region, s.vintage,
        s.base_wholesale, s.transfer_cost, s.canonical_sku_id,
        cs.sku_name as canonical_sku_name, cs.range_name,
        COALESCE(rev.revenue, 0)::numeric(12,2) as revenue_12m,
        COALESCE(rev.qty, 0)::numeric(10,1) as qty_12m,
        COALESCE(econ.avg_econ, 0)::numeric(12,4) as economic_cogs_per_unit,
        CASE WHEN COALESCE(rev.revenue, 0) > 0
          THEN ROUND(((rev.revenue - rev.qty * COALESCE(s.transfer_cost, 0)) / rev.revenue * 100)::numeric, 1)
          ELSE 0 END as gp_pct_accounting,
        CASE WHEN COALESCE(rev.revenue, 0) > 0
          THEN ROUND(((rev.revenue - rev.qty * COALESCE(NULLIF(s.transfer_cost, 0), econ.avg_econ, 0)) / rev.revenue * 100)::numeric, 1)
          ELSE 0 END as gp_pct_economic
      FROM sku s
      LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
      LEFT JOIN LATERAL (
        SELECT SUM(net_revenue) as revenue, SUM(quantity) as qty
        FROM sales_transaction WHERE sku_id = s.sku_id AND sale_date >= CURRENT_DATE - interval '12 months'
      ) rev ON true
      LEFT JOIN LATERAL (
        SELECT AVG(economic_cogs_per_unit) as avg_econ
        FROM sales_transaction WHERE sku_id = s.sku_id AND economic_cogs_per_unit IS NOT NULL
      ) econ ON true
      WHERE s.canonical_sku_id IS NOT NULL
        AND s.sku_id = s.canonical_sku_id
        AND (
          s.item_description ILIKE $1
          OR s.sku_code ILIKE $1
          OR s.variety ILIKE $1
          OR cs.sku_name ILIKE $1
        )
      ORDER BY COALESCE(rev.revenue, 0) DESC
      LIMIT 5
    `, [pattern]);

    if (matchResult.rows.length === 0) {
      return { source: 'Wine Profile', error: `No wines found matching "${search}"` };
    }

    const wines = matchResult.rows.map(r => ({
      sku_code: r.sku_code,
      name: r.canonical_sku_name || r.item_description,
      range: r.range_name,
      variety: r.variety,
      region: r.region,
      vintage: r.vintage,
      requested_vintage: requestedVintage,
      vintage_note: requestedVintage
        ? `Sales are aggregated per canonical wine, not per vintage — revenue/GP shown is blended across all vintages of ${r.canonical_sku_name || r.item_description}.`
        : undefined,
      base_wholesale: parseFloat(r.base_wholesale) || 0,
      transfer_cost: parseFloat(r.transfer_cost) || 0,
      economic_cogs: parseFloat(r.economic_cogs_per_unit) || 0,
      gp_pct_accounting: parseFloat(r.gp_pct_accounting),
      gp_pct_economic: parseFloat(r.gp_pct_economic),
      revenue_12m: parseFloat(r.revenue_12m),
      cases_12m: parseFloat(r.qty_12m),
    }));

    return { source: 'Wine Profile', wines };
  },
});

// ─── 7. Channel Comparison ───────────────────────────────────────────────

export const getChannelComparison = tool({
  description: 'Compare sales across DWS, ALM, and Direct channels. Use for "channel breakdown", "DWS vs Direct", "which channel is biggest".',
  inputSchema: z.object({
    months: z.number().min(1).max(36).default(12),
  }),
  execute: async ({ months }) => {
    const pool = getReadonlyPool();
    const result = await pool.query(`
      SELECT
        c.channel_name,
        SUM(st.net_revenue)::numeric(12,2) as revenue,
        SUM(st.quantity)::numeric(10,1) as cases,
        COUNT(DISTINCT st.customer_id) as customers,
        COUNT(*) as transactions,
        CASE WHEN SUM(st.net_revenue) > 0
          THEN ROUND(((SUM(st.net_revenue) - COALESCE(SUM(
            COALESCE(st.economic_cogs_total, st.quantity * COALESCE(sk.transfer_cost, 0))
          ), 0)) / SUM(st.net_revenue) * 100)::numeric, 1)
          ELSE 0 END as gp_pct
      FROM sales_transaction st
      JOIN channel c ON c.channel_id = st.channel_id
      LEFT JOIN sku sk ON sk.sku_id = st.sku_id
      WHERE st.sale_date >= CURRENT_DATE - interval '${months} months'
      GROUP BY c.channel_name
      ORDER BY SUM(st.net_revenue) DESC
    `);

    const total = result.rows.reduce((sum, r) => sum + parseFloat(r.revenue), 0);

    return {
      source: 'Sales Analytics — Channels',
      period: `Last ${months} months`,
      total_revenue: total,
      channels: result.rows.map(r => ({
        channel: r.channel_name,
        revenue: parseFloat(r.revenue),
        share_pct: total > 0 ? Math.round(parseFloat(r.revenue) / total * 1000) / 10 : 0,
        cases: parseFloat(r.cases),
        customers: parseInt(r.customers),
        gp_pct: parseFloat(r.gp_pct),
      })),
    };
  },
});

// ─── 8. Price Analysis ───────────────────────────────────────────────────

export const getPriceAnalysis = tool({
  description: 'Get pricing information: wholesale prices, transfer costs, grape costs per wine. Use for "pricing", "what do we charge", "cost breakdown".',
  inputSchema: z.object({
    range_name: z.string().optional().describe('Filter by wine range'),
    variety: z.string().optional().describe('Filter by grape variety'),
    sort_by: z.enum(['wholesale', 'transfer_cost', 'revenue']).default('revenue'),
  }),
  execute: async ({ range_name, variety, sort_by }) => {
    const pool = getReadonlyPool();
    const conditions = ['s.variety IS NOT NULL', 's.base_wholesale > 0'];
    const params: string[] = [];
    let paramIdx = 1;

    if (range_name) {
      conditions.push(`cs.range_name = $${paramIdx++}`);
      params.push(range_name);
    }
    if (variety) {
      conditions.push(`s.variety ILIKE $${paramIdx++}`);
      params.push(`%${variety}%`);
    }

    const orderMap: Record<string, string> = {
      wholesale: 's.base_wholesale DESC',
      transfer_cost: 's.transfer_cost DESC NULLS LAST',
      revenue: 'COALESCE(rev.total_revenue, 0) DESC',
    };

    const result = await pool.query(`
      SELECT
        COALESCE(cs.sku_name, s.item_description) as wine_name,
        cs.range_name, s.variety, s.vintage,
        s.base_wholesale,
        s.transfer_cost,
        COALESCE(ecogs.avg_econ, 0)::numeric(12,4) as economic_cogs,
        COALESCE(rev.total_revenue, 0)::numeric(12,2) as revenue_12m,
        COALESCE(rev.total_qty, 0)::numeric(10,1) as cases_12m
      FROM sku s
      LEFT JOIN canonical_sku cs ON cs.id = s.canonical_sku_id
      LEFT JOIN LATERAL (
        SELECT SUM(net_revenue) as total_revenue, SUM(quantity) as total_qty
        FROM sales_transaction WHERE sku_id = s.sku_id AND sale_date >= CURRENT_DATE - interval '12 months'
      ) rev ON true
      LEFT JOIN LATERAL (
        SELECT AVG(economic_cogs_per_unit) as avg_econ
        FROM sales_transaction WHERE sku_id = s.sku_id AND economic_cogs_per_unit IS NOT NULL
      ) ecogs ON true
      WHERE ${conditions.join(' AND ')}
      ORDER BY ${orderMap[sort_by]}
      LIMIT 30
    `, params);

    return {
      source: 'Price Analysis',
      wines: result.rows.map(r => ({
        wine: r.wine_name,
        range: r.range_name,
        variety: r.variety,
        vintage: r.vintage,
        base_wholesale: parseFloat(r.base_wholesale),
        transfer_cost: parseFloat(r.transfer_cost) || 0,
        economic_cogs: parseFloat(r.economic_cogs),
        revenue_12m: parseFloat(r.revenue_12m),
        cases_12m: parseFloat(r.cases_12m),
      })),
    };
  },
});

// ─── 9. DWS Reconciliation ──────────────────────────────────────────────

export const getDwsReconciliation = tool({
  description: 'Get DWS consignment stock reconciliation: producer stock vs DWS sell-through, code mappings. Use for "DWS reconciliation", "consignment stock", "DWS inventory".',
  inputSchema: z.object({}),
  execute: async () => {
    const pool = getReadonlyPool();
    const [inventory, kpis] = await Promise.all([
      pool.query(`
        SELECT
          cs.sku_name,
          STRING_AGG(DISTINCT dws_map.external_code, ', ') as dws_codes,
          STRING_AGG(DISTINCT s.sku_code, ', ') as mv_codes,
          COALESCE(SUM(DISTINCT stock.units_in_stock), 0)::numeric(10,1) as mv_stock,
          COALESCE(SUM(CASE WHEN st.sale_date >= CURRENT_DATE - interval '3 months' THEN st.quantity ELSE 0 END), 0)::numeric(10,1) as dws_qty_3m,
          COALESCE(SUM(CASE WHEN st.sale_date >= CURRENT_DATE - interval '3 months' THEN st.net_revenue ELSE 0 END), 0)::numeric(10,2) as dws_revenue_3m,
          COALESCE(SUM(st.net_revenue), 0)::numeric(10,2) as dws_total_revenue,
          MAX(st.sale_date) as last_sale
        FROM canonical_sku cs
        JOIN sku s ON s.canonical_sku_id = cs.id
        JOIN sku_code_map dws_map ON dws_map.sku_id = s.sku_id AND dws_map.source_system = 'dws'
        LEFT JOIN sales_transaction st ON st.sku_id = s.sku_id
          AND EXISTS (SELECT 1 FROM channel c WHERE c.channel_id = st.channel_id AND c.channel_name = 'DWS')
        LEFT JOIN LATERAL (
          SELECT (si.raw_data->>'UnitsInStock')::numeric as units_in_stock
          FROM staging_vinsight_stock_items si
          WHERE si.raw_data->>'StockItemCode' = s.sku_code
            AND (si.raw_data->>'IsPackagedWine')::boolean = true
          LIMIT 1
        ) stock ON true
        GROUP BY cs.id, cs.sku_name
        ORDER BY COALESCE(SUM(st.net_revenue), 0) DESC
      `),
      pool.query(`
        SELECT
          (SELECT COALESCE(SUM(st.net_revenue), 0)::numeric(12,2) FROM sales_transaction st
           JOIN channel c ON c.channel_id = st.channel_id WHERE c.channel_name = 'DWS'
           AND st.sale_date >= CURRENT_DATE - interval '12 months') as dws_revenue_12m,
          (SELECT COALESCE(SUM(st.quantity), 0)::numeric(10,1) FROM sales_transaction st
           JOIN channel c ON c.channel_id = st.channel_id WHERE c.channel_name = 'DWS'
           AND st.sale_date >= CURRENT_DATE - interval '12 months') as dws_cases_12m
      `),
    ]);

    const k = kpis.rows[0];
    return {
      source: 'DWS Reconciliation',
      dws_revenue_12m: parseFloat(k.dws_revenue_12m),
      dws_cases_12m: parseFloat(k.dws_cases_12m),
      products: inventory.rows.map(r => ({
        product: r.sku_name,
        dws_codes: r.dws_codes,
        moppity_codes: r.mv_codes,
        moppity_stock: parseFloat(r.mv_stock),
        dws_qty_3m: parseFloat(r.dws_qty_3m),
        dws_revenue_3m: parseFloat(r.dws_revenue_3m),
        dws_total_revenue: parseFloat(r.dws_total_revenue),
        last_sale: r.last_sale,
      })),
    };
  },
});

// ─── 10. Overview KPIs ──────────────────────────────────────────────────

export const getOverviewKpis = tool({
  description: 'Get high-level business metrics: revenue, gross profit, active SKUs, inventory value. Use for "how\'s the business", "overview", "dashboard summary".',
  inputSchema: z.object({}),
  execute: async () => {
    const pool = getReadonlyPool();
    const result = await pool.query(`
      SELECT
        (SELECT COALESCE(SUM(net_revenue), 0) FROM sales_transaction
         WHERE sale_date >= date_trunc('month', CURRENT_DATE - interval '1 month')
           AND sale_date < date_trunc('month', CURRENT_DATE))::numeric(12,2) as revenue_prev_month,
        (SELECT COALESCE(SUM(st.net_revenue), 0) - COALESCE(SUM(
          COALESCE(st.economic_cogs_total, st.quantity * COALESCE(sk.transfer_cost, 0))
        ), 0) FROM sales_transaction st
         LEFT JOIN sku sk ON sk.sku_id = st.sku_id
         WHERE st.sale_date >= date_trunc('month', CURRENT_DATE - interval '1 month')
           AND st.sale_date < date_trunc('month', CURRENT_DATE))::numeric(12,2) as gross_profit_prev_month,
        (SELECT COALESCE(SUM(net_revenue), 0) FROM sales_transaction
         WHERE sale_date >= CURRENT_DATE - interval '12 months')::numeric(12,2) as revenue_12m,
        (SELECT COUNT(DISTINCT sku_id) FROM sales_transaction
         WHERE sale_date >= CURRENT_DATE - interval '90 days') as active_skus,
        (SELECT ROUND(SUM((raw_data->>'UnitsInStock')::numeric * (raw_data->>'StandardCost')::numeric)::numeric, 0)
         FROM staging_vinsight_stock_items
         WHERE (raw_data->>'IsPackagedWine')::boolean = true
           AND (raw_data->>'UnitsInStock')::numeric > 0) as inventory_value,
        (SELECT ROUND(SUM((raw_data->>'UnitsInStock')::numeric)::numeric, 0)
         FROM staging_vinsight_stock_items
         WHERE (raw_data->>'IsPackagedWine')::boolean = true
           AND (raw_data->>'UnitsInStock')::numeric > 0) as total_cases_in_stock
    `);

    const r = result.rows[0];
    const revenue = parseFloat(r.revenue_prev_month);
    const gp = parseFloat(r.gross_profit_prev_month);

    return {
      source: 'Overview Dashboard',
      revenue_prev_month: revenue,
      gross_profit_prev_month: gp,
      gp_margin_pct: revenue > 0 ? Math.round(gp / revenue * 1000) / 10 : 0,
      revenue_12m: parseFloat(r.revenue_12m),
      active_skus: parseInt(r.active_skus),
      inventory_value: parseInt(r.inventory_value) || 0,
      total_cases_in_stock: parseInt(r.total_cases_in_stock) || 0,
    };
  },
});

// ─── Export all tools ────────────────────────────────────────────────────

export const aiTools = {
  get_margin_ranking: getMarginRanking,
  get_sales_summary: getSalesSummary,
  get_sales_by_customer: getSalesByCustomer,
  get_sales_by_territory: getSalesByTerritory,
  get_inventory_status: getInventoryStatus,
  get_wine_profile: getWineProfile,
  get_channel_comparison: getChannelComparison,
  get_price_analysis: getPriceAnalysis,
  get_dws_reconciliation: getDwsReconciliation,
  get_overview_kpis: getOverviewKpis,
};

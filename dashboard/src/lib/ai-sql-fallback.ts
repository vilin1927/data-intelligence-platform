import { tool } from 'ai';
import { z } from 'zod';
import getReadonlyPool from './db-readonly';

/**
 * SQL fallback tool for AI Chat.
 * Allows free-form SELECT queries on whitelisted tables.
 * 5 layers of security: auth middleware, rate limiting, read-only role, SQL validation, query timeout + row limit.
 */

// Tables the AI is allowed to query in the VIEW_ONLY demo mirror.
// proven-masked tables/views. This is the app-level backstop for
// /api/chat run_sql_query; the DB grant on moppity_readonly is the deeper
// backstop. Enforcement is gated on VIEW_ONLY below, so the live editor
// (flag unset) keeps its current unrestricted behavior — zero change.
// Exported so /api/browse can share the same list (§2.2).
export const DEMO_READABLE_TABLES = [
  'canonical_customer',
  'customer',
  'canonical_representative',
  'representative',
  'sales_transaction',
  'sales_transaction_normalized',
  'combined_data_enriched',
  'sku',
  'canonical_sku',
  // wholesale_price intentionally excluded — DB grant denies it to the readonly
  // role (public trade price = factor-recovery anchor). Keep app allowlist in
  // sync with demo-grants.sql (27 tables).
  'master_cogs',
  'sku_cogs',
  'territory',
  'canonical_territory',
  'channel',
  'packaging_operation',
  'v_customer_with_codes',
  'customer_alias',
  'customer_code_map',
  'salesperson_code_map',
  'month_end_snapshot',
  'tbl_customer_performance_17',
  'tbl_temp_customers',
  'tbl_samples_territory',
  'tbl_analysis_report',
  'alm_edi_segment_52',
  'staging_vinsight_stock_items',
  'au_postcode',
] as const;

const WHITELISTED_TABLES = new Set<string>(DEMO_READABLE_TABLES);

// Dangerous SQL keywords that must be rejected
const FORBIDDEN_PATTERNS = [
  /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|GRANT|REVOKE|CREATE|EXECUTE|COPY|LOAD)\b/i,
  /;\s*$/,                     // trailing semicolons (prevent multi-statement)
  /;\s*\S/,                    // semicolons followed by more SQL
  /--/,                        // SQL comments
  /\/\*/,                      // block comments
  /\bINTO\s+OUTFILE\b/i,      // file writes
  /\bpg_read_file\b/i,        // Postgres file functions
  /\bpg_write_file\b/i,
  /\blo_import\b/i,
  /\blo_export\b/i,
  /\bDBLINK\b/i,
  /\bCOPY\s/i,
];

const ROW_LIMIT = 500;

/**
 * Extract the table/view names a query reads from (targets of FROM / JOIN).
 * Best-effort static parse: strips string literals and the FROM/IN keywords
 * that live *inside* function calls (EXTRACT(.. FROM ..), SUBSTRING, TRIM,
 * POSITION, OVERLAY) so those don't get mistaken for table references, then
 * pulls the identifier after each FROM/JOIN. Schema qualifiers and quotes are
 * stripped. CTE names (WITH x AS (...)) are excluded — they're not tables.
 */
export function extractTableRefs(sql: string): string[] {
  // 1. Remove single-quoted string literals (a FROM inside a string is noise).
  let cleaned = sql.replace(/'(?:[^']|'')*'/g, "''");
  // 2. Remove function bodies that legally contain the FROM/IN keywords, so
  //    e.g. EXTRACT(YEAR FROM sale_date) does not read `sale_date` as a table.
  cleaned = cleaned.replace(/\b(?:extract|substring|trim|position|overlay)\s*\([^()]*\)/gi, ' ');

  // 3. Collect CTE names so `FROM <cte>` is not flagged as an unknown table.
  const cteNames = new Set<string>();
  const cteRe = /(?:\bwith\b|,)\s+("?[A-Za-z_][A-Za-z0-9_]*"?)\s+as\s*\(/gi;
  let cteMatch: RegExpExecArray | null;
  while ((cteMatch = cteRe.exec(cleaned)) !== null) {
    cteNames.add(cteMatch[1].replace(/"/g, '').toLowerCase());
  }

  // 4. Pull the identifier after every FROM / JOIN.
  const refs: string[] = [];
  const refRe = /\b(?:from|join)\s+("?[A-Za-z_][A-Za-z0-9_."]*"?)/gi;
  let m: RegExpExecArray | null;
  while ((m = refRe.exec(cleaned)) !== null) {
    // strip quotes, keep the part after the last dot (drops schema qualifier)
    const raw = m[1].replace(/"/g, '').toLowerCase();
    const name = raw.split('.').pop() || raw;
    if (name && !cteNames.has(name)) refs.push(name);
  }
  return refs;
}

/**
 * Validate a SQL query for safety.
 * Returns null if safe, or an error message if rejected.
 */
export function validateSQL(sql: string): string | null {
  const trimmed = sql.trim();

  // Must start with SELECT or WITH
  if (!/^\s*(SELECT|WITH)\b/i.test(trimmed)) {
    return 'Only SELECT queries are allowed.';
  }

  // Check for forbidden patterns
  for (const pattern of FORBIDDEN_PATTERNS) {
    if (pattern.test(trimmed)) {
      return `Query contains forbidden pattern: ${pattern.source}`;
    }
  }

  // VIEW_ONLY demo mirror: enforce the table allowlist (DENY-by-default).
  // App-level backstop for the DB grant on moppity_readonly. Active whenever
  // VIEW_ONLY=true, regardless of DEMO_CHAT_ENABLED. Live editor (flag unset)
  // => this block is skipped, so behavior is unchanged.
  if (process.env.VIEW_ONLY === 'true') {
    const refs = extractTableRefs(trimmed);
    const blocked = refs.find((t) => !WHITELISTED_TABLES.has(t));
    if (blocked) {
      return `Query references a table that is not available in this demo: ${blocked}`;
    }
  }

  return null;
}

export const runSqlQuery = tool({
  description: `Run a read-only SQL SELECT query on the wine business database. Use this as a LAST RESORT when no other tool can answer the question.

Available tables: sku, sales_transaction, customer, canonical_sku, grape_price_rule, channel, territory, representative, vessel, wine_batch, packaging_operation, packaging_vessel, sku_code_map, canonical_customer, canonical_territory, staging_vinsight_stock_items, sale_vintage_attribution, etl_run_log. Range data lives on canonical_sku.range_name / range_group (there is no separate range table).

Key columns: sku(sku_id, sku_code, item_description, variety, region, vintage, base_wholesale, transfer_cost, canonical_sku_id), sales_transaction(transaction_id, sku_id, customer_id, channel_id, territory_id, sale_date, quantity, unit_price, net_revenue, economic_cogs_per_unit, economic_cogs_total), customer(customer_id, customer_name), channel(channel_id, channel_name).

RESPONSE RULES (apply to every reply you write back to the user after running this tool):
- Refer to tables in plain English. Say "Customers" not "canonical_customer", "Sales" not "sales_transaction", "Wines" or "SKUs" not "canonical_sku", "Territories" not "canonical_territory", "Reps" not "representative". Never expose raw table names or column names in user-visible prose.
- Never mention internal identifiers in your reply. No ticket numbers (e.g. ADR-###, BUG-###, JC-###, JR-###, JF-###, INFRA-###, SEC-###), no schema file paths (e.g. schema/123_*.sql), no audit-doc paths.
- Never describe internal architecture or migration mechanics (e.g. "forward-only with audit trail", "shadow swap", "cascade", "preserve invariant", "matview", "staging table"). Speak in business terms (customers, wines, sales, channels, territories, reps, costs, margins).
- The SQL itself may use the real table and column names — that's required to query the database. But when you write the natural-language answer for the user, translate everything to plain business language.`,
  inputSchema: z.object({
    sql: z.string().describe('The SELECT query to run'),
    explanation: z.string().describe('Brief explanation of what this query does and why'),
  }),
  execute: async ({ sql, explanation }): Promise<{
    source: string;
    explanation: string;
    error: string | null;
    columns: string[];
    rows: Record<string, unknown>[];
    row_count: number;
    truncated: boolean;
  }> => {
    // Validate
    const validationError = validateSQL(sql);
    if (validationError) {
      return { source: 'SQL Query', error: validationError, explanation, columns: [], rows: [], row_count: 0, truncated: false };
    }

    // Inject LIMIT if not present
    let safeSql = sql.trim().replace(/;+\s*$/, '');
    if (!/\bLIMIT\b/i.test(safeSql)) {
      safeSql += ` LIMIT ${ROW_LIMIT}`;
    }

    const pool = getReadonlyPool();
    try {
      const result = await pool.query(safeSql);
      return {
        source: 'SQL Query',
        explanation,
        error: null,
        columns: result.fields.map(f => f.name),
        rows: result.rows.slice(0, ROW_LIMIT),
        row_count: result.rowCount || 0,
        truncated: (result.rowCount || 0) > ROW_LIMIT,
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Query execution failed';
      return { source: 'SQL Query', error: message, explanation, columns: [], rows: [], row_count: 0, truncated: false };
    }
  },
});

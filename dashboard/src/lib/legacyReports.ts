/**
 * B10b — Legacy Access Reports allowlist.
 *
 * Hard-coded list of the 14 Postgres tables created by
 * `schema/104_b10b_legacy_access_reports.sql`. Both the `/api/legacy-reports`
 * index endpoint and the `/api/legacy-reports/[table]` drill endpoint use
 * this list as a SQL-injection guard — table names cannot be parameterized
 * in `SELECT * FROM <ident>` queries, so we validate against the allowlist
 * before interpolating.
 *
 * `displayName` is the friendly label rendered on the index page; the
 * `accessName` field is the original Access table name, useful for cross-
 * referencing with extract-accdb.md and `mdb-export` calls.
 */

export interface LegacyReport {
  /** Postgres table name (snake_case, prefix `tbl_`) — used in SQL. */
  tableName: string;
  /** Original Access table name (preserved verbatim from mdb-tables). */
  accessName: string;
  /** Human-readable label for the index UI. */
  displayName: string;
  /** Short description rendered as a tooltip / sub-line on the index page. */
  description: string;
}

export const LEGACY_REPORTS: readonly LegacyReport[] = [
  {
    tableName: 'tbl_analysis_report',
    accessName: 'tblAnalysisReport',
    displayName: 'Analysis Report',
    description: 'Territory totals: cases, wholesale, discount, profit, GP%.',
  },
  {
    tableName: 'tbl_distribution_by_range_16',
    accessName: 'tblDistributionByRange_16',
    displayName: 'Distribution by Range (16 brands)',
    description: 'Per-brand distribution counts (16-brand cut). Empty in Access.',
  },
  {
    tableName: 'tbl_distribution_by_range_nd18',
    accessName: 'tblDistributionByRangeND18',
    displayName: 'Distribution by Range — New (ND18)',
    description: 'New-distribution by range, 18-brand cut.',
  },
  {
    tableName: 'tbl_distribution_by_range_td18',
    accessName: 'tblDistributionByRangeTD18',
    displayName: 'Distribution by Range — Total (TD18)',
    description: 'Total distribution by range, 18-brand cut.',
  },
  {
    tableName: 'tbl_distribution_by_range_ld18',
    accessName: 'tblDistributionByRangeLD18',
    displayName: 'Distribution by Range — Lost (LD18)',
    description: 'Lost-distribution by range, 18-brand cut.',
  },
  {
    tableName: 'tbl_top10_opportunities_territory_11a',
    accessName: 'tblTop10OpportunitiesTerritory_11a',
    displayName: 'Top-10 Opportunities — Territory',
    description: 'Top-10 territory opportunities by SKU (cases).',
  },
  {
    tableName: 'tbl_top10_opportunities_whole_11a',
    accessName: 'tblTop10OpportunitiesWhole_11a',
    displayName: 'Top-10 Opportunities — Wholesale',
    description: 'Top-10 wholesale opportunities by SKU (cases).',
  },
  {
    tableName: 'tbl_territory_distribution_performance_report',
    accessName: 'TerritoryDistributionPerformanceReport',
    displayName: 'Territory Distribution Performance',
    description: 'Territory perf with TY/LY MTD+YTD + AC distribution metrics.',
  },
  {
    tableName: 'tbl_customer_performance_17',
    accessName: 'tblCustomerPerformance_17',
    displayName: 'Customer Performance',
    description: 'Customer MAT/MTD/MQT with growth + range. Empty in Access.',
  },
  {
    tableName: 'tbl_samples_territory',
    accessName: 'tblSamplesTerritory',
    displayName: 'Samples by Territory',
    description: 'Sample tracking by rep + territory + group.',
  },
  {
    tableName: 'tbl_xtbl_select_territory',
    accessName: 'xtblSelectTerritory',
    displayName: 'Territory Selector',
    description: 'Selector lookup row used by Access territory filter.',
  },
  {
    tableName: 'tbl_dir_not_found_reps',
    accessName: 'tblDIRNotFoundReps',
    displayName: 'Direct — Not-Found Reps',
    description: 'Direct-channel rep mismatch log.',
  },
  {
    tableName: 'tbl_xtbl_sales_by_range_chart',
    accessName: 'xtblSalesByRangeChart',
    displayName: 'Sales by Range — Chart',
    description: 'Per-range monthly sales by venue (Direct/HOffice/Hybrid/Off-Prem/On-Prem/Wholesale).',
  },
  {
    tableName: 'tbl_xtbl_sales_by_range_total_chart',
    accessName: 'xtblSalesByRangeTotalChart',
    displayName: 'Sales by Range — Total Chart',
    description: 'Total monthly sales by venue (totals across ranges).',
  },
] as const;

/**
 * Set form for O(1) allowlist guards in API routes.
 */
export const LEGACY_REPORT_TABLE_NAMES: ReadonlySet<string> = new Set(
  LEGACY_REPORTS.map(r => r.tableName)
);

/**
 * Lookup by Postgres table name.
 */
export function findLegacyReport(tableName: string): LegacyReport | undefined {
  return LEGACY_REPORTS.find(r => r.tableName === tableName);
}

-- ════════════════════════════════════════════════════════════════════════════
-- schema/105_b10b_sno_text.sql
-- Bundle B10b — fix sno column type on 2 sales-by-range chart tables
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-28
--
-- Problem: schema/104 declared `sno NUMERIC` on tbl_xtbl_sales_by_range_chart
-- and tbl_xtbl_sales_by_range_total_chart, but the Access source data has
-- year-month strings like "2022 01" / "2023 01" (NOT numbers). The COPY
-- import failed mid-run on prod 2026-04-28 11:25 UTC: "invalid input syntax
-- for type numeric: '2022 01'" — tables were empty, so ALTER is trivial.
--
-- current data_type — only runs the ALTER if the column is still NUMERIC.
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  current_type TEXT;
BEGIN
  -- tbl_xtbl_sales_by_range_chart
  SELECT data_type INTO current_type
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name = 'tbl_xtbl_sales_by_range_chart'
     AND column_name = 'sno';

  IF current_type IS NULL THEN
    RAISE NOTICE 'schema/105: tbl_xtbl_sales_by_range_chart.sno absent — skipping';
  ELSIF current_type = 'numeric' THEN
    ALTER TABLE tbl_xtbl_sales_by_range_chart
      ALTER COLUMN sno TYPE TEXT;
    RAISE NOTICE 'schema/105: tbl_xtbl_sales_by_range_chart.sno NUMERIC -> TEXT';
  ELSE
    RAISE NOTICE 'schema/105: tbl_xtbl_sales_by_range_chart.sno already %, skipping', current_type;
  END IF;

  -- tbl_xtbl_sales_by_range_total_chart
  SELECT data_type INTO current_type
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name = 'tbl_xtbl_sales_by_range_total_chart'
     AND column_name = 'sno';

  IF current_type IS NULL THEN
    RAISE NOTICE 'schema/105: tbl_xtbl_sales_by_range_total_chart.sno absent — skipping';
  ELSIF current_type = 'numeric' THEN
    ALTER TABLE tbl_xtbl_sales_by_range_total_chart
      ALTER COLUMN sno TYPE TEXT;
    RAISE NOTICE 'schema/105: tbl_xtbl_sales_by_range_total_chart.sno NUMERIC -> TEXT';
  ELSE
    RAISE NOTICE 'schema/105: tbl_xtbl_sales_by_range_total_chart.sno already %, skipping', current_type;
  END IF;
END $$;

INSERT INTO schema_migrations (version, applied_at)
VALUES ('105_b10b_sno_text', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

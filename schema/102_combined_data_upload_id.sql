-- ════════════════════════════════════════════════════════════════════════════
-- schema/102_combined_data_upload_id.sql
-- Bundle B8 — Chronological upload ID on sales_transaction
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-28
-- JC:     JC-507 — Combined Data needs chronological upload ID
--
-- Purpose:
--   Add `upload_batch_id` BIGINT column on sales_transaction with FK to
--   upload_batch (B12 schema/097). Existing rows stay NULL — they predate the
--   upload pipeline. Going forward, every B12 upload populates this on insert
--   so /legacy-data + /api/export/combined-data can render an ImportID per
--   row, and the owner can sort/filter by chronological upload batch per channel.
--
--   The view (schema/101) reads this column NULL-safe via to_jsonb so it
--   already projects `import_id` even before this migration runs. Once 102
--   lands, the view picks up actual values without re-running schema/101.
--
-- Forward-only ALTER ADD. NULL by default. No row rewrites.
--
-- BLAST RADIUS: sales_transaction (~120,977 rows). One nullable BIGINT col +
--   one partial index on (warehouse, upload_batch_id) for chronological
--   per-channel sorts.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-condition assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.sales_transaction') IS NULL THEN
        RAISE EXCEPTION 'sales_transaction missing; schema/001 must land first';
    END IF;
    IF to_regclass('public.upload_batch') IS NULL THEN
        RAISE EXCEPTION 'upload_batch missing; B12 schema/097 must land first';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. ALTER TABLE — add nullable FK column
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE sales_transaction
    ADD COLUMN IF NOT EXISTS upload_batch_id BIGINT;

-- FK constraint (NOT VALID skipped — table is small enough to validate fully).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
         WHERE table_schema='public'
           AND table_name='sales_transaction'
           AND constraint_name='sales_transaction_upload_batch_id_fkey'
    ) THEN
        ALTER TABLE sales_transaction
            ADD CONSTRAINT sales_transaction_upload_batch_id_fkey
            FOREIGN KEY (upload_batch_id)
            REFERENCES upload_batch(upload_batch_id)
            ON DELETE SET NULL;
    END IF;
END $$;

COMMENT ON COLUMN sales_transaction.upload_batch_id IS
  'B8 JC-507 (2026-04-28): chronological upload provenance per row. FK to '
  'upload_batch (B12). NULL for historical rows imported before the upload '
  'pipeline existed; populated by every new B12 batch on insert. Surfaced in '
  'combined_data_enriched.import_id (Access "ImportID" col 41).';

-- Partial index for chronological per-channel sorts (warehouse + upload_batch).
-- WHERE clause keeps it cheap — only indexes rows where the FK is populated.
-- Wrapped in DO so we can fall back to a single-col index if the warehouse
-- column predates the deploy (e.g. on a fresh DB that never applied the JF-15
-- migration). Both indexes are forward-compatible.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public'
           AND table_name='sales_transaction'
           AND column_name='warehouse'
    ) THEN
        CREATE INDEX IF NOT EXISTS idx_sales_transaction_warehouse_upload_batch
            ON sales_transaction (warehouse, upload_batch_id)
            WHERE upload_batch_id IS NOT NULL;
    ELSE
        CREATE INDEX IF NOT EXISTS idx_sales_transaction_upload_batch
            ON sales_transaction (upload_batch_id)
            WHERE upload_batch_id IS NOT NULL;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-state assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_col_exists BOOLEAN;
    v_fk_exists  BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='sales_transaction'
           AND column_name='upload_batch_id'
    ) INTO v_col_exists;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
         WHERE table_schema='public' AND table_name='sales_transaction'
           AND constraint_name='sales_transaction_upload_batch_id_fkey'
    ) INTO v_fk_exists;

    IF NOT v_col_exists THEN
        RAISE EXCEPTION 'sales_transaction.upload_batch_id missing post-ALTER';
    END IF;
    IF NOT v_fk_exists THEN
        RAISE EXCEPTION 'sales_transaction_upload_batch_id_fkey missing post-ALTER';
    END IF;

    RAISE NOTICE 'B8 schema/102 OK: sales_transaction.upload_batch_id added (NULL for historical rows).';
END $$;

INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('102_b8_combined_data_upload_id', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Verification (run manually after apply):
--   \d sales_transaction
--   -- Expect: upload_batch_id BIGINT (nullable) + FK to upload_batch.
--
--   SELECT count(*) FROM sales_transaction WHERE upload_batch_id IS NOT NULL;
--   -- Expect: 0 immediately post-deploy. Increments per B12 upload.
--
--   SELECT import_id, count(*) FROM combined_data_enriched
--    GROUP BY import_id ORDER BY import_id NULLS LAST LIMIT 5;
--   -- Expect: one NULL group of ~120,977 rows pre-upload; per-batch groups
--   -- after each B12 run.
--
-- ROLLBACK recipe (NOT part of this migration — documentation only):
--   ALTER TABLE sales_transaction DROP CONSTRAINT IF EXISTS
--     sales_transaction_upload_batch_id_fkey;
--   DROP INDEX IF EXISTS idx_sales_transaction_warehouse_upload_batch;
--   ALTER TABLE sales_transaction DROP COLUMN IF EXISTS upload_batch_id;
--   DELETE FROM schema_migrations WHERE version = '102_b8_combined_data_upload_id';
-- ════════════════════════════════════════════════════════════════════════════

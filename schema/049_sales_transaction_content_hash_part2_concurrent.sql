-- Migration 049 part 2: UNIQUE INDEX CONCURRENTLY + NOT NULL.
--
-- BUG-110 AC3 / Phase K0. Runs AFTER part 1 has backfilled every existing
-- row's content_hash. No BEGIN/COMMIT: CREATE INDEX CONCURRENTLY is not
-- permitted inside a transaction block. Each statement auto-commits.
--
-- If part 1's backfill produced a duplicate content_hash across two rows,
-- CREATE UNIQUE INDEX CONCURRENTLY will FAIL and leave an INVALID index in
-- pg_index. Detection procedure if that happens:
--   SELECT content_hash, count(*) FROM sales_transaction
--    GROUP BY content_hash HAVING count(*) > 1;
-- Then decide: (a) collapse the duplicates via a manual de-dup migration
-- and re-run part 2, or (b) widen the hash input columns (requires
-- re-running part 1). Do NOT force the index — that masks data-quality
-- issues.
--
-- idx_sales_tx_content_hash naming follows the schema/025 convention
-- (`idx_sales_tx_*`). IF NOT EXISTS is defensive — re-running this file
-- after a partial failure should be safe.

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_sales_tx_content_hash
    ON sales_transaction(content_hash);

ALTER TABLE sales_transaction
    ALTER COLUMN content_hash SET NOT NULL;

COMMENT ON COLUMN sales_transaction.content_hash IS
    'SHA256 (hex) of pipe-joined (source_system, source_ref, sale_date, '
    'customer_id, sku_id, quantity, net_revenue). Idempotency key: ETL '
    're-runs use ON CONFLICT (content_hash) DO NOTHING to avoid duplicates. '
    'See schema/049_sales_transaction_content_hash_part1.sql for hash recipe '
    'and the list of columns deliberately excluded from the hash.';

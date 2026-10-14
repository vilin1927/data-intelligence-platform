-- schema/111_r011_recon_dedup_and_unique.sql
-- R-011 (run5 RC-DEAD-LETTER-REPLAY) cleanup + BUG-159 UNIQUE constraint.
--
-- Background: 2026-04-30 re-run of etl/recon_etl_access_to_sales.py was
-- intended to recover 35 MVESSHZH14 dead-letter rows (now resolvable since
-- canonical_sku.id=111 exists). It did recover them — distinct source_ref
-- count went from 120,308 to 120,343 (matches HARD CombinedData). But it
-- ALSO inserted 303 NEW rows for source_refs that already existed in
-- sales_transaction. Cause: between the original 2026-03-29 load and today,
-- customer_master got refined (canonical_customer dedup work; customers
-- like "Customer 13" got new customer_id rows alongside the older
-- "CUSTOMER 13"). The ETL's customer lookup picks the latest, so the
-- new rows have a different customer_id (linked to the same
-- canonical_customer_id) → different content_hash → ON CONFLICT
-- (content_hash) DO NOTHING did NOT fire → fresh INSERT.
--
-- Result: 303 source_refs now have 2 rows each in sales_transaction.
-- Total = 120,646 (was 120,308; should be 120,343). 303 extras to clean.
--
-- This migration:
--   1. DELETEs the newer row of each dup pair (keep older = preserve
--      whatever warehouse / economic_cogs / upload_batch_id values were
--      backfilled into the original load — recon ETL leaves those NULL).
--   2. ADDs UNIQUE(source_system, source_ref) constraint to prevent this
--      class of duplicate from recurring (this is BUG-159's fix, landing
--      opportunistically here).
--   3. Spot-verified: each dup pair's two rows have different customer_id
--      but the SAME canonical_customer_id. Functionally equivalent for
--      reporting (which aggregates by canonical). KEEP older = no data
--      loss + preserves NULL warehouse status quo (R-001 will fix that).

BEGIN;

-- Pre-state assertions
DO $$
DECLARE
    total_count INT;
    distinct_refs INT;
    dup_pairs INT;
BEGIN
    SELECT count(*) INTO total_count FROM sales_transaction WHERE source_system='access_db';
    SELECT count(DISTINCT source_ref) INTO distinct_refs FROM sales_transaction WHERE source_system='access_db';
    SELECT count(*) INTO dup_pairs FROM (
        SELECT source_ref FROM sales_transaction
        WHERE source_system='access_db'
        GROUP BY source_ref HAVING count(*) > 1
    ) sub;

    IF total_count != 120646 THEN
        RAISE EXCEPTION 'PRE-STATE FAIL: total access_db rows=% (expected 120646)', total_count;
    END IF;
    IF distinct_refs != 120343 THEN
        RAISE EXCEPTION 'PRE-STATE FAIL: distinct source_refs=% (expected 120343)', distinct_refs;
    END IF;
    IF dup_pairs != 303 THEN
        RAISE EXCEPTION 'PRE-STATE FAIL: dup_pairs=% (expected 303)', dup_pairs;
    END IF;
    RAISE NOTICE 'PRE-STATE OK: total=120646, distinct=120343, dup_pairs=303';
END $$;

-- DELETE the newer row of each dup pair (keep oldest transaction_id)
WITH ranked AS (
    SELECT
        transaction_id,
        row_number() OVER (PARTITION BY source_ref ORDER BY transaction_id ASC) AS rn
    FROM sales_transaction
    WHERE source_system = 'access_db'
      AND source_ref IN (
          SELECT source_ref FROM sales_transaction
          WHERE source_system='access_db'
          GROUP BY source_ref HAVING count(*) > 1
      )
)
DELETE FROM sales_transaction
WHERE transaction_id IN (SELECT transaction_id FROM ranked WHERE rn > 1);

-- Post-state: dup pairs gone, distinct count preserved at HARD target
DO $$
DECLARE
    total_count INT;
    distinct_refs INT;
    dup_pairs INT;
BEGIN
    SELECT count(*) INTO total_count FROM sales_transaction WHERE source_system='access_db';
    SELECT count(DISTINCT source_ref) INTO distinct_refs FROM sales_transaction WHERE source_system='access_db';
    SELECT count(*) INTO dup_pairs FROM (
        SELECT source_ref FROM sales_transaction
        WHERE source_system='access_db'
        GROUP BY source_ref HAVING count(*) > 1
    ) sub;

    IF total_count != 120343 THEN
        RAISE EXCEPTION 'POST-STATE FAIL: total access_db rows=% (expected 120343)', total_count;
    END IF;
    IF distinct_refs != 120343 THEN
        RAISE EXCEPTION 'POST-STATE FAIL: distinct source_refs=% (expected 120343)', distinct_refs;
    END IF;
    IF dup_pairs != 0 THEN
        RAISE EXCEPTION 'POST-STATE FAIL: dup_pairs=% (expected 0)', dup_pairs;
    END IF;
    RAISE NOTICE 'POST-STATE OK: total=120343, distinct=120343, dup_pairs=0';
END $$;

-- BUG-159: ADD UNIQUE(source_system, source_ref) to prevent recurrence
-- across all source_systems. Verified pre-apply that no current dups exist
-- in DWS / ALM / Vinsight / Y&R (only access_db had them, just cleaned).
ALTER TABLE sales_transaction
ADD CONSTRAINT sales_transaction_source_system_source_ref_uniq
UNIQUE (source_system, source_ref);

-- Record migration
INSERT INTO schema_migrations (version, applied_at)
VALUES ('111_r011_recon_dedup_and_unique', now())
ON CONFLICT (version) DO NOTHING;

COMMIT;

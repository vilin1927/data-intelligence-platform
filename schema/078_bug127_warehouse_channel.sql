-- =============================================================================
-- Moppity Vineyards — BUG-127 warehouse_channel column (078_bug127_warehouse_channel.sql)
-- =============================================================================
-- Date:      2026-04-25
-- Author:    Vladimir (Autoflux) + Sprint 1 session
-- Ticket:    BUG-127 AC1 + AC2 + AC4 (AC3 already done — F.4 RECONCILED_COLUMNS interim)
--            orthogonal taxonomies (parallel to ADR-016 historical/forward boundary)
--
-- WHY THIS EXISTS
-- ---------------
-- BUG-127 surfaced via F.5 dry-run (2026-04-22): the data model conflates two
-- orthogonal channel concepts on `customer.channel_id`:
--   D1 sales/warehouse channel — DWS / ALM / Direct (commercial model).
--                                Lives on `channel` table (3 rows) and
--                                `customer.channel_id` FK + `sales_transaction.channel_id`.
--   D2 venue type             — ON PREMISE / OFF PREMISE / WHOLESALE / DIRECT / HYBRID.
--                                Lives on `canonical_customer.channel` (varchar 100).
--
-- The F.4 reconcile path was paused on the channel column (BUG-127 AC3) because
-- canonical.channel (venue values) cannot fill customer.channel_id (warehouse FK).
-- Phase E default per strategy doc: add `customer.warehouse_channel` VARCHAR(20)
-- as an explicit warehouse-channel attribute on customer table; keep
-- canonical_customer.channel as the venue dimension. Two columns, two concepts,
-- two future-proof axes.
--
-- BACKFILL RULE (Vladimir + Mini-CTO concur required before apply)
-- ----------------------------------------------------------------
-- Priority order (sales-dominant primary, code-presence fallback, NULL otherwise):
--   1. Sales-derived dominant channel — most rows in sales_transaction per
--      customer. Tie-broken by row count desc, then channel_name asc.
--   2. Existing customer.channel_id FK (if set).
--   3. canonical_customer code-presence (only when sales-derived + channel_id
--      both empty AND customer is linked to canonical):
--      - has ynr_customer_code AND no alm_customer_code → 'DWS' (Y&R = DWS legacy)
--      - has alm_customer_code AND no ynr_customer_code → 'ALM'
--      - has dir_customer_code only                     → 'Direct'
--      - both ynr AND alm (ambiguous)                   → NULL
--   4. NULL otherwise.
--
-- DEVIATION FROM PROMPT'S LITERAL "else 'Direct'" RULE
-- ----------------------------------------------------
-- literal "else Direct" rule would fabricate ~6,408 spurious 'Direct' labels
-- for legacy zero-sales no-code customers (10,816 NULL channel_id rows; only
-- 316 customers actually transact via Direct per sales_transaction). Sales-
-- dominant + NULL fallback gives the owner an honest "no signal" state on
-- /reference for unknown customers, instead of misclassified 'Direct'.
-- Vladimir confirmed sales-derived approach 2026-04-25.
--
-- TRANSACTION + PRE/POST ASSERTIONS
-- ---------------------------------
-- BEGIN; pre-asserts current state matches expected (10,973 rows; column
-- absent); ALTER TABLE ADD COLUMN + CHECK constraint; backfill via CTE;
-- post-asserts bucket sums add up; INSERT schema_migrations; COMMIT.
-- ROLLBACK if any assertion fails.
--
-- IDEMPOTENT
-- ----------
-- ADD COLUMN IF NOT EXISTS makes the schema change idempotent. The backfill
-- UPDATE has WHERE warehouse_channel IS NULL so re-running won't overwrite
-- prior assignments. Re-applying the migration on a partially-populated
-- table is safe.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PRE-state assertion: confirm prod matches expected state.
-- =============================================================================

DO $$
DECLARE
  v_total INT;
  v_existing_channel INT;
  v_canonical INT;
  v_column_exists BOOL;
BEGIN
  SELECT COUNT(*), COUNT(*) FILTER (WHERE channel_id IS NOT NULL)
    INTO v_total, v_existing_channel FROM customer;
  SELECT COUNT(*) INTO v_canonical FROM canonical_customer;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'customer'
       AND column_name = 'warehouse_channel'
  ) INTO v_column_exists;

  RAISE NOTICE 'BUG-127 PRE: customer_total=% existing_channel_id=% canonical_customer=% warehouse_channel_column_exists=%',
    v_total, v_existing_channel, v_canonical, v_column_exists;

  IF v_total < 10800 OR v_total > 11200 THEN
    RAISE EXCEPTION 'BUG-127 PRE: unexpected customer count % (expected ~10973)', v_total;
  END IF;

  IF v_canonical < 4000 OR v_canonical > 4100 THEN
    RAISE EXCEPTION 'BUG-127 PRE: unexpected canonical_customer count % (expected ~4014)', v_canonical;
  END IF;
END;
$$;

-- =============================================================================
-- 2. ALTER TABLE ADD COLUMN + CHECK constraint.
-- =============================================================================

ALTER TABLE customer ADD COLUMN IF NOT EXISTS warehouse_channel VARCHAR(20) NULL;

-- CHECK constraint (idempotent via DO block — ALTER TABLE ADD CONSTRAINT
-- doesn't have IF NOT EXISTS in PG14, so guard explicitly).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'customer_warehouse_channel_check'
       AND conrelid = 'public.customer'::regclass
  ) THEN
    ALTER TABLE customer ADD CONSTRAINT customer_warehouse_channel_check
      CHECK (warehouse_channel IS NULL
             OR warehouse_channel IN ('DWS','ALM','Direct'));
  END IF;
END;
$$;

COMMENT ON COLUMN customer.warehouse_channel IS
  'Sales/warehouse channel: DWS (consignment) / ALM (wholesale) / Direct '
  '(direct invoice). Orthogonal to canonical_customer.channel (venue type: '
  'ON/OFF Premise). Backfilled BUG-127 schema/078 sales-dominant primary, '
  'code-presence fallback, NULL when no signal. Forward writes via '
  '/api/customers POST + transform_to_core.py + backfill_vinsight_contact_'
  'enrichment.py + import_dws/alm/direct paths preserve the invariant. '
  'Constraint: warehouse_channel IS NULL OR IN (DWS, ALM, Direct). See '
  'ADR-017 + internal notes.';

-- =============================================================================
-- 3. Backfill (sales-dominant primary, code-presence fallback, NULL otherwise).
--    Idempotent via WHERE warehouse_channel IS NULL — re-running won't
--    overwrite prior assignments.
-- =============================================================================

WITH sales_dom AS (
  SELECT
    raw.customer_id,
    (array_agg(raw.channel_name ORDER BY raw.n DESC, raw.channel_name))[1]
      AS dominant_channel
  FROM (
    SELECT st.customer_id, ch.channel_name, COUNT(*) AS n
    FROM sales_transaction st
    JOIN channel ch ON ch.channel_id = st.channel_id
    GROUP BY st.customer_id, ch.channel_name
  ) raw
  GROUP BY raw.customer_id
),
backfill AS (
  SELECT
    c.customer_id,
    COALESCE(
      sd.dominant_channel,
      ch.channel_name,
      CASE
        WHEN cc.ynr_customer_code IS NOT NULL AND cc.ynr_customer_code <> ''
         AND (cc.alm_customer_code IS NULL OR cc.alm_customer_code = '')
        THEN 'DWS'
        WHEN cc.alm_customer_code IS NOT NULL AND cc.alm_customer_code <> ''
         AND (cc.ynr_customer_code IS NULL OR cc.ynr_customer_code = '')
        THEN 'ALM'
        WHEN cc.dir_customer_code IS NOT NULL AND cc.dir_customer_code <> ''
         AND (cc.alm_customer_code IS NULL OR cc.alm_customer_code = '')
         AND (cc.ynr_customer_code IS NULL OR cc.ynr_customer_code = '')
        THEN 'Direct'
        ELSE NULL
      END
    ) AS new_warehouse_channel
  FROM customer c
  LEFT JOIN sales_dom sd ON sd.customer_id = c.customer_id
  LEFT JOIN channel ch ON ch.channel_id = c.channel_id
  LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
)
UPDATE customer c
SET warehouse_channel = b.new_warehouse_channel
FROM backfill b
WHERE c.customer_id = b.customer_id
  AND b.new_warehouse_channel IS NOT NULL
  AND c.warehouse_channel IS NULL;

-- =============================================================================
-- 4. POST-state assertion: bucket sums add up; CHECK constraint passes.
-- =============================================================================

DO $$
DECLARE
  v_dws INT;
  v_alm INT;
  v_direct INT;
  v_null INT;
  v_total INT;
  v_invalid INT;
  v_ambiguous_zero_sales INT;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE warehouse_channel = 'DWS'),
    COUNT(*) FILTER (WHERE warehouse_channel = 'ALM'),
    COUNT(*) FILTER (WHERE warehouse_channel = 'Direct'),
    COUNT(*) FILTER (WHERE warehouse_channel IS NULL),
    COUNT(*),
    COUNT(*) FILTER (WHERE warehouse_channel IS NOT NULL
                       AND warehouse_channel NOT IN ('DWS','ALM','Direct'))
  INTO v_dws, v_alm, v_direct, v_null, v_total, v_invalid
  FROM customer;

  -- Audit count: ambiguous zero-sales canonical-linked customers (left NULL on
  -- purpose). Logged for transparency — Mini-CTO can cross-check.
  SELECT COUNT(*) INTO v_ambiguous_zero_sales
  FROM customer c
  LEFT JOIN canonical_customer cc ON cc.id = c.canonical_customer_id
  WHERE c.warehouse_channel IS NULL
    AND cc.alm_customer_code IS NOT NULL AND cc.alm_customer_code <> ''
    AND cc.ynr_customer_code IS NOT NULL AND cc.ynr_customer_code <> ''
    AND NOT EXISTS (
      SELECT 1 FROM sales_transaction st WHERE st.customer_id = c.customer_id
    );

  RAISE NOTICE 'BUG-127 POST: dws=% alm=% direct=% null=% total=% invalid_values=% ambiguous_zero_sales_left_null=%',
    v_dws, v_alm, v_direct, v_null, v_total, v_invalid, v_ambiguous_zero_sales;

  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'BUG-127 POST: % rows have warehouse_channel outside DWS/ALM/Direct/NULL — CHECK constraint must have been bypassed.', v_invalid;
  END IF;

  IF (v_dws + v_alm + v_direct + v_null) <> v_total THEN
    RAISE EXCEPTION 'BUG-127 POST: bucket sum mismatch (dws+alm+direct+null=%, total=%)',
      (v_dws + v_alm + v_direct + v_null), v_total;
  END IF;

  IF v_total < 10800 OR v_total > 11200 THEN
    RAISE EXCEPTION 'BUG-127 POST: customer count drift, got %', v_total;
  END IF;

  -- Sanity: at least the 1,942-DWS sales-active customers should land DWS.
  IF v_dws < 1500 THEN
    RAISE EXCEPTION 'BUG-127 POST: DWS bucket too small (% rows; expected ≥1500 from sales-derived backfill)', v_dws;
  END IF;

  -- Sanity: Direct should not be >2,000 (sales=316 + dir-only-zero-sales~1,261).
  IF v_direct > 2500 THEN
    RAISE EXCEPTION 'BUG-127 POST: Direct bucket too large (% rows; expected <2500 — fabricated label leak?)', v_direct;
  END IF;
END;
$$;

-- =============================================================================
-- 5. Record migration in schema_migrations (idempotent).
-- =============================================================================

INSERT INTO schema_migrations (version, source)
VALUES ('078_bug127_warehouse_channel', 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- =============================================================================
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- =============================================================================
-- This migration adds a column + backfills. To revert (NOT recommended once
-- forward writers depend on it):
--   ALTER TABLE customer DROP CONSTRAINT IF EXISTS customer_warehouse_channel_check;
--   ALTER TABLE customer DROP COLUMN IF EXISTS warehouse_channel;
--   DELETE FROM schema_migrations WHERE version = '078_bug127_warehouse_channel';
-- For instant pre-apply restore: pg_restore -d moppity_db /var/backups/moppity/full_pre_bug127.pgdump

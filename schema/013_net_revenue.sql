-- =============================================================================
-- Moppity Vineyards -- Actual Net Revenue (013_net_revenue.sql)
-- =============================================================================
-- Version:   1.0
-- Created:   2026-03-27
-- Author:    Vladimir (Autoflux)
-- Milestone: M3-09 (Actual Net Revenue: Rebates, Discounts, Fees)
-- References: OWNER-FEEDBACK-MAR24.md F4, CALL-RESPONSE-MAR25.md item 8
--
-- The owner's reconciliation xlsx confirms:
--   Net $/Case = Wholesale Value Ex - Rebate Total - Discount Total - Wholesaler Fee Total
--   Example: $78.13 - $6.25 - $3.87 - $2.87 = $65.14
--
-- This migration:
--   1. Adds gross_revenue column (= quantity * unit_price, the "Wholesale Value Ex" total)
--   2. Backfills gross_revenue for ALL existing rows
--   3. Backfills rebate_amount, discount_amount, wholesale_fee from access_combined_data
--      JSONB for historical Access DB rows where these were previously zero/missing
--   4. Recalculates net_revenue = gross_revenue - discount_amount - rebate_amount - wholesale_fee
--
-- Idempotent: uses ADD COLUMN IF NOT EXISTS, updates are safe to re-run.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Add gross_revenue column if it doesn't exist
-- ---------------------------------------------------------------------------
ALTER TABLE sales_transaction ADD COLUMN IF NOT EXISTS gross_revenue NUMERIC(12,2);

COMMENT ON COLUMN sales_transaction.gross_revenue IS 'Gross revenue before deductions (quantity * unit_price). Corresponds to Access DB "Wholesale Value Ex" total.';

-- ---------------------------------------------------------------------------
-- 2. Backfill gross_revenue for all existing rows
-- ---------------------------------------------------------------------------
-- gross_revenue = quantity * unit_price (the wholesale value before deductions)
UPDATE sales_transaction
SET gross_revenue = quantity * unit_price
WHERE gross_revenue IS NULL
  AND unit_price IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Backfill rebate/discount/fee from Access DB staging data
-- ---------------------------------------------------------------------------
-- The transform_to_core.py extracted Discount and Rebate from access_combined_data
-- but hardcoded wholesale_fee to 0. Also, some rows have Discount/Rebate in raw_data
-- that weren't properly extracted. This pass fixes all of them.
--
-- Access DB raw_data keys (from CombinedData table):
--   "Discount"           -> per-case discount amount
--   "Rebate"             -> per-case rebate amount
--   "WholesalerFee"      -> per-case wholesaler fee
--   "WholesaleValueExEx" -> unit_price (wholesale value per case, ex GST ex WET)
--
-- IMPORTANT: sales_transaction.transaction_id = access_combined_data.id (1:1 mapping)
-- for all source_system = 'access_db' rows (confirmed in schema/005_fix_orphaned_skus.sql)

-- Pass 3a: Backfill discount_amount from Access DB where currently 0/NULL
UPDATE sales_transaction st
SET discount_amount = COALESCE(
    (ac.raw_data->>'Discount')::numeric,
    0
)
FROM access_combined_data ac
WHERE st.transaction_id = ac.id
  AND st.source_system = 'access_db'
  AND (st.discount_amount IS NULL OR st.discount_amount = 0)
  AND ac.raw_data->>'Discount' IS NOT NULL
  AND ac.raw_data->>'Discount' != ''
  AND ac.raw_data->>'Discount' != '0';

-- Pass 3b: Backfill rebate_amount from Access DB where currently 0/NULL
UPDATE sales_transaction st
SET rebate_amount = COALESCE(
    (ac.raw_data->>'Rebate')::numeric,
    0
)
FROM access_combined_data ac
WHERE st.transaction_id = ac.id
  AND st.source_system = 'access_db'
  AND (st.rebate_amount IS NULL OR st.rebate_amount = 0)
  AND ac.raw_data->>'Rebate' IS NOT NULL
  AND ac.raw_data->>'Rebate' != ''
  AND ac.raw_data->>'Rebate' != '0';

-- Pass 3c: Backfill wholesale_fee from Access DB (was previously hardcoded to 0)
-- NOTE: Access DB 'WholesalerFee' is a per-case fee, but some rows contain bulk totals.
-- Cap at $100/case to prevent bulk totals from corrupting net_revenue.
UPDATE sales_transaction st
SET wholesale_fee = LEAST(
    COALESCE((ac.raw_data->>'WholesalerFee')::numeric, 0),
    100.0
)
FROM access_combined_data ac
WHERE st.transaction_id = ac.id
  AND st.source_system = 'access_db'
  AND (st.wholesale_fee IS NULL OR st.wholesale_fee = 0)
  AND ac.raw_data->>'WholesalerFee' IS NOT NULL
  AND ac.raw_data->>'WholesalerFee' != ''
  AND ac.raw_data->>'WholesalerFee' != '0';

-- ---------------------------------------------------------------------------
-- 4. Recalculate net_revenue for all Access DB rows
-- ---------------------------------------------------------------------------
-- Formula: net_revenue = gross_revenue - discount_amount - rebate_amount - wholesale_fee
-- Only for access_db rows to avoid disrupting DWS/ALM/Direct imports that may have
-- already calculated net_revenue correctly from their source data.

UPDATE sales_transaction
SET net_revenue = COALESCE(gross_revenue, quantity * unit_price, 0)
              - COALESCE(discount_amount, 0)
              - COALESCE(rebate_amount, 0)
              - COALESCE(wholesale_fee, 0)
WHERE source_system = 'access_db'
  AND unit_price IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Also recalculate net_revenue for DWS/ALM/Direct rows to ensure consistency
-- ---------------------------------------------------------------------------
-- These channels already compute net_revenue in their importers, but we should
-- ensure gross_revenue is populated and the formula is consistent going forward.

UPDATE sales_transaction
SET net_revenue = COALESCE(gross_revenue, quantity * unit_price, 0)
              - COALESCE(discount_amount, 0)
              - COALESCE(rebate_amount, 0)
              - COALESCE(wholesale_fee, 0)
WHERE source_system IN ('DWS', 'ALM', 'DIRECT')
  AND gross_revenue IS NOT NULL;

COMMIT;

-- =============================================================================
-- Verification queries
-- =============================================================================

-- Check gross_revenue population
SELECT source_system,
       COUNT(*) as total_rows,
       COUNT(gross_revenue) as has_gross,
       COUNT(discount_amount) FILTER (WHERE discount_amount > 0) as has_discount,
       COUNT(rebate_amount) FILTER (WHERE rebate_amount > 0) as has_rebate,
       COUNT(wholesale_fee) FILTER (WHERE wholesale_fee > 0) as has_fee,
       ROUND(AVG(net_revenue)::numeric, 2) as avg_net_revenue
FROM sales_transaction
GROUP BY source_system
ORDER BY source_system;

-- Spot-check: net_revenue = gross - discount - rebate - fee
SELECT transaction_id, source_system,
       gross_revenue,
       discount_amount,
       rebate_amount,
       wholesale_fee,
       net_revenue,
       ROUND((COALESCE(gross_revenue, 0)
        - COALESCE(discount_amount, 0)
        - COALESCE(rebate_amount, 0)
        - COALESCE(wholesale_fee, 0))::numeric, 2) as expected_net,
       CASE WHEN ABS(COALESCE(net_revenue, 0) -
           (COALESCE(gross_revenue, 0) - COALESCE(discount_amount, 0)
            - COALESCE(rebate_amount, 0) - COALESCE(wholesale_fee, 0))) > 0.01
            THEN 'MISMATCH' ELSE 'OK' END as check
FROM sales_transaction
WHERE source_system = 'access_db'
  AND gross_revenue IS NOT NULL
ORDER BY RANDOM()
LIMIT 20;

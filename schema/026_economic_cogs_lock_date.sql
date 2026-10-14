-- Migration 026: economic_cogs_lock_date on sales_transaction
-- Part of BUG-18 (CRITICAL #5 from 2026-04-11 CTO audit; combines DASH-04 + ETL-04)
--
-- Implements ADR-006 (Economic COGS Versioning Strategy) at the row level:
-- "Once locked at bottling, prices are immutable."
--
-- The What-If Grape Price Calculator POST handler (dashboard/src/app/api/what-if/route.ts)
-- uses this column as a guard: any sales_transaction row with a non-NULL lock_date
-- is refused by the Apply handler and returned in a 409 Conflict response.
--
-- Forward-only. Additive. No data is modified; column is nullable with no default,
-- so existing rows remain unlocked until the bottling ETL stamps a lock_date.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sales_transaction'
          AND column_name = 'economic_cogs_lock_date'
    ) THEN
        ALTER TABLE sales_transaction
            ADD COLUMN economic_cogs_lock_date DATE;
    END IF;
END $$;

COMMENT ON COLUMN sales_transaction.economic_cogs_lock_date IS
    'Date the economic COGS for this row was locked at bottling (ADR-006). '
    'When non-NULL, /api/what-if Apply refuses to mutate economic_cogs_per_unit / '
    'economic_cogs_total for this row and returns 409 Conflict.';

-- Partial index: only the locked rows need to be found fast during the precheck.
CREATE INDEX IF NOT EXISTS idx_st_economic_cogs_lock_date
    ON sales_transaction(economic_cogs_lock_date)
    WHERE economic_cogs_lock_date IS NOT NULL;

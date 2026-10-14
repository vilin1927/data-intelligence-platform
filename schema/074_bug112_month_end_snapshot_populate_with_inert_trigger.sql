-- ════════════════════════════════════════════════════════════════════════════
-- schema/074_bug112_month_end_snapshot_populate_with_inert_trigger.sql
-- BUG-112 half-step — populate month_end_snapshot + economic_cogs_lock_date
-- with trigger guarded behind is_active flag (default FALSE) until the owner confirms.
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-24
--
-- answer + UI choice). Runbook §6.3 says ship default close rule + flag in
-- Phase E. Tension: the existing trg_reject_closed_period trigger BEFORE
-- INSERT on sales_transaction would activate the moment month_end_snapshot
-- has rows for a period — locking ALL pre-current-month-minus-1 periods
-- against future INSERTs. That breaks BUG-155 historical reattribution +
-- any further BUG-105 dead-letter recoveries + Phase 2 backfill work.
--
-- Vladimir-chosen "half-step" approach (2026-04-24):
--   1. Populate month_end_snapshot with default close rule
--      (everything before current-month-minus-1 = closed).
--   2. Populate economic_cogs_lock_date for closed-period sales_transaction
--      rows so the lock-date semantics work for downstream readers.
--   3. Keep the trigger function AROUND but make it INERT by default —
--      add is_active BOOLEAN DEFAULT FALSE column to month_end_snapshot;
--      trigger function checks `is_active=TRUE` before raising. All 86
--      backfilled rows land with is_active=FALSE (inert).
--   4. Phase E asks the owner: (a) confirm close rule (current-month-minus-1 vs
--      different cutoff), (b) decide whether to flip is_active=TRUE for
--      confirmed-closed periods.
--
-- WHY GUARD VS DROP: dropping the trigger loses the structural protection
-- entirely. Guarding via is_active flag preserves the trigger's purpose
-- (reject inserts into closed periods) and makes activation a one-line
-- UPDATE rather than a CREATE TRIGGER DDL. Reversible per-period.
--
-- DEFAULT CLOSE RULE: "everything before current-month-minus-1 is closed".
-- Today = 2026-04-24, so current-month = 2026-04, minus-1 = 2026-03,
-- "everything before 2026-03" = closed. Months populated: 2019-01 through
-- 2026-02 inclusive = 86 months. 2026-03 + 2026-04 stay OPEN.
--
-- BLAST RADIUS:
--   - month_end_snapshot: ALTER TABLE ADD COLUMN (idempotent), 86 INSERTs.
--   - sales_transaction: UPDATE economic_cogs_lock_date for closed-period
--     rows where lock_date IS NULL. Bounded by closed-period row count
--     (~119k rows; 2026-03+04 stay NULL). Idempotent (WHERE IS NULL).
--   - fn_reject_closed_period: CREATE OR REPLACE — function logic gains
--     an `AND is_active = TRUE` clause. trg_reject_closed_period stays.
--   - Existing INSERT/UPDATE behavior on sales_transaction unchanged
--     because all 86 snapshot rows land with is_active=FALSE; trigger
--     check skips them.
--
-- FORWARD-ONLY & ADDITIVE: ADD COLUMN, INSERT, UPDATE WHERE IS NULL,
-- CREATE OR REPLACE FUNCTION. Re-runnable (ON CONFLICT, IS NULL guards).
--
-- EXPECTED POST-STATE:
--   - month_end_snapshot.is_active column exists (NOT NULL DEFAULT FALSE)
--   - month_end_snapshot row count = 86 (one per closed month)
--   - month_end_snapshot WHERE is_active=TRUE = 0 (the owner hasn't confirmed)
--   - sales_transaction.economic_cogs_lock_date populated for ~119k rows
--     in closed periods; ~1k rows in 2026-03+04 stay NULL
--   - fn_reject_closed_period source body contains "AND is_active = TRUE"
--   - Re-running this migration is a no-op
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  snapshot_count INT;
  lock_date_populated INT;
  trigger_exists BOOLEAN;
BEGIN
  SELECT count(*) INTO snapshot_count FROM month_end_snapshot;
  SELECT count(*) INTO lock_date_populated
    FROM sales_transaction WHERE economic_cogs_lock_date IS NOT NULL;
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname='trg_reject_closed_period'
  ) INTO trigger_exists;

  RAISE NOTICE 'schema/074 PRE: month_end_snapshot rows=%, lock_date populated=%, trigger exists=%',
    snapshot_count, lock_date_populated, trigger_exists;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Add is_active guard column (idempotent)
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE month_end_snapshot
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN month_end_snapshot.is_active IS
  'BUG-112 half-step (2026-04-24): when FALSE, fn_reject_closed_period '
  'trigger does NOT enforce the period lock for this row. Allows backfilled '
  'snapshot rows to coexist with ongoing historical reattribution work '
  '(BUG-155, BUG-105 dead-letter recoveries, Phase 2 work). Phase E asks '
  'the owner to confirm close rule + decide whether to flip is_active=TRUE '
  'for confirmed-closed periods.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Replace trigger function to check is_active
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_reject_closed_period()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    -- BUG-112 half-step (2026-04-24): trigger only enforces when the
    -- snapshot row for this period has is_active=TRUE. Default-FALSE
    -- snapshot rows are inert (allow INSERT). The owner flips per-period.
    IF EXISTS (
        SELECT 1 FROM month_end_snapshot
        WHERE period = NEW.period
          AND is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'Period % is closed (active lock). Cannot insert sales data into a closed period.',
          NEW.period;
    END IF;
    RETURN NEW;
END;
$function$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Populate month_end_snapshot for closed months
--    Default close rule: everything before current-month-minus-1.
--    Today = 2026-04-24, so closed = 2019-01 ... 2026-02 inclusive.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO month_end_snapshot (period, closed_at, closed_by, notes, is_active)
SELECT
  to_char(month_start, 'YYYY-MM') AS period,
  -- closed_at = month-end timestamp (last day of month, 23:59:59)
  (date_trunc('month', month_start) + interval '1 month' - interval '1 second')::timestamp AS closed_at,
  'schema/074 backfill' AS closed_by,
  'BUG-112 half-step backfill 2026-04-24. is_active=FALSE pending the owner close-rule confirmation in Phase E.' AS notes,
  FALSE AS is_active
FROM generate_series(
  '2019-01-01'::date,
  -- end at current-month-minus-1 minus 1 day → last closed month
  (date_trunc('month', CURRENT_DATE) - interval '1 month' - interval '1 day')::date,
  '1 month'::interval
) AS month_start
ON CONFLICT (period) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Populate economic_cogs_lock_date for closed-period sales_transaction
-- ────────────────────────────────────────────────────────────────────────────
UPDATE sales_transaction st
SET economic_cogs_lock_date = mes.closed_at::date
FROM month_end_snapshot mes
WHERE st.period = mes.period
  AND st.economic_cogs_lock_date IS NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Self-record + post-state assertion
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('074_bug112_month_end_snapshot_populate_with_inert_trigger', 'live-apply')
ON CONFLICT (version) DO NOTHING;

DO $$
DECLARE
  snapshot_count INT;
  active_count INT;
  lock_date_populated INT;
  open_period_rows INT;
  trigger_body TEXT;
BEGIN
  SELECT count(*) INTO snapshot_count FROM month_end_snapshot;
  SELECT count(*) INTO active_count FROM month_end_snapshot WHERE is_active=TRUE;
  SELECT count(*) INTO lock_date_populated
    FROM sales_transaction WHERE economic_cogs_lock_date IS NOT NULL;
  -- Rows in periods NOT in snapshot (current-month-minus-1 + current-month + future)
  SELECT count(*) INTO open_period_rows
    FROM sales_transaction
    WHERE period NOT IN (SELECT period FROM month_end_snapshot);
  SELECT prosrc INTO trigger_body
    FROM pg_proc WHERE proname='fn_reject_closed_period';

  -- Sanity: snapshot count should be in [80..90] (~86 expected for 2019-01..2026-02)
  IF snapshot_count < 80 OR snapshot_count > 100 THEN
    RAISE EXCEPTION 'schema/074 FAIL: month_end_snapshot rows=% (expected ~86, got out of [80..100] band)',
      snapshot_count;
  END IF;

  -- Sanity: 0 active (default FALSE)
  IF active_count <> 0 THEN
    RAISE EXCEPTION 'schema/074 FAIL: month_end_snapshot is_active=TRUE rows=% (expected 0)',
      active_count;
  END IF;

  -- Sanity: lock_date populated for >> 0 rows but not all (open rows stay NULL)
  IF lock_date_populated < 100000 THEN
    RAISE EXCEPTION 'schema/074 FAIL: lock_date populated rows=% (expected ~119k)',
      lock_date_populated;
  END IF;

  -- Sanity: trigger function source contains the new is_active guard
  IF trigger_body NOT LIKE '%is_active = TRUE%' THEN
    RAISE EXCEPTION 'schema/074 FAIL: trigger function does NOT contain is_active guard. Body: %',
      left(trigger_body, 200);
  END IF;

  RAISE NOTICE 'schema/074 OK: month_end_snapshot=% rows (% active), lock_date populated=%, open-period rows (no lock_date)=%, trigger guard installed.',
    snapshot_count, active_count, lock_date_populated, open_period_rows;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK RECIPE (manual):
--   BEGIN;
--   UPDATE sales_transaction SET economic_cogs_lock_date = NULL;  -- 119k rows
--   DELETE FROM month_end_snapshot WHERE closed_by = 'schema/074 backfill';
--   ALTER TABLE month_end_snapshot DROP COLUMN IF EXISTS is_active;
--   CREATE OR REPLACE FUNCTION public.fn_reject_closed_period()
--   RETURNS trigger LANGUAGE plpgsql AS $$
--   BEGIN
--     IF EXISTS (SELECT 1 FROM month_end_snapshot WHERE period = NEW.period) THEN
--       RAISE EXCEPTION 'Period % is closed. Cannot insert sales data into a closed period.', NEW.period;
--     END IF;
--     RETURN NEW;
--   END; $$;
--   DELETE FROM schema_migrations WHERE version='074_bug112_month_end_snapshot_populate_with_inert_trigger';
--   COMMIT;
--
-- TO ACTIVATE THE LOCK PER PERIOD (Phase E, post-Owner confirmation):
--   UPDATE month_end_snapshot SET is_active=TRUE WHERE period <= '2026-02';
-- ════════════════════════════════════════════════════════════════════════════

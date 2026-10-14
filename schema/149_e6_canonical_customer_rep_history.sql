-- ════════════════════════════════════════════════════════════════════════════
-- schema/149_e6_canonical_customer_rep_history.sql
-- Forward-only audit table for bulk rep reassignment of canonical_customer rows.
-- ════════════════════════════════════════════════════════════════════════════
-- Date: 2026-05-10
--
-- WHY THIS EXISTS
-- ---------------
-- The owner's PDF page 8 #1 (May 4-8 feedback): "Rep A is NSW Central Coast
-- rep and has 27 customers. An additional 328 customers are assigned to
-- Rep D (previous rep) so should be assigned to Rep A. Access
-- has a simple way to change the assignment. How does this work in Postgres?"
--
-- Prod state confirmed 2026-05-10:
--   REP D = 326 customers, REP A = 24 customers
--   (the owner said 328+27, ~2-customer drift since his snapshot — is_active flips)
--
-- Vladimir delivers a bulk-reassign admin UI + API. Per ADR-020 the action is
-- forward-only: canonical_customer.rep_name updates apply to FUTURE
-- transactions; sales_transaction stays attributed to the historical rep.
-- This table records the audit trail.
--
-- FORWARD-ONLY & ADDITIVE
-- -----------------------
-- New table, zero existing-table modifications, zero downstream FK refs at
-- creation. Rollback recipe = DROP TABLE (rows are insert-only audit history,
-- no critical reads depend on them in Phase 1).
--
-- BLAST RADIUS
-- ------------
-- New table only. canonical_customer (4014 rows) untouched by this migration
-- — population happens via the new POST /api/admin/customers/bulk-reassign
-- API at runtime. No ETL changes, no nightly job changes.
--
-- EXPECTED POST-STATE (after this migration applies, before any UI use):
--   canonical_customer_rep_history row count = 0
--   table column count = 8 (id, customer_id, prev_rep_name, new_rep_name,
--     effective_date, reason, changed_by, changed_at)
--   FK target: canonical_customer(id) — 4014 rows confirmed pre-apply.
--   Index on (customer_id, effective_date DESC) for "history of customer X".
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF to_regclass('public.canonical_customer_rep_history') IS NOT NULL THEN
        RAISE EXCEPTION
          'canonical_customer_rep_history already exists; aborting to avoid '
          'accidental overwrite. Drop manually if intentional re-create.';
    END IF;
    IF to_regclass('public.canonical_customer') IS NULL THEN
        RAISE EXCEPTION
          'canonical_customer missing; schema/012 must land first';
    END IF;
    IF (SELECT COUNT(*) FROM canonical_customer) < 4000 THEN
        RAISE EXCEPTION
          'canonical_customer count % unexpected (expected ~4014); '
          'FK target drift',
          (SELECT COUNT(*) FROM canonical_customer);
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. CREATE TABLE canonical_customer_rep_history
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE canonical_customer_rep_history (
    id              BIGSERIAL    PRIMARY KEY,
    customer_id     INTEGER      NOT NULL
                                   REFERENCES canonical_customer(id),
    prev_rep_name   VARCHAR(200),
    new_rep_name    VARCHAR(200) NOT NULL,
    effective_date  DATE         NOT NULL,
    reason          TEXT         NOT NULL,
    changed_by      TEXT         NOT NULL,
    changed_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT canonical_customer_rep_history_reason_nonempty_chk
        CHECK (length(trim(reason)) > 0),
    CONSTRAINT canonical_customer_rep_history_changed_by_nonempty_chk
        CHECK (length(trim(changed_by)) > 0),
    CONSTRAINT canonical_customer_rep_history_new_rep_name_nonempty_chk
        CHECK (length(trim(new_rep_name)) > 0)
);

CREATE INDEX idx_ccrh_customer_effective
    ON canonical_customer_rep_history (customer_id, effective_date DESC);

-- Optional secondary: query "history written this week" / "what did Vladimir
-- change today" by changed_at scan.
CREATE INDEX idx_ccrh_changed_at
    ON canonical_customer_rep_history (changed_at DESC);

COMMENT ON TABLE canonical_customer_rep_history IS
  'E6 (2026-05-10): forward-only audit trail for bulk rep reassignments on '
  'canonical_customer. Per ADR-020 (forward-only with effective_date), each '
  'reassignment writes one row here capturing prev/new rep + effective_date '
  '+ reason + changed_by, then UPDATEs canonical_customer.rep_name. '
  'sales_transaction is NOT touched — historical rep attribution is preserved '
  'on the per-row sales_transaction.rep_name (or implicit via JOIN at query '
  'time). Source: internal notes row '
  'E6 + the owner PDF page 8 #1 (Rep A / Rep D NSW Central Coast).';

COMMENT ON COLUMN canonical_customer_rep_history.customer_id IS
  'FK to canonical_customer(id). Primary lookup key — index supports '
  '"history of customer X" by (customer_id, effective_date DESC).';

COMMENT ON COLUMN canonical_customer_rep_history.prev_rep_name IS
  'rep_name read from canonical_customer immediately before the UPDATE. '
  'NULL allowed for the initial assignment case (e.g. customer was orphan '
  'rep_name=NULL before the reassign). Captured BEFORE the UPDATE inside the '
  'same BEGIN/COMMIT transaction in the API route.';

COMMENT ON COLUMN canonical_customer_rep_history.new_rep_name IS
  'rep_name written to canonical_customer in the same transaction. Matches '
  'canonical_representative.rep_name (UPPER-normalized) — Phase H may '
  'replace this with a FK column new_rep_id without breaking history.';

COMMENT ON COLUMN canonical_customer_rep_history.effective_date IS
  'Logical date the reassignment takes effect for reporting / commission '
  'purposes. Defaults to TODAY in the UI; user can backdate when a rep '
  'cutover happened earlier (e.g. "Rep A effective May 1 even though '
  'I am clicking submit on May 10").';

COMMENT ON COLUMN canonical_customer_rep_history.reason IS
  'Free-text justification provided by the admin in the UI. NOT NULL + '
  'CHECK length>0 enforces an explicit reason on every reassignment. '
  'Example: "Rep A takes NSW Central Coast effective May 1, '
  'replacing Rep D per the owner May 4 ask".';

COMMENT ON COLUMN canonical_customer_rep_history.changed_by IS
  'Identity of the admin performing the action. Defaults to "vladimir" in '
  'Phase 1 (single-admin workflow). Phase H may replace with session user '
  'when auth is wired into the admin layer.';

COMMENT ON COLUMN canonical_customer_rep_history.changed_at IS
  'Timestamp of the INSERT (NOW() default). Distinct from effective_date — '
  'a backdated reassignment has changed_at = today but effective_date in '
  'the past.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Post-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_table_exists  BOOL;
    v_index_count   INT;
    v_column_count  INT;
BEGIN
    SELECT to_regclass('public.canonical_customer_rep_history') IS NOT NULL
      INTO v_table_exists;

    IF NOT v_table_exists THEN
        RAISE EXCEPTION
          'E6 schema/149 POST: canonical_customer_rep_history was not created';
    END IF;

    SELECT COUNT(*) INTO v_index_count
      FROM pg_indexes
     WHERE tablename = 'canonical_customer_rep_history';

    -- Expected: PK auto-index + idx_ccrh_customer_effective + idx_ccrh_changed_at
    IF v_index_count < 3 THEN
        RAISE EXCEPTION
          'E6 schema/149 POST: expected ≥ 3 indexes on rep_history table, got %',
          v_index_count;
    END IF;

    SELECT COUNT(*) INTO v_column_count
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'canonical_customer_rep_history';

    IF v_column_count <> 8 THEN
        RAISE EXCEPTION
          'E6 schema/149 POST: expected 8 columns, got %',
          v_column_count;
    END IF;

    RAISE NOTICE
      'E6 schema/149 OK: canonical_customer_rep_history created (cols=%, indexes=%, rows=0)',
      v_column_count, v_index_count;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Record migration in schema_migrations ledger (idempotent).
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('149_e6_canonical_customer_rep_history', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK / DOWN-MIGRATION RECIPE (manual; not auto-run)
-- ════════════════════════════════════════════════════════════════════════════
-- This migration creates a new audit table. To revert (data loss — all
-- recorded rep reassignment history disappears):
--
--   BEGIN;
--   DROP INDEX IF EXISTS idx_ccrh_changed_at;
--   DROP INDEX IF EXISTS idx_ccrh_customer_effective;
--   DROP TABLE IF EXISTS canonical_customer_rep_history;
--   DELETE FROM schema_migrations
--     WHERE version = '149_e6_canonical_customer_rep_history';
--   COMMIT;
--
-- Note: dropping this table does NOT revert any canonical_customer.rep_name
-- writes that the bulk-reassign API made. Reverting an individual rep
-- reassignment requires writing a new history row with prev/new swapped and
-- re-running the UPDATE — the audit row tells you what to revert to.
-- ════════════════════════════════════════════════════════════════════════════

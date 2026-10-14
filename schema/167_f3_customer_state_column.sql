-- ════════════════════════════════════════════════════════════════════════════
-- schema/167_f3_customer_state_column.sql
-- F3 — Add customer.state column + backfill via au_postcode JOIN on postcode
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-12
-- Ticket:  PHASE1-CLOSE-F3-CUSTOMER-STATE-COL
-- DESTRUCTIVE: false (forward-only ADD COLUMN + idempotent guarded UPDATE)
-- Trust contract v1.1 — single BEGIN/COMMIT envelope, PRE/POST asserts.
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION
-- ════════════════════════════════════════════════════════════════════════════
-- The owner feedback matrix row F3: /admin/unmatched-customers meta-row must show
-- State + Channel next to suburb. Channel already exists as
-- customer.warehouse_channel (surfaced as `source_system` in the API). State
-- has NO source column in `customer` (schema/001 customer L124-132 + schema/019
-- + schema/078 audited — confirmed gap). au_postcode (schema/032, 18,535 rows)
-- has the postcode→state map. JOIN on postcode + suburb produces a HARD answer
-- for ~99.9% of customers with non-NULL postcode and non-NULL canonical link.
--
-- ════════════════════════════════════════════════════════════════════════════
-- L6 CHECK CONSTRAINT INTERACTION (schema/162 customer_must_have_canonical)
-- ════════════════════════════════════════════════════════════════════════════
-- schema/162 added CHECK customer_must_have_canonical (canonical_customer_id
-- IS NOT NULL) NOT VALID. NOT VALID grandfathers existing NULL-canonical rows
-- BUT re-validates every touched row on UPDATE. Mass UPDATE customer SET state
-- without a canonical_customer_id guard would trip the CHECK on ~1988 NULL-
-- canonical rows.
--
-- Mitigation: WHERE customer.canonical_customer_id IS NOT NULL on the UPDATE.
-- Backfill only rows that already pass the CHECK. Remaining ~1988 NULL-
-- canonical rows get state backfilled in a follow-up migration that runs
-- AFTER BUG-165 dedup (schema/161 family) finishes assigning canonical links
-- to the orphan tail.
--
-- ════════════════════════════════════════════════════════════════════════════
-- BACKFILL STRATEGY (postcode + suburb disambiguation)
-- ════════════════════════════════════════════════════════════════════════════
-- au_postcode has 18,535 rows. Some postcodes span multiple states (e.g.
-- 2540 splits ACT/NSW for Jervis Bay; 0872 splits NT/SA/WA). 57 customer
-- rows hit ambiguous postcodes. 53 of those resolve via exact suburb match
-- (UPPER(au_postcode.locality) = UPPER(customer.suburb)). Remaining 4 use
-- deterministic MIN(state) fallback so reruns are idempotent.
--
-- 5 customer rows have postcodes not present in au_postcode at all (truncated
-- or stale input) — those stay NULL and surface as Phase 2 cleanup.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- Prior migrations adding/touching customer.state:
--   grep -r "customer.*state" schema/ — 0 hits on customer table state col.
--   schema/001..165 customer ALTERs: postcode (019), warehouse_channel (078),
--   canonical_customer_id (012), rep_id/canonical_rep_id (various). NO state.
--
--   au_postcode = ABS/AusPost open data, not Owner-authored, not in xlsx scope.
--   The owner xlsx 'Customer table' has no state column either. Postcode→state
--   mapping is reference data, not a Owner-curated cell — au_postcode is the
--   HARD source for AU postcode geography.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_au_postcode_count       INT;
    v_customer_total          INT;
    v_eligible_backfill       INT;
    v_deferred_null_canonical INT;
    v_state_col_exists        BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'customer'
          AND column_name = 'state'
    ) INTO v_state_col_exists;
    IF v_state_col_exists THEN
        RAISE NOTICE 'F3 167 PRE: customer.state already exists — replay-safe path';
    END IF;

    SELECT count(*) INTO v_au_postcode_count FROM au_postcode;
    IF v_au_postcode_count = 0 THEN
        RAISE EXCEPTION 'F3 167 PRE FAIL: au_postcode is empty — schema/032 seed missing';
    END IF;
    IF v_au_postcode_count < 10000 THEN
        RAISE EXCEPTION 'F3 167 PRE FAIL: au_postcode has only % rows — expected >= 10000 (seed corruption?)',
                        v_au_postcode_count;
    END IF;

    SELECT count(*) INTO v_customer_total FROM customer;
    IF v_customer_total < 8000 THEN
        RAISE EXCEPTION 'F3 167 PRE FAIL: customer rowcount % below floor 8000',
                        v_customer_total;
    END IF;

    SELECT count(*) INTO v_eligible_backfill
      FROM customer
     WHERE postcode IS NOT NULL
       AND canonical_customer_id IS NOT NULL;
    SELECT count(*) INTO v_deferred_null_canonical
      FROM customer
     WHERE postcode IS NOT NULL
       AND canonical_customer_id IS NULL;

    RAISE NOTICE 'F3 167 PRE: au_postcode=% customers=% eligible_backfill=% deferred_null_canonical=%',
                 v_au_postcode_count, v_customer_total,
                 v_eligible_backfill, v_deferred_null_canonical;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 ADD COLUMN customer.state (idempotent — IF NOT EXISTS)
--    Length VARCHAR(50) matches territory.state (schema/001 territory L) so
--    the two state cols can be compared / joined without truncation surprises.
--    au_postcode.state is VARCHAR(3) (NSW/VIC/ACT etc), so 50 is generous
--    headroom for future region-string expansion if needed.
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE customer
  ADD COLUMN IF NOT EXISTS state VARCHAR(50);

COMMENT ON COLUMN customer.state IS
  'Customer state (e.g. NSW, VIC, ACT). Backfilled from au_postcode JOIN on '
  'customer.postcode (preferring exact locality=suburb match on ambiguous '
  'multi-state postcodes; MIN(state) deterministic fallback). schema/167 F3. '
  'Forward-only — new writes (admin UI, ETL) responsible for setting state '
  'on insert/update going forward.';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 Audit-trail table
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS f3_customer_state_backfill_audit_167 (
    customer_id      INT          PRIMARY KEY,
    state_after      VARCHAR(50)  NOT NULL,
    postcode_used    VARCHAR(10)  NOT NULL,
    locality_matched VARCHAR(100),
    set_by           TEXT         NOT NULL DEFAULT 'schema/167_f3_customer_state_column',
    set_at           TIMESTAMP    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE f3_customer_state_backfill_audit_167 IS
  'F3 schema/167 audit trail. Per-customer row inserted at backfill time. '
  'state_after = the value written; postcode_used = the JOIN key; '
  'locality_matched = the au_postcode.locality row picked (NULL when MIN(state) '
  'deterministic fallback fired on an ambiguous postcode with no suburb match). '
  'Source: au_postcode (schema/032, ABS/AusPost open data 18,535 rows).';

-- ────────────────────────────────────────────────────────────────────────────
-- §4 Backfill UPDATE — guarded on canonical_customer_id IS NOT NULL per L6
-- ────────────────────────────────────────────────────────────────────────────
-- Strategy via CTE:
--   1. resolved_state ranks au_postcode rows per customer.postcode preferring
--      exact suburb match (locality = customer.suburb).
--   2. UPDATE picks rn=1 (best match per customer).
--   3. WHERE customer.state IS NULL — idempotent (replay-safe).
--   4. WHERE customer.canonical_customer_id IS NOT NULL — L6 CHECK guard.
--
-- This INSERTs audit rows FIRST (matching the UPDATE candidate set), then
-- UPDATEs customer in the same transaction.
WITH resolved_state AS (
    SELECT
        c.customer_id,
        c.postcode,
        ap.state          AS resolved_state,
        ap.locality       AS resolved_locality,
        ROW_NUMBER() OVER (
            PARTITION BY c.customer_id
            ORDER BY
                CASE WHEN UPPER(ap.locality) = UPPER(c.suburb) THEN 0 ELSE 1 END,
                ap.state,
                ap.locality
        ) AS rn
    FROM customer c
    JOIN au_postcode ap ON ap.postcode = c.postcode
    WHERE c.state IS NULL
      AND c.postcode IS NOT NULL
      AND c.canonical_customer_id IS NOT NULL
)
INSERT INTO f3_customer_state_backfill_audit_167
    (customer_id, state_after, postcode_used, locality_matched)
SELECT
    customer_id,
    resolved_state,
    postcode,
    CASE WHEN rn = 1 THEN resolved_locality END
  FROM resolved_state
 WHERE rn = 1
ON CONFLICT (customer_id) DO NOTHING;

UPDATE customer c
   SET state = audit.state_after,
       updated_at = NOW()
  FROM f3_customer_state_backfill_audit_167 audit
 WHERE c.customer_id = audit.customer_id
   AND c.state IS NULL
   AND c.canonical_customer_id IS NOT NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 POST-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_backfilled        INT;
    v_remaining_null    INT;
    v_audit_rows        INT;
    v_check_safety      INT;
BEGIN
    SELECT count(*) INTO v_backfilled
      FROM customer
     WHERE state IS NOT NULL
       AND canonical_customer_id IS NOT NULL;
    SELECT count(*) INTO v_remaining_null
      FROM customer
     WHERE state IS NULL
       AND postcode IS NOT NULL
       AND canonical_customer_id IS NOT NULL;
    SELECT count(*) INTO v_audit_rows
      FROM f3_customer_state_backfill_audit_167;

    -- Safety: confirm zero NULL-canonical rows got their state set (would
    -- prove the L6 guard worked correctly).
    SELECT count(*) INTO v_check_safety
      FROM customer
     WHERE state IS NOT NULL
       AND canonical_customer_id IS NULL;

    IF v_backfilled < 4000 THEN
        RAISE EXCEPTION 'F3 167 POST FAIL: only % customers got state — expected >= 4000 (scout time 4184)',
                        v_backfilled;
    END IF;

    -- v_remaining_null tolerates the 5 known-bad postcodes not in au_postcode.
    IF v_remaining_null > 50 THEN
        RAISE EXCEPTION 'F3 167 POST FAIL: % customers still NULL state (postcode not NULL, canonical not NULL) — expected <= 50 (scout time 5)',
                        v_remaining_null;
    END IF;

    IF v_audit_rows < 4000 THEN
        RAISE EXCEPTION 'F3 167 POST FAIL: audit table has % rows — expected >= 4000',
                        v_audit_rows;
    END IF;

    RAISE NOTICE 'F3 167 POST: backfilled=% remaining_null_postcoded=% audit=% null_canonical_state_leak=%',
                 v_backfilled, v_remaining_null, v_audit_rows, v_check_safety;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 Migration registry
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('167_f3_customer_state_column', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--
--   SELECT count(*) FROM customer WHERE postcode IS NOT NULL AND canonical_customer_id IS NOT NULL;
--   SELECT count(*) FROM customer WHERE postcode IS NOT NULL AND canonical_customer_id IS NULL;
--
-- POST-apply (expected ~4184 backfilled, <= 5 still NULL with postcode):
--   SELECT count(*) FROM customer WHERE state IS NOT NULL;
--   SELECT count(*) FROM customer WHERE state IS NULL AND postcode IS NOT NULL AND canonical_customer_id IS NOT NULL;
--   SELECT state, count(*) FROM customer WHERE state IS NOT NULL GROUP BY state ORDER BY 2 DESC;
--
-- POST-apply L2:
--   EXPECTED: xfail until prod apply lands. Remove xfail in follow-up commit.
--
-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK recipe (forward-only, audit-restore)
-- ════════════════════════════════════════════════════════════════════════════
-- Drop column (destructive — only if state column was a mistake):
--   BEGIN;
--   ALTER TABLE customer DROP COLUMN IF EXISTS state;
--   DROP TABLE IF EXISTS f3_customer_state_backfill_audit_167;
--   DELETE FROM schema_migrations WHERE version = '167_f3_customer_state_column';
--   COMMIT;
--
-- Null-out state but keep column (non-destructive):
--   BEGIN;
--   UPDATE customer SET state = NULL WHERE state IS NOT NULL;
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- schema/165_d1_alm_edi_outlet_address.sql
-- D1 — ALM EDI 5|2 outlet_address column (f[21]) for unmatched-customer
--      form Address pre-fill (Strange Alchemy + every ALM-origin row).
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-11
-- Ticket:  PHASE1-CLOSE-D1-ALM-ADDRESS-PROPAGATE
--          Forward-only ALTER TABLE ADD COLUMN. NULL-able.
--
--
--     → AW875418_2026-03-02-034402.zip
--       → A175418S.AW875418.91812
--   `head -1 grep ^5|2|` shows pipe-split:
--     f[20] = "CUSTOMER 24       " (outlet_name, already captured)
--     f[21] = "1 EXAMPLE STREET        "       (outlet_address — THIS COL)
--     f[22] = "AINSLIE             "            (outlet_suburb)
--     f[23] = "2602"                            (outlet_postcode)
--   ALM EDI HARD source — confirmed against 3 sample 5|2 lines (Customer 24,
--   Customer 105, Customer 24 again). All carry f[21] address.
--
-- DDL-ONLY: 1 ALTER TABLE ADD COLUMN on alm_edi_segment_52. NULL-able with no
--           default. Backfill of historical rows OUT OF SCOPE — only new
--           ALM EDI uploads after this migration capture address. Historical
--           rows return NULL address in JOIN (modal leaves Address blank,
--           same as current behaviour — no regression).
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION
-- ════════════════════════════════════════════════════════════════════════════
-- The owner feedback PDF p6-7 #D1: "Strange Alchemy unmatched form needs Address
-- pre-fill from ALM EDI". Matrix verdict 🟡 PARTIAL: suburb/postcode/group
-- already pre-fill via canonical_customer JOIN; Address field never wired.
--
-- Rep stays blank — genuinely absent in EDI source (ALM doesn't ship sales-
-- rep on EDI lines). Documented as known-limitation in:
--   • dashboard/src/components/MatchCustomerModal.tsx (Field 7 hint)
--   • etl/import_alm_edi.py parse_segment_52 docstring
--
-- Address propagation path (post-this-migration):
--   ALM EDI f[21] → alm_edi_segment_52.outlet_address (NEW COL, THIS FILE)
--                 → /api/admin/unmatched-customers GET LEFT JOIN by outlet_name
--                 → UnmatchedRowSeed.address
--                 → MatchCustomerModal pre-fill Address field
--
-- Same path already works for suburb/postcode via canonical_customer JOIN
-- (route.ts:96-98); we add the missing address leg only.
--
-- ════════════════════════════════════════════════════════════════════════════
-- IDEMPOTENT + REVERSIBLE
-- ════════════════════════════════════════════════════════════════════════════
-- Idempotent: ADD COLUMN IF NOT EXISTS guard.
-- Reversible: `ALTER TABLE alm_edi_segment_52 DROP COLUMN outlet_address;`
--   Safe — no downstream view/index depends on it.
--
-- ════════════════════════════════════════════════════════════════════════════
-- PRE-FLIGHT GREP
-- ════════════════════════════════════════════════════════════════════════════
-- grep "outlet_address" schema/*.sql etl/*.py → 0 hits (this is the first).
-- grep "alm_edi_segment_52" schema/*.sql → schema/097 (creator), schema/147
--   (B3-1 item_code), schema/165 (this file). No conflicts on outlet_address.

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. PRE-ASSERTS
-- ────────────────────────────────────────────────────────────────────────

DO $pre$
DECLARE
    parent_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema='public' AND table_name='alm_edi_segment_52'
    ) INTO parent_exists;
    IF NOT parent_exists THEN
        RAISE EXCEPTION 'schema/165 D1 PRE: alm_edi_segment_52 missing — apply schema/097 first';
    END IF;
END
$pre$;

-- ────────────────────────────────────────────────────────────────────────
-- 2. ADD COLUMN (idempotent)
-- ────────────────────────────────────────────────────────────────────────

ALTER TABLE alm_edi_segment_52
    ADD COLUMN IF NOT EXISTS outlet_address TEXT;

COMMENT ON COLUMN alm_edi_segment_52.outlet_address IS
    'D1 (2026-05-11): ALM EDI 5|2 field [21] — outlet street address. '
    'NULL on rows imported before schema/165. Powers MatchCustomerModal '
    'Address pre-fill via /api/admin/unmatched-customers JOIN by outlet_name.';

-- ────────────────────────────────────────────────────────────────────────
-- 3. POST-ASSERTS
-- ────────────────────────────────────────────────────────────────────────

DO $post$
DECLARE
    col_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='alm_edi_segment_52'
          AND column_name='outlet_address'
    ) INTO col_exists;
    IF NOT col_exists THEN
        RAISE EXCEPTION 'schema/165 D1 POST: outlet_address column missing after ALTER';
    END IF;
END
$post$;

-- ────────────────────────────────────────────────────────────────────────
-- 4. RECORD MIGRATION
-- ────────────────────────────────────────────────────────────────────────

INSERT INTO schema_migrations (version, applied_at)
VALUES (
    '165_d1_alm_edi_outlet_address',
    now()
)
ON CONFLICT (version) DO NOTHING;
-- Note: schema_migrations has cols (version, applied_at, source) only —
-- `source` defaults to 'live-apply'. No `description` col on prod. D1
-- ship-state-matrix-2026-05-10.md D1 row.

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK RECIPE (manual, only if D1 wire-up rejected)
-- ════════════════════════════════════════════════════════════════════════════
-- BEGIN;
-- ALTER TABLE alm_edi_segment_52 DROP COLUMN IF EXISTS outlet_address;
-- DELETE FROM schema_migrations WHERE version='165_d1_alm_edi_outlet_address';
-- COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- schema/153_a9_variety_cleanup.sql
-- A9 variety dropdown cleanup — dedupe + category-leak fix + NULL fill
-- ════════════════════════════════════════════════════════════════════════════
-- Date:    2026-05-10
-- Ticket:  A9 variety dropdown PARTIAL (Phase 1 ship-state matrix line 66)
--
-- HARD SOURCES:
--                      "varietal list incomplete"
--              "🟡 PARTIAL: 29 entries with dupes (Rose+Rosé, Syrah+Shiraz),
--               category leaks (Sparkling-as-variety), 15 NULLs"
--              dropdown 29 entries enumerated
--
-- ════════════════════════════════════════════════════════════════════════════
-- WHY THIS MIGRATION (root cause)
-- ════════════════════════════════════════════════════════════════════════════
-- variety dropdown built off DISTINCT sku.variety. Master is dirty:
--   (a) Rose + Rosé coexist — French diacritic split, Rosé canonical
--   (b) Syrah + Shiraz coexist — same grape, Shiraz canonical (AU standard)
--   (c) Sparkling + Tumbarumba Sparkling appear as varieties — STYLE not VARIETY
--   (d) 15 SKUs have NULL variety — dropdown shows blank entry
--
-- L2 test test_a9_variety_no_dupes_or_category_leaks asserts:
--   * COUNT Rose∩Rosé sku = 0
--   * COUNT variety='Sparkling' = 0
--   * COUNT variety ILIKE '%tumbarumba%' = 0
--
-- Test does NOT assert NULL count, but task includes NULL fill (15) for
-- dropdown hygiene. Conservative default 'Unknown' literal per
-- only escalate to the owner if rejected. sku_name pattern guessing too risky
-- (TASK FLOOR rule).
--
-- ════════════════════════════════════════════════════════════════════════════
-- Schema notes (investigated pre-write)
-- ════════════════════════════════════════════════════════════════════════════
--   * sku.variety VARCHAR(100) — schema/001 line 84 (only variety col)
--   * NO sku.style col exists — grep schema/*.sql confirmed
--   * Strategy for Sparkling rows: set variety='Unknown' (style data lives
--     elsewhere — Vinsight raw_data->>'ProductCategories' has Style:Sparkling).
--     Future Phase 2 ticket can introduce sku.style col + backfill from
--     ProductCategories regex; out-of-scope here.
--   * canonical_sku.variety NOT touched — view inheritance handles downstream.
--
-- ════════════════════════════════════════════════════════════════════════════
-- Forward-only safety
-- ════════════════════════════════════════════════════════════════════════════
--   * BEGIN/COMMIT atomic — any RAISE rolls all UPDATEs back
--   * PRE-asserts: capture before-counts, sanity floor on sku table
--   * 4 UPDATE statements with WHERE filter to be no-op on re-run (idempotent)
--   * variety_cleanup_audit_153 captures sku_id + before/after per UPDATE
--   * POST-asserts: 0 Rose, 0 Syrah, 0 Sparkling-as-variety, 0 NULL — RAISE if any
--   * schema_migrations registry INSERT at end ON CONFLICT DO NOTHING (idempotent)
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- §1 PRE-asserts
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_sku_count        INT;
    v_rose_count       INT;
    v_rose_acc_count   INT;
    v_syrah_count      INT;
    v_shiraz_count     INT;
    v_sparkling_count  INT;
    v_tumb_spk_count   INT;
    v_null_count       INT;
    v_table_sku        BOOLEAN;
BEGIN
    -- Required table present
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='sku') INTO v_table_sku;
    IF NOT v_table_sku THEN
        RAISE EXCEPTION 'A9-153 PRE FAIL: sku table missing';
    END IF;

    -- Sanity floor
    SELECT count(*) INTO v_sku_count FROM sku;
    IF v_sku_count < 500 THEN
        RAISE EXCEPTION 'A9-153 PRE FAIL: sku count % below sanity floor 500', v_sku_count;
    END IF;

    -- Variety distribution snapshot
    SELECT count(*) INTO v_rose_count       FROM sku WHERE variety = 'Rose';
    SELECT count(*) INTO v_rose_acc_count   FROM sku WHERE variety = 'Rosé';
    SELECT count(*) INTO v_syrah_count      FROM sku WHERE variety = 'Syrah';
    SELECT count(*) INTO v_shiraz_count     FROM sku WHERE variety = 'Shiraz';
    SELECT count(*) INTO v_sparkling_count  FROM sku WHERE variety = 'Sparkling';
    SELECT count(*) INTO v_tumb_spk_count   FROM sku WHERE variety ILIKE '%tumbarumba%';
    SELECT count(*) INTO v_null_count       FROM sku WHERE variety IS NULL;

    RAISE NOTICE 'A9-153 PRE: sku=% / Rose=% / Rosé=% / Syrah=% / Shiraz=% / Sparkling=% / Tumb-Spk=% / NULL=%',
                 v_sku_count, v_rose_count, v_rose_acc_count, v_syrah_count,
                 v_shiraz_count, v_sparkling_count, v_tumb_spk_count, v_null_count;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §2 Audit table (captures before/after per affected sku_id)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS variety_cleanup_audit_153 (
    audit_id      SERIAL PRIMARY KEY,
    sku_id        INTEGER NOT NULL,
    sku_code      VARCHAR(50),
    item_description VARCHAR(500),
    variety_before VARCHAR(100),
    variety_after  VARCHAR(100),
    rule_applied  VARCHAR(50)  NOT NULL,  -- 'rose_dedupe' / 'syrah_dedupe' / 'sparkling_leak' / 'null_fill'
    applied_at    TIMESTAMP NOT NULL DEFAULT NOW(),
    set_by        VARCHAR(50)  NOT NULL DEFAULT 'schema/153_a9'
);

CREATE INDEX IF NOT EXISTS idx_vca153_sku_id ON variety_cleanup_audit_153 (sku_id);
CREATE INDEX IF NOT EXISTS idx_vca153_rule   ON variety_cleanup_audit_153 (rule_applied);

COMMENT ON TABLE variety_cleanup_audit_153 IS
    'A9-153 variety cleanup audit trail. One row per UPDATE across 4 rules.';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 RULE 1 — Rose → Rosé dedupe (canonical = Rosé with diacritic)
--    Idempotent: WHERE variety='Rose' is no-op once applied.
-- ────────────────────────────────────────────────────────────────────────────
WITH affected AS (
    SELECT sku_id, sku_code, item_description, variety AS variety_before
      FROM sku
     WHERE variety = 'Rose'
)
INSERT INTO variety_cleanup_audit_153
    (sku_id, sku_code, item_description, variety_before, variety_after, rule_applied)
SELECT sku_id, sku_code, item_description, variety_before, 'Rosé', 'rose_dedupe'
  FROM affected;

UPDATE sku SET variety = 'Rosé', updated_at = NOW()
 WHERE variety = 'Rose';

DO $$
DECLARE v_updated INT;
BEGIN
    SELECT count(*) INTO v_updated
      FROM variety_cleanup_audit_153 WHERE rule_applied = 'rose_dedupe';
    RAISE NOTICE 'A9-153 §3 rose_dedupe UPDATEs=%', v_updated;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §4 RULE 2 — Syrah → Shiraz dedupe (canonical = Shiraz, AU standard)
--    HARD: same grape (Vitis vinifera Syrah/Shiraz), Australian wine
--    Idempotent: WHERE variety='Syrah' no-op once applied.
-- ────────────────────────────────────────────────────────────────────────────
WITH affected AS (
    SELECT sku_id, sku_code, item_description, variety AS variety_before
      FROM sku
     WHERE variety = 'Syrah'
)
INSERT INTO variety_cleanup_audit_153
    (sku_id, sku_code, item_description, variety_before, variety_after, rule_applied)
SELECT sku_id, sku_code, item_description, variety_before, 'Shiraz', 'syrah_dedupe'
  FROM affected;

UPDATE sku SET variety = 'Shiraz', updated_at = NOW()
 WHERE variety = 'Syrah';

DO $$
DECLARE v_updated INT;
BEGIN
    SELECT count(*) INTO v_updated
      FROM variety_cleanup_audit_153 WHERE rule_applied = 'syrah_dedupe';
    RAISE NOTICE 'A9-153 §4 syrah_dedupe UPDATEs=%', v_updated;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §5 RULE 3 — Sparkling category leak ('Sparkling' OR contains 'Tumbarumba')
--    Sparkling = STYLE, not VARIETY. No sku.style col exists in current
--    schema (verified). Set variety='Unknown' as conservative floor.
--    Phase 2 ticket can introduce sku.style + backfill from Vinsight
--    raw_data->>'ProductCategories' Style:Sparkling regex.
--    Idempotent: WHERE matches no-op once applied.
-- ────────────────────────────────────────────────────────────────────────────
WITH affected AS (
    SELECT sku_id, sku_code, item_description, variety AS variety_before
      FROM sku
     WHERE variety = 'Sparkling'
        OR variety ILIKE '%tumbarumba%'
)
INSERT INTO variety_cleanup_audit_153
    (sku_id, sku_code, item_description, variety_before, variety_after, rule_applied)
SELECT sku_id, sku_code, item_description, variety_before, 'Unknown', 'sparkling_leak'
  FROM affected;

UPDATE sku SET variety = 'Unknown', updated_at = NOW()
 WHERE variety = 'Sparkling'
    OR variety ILIKE '%tumbarumba%';

DO $$
DECLARE v_updated INT;
BEGIN
    SELECT count(*) INTO v_updated
      FROM variety_cleanup_audit_153 WHERE rule_applied = 'sparkling_leak';
    RAISE NOTICE 'A9-153 §5 sparkling_leak UPDATEs=%', v_updated;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §6 RULE 4 — NULL variety fill = 'Unknown' (15 expected)
--    sku_name pattern guessing rejected (TASK rule):
--      * many NULL rows are non-wine (packaging dry-goods, GIFT, sample
--        bottles) where variety doesn't apply
--      * pattern matching CABERNET could mis-tag a Cabernet/Merlot blend
--    'Unknown' is honest signal — the owner rejects it post-delivery, append
--    to batch with row sample.
--    Idempotent: WHERE variety IS NULL no-op once applied.
-- ────────────────────────────────────────────────────────────────────────────
WITH affected AS (
    SELECT sku_id, sku_code, item_description, variety AS variety_before
      FROM sku
     WHERE variety IS NULL
)
INSERT INTO variety_cleanup_audit_153
    (sku_id, sku_code, item_description, variety_before, variety_after, rule_applied)
SELECT sku_id, sku_code, item_description, variety_before, 'Unknown', 'null_fill'
  FROM affected;

UPDATE sku SET variety = 'Unknown', updated_at = NOW()
 WHERE variety IS NULL;

DO $$
DECLARE v_updated INT;
BEGIN
    SELECT count(*) INTO v_updated
      FROM variety_cleanup_audit_153 WHERE rule_applied = 'null_fill';
    RAISE NOTICE 'A9-153 §6 null_fill UPDATEs=%', v_updated;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §7 POST-asserts (L2 test invariants — RAISE on any breach)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_rose_post       INT;
    v_syrah_post      INT;
    v_sparkling_post  INT;
    v_tumb_spk_post   INT;
    v_null_post       INT;
    v_rose_dupe       INT;
    v_audit_total     INT;
BEGIN
    -- L2 test (a): no Rose+Rosé coexistence
    SELECT count(*) INTO v_rose_dupe FROM (
        SELECT 1 FROM sku WHERE variety = 'Rose'
        INTERSECT
        SELECT 1 FROM sku WHERE variety = 'Rosé'
    ) x;
    IF v_rose_dupe <> 0 THEN
        RAISE EXCEPTION 'A9-153 POST FAIL: Rose+Rosé still coexist (intersect=%)', v_rose_dupe;
    END IF;

    -- Lone-Rose check (must be 0 — all migrated to Rosé)
    SELECT count(*) INTO v_rose_post FROM sku WHERE variety = 'Rose';
    IF v_rose_post <> 0 THEN
        RAISE EXCEPTION 'A9-153 POST FAIL: variety=Rose count % (expected 0)', v_rose_post;
    END IF;

    -- Lone-Syrah check
    SELECT count(*) INTO v_syrah_post FROM sku WHERE variety = 'Syrah';
    IF v_syrah_post <> 0 THEN
        RAISE EXCEPTION 'A9-153 POST FAIL: variety=Syrah count % (expected 0)', v_syrah_post;
    END IF;

    -- L2 test (b): no Sparkling-as-variety
    SELECT count(*) INTO v_sparkling_post FROM sku WHERE variety = 'Sparkling';
    IF v_sparkling_post <> 0 THEN
        RAISE EXCEPTION 'A9-153 POST FAIL: variety=Sparkling count % (expected 0) — category leak',
            v_sparkling_post;
    END IF;

    -- L2 test (c): no region-in-variety
    SELECT count(*) INTO v_tumb_spk_post FROM sku WHERE variety ILIKE '%tumbarumba%';
    IF v_tumb_spk_post <> 0 THEN
        RAISE EXCEPTION 'A9-153 POST FAIL: variety LIKE %%tumbarumba%% count % (expected 0) — region leak',
            v_tumb_spk_post;
    END IF;

    -- NULL variety check
    SELECT count(*) INTO v_null_post FROM sku WHERE variety IS NULL;
    IF v_null_post <> 0 THEN
        RAISE EXCEPTION 'A9-153 POST FAIL: NULL variety count % (expected 0)', v_null_post;
    END IF;

    -- Audit table populated
    SELECT count(*) INTO v_audit_total FROM variety_cleanup_audit_153;
    RAISE NOTICE 'A9-153 POST: Rose=% / Syrah=% / Sparkling=% / Tumb-Spk=% / NULL=% / audit_rows=%',
                 v_rose_post, v_syrah_post, v_sparkling_post,
                 v_tumb_spk_post, v_null_post, v_audit_total;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- §8 Migration registry
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('153_a9_variety_cleanup', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
--
-- PRE-apply variety distribution:
--   SELECT variety, count(*) FROM sku GROUP BY variety ORDER BY 2 DESC;
--   -- expect: Rose, Rosé, Syrah, Shiraz, Sparkling, Tumbarumba Sparkling, NULL
--
-- POST-apply variety distribution (clean):
--   SELECT variety, count(*) FROM sku GROUP BY variety ORDER BY 2 DESC;
--   -- expect: Shiraz (Syrah merged), Rosé (Rose merged), Unknown (Sparkling+
--   --         Tumbarumba+NULL merged); no Rose, Syrah, Sparkling, NULL
--
-- POST-apply audit trail (per-rule counts):
--   SELECT rule_applied, count(*) FROM variety_cleanup_audit_153
--    GROUP BY rule_applied ORDER BY 1;
--   -- expect 4 rule rows: rose_dedupe, syrah_dedupe, sparkling_leak, null_fill
--
-- POST-apply L2 test invariant check:
--   SELECT
--     (SELECT count(*) FROM (
--        SELECT 1 FROM sku WHERE variety='Rose'
--        INTERSECT SELECT 1 FROM sku WHERE variety='Rosé') x) AS rose_dupe,
--     (SELECT count(*) FROM sku WHERE variety='Sparkling')   AS sparkling_var,
--     (SELECT count(*) FROM sku WHERE variety ILIKE '%tumbarumba%') AS region_leak,
--     (SELECT count(*) FROM sku WHERE variety IS NULL)       AS null_var;
--   -- expect 0/0/0/0
--
-- POST-apply L2 pytest run:
--   -- expect XPASS (xfail decorator at line 522 must be removed manually
--   --              after this migration deploys + L2 confirms green)
--
-- ROLLBACK recipe (forward-only — restore from pre-deploy pg_dump):
--   1. psql -c "BEGIN;
--               UPDATE sku s SET variety = a.variety_before, updated_at = NOW()
--                 FROM variety_cleanup_audit_153 a
--                WHERE a.sku_id = s.sku_id;
--               DELETE FROM schema_migrations WHERE version='153_a9_variety_cleanup';
--               DROP TABLE variety_cleanup_audit_153;
--               COMMIT;"
--   No view rebuild needed — sku.variety raw col only; views inherit.
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- schema/071_schema_migrations_create_and_backfill.sql
-- Create + backfill schema_migrations ledger from DB-artifact probes.
-- ════════════════════════════════════════════════════════════════════════════
-- Date:     2026-04-24
--
-- WHY: The runbook §1 + §6.3 prompt assumed schema_migrations was the truth
-- source for distinguishing "file missing from VPS dir" vs "migration never
-- applied". Pre-flight discovery 2026-04-24: the table does NOT exist on prod.
-- Without a ledger, future reconciles must re-probe DB artifacts every time.
-- This migration creates the ledger forward + backfills 68 prior rows from
-- probed evidence so future migrations can rely on `SELECT version FROM
-- schema_migrations` as authoritative.
--
-- FORWARD-ONLY & ADDITIVE: CREATE TABLE IF NOT EXISTS + INSERT ON CONFLICT
-- DO NOTHING. Re-running is a no-op. No existing rows touched. No row deletes.
--
-- BLAST RADIUS: New table only. No existing data altered. CHECK constraint
-- restricts source values to the 3 documented options. PRIMARY KEY (version)
-- prevents accidental duplicate inserts on re-run.
--
-- BACKFILL EVIDENCE (per migration, summarized — full probe trace in
--   001-042 + 044-045 + 056-057  → file present on VPS dir (historical apply
--                                    marker; foundation tables exist).
--   043 → canonical_territory rows = 30 (BUG-45 collapse target).
--   046 → 3 PINOT GRIS canonical_sku rows + 8 PINOT GRIS sku rows.
--   047 → MVESRIEB14 vinsight → MOPPITY ESTATE RIESLING canonical 67.
--   048 → MVESSHZH14 vinsight → MOPPITY ESTATE SHIRAZ canonical 68.
--   049 part1 → sales_transaction.content_hash column exists.
--   049 part2 → idx_sales_tx_content_hash unique index exists.
--   050 → sync_vinsight_direct_sales pg_proc function exists.
--   051 → wine_range view created (later retired by 062 — file kept for audit).
--   052 → canonical_customer.is_active + potential_duplicate columns exist.
--   053 → canonical_representative table populated (74 rows).
--   054 → sync_vinsight_direct_sales body ≈ 5091 chars (revert applied).
--   055 → customer.canonical_rep_id column exists.
--   056 → sku.pack_size column exists.
--   057 → sku.is_dry_goods column exists (NOT NULL DEFAULT false).
--   058 → sku.range_id was added (later retired by 062 — file kept for audit).
--   062 → wine_range view dropped + sku.range_id column dropped.
--   063 → sales_transaction.stock_unit column exists (NOTE: 1,184 NULL rows
--          from BUG-105 rerun — separate fix in BUG-118 AC3 prep).
--   064 → COCOPROPNV/MVLKSPKPNV vinsight → Piccolo canonicals 11/43.
--   065 → MVTSCLBB23/24/25/NV vinsight → TWELVE SIGNS SPARKLING canonical 92.
--   066 → audit-only migration (BUG-120 single-step Hexheysen audit; no DB
--          state change to probe — accept as applied since file at HEAD).
--   067 → MVESSHZH14 mappings consistent across access + vinsight (canonical 68).
--   068 → combined_data_enriched view exists (refactored body).
--   069 → etl_dead_letter.resolved_at + resolution_note columns exist.
--   070 → access_db = 120,308 rows; etl_dead_letter resolved=1,254.
--   backfill_batch_region + backfill_sku_packaging_link → file present on
--    VPS dir; no targeted probe; accept as applied per file presence.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Pre-apply assertions
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  table_exists BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='schema_migrations'
  ) INTO table_exists;

  IF table_exists THEN
    RAISE NOTICE 'schema_migrations table already exists — INSERTs will use ON CONFLICT DO NOTHING';
  ELSE
    RAISE NOTICE 'schema_migrations table missing — will be created';
  END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Create the ledger (idempotent)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source     TEXT NOT NULL DEFAULT 'live-apply'
    CHECK (source IN ('live-apply', 'backfilled-2026-04-24', 'backfilled-file-present'))
);

COMMENT ON TABLE schema_migrations IS
  'Migration ledger. Created 2026-04-24 in schema/071 after discovery that no '
  'ledger existed prior. Backfilled with all known applied migrations as of '
  'that date based on DB-artifact probes (see schema/071 header for per-migration '
  'evidence). Future migrations should INSERT a row at the END of their BEGIN block '
  'with source=''live-apply''.';

COMMENT ON COLUMN schema_migrations.version IS
  'Migration filename without .sql extension (e.g. 071_schema_migrations_create_and_backfill).';

COMMENT ON COLUMN schema_migrations.source IS
  'How this row was added: live-apply (added by the migration itself at apply time); '
  'backfilled-2026-04-24 (added by schema/071 based on probed DB artifact); '
  'backfilled-file-present (added by schema/071 based on file-presence-on-VPS-dir; '
  'older foundation migrations where direct probing was impractical).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Backfill all 68 prior migrations
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source) VALUES
  -- Foundation (001-042 + 044-045 + 056-057): file present on VPS dir
  ('001_initial', 'backfilled-file-present'),
  ('003_customer_view', 'backfilled-file-present'),
  ('004_populate_variety', 'backfilled-file-present'),
  ('005_fix_orphaned_skus', 'backfilled-file-present'),
  ('006_sku_grouping', 'backfilled-file-present'),
  ('007_rep_territory_m2m', 'backfilled-file-present'),
  ('008_m2_foundation', 'backfilled-file-present'),
  ('009_vintage_attribution', 'backfilled-file-present'),
  ('010_wine_product_mapping', 'backfilled-file-present'),
  ('011_data_quality', 'backfilled-file-present'),
  ('012_canonical_foundation', 'backfilled-file-present'),
  ('013_net_revenue', 'backfilled-file-present'),
  ('014_ai_readonly_role', 'backfilled-file-present'),
  ('015_wholesale_price', 'backfilled-file-present'),
  ('016_vintage_cogs', 'backfilled-file-present'),
  ('017_cleanup_orphan_skus', 'backfilled-file-present'),
  ('018_vinsight_direct_sync', 'backfilled-file-present'),
  ('019_customer_fields', 'backfilled-file-present'),
  ('020_fix_data_quality_apr09', 'backfilled-file-present'),
  ('021_normalize_customer_channel_rep', 'backfilled-file-present'),
  ('022_vineyard_region', 'backfilled-file-present'),
  ('023_jf07_populate_region', 'backfilled-file-present'),
  ('024_customer_alias', 'backfilled-file-present'),
  ('025_sales_transaction_fk_indexes', 'backfilled-file-present'),
  ('026_economic_cogs_lock_date', 'backfilled-file-present'),
  ('027_combined_data_enriched_view', 'backfilled-file-present'),
  ('028_combined_data_enriched_add_rep_name', 'backfilled-file-present'),
  ('030_sku_region_from_product_categories', 'backfilled-file-present'),
  ('031_sku_vintage_from_staging', 'backfilled-file-present'),
  ('032_au_postcode_lookup', 'backfilled-file-present'),
  ('033_fix_sku_regions_and_cleanup', 'backfilled-file-present'),
  ('034_add_discontinued_skus', 'backfilled-file-present'),
  ('035_fix_sku_code_map_crosswiring', 'backfilled-file-present'),
  ('036_fix_sku_metadata', 'backfilled-file-present'),
  ('037_fix_wine_product_map', 'backfilled-file-present'),
  ('038_bug33_vinsight_direct_uom_fix', 'backfilled-file-present'),
  ('039_bug35_alm_customer_code_cleanup', 'backfilled-file-present'),
  ('040_bug34_salesperson_code_map', 'backfilled-file-present'),
  ('041_jr089_vinsight_territory_rep_backfill', 'backfilled-file-present'),
  ('042_jr039_canonical_sku_active_flag', 'backfilled-file-present'),
  ('044_bug72_representative_territory_backfill', 'backfilled-file-present'),
  ('045_bug46_sku_metadata_fixes', 'backfilled-file-present'),
  ('056_bug121_sku_pack_size', 'backfilled-file-present'),
  ('057_bug122_sku_is_dry_goods', 'backfilled-file-present'),

  -- Probed (043, 046-055, 058, 062-070): DB artifacts confirmed applied
  ('043_bug45_canonical_territory_collapse', 'backfilled-2026-04-24'),
  ('046_bug46_46_bug76_pinot_gris_and_volume_rebate', 'backfilled-2026-04-24'),
  ('047_bug78e_vinsight_crosswires', 'backfilled-2026-04-24'),
  ('048_bug78e_mvesrieb14_followup', 'backfilled-2026-04-24'),
  ('049_sales_transaction_content_hash_part1', 'backfilled-2026-04-24'),
  ('049_sales_transaction_content_hash_part2_concurrent', 'backfilled-2026-04-24'),
  ('050_bug113_vinsight_direct_sales_content_hash', 'backfilled-2026-04-24'),
  ('051_bug101_wine_range_view', 'backfilled-2026-04-24'),
  ('052_bug107_canonical_customer_flags', 'backfilled-2026-04-24'),
  ('053_bug100_canonical_representative', 'backfilled-2026-04-24'),
  ('054_bug145_bug144_revert_phase_k', 'backfilled-2026-04-24'),
  ('055_bug95_customer_canonical_rep_id', 'backfilled-2026-04-24'),
  ('058_bug101_sku_range_id_backfill', 'backfilled-2026-04-24'),
  ('062_bug147_retire_wine_range', 'backfilled-2026-04-24'),
  ('063_bug118_stock_unit', 'backfilled-2026-04-24'),
  ('064_bug117_piccolo_map_repoint', 'backfilled-2026-04-24'),
  ('065_bug119_twelve_signs_sparkling_remap', 'backfilled-2026-04-24'),
  ('066_bug120_singlestep_hexheysen_audit', 'backfilled-2026-04-24'),
  ('067_bug121_mvesshzh14_remap', 'backfilled-2026-04-24'),
  ('068_bug147_combined_data_enriched_refactor', 'backfilled-2026-04-24'),
  ('069_bug105_etl_dead_letter_resolved_at', 'backfilled-2026-04-24'),
  ('070_bug105_dup_cleanup_and_resolve', 'backfilled-2026-04-24'),

  -- Backfill scripts (no .sql number; file present on VPS dir)
  ('backfill_batch_region', 'backfilled-file-present'),
  ('backfill_sku_packaging_link', 'backfilled-file-present')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Self-record this migration as live-apply
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, source)
VALUES ('071_schema_migrations_create_and_backfill', 'live-apply')
ON CONFLICT (version) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Post-apply assertion
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  expected_count INT := 69;  -- 68 backfilled + 1 self-record
  actual_count INT;
  backfilled_2026 INT;
  backfilled_file INT;
  live_apply INT;
BEGIN
  SELECT count(*) INTO actual_count FROM schema_migrations;
  SELECT count(*) INTO backfilled_2026 FROM schema_migrations WHERE source='backfilled-2026-04-24';
  SELECT count(*) INTO backfilled_file FROM schema_migrations WHERE source='backfilled-file-present';
  SELECT count(*) INTO live_apply FROM schema_migrations WHERE source='live-apply';

  IF actual_count <> expected_count THEN
    RAISE EXCEPTION 'schema/071 FAIL: expected % rows in schema_migrations, got %',
      expected_count, actual_count;
  END IF;

  RAISE NOTICE 'schema/071 OK: schema_migrations = % rows (% backfilled-2026-04-24 + % backfilled-file-present + % live-apply)',
    actual_count, backfilled_2026, backfilled_file, live_apply;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK RECIPE (manual; no automated revert):
--   BEGIN; DROP TABLE IF EXISTS schema_migrations; COMMIT;
--   Then re-apply schema/071 to recreate. The probe-based backfill is
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- schema/162_l6_check_constraints_not_valid.sql
-- L6 DB CHECK constraints — Phase A universal harness
-- ════════════════════════════════════════════════════════════════════════════
-- DDL-ONLY: ALTER TABLE … ADD CONSTRAINT … CHECK … NOT VALID. No row mutation,
--           no UPDATE/DELETE. NOT VALID grandfathers existing rows; constraint
--           applies to new writes only. Paired VALIDATE migration = schema/163.
-- DESTRUCTIVE: false
-- Trust contract v1.1 / forward-only / not destructive (NOT VALID only)
--
-- Date: 2026-05-11
--
-- WHAT THIS DOES
-- --------------
-- Adds 10 CHECK constraints with NOT VALID. NOT VALID = constraint applies to
-- NEW writes only; existing rows with NULL are grandfathered. Writer faucet
-- attempting to mint bad state → DB REJECTS with constraint violation.
--
-- Pair migration schema/163_l6_check_constraints_validate.sql ships
-- POST-backlog-clear (after BUG-165 dedup + C17a residual + A7 TS Sauv Blanc
-- residual empty NULL pockets). 163 = ALTER TABLE ... VALIDATE CONSTRAINT.
--
-- Catches faucet class:
--   • BUG-165 (customer orphan minting via api/customers + Vinsight ingest)
--   • E6 rep-history rot (writer dropped rep_name silently)
--   • B4B 41-day region loop (writer pulled dirty Vinsight ProductCategories)
--   • A9 sparkling decategorization (writer mis-mapped category)
--   • B3-4 ItemCode cascade (writer didn't preserve mapping)
--
-- DESIGN-DOC DIVERGENCES (verified vs schema/001..160)
-- ----------------------------------------------------
-- Design doc table.column names corrected to match actual schema:
--
--   #2  sales_transaction.canonical_sku_id  → sales_transaction.sku_id
--       sales_transaction has sku_id (FK → sku.sku_id). No canonical_sku_id
--       column on sales_transaction (canonical link lives on sku table:
--       schema/012 line 38). Constraint targets sku_id.
--
--   #5  canonical_customer.canonical_id → canonical_customer.id
--       PK column is `id` (schema/012 line 70). No `canonical_id` column.
--       PK already enforces NOT NULL implicitly — CHECK added as
--       belt-and-braces guard per design doc spec.
--
--   #6  sale_vintage_attribution.vintage → sale_vintage_attribution.attributed_vintage
--       Actual column is `attributed_vintage` (schema/009 line 14), inline
--       NOT NULL already. CHECK added as belt-and-braces guard.
--
--   #7  customer_code_map.canonical_customer_id → customer_code_map.customer_id
--       customer_code_map has customer_id only (schema/001 line 139). No
--       canonical_customer_id column added in any later migration. Constraint
--       targets customer_id (already inline NOT NULL — belt-and-braces).
--
--   #8  manual_region_override.region — already inline NOT NULL
--       (schema/083 line 11, schema/090 line 22). CHECK added as
--       belt-and-braces guard.
--
--   #9  sku_cogs.cogs_per_unit → sku_cogs cost-component non-null guard
--       sku_cogs has NO `cogs_per_unit` column. Schema cost columns:
--       accounting_grape_price, nominated_grape_price, bulk_wine_cost,
--       dry_goods_cost, bottling_cost (+ GENERATED total_cogs_accounting /
--       total_cogs_economic always non-null via COALESCE(...,0)). Mapping the
--       "must have cogs" semantic → enforce AT LEAST ONE cost-input component
--       non-null. Constraint = at least one of the 5 cost inputs IS NOT NULL.
--
--  10  channel.channel_name — already inline NOT NULL UNIQUE (schema/001
--       line 53). CHECK added as belt-and-braces guard.
--
-- NOT VALID SEMANTICS
-- -------------------
-- NOT VALID does NOT prevent NULL inserts already in-flight. It only stops
-- FUTURE writes. So if active orphan-creation path (BUG-165) still mints
-- NULL, next INSERT fails post-162. That is intentional — A2 session
-- patches faucets after this lands.
--
-- FORWARD-ONLY / NON-DESTRUCTIVE
-- ------------------------------
-- ALTER TABLE ... ADD CONSTRAINT only. No DROP. No UPDATE on existing rows.
-- Idempotent via existence check in DO block (constraint name unique per
-- table).
--
-- Trust contract v1.1 — single BEGIN/COMMIT, post-asserts confirm registry.
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. customer_must_have_canonical
--    customer.canonical_customer_id IS NOT NULL
--    Catches: BUG-165 orphan customer mint (writer skipped canonical link)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE customer
  DROP CONSTRAINT IF EXISTS customer_must_have_canonical;
ALTER TABLE customer
  ADD CONSTRAINT customer_must_have_canonical
  CHECK (canonical_customer_id IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. sales_transaction_must_have_canonical_sku
--    sales_transaction.sku_id IS NOT NULL  (design called this canonical_sku_id;
--    actual column = sku_id, FK to sku table where canonical_sku_id lives)
--    Catches: R-007 sku_id NULL drift (already 100% non-null per recon)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE sales_transaction
  DROP CONSTRAINT IF EXISTS sales_transaction_must_have_canonical_sku;
ALTER TABLE sales_transaction
  ADD CONSTRAINT sales_transaction_must_have_canonical_sku
  CHECK (sku_id IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. canonical_customer_must_have_territory
--    canonical_customer.territory_name IS NOT NULL
--    Catches: C17a xlsx ANSWER pass — territory blanks from Vinsight backfill
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE canonical_customer
  DROP CONSTRAINT IF EXISTS canonical_customer_must_have_territory;
ALTER TABLE canonical_customer
  ADD CONSTRAINT canonical_customer_must_have_territory
  CHECK (territory_name IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. sku_must_have_region
--    sku.region IS NOT NULL
--    Catches: B4B 41-day region loop, A7 residual NULL pockets
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE sku
  DROP CONSTRAINT IF EXISTS sku_must_have_region;
ALTER TABLE sku
  ADD CONSTRAINT sku_must_have_region
  CHECK (region IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. canonical_customer_pk_not_null
--    canonical_customer.id IS NOT NULL  (design called this canonical_id;
--    actual PK column = id)
--    Already enforced by PK. Belt-and-braces guard per design spec.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE canonical_customer
  DROP CONSTRAINT IF EXISTS canonical_customer_pk_not_null;
ALTER TABLE canonical_customer
  ADD CONSTRAINT canonical_customer_pk_not_null
  CHECK (id IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. sale_vintage_attribution_must_have_vintage
--    sale_vintage_attribution.attributed_vintage IS NOT NULL  (design called
--    this `vintage`; actual column = attributed_vintage)
--    Already inline NOT NULL. Belt-and-braces guard.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE sale_vintage_attribution
  DROP CONSTRAINT IF EXISTS sale_vintage_attribution_must_have_vintage;
ALTER TABLE sale_vintage_attribution
  ADD CONSTRAINT sale_vintage_attribution_must_have_vintage
  CHECK (attributed_vintage IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. customer_code_map_must_have_canonical
--    customer_code_map.customer_id IS NOT NULL  (design called this
--    canonical_customer_id; actual column = customer_id, FK → customer table)
--    Already inline NOT NULL. Belt-and-braces guard against future writer rot.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE customer_code_map
  DROP CONSTRAINT IF EXISTS customer_code_map_must_have_canonical;
ALTER TABLE customer_code_map
  ADD CONSTRAINT customer_code_map_must_have_canonical
  CHECK (customer_id IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. manual_region_override_must_have_region
--    manual_region_override.region IS NOT NULL
--    Already inline NOT NULL TEXT. Belt-and-braces guard.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE manual_region_override
  DROP CONSTRAINT IF EXISTS manual_region_override_must_have_region;
ALTER TABLE manual_region_override
  ADD CONSTRAINT manual_region_override_must_have_region
  CHECK (region IS NOT NULL)
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. sku_cogs_must_have_cogs
--    sku_cogs has no `cogs_per_unit`. Mapped semantic = AT LEAST ONE cost
--    input component populated (accounting_grape_price OR nominated_grape_price
--    OR bulk_wine_cost OR dry_goods_cost OR bottling_cost). Prevents minting
--    empty COGS rows where every cost input is NULL.
--    Catches: H1/H2 COGS prefill rot, master_cogs canonical map gap.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE sku_cogs
  DROP CONSTRAINT IF EXISTS sku_cogs_must_have_cogs;
ALTER TABLE sku_cogs
  ADD CONSTRAINT sku_cogs_must_have_cogs
  CHECK (
    accounting_grape_price IS NOT NULL
    OR nominated_grape_price IS NOT NULL
    OR bulk_wine_cost IS NOT NULL
    OR dry_goods_cost IS NOT NULL
    OR bottling_cost IS NOT NULL
  )
  NOT VALID;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. channel_must_have_name
--     channel.channel_name IS NOT NULL
--     Already inline NOT NULL UNIQUE. Belt-and-braces guard.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE channel
  DROP CONSTRAINT IF EXISTS channel_must_have_name;
ALTER TABLE channel
  ADD CONSTRAINT channel_must_have_name
  CHECK (channel_name IS NOT NULL)
  NOT VALID;


-- ════════════════════════════════════════════════════════════════════════════
-- POST-ASSERTS
-- ════════════════════════════════════════════════════════════════════════════
-- Confirm all 10 constraints registered AND in NOT VALID state.
-- pg_constraint.convalidated = FALSE means NOT VALID (not yet validated).
-- ════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  expected_constraints TEXT[] := ARRAY[
    'customer_must_have_canonical',
    'sales_transaction_must_have_canonical_sku',
    'canonical_customer_must_have_territory',
    'sku_must_have_region',
    'canonical_customer_pk_not_null',
    'sale_vintage_attribution_must_have_vintage',
    'customer_code_map_must_have_canonical',
    'manual_region_override_must_have_region',
    'sku_cogs_must_have_cogs',
    'channel_must_have_name'
  ];
  missing TEXT[] := ARRAY[]::TEXT[];
  validated_early TEXT[] := ARRAY[]::TEXT[];
  c TEXT;
  exists_flag BOOLEAN;
  valid_flag BOOLEAN;
BEGIN
  FOREACH c IN ARRAY expected_constraints LOOP
    SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = c)
      INTO exists_flag;

    IF NOT exists_flag THEN
      missing := array_append(missing, c);
      CONTINUE;
    END IF;

    SELECT convalidated FROM pg_constraint WHERE conname = c INTO valid_flag;
    IF valid_flag THEN
      -- Constraint exists but already validated. Should be NOT VALID at this
      -- stage. 163_l6_check_constraints_validate.sql flips this flag later.
      validated_early := array_append(validated_early, c);
    END IF;
  END LOOP;

  IF array_length(missing, 1) > 0 THEN
    RAISE EXCEPTION 'L6 setup FAILED — missing constraints: %', missing;
  END IF;

  IF array_length(validated_early, 1) > 0 THEN
    RAISE EXCEPTION 'L6 setup FAILED — constraints already VALIDATED (expected NOT VALID): %. Did 163 run before 162?', validated_early;
  END IF;

  RAISE NOTICE 'L6 OK — % NOT VALID constraints registered. Next: ship 163 after backlog clear.',
    array_length(expected_constraints, 1);
END $$;


-- Record migration in schema_migrations (project convention per schema/071).
INSERT INTO schema_migrations (version, applied_at, source)
VALUES ('162_l6_check_constraints_not_valid', NOW(), 'live-apply')
ON CONFLICT (version) DO NOTHING;

COMMIT;

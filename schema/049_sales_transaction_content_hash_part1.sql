-- Migration 049 part 1: sales_transaction.content_hash — ETL idempotency key.
--
--
-- sales_transaction has no UNIQUE key that permits idempotent re-runs of
-- etl/transform_to_core.py + the other ingest scripts (schema/001_initial.sql
-- :243-261). A naive re-run duplicates 119k access_db rows. Phase K needs
-- ON CONFLICT DO NOTHING semantics so the transform can finish the B1 non-
-- wine-skip flip (see Phase K section, plan doc lines 362-388).
--
-- This file is part 1 of 2. It:
--   (a) adds content_hash as a nullable CHAR(64) column, then
--   (b) backfills it for every existing row using the SHA256 expression below.
-- Both statements are transaction-wrapped so a mid-run failure rolls back.
--
-- Part 2 (schema/049_sales_transaction_content_hash_part2_concurrent.sql)
-- creates the UNIQUE INDEX CONCURRENTLY and enforces NOT NULL. It must run
-- AFTER part 1 and OUTSIDE a transaction because CONCURRENTLY is not allowed
-- inside a txn block.
--
-- ============================================================================
-- Option D hash basis (pipe-joined, then SHA256):
--   source_system, source_ref, sku_id, customer_id, sale_date, quantity.
--
-- net_revenue is DELIBERATELY EXCLUDED from the hash under Option D.
-- Rationale (BUG-113, 2026-04-22):
--   * content_hash is an identity key, not a value signature. Identity fields
--     answer "is this the same logical row?" — source + ref + who + what +
--     when + how-much. Derived financial values (net_revenue, gross_revenue,
--     discount_amount, rebate_amount, wholesale_fee, economic_cogs_*) can
--     drift between ETL runs (formula amendments, downstream recomputes) and
--     must NOT be part of a stable idempotency key.
--   * BUG-110 AC3 dry-run on 2026-04-22 (early-11 session) found that the
--     119,124 prod access_db rows were populated with net_revenue = gross
--     (wholesale_fee stored as 0.00), whereas transform_to_core.py:671 at
--     HEAD computes net = gross - discount - rebate - wholesale_fee where
--     the raw Access DB WholesalerFee field has implausible values like
--     $N on a $105 sale. Including net_revenue in the hash makes every
--     row drift between data-at-rest and code-at-HEAD. Root cause tracked in
--     BUG-114 (data-quality fix, Owner-gated, Phase E batch).
--   * Option D preserves the owner's Mar 19 HARD "history must never drift" rule
--     by zeroing UPDATE traffic on historical rows.
--
-- Also deliberately excluded from the hash: discount_amount, rebate_amount,
-- wholesale_fee, unit_price, gross_revenue, economic_cogs_*, vintage. These
-- are post-bottling-amendable (the owner Mar 19 HARD) or downstream-recomputed
-- (calculate_economic_cogs.py NULL-fills economic columns).
--
-- Source-specific source_ref uniqueness (BUG-113 AC2 audit):
--   access_db = raw Access `ID` (unique 120,343/120,343 per AC1)
--   ALM       = f"ALM-{transaction_id}-{date}-{alm_code}"
--   DWS       = f"{REFNO}-{sku_code}" (REFNO present in all 271 prod rows)
--   DIRECT    = f"{invoice_or_order_num}-{sku_code}"
--   vinsight  = 'vinsight-' || order_num || '-' || entry_num
-- All prod sales_transaction rows verified 100% unique source_ref within
-- source_system; Option D hash is stable across the union.
-- ============================================================================

BEGIN;

ALTER TABLE sales_transaction
    ADD COLUMN content_hash CHAR(64);

UPDATE sales_transaction
SET content_hash = encode(
    sha256(
        (
            coalesce(source_system, '')       || '|' ||
            coalesce(source_ref, '')          || '|' ||
            coalesce(sku_id::text, '')        || '|' ||
            coalesce(customer_id::text, '')   || '|' ||
            sale_date::text                   || '|' ||
            quantity::text
        )::bytea
    ),
    'hex'
);

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- schema/106_grant_readonly_select_all.sql
-- Bundle: AICHAT-READONLY-GRANT-FIX-P1 — durable form of live GRANT
-- ════════════════════════════════════════════════════════════════════════════
-- Date:   2026-04-29
-- Bundle: AI Chat regression fix (Phase 1 close-out)
--
-- Problem (incident 2026-04-29):
--   AI Chat at /chat returned "permission denied for table sales_transaction"
--   on every business question. The dashboard's AI Chat connects as the
--   dedicated read-only user `moppity_readonly` (DATABASE_URL_READONLY in
--   dashboard/src/lib/db-readonly.ts), but that user only had SELECT on 3 of
--   107 public tables.
--
--   Root cause: B2 ETL ownership realign on 2026-04-27 changed table ownership
--   to `moppity` across 49 tables but did not preserve / re-apply the
--   GRANT SELECT to moppity_readonly that had previously been per-table.
--
-- Fix applied live to prod 2026-04-29 (this file makes it durable):
--   1. GRANT SELECT ON ALL TABLES IN SCHEMA public TO moppity_readonly
--   2. GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO moppity_readonly
--   3. ALTER DEFAULT PRIVILEGES so future ETL-created tables auto-grant
--   4. Best-effort grant on the postgres-owned view sales_transaction_normalized
--      (will NOTICE-skip if migration is not run as postgres)
--
-- Idempotent: GRANT/ALTER DEFAULT PRIVILEGES are no-ops if already granted.
--
-- Verification (post-apply):
--   psql -U moppity_readonly -d moppity_db -c "SELECT count(*) FROM sales_transaction;"
--   should return 120977 (was: ERROR: permission denied)
--
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- (1) Existing tables — bulk grant
GRANT SELECT ON ALL TABLES IN SCHEMA public TO moppity_readonly;

-- (2) Existing sequences — bulk grant
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO moppity_readonly;

-- (3) Future objects — auto-grant via default privileges
-- Applies to objects created by the role running this migration (moppity).
-- ETL scripts run as `moppity`, so any future tables they create will
-- auto-grant SELECT to moppity_readonly without manual intervention.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO moppity_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO moppity_readonly;

-- (4) Postgres-owned view — best-effort grant
-- sales_transaction_normalized is currently owned by `postgres` (not `moppity`),
-- so a moppity-run migration cannot GRANT on it. Wrap in DO $$ to NOTICE-skip
-- gracefully. To enable AI Chat reads on this view, either:
--   (a) run this block as the postgres superuser, OR
--   (b) first run: ALTER VIEW public.sales_transaction_normalized OWNER TO moppity;
DO $$
BEGIN
  GRANT SELECT ON public.sales_transaction_normalized TO moppity_readonly;
  RAISE NOTICE 'schema/106: granted SELECT on sales_transaction_normalized to moppity_readonly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'schema/106: cannot grant on sales_transaction_normalized (owned by another role) — run as postgres or first: ALTER VIEW sales_transaction_normalized OWNER TO moppity';
  WHEN undefined_table THEN
    RAISE NOTICE 'schema/106: sales_transaction_normalized absent — skipping';
END $$;

-- (5) Verification log
DO $$
DECLARE
  readable_tables INT;
  readable_views INT;
BEGIN
  SELECT count(*) INTO readable_tables
    FROM pg_tables
    WHERE schemaname = 'public'
      AND has_table_privilege('moppity_readonly', schemaname || '.' || tablename, 'SELECT');
  SELECT count(*) INTO readable_views
    FROM pg_views
    WHERE schemaname = 'public'
      AND has_table_privilege('moppity_readonly', schemaname || '.' || viewname, 'SELECT');
  RAISE NOTICE 'schema/106 post-apply: moppity_readonly can SELECT from % tables + % views in public schema', readable_tables, readable_views;
END $$;

INSERT INTO schema_migrations (version, applied_at)
VALUES ('106_grant_readonly_select_all', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

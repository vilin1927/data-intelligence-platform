# Data Intelligence Platform

A data platform for an Australian wine producer. It brings sales, stock, production costing and
accounting data from four business systems into one PostgreSQL database. A Next.js dashboard sits
on top, with an AI assistant that answers business questions in plain English.

## Architecture

```
Vinsight REST API ──┐
Xero (OAuth 2.0) ───┤  connectors/  ──►  staging_* tables (raw JSON per source)
Google Sheets ──────┤                          │
MS Access exports ──┤  etl/  ──────────────────┤  mapping, de-duplication, cost attribution
Distributor files ──┘                          ▼
(DWS, ALM, Direct)                  canonical_* master data (SKU, customer, rep, territory)
                                    sales_transaction fact table + cost model
                                    reporting views
                                               │
                                    dashboard/  Next.js API routes + pages
                                               │
                                    AI assistant (agent with SQL tools)
```

## AI assistant

- Vercel AI SDK with an Anthropic model (`dashboard/src/app/api/chat/route.ts`). Answers stream to the
  UI; each tool call shows as a source badge with its result table.
- Agent loop, up to 5 steps per question, with 11 tools (`dashboard/src/lib/ai-tools.ts`):
  10 typed business tools built on fixed SQL templates (margin ranking, sales summary, sales by
  customer and territory, inventory cover, wine profile, channel comparison, price analysis,
  distributor reconciliation, KPI overview) and 1 text-to-SQL fallback. Text inputs are passed as
  query parameters; numeric inputs are range-checked with zod before they reach the SQL.
- Text-to-SQL guard (`dashboard/src/lib/ai-sql-fallback.ts`): a single SELECT/WITH statement only,
  write and admin keywords blocked, `;` and SQL comments rejected, results capped at 500 rows,
  optional table allowlist. Queries go through a separate connection pool meant for a SELECT-only
  database role with a 5 second statement timeout (`schema/014_ai_readonly_role.sql`).
- The system prompt holds the business rules and the join paths between the three product-code
  systems the data comes from (`dashboard/src/lib/ai-system-prompt.ts`).
- Regression set: `tests/ai-chat-baseline/questions.json` (question, expected tools, required terms,
  forbidden error patterns), run against a live instance by `scripts/ai-chat-smoke.sh`.

## Data pipeline

- `connectors/`: Vinsight (rate-limited REST, raw JSON into staging), Xero (OAuth 2.0 token refresh,
  two company tenants), Google Sheets (service account).
- `etl/`: importers for distributor files (DWS, ALM including EDI, Direct) with duplicate detection
  and post-import reconciliation; canonical SKU / customer / rep mapping; vintage attribution; an
  "economic" cost of goods with a configurable grape-price cascade next to the accounting cost;
  legacy MS Access report import (mdb-tools).
- Every ETL run writes a row to `etl_run_log`; rows that cannot be processed go to `etl_dead_letter`.
- `schema/`: PostgreSQL DDL history (tables, views, functions, constraints, read-only role).
  One-off data-fix migrations were removed from this copy, so the folder is for reading the data
  model, not for replaying from an empty database.

## Dashboard

Overview, sales, margin, wine profiles, inventory, reference data, legacy reports, an upload wizard
for distributor files with preview and matching, admin tools for unmatched customers and SKUs, and
the AI chat. Login is a shared password with an HMAC-signed session cookie (`dashboard/src/middleware.ts`).

## Quality checks

- `tests/`: pytest unit tests for parsers, filters, price lookup and upload logic (run offline).
- `scripts/`: data-integrity checks, drift tracker, migration lint, a guard check for canonical-ID
  updates, API smoke probe, backup with restore drill, post-deploy health checks.

## Stack

Python 3, psycopg2, PostgreSQL, Next.js 14, TypeScript, Tailwind CSS, Recharts, Vercel AI SDK, PM2.

## Running locally

```bash
cp .env.example .env                  # fill in values
pip install -r requirements-dev.txt
python -m pytest

cd dashboard
cp .env.example .env.local            # fill in values
npm ci
npm run dev
```

The dashboard needs a PostgreSQL database with this schema.

## Note

This is a portfolio copy of a production project. Credentials, client data, internal documents and
one-off data migrations were removed. Names of real people and customers in code comments and
examples were replaced with neutral labels.

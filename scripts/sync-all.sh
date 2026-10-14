#!/bin/bash
# Daily sync script for all data sources
# Runs via cron: 0 6 * * * /opt/moppity/scripts/sync-all.sh >> /var/log/moppity-sync.log 2>&1
# 6:00 AM AEST (UTC+10) = runs at 20:00 UTC previous day

set -euo pipefail

LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"
VENV="/opt/moppity/venv/bin/activate"
WORKDIR="/opt/moppity"
ENV_FILE="/opt/moppity/.env"

# Source credentials from .env file (never hardcode!)
if [ ! -f "$ENV_FILE" ]; then
    echo "$LOG_PREFIX ERROR: $ENV_FILE not found. Create it with required credentials."
    exit 1
fi

# Export all variables from .env file
set -a
source "$ENV_FILE"
set +a

# Validate required environment variables
REQUIRED_VARS="DATABASE_URL VINSIGHT_API_KEY XERO_CLIENT_ID XERO_CLIENT_SECRET GOOGLE_API_KEY"
for var in $REQUIRED_VARS; do
    if [ -z "${!var:-}" ]; then
        echo "$LOG_PREFIX ERROR: $var is not set in $ENV_FILE"
        exit 1
    fi
done

# Default for optional vars
export XERO_TOKEN_FILE="${XERO_TOKEN_FILE:-/opt/moppity/config/xero_tokens.json}"

cd "$WORKDIR"
source "$VENV"

echo "$LOG_PREFIX === Starting daily sync ==="

# 1. Vinsight
echo "$LOG_PREFIX [Vinsight] Starting..."
python3 -m connectors.vinsight && echo "$LOG_PREFIX [Vinsight] OK" || echo "$LOG_PREFIX [Vinsight] FAILED"

# 2. Vinsight COGS (WineBatches, Vessels, PackagingOperations, SalesOrderItems)
echo "$LOG_PREFIX [Vinsight COGS] Starting..."
python3 -m etl.sync_vinsight_cogs && echo "$LOG_PREFIX [Vinsight COGS] OK" || echo "$LOG_PREFIX [Vinsight COGS] FAILED"

# 3. Xero (both tenants)
echo "$LOG_PREFIX [Xero] Starting..."
python3 -m connectors.xero && echo "$LOG_PREFIX [Xero] OK" || echo "$LOG_PREFIX [Xero] FAILED"

# 4. Google Sheets
echo "$LOG_PREFIX [Sheets] Starting..."
python3 -m connectors.google_sheets && echo "$LOG_PREFIX [Sheets] OK" || echo "$LOG_PREFIX [Sheets] FAILED"

# 5. Sync Vinsight Sales Order Items (line-item detail for COGS engine)
echo "$LOG_PREFIX [Sales Order Items] Starting..."
python3 -m etl.sync_sales_order_items && echo "$LOG_PREFIX [Sales Order Items] OK" || echo "$LOG_PREFIX [Sales Order Items] FAILED"

# 6. Build wine product map (SKU-to-wine-product linkage)
echo "$LOG_PREFIX [Wine Product Map] Starting..."
python3 -m etl.build_wine_product_map && echo "$LOG_PREFIX [Wine Product Map] OK" || echo "$LOG_PREFIX [Wine Product Map] FAILED"

# 7. Sync Vinsight Direct sales → sales_transaction
echo "$LOG_PREFIX [Vinsight Direct] Syncing to sales_transaction..."
PGPASSWORD=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p') \
  psql "$DATABASE_URL" -c "SELECT * FROM sync_vinsight_direct_sales();" \
  && echo "$LOG_PREFIX [Vinsight Direct] OK" \
  || echo "$LOG_PREFIX [Vinsight Direct] FAILED"

echo "$LOG_PREFIX === Daily sync complete ==="

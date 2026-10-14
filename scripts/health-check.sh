#!/bin/bash
# Quick health check for all Moppity services
# Run this anytime to verify everything is working

echo "=== Moppity Health Check — $(date) ==="
echo ""

# PostgreSQL
echo "--- PostgreSQL ---"
if systemctl is-active --quiet postgresql; then
    echo "Status: ✅ Running"
    TABLE_COUNT=$(sudo -u postgres psql -d moppity_db -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' ')
    echo "Public tables: $TABLE_COUNT"
    DB_SIZE=$(sudo -u postgres psql -d moppity_db -t -c "SELECT pg_size_pretty(pg_database_size('moppity_db'));" 2>/dev/null | tr -d ' ')
    echo "Database size: $DB_SIZE"
else
    echo "Status: ❌ NOT RUNNING"
fi
echo ""

# Next.js Dashboard (PM2)
echo "--- Dashboard (PM2) ---"
if pm2 list 2>/dev/null | grep -q "moppity-dashboard"; then
    PM2_STATUS=$(pm2 list 2>/dev/null | grep "moppity-dashboard" | awk '{print $10}')
    echo "Status: $PM2_STATUS"
    PM2_UPTIME=$(pm2 list 2>/dev/null | grep "moppity-dashboard" | awk '{print $12}')
    echo "Uptime: $PM2_UPTIME"
else
    echo "Status: ❌ NOT RUNNING"
fi
echo ""

# nginx
echo "--- nginx ---"
if systemctl is-active --quiet nginx; then
    echo "Status: ✅ Running"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null)
    echo "HTTP response: $HTTP_CODE"
else
    echo "Status: ❌ NOT RUNNING"
fi
echo ""

# Disk Space
echo "--- Disk Space ---"
DISK_USED=$(df -h / | tail -1 | awk '{print $5}')
DISK_AVAIL=$(df -h / | tail -1 | awk '{print $4}')
echo "Used: $DISK_USED | Available: $DISK_AVAIL"
echo ""

# Last ETL Runs
echo "--- Last 5 ETL Runs ---"
sudo -u postgres psql -d moppity_db -c "SELECT source, status, rows_processed, error_count, started_at FROM etl_run_log ORDER BY started_at DESC LIMIT 5;" 2>/dev/null || echo "ETL log table not yet created"
echo ""

# Backups
echo "--- Recent Backups ---"
ls -lh /opt/moppity/backups/*.sql.gz 2>/dev/null | tail -3 || echo "No backups found"
echo ""

echo "=== Health Check Complete ==="

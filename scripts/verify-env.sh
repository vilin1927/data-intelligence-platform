#!/bin/bash
# Verify that the VPS environment is correctly set up
# Run this after initial setup or after any infrastructure changes

echo "=== Moppity VPS Environment Verification ==="
echo ""

PASS=0
FAIL=0

check() {
    if eval "$2" > /dev/null 2>&1; then
        echo "✅ $1"
        PASS=$((PASS + 1))
    else
        echo "❌ $1"
        FAIL=$((FAIL + 1))
    fi
}

# System checks
check "PostgreSQL >=16 installed" "psql --version | grep -qE 'PostgreSQL\) (1[6-9]|2[0-9])'"
check "PostgreSQL running" "systemctl is-active --quiet postgresql"
check "Python >=3.12 available" "python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)'"
check "Node.js 20 installed" "node --version | grep -q 'v20'"
check "PM2 installed" "pm2 --version"
check "nginx installed" "nginx -v 2>&1"
check "nginx running" "systemctl is-active --quiet nginx"

# Database checks
check "moppity_db exists" "sudo -u postgres psql -lqt | grep -q moppity_db"
check "moppity user exists" "sudo -u postgres psql -c '\du' | grep -q moppity"

# Firewall checks
check "UFW enabled" "ufw status | grep -q 'Status: active'"
check "Port 22 open" "ufw status | grep -q '22.*ALLOW'"
check "Port 80 open" "ufw status | grep -q '80.*ALLOW'"
check "Port 443 open" "ufw status | grep -q '443.*ALLOW'"

# Directory checks
check "/opt/moppity exists" "test -d /opt/moppity"
check "Python venv exists" "test -d /opt/moppity/venv"
check "Backup directory exists" "test -d /opt/moppity/backups"
check "Log directory exists" "test -d /var/log/moppity"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ $FAIL -gt 0 ]; then
    echo "⚠️  Some checks failed. Review the items above."
    exit 1
else
    echo "✅ All checks passed. Environment is ready."
    exit 0
fi

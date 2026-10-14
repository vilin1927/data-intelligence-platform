#!/bin/bash
# =============================================================================
# Moppity Vineyards — Data Integrity Checks
# =============================================================================
# Runs 28 SQL checks against production moppity_db via SSH.
# Usage:
#   bash scripts/data-integrity-checks.sh            # All 28 checks
#   bash scripts/data-integrity-checks.sh --quick     # TIER 1 only (6 checks)
#   bash scripts/data-integrity-checks.sh --verbose   # All checks with full output
# Exit code: 0 if all TIER 1+2 pass, 1 if any TIER 1+2 fail
# =============================================================================

set -euo pipefail

VPS_HOST="root@${SERVER_HOST:-your-server-ip}"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
DB_CMD="sudo -u postgres psql -d moppity_db -t -c"

# --- Flags ---
QUICK=false
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        --quick)   QUICK=true ;;
        --verbose) VERBOSE=true ;;
    esac
done

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters ---
PASS_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0
TIER12_FAIL=0

# --- Helper: run a query on the VPS ---
# Returns trimmed output. On error (table missing, etc.), returns "ERROR: ..."
run_query() {
    local query="$1"
    local result
    result=$(ssh $SSH_OPTS "$VPS_HOST" "$DB_CMD \"$query\"" 2>&1) || true
    # Trim whitespace
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$result"
}

# --- Helper: check if result indicates a missing table ---
is_table_missing() {
    local result="$1"
    if echo "$result" | grep -qi "does not exist\|relation.*does not exist\|ERROR.*does not exist"; then
        return 0
    fi
    return 1
}

# --- Helper: print check result ---
print_pass() {
    local num="$1" name="$2" detail="$3"
    echo -e "  ${GREEN}PASS${NC}  #${num} ${name}: ${detail}"
    PASS_COUNT=$((PASS_COUNT + 1))
}

print_fail() {
    local num="$1" name="$2" detail="$3" tier="$4"
    echo -e "  ${RED}FAIL${NC}  #${num} ${name}: ${detail}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$tier" -le 2 ]; then
        TIER12_FAIL=$((TIER12_FAIL + 1))
    fi
}

print_info() {
    local num="$1" name="$2" detail="$3"
    echo -e "  ${YELLOW}INFO${NC}  #${num} ${name}: ${detail}"
    INFO_COUNT=$((INFO_COUNT + 1))
}

print_table_missing() {
    local num="$1" name="$2" table="$3"
    echo -e "  ${YELLOW}INFO${NC}  #${num} ${name}: TABLE NOT FOUND (${table})"
    INFO_COUNT=$((INFO_COUNT + 1))
}

# =============================================================================
echo ""
echo -e "${BOLD}=== Moppity Data Integrity Checks — $(date '+%Y-%m-%d %H:%M:%S') ===${NC}"
echo ""

# --- Test SSH connectivity first ---
echo -e "${CYAN}Connecting to VPS...${NC}"
SSH_TEST=$(ssh $SSH_OPTS "$VPS_HOST" "echo ok" 2>&1) || true
if [ "$SSH_TEST" != "ok" ]; then
    echo -e "${RED}FATAL: Cannot connect to VPS ($VPS_HOST)${NC}"
    echo "$SSH_TEST"
    exit 1
fi
echo -e "${GREEN}Connected.${NC}"
echo ""

# =============================================================================
# TIER 1: CRITICAL (6 checks)
# =============================================================================
echo -e "${BOLD}${RED}--- TIER 1: CRITICAL ---${NC}"

# --- Check 1: COGS coverage ---
RESULT=$(run_query "SELECT COUNT(*) FROM sales_transaction WHERE sale_date >= '2024-01-01' AND economic_cogs_per_unit IS NULL")
if is_table_missing "$RESULT"; then
    print_table_missing 1 "COGS coverage" "sales_transaction or economic_cogs_per_unit column"
else
    NULL_COGS=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL=$(run_query "SELECT COUNT(*) FROM sales_transaction WHERE sale_date >= '2024-01-01'" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_COGS * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        if echo "$PCT" | awk '{exit ($1 < 1) ? 0 : 1}' 2>/dev/null; then
            print_pass 1 "COGS coverage" "${NULL_COGS}/${TOTAL} null (${PCT}%)"
        else
            print_fail 1 "COGS coverage" "${NULL_COGS}/${TOTAL} null (${PCT}%) -- must be <1%" 1
        fi
    else
        print_fail 1 "COGS coverage" "No rows since 2024-01-01" 1
    fi
fi

# --- Check 2: COGS diversity ---
RESULT=$(run_query "SELECT COUNT(DISTINCT economic_cogs_per_unit) FROM sales_transaction WHERE economic_cogs_per_unit IS NOT NULL")
if is_table_missing "$RESULT"; then
    print_table_missing 2 "COGS diversity" "sales_transaction"
else
    DISTINCT_COGS=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$DISTINCT_COGS" -le 1 ] 2>/dev/null; then
        print_fail 2 "COGS diversity" "Only ${DISTINCT_COGS} distinct value(s) -- flat rate bug" 1
    else
        print_pass 2 "COGS diversity" "${DISTINCT_COGS} distinct values"
    fi
fi

# --- Check 3: No flat $22.50 ---
RESULT=$(run_query "SELECT COUNT(*) FROM sku WHERE transfer_cost = 22.50")
if is_table_missing "$RESULT"; then
    print_table_missing 3 "No flat \$22.50" "sku"
else
    FLAT_COUNT=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$FLAT_COUNT" -eq 0 ] 2>/dev/null; then
        print_pass 3 "No flat \$22.50" "0 SKUs with transfer_cost=22.50"
    else
        print_fail 3 "No flat \$22.50" "${FLAT_COUNT} SKUs still have transfer_cost=22.50" 1
    fi
fi

# --- Check 4: Sales row count ---
RESULT=$(run_query "SELECT COUNT(*) FROM sales_transaction")
if is_table_missing "$RESULT"; then
    print_table_missing 4 "Sales row count" "sales_transaction"
else
    ROW_COUNT=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$ROW_COUNT" -gt 100000 ] 2>/dev/null; then
        print_pass 4 "Sales row count" "${ROW_COUNT} rows"
    else
        print_fail 4 "Sales row count" "${ROW_COUNT} rows -- expected >100,000" 1
    fi
fi

# --- Check 5: Revenue sanity ---
RESULT=$(run_query "SELECT ROUND(COALESCE(SUM(net_revenue), 0)::numeric, 2) FROM sales_transaction")
if is_table_missing "$RESULT"; then
    print_table_missing 5 "Revenue sanity" "sales_transaction"
else
    TOTAL_REV=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    # Check bounds
    IS_NEG=$(echo "$TOTAL_REV < 0" | bc 2>/dev/null || echo "0")
    IS_HIGH=$(echo "$TOTAL_REV > 50000000" | bc 2>/dev/null || echo "0")
    if [ "$IS_NEG" = "1" ] || [ "$IS_HIGH" = "1" ]; then
        print_fail 5 "Revenue sanity" "\$${TOTAL_REV} -- out of bounds (0 to 50M)" 1
    else
        print_pass 5 "Revenue sanity" "\$${TOTAL_REV}"
    fi
fi

# --- Check 6: Region coverage ---
RESULT=$(run_query "SELECT COUNT(*) FROM sku s JOIN sales_transaction st ON st.sku_id = s.sku_id WHERE s.region IS NULL")
if is_table_missing "$RESULT"; then
    print_table_missing 6 "Region coverage" "sku/sales_transaction"
else
    NULL_REGION=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL_WITH_SKU=$(run_query "SELECT COUNT(*) FROM sku s JOIN sales_transaction st ON st.sku_id = s.sku_id" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL_WITH_SKU" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_REGION * 100 / $TOTAL_WITH_SKU" | bc 2>/dev/null || echo "0")
        if echo "$PCT" | awk '{exit ($1 < 5) ? 0 : 1}' 2>/dev/null; then
            print_pass 6 "Region coverage" "${NULL_REGION}/${TOTAL_WITH_SKU} null region (${PCT}%)"
        else
            print_fail 6 "Region coverage" "${NULL_REGION}/${TOTAL_WITH_SKU} null region (${PCT}%) -- must be <5%" 1
        fi
    else
        print_info 6 "Region coverage" "No SKU-linked sales found"
    fi
fi

echo ""

# --- Stop here if --quick ---
if [ "$QUICK" = true ]; then
    echo -e "${BOLD}=== Quick Mode: TIER 1 only ===${NC}"
    echo ""
    echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}  ${RED}FAIL: ${FAIL_COUNT}${NC}  ${YELLOW}INFO: ${INFO_COUNT}${NC}"
    echo ""
    if [ "$TIER12_FAIL" -gt 0 ]; then
        echo -e "${RED}RESULT: ${TIER12_FAIL} critical check(s) failed.${NC}"
        exit 1
    else
        echo -e "${GREEN}RESULT: All critical checks passed.${NC}"
        exit 0
    fi
fi

# =============================================================================
# TIER 2: HIGH (8 checks)
# =============================================================================
echo -e "${BOLD}${YELLOW}--- TIER 2: HIGH ---${NC}"

# --- Check 7: Region vintage consistency ---
RESULT=$(run_query "SELECT COUNT(*) FROM (SELECT variety, vintage, COUNT(DISTINCT region) as region_count FROM wine_batch WHERE region IS NOT NULL GROUP BY variety, vintage HAVING COUNT(DISTINCT region) > 1) sub")
if is_table_missing "$RESULT"; then
    print_table_missing 7 "Region vintage consistency" "wine_batch"
else
    MISMATCH=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$MISMATCH" -eq 0 ] 2>/dev/null; then
        print_pass 7 "Region vintage consistency" "No mismatches"
    else
        print_info 7 "Region vintage consistency" "${MISMATCH} variety+vintage combos have multiple regions"
        if [ "$VERBOSE" = true ]; then
            DETAIL=$(run_query "SELECT variety, vintage, COUNT(DISTINCT region) as regions FROM wine_batch WHERE region IS NOT NULL GROUP BY variety, vintage HAVING COUNT(DISTINCT region) > 1 ORDER BY vintage DESC LIMIT 10")
            echo "        $DETAIL"
        fi
    fi
fi

# --- Check 8: Territory on customers ---
RESULT=$(run_query "SELECT COUNT(*) FROM canonical_customer WHERE territory_name IS NULL OR territory_name = ''")
if is_table_missing "$RESULT"; then
    # Fall back to customer table
    RESULT=$(run_query "SELECT COUNT(*) FROM customer WHERE territory_id IS NULL")
    if is_table_missing "$RESULT"; then
        print_table_missing 8 "Territory on customers" "canonical_customer/customer"
    else
        NULL_TERR=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        TOTAL_CUST=$(run_query "SELECT COUNT(*) FROM customer" | head -1 | tr -d '[:space:]')
        PCT=$(echo "scale=2; $NULL_TERR * 100 / $TOTAL_CUST" | bc 2>/dev/null || echo "0")
        print_info 8 "Territory on customers (customer table)" "${NULL_TERR}/${TOTAL_CUST} null (${PCT}%)"
    fi
else
    NULL_TERR=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL_CUST=$(run_query "SELECT COUNT(*) FROM canonical_customer" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL_CUST" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_TERR * 100 / $TOTAL_CUST" | bc 2>/dev/null || echo "0")
        print_info 8 "Territory on customers" "${NULL_TERR}/${TOTAL_CUST} null (${PCT}%)"
    else
        print_info 8 "Territory on customers" "No customers found"
    fi
fi

# --- Check 9: SKU mapping completeness ---
RESULT=$(run_query "SELECT COUNT(*) FROM sku_code_map")
if is_table_missing "$RESULT"; then
    print_table_missing 9 "SKU mapping completeness" "sku_code_map"
else
    TOTAL_MAP=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    DWS_MAP=$(run_query "SELECT COUNT(*) FROM sku_code_map WHERE source_system = 'dws'" | head -1 | tr -d '[:space:]')
    UNMAPPED=$(run_query "SELECT COUNT(DISTINCT st.sku_id) FROM sales_transaction st WHERE st.source_system = 'DWS' AND NOT EXISTS (SELECT 1 FROM sku_code_map scm WHERE scm.sku_id = st.sku_id AND scm.source_system = 'dws')" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -z "$UNMAPPED" ] || echo "$UNMAPPED" | grep -qi "error"; then
        UNMAPPED="N/A"
    fi
    if [ "$UNMAPPED" != "N/A" ] && [ "$UNMAPPED" -lt 20 ] 2>/dev/null; then
        print_pass 9 "SKU mapping completeness" "Total: ${TOTAL_MAP}, DWS: ${DWS_MAP}, Unmapped DWS: ${UNMAPPED}"
    else
        print_info 9 "SKU mapping completeness" "Total: ${TOTAL_MAP}, DWS: ${DWS_MAP}, Unmapped DWS: ${UNMAPPED}"
    fi
fi

# --- Check 10: Customer mapping completeness ---
RESULT=$(run_query "SELECT COUNT(*) FROM customer_code_map")
if is_table_missing "$RESULT"; then
    # Try canonical_customer
    RESULT=$(run_query "SELECT COUNT(*) FROM canonical_customer")
    if is_table_missing "$RESULT"; then
        print_table_missing 10 "Customer mapping completeness" "customer_code_map/canonical_customer"
    else
        TOTAL=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        print_info 10 "Customer mapping completeness" "${TOTAL} canonical customers (customer_code_map not found)"
    fi
else
    TOTAL=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    print_info 10 "Customer mapping completeness" "${TOTAL} customer code mappings"
fi

# --- Check 11: Channel distribution ---
RESULT=$(run_query "SELECT source_system, COUNT(*) as cnt FROM sales_transaction GROUP BY source_system ORDER BY cnt DESC")
if is_table_missing "$RESULT"; then
    print_table_missing 11 "Channel distribution" "sales_transaction"
else
    # Format for single line
    DIST=$(echo "$RESULT" | grep -v '^$' | sed 's/|/:/g' | tr '\n' ', ' | sed 's/,$//')
    print_info 11 "Channel distribution" "$DIST"
fi

# --- Check 12: Duplicate detection ---
RESULT=$(run_query "SELECT COUNT(*) FROM (SELECT source_system, source_ref, COUNT(*) FROM sales_transaction WHERE source_ref IS NOT NULL GROUP BY source_system, source_ref HAVING COUNT(*) > 1) sub")
if is_table_missing "$RESULT"; then
    print_table_missing 12 "Duplicate detection" "sales_transaction"
else
    DUPS=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$DUPS" -eq 0 ] 2>/dev/null; then
        print_pass 12 "Duplicate detection" "0 duplicate source_ref per source_system"
    else
        print_fail 12 "Duplicate detection" "${DUPS} duplicate source_ref groups found" 2
        if [ "$VERBOSE" = true ]; then
            DETAIL=$(run_query "SELECT source_system, source_ref, COUNT(*) FROM sales_transaction WHERE source_ref IS NOT NULL GROUP BY source_system, source_ref HAVING COUNT(*) > 1 ORDER BY COUNT(*) DESC LIMIT 10")
            echo "        $DETAIL"
        fi
    fi
fi

# --- Check 13: Variety coverage ---
RESULT=$(run_query "SELECT COUNT(*) FROM sku s JOIN sales_transaction st ON st.sku_id = s.sku_id WHERE s.variety IS NULL")
if is_table_missing "$RESULT"; then
    print_table_missing 13 "Variety coverage" "sku"
else
    NULL_VAR=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL_SKU_SALES=$(run_query "SELECT COUNT(*) FROM sku s JOIN sales_transaction st ON st.sku_id = s.sku_id" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL_SKU_SALES" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_VAR * 100 / $TOTAL_SKU_SALES" | bc 2>/dev/null || echo "0")
        print_info 13 "Variety coverage" "${NULL_VAR}/${TOTAL_SKU_SALES} null variety (${PCT}%)"
    else
        print_info 13 "Variety coverage" "No SKU-linked sales found"
    fi
fi

# --- Check 14: Invoice format check ---
RESULT=$(run_query "SELECT source_ref FROM sales_transaction WHERE source_system IN ('vinsight', 'Vinsight', 'direct', 'Direct', 'DIRECT') AND source_ref IS NOT NULL LIMIT 5")
if is_table_missing "$RESULT"; then
    print_table_missing 14 "Invoice format check" "sales_transaction"
else
    SAMPLES=$(echo "$RESULT" | grep -v '^$' | head -5)
    # Check if any match the bad format "vinsight-xxxxx-xxxxx"
    BAD_FMT=$(echo "$SAMPLES" | grep -ci 'vinsight-' 2>/dev/null || echo "0")
    if [ "$BAD_FMT" -gt 0 ]; then
        print_fail 14 "Invoice format check" "Found 'vinsight-xxxxx' format refs (expected 6-digit numbers)" 2
    else
        SAMPLE_LINE=$(echo "$SAMPLES" | tr '\n' ', ' | sed 's/,$//')
        print_info 14 "Invoice format check" "Sample refs: ${SAMPLE_LINE}"
    fi
fi

echo ""

# =============================================================================
# TIER 3: MEDIUM (8 checks)
# =============================================================================
echo -e "${BOLD}${CYAN}--- TIER 3: MEDIUM ---${NC}"

# --- Check 15: Customer postcode coverage ---
RESULT=$(run_query "SELECT COUNT(*) FROM canonical_customer WHERE postcode IS NULL OR postcode = ''")
if is_table_missing "$RESULT"; then
    # Fall back to customer table
    RESULT=$(run_query "SELECT COUNT(*) FROM customer WHERE postcode IS NULL OR postcode = ''")
    if is_table_missing "$RESULT"; then
        print_table_missing 15 "Customer postcode coverage" "canonical_customer/customer"
    else
        NULL_PC=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        TOTAL=$(run_query "SELECT COUNT(*) FROM customer" | head -1 | tr -d '[:space:]')
        PCT=$(echo "scale=2; $NULL_PC * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        print_info 15 "Customer postcode coverage" "${NULL_PC}/${TOTAL} null (${PCT}%)"
    fi
else
    NULL_PC=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL=$(run_query "SELECT COUNT(*) FROM canonical_customer" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_PC * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        print_info 15 "Customer postcode coverage" "${NULL_PC}/${TOTAL} null (${PCT}%)"
    else
        print_info 15 "Customer postcode coverage" "No customers found"
    fi
fi

# --- Check 16: Customer suburb coverage ---
RESULT=$(run_query "SELECT COUNT(*) FROM canonical_customer WHERE suburb IS NULL OR suburb = ''")
if is_table_missing "$RESULT"; then
    RESULT=$(run_query "SELECT COUNT(*) FROM customer WHERE suburb IS NULL OR suburb = ''")
    if is_table_missing "$RESULT"; then
        print_table_missing 16 "Customer suburb coverage" "canonical_customer/customer"
    else
        NULL_SUB=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        TOTAL=$(run_query "SELECT COUNT(*) FROM customer" | head -1 | tr -d '[:space:]')
        PCT=$(echo "scale=2; $NULL_SUB * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        print_info 16 "Customer suburb coverage" "${NULL_SUB}/${TOTAL} null (${PCT}%)"
    fi
else
    NULL_SUB=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL=$(run_query "SELECT COUNT(*) FROM canonical_customer" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_SUB * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        print_info 16 "Customer suburb coverage" "${NULL_SUB}/${TOTAL} null (${PCT}%)"
    else
        print_info 16 "Customer suburb coverage" "No customers found"
    fi
fi

# --- Check 17: Rep coverage ---
RESULT=$(run_query "SELECT COUNT(*) FROM canonical_customer WHERE rep_name IS NULL OR rep_name = ''")
if is_table_missing "$RESULT"; then
    # Fall back to customer table
    RESULT=$(run_query "SELECT COUNT(*) FROM customer WHERE rep_id IS NULL")
    if is_table_missing "$RESULT"; then
        print_table_missing 17 "Rep coverage" "canonical_customer/customer"
    else
        NULL_REP=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        TOTAL=$(run_query "SELECT COUNT(*) FROM customer" | head -1 | tr -d '[:space:]')
        PCT=$(echo "scale=2; $NULL_REP * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        print_info 17 "Rep coverage" "${NULL_REP}/${TOTAL} null (${PCT}%)"
    fi
else
    NULL_REP=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL=$(run_query "SELECT COUNT(*) FROM canonical_customer" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_REP * 100 / $TOTAL" | bc 2>/dev/null || echo "0")
        print_info 17 "Rep coverage" "${NULL_REP}/${TOTAL} null (${PCT}%)"
    else
        print_info 17 "Rep coverage" "No customers found"
    fi
fi

# --- Check 18: Territory name normalization ---
RESULT=$(run_query "SELECT COUNT(*) FROM (SELECT UPPER(territory_name) as tn, COUNT(DISTINCT territory_name) as variants FROM territory GROUP BY UPPER(territory_name) HAVING COUNT(DISTINCT territory_name) > 1) sub")
if is_table_missing "$RESULT"; then
    # Try canonical_territory
    RESULT=$(run_query "SELECT COUNT(*) FROM (SELECT UPPER(territory_name) as tn, COUNT(DISTINCT territory_name) as variants FROM canonical_territory GROUP BY UPPER(territory_name) HAVING COUNT(DISTINCT territory_name) > 1) sub")
    if is_table_missing "$RESULT"; then
        print_table_missing 18 "Territory name normalization" "territory/canonical_territory"
    else
        DUP_TERR=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        if [ "$DUP_TERR" -eq 0 ] 2>/dev/null; then
            print_pass 18 "Territory name normalization" "No case-variant duplicates"
        else
            print_info 18 "Territory name normalization" "${DUP_TERR} case-variant duplicate(s)"
        fi
    fi
else
    DUP_TERR=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$DUP_TERR" -eq 0 ] 2>/dev/null; then
        print_pass 18 "Territory name normalization" "No case-variant duplicates"
    else
        print_info 18 "Territory name normalization" "${DUP_TERR} case-variant duplicate(s)"
        if [ "$VERBOSE" = true ]; then
            DETAIL=$(run_query "SELECT territory_name FROM territory ORDER BY territory_name")
            echo "        $DETAIL"
        fi
    fi
fi

# --- Check 19: Period/date consistency ---
RESULT=$(run_query "SELECT COUNT(*) FROM (SELECT transaction_id, period, TO_CHAR(sale_date, 'YYYY-MM') as expected_period FROM sales_transaction WHERE period IS NOT NULL LIMIT 1000) sub WHERE period != expected_period")
if is_table_missing "$RESULT"; then
    print_table_missing 19 "Period/date consistency" "sales_transaction"
else
    MISMATCHES=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    if [ "$MISMATCHES" -eq 0 ] 2>/dev/null; then
        print_pass 19 "Period/date consistency" "0 mismatches (sampled 1000 rows)"
    else
        print_info 19 "Period/date consistency" "${MISMATCHES} mismatches in 1000-row sample"
        if [ "$VERBOSE" = true ]; then
            DETAIL=$(run_query "SELECT transaction_id, period, TO_CHAR(sale_date, 'YYYY-MM') as expected FROM sales_transaction WHERE period != TO_CHAR(sale_date, 'YYYY-MM') LIMIT 10")
            echo "        $DETAIL"
        fi
    fi
fi

# --- Check 20: Rebate distribution ---
RESULT=$(run_query "SELECT source_system, COUNT(*) FROM sales_transaction WHERE rebate_amount IS NOT NULL AND rebate_amount != 0 GROUP BY source_system ORDER BY source_system")
if is_table_missing "$RESULT"; then
    print_table_missing 20 "Rebate distribution" "sales_transaction"
else
    if [ -z "$RESULT" ]; then
        print_info 20 "Rebate distribution" "No non-zero rebates found"
    else
        DIST=$(echo "$RESULT" | grep -v '^$' | sed 's/|/:/g' | tr '\n' ', ' | sed 's/,$//')
        print_info 20 "Rebate distribution" "$DIST"
    fi
fi

# --- Check 21: Fee distribution ---
RESULT=$(run_query "SELECT source_system, COUNT(*) FROM sales_transaction WHERE wholesale_fee IS NOT NULL AND wholesale_fee != 0 GROUP BY source_system ORDER BY source_system")
if is_table_missing "$RESULT"; then
    print_table_missing 21 "Fee distribution" "sales_transaction"
else
    if [ -z "$RESULT" ]; then
        print_info 21 "Fee distribution" "No non-zero wholesale fees found"
    else
        DIST=$(echo "$RESULT" | grep -v '^$' | sed 's/|/:/g' | tr '\n' ', ' | sed 's/,$//')
        print_info 21 "Fee distribution" "$DIST"
    fi
fi

# --- Check 22: COGS lock dates ---
RESULT=$(run_query "SELECT COUNT(*) FROM sku_cogs WHERE lock_date IS NULL")
if is_table_missing "$RESULT"; then
    print_table_missing 22 "COGS lock dates" "sku_cogs"
else
    NULL_LOCK=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    TOTAL_COGS=$(run_query "SELECT COUNT(*) FROM sku_cogs" | head -1 | tr -d '[:space:]')
    if [ "$TOTAL_COGS" -gt 0 ] 2>/dev/null; then
        PCT=$(echo "scale=2; $NULL_LOCK * 100 / $TOTAL_COGS" | bc 2>/dev/null || echo "0")
        print_info 22 "COGS lock dates" "${NULL_LOCK}/${TOTAL_COGS} null lock_date (${PCT}%)"
    else
        print_info 22 "COGS lock dates" "No sku_cogs rows found"
    fi
fi

echo ""

# =============================================================================
# TIER 4: INFO (6 checks)
# =============================================================================
echo -e "${BOLD}--- TIER 4: INFO ---${NC}"

# --- Check 23: Table row counts ---
echo -e "  ${YELLOW}INFO${NC}  #23 Table row counts:"
INFO_COUNT=$((INFO_COUNT + 1))
for TBL in sales_transaction canonical_sku canonical_customer sku_code_map representative sku_cogs wine_batch; do
    RESULT=$(run_query "SELECT COUNT(*) FROM ${TBL}" 2>/dev/null)
    if is_table_missing "$RESULT"; then
        echo "        ${TBL}: TABLE NOT FOUND"
    else
        CNT=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
        echo "        ${TBL}: ${CNT}"
    fi
done

# --- Check 24: Last ETL run ---
RESULT=$(run_query "SELECT source, status, started_at FROM etl_run_log WHERE started_at = (SELECT MAX(started_at) FROM etl_run_log e2 WHERE e2.source = etl_run_log.source) ORDER BY started_at DESC")
if is_table_missing "$RESULT"; then
    print_table_missing 24 "Last ETL run" "etl_run_log"
else
    if [ -z "$RESULT" ]; then
        print_info 24 "Last ETL run" "No ETL runs recorded"
    else
        echo -e "  ${YELLOW}INFO${NC}  #24 Last ETL run per source:"
        INFO_COUNT=$((INFO_COUNT + 1))
        echo "$RESULT" | grep -v '^$' | while IFS= read -r line; do
            echo "        $line"
        done
    fi
fi

# --- Check 25: Data freshness ---
RESULT=$(run_query "SELECT MAX(sale_date) FROM sales_transaction")
if is_table_missing "$RESULT"; then
    print_table_missing 25 "Data freshness" "sales_transaction"
else
    LATEST=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
    print_info 25 "Data freshness" "Latest sale_date: ${LATEST}"
fi

# --- Check 26: Channel table ---
RESULT=$(run_query "SELECT channel_name, commercial_model FROM channel ORDER BY channel_id")
if is_table_missing "$RESULT"; then
    print_table_missing 26 "Channel table" "channel"
else
    CHANNELS=$(echo "$RESULT" | grep -v '^$' | sed 's/|/:/g' | tr '\n' ', ' | sed 's/,$//')
    print_info 26 "Channel table" "$CHANNELS"
fi

# --- Check 27: Region list ---
RESULT=$(run_query "SELECT DISTINCT region FROM sku WHERE region IS NOT NULL ORDER BY region")
if is_table_missing "$RESULT"; then
    print_table_missing 27 "Region list" "sku"
else
    REGIONS=$(echo "$RESULT" | grep -v '^$' | tr -s '[:space:]' | tr '\n' ', ' | sed 's/,$//' | sed 's/^,//')
    print_info 27 "Region list" "$REGIONS"
fi

# --- Check 28: Variety list ---
RESULT=$(run_query "SELECT DISTINCT variety FROM sku WHERE variety IS NOT NULL ORDER BY variety")
if is_table_missing "$RESULT"; then
    print_table_missing 28 "Variety list" "sku"
else
    VARIETIES=$(echo "$RESULT" | grep -v '^$' | tr -s '[:space:]' | tr '\n' ', ' | sed 's/,$//' | sed 's/^,//')
    print_info 28 "Variety list" "$VARIETIES"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "${BOLD}=== Summary ===${NC}"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}  ${RED}FAIL: ${FAIL_COUNT}${NC}  ${YELLOW}INFO: ${INFO_COUNT}${NC}"
echo ""

if [ "$TIER12_FAIL" -gt 0 ]; then
    echo -e "${RED}RESULT: ${TIER12_FAIL} TIER 1/2 check(s) failed. Exit code 1.${NC}"
    exit 1
else
    echo -e "${GREEN}RESULT: All TIER 1+2 checks passed. Exit code 0.${NC}"
    exit 0
fi

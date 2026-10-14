#!/usr/bin/env bash
# scripts/migration-consistency-lint.sh
# L0 — Migration self-consistency lint
#
# Purpose:
#   Catches internal contradictions inside a single schema/*.sql migration
#   BEFORE it runs. Pure static analysis; never connects to DB.
#
# Bug classes flagged:
#   A. UPDATE-body SET value vs POST-assert value mismatch for the same id
#      (e.g. SET territory_name='Internal' WHERE id=4124 but POST asserts
#      territory_name='Head Office' WHERE id=4124).
#   B. Comment-block target value (e.g. -- ...territory='Head Office') vs
#      body UPDATE value for the same id.
#   C. Header docstring PRE expected count vs PRE assertion guard range
#      (e.g. header says "78 NULL" but guard accepts 50..200).
#   D. schema_migrations ledger version vs filename mismatch (file is
#      schema/177_*.sql but ledger insert uses '178' or '199').
#   E. Sentinel id declared in header but NO body UPDATE for that id, or
#      a body UPDATE id never mentioned in header tally / per-id comment.
#   F. Forward-only-rule violation: DROP / RENAME / TRUNCATE / CASCADE
#      anywhere outside a comment.
#
# Motivating incident — 2026-05-20, schema/177_null_territory_backfill.sql:
#   Header line 32 said sentinel cc_id=4124 territory='Head Office'. Body
#   UPDATE on line 407 originally wrote SET territory_name='Internal'. POST
#   assertion on line 1313 checked territory_name='Head Office'. Result:
#   apply-time mid-txn abort and a fully rolled-back migration on prod.
#   at builder step. This script is that self-lint.
#
# Usage:
#   bash scripts/migration-consistency-lint.sh schema/177_null_territory_backfill.sql
#
# Exit: 0 = clean ; 1 = mismatch(es) found.
#
# Constraints: bash + awk + sed + grep only. No psql. No python deps.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

err()  { echo -e "${RED}[L0 RED]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[L0 GREEN]${NC} $*"; }
warn() { echo -e "${YELLOW}[L0 WARN]${NC} $*"; }

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  err "usage: $0 <schema/NNN_*.sql>"; exit 1
fi

BASENAME=$(basename "$FILE")
# Filename version (leading digits)
FILE_VERSION=$(echo "$BASENAME" | sed -n 's/^\([0-9]\{1,4\}\)_.*/\1/p')
[ -n "$FILE_VERSION" ] || FILE_VERSION=$(echo "$BASENAME" | sed -n 's/^\([0-9]\{1,4\}\).*/\1/p')

echo "═══════════════════════════════════════════════════════"
echo "L0 migration-consistency-lint: $BASENAME"
echo "  filename version token: ${FILE_VERSION:-<none>}"
echo "═══════════════════════════════════════════════════════"

PROBLEMS=0

# ─────────────────────────────────────────────────────────────
# Class F — forward-only rule: scan for DROP / RENAME / TRUNCATE / CASCADE
#   outside SQL comments. Allow inside -- ... or /* ... */ comments.
# ─────────────────────────────────────────────────────────────
# Strip line comments (everything after --), then scan for forbidden tokens.
# This won't strip block comments perfectly but catches the dominant case.
# Escape hatch: any line ending with `-- @L0-ALLOW: <reason>` is skipped.
# Use SPARINGLY — only for safety-verified DROP VIEW + CREATE VIEW patterns
# in atomic txn with documented zero-dependents check.
FORBIDDEN_HITS=$(awk '
  {
    line=$0
    # honor per-line escape hatch
    if (line ~ /@L0-ALLOW/) next
    # cut at first -- (line comment)
    idx=index(line,"--")
    if (idx>0) line=substr(line,1,idx-1)
    if (match(toupper(line), /(^|[^A-Z_])(DROP[ \t]+(TABLE|VIEW|INDEX|COLUMN|CONSTRAINT|MATERIALIZED|TYPE|FUNCTION)|ALTER[ \t]+TABLE[ \t]+[A-Za-z0-9_."]+[ \t]+DROP|RENAME[ \t]+(TO|COLUMN)|TRUNCATE|CASCADE)/)) {
      print NR ": " $0
    }
  }
' "$FILE" || true)

if [ -n "$FORBIDDEN_HITS" ]; then
  err "Class F — forward-only violation (DROP/RENAME/TRUNCATE/CASCADE found):"
  echo "$FORBIDDEN_HITS" | sed 's/^/    /'
  PROBLEMS=$((PROBLEMS+1))
fi

# ─────────────────────────────────────────────────────────────
# Class D — schema_migrations ledger version vs filename
# ─────────────────────────────────────────────────────────────
LEDGER_LINES=$(grep -nE "INSERT[ \t]+INTO[ \t]+schema_migrations" "$FILE" || true)
if [ -n "$LEDGER_LINES" ]; then
  # find the VALUES line that immediately follows or is on the same statement
  LEDGER_VERSION=$(awk '
    /INSERT[ \t]+INTO[ \t]+schema_migrations/ { in_ins=1 }
    in_ins && match($0, /VALUES[ \t]*\(/) {
      # grab the first quoted token after VALUES (
      rest=substr($0, RSTART+RLENGTH)
      if (match(rest, /'\''[^'\'']*'\''/)) {
        print substr(rest, RSTART+1, RLENGTH-2)
        exit
      }
    }
  ' "$FILE" || true)
  if [ -n "$LEDGER_VERSION" ] && [ -n "$FILE_VERSION" ]; then
    # ledger value may be "177" or "177_null_territory_backfill"; strip _suffix
    LEDGER_NUM=$(echo "$LEDGER_VERSION" | sed -n 's/^\([0-9]\{1,4\}\).*/\1/p')
    if [ -n "$LEDGER_NUM" ] && [ "$LEDGER_NUM" != "$FILE_VERSION" ]; then
      err "Class D — schema_migrations ledger version='$LEDGER_VERSION' but filename version='$FILE_VERSION'"
      PROBLEMS=$((PROBLEMS+1))
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Class A + B — per-id UPDATE vs POST-assert vs comment-block
# Parse strategy:
#   For each UPDATE block: walk forward until matching ';'. Capture
#     SET assignments AND the id from WHERE id = N.
#   For each POST DO-block IF/SELECT: capture id = N + asserted
#     col='val' pairs.
#   For each header per-id comment line `-- ── id=N ...` capture target
#     values (rep='X' and/or territory='Y') from the bracketed metadata.
# ─────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

UPD_FILE="$TMPDIR/updates.tsv"      # id<TAB>col<TAB>val<TAB>lineno
POST_FILE="$TMPDIR/posts.tsv"       # id<TAB>col<TAB>val<TAB>lineno
CMT_FILE="$TMPDIR/comments.tsv"     # id<TAB>col<TAB>val<TAB>lineno
HDR_IDS_FILE="$TMPDIR/header_ids.txt"
BODY_IDS_FILE="$TMPDIR/body_ids.txt"

# Pass 1: UPDATE statements — extract id + SET col=val pairs.
awk '
  BEGIN { in_upd=0; buf=""; start_ln=0 }
  /^[ \t]*UPDATE[ \t]+/ && !in_upd {
    in_upd=1; buf=$0; start_ln=NR; next
  }
  in_upd {
    buf=buf " " $0
    if (index($0,";")>0) {
      # parse buf
      id=""
      if (match(buf, /WHERE[ \t]+id[ \t]*=[ \t]*[0-9]+/)) {
        s=substr(buf,RSTART,RLENGTH)
        gsub(/[^0-9]/,"",s); id=s
      }
      if (id != "") {
        # extract SET segment up to WHERE
        set_seg=""
        if (match(buf, /SET[ \t]+.*WHERE/)) {
          set_seg=substr(buf,RSTART+3,RLENGTH-3-5)
        }
        # split on commas at top level (no nested parens in our migs)
        n=split(set_seg, parts, ",")
        for (i=1;i<=n;i++) {
          p=parts[i]
          # match col = '\''value'\''
          if (match(p, /[a-zA-Z_][a-zA-Z0-9_]*[ \t]*=[ \t]*'\''[^'\'']*'\''/)) {
            m=substr(p,RSTART,RLENGTH)
            # split on =
            eqp=index(m,"=")
            col=substr(m,1,eqp-1); gsub(/[ \t]/,"",col)
            val=substr(m,eqp+1); gsub(/^[ \t]*'\''/,"",val); gsub(/'\''[ \t]*$/,"",val)
            print id "\t" col "\t" val "\t" start_ln
          }
        }
      }
      in_upd=0; buf=""
    }
  }
' "$FILE" > "$UPD_FILE"

# Pass 2: POST assertion blocks — search lines of pattern
#   id = N  ... col = 'val'   within a few lines of each other inside DO $$ blocks.
# Simpler heuristic: any line `id = N` followed within 6 lines by `col = '...'`
# inside an IF NOT EXISTS / SELECT 1 / RAISE EXCEPTION cluster.
awk '
  {
    line=$0
    # only inspect lines inside DO $$ or IF EXISTS blocks; approximate by tracking DO $$
    if (match(line,/DO[ \t]+\$\$/)) in_do=1
    if (in_do && match(line,/END[ \t]+\$\$/)) in_do=2  # block ending
    if (in_do==0) next
    # capture id token
    if (match(line, /id[ \t]*=[ \t]*[0-9]+/)) {
      s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s)
      cur_id=s; cur_id_ln=NR
    }
    # capture col='val' if recent cur_id seen
    if (cur_id != "" && NR-cur_id_ln <= 8) {
      l=line
      while (match(l, /[a-zA-Z_][a-zA-Z0-9_]*[ \t]*=[ \t]*'\''[^'\'']*'\''/)) {
        m=substr(l,RSTART,RLENGTH)
        eqp=index(m,"=")
        col=substr(m,1,eqp-1); gsub(/[ \t]/,"",col)
        val=substr(m,eqp+1); gsub(/^[ \t]*'\''/,"",val); gsub(/'\''[ \t]*$/,"",val)
        # filter: only interesting cols for our class (territory_name, rep_name, etc)
        if (col ~ /^(territory_name|rep_name|customer_group|region|channel|suburb|state)$/) {
          print cur_id "\t" col "\t" val "\t" NR
        }
        l=substr(l,RSTART+RLENGTH)
      }
    }
    if (in_do==2) { in_do=0; cur_id=""; cur_id_ln=0 }
  }
' "$FILE" > "$POST_FILE"

# Pass 3: header per-id comment lines like  `-- ── id=N NAME ... [tag rep='X', territory='Y']`
awk '
  /^[ \t]*--.*id[ \t]*=[ \t]*[0-9]+/ {
    line=$0
    if (match(line, /id[ \t]*=[ \t]*[0-9]+/)) {
      s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); id=s
    } else { next }
    # scan for territory='..' rep='..'  AND  territory=Foo (unquoted in brackets is also seen)
    l=line
    while (match(l, /(rep|territory)[ \t]*=[ \t]*'\''[^'\'']*'\''/)) {
      m=substr(l,RSTART,RLENGTH)
      eqp=index(m,"=")
      col=substr(m,1,eqp-1); gsub(/[ \t]/,"",col)
      val=substr(m,eqp+1); gsub(/^[ \t]*'\''/,"",val); gsub(/'\''[ \t]*$/,"",val)
      # normalize: territory -> territory_name; rep -> rep_name
      if (col=="territory") col="territory_name"
      else if (col=="rep") col="rep_name"
      print id "\t" col "\t" val "\t" NR
      l=substr(l,RSTART+RLENGTH)
    }
  }
' "$FILE" > "$CMT_FILE"

# Collect distinct ids per source
awk -F'\t' '{print $1}' "$CMT_FILE"  | sort -u > "$HDR_IDS_FILE"
awk -F'\t' '{print $1}' "$UPD_FILE"  | sort -u > "$BODY_IDS_FILE"

# Class A — UPDATE vs POST mismatch per (id,col)
A_MISMATCH=$(awk -F'\t' '
  FNR==NR { upd[$1"|"$2]=$3; updln[$1"|"$2]=$4; next }
  {
    k=$1"|"$2
    if (k in upd && upd[k] != $3) {
      print "    id="$1" col="$2" UPDATE='\''"upd[k]"'\''@L"updln[k]" vs POST='\''"$3"'\''@L"$4
    }
  }
' "$UPD_FILE" "$POST_FILE" || true)

if [ -n "$A_MISMATCH" ]; then
  err "Class A — UPDATE body vs POST assertion mismatch:"
  echo "$A_MISMATCH"
  PROBLEMS=$((PROBLEMS+1))
fi

# Class B — header comment-target vs UPDATE body mismatch per (id,col)
B_MISMATCH=$(awk -F'\t' '
  FNR==NR { upd[$1"|"$2]=$3; updln[$1"|"$2]=$4; next }
  {
    k=$1"|"$2
    if (k in upd && upd[k] != $3) {
      print "    id="$1" col="$2" COMMENT='\''"$3"'\''@L"$4" vs UPDATE='\''"upd[k]"'\''@L"updln[k]
    }
  }
' "$UPD_FILE" "$CMT_FILE" || true)

if [ -n "$B_MISMATCH" ]; then
  err "Class B — header comment-target vs UPDATE body mismatch:"
  echo "$B_MISMATCH"
  PROBLEMS=$((PROBLEMS+1))
fi

# ─────────────────────────────────────────────────────────────
# Class C — header docstring expected count vs PRE assertion guard
# Look for header lines like "78 NULL" / "expected 78" / "applied : 70"
# and PRE-block guard ranges like "BETWEEN X AND Y" or "NOT BETWEEN".
# ─────────────────────────────────────────────────────────────
HDR_COUNT=$(awk '
  /^[ \t]*--/ {
    # patterns: "expected 78", "expected ~78", "78 NULL rows", "78 canonical"
    if (match($0, /expected[ \t]*~?[ \t]*[0-9]+/)) {
      m=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",m); print m; exit
    }
    if (match($0, /[0-9]+[ \t]+NULL[ \t]+(canonical|rows)/)) {
      m=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",m); print m; exit
    }
  }
' "$FILE" || true)

PRE_RANGE_LO=""
PRE_RANGE_HI=""
PRE_LN=""
if [ -n "$HDR_COUNT" ]; then
  read PRE_RANGE_LO PRE_RANGE_HI PRE_LN <<<"$(awk '
    /^[ \t]*--/ { next }
    /(BETWEEN|NOT[ \t]+BETWEEN)/ {
      if (match($0, /BETWEEN[ \t]+[0-9]+[ \t]+AND[ \t]+[0-9]+/)) {
        m=substr($0,RSTART,RLENGTH); gsub(/BETWEEN|AND/,"",m)
        n=split(m,parts," ")
        lo=""; hi=""
        for (i=1;i<=n;i++) if (parts[i] ~ /^[0-9]+$/) { if (lo=="") lo=parts[i]; else hi=parts[i] }
        print lo " " hi " " NR; exit
      }
    }
  ' "$FILE" || true)"

  if [ -n "${PRE_RANGE_LO:-}" ] && [ -n "${PRE_RANGE_HI:-}" ]; then
    if [ "$HDR_COUNT" -lt "$PRE_RANGE_LO" ] || [ "$HDR_COUNT" -gt "$PRE_RANGE_HI" ]; then
      err "Class C — header expected count $HDR_COUNT outside PRE guard range [$PRE_RANGE_LO,$PRE_RANGE_HI]@L$PRE_LN"
      PROBLEMS=$((PROBLEMS+1))
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Class E — sentinel header-vs-body symmetry
#   For every id mentioned in a header per-id comment, expect at least one UPDATE
#   touching that id (and vice versa).
# ─────────────────────────────────────────────────────────────
ONLY_IN_HDR=$(comm -23 "$HDR_IDS_FILE" "$BODY_IDS_FILE" || true)
ONLY_IN_BODY=$(comm -13 "$HDR_IDS_FILE" "$BODY_IDS_FILE" || true)

if [ -n "$ONLY_IN_HDR" ]; then
  err "Class E — id(s) declared in header comments but no UPDATE body:"
  echo "$ONLY_IN_HDR" | sed 's/^/    id=/'
  PROBLEMS=$((PROBLEMS+1))
fi
if [ -n "$ONLY_IN_BODY" ]; then
  warn "Class E — id(s) in UPDATE body but not in header per-id comment block:"
  echo "$ONLY_IN_BODY" | sed 's/^/    id=/' | head -20
  # non-fatal: header may use aggregate language. Warn only.
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
N_UPD_PAIRS=$(wc -l < "$UPD_FILE" | tr -d ' ')
N_POST_PAIRS=$(wc -l < "$POST_FILE" | tr -d ' ')
N_CMT_PAIRS=$(wc -l < "$CMT_FILE" | tr -d ' ')
N_HDR_IDS=$(wc -l < "$HDR_IDS_FILE" | tr -d ' ')
N_BODY_IDS=$(wc -l < "$BODY_IDS_FILE" | tr -d ' ')

echo ""
echo "─── parse stats ───"
echo "  UPDATE  (id,col,val) extracted : $N_UPD_PAIRS"
echo "  POST    (id,col,val) extracted : $N_POST_PAIRS"
echo "  COMMENT (id,col,val) extracted : $N_CMT_PAIRS"
echo "  header ids : $N_HDR_IDS  body ids : $N_BODY_IDS"
echo "  header expected count (if found) : ${HDR_COUNT:-<none>}"
echo "  PRE guard range : ${PRE_RANGE_LO:-<none>}..${PRE_RANGE_HI:-<none>}"

echo ""
echo "═══════════════════════════════════════════════════════"
if [ "$PROBLEMS" -gt 0 ]; then
  err "L0 BLOCKED — $PROBLEMS class(es) of mismatch in $BASENAME"
  exit 1
fi
ok "L0 CLEAN — $BASENAME passes self-consistency lint"
exit 0

#!/usr/bin/env bash
# scripts/check_canonical_update_guards.sh
#
# Enforces ADR-015 Access-first invariant (BUG-154 Stream D).
#
# Every UPDATE that SETs `canonical_sku_id` or `canonical_customer_id`
# must carry a `WHERE canonical_<col>_id IS NULL` guard in the same
# statement. Without the guard, a later fuzzy-match / re-resolver run
# can silently overwrite an Access-sourced canonical link.
#
#
# Usage
# -----
#   scripts/check_canonical_update_guards.sh
#       Default mode: scan only files staged for commit
#       (`git diff --cached --name-only --diff-filter=ACMR`). This is
#       the mode that runs as a pre-commit hook — it must NOT re-scan
#       merged code that the committer didn't touch (otherwise an old
#       pre-existing violation on `main` blocks every future commit).
#
#   scripts/check_canonical_update_guards.sh --all
#       Scan every .py under etl/ and .sql under schema/. This is the
#       audit / CI mode. Use it from CI, regression suites, or when
#       investigating "is the repo clean?" — never from a pre-commit
#       hook.
#
#   scripts/check_canonical_update_guards.sh path/one.py path/two.sql
#       Scan specific files (used by tests + ad-hoc invocation).
#
# Install as a pre-commit hook:
#   ln -sf ../../scripts/check_canonical_update_guards.sh \
#          .git/hooks/pre-commit
#
# Why staged-only by default (added 2026-04-27, B11/B7a/B9 hook scope fix)
# ----------------------------------------------------------------------
# schema/090_b6b_canonical_separation_and_region_overrides.sql carries
# 4 deliberate IS DISTINCT FROM repoints (JC-135 / JC-136 / JC-138)
# that violate the strict ADR-015 IS NULL rule by design — they exist
# explicitly to overwrite mis-merged canonical_sku_id values from the
# fuzzy matcher. Once that schema landed on `main`, the old "scan the
# whole repo" default tripped on every subsequent commit even when the
# committer only touched unrelated code. Pre-commit hooks must check
# what the committer is actually adding, not re-relitigate merged
# history. Audit / CI / cleanup work that DOES want a whole-repo scan
# can opt in with `--all`.
#
# The hook's regex is NOT widened to accept `IS DISTINCT FROM (target)`
# as a guard: that is idempotency, not Access-protection. A buggy
# fuzzy matcher whose target value differs from the current canonical
# would pass an `IS DISTINCT FROM` check and clobber the Access link —
# the exact threat ADR-015 protects against. The schema/090 sites
# remain real ADR-015 exceptions and need a separate annotation /
# schema-090-cleanup.md).
#
# Exit codes
#   0  all canonical_*_id UPDATE sites carry an IS NULL guard
#   1  one or more unguarded sites found (file:line report on stderr)
#   2  internal error (python3 missing, bad input)

set -euo pipefail

# Determine the repo root for the *invoking* context, not the script's
# install location. Git worktrees share a single `.git/hooks/`
# directory with the main checkout; if we cd'd to the script's own
# parent we'd run `git diff --cached` against the wrong index. The
# right toplevel is what `git rev-parse --show-toplevel` reports from
# the current working directory at invocation time.
#
# Fall back to the script's own parent directory only when not inside
# a git working tree (e.g. someone running the script ad-hoc against
# a tarball checkout).
if command -v git >/dev/null 2>&1 \
    && git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    # Resolve symlinks so we still find files when called from a
    # `.git/hooks/pre-commit` symlink outside any git working tree.
    script_path="${BASH_SOURCE[0]}"
    while [[ -L "$script_path" ]]; do
        link_target="$(readlink "$script_path")"
        if [[ "$link_target" = /* ]]; then
            script_path="$link_target"
        else
            script_path="$(cd "$(dirname "$script_path")" && pwd)/$link_target"
        fi
    done
    REPO_ROOT="$(cd "$(dirname "$script_path")/.." && pwd)"
fi
cd "$REPO_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
    echo "check_canonical_update_guards.sh: python3 not on PATH" >&2
    exit 2
fi

# Mode selection:
#   no args        -> staged-only (default; pre-commit hook mode)
#   --all          -> whole-repo scan (audit / CI mode)
#   --staged       -> explicit staged-only (same as no args; for clarity in scripts)
#   path args      -> explicit file list (test / ad-hoc mode)
mode="staged"
explicit_paths=()
if [[ $# -gt 0 ]]; then
    case "$1" in
        --all)
            mode="all"
            shift
            ;;
        --staged)
            mode="staged"
            shift
            ;;
    esac
    if [[ $# -gt 0 ]]; then
        mode="paths"
        explicit_paths=("$@")
    fi
fi

targets=()
case "$mode" in
    paths)
        for arg in "${explicit_paths[@]}"; do
            # Only care about .py under etl/ and .sql under schema/.
            # Silently drop anything else so this script can be called
            # with a wider file list (e.g. full `git diff --cached`).
            case "$arg" in
                etl/*.py|schema/*.sql) targets+=("$arg") ;;
            esac
        done
        ;;
    staged)
        # Pre-commit mode: only scan files the committer is actually
        # adding/modifying. --diff-filter=ACMR drops deletions (D) and
        # type-changes (T) we can't read. -z + null-delim handles paths
        # with spaces. If git isn't available or we're not in a repo,
        # fall back to no-op (vacuous pass) — the hook should never
        # block a commit for infra reasons.
        if ! command -v git >/dev/null 2>&1; then
            exit 0
        fi
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
            exit 0
        fi
        while IFS= read -r -d '' f; do
            case "$f" in
                etl/*.py|schema/*.sql) targets+=("$f") ;;
            esac
        done < <(git diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)
        ;;
    all)
        while IFS= read -r -d '' f; do targets+=("$f"); done < <(
            find etl -type f -name '*.py' -print0 2>/dev/null
        )
        while IFS= read -r -d '' f; do targets+=("$f"); done < <(
            find schema -type f -name '*.sql' -print0 2>/dev/null
        )
        ;;
esac

if [[ ${#targets[@]} -eq 0 ]]; then
    # No relevant files in scope — vacuously pass.
    exit 0
fi

python3 - "${targets[@]}" <<'PY'
import re
import sys

# A SET-line that assigns canonical_sku_id or canonical_customer_id.
# Matches both "SET canonical_X_id = ..." (single-field SET, first
# line after UPDATE) and ", canonical_X_id = ..." (continuation line
# in a multi-field SET). Case-insensitive so SQL and any upper-case
# Python strings both match.
SET_RE = re.compile(
    r'(?:SET|,)\s+canonical_(?P<col>sku|customer)_id\s*=',
    re.IGNORECASE,
)

# Max lines to scan forward when looking for the end of the
# enclosing UPDATE statement. Any real guarded statement fits well
# inside this bound; the cap prevents runaway scanning on malformed
# input.
MAX_STMT_LEN = 30

# A line that terminates the enclosing statement. Handles SQL `;`,
# Python triple-quote close, and Python `cur.execute(...)` closing
# paren on its own line (often ")," when more args follow). Built
# by concat so the pattern can literally contain the triple-quote
# markers without clashing with Python's own string literals.
STMT_END_RE = re.compile(
    ';'
    '|' + ('"' * 3)
    + '|' + ("'" * 3)
    + r'|^\s*\)\s*,?\s*$',
    re.MULTILINE,
)

# A line that starts a NEW top-level statement — the previous one
# implicitly ended. Indentation matters: we only treat these as
# boundaries at column 0 (SQL files) or very shallow indent (Python
# strings would normally keep their SQL keywords indented further).
NEXT_STMT_RE = re.compile(
    r'^\s{0,4}(UPDATE|INSERT|SELECT|DELETE|CREATE|WITH|COMMIT|'
    r'BEGIN|ALTER|DROP|MERGE)\b',
    re.IGNORECASE,
)


def guard_re(col):
    return re.compile(rf'canonical_{col}_id\s+IS\s+NULL', re.IGNORECASE)


def statement_forward(lines, start_idx):
    """Return the text of the statement from start_idx forward, bounded
    by either a terminator or the start of a new top-level statement,
    or MAX_STMT_LEN lines. The returned block is where the guard must
    appear for this site to count as guarded."""
    buf = [lines[start_idx]]
    for j in range(start_idx + 1, min(len(lines), start_idx + MAX_STMT_LEN)):
        buf.append(lines[j])
        if STMT_END_RE.search(lines[j]):
            break
        # A new top-level keyword on the next line means the previous
        # statement ended without a visible terminator (bare SQL in a
        # triple-quoted block, or Python concatenated strings).
        if j + 1 < len(lines) and NEXT_STMT_RE.search(lines[j + 1]):
            break
    return ''.join(buf)


violations = []
site_count = 0

for path in sys.argv[1:]:
    try:
        with open(path, encoding='utf-8') as fh:
            lines = fh.readlines()
    except (OSError, UnicodeDecodeError) as exc:
        print(f'check_canonical_update_guards: could not read {path}: {exc}',
              file=sys.stderr)
        continue

    for i, line in enumerate(lines):
        m = SET_RE.search(line)
        if not m:
            continue
        site_count += 1
        col = m.group('col').lower()
        stmt = statement_forward(lines, i)
        if not guard_re(col).search(stmt):
            violations.append((path, i + 1, line.rstrip()))

if violations:
    print(
        f'ADR-015 violation: {len(violations)} unguarded canonical_*_id '
        f'UPDATE site(s) found (of {site_count} total):',
        file=sys.stderr,
    )
    for path, lineno, txt in violations:
        print(f'  {path}:{lineno}: {txt}', file=sys.stderr)
    print(
        '\nEvery UPDATE that SETs canonical_sku_id or '
        'canonical_customer_id must carry a `WHERE canonical_<col>_id '
        'IS NULL` guard inside the same statement.',
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f'ADR-015 check: {site_count} canonical_*_id UPDATE site(s) '
    f'scanned across {len(sys.argv) - 1} file(s), all guarded.'
)
PY

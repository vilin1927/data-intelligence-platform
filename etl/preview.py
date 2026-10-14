"""
Data Import Wizard — Preview & Confirm modes.

Wraps the existing channel importers (Direct, DWS, ALM) to provide:
  1. preview_file(): Parse + match without inserting. Returns JSON.
  2. confirm_import(): Import with optional manual SKU/customer overrides.

Usage:
    # Preview (dry run):
    DATABASE_URL=... python -m etl.preview --channel direct --file path.csv

    # Confirm (import with overrides):
    DATABASE_URL=... python -m etl.preview --channel direct --file path.csv \
        --confirm --overrides '{"sku":{"BADCODE":42},"customer":{"Unknown":17}}'
"""

import csv
import datetime
import json
import logging
import os
import sys
import time
import zipfile
import io
from decimal import Decimal, InvalidOperation

import psycopg2
import psycopg2.extras

from etl.logger import log_etl_run, log_dead_letter

# BUG-24: batch size for execute_values — 500 rows per round-trip.
BATCH_SIZE = 500

logger = logging.getLogger("moppity.etl.preview")

# ---------------------------------------------------------------------------
# Shared parsing helpers (same as existing importers)
# ---------------------------------------------------------------------------

def _parse_date(value: str) -> datetime.date | None:
    if not value or not value.strip():
        return None
    text = value.strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y",
                 "%d %b %Y", "%d %B %Y", "%Y-%m-%dT%H:%M:%S",
                 "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def _parse_decimal(value: str) -> Decimal | None:
    if not value or not value.strip():
        return None
    text = value.strip().replace(",", "").replace("$", "")
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def _parse_percentage(value: str) -> Decimal | None:
    if not value or not value.strip():
        return None
    text = value.strip()
    if text.endswith("%"):
        text = text[:-1].strip()
        try:
            return Decimal(text) / Decimal("100")
        except InvalidOperation:
            return None
    return None


def _normalise_header(value: str) -> str:
    if not value:
        return ""
    return value.strip().lower()


def _upsert_batch(
    cur,
    *,
    batch_label: str,
    batch_sql: str,
    single_sql: str,
    rows: list[tuple],
) -> None:
    """Run a batched upsert via execute_values with per-row SAVEPOINT fallback.

    BUG-24: used by confirm_import to collapse override-mapping upserts into
    a single round-trip. Falls back to per-row inserts if the batch statement
    fails (e.g. unexpected schema/constraint issue), preserving as much work
    as possible on partial failure.

    Args:
        cur: psycopg2 cursor (must be inside an open transaction).
        batch_label: human-readable label used in log lines.
        batch_sql: the `INSERT ... VALUES %s ...` form for execute_values.
        single_sql: the per-row `INSERT ... VALUES (%s, ...)` form used by
            the fallback path.
        rows: list of value tuples.
    """
    if not rows:
        return

    total = len(rows)
    for batch_start in range(0, total, BATCH_SIZE):
        batch = rows[batch_start:batch_start + BATCH_SIZE]
        batch_no = (batch_start // BATCH_SIZE) + 1
        t0 = time.monotonic()
        try:
            cur.execute("SAVEPOINT batch_sp")
            psycopg2.extras.execute_values(
                cur, batch_sql, batch, page_size=BATCH_SIZE,
            )
            cur.execute("RELEASE SAVEPOINT batch_sp")
            elapsed = time.monotonic() - t0
            logger.info(
                "%s batch %d: %d rows in %.3fs",
                batch_label, batch_no, len(batch), elapsed,
            )
        except psycopg2.Error as batch_exc:
            cur.execute("ROLLBACK TO SAVEPOINT batch_sp")
            logger.warning(
                "%s batch %d failed (%s) — falling back to per-row inserts "
                "for %d rows",
                batch_label, batch_no, batch_exc, len(batch),
            )
            landed = 0
            for tup in batch:
                try:
                    cur.execute("SAVEPOINT fallback_sp")
                    cur.execute(single_sql, tup)
                    cur.execute("RELEASE SAVEPOINT fallback_sp")
                    landed += 1
                except psycopg2.Error as row_exc:
                    cur.execute("ROLLBACK TO SAVEPOINT fallback_sp")
                    logger.error(
                        "%s batch %d fallback row failed: %s (row=%r)",
                        batch_label, batch_no, row_exc, tup,
                    )
            logger.info(
                "%s batch %d fallback: %d/%d rows landed",
                batch_label, batch_no, landed, len(batch),
            )


# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

class Lookups:
    """Shared lookup logic for SKU, customer, channel, duplicates."""

    def __init__(self, cursor, source_system: str):
        self.cur = cursor
        self.source = source_system.lower()
        self.source_upper = source_system.upper()
        self._sku_list = None
        self._customer_list = None

        # Batch-load all lookups into memory (eliminates per-row DB queries)
        # SKU code map: lowered external_code → (sku_id, description)
        cursor.execute(
            "SELECT LOWER(m.external_code), m.sku_id, s.item_description "
            "FROM sku_code_map m JOIN sku s ON s.sku_id = m.sku_id "
            "WHERE m.source_system = %s", (self.source,))
        self._sku_code_map = {r[0]: (r[1], r[2]) for r in cursor.fetchall()}

        # SKU canonical: lowered sku_code → (sku_id, description)
        cursor.execute("SELECT LOWER(sku_code), sku_id, item_description FROM sku")
        self._sku_canonical = {r[0]: (r[1], r[2]) for r in cursor.fetchall()}

        # SKU table for fuzzy matching
        cursor.execute("SELECT sku_id, item_description FROM sku")
        self._sku_all = cursor.fetchall()

        # Full SKU list for suggest_skus() — includes sku_code + canonical_name
        cursor.execute(
            "SELECT s.sku_id, s.sku_code, s.item_description, cs.sku_name "
            "FROM sku s LEFT JOIN canonical_sku cs "
            "  ON cs.id = s.canonical_sku_id AND cs.is_active_canonical = true "
            "WHERE s.item_description IS NOT NULL "
            "ORDER BY s.sku_code"
        )
        self._sku_suggest_list = cursor.fetchall()

        # Customer code map: external_name → (customer_id, customer_name) for this source
        cursor.execute(
            "SELECT LOWER(m.external_name), m.customer_id, c.customer_name "
            "FROM customer_code_map m JOIN customer c ON c.customer_id = m.customer_id "
            "WHERE m.source_system = %s", (self.source,))
        self._customer_code_map = {r[0]: (r[1], r[2]) for r in cursor.fetchall()}

        # Customer canonical: lowered name → (customer_id, customer_name)
        cursor.execute("SELECT LOWER(customer_name), customer_id, customer_name FROM customer")
        self._customer_canonical = {r[0]: (r[1], r[2]) for r in cursor.fetchall()}

        # Canonical customer list for fuzzy suggestions (F17)
        # B8 (May 8 / 25-day loop): include suburb, postcode, channel so the
        # suggestion payload can show richer context — Apr 13 the owner asked for
        # rep / territory / channel pre-pop on customer create, same context
        # is useful when picking suggestions inline.
        cursor.execute(
            "SELECT DISTINCT ON (cc.id) "
            "       c.customer_id, cc.customer_name, cc.customer_name as display, "
            "       cc.suburb, cc.postcode, cc.channel "
            "FROM customer c JOIN canonical_customer cc ON cc.id = c.canonical_customer_id "
            "WHERE c.canonical_customer_id IS NOT NULL "
            "ORDER BY cc.id, c.customer_id")
        self._customer_list_raw = cursor.fetchall()

        # B8: postcode → state map sourced from au_postcode (schema/032).
        # Used by suggest_customers() to derive state for suggestion payload.
        # Prefer "Delivery Area" rows when a postcode has multiple matches —
        # PO Box / LVR rows are mailbox-only and may map to a different state
        # than the actual delivery area in rare cases.
        # Wrapped in SAVEPOINT so a missing table on a fresh dev DB doesn't
        # poison the surrounding transaction.
        self._postcode_to_state: dict[str, str] = {}
        try:
            cursor.execute("SAVEPOINT au_postcode_load")
            cursor.execute(
                "SELECT postcode, state FROM au_postcode "
                "ORDER BY postcode, "
                "         CASE WHEN type = 'Delivery Area' THEN 0 ELSE 1 END"
            )
            for row in cursor.fetchall():
                pc, st = row[0], row[1]
                if pc and st and pc not in self._postcode_to_state:
                    self._postcode_to_state[pc] = st
            cursor.execute("RELEASE SAVEPOINT au_postcode_load")
        except psycopg2.Error:
            # au_postcode missing on a fresh dev DB — degrade gracefully.
            cursor.execute("ROLLBACK TO SAVEPOINT au_postcode_load")
            self._postcode_to_state = {}

        # Existing source_refs for this channel (duplicate detection)
        cursor.execute(
            "SELECT source_ref FROM sales_transaction WHERE source_system = %s",
            (self.source_upper,))
        self._existing_refs = {r[0] for r in cursor.fetchall()}

        # JR-083: representative names (case-insensitive) for unmatched-rep detection.
        # Used by preview_file() to aggregate meta_rep values absent from the
        # representative table so the UI UnmatchedRepsPanel can surface them.
        cursor.execute("SELECT LOWER(rep_name) FROM representative WHERE rep_name IS NOT NULL")
        self._rep_names = {r[0] for r in cursor.fetchall() if r[0]}

    def lookup_sku(self, external_code: str, description: str | None = None) -> tuple[int | None, str | None]:
        """Returns (sku_id, canonical_name) or (None, None).

        BUG-36: accepts optional description so DWS/ALM rows whose external_code
        is a brand-new vintage (e.g. MOATRI26F, first-seen 2026 vintage) can be
        auto-matched against the existing canonical SKU family by description
        (e.g. "MOPPITY ATRIUS RIESLING 2026" -> sku_id=50 MOPPITY ATRIUS RIESLING).
        """
        key = external_code.lower()
        # 1. sku_code_map
        if key in self._sku_code_map:
            return self._sku_code_map[key]
        # 2. Canonical sku table
        if key in self._sku_canonical:
            return self._sku_canonical[key]
        # 3. Fuzzy match on description (DWS/ALM only) — use description if
        # available (it carries the product name), else fall back to the code.
        if self.source in ("dws", "alm"):
            candidate_text = description if description else external_code
            return self._fuzzy_sku_match(candidate_text)
        return None, None

    def _fuzzy_sku_match(self, description: str) -> tuple[int | None, str | None]:
        """Extract keywords from description and substring-match against sku table.

        BUG-36 fix: previously built `"%".join(words)` and tested with Python `in`
        — but `in` treats `%` as a literal character, so
        `"MOPPITY%ATRIUS%RIESLING" in "MOPPITY ATRIUS RIESLING"` is False. The
        helper was effectively dead. Rewritten to require ALL of the top
        descriptive tokens to appear (case-insensitive, word-boundary friendly)
        in the candidate SKU description. Order-independent and space-tolerant.
        """
        if not description:
            return None, None
        stop_words = {
            "the", "and", "750ml", "375ml", "1500ml", "ml", "case", "of", "x",
            "btl", "btls", "bottle", "bottles", "carton", "cartons",
        }
        # Upper-case, split, drop stopwords + short tokens.
        # Strip trailing 2- or 4-digit vintage from matching tokens so a new
        # vintage (e.g. "...RIESLING 2026") still matches an existing vintage
        # sku description (e.g. "...RIESLING 2025" or "...RIESLING" canonical).
        raw_tokens = description.upper().split()
        words: list[str] = []
        for tok in raw_tokens:
            clean = tok.strip(".,()[]{}/\\")
            if not clean or len(clean) <= 2:
                continue
            if clean.lower() in stop_words:
                continue
            # Skip pure-numeric tokens (vintages / SKU numeric suffixes).
            if clean.isdigit():
                continue
            words.append(clean)
        if len(words) < 2:
            return None, None
        # Use the first 3 tokens as required keywords.
        required = words[:3]
        best_match: tuple[int | None, str | None] = (None, None)
        best_len: int | None = None  # shortest matching desc wins (tightest fit)
        for sku_id, desc in self._sku_all:
            if not desc:
                continue
            desc_upper = desc.upper()
            # All required tokens must appear as substrings.
            if not all(tok in desc_upper for tok in required):
                continue
            # Prefer the shortest matching description (tightest fit). A very
            # short canonical like "MOPPITY ATRIUS RIESLING" beats a longer
            # vintage-specific variant; both are legitimate but the canonical
            # is the anchor the owner wants new vintages attached to.
            cand_len = len(desc_upper)
            if best_len is None or cand_len < best_len:
                best_len = cand_len
                best_match = (sku_id, desc)
        return best_match

    def lookup_customer(self, external_name: str, external_code: str | None = None) -> tuple[int | None, str | None, str]:
        """Returns (customer_id, canonical_name, match_method) or (None, None, '').

        Match priority (per the owner's Access logic):
          1. By customer code (foolproof) — stored in customer_code_map as code:<code>
          2. By external name in customer_code_map (existing saved mappings)
          3. By canonical customer name (exact match)
        """
        # 1. Match by customer code FIRST — foolproof per the owner
        if external_code:
            code_clean = external_code.strip().lstrip('0')
            if code_clean:
                key = f"code:{code_clean}"
                if key in self._customer_code_map:
                    return (*self._customer_code_map[key], "code")
        # 2. customer_code_map by name
        name_key = external_name.lower()
        if name_key in self._customer_code_map:
            return (*self._customer_code_map[name_key], "saved")
        # 3. Canonical customer table
        if name_key in self._customer_canonical:
            return (*self._customer_canonical[name_key], "name")
        return None, None, ""

    def is_duplicate(self, source_ref: str) -> bool:
        if not source_ref:
            return False
        return source_ref in self._existing_refs

    def suggest_customers(
        self,
        external_name: str,
        meta_territory: str = "",
        meta_suburb: str = "",
        meta_postcode: str = "",
        top_n: int = 5,
    ) -> list[dict]:
        """Fuzzy-match external_name against canonical customers. Returns top N matches with scores.

        B8 (May 8 / 25-day loop): "CUSTOMER 106" failed to suggest
        "CUSTOMER 02 @ COLEDALE" because (a) "cellars" was stripped from
        the canonical name during normalize, collapsing it to a single
        "coledale" token that lost on trigram to two-token "fine wines" rivals,
        and (b) there was no suburb signal to break the tie. Fix:
          1. Keep "cellars" — it's a brand-meaningful token like "fine wines".
          2. Boost ratio when source row's suburb matches canonical suburb.
        Suggestion payload now includes suburb / postcode / state / channel so
        the picker UI shows enough context for the owner to disambiguate.
        """
        import re
        from difflib import SequenceMatcher
        if not external_name or not self._customer_list_raw:
            return []

        def normalize(s: str) -> str:
            """Strip punctuation, articles, common suffixes for better matching.

            B8: "cellars" removed from the strip list — it carries brand
            meaning ("Customer 02" vs "Customer 106"). The other
            terms (the/pty/ltd/hotel/bar/bottleshop/liquor) remain because
            they are generic business-type noise, not brand identifiers.
            """
            s = s.lower().strip()
            s = re.sub(r"[,.'&\-]", " ", s)
            s = re.sub(r"\b(the|pty|ltd|hotel|bar|bottleshop|liquor)\b", "", s)
            s = re.sub(r"\s@\s.*$", "", s)  # Strip "@ SUBURB" suffix from canonical names
            return re.sub(r"\s+", " ", s).strip()

        ext_norm = normalize(external_name)
        ext_words = set(ext_norm.split())
        src_suburb = (meta_suburb or "").strip().lower()
        # C1 (matrix row C1 — DWS suburb gap): DWS reports have NO postcode and
        # NO suburb column (dws_staging_114 geographic info = sareaname / state
        # only: ACT/NSW/QLD/VIC/WA). So src_suburb is always empty on the DWS
        # path and the +0.20 row-level suburb boost (below) never fires for DWS,
        # leaving DWS fuzzy matching as pure name-trigram. For the canonical
        # cluster "CELLARBRATIONS @ X" (60+ rows, same name prefix, different
        # suburb suffix) every member ties at ratio ~0.757 against the DWS row
        # "CELLARBRATIONS CARNEGIE" — the correct target "CUSTOMER 04 @
        # CARNEGIE" sits at 0.410 (only "carnegie" overlaps) and never enters
        # the top-5 suggestion list. Fix: on the DWS path, fall back to a
        # "canonical-suburb-as-word-in-source-name" implicit-suburb boost. If
        # the canonical row's suburb appears as a discrete word in the DWS
        # source name (case-insensitive, word-boundary anchored), treat it as
        # a suburb match and apply a +0.40 boost. The word-boundary anchor
        # prevents false positives ("Customer 103" won't match suburb
        # SYDNEY). The boost is larger than the +0.20 ALM exact-suburb boost
        # because the DWS name-only base ratio is intrinsically lower (the
        # "@ SUBURB" suffix is stripped by normalize() so only the brand
        # prefix contributes — see CUSTOMER 04 → "customer 04" at
        # 0.410). +0.40 is the minimum needed to lift the suburb-aligned
        # canonical above the same-brand cluster noise floor (~0.757) on the
        # Cellarbrations Carnegie HARD test case.
        is_dws_no_suburb = (self.source == "dws") and not src_suburb
        scored = []
        for row in self._customer_list_raw:
            cid, cname, display = row[0], row[1], row[2]
            cc_suburb = (row[3] if len(row) > 3 else None) or ""
            cc_postcode = (row[4] if len(row) > 4 else None) or ""
            cc_channel = (row[5] if len(row) > 5 else None) or ""
            name_norm = normalize(cname or "")
            # Quick filter: skip if no words overlap
            name_words = set(name_norm.split())
            if not ext_words & name_words:
                continue
            ratio = SequenceMatcher(None, ext_norm, name_norm).ratio()
            # Boost if territory matches
            if meta_territory and display and meta_territory.lower() in display.lower():
                ratio = min(ratio + 0.05, 1.0)
            # B8: suburb-trigram boost. When the upload row's suburb matches
            # the canonical suburb (case-insensitive trim), this is a strong
            # signal — the owner's "CUSTOMER 106 @ COLEDALE" should beat
            # any "Fine Wines" rival in another suburb. +0.20 is large enough
            # to flip ties but not so large it overrides a clear name match.
            if src_suburb and cc_suburb and src_suburb == cc_suburb.strip().lower():
                ratio = min(ratio + 0.20, 1.0)
            # C1: DWS implicit-suburb boost — canonical suburb appears as a
            # discrete word in the DWS source name. See block comment above.
            elif is_dws_no_suburb and cc_suburb:
                cc_sub_lower = cc_suburb.strip().lower()
                if cc_sub_lower and re.search(
                    r"\b" + re.escape(cc_sub_lower) + r"\b",
                    external_name.lower(),
                ):
                    ratio = min(ratio + 0.40, 1.0)
            if ratio >= 0.40:
                state = self._postcode_to_state.get(cc_postcode, "") if cc_postcode else ""
                scored.append({
                    "customer_id": cid,
                    "display_name": display or cname,
                    "score": round(ratio * 100),
                    "suburb": cc_suburb,
                    "postcode": cc_postcode,
                    "state": state,
                    "channel": cc_channel,
                })
        scored.sort(key=lambda x: -x["score"])
        return scored[:top_n]

    def suggest_skus(self, external_code: str, description: str = "", top_n: int = 5) -> list[dict]:
        """Fuzzy-match external SKU code/description against canonical SKUs.

        Returns top N matches with scores.  Matches on both sku_code and
        item_description, keeping whichever gives the higher similarity.
        Shape matches frontend SkuSuggestion interface:
            {sku_id, sku_code, description, canonical_name, score}
        """
        import re
        from difflib import SequenceMatcher
        if not external_code and not description:
            return []
        if not self._sku_suggest_list:
            return []

        def normalize(s: str) -> str:
            """Strip punctuation and common wine packaging terms."""
            s = s.lower().strip()
            s = re.sub(r"[,.'&\-/]", " ", s)
            s = re.sub(r"\b(750ml|375ml|1500ml|ml|case|of|x|the|and)\b", "", s)
            return re.sub(r"\s+", " ", s).strip()

        ext_code_norm = normalize(external_code) if external_code else ""
        ext_desc_norm = normalize(description) if description else ""
        scored: list[dict] = []
        for sku_id, sku_code, item_desc, canonical_name in self._sku_suggest_list:
            code_norm = normalize(sku_code or "")
            desc_norm = normalize(item_desc or "")
            # Score against code and description, take best
            best_ratio = 0.0
            if ext_code_norm and code_norm:
                best_ratio = max(best_ratio, SequenceMatcher(None, ext_code_norm, code_norm).ratio())
            if ext_code_norm and desc_norm:
                best_ratio = max(best_ratio, SequenceMatcher(None, ext_code_norm, desc_norm).ratio())
            if ext_desc_norm and code_norm:
                best_ratio = max(best_ratio, SequenceMatcher(None, ext_desc_norm, code_norm).ratio())
            if ext_desc_norm and desc_norm:
                best_ratio = max(best_ratio, SequenceMatcher(None, ext_desc_norm, desc_norm).ratio())
            if best_ratio >= 0.40:
                scored.append({
                    "sku_id": sku_id,
                    "sku_code": sku_code,
                    "description": item_desc,
                    "canonical_name": canonical_name,
                    "score": round(best_ratio * 100),
                })
        scored.sort(key=lambda x: -x["score"])
        return scored[:top_n]

    def get_channel_id(self, channel_name: str) -> int:
        self.cur.execute(
            "SELECT channel_id FROM channel WHERE channel_name = %s",
            (channel_name,),
        )
        row = self.cur.fetchone()
        if not row:
            raise RuntimeError(f"Channel '{channel_name}' not found in channel table.")
        return row[0]

    def get_sku_list(self) -> list[dict]:
        """All canonical SKUs for dropdown suggestions."""
        if self._sku_list is None:
            self.cur.execute(
                "SELECT s.sku_id, s.sku_code, s.item_description, cs.sku_name "
                "FROM sku s LEFT JOIN canonical_sku cs "
                "  ON cs.id = s.canonical_sku_id AND cs.is_active_canonical = true "
                "WHERE s.item_description IS NOT NULL "
                "ORDER BY s.sku_code"
            )
            self._sku_list = [
                {"sku_id": r[0], "sku_code": r[1],
                 "description": r[2], "canonical_name": r[3]}
                for r in self.cur.fetchall()
            ]
        return self._sku_list

    def get_customer_list(self) -> list[dict]:
        """All canonical customers for dropdown suggestions.

        Uses canonical_customer table as the source of truth (F6+F16).
        canonical_customer.customer_name already has "NAME @ SUBURB" format.
        Each canonical shows ONCE — the owner picks the canonical, matching
        behaviour of his Access master customer list.

        Raw customers with NULL canonical_customer_id are included as
        fallback (may be new customers not yet canonicalized).
        """
        if self._customer_list is None:
            # 1. All canonical customers (the master list — 4,030 entries)
            self.cur.execute(
                "SELECT DISTINCT ON (c.canonical_customer_id) "
                "       c.customer_id, cc.customer_name, c.suburb, "
                "       cc.territory_name, cc.rep_name, c.canonical_customer_id "
                "FROM customer c "
                "JOIN canonical_customer cc ON cc.id = c.canonical_customer_id "
                "WHERE c.canonical_customer_id IS NOT NULL "
                "ORDER BY c.canonical_customer_id, c.customer_id"
            )
            canonical_rows = self.cur.fetchall()
            result = []
            for r in canonical_rows:
                cid, cname, suburb, territory, rep, canonical_id = r
                result.append({
                    "customer_id": cid,
                    "customer_name": cname,
                    "display_name": cname,  # Already "NAME @ SUBURB" format
                    "suburb": suburb or "",
                    "territory": territory or "",
                    "rep": rep or "",
                    "canonical_customer_id": canonical_id,
                })

            # Orphan raw customers (NULL canonical_customer_id) are EXCLUDED
            # from the dropdown to match the owner's Access experience (one entry
            # per physical customer). Orphans are typically variants of existing
            # canonicals ("Customer 09 Albury" = "CUSTOMER 09 @ ALBURY").
            # If the owner needs a customer that doesn't appear, he creates it via
            # "+ New" — the canonical rollup is Phase 2 work.
            result.sort(key=lambda x: x["display_name"].lower())
            self._customer_list = result
        return self._customer_list


# ---------------------------------------------------------------------------
# Direct CSV parser
# ---------------------------------------------------------------------------

DIRECT_COLUMNS = {
    "sku": "sku_code", "sku code": "sku_code", "item code": "sku_code",
    "product code": "sku_code", "stockitemcode": "sku_code",
    "stock item code": "sku_code", "itemcode": "sku_code",
    "customer": "customer_name", "customer name": "customer_name",
    "contact": "customer_name", "contact name": "customer_name",
    "contactname": "customer_name", "account": "customer_name",
    "customer code": "customer_code", "customer id": "customer_code",
    "contact code": "customer_code", "account code": "customer_code",
    "date": "sale_date", "sale date": "sale_date", "invoice date": "sale_date",
    "invoicedate": "sale_date", "order date": "sale_date", "orderdate": "sale_date",
    "quantity": "quantity", "qty": "quantity", "cases": "quantity",
    "unit price": "unit_price", "unitprice": "unit_price", "price": "unit_price",
    "discount": "discount_pct", "discount amount": "discount_amount",
    "discountamount": "discount_amount",
    "net price": "net_price", "revenue": "revenue",
    "rebate": "rebate_amount", "rebate amount": "rebate_amount",
    "invoice": "source_ref", "invoice number": "source_ref",
    "invoice no": "source_ref", "invoicenumber": "source_ref",
    "reference": "source_ref", "ref": "source_ref",
    "order number": "source_ref", "order num": "source_ref",
    "ordernumber": "source_ref", "salesordernumber": "source_ref",
    "sales order number": "source_ref",
    # SKU description (for fuzzy matching suggestions — BUG-30)
    "description": "sku_description", "item description": "sku_description",
    "product": "sku_description", "product name": "sku_description",
    "item name": "sku_description", "stockitemname": "sku_description",
    "stock item name": "sku_description",
}


def _find_header_row(all_rows, expected_columns):
    for idx, row in enumerate(all_rows[:10]):
        non_empty = [c for c in row if c and c.strip()]
        if len(non_empty) < 3:
            continue
        normalised = [_normalise_header(c) for c in row]
        matches = sum(1 for n in normalised if n in expected_columns)
        if matches >= 3:
            return idx, row
    return 0, all_rows[0]


def _map_columns(header_row, expected_columns):
    mapping = {}
    for idx, cell_value in enumerate(header_row):
        normalised = _normalise_header(cell_value)
        if normalised in expected_columns:
            field = expected_columns[normalised]
            if field not in mapping:
                mapping[field] = idx
    return mapping


def parse_direct_csv(file_path: str, lookups: Lookups) -> list[dict]:
    """Parse a Direct CSV and return preview rows."""
    with open(file_path, "r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(8192)
        f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",\t;|")
        except csv.Error:
            dialect = csv.excel
        reader = csv.reader(f, dialect)
        all_rows = list(reader)

    if not all_rows:
        raise ValueError("Direct CSV is empty — no rows found.")

    header_idx, header_row = _find_header_row(all_rows, DIRECT_COLUMNS)
    col_map = _map_columns(header_row, DIRECT_COLUMNS)

    if "sku_code" not in col_map:
        raise ValueError(f"Cannot find SKU column. Headers: {header_row}")
    if "sale_date" not in col_map:
        raise ValueError(f"Cannot find date column. Headers: {header_row}")

    data_rows = all_rows[header_idx + 1:]
    data_rows = [r for r in data_rows if any(cell.strip() for cell in r)]

    preview_rows = []
    for row_num, row in enumerate(data_rows, start=1):
        def _get(field):
            idx = col_map.get(field)
            if idx is None or idx >= len(row):
                return ""
            return row[idx]

        raw_sku = _get("sku_code").strip()
        raw_description = _get("sku_description").strip()  # BUG-30: capture for fuzzy suggestions
        raw_customer = _get("customer_name").strip()
        raw_customer_code = _get("customer_code").strip()
        raw_date = _get("sale_date")
        raw_qty = _get("quantity")
        raw_price = _get("unit_price")
        raw_discount_pct = _get("discount_pct")
        raw_discount_amt = _get("discount_amount")
        raw_rebate = _get("rebate_amount")
        raw_ref = _get("source_ref")
        raw_revenue = _get("revenue")

        # Parse fields
        sale_date = _parse_date(raw_date)
        quantity = _parse_decimal(raw_qty)
        unit_price = _parse_decimal(raw_price)
        rebate_amount = _parse_decimal(raw_rebate) or Decimal("0")

        # Discount
        discount_amount = Decimal("0")
        discount_pct = _parse_percentage(raw_discount_pct)
        if discount_pct is not None and unit_price is not None and quantity is not None:
            discount_amount = (quantity * unit_price * discount_pct).quantize(Decimal("0.01"))
        elif raw_discount_amt:
            discount_amount = _parse_decimal(raw_discount_amt) or Decimal("0")

        # Revenue
        gross_revenue = (quantity * unit_price).quantize(Decimal("0.01")) if quantity and unit_price else None
        revenue = _parse_decimal(raw_revenue)
        if revenue is not None:
            net_revenue = revenue
        elif gross_revenue is not None:
            net_revenue = gross_revenue - discount_amount - rebate_amount
        else:
            net_revenue = None

        # Source ref
        source_ref = raw_ref.strip() if raw_ref else None
        if source_ref:
            source_ref = f"{source_ref}-{raw_sku}"
        else:
            source_ref = f"DIRECT-{sale_date.isoformat() if sale_date else 'nodate'}-{raw_sku}-{row_num}"

        # Validation errors
        errors = []
        if not raw_sku:
            errors.append("Missing SKU code")
        if sale_date is None:
            errors.append(f"Invalid date: {raw_date!r}")
        if quantity is None:
            errors.append(f"Invalid quantity: {raw_qty!r}")

        # SKU lookup
        sku_id, sku_name = (None, None)
        if raw_sku:
            sku_id, sku_name = lookups.lookup_sku(raw_sku, raw_description)

        # Customer lookup
        customer_id, customer_name_canonical, customer_match_method = (None, None, "")
        if raw_customer or raw_customer_code:
            customer_id, customer_name_canonical, customer_match_method = lookups.lookup_customer(raw_customer, raw_customer_code)

        # Duplicate check
        is_duplicate = lookups.is_duplicate(source_ref)

        # Determine status
        if errors:
            status = "error"
        elif is_duplicate:
            status = "duplicate"
        elif sku_id is None or (raw_customer and customer_id is None):
            status = "unmatched"
        else:
            status = "matched"

        preview_rows.append({
            "row_num": row_num,
            "raw_sku": raw_sku,
            "raw_description": raw_description,  # BUG-30: for fuzzy suggestions
            "raw_customer": raw_customer,
            "sale_date": sale_date.isoformat() if sale_date else None,
            "quantity": float(quantity) if quantity else None,
            "unit_price": float(unit_price) if unit_price else None,
            "discount": float(discount_amount),
            "rebate": float(rebate_amount),
            "net_revenue": float(net_revenue) if net_revenue else None,
            "source_ref": source_ref,
            "sku_id": sku_id,
            "sku_name": sku_name,
            "customer_id": customer_id,
            "customer_name": customer_name_canonical,
            "match_method": customer_match_method,
            "is_duplicate": is_duplicate,
            "status": status,
            "errors": errors,
        })

    return preview_rows


# ---------------------------------------------------------------------------
# DWS Excel parser
# ---------------------------------------------------------------------------

DWS_COLUMNS = {
    "sku": "sku_code", "sku code": "sku_code", "item code": "sku_code",
    "product code": "sku_code", "stockitem": "sku_code", "stkalias": "sku_code",
    "customer": "customer_name", "customer name": "customer_name",
    "account": "customer_name", "account name": "customer_name",
    "drname": "customer_name",
    "debtor": "customer_code", "customer code": "customer_code",
    "customer id": "customer_code", "account id": "customer_code",
    "dralias": "customer_code",
    "date": "sale_date", "sale date": "sale_date", "invoice date": "sale_date",
    "cartons": "quantity", "cases": "quantity", "qty": "quantity",
    "quantity": "quantity_bottles",
    "unit price": "unit_price", "price": "unit_price",
    "grossval": "gross_value", "discval": "discount_amount",
    "discount": "discount_amount", "discount amount": "discount_amount",
    "rebate": "rebate_amount", "rebate amount": "rebate_amount",
    "wholesale fee": "wholesale_fee", "fee": "wholesale_fee",
    "refno": "source_ref", "reference": "source_ref", "ref": "source_ref",
    "invoice": "source_ref", "invoice no": "source_ref",
    # Metadata for F5 (pre-populate new customer form)
    "sareaname": "area_name", "srepname": "rep_name",
    "drgrpname": "group_name", "drcatname": "category_name",
    # SKU description (for fuzzy matching suggestions)
    "stkdesc1": "sku_description", "description": "sku_description",
    "item description": "sku_description", "product": "sku_description",
}


def parse_dws_excel(file_path: str, lookups: Lookups) -> list[dict]:
    """Parse a DWS Excel report and return preview rows."""
    import openpyxl
    wb = openpyxl.load_workbook(file_path, data_only=True, read_only=True)
    ws = wb.active

    # Read all rows as strings
    all_rows = []
    for row in ws.iter_rows(values_only=True):
        all_rows.append([str(cell) if cell is not None else "" for cell in row])
    wb.close()

    if not all_rows:
        raise ValueError("DWS Excel is empty — no rows found.")

    header_idx, header_row = _find_header_row(all_rows, DWS_COLUMNS)
    col_map = _map_columns(header_row, DWS_COLUMNS)

    if "sku_code" not in col_map:
        raise ValueError(f"Cannot find SKU column. Headers: {header_row}")

    data_rows = all_rows[header_idx + 1:]
    data_rows = [r for r in data_rows if any(cell.strip() for cell in r)]

    preview_rows = []
    for row_num, row in enumerate(data_rows, start=1):
        def _get(field):
            idx = col_map.get(field)
            if idx is None or idx >= len(row):
                return ""
            return row[idx]

        raw_sku = _get("sku_code").strip()
        raw_description = _get("sku_description").strip()
        raw_customer = _get("customer_name").strip()
        raw_customer_code = _get("customer_code").strip()
        raw_date = _get("sale_date")
        raw_qty = _get("quantity")
        raw_gross = _get("gross_value")
        raw_discount = _get("discount_amount")
        raw_rebate = _get("rebate_amount")
        raw_fee = _get("wholesale_fee")
        raw_ref = _get("source_ref")
        raw_price = _get("unit_price")
        raw_area = _get("area_name").strip()
        raw_rep = _get("rep_name").strip()
        raw_group = _get("group_name").strip()
        raw_category = _get("category_name").strip()

        sale_date = _parse_date(raw_date)
        quantity = _parse_decimal(raw_qty)
        gross_value = _parse_decimal(raw_gross)
        discount_amount = _parse_decimal(raw_discount) or Decimal("0")
        rebate_amount = _parse_decimal(raw_rebate) or Decimal("0")
        wholesale_fee = _parse_decimal(raw_fee) or Decimal("0")
        unit_price = _parse_decimal(raw_price)

        # Derive unit_price if not present
        if unit_price is None and gross_value and quantity and quantity != 0:
            unit_price = (gross_value / quantity).quantize(Decimal("0.01"))
        elif unit_price is None and gross_value:
            unit_price = gross_value

        gross_revenue = gross_value or (
            (quantity * unit_price).quantize(Decimal("0.01"))
            if quantity and unit_price else None
        )
        net_revenue = (
            (gross_revenue - discount_amount - rebate_amount - wholesale_fee)
            if gross_revenue is not None else None
        )

        source_ref = raw_ref.strip() if raw_ref else None
        if source_ref:
            source_ref = f"{source_ref}-{raw_sku}"
        else:
            source_ref = f"DWS-{sale_date.isoformat() if sale_date else 'nodate'}-{raw_sku}-{row_num}"

        errors = []
        if not raw_sku:
            errors.append("Missing SKU code")
        if sale_date is None:
            errors.append(f"Invalid date: {raw_date!r}")
        if quantity is None and gross_value is None:
            errors.append("Missing quantity and gross value")

        sku_id, sku_name = (None, None)
        if raw_sku:
            sku_id, sku_name = lookups.lookup_sku(raw_sku, raw_description)

        customer_id, customer_name_canonical, customer_match_method = (None, None, "")
        if raw_customer or raw_customer_code:
            customer_id, customer_name_canonical, customer_match_method = lookups.lookup_customer(raw_customer, raw_customer_code)

        is_duplicate = lookups.is_duplicate(source_ref)
        is_sample = (gross_value is not None and gross_value == 0) or "sample" in raw_customer.lower()

        if errors:
            status = "error"
        elif is_duplicate:
            status = "duplicate"
        elif sku_id is None or (raw_customer and customer_id is None):
            status = "unmatched"
        else:
            status = "matched"

        preview_rows.append({
            "row_num": row_num,
            "raw_sku": raw_sku,
            "raw_description": raw_description,
            "raw_customer": raw_customer,
            "raw_customer_code": raw_customer_code,
            "sale_date": sale_date.isoformat() if sale_date else None,
            "quantity": float(quantity) if quantity else None,
            "unit_price": float(unit_price) if unit_price else None,
            "discount": float(discount_amount),
            "rebate": float(rebate_amount),
            "wholesale_fee": float(wholesale_fee),
            "net_revenue": float(net_revenue) if net_revenue else None,
            "source_ref": source_ref,
            "sku_id": sku_id,
            "sku_name": sku_name,
            "customer_id": customer_id,
            "customer_name": customer_name_canonical,
            "match_method": customer_match_method,
            "is_duplicate": is_duplicate,
            "is_sample": is_sample,
            "status": status,
            "errors": errors,
            "meta_territory": raw_area,
            "meta_rep": raw_rep,
            "meta_group": raw_group,
            "meta_category": raw_category,
        })

    return preview_rows


# ---------------------------------------------------------------------------
# ALM EDI/ZIP parser
# ---------------------------------------------------------------------------

def parse_alm_zip(file_path: str, lookups: Lookups) -> list[dict]:
    """Parse an ALM ZIP EDI report and return preview rows."""
    edi_lines = []

    def _extract_edi(zf):
        for name in zf.namelist():
            if name.endswith(".zip"):
                inner_data = zf.read(name)
                with zipfile.ZipFile(io.BytesIO(inner_data)) as inner_zf:
                    _extract_edi(inner_zf)
            else:
                try:
                    content = zf.read(name).decode("utf-8", errors="replace")
                    for line in content.splitlines():
                        if line.startswith("5|2|"):
                            edi_lines.append(line)
                except Exception:
                    pass

    with zipfile.ZipFile(file_path, "r") as zf:
        _extract_edi(zf)

    if not edi_lines:
        raise ValueError("ALM ZIP contains no 5|2 transaction records.")

    preview_rows = []
    for row_num, line in enumerate(edi_lines, start=1):
        fields = line.split("|")

        def _field(idx):
            return fields[idx].strip() if idx < len(fields) else ""

        raw_customer_code = _field(4)  # ALM customer account number (matches the owner's ALMCustomerCode)
        txn_id = _field(5)  # Actual invoice/transaction number
        raw_date = _field(8)
        raw_sku = _field(11)
        raw_desc = _field(12)
        pack_size_str = _field(18)
        raw_customer = _field(20)
        raw_address = _field(21)         # Customer street address
        raw_suburb = _field(22)          # Customer suburb
        raw_postcode = _field(23)        # Customer postcode
        raw_chain_group = _field(33)     # Chain/group name (e.g. "THE BOTTLE-O CDS - ACT")
        raw_premise_flag = _field(35)    # Premise type: "O"=off, "T"=on-premise, ""=unknown
        qty_delivered_str = _field(37)
        gross_cents_str = _field(43)
        discount_cents_str = _field(45)

        # Parse
        sale_date = _parse_date(raw_date)
        if sale_date is None and len(raw_date) == 8:
            # YYYYMMDD format
            try:
                sale_date = datetime.date(
                    int(raw_date[:4]), int(raw_date[4:6]), int(raw_date[6:8])
                )
            except (ValueError, IndexError):
                pass

        pack_size = 12
        try:
            pack_size = int(pack_size_str) if pack_size_str else 12
        except ValueError:
            pass
        if pack_size <= 0:
            pack_size = 12

        qty_bottles = _parse_decimal(qty_delivered_str) or Decimal("0")
        quantity = (qty_bottles / Decimal(str(pack_size))).quantize(Decimal("0.01"))

        gross_cents = _parse_decimal(gross_cents_str) or Decimal("0")
        gross_revenue = (gross_cents / Decimal("100")).quantize(Decimal("0.01"))

        discount_cents = _parse_decimal(discount_cents_str) or Decimal("0")
        discount_amount = (discount_cents / Decimal("100")).quantize(Decimal("0.01"))

        unit_price = (gross_revenue / quantity).quantize(Decimal("0.01")) if quantity else Decimal("0")
        net_revenue = gross_revenue - discount_amount

        source_ref = f"ALM-{txn_id}-{raw_date}-{raw_sku}" if txn_id else f"ALM-{raw_date}-{raw_sku}-{row_num}"

        errors = []
        if not raw_sku:
            errors.append("Missing product code")
        if sale_date is None:
            errors.append(f"Invalid date: {raw_date!r}")

        sku_id, sku_name = (None, None)
        if raw_sku:
            sku_id, sku_name = lookups.lookup_sku(raw_sku, raw_desc)
        elif raw_desc:
            sku_id, sku_name = lookups._fuzzy_sku_match(raw_desc)

        customer_id, customer_name_canonical, customer_match_method = (None, None, "")
        if raw_customer or raw_customer_code:
            customer_id, customer_name_canonical, customer_match_method = lookups.lookup_customer(raw_customer, raw_customer_code)

        is_duplicate = lookups.is_duplicate(source_ref)

        if errors:
            status = "error"
        elif is_duplicate:
            status = "duplicate"
        elif sku_id is None or (raw_customer and customer_id is None):
            status = "unmatched"
        else:
            status = "matched"

        # Derive meta fields for new-customer form pre-populate
        # meta_territory: extract state suffix from chain group (e.g. "THE BOTTLE-O CDS - ACT" -> "ACT")
        meta_territory = ""
        if raw_chain_group and " - " in raw_chain_group:
            meta_territory = raw_chain_group.rsplit(" - ", 1)[-1].strip()
        # meta_group: chain/group name (full value)
        meta_group = raw_chain_group
        # meta_category: map premise flag to On/Off Premise (matches DWS category convention)
        meta_category = ""
        if raw_premise_flag.upper() == "O":
            meta_category = "Off Premise"
        elif raw_premise_flag.upper() == "T":
            meta_category = "On Premise"
        # meta_rep: ALM EDI has no rep field (confirmed: Icon Commission Reps not in EDI data)

        preview_rows.append({
            "row_num": row_num,
            "raw_sku": raw_sku or raw_desc,
            "raw_description": raw_desc,  # BUG-30: EDI field 12 description for fuzzy suggestions
            "raw_customer": raw_customer,
            "raw_customer_code": raw_customer_code,
            "raw_suburb": raw_suburb,
            "raw_postcode": raw_postcode,
            "sale_date": sale_date.isoformat() if sale_date else None,
            "quantity": float(quantity),
            "unit_price": float(unit_price),
            "discount": float(discount_amount),
            "rebate": 0.0,
            "net_revenue": float(net_revenue),
            "source_ref": source_ref,
            "sku_id": sku_id,
            "sku_name": sku_name,
            "customer_id": customer_id,
            "customer_name": customer_name_canonical,
            "match_method": customer_match_method,
            "is_duplicate": is_duplicate,
            "status": status,
            "errors": errors,
            "meta_territory": meta_territory,
            "meta_rep": "",
            "meta_group": meta_group,
            "meta_category": meta_category,
        })

    return preview_rows


# ---------------------------------------------------------------------------
# Confirm import — uses existing importers with override mappings
# ---------------------------------------------------------------------------

def confirm_import(
    db_url: str, channel: str, file_path: str,
    sku_overrides: dict[str, int] | None = None,
    customer_overrides: dict[str, int] | None = None,
    customer_code_overrides: dict[str, int] | None = None,
    excluded_rows: list[int] | None = None,
) -> dict:
    """
    Run the actual import using existing importers.
    Before importing, save any manual overrides to sku_code_map / customer_code_map
    so the importer picks them up automatically.

    customer_code_overrides: maps customer_code (not name) to customer_id.
    Stored with "code:" prefix to disambiguate from name mappings.

    excluded_rows (D3 / 2026-05-11 / JF-13): 1-based preview row numbers the
    user unchecked in the import-preview UI. These rows are SKIPPED by both
    the staging parsers and the canonical sales_transaction importer, so
    excluded rows never reach combined_data. Staging tables still receive
    the raw EDI/CSV/XLSX bytes for audit unless the staging parser also
    honors excluded_rows (currently OUT OF SCOPE — staging = raw audit;
    canonical = what we trust).
    """
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            channel_lower = channel.lower()

            # BUG-24: batched upsert for override mappings. The override
            # counts are typically small (a handful per upload), but we use
            # execute_values for consistency across the ETL surface and to
            # collapse round-trips. Falls back to per-row inserts if the
            # batch statement fails.

            # --- Save SKU overrides to sku_code_map ---
            if sku_overrides:
                rows = [
                    (sku_id, channel_lower, external_code)
                    for external_code, sku_id in sku_overrides.items()
                ]
                _upsert_batch(
                    cur,
                    batch_label="preview sku_code_map",
                    batch_sql=(
                        "INSERT INTO sku_code_map "
                        "(sku_id, source_system, external_code) VALUES %s "
                        "ON CONFLICT (source_system, external_code) "
                        "DO UPDATE SET sku_id = EXCLUDED.sku_id"
                    ),
                    single_sql=(
                        "INSERT INTO sku_code_map "
                        "(sku_id, source_system, external_code) "
                        "VALUES (%s, %s, %s) "
                        "ON CONFLICT (source_system, external_code) "
                        "DO UPDATE SET sku_id = EXCLUDED.sku_id"
                    ),
                    rows=rows,
                )
                logger.info("Saved %d SKU override(s) for channel=%s",
                            len(rows), channel_lower)

            # --- Save customer overrides to customer_code_map (by name) ---
            if customer_overrides:
                rows = [
                    (customer_id, channel_lower, external_name)
                    for external_name, customer_id in customer_overrides.items()
                ]
                _upsert_batch(
                    cur,
                    batch_label="preview customer_code_map (name)",
                    batch_sql=(
                        "INSERT INTO customer_code_map "
                        "(customer_id, source_system, external_name) VALUES %s "
                        "ON CONFLICT (source_system, external_name) "
                        "DO UPDATE SET customer_id = EXCLUDED.customer_id"
                    ),
                    single_sql=(
                        "INSERT INTO customer_code_map "
                        "(customer_id, source_system, external_name) "
                        "VALUES (%s, %s, %s) "
                        "ON CONFLICT (source_system, external_name) "
                        "DO UPDATE SET customer_id = EXCLUDED.customer_id"
                    ),
                    rows=rows,
                )
                logger.info("Saved %d customer name override(s) for channel=%s",
                            len(rows), channel_lower)

            # --- Save customer code overrides (F2 — foolproof code matching) ---
            # Codes stored with "code:" prefix, leading zeros stripped (F1).
            if customer_code_overrides:
                rows = []
                for external_code, customer_id in customer_code_overrides.items():
                    code_clean = external_code.strip().lstrip('0')
                    if not code_clean:
                        continue
                    code_key = f"code:{code_clean}"
                    rows.append((customer_id, channel_lower, code_key))
                if rows:
                    _upsert_batch(
                        cur,
                        batch_label="preview customer_code_map (code)",
                        batch_sql=(
                            "INSERT INTO customer_code_map "
                            "(customer_id, source_system, external_name) VALUES %s "
                            "ON CONFLICT (source_system, external_name) "
                            "DO UPDATE SET customer_id = EXCLUDED.customer_id"
                        ),
                        single_sql=(
                            "INSERT INTO customer_code_map "
                            "(customer_id, source_system, external_name) "
                            "VALUES (%s, %s, %s) "
                            "ON CONFLICT (source_system, external_name) "
                            "DO UPDATE SET customer_id = EXCLUDED.customer_id"
                        ),
                        rows=rows,
                    )
                    logger.info("Saved %d customer code override(s) for channel=%s",
                                len(rows), channel_lower)

        conn.commit()
    finally:
        conn.close()

    # B12.1 wire-up (2026-04-29): run the new staging parser FIRST so the
    # full upload_batch + audit trail is captured (alm_edi_segment_5{0..3} /
    # dws_staging_114 / vinsight_sales_detail_28). Then run the legacy
    # importer for canonical sales_transaction inserts. The staging parsers
    # are ADDITIVE — they do not insert into sales_transaction themselves.
    staging_summary: dict | None = None
    try:
        if channel == "alm":
            from etl import import_alm_edi
            staging_summary = import_alm_edi.run_import(
                file_path, db_url=db_url, actor="upload_wizard"
            )
        elif channel == "dws":
            from etl import import_dws_zip
            staging_summary = import_dws_zip.run_import(
                file_path, db_url=db_url, actor="upload_wizard"
            )
        elif channel == "direct" and _looks_like_vinsight_28col_csv(file_path):
            from etl import import_vinsight_sales_detail
            staging_summary = import_vinsight_sales_detail.run_import(
                file_path, db_url=db_url, actor="upload_wizard"
            )
    except Exception as exc:
        logger.warning("B12 staging parser failed (non-fatal); canonical "
                       "import will still run: %s", exc)
        staging_summary = {"staging_error": str(exc)}

    # Canonical sales_transaction insert via the legacy importer.
    # D3: excluded_rows (preview 1-based) passes through to each importer.
    excluded_set: set[int] = set(excluded_rows or [])
    if channel == "direct":
        from etl.import_direct import DirectImporter
        importer = DirectImporter(db_url)
        result = importer.import_file(file_path, excluded_rows=excluded_set)
    elif channel == "dws":
        from etl.import_dws import DWSImporter
        importer = DWSImporter(db_url)
        result = importer.import_file(file_path, excluded_rows=excluded_set)
    elif channel == "alm":
        from etl.import_alm import ALMImporter
        importer = ALMImporter(db_url)
        result = importer.import_file(file_path, excluded_rows=excluded_set)
    else:
        raise ValueError(f"Unknown channel: {channel}")

    if staging_summary is not None:
        result = dict(result)
        result["staging_summary"] = staging_summary
    return result


def _looks_like_vinsight_28col_csv(file_path: str) -> bool:
    """Detect Vinsight Sales Detail 28-col format (B12 / JC-305) by peeking
    at the first few lines for the literal "Sales Detail" title row."""
    if not file_path.lower().endswith(".csv"):
        return False
    try:
        with open(file_path, "r", encoding="utf-8-sig", errors="ignore") as fh:
            head = "".join(next(fh, "") for _ in range(3))
    except OSError:
        return False
    return "sales detail" in head.lower()


# ---------------------------------------------------------------------------
# Preview — main entry point
# ---------------------------------------------------------------------------

def preview_file(db_url: str, channel: str, file_path: str) -> dict:
    """Parse file, match against DB, return preview JSON (no inserts)."""
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            lookups = Lookups(cur, channel)

            if channel == "direct":
                rows = parse_direct_csv(file_path, lookups)
            elif channel == "dws":
                rows = parse_dws_excel(file_path, lookups)
            elif channel == "alm":
                rows = parse_alm_zip(file_path, lookups)
            else:
                raise ValueError(f"Unknown channel: {channel}")

            # Summary stats
            matched = sum(1 for r in rows if r["status"] == "matched")
            unmatched = sum(1 for r in rows if r["status"] == "unmatched")
            duplicates = sum(1 for r in rows if r["status"] == "duplicate")
            errors = sum(1 for r in rows if r["status"] == "error")
            sample_rows = sum(1 for r in rows if r.get("is_sample", False))
            matched_by_code = sum(1 for r in rows if r["status"] == "matched" and r.get("match_method") == "code")
            matched_by_saved = sum(1 for r in rows if r["status"] == "matched" and r.get("match_method") == "saved")
            matched_by_name = sum(1 for r in rows if r["status"] == "matched" and r.get("match_method") == "name")
            total_revenue = sum(r["net_revenue"] or 0 for r in rows if r["status"] != "duplicate")

            # Collect unique unmatched SKUs and customers for assignment UI
            unmatched_skus = {}
            unmatched_customers = {}
            # JR-083: collect unmatched reps (meta_rep not in representative table)
            unmatched_reps: dict[str, dict] = {}
            # F4 (May 10): per-rep transaction drill-down. Build a customer_id ->
            # canonical_suburb map once so DWS/Direct rows (no row-level suburb
            # field) can backfill suburb from the matched canonical_customer.
            # ALM rows already carry raw_suburb (EDI field 22) and win at the
            # row level. unmatched-customer rows fall back to empty string.
            customer_suburb_map: dict[int, str] = {}
            for c in lookups.get_customer_list():
                cid = c.get("customer_id")
                if cid is not None:
                    customer_suburb_map[cid] = c.get("suburb") or ""
            # F4: per-rep aggregator. Keyed by lower(rep_name). Tracks distinct
            # customers + suburbs (capped at 20 / 10 in payload), full transaction
            # count, and 5 sample rows. Sets are converted to capped lists at
            # serialization time.
            unmatched_reps_detail: dict[str, dict] = {}
            for r in rows:
                if r["sku_id"] is None and r["raw_sku"] and r["status"] != "error":
                    if r["raw_sku"] not in unmatched_skus:
                        unmatched_skus[r["raw_sku"]] = {
                            "external_code": r["raw_sku"],
                            "description": r.get("raw_description") or "",
                            "row_count": 0,
                            "total_revenue": 0,
                        }
                    unmatched_skus[r["raw_sku"]]["row_count"] += 1
                    unmatched_skus[r["raw_sku"]]["total_revenue"] += r["net_revenue"] or 0

                if r["customer_id"] is None and r["raw_customer"] and r["status"] != "error":
                    if r["raw_customer"] not in unmatched_customers:
                        unmatched_customers[r["raw_customer"]] = {
                            "external_name": r["raw_customer"],
                            "external_code": r.get("raw_customer_code") or "",
                            "row_count": 0,
                            "total_revenue": 0,
                            "is_sample": True,
                            "meta_territory": r.get("meta_territory") or "",
                            "meta_rep": r.get("meta_rep") or "",
                            "meta_group": r.get("meta_group") or "",
                            "meta_category": r.get("meta_category") or "",
                            "meta_suburb": r.get("raw_suburb") or "",
                            "meta_postcode": r.get("raw_postcode") or "",
                        }
                    unmatched_customers[r["raw_customer"]]["row_count"] += 1
                    unmatched_customers[r["raw_customer"]]["total_revenue"] += r["net_revenue"] or 0
                    if not r.get("is_sample", False):
                        unmatched_customers[r["raw_customer"]]["is_sample"] = False

                # JR-083: aggregate distinct meta_rep values not matching any
                # existing representative. Mirror the shape of unmatched_skus /
                # unmatched_customers so the UI UnmatchedRepsPanel can render
                # them (see dashboard/src/components/ImportPreviewOverrides.tsx).
                # F4 (May 10): also capture per-rep customers / suburbs / 5 sample
                # rows so the owner can verify rep-territory assignment before clicking
                rep_name = (r.get("meta_rep") or "").strip()
                if rep_name and r["status"] != "error" and rep_name.lower() not in lookups._rep_names:
                    key = rep_name.lower()
                    if key not in unmatched_reps:
                        unmatched_reps[key] = {
                            "rep_name": rep_name,
                            "meta_territory": r.get("meta_territory") or "",
                            "row_count": 0,
                        }
                    unmatched_reps[key]["row_count"] += 1

                    # F4 detail aggregator
                    if key not in unmatched_reps_detail:
                        unmatched_reps_detail[key] = {
                            "_customers": set(),         # distinct customer names
                            "_suburbs": set(),           # distinct suburbs (non-empty only)
                            "transactions_count": 0,
                            "sample_rows": [],           # max 5 dicts
                        }
                    detail = unmatched_reps_detail[key]
                    detail["transactions_count"] += 1

                    raw_cust = (r.get("raw_customer") or "").strip()
                    if raw_cust:
                        detail["_customers"].add(raw_cust)

                    # Suburb resolution per channel:
                    #   ALM rows carry row-level raw_suburb (EDI field 22).
                    #   DWS / Direct rows have no row-level suburb — fall back
                    #   to canonical_customer.suburb when the row matched a
                    #   known customer. Unmatched DWS/Direct rows yield "".
                    suburb = (r.get("raw_suburb") or "").strip()
                    if not suburb and r.get("customer_id") is not None:
                        suburb = customer_suburb_map.get(r["customer_id"], "") or ""
                    if suburb:
                        detail["_suburbs"].add(suburb)

                    # Sample rows — keep first 5 in encounter order. SKU display
                    # prefers raw_description (human-readable) and falls back to
                    # raw_sku (code). qty + total_amount are floats already on
                    # the row dict (parser-side conversion).
                    if len(detail["sample_rows"]) < 5:
                        sku_display = (r.get("raw_description") or "").strip() \
                            or (r.get("raw_sku") or "").strip()
                        qty_val = r.get("quantity")
                        amt_val = r.get("net_revenue")
                        detail["sample_rows"].append({
                            "customer_name": raw_cust,
                            "suburb": suburb,
                            "sku_or_description": sku_display,
                            "qty": float(qty_val) if qty_val is not None else 0.0,
                            "total_amount": round(float(amt_val), 2) if amt_val is not None else 0.0,
                        })

            # F4: merge per-rep detail into the unmatched_reps payload + cap
            # large lists. Customer/suburb lists are sorted alphabetically for
            # stable output and easier visual scanning by the owner.
            for key, base in unmatched_reps.items():
                detail = unmatched_reps_detail.get(key)
                if not detail:
                    continue
                customers_sorted = sorted(detail["_customers"])
                suburbs_sorted = sorted(detail["_suburbs"])
                base["customers"] = customers_sorted[:20]
                base["customers_count_total"] = len(customers_sorted)
                base["transactions_count"] = detail["transactions_count"]
                base["distinct_suburbs"] = suburbs_sorted[:10]
                base["suburbs_count_total"] = len(suburbs_sorted)
                base["sample_rows"] = detail["sample_rows"]

            # F17: Add fuzzy suggestions for each unmatched customer.
            # B8 (May 8): pass suburb + postcode so suggest_customers() can
            # boost ratio when canonical suburb matches the upload row's
            # suburb (Customer 106 vs Customer 02 discriminator).
            for cust in unmatched_customers.values():
                cust["suggestions"] = lookups.suggest_customers(
                    cust["external_name"],
                    meta_territory=cust.get("meta_territory", ""),
                    meta_suburb=cust.get("meta_suburb", ""),
                    meta_postcode=cust.get("meta_postcode", ""),
                )

            # Pre-compute suggestions for ALL unique customers (matched + unmatched)
            # so the frontend has suggestions available when a user manually unmatches
            # an auto-matched customer.
            all_customer_suggestions: dict[str, list[dict]] = {}
            seen_customer_names: set[str] = set()
            for r in rows:
                raw_name = r.get("raw_customer") or ""
                if raw_name and raw_name not in seen_customer_names and r["status"] != "error":
                    seen_customer_names.add(raw_name)
                    # Skip unmatched — already computed above
                    if raw_name in unmatched_customers:
                        continue
                    suggestions = lookups.suggest_customers(
                        raw_name,
                        meta_territory=r.get("meta_territory") or "",
                        meta_suburb=r.get("raw_suburb") or "",
                        meta_postcode=r.get("raw_postcode") or "",
                    )
                    if suggestions:
                        all_customer_suggestions[raw_name] = suggestions

            # JF-12: Add fuzzy suggestions for each unmatched SKU
            for sku in unmatched_skus.values():
                sku["suggestions"] = lookups.suggest_skus(
                    sku["external_code"],
                    sku.get("description", ""),
                )

            # BUG-31: Pre-compute suggestions for ALL unique SKUs (matched + unmatched)
            # so the frontend has suggestions available when a user manually unmatches
            # an auto-matched SKU (same pattern as customer_suggestions above).
            all_sku_suggestions: dict[str, list[dict]] = {}
            seen_sku_codes: set[str] = set()
            for r in rows:
                raw_sku = r.get("raw_sku") or ""
                if raw_sku and raw_sku not in seen_sku_codes and r["status"] != "error":
                    seen_sku_codes.add(raw_sku)
                    # Skip unmatched — already computed above
                    if raw_sku in unmatched_skus:
                        continue
                    suggestions = lookups.suggest_skus(
                        raw_sku,
                        r.get("raw_description", ""),
                    )
                    if suggestions:
                        all_sku_suggestions[raw_sku] = suggestions

            return {
                "channel": channel,
                "file": os.path.basename(file_path),
                "summary": {
                    "total_rows": len(rows),
                    "matched": matched,
                    "unmatched": unmatched,
                    "duplicates": duplicates,
                    "errors": errors,
                    "total_revenue": round(total_revenue, 2),
                    "sample_rows": sample_rows,
                    "matched_by_code": matched_by_code,
                    "matched_by_saved": matched_by_saved,
                    "matched_by_name": matched_by_name,
                },
                "unmatched_skus": list(unmatched_skus.values()),
                "unmatched_customers": list(unmatched_customers.values()),
                "unmatched_reps": list(unmatched_reps.values()),
                "customer_suggestions": all_customer_suggestions,
                "sku_suggestions": all_sku_suggestions,
                "sku_list": lookups.get_sku_list(),
                "customer_list": lookups.get_customer_list(),
                "rows": rows,
            }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    import argparse
    parser = argparse.ArgumentParser(description="Data Import Wizard — Preview & Confirm")
    parser.add_argument("--channel", required=True, choices=["direct", "dws", "alm"])
    parser.add_argument("--file", required=True, help="Path to the import file")
    parser.add_argument("--confirm", action="store_true", help="Actually import (not just preview)")
    parser.add_argument("--overrides", type=str, default=None,
                        help='JSON: {"sku":{"CODE":42},"customer":{"NAME":17}}')
    args = parser.parse_args()

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        print("ERROR: DATABASE_URL not set.", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(args.file):
        print(f"ERROR: File not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    if args.confirm:
        sku_overrides = {}
        customer_overrides = {}
        customer_code_overrides = {}
        excluded_rows: list[int] = []
        if args.overrides:
            overrides = json.loads(args.overrides)
            sku_overrides = {k: int(v) for k, v in overrides.get("sku", {}).items()}
            customer_overrides = {k: int(v) for k, v in overrides.get("customer", {}).items()}
            customer_code_overrides = {k: int(v) for k, v in overrides.get("customer_code", {}).items()}
            # D3 / JF-13: 1-based preview row numbers the user unchecked.
            excluded_rows = [int(r) for r in overrides.get("excluded_rows", [])]

        result = confirm_import(
            db_url, args.channel, args.file,
            sku_overrides, customer_overrides, customer_code_overrides,
            excluded_rows=excluded_rows,
        )
        print(json.dumps(result, cls=DecimalEncoder))
    else:
        result = preview_file(db_url, args.channel, args.file)
        print(json.dumps(result, cls=DecimalEncoder))

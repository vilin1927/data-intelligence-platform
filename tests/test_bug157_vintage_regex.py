"""
BUG-157 regression test — verify the corrected vintage-extraction regex
shape used in etl/ingest_access_vintages.py:71 and :73 (and mirrored
per-row in schema/075_bug157_vintage_parser_fix.sql).

Old regex: '(19|20)\\d{2}'
  - Capture-group bug: Postgres SUBSTRING-FROM-pattern returns the FIRST
    parenthesized group, so '(19|20)' returned only '19' or '20'.

New regex: '(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])'
  - Outer capture holds the full 4-digit year.
  - Lookbehind `(?<![0-9])` + lookahead `(?![0-9])` reject false matches
    inside numeric invoice IDs (e.g. '1946' inside '1946540') while still
    matching stuck-to-text years (e.g. '2018' in 'Cabernet2018').

Python's `re` supports the same lookbehind/lookahead construct, so this
test validates the regex shape without needing a live Postgres connection.
"""

import re

REGEX = re.compile(r'(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])')


def extract(text: str) -> str | None:
    m = REGEX.search(text or "")
    return m.group(1) if m else None


# ─── Positive cases — should extract the full 4-digit year ────────────────

def test_year_with_space_before():
    """Standard: year preceded by a space."""
    assert extract("Coppabella Pinot Rose 2015") == "2015"


def test_year_at_end_of_string():
    """Year at end of description, no trailing char."""
    assert extract("Twelve Signs Shiraz 2013") == "2013"


def test_year_stuck_to_text():
    """Stuck-to-text: 'Cabernet2018' should still match 2018.
    This is the case POSIX \\y fails on because both 't' and '2' are word chars."""
    assert extract("Lock & Key ReserveCabernet2018 (6pack)") == "2018"


def test_year_at_start_of_string():
    """Year at start of string — lookbehind must allow beginning-of-string."""
    assert extract("2024 Moppity Estate Shiraz") == "2024"


def test_year_with_parens_after():
    """Year followed by '(': lookahead non-digit is satisfied."""
    assert extract("Twelve Signs Cabernet Merlot 2019 (6 packs)") == "2019"


def test_1990s_year():
    """19xx branch of the alternation."""
    assert extract("Classic 1996 Shiraz Collection") == "1996"


# ─── Negative cases — should NOT match spurious digits inside longer IDs ──

def test_invoice_id_rejected():
    """The 11 vintage=19 corrupted rows had codes like 1851954.
    Old buggy regex matched '19' (decade prefix). New regex must reject
    because '1954' is preceded by '5' (digit) or the leading digits of
    the ID are '18' not '19'."""
    assert extract("1851954") is None


def test_invoice_id_rejected_numeric_leading_19():
    """Code '1946540' — old naive fix would match '1946'; lookahead
    rejects because '1946' is followed by '5' (digit)."""
    assert extract("1946540") is None


def test_invoice_id_rejected_prefix_19():
    """Code '1968749' — '1968' would be captured by naive fix; lookahead
    finds '7' (digit) → reject."""
    assert extract("1968749") is None


def test_invoice_id_with_91_suffix():
    """Code '00744191' — no 19xx/20xx year extractable. (The 2 vintage=1991
    rows come from the step-3 2-digit-suffix fallback, not this regex.)"""
    assert extract("00744191") is None


def test_no_year_in_description():
    """Description with no year returns None."""
    assert extract("Twelve Signs Cabernet Merlot") is None


def test_empty_string():
    assert extract("") is None


def test_only_2_digit_suffix():
    """Code ending in a 2-digit vintage suffix: this regex does NOT match
    it (step-3 fallback handles 2-digit suffixes in the real ETL)."""
    assert extract("COCOROSB15") is None


# ─── Parametric spot-check against the 111 vintage=20 fix expectations ────

EXPECTED_FIXES = [
    ("Coppabella Pinot Rose 2015", "2015"),
    ("Twelve Signs Shiraz 2013", "2013"),
    ("Lock & Key Rose 2018", "2018"),
    ("Coppabella Sirius Chardonnay 2016", "2016"),
    ("Moppity ATRIUS Riesling 2025", "2025"),
    ("Twelve Signs Semillon Sauv Blanc 2022", "2022"),
    ("Procella Clare Riesling 2024", "2024"),
    ("Lock & Key ReserveCabernet2018 (6pack)", "2018"),      # stuck-to-text
    ("Twelve Signs Cab Sauvignon2016", "2016"),              # stuck-to-text
    ("Lock & Key ReserveCabernet2013", "2013"),              # stuck-to-text, end
]


def test_all_expected_fixes():
    for desc, want in EXPECTED_FIXES:
        got = extract(desc)
        assert got == want, f"extract({desc!r}) = {got!r}, want {want!r}"

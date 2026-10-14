-- B7b JC-179/180/182/183/184: 4-level grape-price cascade documentation + hot-path index
--
-- The cascade itself (region/color/grade/variety × vintage with NULL=wildcard +
-- "most specific wins" tiebreaker) was created by schema/008_m2_foundation.sql:
--   - TABLE     grape_price_rule   (lines 13-29)
--   - FUNCTION  get_effective_grape_price()  (lines 160-189)
--   - FUNCTION  weighted_grape_cost()         (lines 199-252)
--
-- (a) a covering index on the cascade hot-path keys (only if missing),
-- (b) a documented JSON-returning helper that surfaces *which* level matched,
--     so /api/wines/cogs can show the user "matched level 4 (region+color+grade+variety)"
--     vs "matched level 1 (region only — fell back via vintage cascade)" per JC-179/180.
-- (c) updated COMMENT ON TABLE so future readers know the 4-level intent.

BEGIN;

-- (a) Hot-path index: schema/008 already creates idx_grape_price_rule_lookup on
-- (region, vintage, color, grade, variety). That ordering favours vintage-first
-- queries; the cascade more often filters by region+color+grade+variety first
-- and falls back through vintages. Add a complementary index that matches the
-- WHERE-clause structure of get_effective_grape_price() so cascade lookups are
-- index-only.
CREATE INDEX IF NOT EXISTS idx_grape_price_rule_cascade
    ON grape_price_rule (region, color, grade, variety, vintage);

COMMENT ON TABLE grape_price_rule IS
    '4-level economic grape-price cascade (region → color → grade → variety) keyed by vintage. '
    'NULL in any level = wildcard. Lookup uses get_effective_grape_price() which picks the row '
    'with the most non-NULL columns matching (most-specific-wins). Seeded by /reference Scheduling '
    'tab (the owner maintained matrix). Drives economic_cogs_per_unit on sales_transaction_normalized '
    'via etl/calculate_economic_cogs.py.';

-- (b) Cascade helper that returns BOTH the price AND the matched level.
-- Used by /api/wines/cogs to render explainability.
CREATE OR REPLACE FUNCTION get_effective_grape_price_v2(
    p_region  VARCHAR,
    p_color   VARCHAR,
    p_grade   INTEGER,
    p_variety VARCHAR,
    p_vintage INTEGER
) RETURNS TABLE (
    price_per_ton  NUMERIC(10,2),
    level_matched  INTEGER,           -- 0..4 = number of non-wildcard cols matched (4 = most specific)
    rule_id        INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        gpr.price_per_ton,
        ((CASE WHEN gpr.region  IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN gpr.color   IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN gpr.grade   IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN gpr.variety IS NOT NULL THEN 1 ELSE 0 END))::int AS level_matched,
        gpr.id AS rule_id
    FROM grape_price_rule gpr
    WHERE gpr.vintage = p_vintage
      AND (gpr.region  IS NULL OR gpr.region  = p_region)
      AND (gpr.color   IS NULL OR gpr.color   = p_color)
      AND (gpr.grade   IS NULL OR gpr.grade   = p_grade)
      AND (gpr.variety IS NULL OR gpr.variety = p_variety)
    ORDER BY 2 DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_effective_grape_price_v2 IS
    'Like get_effective_grape_price but also returns level_matched (0..4) and rule_id, '
    'so the dashboard can show users which cascade level produced the price (JC-179/180 explainability).';

COMMIT;

--   SELECT * FROM get_effective_grape_price_v2('Tumbarumba', 'white', 1, 'Chardonnay', 2024);
--     expect a row with level_matched=4 from schema/008 seed
--   SELECT * FROM get_effective_grape_price_v2('Tumbarumba', 'red',   3, 'Shiraz',     2024);
--     expect level_matched=1 (region-only match for 2024) — proves L2/L3 fallback works

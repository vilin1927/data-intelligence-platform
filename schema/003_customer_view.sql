-- FIX-03: Customer view with cross-reference codes from all systems
-- Shows each customer with their DWS, ALM, Direct, Vinsight, and Xero codes in one row

CREATE OR REPLACE VIEW v_customer_with_codes AS
SELECT
    c.customer_id,
    c.customer_name,
    ch.channel_name,
    t.territory_name,
    c.customer_group,
    MAX(CASE WHEN ccm.source_system = 'dws'     THEN ccm.external_name END) AS dws_code,
    MAX(CASE WHEN ccm.source_system = 'alm'     THEN ccm.external_name END) AS alm_code,
    MAX(CASE WHEN ccm.source_system = 'direct'   THEN ccm.external_name END) AS direct_code,
    MAX(CASE WHEN ccm.source_system = 'vinsight' THEN ccm.external_name END) AS vinsight_code,
    MAX(CASE WHEN ccm.source_system = 'xero'     THEN ccm.external_name END) AS xero_code
FROM customer c
LEFT JOIN customer_code_map ccm ON ccm.customer_id = c.customer_id
LEFT JOIN channel ch ON ch.channel_id = c.channel_id
LEFT JOIN territory t ON t.territory_id = c.territory_id
GROUP BY c.customer_id, c.customer_name, ch.channel_name, t.territory_name, c.customer_group;

-- FIX-07: Rep ↔ Territory many-to-many relationship
-- The owner: "A rep can sell in multiple territories. Territory is geographic (by postcode)."
-- Current schema has rep → territory_id (1:1). Need junction table for M:N.

-- Create junction table
CREATE TABLE IF NOT EXISTS rep_territory (
  rep_id INTEGER NOT NULL REFERENCES representative(rep_id),
  territory_id INTEGER NOT NULL REFERENCES territory(territory_id),
  is_primary BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW(),
  PRIMARY KEY (rep_id, territory_id)
);

-- Migrate existing 1:1 assignments from representative.territory_id
INSERT INTO rep_territory (rep_id, territory_id, is_primary)
SELECT rep_id, territory_id, true
FROM representative
WHERE territory_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- Also derive rep-territory pairs from actual sales data
-- (a rep who sold to a customer in a territory implies they work that territory)
INSERT INTO rep_territory (rep_id, territory_id, is_primary)
SELECT DISTINCT st.rep_id, c.territory_id, false
FROM sales_transaction st
JOIN customer c ON c.customer_id = st.customer_id
WHERE st.rep_id IS NOT NULL
  AND c.territory_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM rep_territory rt
    WHERE rt.rep_id = st.rep_id AND rt.territory_id = c.territory_id
  )
ON CONFLICT DO NOTHING;

-- Report
SELECT r.rep_name, count(rt.territory_id) AS territories,
       string_agg(t.territory_name, ', ' ORDER BY t.territory_name) AS territory_list
FROM representative r
JOIN rep_territory rt ON rt.rep_id = r.rep_id
JOIN territory t ON t.territory_id = rt.territory_id
GROUP BY r.rep_name
HAVING count(rt.territory_id) > 1
ORDER BY count(rt.territory_id) DESC
LIMIT 15;

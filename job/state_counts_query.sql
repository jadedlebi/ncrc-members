-- Same membership filter as query.sql; aggregate raw state values (Python normalizes to USPS codes).
SELECT
  CAST(state AS STRING) AS state,
  COUNT(*) AS c
FROM __BQ_TABLE__
WHERE current_membership_status IN ('CURRENT', 'GRACE PERIOD')
  AND latitude IS NOT NULL
  AND longitude IS NOT NULL
  AND NULLIF(TRIM(CAST(state AS STRING)), '') IS NOT NULL
GROUP BY CAST(state AS STRING)

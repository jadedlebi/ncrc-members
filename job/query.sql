-- Standard SQL (GoogleSQL). Not legacy SQL — run with use_legacy_sql=false (see job/main.py).
-- Schema: companies — name, street_address*, postal_code, domain, etc.
--
-- FROM uses __BQ_TABLE__ (replaced at runtime from BQ_TABLE env in job/main.py) so the file does not
-- embed a real project.dataset.table. That avoids IDE/BigQuery extensions dry-running against a table
-- your local Google account cannot access ("Access Denied"). To lint against a real table, set BQ_TABLE
-- and authenticate: gcloud auth application-default login
SELECT
  CAST(COALESCE(name, '') AS STRING) AS company_na,
  CAST(
    TRIM(CONCAT(COALESCE(street_address, ''), ' ', COALESCE(street_address_2, '')))
    AS STRING
  ) AS address,
  CAST(city AS STRING) AS city,
  CAST(state AS STRING) AS state,
  CAST(postal_code AS STRING) AS zip1,
  CAST(COALESCE(NULLIF(TRIM(domain), ''), '') AS STRING) AS url,
  CAST(latitude AS FLOAT64) AS latitude,
  CAST(longitude AS FLOAT64) AS longitude
FROM __BQ_TABLE__
WHERE current_membership_status IN ('CURRENT', 'GRACE PERIOD')
  AND latitude IS NOT NULL
  AND longitude IS NOT NULL
  AND NULLIF(TRIM(CAST(state AS STRING)), '') IS NOT NULL

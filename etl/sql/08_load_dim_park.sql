-- =============================================================================
-- Step 08 — dim_park. Natural key = Retrosheet site code.
-- Attributes come from the park lookup file chosen by the stager (the file whose
-- codes best match the site codes in plays). Site codes missing from the lookup
-- are still added so every fact row has a real park member; their attributes
-- are 'Unknown' and counted in the verification report.
--
-- Hierarchy Park -> City -> Region -> Country:
--   region       = state/province when the lookup gives one, otherwise the
--                  country (parks in Japan, the UK, Australia, Mexico ... have
--                  no state, so the level repeats its parent instead of being empty)
--   region_label = 'Region, Country'        (unique Region member; just the
--                  country when there is no state)
--   city_label   = 'City, Region, Country'  (unique City member; 'City, Country'
--                  when there is no state)
-- =============================================================================
USE baseball_dw;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'dim_park', source_file, source_row, NULL, 'MISSING_NATURAL_KEY', 'Park lookup row has no park code'
FROM stg_park_lookup
WHERE park_code IS NULL
ORDER BY source_file, source_row;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'dim_park', source_file, source_row, park_code, 'DUPLICATE_NATURAL_KEY',
       'Repeated park code; first occurrence kept'
FROM (SELECT s.*, ROW_NUMBER() OVER (PARTITION BY park_code ORDER BY source_file, source_row) AS rn
      FROM stg_park_lookup s WHERE park_code IS NOT NULL) d
WHERE rn > 1
ORDER BY source_file, source_row;

INSERT INTO dim_park (park_code, park_name, city, state, country, region, region_label, city_label,
                      attribute_source)
SELECT park_code, park_name, city, state, country, region,
       LEFT(IF(state = 'None', country, CONCAT(region, ', ', country)), 90),
       LEFT(IF(state = 'None', CONCAT(city, ', ', country), CONCAT(city, ', ', region, ', ', country)), 160),
       'park lookup file'
FROM (SELECT park_code,
             LEFT(COALESCE(park_name, CONCAT('Park ', park_code)), 100) AS park_name,
             LEFT(COALESCE(city, 'Unknown'), 60)                        AS city,
             LEFT(COALESCE(state, 'None'), 40)                          AS state,
             LEFT(COALESCE(country, 'Unknown'), 40)                     AS country,
             LEFT(COALESCE(state, country, 'Unknown'), 40)              AS region,
             ROW_NUMBER() OVER (PARTITION BY park_code ORDER BY source_file, source_row) AS rn
      FROM stg_park_lookup s WHERE park_code IS NOT NULL) d
WHERE rn = 1
ORDER BY park_code;

INSERT INTO dim_park (park_code, park_name, city, state, country, region, region_label, city_label,
                      attribute_source)
SELECT s.site, CONCAT('Park ', s.site), 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown',
       'site code only (not in lookup)'
FROM (SELECT DISTINCT site FROM stg_retro_plays WHERE site IS NOT NULL) s
LEFT JOIN dim_park d ON d.park_code = s.site
WHERE d.park_key IS NULL
ORDER BY s.site;

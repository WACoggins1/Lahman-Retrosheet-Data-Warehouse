-- =============================================================================
-- Step 06 — dim_player (Lahman People). SCD Type 1: corrections overwrite.
-- =============================================================================
USE baseball_dw;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'dim_player', source_file, source_row, NULL, 'MISSING_NATURAL_KEY', 'People.playerID is blank'
FROM stg_lahman_people
WHERE playerID IS NULL
ORDER BY source_file, source_row;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'dim_player', source_file, source_row, playerID, 'DUPLICATE_NATURAL_KEY',
       'Repeated People.playerID; first occurrence kept'
FROM (SELECT p.*, ROW_NUMBER() OVER (PARTITION BY playerID ORDER BY source_file, source_row) AS rn
      FROM stg_lahman_people p WHERE playerID IS NOT NULL) d
WHERE rn > 1
ORDER BY source_file, source_row;

INSERT INTO dim_player (lahman_player_id, retro_id, bbref_id, first_name, last_name, full_name,
                        bats, throws, birth_year, birth_country, debut_date, final_game_date)
SELECT playerID, retroID, bbrefID,
       LEFT(COALESCE(nameFirst, ''), 60), LEFT(COALESCE(nameLast, ''), 60),
       LEFT(TRIM(CONCAT(COALESCE(nameFirst, ''), ' ', COALESCE(nameLast, ''))), 130),
       CASE WHEN UPPER(bats)   IN ('L','R','B') THEN UPPER(bats)   ELSE '?' END,
       CASE WHEN UPPER(throws) IN ('L','R')     THEN UPPER(throws) ELSE '?' END,
       CASE WHEN birthYear REGEXP '^[0-9]{4}$' THEN CAST(birthYear AS UNSIGNED) END,
       LEFT(birthCountry, 40),
       CASE WHEN debut REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN STR_TO_DATE(LEFT(debut, 10), '%Y-%m-%d')
            WHEN debut REGEXP '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN STR_TO_DATE(debut, '%c/%e/%Y') END,
       CASE WHEN finalGame REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN STR_TO_DATE(LEFT(finalGame, 10), '%Y-%m-%d')
            WHEN finalGame REGEXP '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN STR_TO_DATE(finalGame, '%c/%e/%Y') END
FROM (SELECT p.*, ROW_NUMBER() OVER (PARTITION BY playerID ORDER BY source_file, source_row) AS rn
      FROM stg_lahman_people p WHERE playerID IS NOT NULL) d
WHERE rn = 1
ORDER BY playerID;

-- Lookup used by the plate-appearance fact: Retrosheet ID -> player surrogate key.
-- If a Retrosheet ID were ever shared by two People rows, the lowest key is used
-- and the duplicate is reported by step 11.
DROP TABLE IF EXISTS wrk_player_retro;
CREATE TABLE wrk_player_retro (
  retro_id    VARCHAR(12) NOT NULL,
  player_key  INT         NOT NULL,
  n_rows      INT         NOT NULL,
  PRIMARY KEY (retro_id)
) ENGINE=InnoDB;
INSERT INTO wrk_player_retro (retro_id, player_key, n_rows)
SELECT retro_id, MIN(player_key), COUNT(*)
FROM dim_player
WHERE retro_id IS NOT NULL
GROUP BY retro_id
ORDER BY retro_id;

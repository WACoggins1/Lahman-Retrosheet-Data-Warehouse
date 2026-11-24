-- =============================================================================
-- Step 05 — dim_date (from a calendar range, not from fact dates) and dim_season
-- =============================================================================
USE baseball_dw;
SET SESSION cte_max_recursion_depth = 100000;

-- Day -> Month -> Season -> Era, for every calendar day 1871-01-01 .. 2025-12-31
INSERT INTO dim_date (full_date, day_of_month, day_name, month_num, month_name,
                      year_month_label, season_year, era_name, era_start_year, era_end_year)
WITH RECURSIVE cal AS (
  SELECT DATE('1871-01-01') AS d
  UNION ALL
  SELECT d + INTERVAL 1 DAY FROM cal WHERE d < DATE('2025-12-31')
)
SELECT c.d, DAY(c.d), DAYNAME(c.d), MONTH(c.d), MONTHNAME(c.d), DATE_FORMAT(c.d, '%Y-%m'),
       YEAR(c.d), COALESCE(e.era_name, 'Unassigned'), e.start_year, e.end_year
FROM cal c
LEFT JOIN ref_era e ON YEAR(c.d) BETWEEN e.start_year AND e.end_year
ORDER BY c.d;

-- Which plate-appearance components Lahman recorded, per season AND league.
-- A component counts as recorded when at least half of that league-season's
-- rows have it. Per-league because Lahman 1871-2025 mixes MLB and Negro League
-- rows whose sources tracked different categories: a handful of Negro League
-- rows with SF must not make SF "recorded" for every 1920s AL/NL row.
DROP TABLE IF EXISTS wrk_season_league_recorded;
CREATE TABLE wrk_season_league_recorded (
  yr       SMALLINT    NOT NULL,
  lg       VARCHAR(12) NOT NULL,
  hbp_rec  TINYINT     NOT NULL,
  sh_rec   TINYINT     NOT NULL,
  sf_rec   TINYINT     NOT NULL,
  PRIMARY KEY (yr, lg)
) ENGINE=InnoDB;
INSERT INTO wrk_season_league_recorded (yr, lg, hbp_rec, sh_rec, sf_rec)
SELECT CAST(yearID AS UNSIGNED) AS yr, COALESCE(lgID, '?') AS lg,
       AVG(HBP IS NOT NULL) >= 0.5, AVG(SH IS NOT NULL) >= 0.5, AVG(SF IS NOT NULL) >= 0.5
FROM stg_lahman_batting
WHERE yearID REGEXP '^[0-9]{4}$'
GROUP BY yr, lg
ORDER BY yr, lg;

-- Season-level summary for dim_season.pa_definition (same majority rule over
-- all of the season's rows).
DROP TABLE IF EXISTS wrk_season_recorded;
CREATE TABLE wrk_season_recorded (
  yr       SMALLINT NOT NULL,
  hbp_rec  TINYINT  NOT NULL,
  sh_rec   TINYINT  NOT NULL,
  sf_rec   TINYINT  NOT NULL,
  PRIMARY KEY (yr)
) ENGINE=InnoDB;
INSERT INTO wrk_season_recorded (yr, hbp_rec, sh_rec, sf_rec)
SELECT CAST(yearID AS UNSIGNED) AS yr,
       AVG(HBP IS NOT NULL) >= 0.5, AVG(SH IS NOT NULL) >= 0.5, AVG(SF IS NOT NULL) >= 0.5
FROM stg_lahman_batting
WHERE yearID REGEXP '^[0-9]{4}$'
GROUP BY yr
ORDER BY yr;

-- Season -> Era (conformed roll-up of dim_date: same season and era values)
INSERT INTO dim_season (season_year, era_name, era_start_year, era_end_year, pa_definition)
WITH RECURSIVE yrs AS (
  SELECT 1871 AS y
  UNION ALL
  SELECT y + 1 FROM yrs WHERE y < 2025
)
SELECT y.y, COALESCE(e.era_name, 'Unassigned'), e.start_year, e.end_year,
       CASE WHEN r.yr IS NULL THEN 'No batting data'
            ELSE CONCAT_WS('+', 'AB', 'BB', IF(r.hbp_rec = 1, 'HBP', NULL),
                           IF(r.sh_rec = 1, 'SH', NULL), IF(r.sf_rec = 1, 'SF', NULL)) END
FROM yrs y
LEFT JOIN ref_era e ON y.y BETWEEN e.start_year AND e.end_year
LEFT JOIN wrk_season_recorded r ON r.yr = y.y
ORDER BY y.y;

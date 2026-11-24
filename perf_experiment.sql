-- =============================================================================
-- Team 5 — Physical design and performance: summary table before/after
--
-- Optimization: agg_pa_season_park, a summary (aggregate) table at the grain
-- season x park x game type, built in ETL step 11 from fact_plate_appearance.
--
-- Test query: the park slice — 2023 home runs per batted ball by park.
--   BEFORE  answers it from fact_plate_appearance (every 2023 plate appearance)
--   AFTER   answers it from agg_pa_season_park   (a few rows per park)
--
-- Evidence produced, in order:
--   1. EXPLAIN ANALYZE of both versions (plan, rows read, actual time)
--   2. Wall-clock timing: each version run 10 times after a warm-up run
--   3. Proof both versions return identical results (EXCEPT both ways = 0)
--   4. Table sizes (rows) of the fact vs the summary table
--
-- Run:  docker exec -i dw-mysql mysql -uroot -pdwpass -t baseball_dw < perf_experiment.sql
-- =============================================================================
USE baseball_dw;

-- -----------------------------------------------------------------------------
-- 1a. BEFORE — query plan and actual cost on the fact table
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT pk.park_code, pk.park_name, pk.city,
       SUM(f.batted_ball) AS batted_balls, SUM(f.home_run) AS home_runs,
       ROUND(SUM(f.home_run) / SUM(f.batted_ball), 4) AS hr_per_batted_ball
FROM fact_plate_appearance AS f
JOIN dim_date AS d  ON d.date_key  = f.date_key
JOIN dim_park AS pk ON pk.park_key = f.park_key
WHERE d.season_year = 2023
GROUP BY pk.park_key, pk.park_code, pk.park_name, pk.city
HAVING SUM(f.batted_ball) >= 1000
ORDER BY hr_per_batted_ball DESC;

-- -----------------------------------------------------------------------------
-- 1b. AFTER — the same question answered from the summary table
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT pk.park_code, pk.park_name, pk.city,
       SUM(a.batted_ball) AS batted_balls, SUM(a.home_run) AS home_runs,
       ROUND(SUM(a.home_run) / SUM(a.batted_ball), 4) AS hr_per_batted_ball
FROM agg_pa_season_park AS a
JOIN dim_season AS s ON s.season_key = a.season_key
JOIN dim_park  AS pk ON pk.park_key  = a.park_key
WHERE s.season_year = 2023
GROUP BY pk.park_key, pk.park_code, pk.park_name, pk.city
HAVING SUM(a.batted_ball) >= 1000
ORDER BY hr_per_batted_ball DESC;

-- -----------------------------------------------------------------------------
-- 2. Wall-clock timing — 1 warm-up run, then 10 timed runs of each version
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS perf_timing;
CREATE TABLE perf_timing (
  version  VARCHAR(40) NOT NULL,
  run_no   INT         NOT NULL,
  ms       DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (version, run_no)
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS time_query;
DELIMITER //
CREATE PROCEDURE time_query(IN p_version VARCHAR(40), IN p_sql TEXT, IN p_runs INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  DECLARE t0 DATETIME(6);
  SET @q = p_sql;
  PREPARE stmt FROM @q;
  EXECUTE stmt;                                   -- warm-up (not timed)
  WHILE i < p_runs DO
    SET t0 = NOW(6);
    EXECUTE stmt;
    INSERT INTO perf_timing VALUES (p_version, i + 1, TIMESTAMPDIFF(MICROSECOND, t0, NOW(6)) / 1000);
    SET i = i + 1;
  END WHILE;
  DEALLOCATE PREPARE stmt;
END //
DELIMITER ;

-- Each version is wrapped in SELECT COUNT(*) so the timed runs do not print
-- 30 rows ten times; the inner GROUP BY / HAVING still runs in full.
CALL time_query('BEFORE: fact_plate_appearance',
 'SELECT COUNT(*) INTO @n_before FROM (
    SELECT pk.park_key, SUM(f.home_run) / SUM(f.batted_ball) AS r
    FROM fact_plate_appearance f
    JOIN dim_date d  ON d.date_key  = f.date_key
    JOIN dim_park pk ON pk.park_key = f.park_key
    WHERE d.season_year = 2023
    GROUP BY pk.park_key HAVING SUM(f.batted_ball) >= 1000) x', 10);

CALL time_query('AFTER: agg_pa_season_park',
 'SELECT COUNT(*) INTO @n_after FROM (
    SELECT pk.park_key, SUM(a.home_run) / SUM(a.batted_ball) AS r
    FROM agg_pa_season_park a
    JOIN dim_season s ON s.season_key = a.season_key
    JOIN dim_park  pk ON pk.park_key  = a.park_key
    WHERE s.season_year = 2023
    GROUP BY pk.park_key HAVING SUM(a.batted_ball) >= 1000) x', 10);

SELECT version,
       COUNT(*)            AS runs,
       ROUND(AVG(ms), 2)   AS avg_ms,
       MIN(ms)             AS min_ms,
       MAX(ms)             AS max_ms
FROM perf_timing
GROUP BY version
ORDER BY version DESC;

SELECT ROUND((SELECT AVG(ms) FROM perf_timing WHERE version LIKE 'BEFORE%')
           / (SELECT AVG(ms) FROM perf_timing WHERE version LIKE 'AFTER%'), 1) AS speedup_x,
       @n_before AS parks_before, @n_after AS parks_after;

-- -----------------------------------------------------------------------------
-- 3. Same answer? Rows in one result but not the other, both directions (expect 0, 0)
-- -----------------------------------------------------------------------------
SELECT
 (SELECT COUNT(*) FROM (
    SELECT pk.park_code, SUM(f.batted_ball) bb, SUM(f.home_run) hr
    FROM fact_plate_appearance f JOIN dim_date d ON d.date_key = f.date_key
    JOIN dim_park pk ON pk.park_key = f.park_key
    WHERE d.season_year = 2023 GROUP BY pk.park_code
    EXCEPT
    SELECT pk.park_code, SUM(a.batted_ball), SUM(a.home_run)
    FROM agg_pa_season_park a JOIN dim_season s ON s.season_key = a.season_key
    JOIN dim_park pk ON pk.park_key = a.park_key
    WHERE s.season_year = 2023 GROUP BY pk.park_code) x) AS only_in_before,
 (SELECT COUNT(*) FROM (
    SELECT pk.park_code, SUM(a.batted_ball) bb, SUM(a.home_run) hr
    FROM agg_pa_season_park a JOIN dim_season s ON s.season_key = a.season_key
    JOIN dim_park pk ON pk.park_key = a.park_key
    WHERE s.season_year = 2023 GROUP BY pk.park_code
    EXCEPT
    SELECT pk.park_code, SUM(f.batted_ball), SUM(f.home_run)
    FROM fact_plate_appearance f JOIN dim_date d ON d.date_key = f.date_key
    JOIN dim_park pk ON pk.park_key = f.park_key
    WHERE d.season_year = 2023 GROUP BY pk.park_code) y) AS only_in_after;

-- -----------------------------------------------------------------------------
-- 4. Size of what each version has to read
-- -----------------------------------------------------------------------------
SELECT 'fact_plate_appearance' AS table_name, COUNT(*) AS total_rows,
       (SELECT COUNT(*) FROM fact_plate_appearance f JOIN dim_date d ON d.date_key = f.date_key
        WHERE d.season_year = 2023) AS rows_for_2023
FROM fact_plate_appearance
UNION ALL
SELECT 'agg_pa_season_park', COUNT(*),
       (SELECT COUNT(*) FROM agg_pa_season_park a JOIN dim_season s ON s.season_key = a.season_key
        WHERE s.season_year = 2023)
FROM agg_pa_season_park;

DROP PROCEDURE IF EXISTS time_query;
DROP TABLE IF EXISTS perf_timing;

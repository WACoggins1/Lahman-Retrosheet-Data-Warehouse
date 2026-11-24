-- =============================================================================
-- Step 12 — fact_reconciliation (drill-across result, stored)
-- Grain: player x season x measure (H, HR) for the Retrosheet seasons.
-- Lahman side:     fact_player_season summed over stints.
-- Retrosheet side: fact_plate_appearance summed two ways —
--   regular_label: only games Retrosheet labels 'regular'
--   official:      every game with counts_in_official_season_stats = 1
--                  (adds the 2018 tiebreakers that MLB counts as regular season)
-- match_status records whether the player-season exists in one source or both.
-- =============================================================================
USE baseball_dw;

-- Seasons that have Retrosheet plate appearances (read from the summary table)
DROP TABLE IF EXISTS wrk_recon_seasons;
CREATE TABLE wrk_recon_seasons (season_key INT NOT NULL, PRIMARY KEY (season_key)) ENGINE=InnoDB;
INSERT INTO wrk_recon_seasons
SELECT DISTINCT season_key FROM agg_pa_season_park WHERE season_key <> -1 ORDER BY season_key;

DROP TABLE IF EXISTS wrk_recon_lahman;
CREATE TABLE wrk_recon_lahman (
  player_key INT NOT NULL, season_key INT NOT NULL, h INT NULL, hr INT NULL,
  PRIMARY KEY (player_key, season_key)
) ENGINE=InnoDB;
INSERT INTO wrk_recon_lahman
SELECT f.player_key, f.season_key, SUM(f.hits), SUM(f.home_runs)
FROM fact_player_season AS f
WHERE f.season_key IN (SELECT season_key FROM wrk_recon_seasons)
GROUP BY f.player_key, f.season_key
ORDER BY f.player_key, f.season_key;

DROP TABLE IF EXISTS wrk_recon_retro;
CREATE TABLE wrk_recon_retro (
  player_key INT NOT NULL, season_key INT NOT NULL,
  h_label INT NOT NULL, hr_label INT NOT NULL, h_official INT NOT NULL, hr_official INT NOT NULL,
  PRIMARY KEY (player_key, season_key)
) ENGINE=InnoDB;
INSERT INTO wrk_recon_retro
SELECT f.batter_key, s.season_key,
       SUM(CASE WHEN g.game_type_code = 'regular' THEN f.hit      ELSE 0 END),
       SUM(CASE WHEN g.game_type_code = 'regular' THEN f.home_run ELSE 0 END),
       SUM(f.hit), SUM(f.home_run)
FROM fact_plate_appearance AS f
JOIN dim_date      AS d ON d.date_key      = f.date_key
JOIN dim_season    AS s ON s.season_year   = d.season_year
JOIN dim_game_type AS g ON g.game_type_key = f.game_type_key
WHERE g.counts_in_official_season_stats = 1
  AND f.batter_key <> -1
GROUP BY f.batter_key, s.season_key
ORDER BY f.batter_key, s.season_key;

INSERT INTO fact_reconciliation (player_key, season_key, measure_code, match_status, lahman_value,
                                 retro_regular_label_value, retro_official_value, diff_regular_label, diff_official)
SELECT k.player_key, k.season_key, m.measure_code,
       CASE WHEN l.player_key IS NOT NULL AND r.player_key IS NOT NULL THEN 'both'
            WHEN l.player_key IS NOT NULL THEN 'lahman_only' ELSE 'retro_only' END,
       CASE m.measure_code WHEN 'H' THEN l.h ELSE l.hr END,
       CASE m.measure_code WHEN 'H' THEN r.h_label ELSE r.hr_label END,
       CASE m.measure_code WHEN 'H' THEN r.h_official ELSE r.hr_official END,
       CASE m.measure_code WHEN 'H' THEN l.h - r.h_label ELSE l.hr - r.hr_label END,
       CASE m.measure_code WHEN 'H' THEN l.h - r.h_official ELSE l.hr - r.hr_official END
FROM (SELECT player_key, season_key FROM wrk_recon_lahman
      UNION
      SELECT player_key, season_key FROM wrk_recon_retro) AS k
CROSS JOIN (SELECT 'H' AS measure_code UNION ALL SELECT 'HR') AS m
LEFT JOIN wrk_recon_lahman AS l ON l.player_key = k.player_key AND l.season_key = k.season_key
LEFT JOIN wrk_recon_retro  AS r ON r.player_key = k.player_key AND r.season_key = k.season_key
ORDER BY k.player_key, k.season_key, m.measure_code;

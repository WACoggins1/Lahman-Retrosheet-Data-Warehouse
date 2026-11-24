-- =============================================================================
-- Step 11 — agg_pa_season_park (summary table; physical-design optimization)
-- Rolls fact_plate_appearance up to season x park x game type. The season
-- comes from dim_date -> dim_season, the conformed roll-up shared with
-- fact_player_season. Every measure is a SUM of the fact, so totals match the
-- fact exactly (checked in step 13).
-- =============================================================================
USE baseball_dw;

INSERT INTO agg_pa_season_park (season_key, park_key, game_type_key, pa_count, at_bat, hit, home_run,
                                batted_ball, total_bases, walk, strikeout)
SELECT COALESCE(s.season_key, -1) AS season_key, f.park_key, f.game_type_key,
       SUM(f.pa_count), SUM(f.at_bat), SUM(f.hit), SUM(f.home_run),
       SUM(f.batted_ball), SUM(f.total_bases), SUM(f.walk), SUM(f.strikeout)
FROM fact_plate_appearance AS f
JOIN dim_date AS d ON d.date_key = f.date_key
LEFT JOIN dim_season AS s ON s.season_year = d.season_year
GROUP BY COALESCE(s.season_key, -1), f.park_key, f.game_type_key
ORDER BY season_key, f.park_key, f.game_type_key;

ANALYZE TABLE agg_pa_season_park;

SELECT d.full_date,                                                                  -- C4 drill-down: season -> day
       g.game_type_code,
       g.counts_in_official_season_stats,
       t.team_name                                                             AS batting_team,
       COUNT(DISTINCT f.game_id)                                               AS games,
       SUM(f.pa_count)                                                         AS plate_appearances,
       SUM(f.hit)                                                              AS hits,
       SUM(f.home_run)                                                         AS home_runs
FROM fact_plate_appearance AS f
JOIN dim_date      AS d ON d.date_key      = f.date_key
JOIN dim_game_type AS g ON g.game_type_key = f.game_type_key
JOIN dim_team      AS t ON t.team_key      = f.bat_team_key
WHERE d.season_year = 2018                                                           -- C2 slice: season = 2018
  AND g.game_type_code = 'playoff'                                                   -- C3 slice: game type = playoff
GROUP BY d.full_date, g.game_type_code, g.counts_in_official_season_stats,
         t.team_name                                                                 -- C1 kept dims; others -> all
ORDER BY d.full_date, t.team_name;

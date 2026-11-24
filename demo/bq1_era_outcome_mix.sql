SELECT x.level_shown, x.era_name, x.season, x.plate_appearances,
       x.so_per_pa, x.bb_per_pa, x.h_per_pa, x.hr_per_pa
FROM (
  SELECT 'C2 era' AS level_shown, s.era_name, s.era_start_year AS sort_year,     -- C2 roll-up: era level
         CAST(NULL AS SIGNED) AS season, 0 AS sort_sub,
         SUM(f.plate_appearances) AS plate_appearances,
         ROUND(SUM(CASE WHEN f.strikeouts IS NOT NULL THEN f.strikeouts END)
               / SUM(CASE WHEN f.strikeouts IS NOT NULL THEN f.plate_appearances END), 3) AS so_per_pa,
         ROUND(SUM(CASE WHEN f.walks IS NOT NULL THEN f.walks END)
               / SUM(CASE WHEN f.walks IS NOT NULL THEN f.plate_appearances END), 3)      AS bb_per_pa,
         ROUND(SUM(CASE WHEN f.hits IS NOT NULL THEN f.hits END)
               / SUM(CASE WHEN f.hits IS NOT NULL THEN f.plate_appearances END), 3)       AS h_per_pa,
         ROUND(SUM(CASE WHEN f.home_runs IS NOT NULL THEN f.home_runs END)
               / SUM(CASE WHEN f.home_runs IS NOT NULL THEN f.plate_appearances END), 4)  AS hr_per_pa
  FROM fact_player_season AS f                                                     -- C1 roll-up: player, team -> all
  JOIN dim_season AS s ON s.season_key = f.season_key
  WHERE s.season_key <> -1 AND f.plate_appearances IS NOT NULL
  GROUP BY s.era_name, s.era_start_year                                            -- C2 roll-up: season -> era
  UNION ALL
  SELECT 'C4 season', s.era_name, s.era_start_year, s.season_year, 1,              -- C3 drill-down: era -> season
         SUM(f.plate_appearances),
         ROUND(SUM(CASE WHEN f.strikeouts IS NOT NULL THEN f.strikeouts END)
               / SUM(CASE WHEN f.strikeouts IS NOT NULL THEN f.plate_appearances END), 3),
         ROUND(SUM(CASE WHEN f.walks IS NOT NULL THEN f.walks END)
               / SUM(CASE WHEN f.walks IS NOT NULL THEN f.plate_appearances END), 3),
         ROUND(SUM(CASE WHEN f.hits IS NOT NULL THEN f.hits END)
               / SUM(CASE WHEN f.hits IS NOT NULL THEN f.plate_appearances END), 3),
         ROUND(SUM(CASE WHEN f.home_runs IS NOT NULL THEN f.home_runs END)
               / SUM(CASE WHEN f.home_runs IS NOT NULL THEN f.plate_appearances END), 4)
  FROM fact_player_season AS f                                                     -- C1 roll-up: player, team -> all
  JOIN dim_season AS s ON s.season_key = f.season_key
  WHERE s.era_name = 'Post-Steroid'                                                -- C4 slice: era = Post-Steroid
    AND f.plate_appearances IS NOT NULL
  GROUP BY s.era_name, s.era_start_year, s.season_year                             -- C3 drill-down: season level
) AS x
ORDER BY x.sort_year, x.sort_sub, x.season;

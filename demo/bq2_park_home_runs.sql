SELECT pk.park_name,
       pk.city_label                                                          AS city,
       ROUND(SUM(CASE WHEN d.season_year = 2014 THEN f.home_run END)                 -- C3 pivot: 2014 column
             / SUM(CASE WHEN d.season_year = 2014 THEN f.batted_ball END), 4)  AS hr_per_bb_2014,
       ROUND(SUM(CASE WHEN d.season_year = 2018 THEN f.home_run END)                 -- C3 pivot: 2018 column
             / SUM(CASE WHEN d.season_year = 2018 THEN f.batted_ball END), 4)  AS hr_per_bb_2018,
       ROUND(SUM(CASE WHEN d.season_year = 2023 THEN f.home_run END)                 -- C3 pivot: 2023 column
             / SUM(CASE WHEN d.season_year = 2023 THEN f.batted_ball END), 4)  AS hr_per_bb_2023,
       ROUND(SUM(f.home_run) / SUM(f.batted_ball), 4)                          AS hr_per_bb_3_seasons
FROM fact_plate_appearance AS f
JOIN dim_date      AS d  ON d.date_key       = f.date_key                            -- C1 roll-up: day -> season
JOIN dim_park      AS pk ON pk.park_key      = f.park_key
JOIN dim_game_type AS g  ON g.game_type_key  = f.game_type_key                       -- C1 roll-up: game type -> phase
WHERE g.season_phase = 'Regular season'                                              -- C2 slice: regular season
GROUP BY pk.park_key, pk.park_name, pk.city_label                                    -- C1 park level; others -> all
HAVING SUM(CASE WHEN d.season_year = 2014 THEN f.batted_ball ELSE 0 END) >= 1000
   AND SUM(CASE WHEN d.season_year = 2018 THEN f.batted_ball ELSE 0 END) >= 1000
   AND SUM(CASE WHEN d.season_year = 2023 THEN f.batted_ball ELSE 0 END) >= 1000
ORDER BY hr_per_bb_3_seasons DESC;

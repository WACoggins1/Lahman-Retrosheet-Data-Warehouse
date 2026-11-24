SELECT d.season_year,                                                                -- C1 roll-up: day -> season
       m.platoon_status,                                                             -- C1 roll-up: hands -> platoon status
       SUM(f.pa_count)                                                              AS plate_appearances,
       ROUND(SUM(CASE WHEN o.result_type = 'On base' THEN f.pa_count ELSE 0 END)     -- C1 roll-up: outcome -> result type
             / SUM(f.pa_count), 3)                                                  AS on_base_per_pa,
       ROUND(SUM(f.total_bases) / SUM(f.at_bat), 3)                                 AS slugging
FROM fact_plate_appearance AS f
JOIN dim_date      AS d ON d.date_key      = f.date_key
JOIN dim_matchup   AS m ON m.matchup_key   = f.matchup_key
JOIN dim_game_type AS g ON g.game_type_key = f.game_type_key
JOIN dim_outcome   AS o ON o.outcome_key   = f.outcome_key
WHERE m.platoon_status IN ('Platoon advantage', 'Same side')                         -- C2 dice: matchup
  AND g.season_phase = 'Regular season'                                              -- C2 dice: game type
GROUP BY d.season_year, m.platoon_status                                             -- C1 levels kept; others -> all
ORDER BY d.season_year, m.platoon_status;

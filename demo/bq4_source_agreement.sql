SELECT s.season_year,                                                                -- C2 season level kept
       COUNT(DISTINCT r.player_key)                                            AS players_compared,
       COUNT(DISTINCT CASE WHEN r.measure_code = 'H'  AND r.diff_regular_label <> 0
                           THEN r.player_key END)                              AS h_differ_label_rule,   -- C3 pivot
       COUNT(DISTINCT CASE WHEN r.measure_code = 'HR' AND r.diff_regular_label <> 0
                           THEN r.player_key END)                              AS hr_differ_label_rule,  -- C3 pivot
       COUNT(DISTINCT CASE WHEN r.diff_regular_label <> 0
                           THEN r.player_key END)                              AS any_differ_label_rule,
       COUNT(DISTINCT CASE WHEN r.measure_code = 'H'  AND r.diff_official <> 0
                           THEN r.player_key END)                              AS h_differ_official,     -- C3 pivot
       COUNT(DISTINCT CASE WHEN r.measure_code = 'HR' AND r.diff_official <> 0
                           THEN r.player_key END)                              AS hr_differ_official,    -- C3 pivot
       COUNT(DISTINCT CASE WHEN r.diff_official <> 0
                           THEN r.player_key END)                              AS any_differ_official
FROM fact_reconciliation AS r
JOIN dim_season AS s ON s.season_key = r.season_key
WHERE r.match_status = 'both'                                                        -- C1 slice: in both sources
GROUP BY s.season_year                                                               -- C2 roll-up: player -> all
ORDER BY s.season_year;

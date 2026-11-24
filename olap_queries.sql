-- =============================================================================
-- Team 5 (Dead Ball Data) — Final project — olap_queries.sql
-- MySQL 8, database baseball_dw (Lahman 1871-2025 + Retrosheet 2014/2018/2023)
--
-- Organized by business question. Each query lists: the question and who uses
-- the answer, the OLAP operation(s), the hierarchy footsteps, the C1-Cn
-- decomposition (a chain of cuboids, each made by one OLAP operation on the
-- base cuboid or an earlier Ci), and the inference. Inside the SQL, every
-- clause is labeled with the Ci step it implements.
--
-- Coverage: roll-up (Q1-Q5), drill-down (Q1, Q5), slice (Q1, Q2, Q4, Q5),
-- dice (Q3), pivot (Q2, Q4). Hierarchies: Date (Day -> Year-month -> Season
-- -> Era), Game type (Game type -> Season phase), Park (Park -> City -> Region
-- -> Country),
-- Matchup (hand x hand -> Platoon status).
--
-- Base cuboids
--   fact_player_season    : player x season x team (stint)
--   fact_plate_appearance : date x batter x pitcher x batting team x fielding
--                           team x park x outcome x game type x matchup
--   fact_reconciliation   : player x season x measure x match status
-- =============================================================================
USE baseball_dw;

-- -----------------------------------------------------------------------------
-- QUERY 1 — BQ1: How has the outcome mix of a plate appearance (strikeout,
--   walk, hit, home run) shifted from era to era, and has the modern
--   strikeout trend turned since MLB's 2023 rule changes?
-- Who uses it: MLB's Competition Committee, judging whether rule changes
--   (pitch clock, shift ban, bigger bases) are moving the game back toward
--   balls in play.
-- OLAP operations: roll-up, drill-down, slice.
-- Hierarchy footsteps: Date — Season -> Era (roll-up), then Era -> Season
--   (drill-down) inside the Post-Steroid era.
-- Decomposition (base cuboid: player x season x team):
--   C1 = Roll-up the base cuboid on Player (player -> all) and Team (team -> all)
--        => season cuboid
--   C2 = Roll-up C1 on Date (season -> era)                  => era cuboid
--   C3 = Drill-down C2 on Date (era -> season)               => season cuboid
--   C4 = Slice C3 for era = 'Post-Steroid'                   => 2006-2025 seasons
--   The result shows C2 (every era) and C4 (Post-Steroid seasons) together.
-- Rates are non-additive: numerator and denominator are summed separately and
-- divided at query time, over rows where plate appearances are known.
-- Inference: Strikeouts per PA roughly tripled from the Live Ball era (0.070)
--   to the Post-Steroid era (0.205), and home runs per PA rose about sevenfold
--   from the Dead Ball era (0.0042 -> 0.0287), while hits per PA stayed near
--   0.22-0.25. Within the Post-Steroid era, strikeouts rose almost every season
--   to a 2020 peak (0.234) and have eased since (0.222 in 2025).
-- Decision supported: the 2023 rule changes coincide with the first sustained
--   dip in strikeout rate in this data; keep them, and target strikeouts if
--   further change is wanted, since strikeouts are what grew most.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- QUERY 2 — BQ2: Which ballparks inflate or suppress home runs, and does the
--   effect hold every season or is it one-year noise?
-- Who uses it: a club's front office (park-adjusted player valuation, which
--   free-agent hitters fit the home park); fantasy and betting analysts.
-- OLAP operations: roll-up, slice, pivot.
-- Hierarchy footsteps: Date — Day -> Year-month -> Season; Game type — Game type -> Season
--   phase; Park stays at the Park level of Park -> City -> Region -> Country
--   (its unique City member, city_label, is shown with it).
-- Decomposition (base cuboid: date x batter x pitcher x bat team x fld team x
--   park x outcome x game type x matchup):
--   C1 = Roll-up the base cuboid on Date (day -> season) and Game type
--        (game type -> season phase), and on every other dimension except Park
--        to all                                    => park x season x phase
--   C2 = Slice C1 for season phase = 'Regular season' => park x season
--   C3 = Pivot C2: move Season from rows to columns   => park x {2014, 2018, 2023}
--   Parks need 1,000+ batted balls in every season, so each cell is a full
--   home season and a park that changed (new stadium) drops out.
-- Inference: [fill in from your run: the top and bottom parks, and whether
--   their order holds in all three seasons]
-- Decision supported: weight a hitter's home-run numbers by the park effects
--   that repeat every season (not one-season spikes) when valuing free agents
--   and setting park-adjusted projections.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- QUERY 3 — BQ3: Has the platoon advantage (batter facing an opposite-handed
--   pitcher) changed across 2014, 2018 and 2023?
-- Who uses it: managers and analysts setting lineups and building platoon
--   pairs on the roster.
-- OLAP operations: roll-up, dice.
-- Hierarchy footsteps: Date — Day -> Year-month -> Season; Game type — Game type -> Season
--   phase; Outcome — Outcome -> Result type; Matchup — hand x hand ->
--   Platoon status.
-- Decomposition (base cuboid: the plate-appearance cube above):
--   C1 = Roll-up the base cuboid on Date (day -> season), Game type (game type
--        -> season phase), Outcome (outcome -> result type), Matchup (hands ->
--        platoon status), and on every other dimension to all
--                                    => season x phase x result type x platoon status
--   C2 = Dice C1 for platoon status IN ('Platoon advantage', 'Same side')
--        and season phase = 'Regular season'  => season x platoon status
-- Inference: In every season, hitters with the platoon advantage reached base
--   about 0.02 more often and slugged about 0.03 higher. The on-base gap
--   narrowed (0.024 -> 0.022 -> 0.018) while the slugging gap widened
--   (0.029 -> 0.030 -> 0.034): the advantage persists and shows up more as power.
-- Decision supported: keep platooning, especially at power positions, and
--   value hitters who hit same-side pitching well, since they are rarer.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- QUERY 4 — BQ4: Where do Lahman's season totals disagree with totals rolled
--   up from Retrosheet events, and does the game-type rule explain it?
-- Who uses it: researchers and data teams that combine both sources (and this
--   warehouse's own ETL), deciding which rule to use when deriving official
--   season totals from play-by-play data.
-- OLAP operations: slice, roll-up, pivot.
-- Hierarchy footsteps: Player — player -> all; Season stays at Season.
-- Decomposition (base cuboid: player x season x measure x match status,
--   from fact_reconciliation):
--   C1 = Slice the base cuboid for match status = 'both' (player-seasons
--        present in both sources)                    => player x season x measure
--   C2 = Roll-up C1 on Player (player -> all), counting players whose values
--        differ                                       => season x measure
--   C3 = Pivot C2: move Measure (H, HR) from rows to columns, once per
--        game-type rule                              => season x {H, HR} x rule
-- Inference: 2014 and 2023 agree completely. In 2018, [from your run: 21] of
--   990 players disagree when only games Retrosheet labels 'regular' are
--   counted, and none disagree under the official rule, which adds the two
--   tiebreaker games Retrosheet labels 'playoff'. Query 5 shows those games.
-- Decision supported: derive official season totals from Retrosheet with the
--   official-stats rule (dim_game_type.counts_in_official_season_stats), not
--   Retrosheet's game-type label; under that rule the two sources can be used
--   interchangeably for these seasons.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- QUERY 5 — BQ4 (the "why"): which games cause the 2018 disagreement?
-- Who uses it: the same data teams, to confirm the cause before adopting the
--   rule in Query 4.
-- OLAP operations: roll-up, slice, drill-down.
-- Hierarchy footsteps: Date — Season -> Year-month -> Day (drill-down); Game type at the
--   Game type level; Team at the Team level.
-- Decomposition (base cuboid: the plate-appearance cube):
--   C1 = Roll-up the base cuboid on every dimension except Date, Game type
--        and batting Team to all; Date at Season level
--                                    => season x game type x batting team
--   C2 = Slice C1 for season = 2018                    => game type x team
--   C3 = Slice C2 for game type = 'playoff' (Retrosheet's label for games
--        MLB counts as regular season)                  => team
--   C4 = Drill-down C3 on Date (season -> day)          => day x team
-- Inference: All of the disagreement sits in two games on one day,
--   October 1, 2018, played by four teams (the NL Central and NL West
--   tiebreakers). [from your run: games, plate appearances, hits, HR]
-- Decision supported: the cause is a game-type classification, not a data
--   error in either source; fix it with the dimension rule, not by editing data.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- QUERY 6 — ASSIGNED QUERY
-- Business question: [fill in]
-- Who uses it: [fill in]
-- OLAP operations: [fill in]
-- Hierarchy footsteps: [fill in]
-- Decomposition: C1 = ... ; C2 = ... ; C3 = ... ; C4 = ...
-- Inference: [fill in]
-- Decision supported: [fill in]
-- -----------------------------------------------------------------------------
-- (paste the assigned query here, labeling each clause with its Ci step)

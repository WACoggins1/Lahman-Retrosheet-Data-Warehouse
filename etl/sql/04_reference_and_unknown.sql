-- =============================================================================
-- Step 04 — Reference data, seeded dimensions, and reserved Unknown members
-- =============================================================================
USE baseball_dw;

-- Era boundaries (top level of the date hierarchy). Conventional named eras;
-- Whalen, Matthews & Mills (2025) recover the Dead Ball, Integration, Steroid and
-- Post-Steroid eras empirically. Contiguous and covering 1871-2025.
DROP TABLE IF EXISTS ref_era;
CREATE TABLE ref_era (
  era_name    VARCHAR(40) NOT NULL,
  start_year  SMALLINT    NOT NULL,
  end_year    SMALLINT    NOT NULL,
  era_order   TINYINT     NOT NULL,
  PRIMARY KEY (era_name)
) ENGINE=InnoDB;
INSERT INTO ref_era (era_name, start_year, end_year, era_order) VALUES
  ('Nineteenth Century', 1871, 1900, 1),
  ('Dead Ball',          1901, 1919, 2),
  ('Live Ball',          1920, 1941, 3),
  ('World War II',       1942, 1946, 4),
  ('Integration',        1947, 1960, 5),
  ('Expansion',          1961, 1976, 6),
  ('Free Agency',        1977, 1993, 7),
  ('Steroid',            1994, 2005, 8),
  ('Post-Steroid',       2006, 2025, 9);

-- Reserved Unknown members (surrogate key -1) ------------------------------------
INSERT INTO dim_date (date_key, full_date, day_of_month, day_name, month_num, month_name,
                      year_month_label, season_year, era_name, era_start_year, era_end_year)
VALUES (-1, NULL, NULL, 'Unknown', NULL, 'Unknown', 'Unknown', NULL, 'Unknown', NULL, NULL);

INSERT INTO dim_season (season_key, season_year, era_name, era_start_year, era_end_year, pa_definition)
VALUES (-1, NULL, 'Unknown', NULL, NULL, 'Unknown');

INSERT INTO dim_player (player_key, lahman_player_id, retro_id, bbref_id, first_name, last_name,
                        full_name, bats, throws, birth_year, birth_country, debut_date, final_game_date)
VALUES (-1, NULL, NULL, NULL, 'Unknown', 'Unknown', 'Unknown player', '?', '?', NULL, NULL, NULL, NULL);

INSERT INTO dim_team (team_key, franchise_id, team_code_lahman, team_code_retro, team_name, division_name,
                      league_code, league_name, effective_date, end_date, is_current, version_num)
VALUES (-1, NULL, 'UNK', 'UNK', 'Unknown team', 'Unknown', 'UNK', 'Unknown', '1000-01-01', '9999-12-31', 1, 0);

INSERT INTO dim_park (park_key, park_code, park_name, city, state, country, region, region_label, city_label,
                      attribute_source)
VALUES (-1, NULL, 'Unknown park', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown',
        'reserved Unknown member');

INSERT INTO dim_outcome (outcome_key, outcome_code, outcome_name, outcome_class, result_type)
VALUES (-1, NULL, 'Unknown', 'Unknown', 'Unknown');

INSERT INTO dim_game_type (game_type_key, game_type_code, game_type_name, season_phase, counts_in_official_season_stats)
VALUES (-1, NULL, 'Unknown', 'Unknown', 0);

INSERT INTO dim_matchup (matchup_key, bat_hand, pit_hand, matchup_label, platoon_status)
VALUES (-1, '-', '-', 'Unknown', 'Unknown');

-- dim_outcome: Outcome -> Outcome class -> Result type --------------------------
INSERT INTO dim_outcome (outcome_code, outcome_name, outcome_class, result_type) VALUES
  ('1B',  'Single',                    'Hit',              'On base'),
  ('2B',  'Double',                    'Hit',              'On base'),
  ('3B',  'Triple',                    'Hit',              'On base'),
  ('HR',  'Home run',                  'Hit',              'On base'),
  ('BB',  'Walk',                      'Walk',             'On base'),
  ('IBB', 'Intentional walk',          'Walk',             'On base'),
  ('HBP', 'Hit by pitch',              'Hit by pitch',     'On base'),
  ('KS',  'Strikeout, batter reached', 'Strikeout',        'Reached, no on-base credit'),
  ('K',   'Strikeout',                 'Strikeout',        'Out'),
  ('SF',  'Sacrifice fly',             'Sacrifice',        'Out'),
  ('SH',  'Sacrifice bunt',            'Sacrifice',        'Out'),
  ('XI',  'Catcher interference',      'Interference',     'Reached, no on-base credit'),
  ('ROE', 'Reached on error',          'Reached on error', 'Reached, no on-base credit'),
  ('FC',  'Fielder''s choice',         'Fielder''s choice','Reached, no on-base credit'),
  ('OUT', 'Batted-ball out',           'Out in play',      'Out'),
  ('OTH', 'Other plate appearance',    'Other',            'Out');

-- dim_game_type: Game type -> Season phase.
-- Retrosheet labels the 2018 tiebreaker games 'playoff'; MLB (and Lahman) count them
-- in official regular-season statistics, so they belong to the Regular season phase.
INSERT INTO dim_game_type (game_type_code, game_type_name, season_phase, counts_in_official_season_stats) VALUES
  ('regular',        'Regular season game',                 'Regular season', 1),
  ('playoff',        'Tiebreaker game (Retrosheet: playoff)','Regular season', 1),
  ('wildcard',       'Wild Card round',                     'Postseason',     0),
  ('divisionseries', 'Division Series',                     'Postseason',     0),
  ('lcs',            'League Championship Series',          'Postseason',     0),
  ('worldseries',    'World Series',                        'Postseason',     0),
  ('allstar',        'All-Star Game',                       'Exhibition',     0);

-- Any game type present in the data but not seeded is added, flagged Unclassified.
INSERT INTO dim_game_type (game_type_code, game_type_name, season_phase, counts_in_official_season_stats)
SELECT s.gametype, LEFT(CONCAT('Unclassified: ', s.gametype), 40), 'Unclassified', 0
FROM (SELECT DISTINCT gametype FROM stg_retro_plays WHERE gametype IS NOT NULL) s
LEFT JOIN dim_game_type g ON g.game_type_code = s.gametype
WHERE g.game_type_key IS NULL
ORDER BY s.gametype;

-- dim_matchup: junk dimension, every batter-hand x pitcher-hand combination ------
INSERT INTO dim_matchup (bat_hand, pit_hand, matchup_label, platoon_status)
SELECT b.h, p.h, CONCAT(b.h, ' vs ', p.h),
       CASE WHEN b.h IN ('L','R') AND p.h IN ('L','R')
              THEN IF(b.h <> p.h, 'Platoon advantage', 'Same side')
            WHEN b.h = 'B' AND p.h IN ('L','R') THEN 'Switch hitter, side not recorded'
            ELSE 'Hand unknown' END
FROM (SELECT 'L' AS h, 1 AS o UNION ALL SELECT 'R', 2 UNION ALL SELECT 'B', 3 UNION ALL SELECT '?', 4) b
CROSS JOIN (SELECT 'L' AS h, 1 AS o UNION ALL SELECT 'R', 2 UNION ALL SELECT '?', 3) p
ORDER BY b.o, p.o;

-- =============================================================================
-- Step 13 — Load verification
--   1. Load reconciliation: source rows = loaded rows + rejected rows, per table
--   2. Grain checks (must return zero rows)
--   3. Orphan checks, one per fact foreign key (must return 0)
--   4. Summary-table and reconciliation-fact totals checks
--   5. Reject and data-quality summaries
-- Lines starting with "-- @report:" are printed as headings by run_etl.py.
-- =============================================================================
USE baseball_dw;

TRUNCATE TABLE etl_load_audit;

INSERT INTO etl_load_audit
SELECT 'dim_date', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Calendar days 1871-01-01 to 2025-12-31'
FROM (SELECT DATEDIFF('2025-12-31', '1871-01-01') + 1 AS s,
             (SELECT COUNT(*) FROM dim_date WHERE date_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_date') AS r) x;

INSERT INTO etl_load_audit
SELECT 'dim_season', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Seasons 1871 to 2025'
FROM (SELECT 2025 - 1871 + 1 AS s,
             (SELECT COUNT(*) FROM dim_season WHERE season_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_season') AS r) x;

INSERT INTO etl_load_audit
SELECT 'dim_player', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Lahman People.csv rows'
FROM (SELECT (SELECT COUNT(*) FROM stg_lahman_people) AS s,
             (SELECT COUNT(*) FROM dim_player WHERE player_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_player') AS r) x;

INSERT INTO etl_load_audit
SELECT 'dim_team', s, l, r, IF(s = l + r, 'YES', 'NO'),
       CONCAT('Lahman Teams.csv team-season rows; loaded = team-seasons assigned to one of ', v, ' SCD2 versions')
FROM (SELECT (SELECT COUNT(*) FROM stg_lahman_teams) AS s,
             (SELECT COUNT(*) FROM wrk_team_lookup) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_team') AS r,
             (SELECT COUNT(*) FROM dim_team WHERE team_key <> -1) AS v) x;

INSERT INTO etl_load_audit
SELECT 'dim_park', s, l, r, IF(s = l + r, 'YES', 'NO'),
       'Park lookup rows plus Retrosheet site codes absent from the lookup'
FROM (SELECT (SELECT COUNT(*) FROM stg_park_lookup)
           + (SELECT COUNT(*) FROM dim_park WHERE attribute_source = 'site code only (not in lookup)') AS s,
             (SELECT COUNT(*) FROM dim_park WHERE park_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_park') AS r) x;

INSERT INTO etl_load_audit
SELECT 'dim_outcome', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Seeded outcome codes (step 04)'
FROM (SELECT 16 AS s,
             (SELECT COUNT(*) FROM dim_outcome WHERE outcome_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_outcome') AS r) x;

INSERT INTO etl_load_audit
SELECT 'dim_game_type', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Seeded game types plus unseen codes found in plays'
FROM (SELECT 7 + (SELECT COUNT(DISTINCT gametype) FROM stg_retro_plays
                  WHERE gametype IS NOT NULL
                    AND gametype NOT IN ('regular','playoff','wildcard','divisionseries','lcs','worldseries','allstar')) AS s,
             (SELECT COUNT(*) FROM dim_game_type WHERE game_type_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_game_type') AS r) x;

INSERT INTO etl_load_audit
SELECT 'dim_matchup', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Batter hand (L,R,B,?) x pitcher hand (L,R,?)'
FROM (SELECT 4 * 3 AS s,
             (SELECT COUNT(*) FROM dim_matchup WHERE matchup_key <> -1) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'dim_matchup') AS r) x;

INSERT INTO etl_load_audit
SELECT 'fact_player_season', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Lahman Batting.csv rows'
FROM (SELECT (SELECT COUNT(*) FROM stg_lahman_batting) AS s,
             (SELECT COUNT(*) FROM fact_player_season) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'fact_player_season') AS r) x;

INSERT INTO etl_load_audit
SELECT 'fact_plate_appearance', s, l, r, IF(s = l + r, 'YES', 'NO'), 'Retrosheet plays.csv rows, 2014 + 2018 + 2023'
FROM (SELECT (SELECT COUNT(*) FROM stg_retro_plays) AS s,
             (SELECT COUNT(*) FROM fact_plate_appearance) AS l,
             (SELECT COUNT(*) FROM etl_reject WHERE target_table = 'fact_plate_appearance') AS r) x;

-- Lahman hits in the Retrosheet seasons (for the reconciliation totals check)
DROP TABLE IF EXISTS wrk_recon_lahman_check;
CREATE TABLE wrk_recon_lahman_check ENGINE=InnoDB AS
SELECT f.hits FROM fact_player_season f
WHERE f.season_key IN (SELECT season_key FROM wrk_recon_seasons);

-- Data-quality summary used on the Data Quality slide and in the design log
DROP TABLE IF EXISTS etl_dq_summary;
CREATE TABLE etl_dq_summary (
  metric      VARCHAR(60)  NOT NULL,
  value       BIGINT       NOT NULL,
  description VARCHAR(160) NOT NULL,
  PRIMARY KEY (metric)
) ENGINE=InnoDB;
INSERT INTO etl_dq_summary (metric, value, description) VALUES
 ('batting_rows_pre1954', (SELECT COUNT(*) FROM stg_lahman_batting WHERE yearID < '1954'), 'Lahman Batting rows before 1954'),
 ('sf_blank_pre1954', (SELECT COUNT(*) FROM stg_lahman_batting WHERE yearID < '1954' AND SF IS NULL), 'Batting.SF blank, seasons before 1954'),
 ('sf_blank_all', (SELECT COUNT(*) FROM stg_lahman_batting WHERE SF IS NULL), 'Batting.SF blank, all seasons'),
 ('seasons_sf_not_recorded', (SELECT COUNT(*) FROM wrk_season_recorded WHERE sf_rec = 0), 'Seasons where SF was not a recorded category (blank in most rows)'),
 ('pa_era_rule_applied', (SELECT COUNT(*) FROM fact_player_season WHERE plate_appearances IS NOT NULL AND (sac_flies IS NULL OR hit_by_pitch IS NULL OR sac_hits IS NULL)), 'Rows whose PA used the era-aware rule (an unrecorded component added 0)'),
 ('pa_left_null', (SELECT COUNT(*) FROM fact_player_season WHERE plate_appearances IS NULL), 'Rows where PA could not be derived and stays NULL'),
 ('team_seasons_code_differs', (SELECT COUNT(*) FROM wrk_team_season WHERE team_code_lahman <> team_code_retro), 'Team-seasons where Lahman teamID differs from teamIDretro'),
 ('franchise_seasons_multi_team', (SELECT COUNT(*) FROM wrk_franchise_season WHERE n_teams > 1), 'Franchise-seasons with two or more team rows (mapped to one SCD2 version)'),
 ('parks_region_is_country', (SELECT COUNT(*) FROM dim_park WHERE park_key <> -1 AND state = 'None'), 'Parks with no state/province: Region level repeats the country'),
 ('team_versions', (SELECT COUNT(*) FROM dim_team WHERE team_key <> -1), 'dim_team SCD2 versions'),
 ('franchises_with_history', (SELECT COUNT(*) FROM (SELECT franchise_id FROM dim_team WHERE team_key <> -1 GROUP BY franchise_id HAVING COUNT(*) > 1) z), 'Franchises with more than one SCD2 version'),
 ('ambiguous_retro_team_codes', (SELECT COUNT(*) FROM wrk_team_retro_lookup WHERE n_rows > 1), 'Season + Retrosheet team code pairs matching more than one team'),
 ('not_pa_rows', (SELECT COUNT(*) FROM etl_reject WHERE reason_code = 'NOT_PLATE_APPEARANCE'), 'Retrosheet rows that are not plate appearances (pa = 0)'),
 ('plays_rows', (SELECT COUNT(*) FROM stg_retro_plays), 'Retrosheet plays rows staged'),
 ('tiebreaker_pa_rows', (SELECT COUNT(*) FROM fact_plate_appearance f JOIN dim_game_type g ON g.game_type_key = f.game_type_key WHERE g.game_type_code = 'playoff'), 'Plate appearances in Retrosheet playoff (tiebreaker) games'),
 ('people_without_retro_id', (SELECT COUNT(*) FROM dim_player WHERE player_key <> -1 AND retro_id IS NULL), 'dim_player members with no Retrosheet ID'),
 ('duplicate_retro_ids', (SELECT COUNT(*) FROM wrk_player_retro WHERE n_rows > 1), 'Retrosheet IDs shared by more than one People row'),
 ('pa_unknown_batter', (SELECT COUNT(*) FROM fact_plate_appearance WHERE batter_key = -1), 'Plate appearances assigned the Unknown batter'),
 ('pa_unknown_pitcher', (SELECT COUNT(*) FROM fact_plate_appearance WHERE pitcher_key = -1), 'Plate appearances assigned the Unknown pitcher'),
 ('pa_unknown_bat_team', (SELECT COUNT(*) FROM fact_plate_appearance WHERE bat_team_key = -1), 'Plate appearances assigned the Unknown batting team'),
 ('pa_unknown_outcome', (SELECT COUNT(*) FROM fact_plate_appearance WHERE outcome_key = -1), 'Plate appearances with no recognised outcome flag'),
 ('pa_unknown_date', (SELECT COUNT(*) FROM fact_plate_appearance WHERE date_key = -1), 'Plate appearances with an unparseable date'),
 ('parks_without_attributes', (SELECT COUNT(*) FROM dim_park WHERE attribute_source = 'site code only (not in lookup)'), 'Park codes in plays not found in the park lookup'),
 ('ps_unknown_team', (SELECT COUNT(*) FROM fact_player_season WHERE team_key = -1), 'Player-season rows assigned the Unknown team');

-- @report: Source file -> staging -> warehouse row counts
SELECT x.staging_table,
       x.files,
       x.source_file_rows,
       x.staging_rows,
       IF(x.source_file_rows = x.staging_rows, 'YES', 'NO')                AS file_eq_staging,
       a.target_table                                                      AS warehouse_table,
       a.source_rows                                                       AS warehouse_source_rows,
       a.loaded_rows,
       a.rejected_rows,
       a.balanced
FROM (SELECT sa.staging_table, COUNT(*) AS files, SUM(sa.file_rows) AS source_file_rows,
             CASE sa.staging_table
               WHEN 'stg_lahman_people'  THEN (SELECT COUNT(*) FROM stg_lahman_people)
               WHEN 'stg_lahman_batting' THEN (SELECT COUNT(*) FROM stg_lahman_batting)
               WHEN 'stg_lahman_teams'   THEN (SELECT COUNT(*) FROM stg_lahman_teams)
               WHEN 'stg_retro_plays'    THEN (SELECT COUNT(*) FROM stg_retro_plays)
               WHEN 'stg_park_lookup'    THEN (SELECT COUNT(*) FROM stg_park_lookup)
             END AS staging_rows,
             CASE sa.staging_table
               WHEN 'stg_lahman_people'  THEN 'dim_player'
               WHEN 'stg_lahman_batting' THEN 'fact_player_season'
               WHEN 'stg_lahman_teams'   THEN 'dim_team'
               WHEN 'stg_retro_plays'    THEN 'fact_plate_appearance'
               WHEN 'stg_park_lookup'    THEN 'dim_park'
             END AS target_table
      FROM etl_source_audit AS sa
      GROUP BY sa.staging_table) AS x
LEFT JOIN etl_load_audit AS a ON a.target_table = x.target_table
ORDER BY x.staging_table;

-- @report: Totals check — summary table and reconciliation fact match the base facts
SELECT 'agg_pa_season_park.pa_count = SUM(fact_plate_appearance.pa_count)' AS check_name,
       (SELECT SUM(pa_count) FROM agg_pa_season_park) AS derived_total,
       (SELECT SUM(pa_count) FROM fact_plate_appearance) AS base_total,
       IF((SELECT SUM(pa_count) FROM agg_pa_season_park) = (SELECT SUM(pa_count) FROM fact_plate_appearance), 'YES', 'NO') AS ok
UNION ALL
SELECT 'agg_pa_season_park.home_run = SUM(fact_plate_appearance.home_run)',
       (SELECT SUM(home_run) FROM agg_pa_season_park), (SELECT SUM(home_run) FROM fact_plate_appearance),
       IF((SELECT SUM(home_run) FROM agg_pa_season_park) = (SELECT SUM(home_run) FROM fact_plate_appearance), 'YES', 'NO')
UNION ALL
SELECT 'agg_pa_season_park.batted_ball = SUM(fact_plate_appearance.batted_ball)',
       (SELECT SUM(batted_ball) FROM agg_pa_season_park), (SELECT SUM(batted_ball) FROM fact_plate_appearance),
       IF((SELECT SUM(batted_ball) FROM agg_pa_season_park) = (SELECT SUM(batted_ball) FROM fact_plate_appearance), 'YES', 'NO')
UNION ALL
SELECT 'fact_reconciliation lahman H = fact_player_season hits (Retrosheet seasons)',
       (SELECT COALESCE(SUM(lahman_value), 0) FROM fact_reconciliation WHERE measure_code = 'H'),
       (SELECT COALESCE(SUM(hits), 0) FROM wrk_recon_lahman_check),
       IF((SELECT COALESCE(SUM(lahman_value), 0) FROM fact_reconciliation WHERE measure_code = 'H')
          = (SELECT COALESCE(SUM(hits), 0) FROM wrk_recon_lahman_check), 'YES', 'NO')
UNION ALL
SELECT 'fact_reconciliation retro official H = fact_plate_appearance hits (official games)',
       (SELECT COALESCE(SUM(retro_official_value), 0) FROM fact_reconciliation WHERE measure_code = 'H'),
       (SELECT COALESCE(SUM(f.hit), 0) FROM fact_plate_appearance f
          JOIN dim_game_type g ON g.game_type_key = f.game_type_key
          JOIN dim_date d ON d.date_key = f.date_key
        WHERE g.counts_in_official_season_stats = 1 AND f.batter_key <> -1 AND d.season_year IS NOT NULL),
       IF((SELECT COALESCE(SUM(retro_official_value), 0) FROM fact_reconciliation WHERE measure_code = 'H')
          = (SELECT COALESCE(SUM(f.hit), 0) FROM fact_plate_appearance f
               JOIN dim_game_type g ON g.game_type_key = f.game_type_key
               JOIN dim_date d ON d.date_key = f.date_key
             WHERE g.counts_in_official_season_stats = 1 AND f.batter_key <> -1 AND d.season_year IS NOT NULL), 'YES', 'NO');

-- @report: Grain check — fact_reconciliation (expect 0 rows)
SELECT player_key, season_key, measure_code, COUNT(*) AS n
FROM fact_reconciliation
GROUP BY player_key, season_key, measure_code
HAVING COUNT(*) > 1;

-- @report: Grain check — agg_pa_season_park (expect 0 rows)
SELECT season_key, park_key, game_type_key, COUNT(*) AS n
FROM agg_pa_season_park
GROUP BY season_key, park_key, game_type_key
HAVING COUNT(*) > 1;

-- @report: Load reconciliation (source rows = loaded rows + rejected rows)
SELECT target_table, source_rows, loaded_rows, rejected_rows, balanced, source_definition
FROM etl_load_audit
ORDER BY CASE WHEN target_table LIKE 'fact%' THEN 2 ELSE 1 END, target_table;

-- @report: Grain check — fact_player_season (expect 0 rows)
SELECT player_key, season_key, stint, COUNT(*) AS n
FROM fact_player_season
GROUP BY player_key, season_key, stint
HAVING COUNT(*) > 1;

-- @report: Grain check — fact_plate_appearance (expect 0 rows)
SELECT game_id, play_num, COUNT(*) AS n
FROM fact_plate_appearance
GROUP BY game_id, play_num
HAVING COUNT(*) > 1;

-- @report: Orphan check — fact_player_season.player_key -> dim_player
SELECT COUNT(*) AS orphan_rows FROM fact_player_season AS f
LEFT JOIN dim_player AS d ON f.player_key = d.player_key WHERE d.player_key IS NULL;

-- @report: Orphan check — fact_player_season.season_key -> dim_season
SELECT COUNT(*) AS orphan_rows FROM fact_player_season AS f
LEFT JOIN dim_season AS d ON f.season_key = d.season_key WHERE d.season_key IS NULL;

-- @report: Orphan check — fact_player_season.team_key -> dim_team
SELECT COUNT(*) AS orphan_rows FROM fact_player_season AS f
LEFT JOIN dim_team AS d ON f.team_key = d.team_key WHERE d.team_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.date_key -> dim_date
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_date AS d ON f.date_key = d.date_key WHERE d.date_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.batter_key -> dim_player
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_player AS d ON f.batter_key = d.player_key WHERE d.player_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.pitcher_key -> dim_player
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_player AS d ON f.pitcher_key = d.player_key WHERE d.player_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.bat_team_key -> dim_team
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_team AS d ON f.bat_team_key = d.team_key WHERE d.team_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.fld_team_key -> dim_team
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_team AS d ON f.fld_team_key = d.team_key WHERE d.team_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.park_key -> dim_park
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_park AS d ON f.park_key = d.park_key WHERE d.park_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.outcome_key -> dim_outcome
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_outcome AS d ON f.outcome_key = d.outcome_key WHERE d.outcome_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.game_type_key -> dim_game_type
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_game_type AS d ON f.game_type_key = d.game_type_key WHERE d.game_type_key IS NULL;

-- @report: Orphan check — fact_plate_appearance.matchup_key -> dim_matchup
SELECT COUNT(*) AS orphan_rows FROM fact_plate_appearance AS f
LEFT JOIN dim_matchup AS d ON f.matchup_key = d.matchup_key WHERE d.matchup_key IS NULL;

-- @report: Orphan check — fact_reconciliation.player_key -> dim_player
SELECT COUNT(*) AS orphan_rows FROM fact_reconciliation AS f
LEFT JOIN dim_player AS d ON f.player_key = d.player_key WHERE d.player_key IS NULL;

-- @report: Orphan check — fact_reconciliation.season_key -> dim_season
SELECT COUNT(*) AS orphan_rows FROM fact_reconciliation AS f
LEFT JOIN dim_season AS d ON f.season_key = d.season_key WHERE d.season_key IS NULL;

-- @report: Orphan check — agg_pa_season_park.season_key -> dim_season
SELECT COUNT(*) AS orphan_rows FROM agg_pa_season_park AS f
LEFT JOIN dim_season AS d ON f.season_key = d.season_key WHERE d.season_key IS NULL;

-- @report: Orphan check — agg_pa_season_park.park_key -> dim_park
SELECT COUNT(*) AS orphan_rows FROM agg_pa_season_park AS f
LEFT JOIN dim_park AS d ON f.park_key = d.park_key WHERE d.park_key IS NULL;

-- @report: Orphan check — agg_pa_season_park.game_type_key -> dim_game_type
SELECT COUNT(*) AS orphan_rows FROM agg_pa_season_park AS f
LEFT JOIN dim_game_type AS d ON f.game_type_key = d.game_type_key WHERE d.game_type_key IS NULL;

-- @report: Rejected rows by table and reason
SELECT target_table, reason_code, COUNT(*) AS rejected_rows
FROM etl_reject
GROUP BY target_table, reason_code
ORDER BY target_table, reason_code;

-- @report: Data-quality summary
SELECT metric, value, description FROM etl_dq_summary ORDER BY metric;

-- Work tables are no longer needed (staging tables are kept for lineage)
DROP TABLE IF EXISTS wrk_batting_valid;
DROP TABLE IF EXISTS wrk_plays_valid;
DROP TABLE IF EXISTS wrk_player_retro;
DROP TABLE IF EXISTS wrk_team_retro_lookup;
DROP TABLE IF EXISTS wrk_team_lookup;
DROP TABLE IF EXISTS wrk_team_version;
DROP TABLE IF EXISTS wrk_team_season;
DROP TABLE IF EXISTS wrk_franchise_season;
DROP TABLE IF EXISTS wrk_season_recorded;
DROP TABLE IF EXISTS wrk_season_league_recorded;
DROP TABLE IF EXISTS wrk_recon_lahman;
DROP TABLE IF EXISTS wrk_recon_retro;
DROP TABLE IF EXISTS wrk_recon_lahman_check;
DROP TABLE IF EXISTS wrk_recon_seasons;

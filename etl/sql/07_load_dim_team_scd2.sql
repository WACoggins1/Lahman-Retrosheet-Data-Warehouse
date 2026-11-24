-- =============================================================================
-- Step 07 — dim_team, SCD Type 2 (Lahman Teams)
-- Natural key: franchise_id (Lahman franchID) alone. Tracked (Type 2)
-- attributes: team name, league, division, Lahman team code, Retrosheet team
-- code. Consecutive franchise-seasons with the same tracked values form one
-- version ("gaps and islands"); (franchise_id, effective_date) is unique.
--
-- Franchise-seasons with two team rows: Lahman 1871-2025 includes Negro League
-- franchises that changed city or league during a season (e.g. the Crawfords,
-- PC, in 1939). Lahman gives no mid-season date, so one season cannot be split
-- into two versions. The franchise-season takes its tracked attributes from
-- the team row with the most games (ties: team code order); both team rows map
-- to that version, and the count is reported as franchise_seasons_multi_team.
-- =============================================================================
USE baseball_dw;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'dim_team', source_file, source_row, CONCAT_WS('|', yearID, teamID, franchID),
       'MISSING_NATURAL_KEY', 'Teams row lacks yearID, teamID, franchID, or lgID'
FROM stg_lahman_teams
WHERE yearID IS NULL OR NOT (yearID REGEXP '^[0-9]{4}$') OR teamID IS NULL OR franchID IS NULL OR lgID IS NULL
ORDER BY source_file, source_row;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'dim_team', source_file, source_row, CONCAT_WS('|', yearID, teamID), 'DUPLICATE_NATURAL_KEY',
       'Repeated (yearID, teamID); first occurrence kept'
FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY yearID, teamID ORDER BY source_file, source_row) AS rn
      FROM stg_lahman_teams t
      WHERE yearID REGEXP '^[0-9]{4}$' AND teamID IS NOT NULL AND franchID IS NOT NULL AND lgID IS NOT NULL) d
WHERE rn > 1
ORDER BY source_file, source_row;

-- One row per team-season (the grain of Teams.csv)
DROP TABLE IF EXISTS wrk_team_season;
CREATE TABLE wrk_team_season (
  yr                SMALLINT     NOT NULL,
  team_code_lahman  VARCHAR(4)   NOT NULL,
  franchise_id      VARCHAR(4)   NOT NULL,
  team_code_retro   VARCHAR(4)   NOT NULL,
  team_name         VARCHAR(60)  NOT NULL,
  league_code       VARCHAR(3)   NOT NULL,
  div_code          VARCHAR(2)   NULL,
  games             INT          NULL,
  PRIMARY KEY (yr, team_code_lahman)
) ENGINE=InnoDB;
INSERT INTO wrk_team_season (yr, team_code_lahman, franchise_id, team_code_retro, team_name, league_code,
                             div_code, games)
SELECT CAST(yearID AS UNSIGNED), teamID, franchID, COALESCE(teamIDretro, teamID),
       LEFT(COALESCE(name, teamID), 60), lgID, divID,
       CASE WHEN G REGEXP '^[0-9]+$' THEN CAST(G AS SIGNED) END
FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY yearID, teamID ORDER BY source_file, source_row) AS rn
      FROM stg_lahman_teams t
      WHERE yearID REGEXP '^[0-9]{4}$' AND teamID IS NOT NULL AND franchID IS NOT NULL AND lgID IS NOT NULL) d
WHERE rn = 1
ORDER BY yearID, teamID;

-- One row per franchise-season: the primary team row supplies the attributes
DROP TABLE IF EXISTS wrk_franchise_season;
CREATE TABLE wrk_franchise_season (
  franchise_id      VARCHAR(4)   NOT NULL,
  yr                SMALLINT     NOT NULL,
  team_code_lahman  VARCHAR(4)   NOT NULL,
  team_code_retro   VARCHAR(4)   NOT NULL,
  team_name         VARCHAR(60)  NOT NULL,
  league_code       VARCHAR(3)   NOT NULL,
  div_code          VARCHAR(2)   NULL,
  n_teams           INT          NOT NULL,
  PRIMARY KEY (franchise_id, yr)
) ENGINE=InnoDB;
INSERT INTO wrk_franchise_season (franchise_id, yr, team_code_lahman, team_code_retro, team_name,
                                  league_code, div_code, n_teams)
SELECT franchise_id, yr, team_code_lahman, team_code_retro, team_name, league_code, div_code, n_teams
FROM (SELECT w.*,
             ROW_NUMBER() OVER (PARTITION BY franchise_id, yr ORDER BY games DESC, team_code_lahman) AS rn,
             COUNT(*)     OVER (PARTITION BY franchise_id, yr) AS n_teams
      FROM wrk_team_season w) x
WHERE rn = 1
ORDER BY franchise_id, yr;

-- Versions: islands of consecutive franchise-seasons with identical tracked attributes
DROP TABLE IF EXISTS wrk_team_version;
CREATE TABLE wrk_team_version (
  franchise_id      VARCHAR(4)   NOT NULL,
  ver               INT          NOT NULL,
  start_yr          SMALLINT     NOT NULL,
  end_yr            SMALLINT     NOT NULL,
  team_name         VARCHAR(60)  NOT NULL,
  league_code       VARCHAR(3)   NOT NULL,
  div_code          VARCHAR(2)   NULL,
  team_code_retro   VARCHAR(4)   NOT NULL,
  team_code_lahman  VARCHAR(4)   NOT NULL,
  seasons           INT          NOT NULL,
  PRIMARY KEY (franchise_id, ver)
) ENGINE=InnoDB;
INSERT INTO wrk_team_version (franchise_id, ver, start_yr, end_yr, team_name, league_code, div_code,
                              team_code_retro, team_code_lahman, seasons)
WITH a AS (
  SELECT f.*, CONCAT_WS('|', team_name, league_code, COALESCE(div_code, '-'), team_code_retro, team_code_lahman) AS attr
  FROM wrk_franchise_season f
), c AS (
  SELECT a.*, CASE WHEN LAG(attr) OVER (PARTITION BY franchise_id ORDER BY yr) <=> attr THEN 0 ELSE 1 END AS chg
  FROM a
), v AS (
  SELECT c.*, SUM(chg) OVER (PARTITION BY franchise_id ORDER BY yr
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ver
  FROM c
)
SELECT franchise_id, ver, MIN(yr), MAX(yr), team_name, league_code, div_code, team_code_retro, team_code_lahman, COUNT(*)
FROM v
GROUP BY franchise_id, ver, team_name, league_code, div_code, team_code_retro, team_code_lahman
ORDER BY franchise_id, ver;

INSERT INTO dim_team (franchise_id, team_code_lahman, team_code_retro, team_name, division_name,
                      league_code, league_name, effective_date, end_date, is_current, version_num)
SELECT v.franchise_id, v.team_code_lahman, v.team_code_retro, v.team_name,
       CASE v.div_code WHEN 'E' THEN CONCAT(v.league_code, ' East')
                       WHEN 'C' THEN CONCAT(v.league_code, ' Central')
                       WHEN 'W' THEN CONCAT(v.league_code, ' West')
                       ELSE CONCAT(v.league_code, ' (no divisions)') END,
       v.league_code,
       CASE v.league_code WHEN 'AL' THEN 'American League' WHEN 'NL' THEN 'National League'
                          WHEN 'AA' THEN 'American Association' WHEN 'UA' THEN 'Union Association'
                          WHEN 'PL' THEN 'Players League' WHEN 'FL' THEN 'Federal League'
                          WHEN 'NA' THEN 'National Association' ELSE v.league_code END,
       MAKEDATE(v.start_yr, 1),
       CASE WHEN v.ver = m.max_ver AND m.last_yr = g.max_yr THEN DATE('9999-12-31')
            ELSE DATE(CONCAT(v.end_yr, '-12-31')) END,
       IF(v.ver = m.max_ver, 1, 0),
       v.ver
FROM wrk_team_version v
JOIN (SELECT franchise_id, MAX(ver) AS max_ver, MAX(end_yr) AS last_yr
      FROM wrk_team_version GROUP BY franchise_id) m ON m.franchise_id = v.franchise_id
CROSS JOIN (SELECT MAX(yr) AS max_yr FROM wrk_team_season) g
ORDER BY v.franchise_id, v.start_yr;

-- Surrogate-key lookups used by both fact loads: every team-season (including a
-- franchise's second team row in a season) maps to the franchise's version for
-- that season. Versions of one franchise never overlap, so the match is unique.
DROP TABLE IF EXISTS wrk_team_lookup;
CREATE TABLE wrk_team_lookup (
  yr                SMALLINT    NOT NULL,
  team_code_lahman  VARCHAR(4)  NOT NULL,
  team_code_retro   VARCHAR(4)  NOT NULL,
  team_key          INT         NOT NULL,
  PRIMARY KEY (yr, team_code_lahman)
) ENGINE=InnoDB;
INSERT INTO wrk_team_lookup (yr, team_code_lahman, team_code_retro, team_key)
SELECT w.yr, w.team_code_lahman, w.team_code_retro, d.team_key
FROM wrk_team_season w
JOIN dim_team d ON d.franchise_id = w.franchise_id
               AND w.yr BETWEEN YEAR(d.effective_date) AND YEAR(d.end_date)
ORDER BY w.yr, w.team_code_lahman;

DROP TABLE IF EXISTS wrk_team_retro_lookup;
CREATE TABLE wrk_team_retro_lookup (
  yr               SMALLINT    NOT NULL,
  team_code_retro  VARCHAR(4)  NOT NULL,
  team_key         INT         NOT NULL,
  n_rows           INT         NOT NULL,
  PRIMARY KEY (yr, team_code_retro)
) ENGINE=InnoDB;
INSERT INTO wrk_team_retro_lookup (yr, team_code_retro, team_key, n_rows)
SELECT yr, team_code_retro, MIN(team_key), COUNT(*)
FROM wrk_team_lookup
GROUP BY yr, team_code_retro
ORDER BY yr, team_code_retro;

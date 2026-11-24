-- =============================================================================
-- Step 09 — fact_player_season (Lahman Batting)
-- Grain: one row per player, per season, per stint.
-- Plate appearances (derived, era-aware):
--   PA = AB + BB + HBP + SH + SF, where a component that was not a recorded
--   category in that season and league (blank in more than half of the
--   league-season's rows, e.g. SF before 1954) adds 0. If a component is blank
--   on this row but recorded for its league that season, PA stays NULL.
--   Source columns are never coerced: a blank SF stays NULL in sac_flies.
-- =============================================================================
USE baseball_dw;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'fact_player_season', source_file, source_row, CONCAT_WS('|', playerID, yearID, stint),
       'MISSING_GRAIN_KEY', 'playerID, yearID, or stint blank or non-numeric'
FROM stg_lahman_batting
WHERE playerID IS NULL OR yearID IS NULL OR NOT (yearID REGEXP '^[0-9]{4}$')
   OR stint IS NULL OR NOT (stint REGEXP '^[0-9]+$')
ORDER BY source_file, source_row;

DROP TABLE IF EXISTS wrk_batting_valid;
CREATE TABLE wrk_batting_valid (
  source_file VARCHAR(255) NOT NULL, source_row INT NOT NULL,
  playerID VARCHAR(20) NOT NULL, yr SMALLINT NOT NULL, stint TINYINT UNSIGNED NOT NULL, teamID VARCHAR(5) NULL,
  rn INT NOT NULL,
  PRIMARY KEY (source_file, source_row),
  KEY ix_wbv_grain (playerID, yr, stint)
) ENGINE=InnoDB;
INSERT INTO wrk_batting_valid (source_file, source_row, playerID, yr, stint, teamID, rn)
SELECT source_file, source_row, playerID, CAST(yearID AS UNSIGNED), CAST(stint AS UNSIGNED), teamID,
       ROW_NUMBER() OVER (PARTITION BY playerID, CAST(yearID AS UNSIGNED), CAST(stint AS UNSIGNED)
                          ORDER BY source_file, source_row)
FROM stg_lahman_batting
WHERE playerID IS NOT NULL AND yearID REGEXP '^[0-9]{4}$' AND stint REGEXP '^[0-9]+$'
ORDER BY source_file, source_row;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'fact_player_season', source_file, source_row, CONCAT_WS('|', playerID, yr, stint),
       'DUPLICATE_GRAIN', 'Repeated (playerID, yearID, stint); first occurrence kept'
FROM wrk_batting_valid
WHERE rn > 1
ORDER BY source_file, source_row;

-- A row whose player is not in dim_player cannot be placed at the grain
-- (two such rows would collide on the Unknown member), so it is rejected.
INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'fact_player_season', w.source_file, w.source_row, CONCAT_WS('|', w.playerID, w.yr, w.stint),
       'PLAYER_NOT_IN_DIMENSION', 'Batting.playerID has no People row'
FROM wrk_batting_valid w
LEFT JOIN dim_player p ON p.lahman_player_id = w.playerID
WHERE w.rn = 1 AND p.player_key IS NULL
ORDER BY w.source_file, w.source_row;

INSERT INTO fact_player_season (player_key, season_key, team_key, stint, games, at_bats, runs, hits,
                                doubles, triples, home_runs, rbi, stolen_bases, caught_stealing, walks,
                                strikeouts, intentional_walks, hit_by_pitch, sac_hits, sac_flies, gidp,
                                plate_appearances)
SELECT p.player_key, COALESCE(s.season_key, -1), COALESCE(t.team_key, -1), w.stint,
       x.g, x.ab, x.r, x.h, x.b2, x.b3, x.hr, x.rbi, x.sb, x.cs, x.bb, x.so, x.ibb, x.hbp, x.sh, x.sf, x.gidp,
       CASE WHEN x.ab IS NULL OR x.bb IS NULL THEN NULL
            WHEN (x.hbp IS NULL AND COALESCE(r.hbp_rec, 0) = 1)
              OR (x.sh  IS NULL AND COALESCE(r.sh_rec,  0) = 1)
              OR (x.sf  IS NULL AND COALESCE(r.sf_rec,  0) = 1) THEN NULL
            ELSE x.ab + x.bb + COALESCE(x.hbp, 0) + COALESCE(x.sh, 0) + COALESCE(x.sf, 0) END
FROM wrk_batting_valid w
JOIN stg_lahman_batting b ON b.source_file = w.source_file AND b.source_row = w.source_row
JOIN dim_player p ON p.lahman_player_id = w.playerID
LEFT JOIN dim_season s ON s.season_year = w.yr
LEFT JOIN wrk_team_lookup t ON t.yr = w.yr AND t.team_code_lahman = w.teamID
LEFT JOIN wrk_season_league_recorded r ON r.yr = w.yr AND r.lg = COALESCE(b.lgID, '?')
CROSS JOIN LATERAL (
  SELECT CASE WHEN b.G    REGEXP '^[0-9]+$' THEN CAST(b.G    AS SIGNED) END AS g,
         CASE WHEN b.AB   REGEXP '^[0-9]+$' THEN CAST(b.AB   AS SIGNED) END AS ab,
         CASE WHEN b.R    REGEXP '^[0-9]+$' THEN CAST(b.R    AS SIGNED) END AS r,
         CASE WHEN b.H    REGEXP '^[0-9]+$' THEN CAST(b.H    AS SIGNED) END AS h,
         CASE WHEN b.X2B  REGEXP '^[0-9]+$' THEN CAST(b.X2B  AS SIGNED) END AS b2,
         CASE WHEN b.X3B  REGEXP '^[0-9]+$' THEN CAST(b.X3B  AS SIGNED) END AS b3,
         CASE WHEN b.HR   REGEXP '^[0-9]+$' THEN CAST(b.HR   AS SIGNED) END AS hr,
         CASE WHEN b.RBI  REGEXP '^[0-9]+$' THEN CAST(b.RBI  AS SIGNED) END AS rbi,
         CASE WHEN b.SB   REGEXP '^[0-9]+$' THEN CAST(b.SB   AS SIGNED) END AS sb,
         CASE WHEN b.CS   REGEXP '^[0-9]+$' THEN CAST(b.CS   AS SIGNED) END AS cs,
         CASE WHEN b.BB   REGEXP '^[0-9]+$' THEN CAST(b.BB   AS SIGNED) END AS bb,
         CASE WHEN b.SO   REGEXP '^[0-9]+$' THEN CAST(b.SO   AS SIGNED) END AS so,
         CASE WHEN b.IBB  REGEXP '^[0-9]+$' THEN CAST(b.IBB  AS SIGNED) END AS ibb,
         CASE WHEN b.HBP  REGEXP '^[0-9]+$' THEN CAST(b.HBP  AS SIGNED) END AS hbp,
         CASE WHEN b.SH   REGEXP '^[0-9]+$' THEN CAST(b.SH   AS SIGNED) END AS sh,
         CASE WHEN b.SF   REGEXP '^[0-9]+$' THEN CAST(b.SF   AS SIGNED) END AS sf,
         CASE WHEN b.GIDP REGEXP '^[0-9]+$' THEN CAST(b.GIDP AS SIGNED) END AS gidp
) x
WHERE w.rn = 1
ORDER BY w.playerID, w.yr, w.stint;

-- =============================================================================
-- Step 10 — fact_plate_appearance (Retrosheet plays)
-- Grain: one row per plate appearance, identified by (game_id, play_num).
-- Rows that are not plate appearances (pa = 0: stolen bases, wild pitches,
-- pickoffs ...) are outside the grain and go to etl_reject as NOT_PLATE_APPEARANCE.
-- =============================================================================
USE baseball_dw;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'fact_plate_appearance', source_file, source_row, LEFT(CONCAT_WS('#', gid, pn), 100),
       'NOT_PLATE_APPEARANCE', LEFT(CONCAT('pa=', COALESCE(pa, 'blank'), ' event=', COALESCE(event, '')), 255)
FROM stg_retro_plays
WHERE COALESCE(pa, '') <> '1'
ORDER BY source_file, source_row;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'fact_plate_appearance', source_file, source_row, LEFT(CONCAT_WS('#', gid, pn), 100),
       'MISSING_GRAIN_KEY', 'gid or pn blank or non-numeric'
FROM stg_retro_plays
WHERE pa = '1' AND (gid IS NULL OR pn IS NULL OR NOT (pn REGEXP '^[0-9]+$'))
ORDER BY source_file, source_row;

-- Typed, validated plate appearances (one row per grain; duplicates flagged by rn)
DROP TABLE IF EXISTS wrk_plays_valid;
CREATE TABLE wrk_plays_valid (
  source_file   VARCHAR(255) NOT NULL,
  source_row    INT          NOT NULL,
  gid           VARCHAR(16)  NOT NULL,
  pn_num        SMALLINT     NOT NULL,
  rn            INT          NOT NULL,
  game_dt       DATE         NULL,
  season        SMALLINT     NULL,
  batter        VARCHAR(12)  NULL,
  pitcher       VARCHAR(12)  NULL,
  batteam       VARCHAR(5)   NULL,
  pitteam       VARCHAR(5)   NULL,
  site          VARCHAR(10)  NULL,
  gametype      VARCHAR(20)  NULL,
  bat_hand      CHAR(1)      NOT NULL,
  pit_hand      CHAR(1)      NOT NULL,
  outcome_code  VARCHAR(4)   NULL,
  f_ab TINYINT NOT NULL, f_single TINYINT NOT NULL, f_double TINYINT NOT NULL, f_triple TINYINT NOT NULL,
  f_hr TINYINT NOT NULL, f_walk TINYINT NOT NULL, f_iw TINYINT NOT NULL, f_hbp TINYINT NOT NULL,
  f_k TINYINT NOT NULL, f_sf TINYINT NOT NULL, f_sh TINYINT NOT NULL, f_bip TINYINT NOT NULL,
  n_rbi TINYINT NOT NULL, n_runs TINYINT NOT NULL,
  PRIMARY KEY (source_file, source_row),
  KEY ix_wpv_grain (gid, pn_num)
) ENGINE=InnoDB;

INSERT INTO wrk_plays_valid
SELECT x.source_file, x.source_row, x.gid, x.pn_num,
       ROW_NUMBER() OVER (PARTITION BY x.gid, x.pn_num ORDER BY x.source_file, x.source_row),
       x.game_dt,
       COALESCE(YEAR(x.game_dt), CASE WHEN SUBSTRING(x.gid, 4, 4) REGEXP '^[0-9]{4}$'
                                      THEN CAST(SUBSTRING(x.gid, 4, 4) AS UNSIGNED) END),
       x.batter, x.pitcher, x.batteam, x.pitteam, x.site, x.gametype,
       CASE WHEN UPPER(x.bathand) IN ('L','R','B') THEN UPPER(x.bathand) ELSE '?' END,
       CASE WHEN UPPER(x.pithand) IN ('L','R')     THEN UPPER(x.pithand) ELSE '?' END,
       -- Outcome derivation: first matching flag wins (documented precedence)
       CASE WHEN x.hr = 1 THEN 'HR' WHEN x.tr = 1 THEN '3B' WHEN x.db = 1 THEN '2B' WHEN x.si = 1 THEN '1B'
            WHEN x.iw = 1 THEN 'IBB' WHEN x.wk = 1 THEN 'BB' WHEN x.hbp = 1 THEN 'HBP'
            WHEN x.k = 1 AND x.ks = 1 THEN 'KS' WHEN x.k = 1 THEN 'K'
            WHEN x.sf = 1 THEN 'SF' WHEN x.sh = 1 THEN 'SH' WHEN x.xi = 1 THEN 'XI'
            WHEN x.roe = 1 THEN 'ROE' WHEN x.fc = 1 THEN 'FC'
            WHEN x.oo = 1 THEN 'OUT' WHEN x.nout = 1 THEN 'OTH' END,
       x.ab, x.si, x.db, x.tr, x.hr, x.wk, x.iw, x.hbp, x.k, x.sf, x.sh, x.bip, x.rbi, x.runs
FROM (
  SELECT s.source_file, s.source_row, s.gid, CAST(s.pn AS UNSIGNED) AS pn_num,
         CASE WHEN s.game_date REGEXP '^[0-9]{8}$' THEN STR_TO_DATE(s.game_date, '%Y%m%d')
              WHEN s.game_date REGEXP '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$' THEN STR_TO_DATE(s.game_date, '%Y-%c-%e')
              WHEN s.game_date REGEXP '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$' THEN STR_TO_DATE(s.game_date, '%Y/%c/%e')
              WHEN s.game_date REGEXP '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN STR_TO_DATE(s.game_date, '%c/%e/%Y')
              WHEN SUBSTRING(s.gid, 4, 8) REGEXP '^[0-9]{8}$' THEN STR_TO_DATE(SUBSTRING(s.gid, 4, 8), '%Y%m%d')
         END AS game_dt,
         s.batter, s.pitcher, s.batteam, s.pitteam, s.site, s.gametype, s.bathand, s.pithand,
         IF(s.ab = '1', 1, 0) AS ab, IF(s.single = '1', 1, 0) AS si, IF(s.dbl = '1', 1, 0) AS db,
         IF(s.triple = '1', 1, 0) AS tr, IF(s.hr = '1', 1, 0) AS hr, IF(s.walk = '1', 1, 0) AS wk,
         IF(s.iw = '1', 1, 0) AS iw, IF(s.hbp = '1', 1, 0) AS hbp, IF(s.k = '1', 1, 0) AS k,
         IF(s.k_safe = '1', 1, 0) AS ks, IF(s.sf = '1', 1, 0) AS sf, IF(s.sh = '1', 1, 0) AS sh,
         IF(s.xi = '1', 1, 0) AS xi, IF(s.roe = '1', 1, 0) AS roe, IF(s.fc = '1', 1, 0) AS fc,
         IF(s.othout = '1', 1, 0) AS oo, IF(s.noout = '1', 1, 0) AS nout, IF(s.bip = '1', 1, 0) AS bip,
         CASE WHEN s.rbi  REGEXP '^[0-9]$' THEN CAST(s.rbi  AS UNSIGNED) ELSE 0 END AS rbi,
         CASE WHEN s.runs REGEXP '^[0-9]$' THEN CAST(s.runs AS UNSIGNED) ELSE 0 END AS runs
  FROM stg_retro_plays s
  WHERE s.pa = '1' AND s.gid IS NOT NULL AND s.pn REGEXP '^[0-9]+$'
) x
ORDER BY x.source_file, x.source_row;

INSERT INTO etl_reject (target_table, source_file, source_row, natural_key, reason_code, detail)
SELECT 'fact_plate_appearance', source_file, source_row, CONCAT(gid, '#', pn_num), 'DUPLICATE_GRAIN',
       'Repeated (gid, pn); first occurrence kept'
FROM wrk_plays_valid
WHERE rn > 1
ORDER BY source_file, source_row;

INSERT INTO fact_plate_appearance (game_id, play_num, date_key, batter_key, pitcher_key, bat_team_key,
       fld_team_key, park_key, outcome_key, game_type_key, matchup_key, pa_count, at_bat, hit,
       single_hit, double_hit, triple_hit, home_run, total_bases, walk, intentional_walk, hit_by_pitch,
       strikeout, sac_fly, sac_hit, batted_ball, rbi, runs_scored)
SELECT p.gid, p.pn_num,
       COALESCE(dd.date_key, -1), COALESCE(bp.player_key, -1), COALESCE(pp.player_key, -1),
       COALESCE(bt.team_key, -1), COALESCE(ft.team_key, -1), COALESCE(pk.park_key, -1),
       COALESCE(o.outcome_key, -1), COALESCE(gt.game_type_key, -1), COALESCE(m.matchup_key, -1),
       1, p.f_ab, p.f_single + p.f_double + p.f_triple + p.f_hr,
       p.f_single, p.f_double, p.f_triple, p.f_hr,
       p.f_single + 2 * p.f_double + 3 * p.f_triple + 4 * p.f_hr,
       p.f_walk, p.f_iw, p.f_hbp, p.f_k, p.f_sf, p.f_sh, GREATEST(p.f_bip, p.f_hr), p.n_rbi, p.n_runs
FROM wrk_plays_valid p
LEFT JOIN dim_date dd              ON dd.full_date = p.game_dt
LEFT JOIN wrk_player_retro bp      ON bp.retro_id = p.batter
LEFT JOIN wrk_player_retro pp      ON pp.retro_id = p.pitcher
LEFT JOIN wrk_team_retro_lookup bt ON bt.yr = p.season AND bt.team_code_retro = p.batteam
LEFT JOIN wrk_team_retro_lookup ft ON ft.yr = p.season AND ft.team_code_retro = p.pitteam
LEFT JOIN dim_park pk              ON pk.park_code = p.site
LEFT JOIN dim_outcome o            ON o.outcome_code = p.outcome_code
LEFT JOIN dim_game_type gt         ON gt.game_type_code = p.gametype
LEFT JOIN dim_matchup m            ON m.bat_hand = p.bat_hand AND m.pit_hand = p.pit_hand
WHERE p.rn = 1
ORDER BY p.gid, p.pn_num;

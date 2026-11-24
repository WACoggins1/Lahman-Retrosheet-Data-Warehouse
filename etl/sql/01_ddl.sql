-- =============================================================================
-- Team 5 — Final project — Warehouse DDL (MySQL 8)
-- Reconciling a Century of Baseball: Lahman + Retrosheet fact constellation
--
-- Runs on an empty MySQL 8 server: creates database baseball_dw, then every
-- dimension and fact table with primary keys, foreign keys, and indexes.
-- Safe to rerun: drops the warehouse tables first.
--
-- Conventions
--   * Every dimension has an INT surrogate key generated in the warehouse
--     (AUTO_INCREMENT) and keeps its natural key as a UNIQUE attribute.
--   * Surrogate key -1 is the reserved "Unknown" member in every dimension;
--     facts never carry NULL foreign keys.
--   * Two fact tables (constellation) share the conformed dimensions
--     dim_player and dim_team; dim_season is the conformed season-level
--     roll-up of dim_date (same season and era attributes and values).
-- =============================================================================

CREATE DATABASE IF NOT EXISTS baseball_dw
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE baseball_dw;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS agg_pa_season_park;
DROP TABLE IF EXISTS fact_reconciliation;
DROP TABLE IF EXISTS etl_source_audit;
DROP TABLE IF EXISTS fact_plate_appearance;
DROP TABLE IF EXISTS fact_player_season;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_season;
DROP TABLE IF EXISTS dim_player;
DROP TABLE IF EXISTS dim_team;
DROP TABLE IF EXISTS dim_park;
DROP TABLE IF EXISTS dim_outcome;
DROP TABLE IF EXISTS dim_game_type;
DROP TABLE IF EXISTS dim_matchup;
DROP TABLE IF EXISTS etl_reject;
DROP TABLE IF EXISTS etl_load_audit;
SET FOREIGN_KEY_CHECKS = 1;

-- -----------------------------------------------------------------------------
-- dim_date — day grain, generated from a calendar range (1871-01-01 .. 2025-12-31)
-- Hierarchy (4 levels): Day -> Year-month -> Season -> Era
-- The Month level is year_month_label ('2023-04'), which belongs to exactly one
-- season. month_name / month_num ('April') are descriptive attributes only:
-- April alone recurs every year, so it cannot roll up to a single season.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_date (
  date_key          INT          NOT NULL AUTO_INCREMENT,
  full_date         DATE         NULL,          -- natural key (NULL only on Unknown row)
  day_of_month      TINYINT      NULL,
  day_name          VARCHAR(9)   NOT NULL,
  month_num         TINYINT      NULL,
  month_name        VARCHAR(9)   NOT NULL,
  year_month_label  CHAR(7)      NOT NULL,      -- Year-month level, e.g. '2023-04'
  season_year       SMALLINT     NULL,          -- Season level
  era_name          VARCHAR(40)  NOT NULL,      -- Era level
  era_start_year    SMALLINT     NULL,
  era_end_year      SMALLINT     NULL,
  PRIMARY KEY (date_key),
  UNIQUE KEY uk_dim_date_full_date (full_date),
  KEY ix_dim_date_season (season_year),
  KEY ix_dim_date_era (era_name)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_season — conformed season-level roll-up of dim_date (shrunken dimension)
-- Hierarchy (2 levels): Season -> Era
-- -----------------------------------------------------------------------------
CREATE TABLE dim_season (
  season_key        INT          NOT NULL AUTO_INCREMENT,
  season_year       SMALLINT     NULL,          -- natural key
  era_name          VARCHAR(40)  NOT NULL,
  era_start_year    SMALLINT     NULL,
  era_end_year      SMALLINT     NULL,
  pa_definition     VARCHAR(40)  NOT NULL,      -- which PA components were recorded that season
  PRIMARY KEY (season_key),
  UNIQUE KEY uk_dim_season_year (season_year),
  KEY ix_dim_season_era (era_name)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_player — conformed; role-played as batter and pitcher. SCD Type 1.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_player (
  player_key        INT          NOT NULL AUTO_INCREMENT,
  lahman_player_id  VARCHAR(12)  NULL,          -- natural key (Lahman playerID)
  retro_id          VARCHAR(12)  NULL,          -- Retrosheet ID (bridge to plays)
  bbref_id          VARCHAR(12)  NULL,
  first_name        VARCHAR(60)  NOT NULL,
  last_name         VARCHAR(60)  NOT NULL,
  full_name         VARCHAR(130) NOT NULL,
  bats              CHAR(1)      NOT NULL,      -- L, R, B, or ? (unknown)
  throws            CHAR(1)      NOT NULL,      -- L, R, or ?
  birth_year        SMALLINT     NULL,
  birth_country     VARCHAR(40)  NULL,
  debut_date        DATE         NULL,
  final_game_date   DATE         NULL,
  PRIMARY KEY (player_key),
  UNIQUE KEY uk_dim_player_lahman_id (lahman_player_id),
  KEY ix_dim_player_retro_id (retro_id)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_team — conformed; SCD Type 2 on franchise identity.
-- Natural key: franchise_id alone (it never changes). The team codes are Type 2
-- attributes, not part of the key. A new version is added whenever team name,
-- league, division, or team codes change; (franchise_id, effective_date)
-- identifies one version, and is_current / version_num describe it.
-- Hierarchy (3 levels): Team -> Division -> League
-- -----------------------------------------------------------------------------
CREATE TABLE dim_team (
  team_key          INT          NOT NULL AUTO_INCREMENT,  -- surrogate key, one per version
  franchise_id      VARCHAR(4)   NULL,          -- natural (business) key: Lahman franchID, alone
  team_code_lahman  VARCHAR(4)   NOT NULL,      -- Type 2 attribute (changes, e.g. ANA -> LAA)
  team_code_retro   VARCHAR(4)   NOT NULL,      -- Type 2 attribute
  team_name         VARCHAR(60)  NOT NULL,      -- Type 2 attribute (Team level)
  division_name     VARCHAR(30)  NOT NULL,      -- Type 2 attribute (Division level), e.g. 'AL West'
  league_code       VARCHAR(3)   NOT NULL,      -- Type 2 attribute (League level)
  league_name       VARCHAR(30)  NOT NULL,
  effective_date    DATE         NOT NULL,      -- SCD2: first day this version applies
  end_date          DATE         NOT NULL,      -- SCD2: last day ('9999-12-31' if open)
  is_current        TINYINT      NOT NULL,      -- SCD2: 1 = latest version of the franchise
  version_num       SMALLINT     NOT NULL,      -- SCD2: 1, 2, 3 ... within the franchise
  PRIMARY KEY (team_key),
  UNIQUE KEY uk_dim_team_version (franchise_id, effective_date),   -- one row per version
  KEY ix_dim_team_range (franchise_id, effective_date, end_date),
  KEY ix_dim_team_league_div (league_code, division_name)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_park — Retrosheet park (site) code is the natural key.
-- Hierarchy (4 levels): Park -> City -> Region -> Country
-- Region = state or province where the lookup gives one; for parks outside
-- the U.S. and Canada with no state (Tokyo, London, Sydney, Monterrey ...) the
-- region repeats the country, so every path has all four levels (labels
-- then read 'Tokyo, JP' rather than repeating the country).
-- City and Region members are made unique by their parents: city_label is
-- 'City, Region, Country' (Portland, OR is not Portland, ME).
-- -----------------------------------------------------------------------------
CREATE TABLE dim_park (
  park_key          INT          NOT NULL AUTO_INCREMENT,
  park_code         VARCHAR(8)   NULL,          -- natural key (Retrosheet site)
  park_name         VARCHAR(100) NOT NULL,
  city              VARCHAR(60)  NOT NULL,
  state             VARCHAR(40)  NOT NULL,
  country           VARCHAR(40)  NOT NULL,      -- Country level
  region            VARCHAR(40)  NOT NULL,      -- Region level: state/province, else country
  region_label      VARCHAR(90)  NOT NULL,      -- 'Region, Country' (unique Region member)
  city_label        VARCHAR(160) NOT NULL,      -- 'City, Region, Country' (unique City member)
  attribute_source  VARCHAR(60)  NOT NULL,
  PRIMARY KEY (park_key),
  UNIQUE KEY uk_dim_park_code (park_code),
  KEY ix_dim_park_city (city_label),
  KEY ix_dim_park_country (country, region_label)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_outcome — plate-appearance result.
-- Hierarchy (3 levels): Outcome -> Outcome class -> Result type
-- -----------------------------------------------------------------------------
CREATE TABLE dim_outcome (
  outcome_key       INT          NOT NULL AUTO_INCREMENT,
  outcome_code      VARCHAR(4)   NULL,          -- natural key
  outcome_name      VARCHAR(40)  NOT NULL,
  outcome_class     VARCHAR(30)  NOT NULL,
  result_type       VARCHAR(30)  NOT NULL,      -- 'On base', 'Reached, no on-base credit', 'Out'
  PRIMARY KEY (outcome_key),
  UNIQUE KEY uk_dim_outcome_code (outcome_code)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_game_type — Retrosheet gametype; resolves the 2018 tiebreaker conflict.
-- Hierarchy (2 levels): Game type -> Season phase
-- -----------------------------------------------------------------------------
CREATE TABLE dim_game_type (
  game_type_key                   INT          NOT NULL AUTO_INCREMENT,
  game_type_code                  VARCHAR(20)  NULL,  -- natural key (Retrosheet value)
  game_type_name                  VARCHAR(40)  NOT NULL,
  season_phase                    VARCHAR(20)  NOT NULL,
  counts_in_official_season_stats TINYINT      NOT NULL,
  PRIMARY KEY (game_type_key),
  UNIQUE KEY uk_dim_game_type_code (game_type_code)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- dim_matchup — junk dimension: batter hand x pitcher hand for the event
-- -----------------------------------------------------------------------------
CREATE TABLE dim_matchup (
  matchup_key       INT          NOT NULL AUTO_INCREMENT,
  bat_hand          CHAR(1)      NOT NULL,
  pit_hand          CHAR(1)      NOT NULL,
  matchup_label     VARCHAR(16)  NOT NULL,
  platoon_status    VARCHAR(40)  NOT NULL,
  PRIMARY KEY (matchup_key),
  UNIQUE KEY uk_dim_matchup_hands (bat_hand, pit_hand)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- fact_player_season — Lahman. Grain: one row per player, per season, per stint
-- (a stint is one team spell within a season, so team is determined by stint).
-- -----------------------------------------------------------------------------
CREATE TABLE fact_player_season (
  player_season_id  BIGINT       NOT NULL AUTO_INCREMENT,
  player_key        INT          NOT NULL,
  season_key        INT          NOT NULL,
  team_key          INT          NOT NULL,
  stint             TINYINT UNSIGNED NOT NULL,  -- degenerate dimension (part of grain)
  games             SMALLINT     NULL,
  at_bats           SMALLINT     NULL,
  runs              SMALLINT     NULL,
  hits              SMALLINT     NULL,
  doubles           SMALLINT     NULL,
  triples           SMALLINT     NULL,
  home_runs         SMALLINT     NULL,
  rbi               SMALLINT     NULL,
  stolen_bases      SMALLINT     NULL,
  caught_stealing   SMALLINT     NULL,
  walks             SMALLINT     NULL,
  strikeouts        SMALLINT     NULL,
  intentional_walks SMALLINT     NULL,
  hit_by_pitch      SMALLINT     NULL,
  sac_hits          SMALLINT     NULL,
  sac_flies         SMALLINT     NULL,
  gidp              SMALLINT     NULL,
  plate_appearances SMALLINT     NULL,          -- derived, era-aware (see ETL step 09)
  PRIMARY KEY (player_season_id),
  UNIQUE KEY uk_fps_grain (player_key, season_key, stint),
  KEY ix_fps_season (season_key),
  KEY ix_fps_team (team_key),
  CONSTRAINT fk_fps_player FOREIGN KEY (player_key) REFERENCES dim_player (player_key),
  CONSTRAINT fk_fps_season FOREIGN KEY (season_key) REFERENCES dim_season (season_key),
  CONSTRAINT fk_fps_team   FOREIGN KEY (team_key)   REFERENCES dim_team (team_key)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- fact_plate_appearance — Retrosheet. Grain: one row per plate appearance,
-- identified by game (game_id) and play number within the game (play_num).
-- -----------------------------------------------------------------------------
CREATE TABLE fact_plate_appearance (
  pa_id             BIGINT       NOT NULL AUTO_INCREMENT,
  game_id           VARCHAR(16)  NOT NULL,      -- degenerate dimension (Retrosheet gid)
  play_num          SMALLINT     NOT NULL,      -- degenerate dimension (Retrosheet pn)
  date_key          INT          NOT NULL,
  batter_key        INT          NOT NULL,      -- role-playing dim_player
  pitcher_key       INT          NOT NULL,      -- role-playing dim_player
  bat_team_key      INT          NOT NULL,      -- role-playing dim_team
  fld_team_key      INT          NOT NULL,      -- role-playing dim_team
  park_key          INT          NOT NULL,
  outcome_key       INT          NOT NULL,
  game_type_key     INT          NOT NULL,
  matchup_key       INT          NOT NULL,
  pa_count          TINYINT      NOT NULL,      -- always 1 (additive count)
  at_bat            TINYINT      NOT NULL,
  hit               TINYINT      NOT NULL,
  single_hit        TINYINT      NOT NULL,
  double_hit        TINYINT      NOT NULL,
  triple_hit        TINYINT      NOT NULL,
  home_run          TINYINT      NOT NULL,
  total_bases       TINYINT      NOT NULL,
  walk              TINYINT      NOT NULL,
  intentional_walk  TINYINT      NOT NULL,
  hit_by_pitch      TINYINT      NOT NULL,
  strikeout         TINYINT      NOT NULL,
  sac_fly           TINYINT      NOT NULL,
  sac_hit           TINYINT      NOT NULL,
  batted_ball       TINYINT      NOT NULL,
  rbi               TINYINT      NOT NULL,
  runs_scored       TINYINT      NOT NULL,
  PRIMARY KEY (pa_id),
  UNIQUE KEY uk_fpa_grain (game_id, play_num),
  KEY ix_fpa_date (date_key),
  KEY ix_fpa_batter (batter_key),
  KEY ix_fpa_pitcher (pitcher_key),
  KEY ix_fpa_bat_team (bat_team_key),
  KEY ix_fpa_fld_team (fld_team_key),
  KEY ix_fpa_park_date (park_key, date_key),
  KEY ix_fpa_outcome (outcome_key),
  KEY ix_fpa_game_type (game_type_key),
  KEY ix_fpa_matchup (matchup_key),
  CONSTRAINT fk_fpa_date      FOREIGN KEY (date_key)      REFERENCES dim_date (date_key),
  CONSTRAINT fk_fpa_batter    FOREIGN KEY (batter_key)    REFERENCES dim_player (player_key),
  CONSTRAINT fk_fpa_pitcher   FOREIGN KEY (pitcher_key)   REFERENCES dim_player (player_key),
  CONSTRAINT fk_fpa_bat_team  FOREIGN KEY (bat_team_key)  REFERENCES dim_team (team_key),
  CONSTRAINT fk_fpa_fld_team  FOREIGN KEY (fld_team_key)  REFERENCES dim_team (team_key),
  CONSTRAINT fk_fpa_park      FOREIGN KEY (park_key)      REFERENCES dim_park (park_key),
  CONSTRAINT fk_fpa_outcome   FOREIGN KEY (outcome_key)   REFERENCES dim_outcome (outcome_key),
  CONSTRAINT fk_fpa_game_type FOREIGN KEY (game_type_key) REFERENCES dim_game_type (game_type_key),
  CONSTRAINT fk_fpa_matchup   FOREIGN KEY (matchup_key)   REFERENCES dim_matchup (matchup_key)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- ETL control tables
-- -----------------------------------------------------------------------------
CREATE TABLE etl_reject (
  reject_id         BIGINT       NOT NULL AUTO_INCREMENT,
  target_table      VARCHAR(64)  NOT NULL,
  source_file       VARCHAR(255) NOT NULL,
  source_row        INT          NOT NULL,
  natural_key       VARCHAR(100) NULL,
  reason_code       VARCHAR(32)  NOT NULL,
  detail            VARCHAR(255) NULL,
  PRIMARY KEY (reject_id),
  KEY ix_etl_reject_table_reason (target_table, reason_code)
) ENGINE=InnoDB;

CREATE TABLE etl_load_audit (
  target_table      VARCHAR(64)  NOT NULL,
  source_rows       INT          NOT NULL,
  loaded_rows       INT          NOT NULL,
  rejected_rows     INT          NOT NULL,
  balanced          CHAR(3)      NOT NULL,      -- 'YES' when source = loaded + rejected
  source_definition VARCHAR(160) NOT NULL,
  PRIMARY KEY (target_table)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- etl_source_audit — rows read from each source file (first hop of the
-- source -> staging -> warehouse count chain).
-- -----------------------------------------------------------------------------
CREATE TABLE etl_source_audit (
  source_file       VARCHAR(255) NOT NULL,
  staging_table     VARCHAR(64)  NOT NULL,
  file_rows         INT          NOT NULL,      -- data rows read from the file (header excluded)
  PRIMARY KEY (source_file, staging_table)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- fact_reconciliation — Lahman vs Retrosheet season totals, side by side.
-- Grain: one row per player, per season, per measure (H or HR), for the three
-- seasons loaded from Retrosheet. Values and differences are additive across
-- players and seasons (not across measures).
-- -----------------------------------------------------------------------------
CREATE TABLE fact_reconciliation (
  recon_id                  BIGINT       NOT NULL AUTO_INCREMENT,
  player_key                INT          NOT NULL,
  season_key                INT          NOT NULL,
  measure_code              VARCHAR(4)   NOT NULL,   -- degenerate: 'H' or 'HR'
  match_status              VARCHAR(16)  NOT NULL,   -- degenerate: both / lahman_only / retro_only
  lahman_value              SMALLINT     NULL,
  retro_regular_label_value SMALLINT     NULL,       -- Retrosheet games labeled 'regular'
  retro_official_value      SMALLINT     NULL,       -- + games MLB counts as regular season (2018 tiebreakers)
  diff_regular_label        SMALLINT     NULL,       -- lahman_value - retro_regular_label_value
  diff_official             SMALLINT     NULL,       -- lahman_value - retro_official_value
  PRIMARY KEY (recon_id),
  UNIQUE KEY uk_recon_grain (player_key, season_key, measure_code),
  KEY ix_recon_season (season_key),
  CONSTRAINT fk_recon_player FOREIGN KEY (player_key) REFERENCES dim_player (player_key),
  CONSTRAINT fk_recon_season FOREIGN KEY (season_key) REFERENCES dim_season (season_key)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- agg_pa_season_park — summary (aggregate) table, the physical-design
-- optimization. Grain: season x park x game type, rolled up from
-- fact_plate_appearance through dim_date -> dim_season (conformed roll-up).
-- About 560K fact rows collapse to a few hundred rows; every measure is a
-- plain SUM of the fact, so the table answers park-by-season questions
-- (Query 3 / pivot) without touching the fact.
-- -----------------------------------------------------------------------------
CREATE TABLE agg_pa_season_park (
  season_key        INT          NOT NULL,
  park_key          INT          NOT NULL,
  game_type_key     INT          NOT NULL,
  pa_count          INT          NOT NULL,
  at_bat            INT          NOT NULL,
  hit               INT          NOT NULL,
  home_run          INT          NOT NULL,
  batted_ball       INT          NOT NULL,
  total_bases       INT          NOT NULL,
  walk              INT          NOT NULL,
  strikeout         INT          NOT NULL,
  PRIMARY KEY (season_key, park_key, game_type_key),
  KEY ix_agg_park (park_key),
  KEY ix_agg_game_type (game_type_key),
  CONSTRAINT fk_agg_season    FOREIGN KEY (season_key)    REFERENCES dim_season (season_key),
  CONSTRAINT fk_agg_park      FOREIGN KEY (park_key)      REFERENCES dim_park (park_key),
  CONSTRAINT fk_agg_game_type FOREIGN KEY (game_type_key) REFERENCES dim_game_type (game_type_key)
) ENGINE=InnoDB;

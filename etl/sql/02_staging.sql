-- =============================================================================
-- Step 02 — Staging tables (raw values, unaltered except empty string -> NULL)
-- Every staging row carries its source file and 1-based data row number so any
-- warehouse or reject row can be traced back to the exact source line.
-- Source columns that start with a digit or collide with SQL keywords are renamed:
--   Lahman 2B -> X2B, 3B -> X3B;  Retrosheet double -> dbl, date -> game_date.
-- =============================================================================
USE baseball_dw;

DROP TABLE IF EXISTS stg_lahman_people;
DROP TABLE IF EXISTS stg_lahman_batting;
DROP TABLE IF EXISTS stg_lahman_teams;
DROP TABLE IF EXISTS stg_park_lookup;
DROP TABLE IF EXISTS stg_retro_plays;

CREATE TABLE stg_lahman_people (
  source_file  VARCHAR(255) NOT NULL,
  source_row   INT          NOT NULL,
  playerID     VARCHAR(20), birthYear VARCHAR(10), birthCountry VARCHAR(60),
  nameFirst    VARCHAR(100), nameLast VARCHAR(100), bats VARCHAR(12), throws VARCHAR(12),
  debut        VARCHAR(30), finalGame VARCHAR(30), retroID VARCHAR(20), bbrefID VARCHAR(20),
  PRIMARY KEY (source_file, source_row),
  KEY ix_stg_people_id (playerID)
) ENGINE=InnoDB;

CREATE TABLE stg_lahman_batting (
  source_file  VARCHAR(255) NOT NULL,
  source_row   INT          NOT NULL,
  playerID VARCHAR(20), yearID VARCHAR(10), stint VARCHAR(12), teamID VARCHAR(12), lgID VARCHAR(12),
  G VARCHAR(10), AB VARCHAR(10), R VARCHAR(10), H VARCHAR(10), X2B VARCHAR(10), X3B VARCHAR(10),
  HR VARCHAR(10), RBI VARCHAR(10), SB VARCHAR(10), CS VARCHAR(10), BB VARCHAR(10), SO VARCHAR(10),
  IBB VARCHAR(10), HBP VARCHAR(10), SH VARCHAR(10), SF VARCHAR(10), GIDP VARCHAR(10),
  PRIMARY KEY (source_file, source_row),
  KEY ix_stg_batting_grain (playerID, yearID, stint)
) ENGINE=InnoDB;

CREATE TABLE stg_lahman_teams (
  source_file  VARCHAR(255) NOT NULL,
  source_row   INT          NOT NULL,
  yearID VARCHAR(10), lgID VARCHAR(12), teamID VARCHAR(12), franchID VARCHAR(12), divID VARCHAR(12),
  G VARCHAR(10), name VARCHAR(150), park VARCHAR(150), teamIDBR VARCHAR(12), teamIDretro VARCHAR(12),
  PRIMARY KEY (source_file, source_row)
) ENGINE=InnoDB;

CREATE TABLE stg_park_lookup (
  source_file  VARCHAR(255) NOT NULL,
  source_row   INT          NOT NULL,
  park_code VARCHAR(20), park_name VARCHAR(150), city VARCHAR(80), state VARCHAR(60), country VARCHAR(60),
  PRIMARY KEY (source_file, source_row),
  KEY ix_stg_park_code (park_code)
) ENGINE=InnoDB;

CREATE TABLE stg_retro_plays (
  source_file  VARCHAR(255) NOT NULL,
  source_row   INT          NOT NULL,
  gid VARCHAR(16), pn VARCHAR(8), event VARCHAR(255), inning VARCHAR(12), top_bot VARCHAR(12),
  site VARCHAR(10), batteam VARCHAR(12), pitteam VARCHAR(12), batter VARCHAR(12), pitcher VARCHAR(12),
  bathand VARCHAR(12), pithand VARCHAR(12), pa VARCHAR(12), ab VARCHAR(12),
  single VARCHAR(12), dbl VARCHAR(12), triple VARCHAR(12), hr VARCHAR(12), sh VARCHAR(12), sf VARCHAR(12),
  hbp VARCHAR(12), walk VARCHAR(12), iw VARCHAR(12), k VARCHAR(12), k_safe VARCHAR(12), xi VARCHAR(12),
  roe VARCHAR(12), fc VARCHAR(12), othout VARCHAR(12), noout VARCHAR(12), bip VARCHAR(12),
  rbi VARCHAR(12), runs VARCHAR(12), game_date VARCHAR(10), gametype VARCHAR(20),
  PRIMARY KEY (source_file, source_row),
  KEY ix_stg_plays_grain (gid, pn),
  KEY ix_stg_plays_batter (batter),
  KEY ix_stg_plays_pitcher (pitcher)
) ENGINE=InnoDB;

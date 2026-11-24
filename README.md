# Reconciling a Century of Baseball — A Lahman + Retrosheet Data Warehouse

**Team 5 (Dead Ball Data):** Anthony Coggins
**Course:** CSCI 7435 Data Warehousing, Georgia Southern University, Fall 2026

This is a MySQL 8 dimensional warehouse that integrates the Lahman Baseball Database (season totals, 1871–2025) with Retrosheet play-by-play data (every plate appearance in 2014, 2018 and 2023). It's built as a fact constellation sharing conformed player and team dimensions.

## Business questions

1. How has the outcome mix of a plate appearance (strikeout, walk, hit, home run) shifted from era to era, and has the strikeout trend turned since MLB's 2023 rule changes? *(MLB Competition Committee)*
2. Which ballparks inflate or suppress home runs, and is the effect stable from season to season? *(club front offices)*
3. Has the platoon advantage changed across 2014, 2018 and 2023? *(managers and lineup analysts)*
4. Where do Lahman's season totals disagree with totals rolled up from Retrosheet events, and does the game-type rule explain it? *(researchers and data teams combining the sources)*

## Repository

| Path | Contents |
|---|---|
| `schema_load.sql` | Builds **and loads** the warehouse on a clean MySQL 8 instance (DDL, `LOAD DATA`, transformations, verification) |
| `olap_queries.sql` | One query per business question (plus the cause behind BQ4 and the assigned query), each labeled with its OLAP operations, hierarchy footsteps, C1–Cn cuboid chain, inference and the decision it supports; every SQL clause is tagged with its Ci step |
| `perf_experiment.sql` | Physical-design evidence: summary table vs. fact table (`EXPLAIN ANALYZE`, timings, identical-result check) |
| `demo/` | One file per business question plus `run_demo_query.bat` (echoes the labeled SQL, the result and run time) for the recorded demo |
| `etl/` | Python runner, SQL steps, source downloader, `schema_load.sql` generator and clean-instance test. See `etl/README.md` |
| `docs/` | ER diagram and verification output |

## Quick start

```
docker run -d --name dw-mysql -e MYSQL_ROOT_PASSWORD=dwpass -p 3306:3306 mysql:8.4
cd etl
pip install -r requirements.txt
python get_sources.py                                     # downloads Retrosheet
mysql --local-infile=1 -h 127.0.0.1 -u root -p -t < ../schema_load.sql
mysql -h 127.0.0.1 -u root -p -t baseball_dw < ../olap_queries.sql
```

## Schema

**Facts:**
- `fact_player_season`: one row per player, season and stint (Lahman)
- `fact_plate_appearance`: one row per plate appearance (Retrosheet)
- `fact_reconciliation`: one row per player, season and measure (Lahman vs. Retrosheet)
- `agg_pa_season_park`: summary table, one row per season, park and game type

**Dimensions:**
- `dim_date`: Day → Year-month → Season → Era
- `dim_season`: conformed season roll-up
- `dim_player`: conformed; role-playing as batter and pitcher
- `dim_team`: conformed; SCD Type 2 on natural key `franchise_id`; role-playing as batting and fielding team
- `dim_park`: Park → City → Region → Country
- `dim_outcome`: Outcome → Class → Result type
- `dim_game_type`: Game type → Season phase
- `dim_matchup`: junk dimension

The ER diagram is in `docs/`.

## Data sources

- Lahman, S. (2026). *Lahman's baseball database, 1871–2025* (Version 2025) [Data set]. SABR. https://sabr.org/lahman-database/ (CC BY-SA 3.0)
- Retrosheet. (n.d.). *Play-by-play files, 2014, 2018, 2023* [Data set]. https://www.retrosheet.org/

*The information used here was obtained free of charge from and is copyrighted by Retrosheet. Interested parties may contact Retrosheet at 20 Sunset Rd., Newark, DE 19711.*

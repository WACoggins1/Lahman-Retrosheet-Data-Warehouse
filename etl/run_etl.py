#!/usr/bin/env python3
"""
run_etl.py — rebuild the whole baseball_dw warehouse from the source files.

    python run_etl.py --password <mysql root password>

One command, no manual steps. Run order (also listed in README.md):

  00  get_sources.py                 download Retrosheet; check bundled Lahman files
  01  sql/01_ddl.sql                 create database, dimensions, facts, ETL tables
  02  sql/02_staging.sql             create staging tables
  03  stage (this file)              load source CSVs into staging, unaltered
  04  sql/04_reference_and_unknown   eras, seeded dimensions, Unknown members
  05  sql/05_load_dim_date_season    calendar date dimension and season roll-up
  06  sql/06_load_dim_player         players (SCD Type 1)
  07  sql/07_load_dim_team_scd2      teams (SCD Type 2) and surrogate-key lookups
  08  sql/08_load_dim_park           parks
  09  sql/09_load_fact_player_season season-grain fact (Lahman)
  10  sql/10_load_fact_plate_appearance  plate-appearance fact (Retrosheet)
  11  sql/11_load_agg_pa_season_park summary table (season x park x game type)
  12  sql/12_load_fact_reconciliation Lahman vs Retrosheet totals per player-season
  13  sql/13_verify.sql              source->staging->warehouse counts, reconciliation,
                                     totals, grain and orphan checks

Output: etl_output/verification_report.txt. Exit code 1 if any table fails to
balance, a grain check returns rows, or an orphan check is non-zero.
Reruns are deterministic: every load is ordered by its natural key.
"""
import argparse
import csv
import glob
import io
import os
import re
import sys
import time

try:
    import mysql.connector
except ImportError:
    sys.exit("Missing driver. Run:  pip install mysql-connector-python")

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, "sql")
OUT_DIR = os.path.join(HERE, "etl_output")
SEASONS = [2014, 2018, 2023]
csv.field_size_limit(10_000_000)

# (staging column, source column, required)
PEOPLE = [("playerID", "playerID", True), ("birthYear", "birthYear", False), ("birthCountry", "birthCountry", False),
          ("nameFirst", "nameFirst", False), ("nameLast", "nameLast", False), ("bats", "bats", False),
          ("throws", "throws", False), ("debut", "debut", False), ("finalGame", "finalGame", False),
          ("retroID", "retroID", True), ("bbrefID", "bbrefID", False)]
BATTING = [("playerID", "playerID", True), ("yearID", "yearID", True), ("stint", "stint", True),
           ("teamID", "teamID", True), ("lgID", "lgID", False), ("G", "G", False), ("AB", "AB", True),
           ("R", "R", False), ("H", "H", True), ("X2B", "2B", False), ("X3B", "3B", False), ("HR", "HR", True),
           ("RBI", "RBI", False), ("SB", "SB", False), ("CS", "CS", False), ("BB", "BB", True),
           ("SO", "SO", False), ("IBB", "IBB", False), ("HBP", "HBP", False), ("SH", "SH", False),
           ("SF", "SF", False), ("GIDP", "GIDP", False)]
TEAMS = [("yearID", "yearID", True), ("lgID", "lgID", True), ("teamID", "teamID", True),
         ("franchID", "franchID", True), ("divID", "divID", False), ("G", "G", False),
         ("name", "name", True),
         ("park", "park", False), ("teamIDBR", "teamIDBR", False), ("teamIDretro", "teamIDretro", True)]
PLAYS = [("gid", "gid", True), ("pn", "pn", True), ("event", "event", False), ("inning", "inning", False),
         ("top_bot", "top_bot", False), ("site", "site", True), ("batteam", "batteam", True),
         ("pitteam", "pitteam", True), ("batter", "batter", True), ("pitcher", "pitcher", True),
         ("bathand", "bathand", False), ("pithand", "pithand", False), ("pa", "pa", True), ("ab", "ab", True),
         ("single", "single", True), ("dbl", "double", True), ("triple", "triple", True), ("hr", "hr", True),
         ("sh", "sh", True), ("sf", "sf", True), ("hbp", "hbp", True), ("walk", "walk", True),
         ("iw", "iw", False), ("k", "k", True), ("k_safe", "k_safe", False), ("xi", "xi", False),
         ("roe", "roe", False), ("fc", "fc", False), ("othout", "othout", False), ("noout", "noout", False),
         ("bip", "bip", False), ("rbi", "rbi", False), ("runs", "runs", False), ("game_date", "date", False),
         ("gametype", "gametype", False)]

LOG = []


def say(msg=""):
    print(msg, flush=True)
    LOG.append(msg)


def norm(name):
    return re.sub(r"[^a-z0-9]", "", name.replace("﻿", "").strip().lower())


def find_ci(root, name):
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            if fn.lower() == name.lower():
                return os.path.join(dirpath, fn)
    return None


def read_csv(path):
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = raw.decode("latin-1")
    reader = csv.reader(io.StringIO(text, newline=""))
    header = next(reader)
    return header, reader


# ----------------------------------------------------------------------------- SQL
def split_sql(text):
    out, buf, title = [], [], None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("--"):
            if s.startswith("-- @report:"):
                title = s[len("-- @report:"):].strip()
            continue
        if not s and not buf:
            continue
        buf.append(line)
        if s.endswith(";"):
            stmt = "\n".join(buf).strip()[:-1].strip()
            if stmt:
                out.append((title, stmt))
            buf, title = [], None
    if "".join(buf).strip():
        out.append((title, "\n".join(buf).strip()))
    return out


def fmt_table(cols, rows):
    rows = [["NULL" if v is None else str(v) for v in r] for r in rows]
    widths = [max([len(c)] + [len(r[i]) for r in rows]) for i, c in enumerate(cols)]
    line = "+" + "+".join("-" * (w + 2) for w in widths) + "+"
    out = [line, "| " + " | ".join(c.ljust(w) for c, w in zip(cols, widths)) + " |", line]
    out += ["| " + " | ".join(v.ljust(w) for v, w in zip(r, widths)) + " |" for r in rows]
    out.append(line)
    return "\n".join(out) + f"\n{len(rows)} row{'s' if len(rows) != 1 else ''} in set"


REPORTS = {}


def run_sql_file(conn, fname):
    t0 = time.time()
    with open(os.path.join(SQL_DIR, fname), encoding="utf-8") as f:
        stmts = split_sql(f.read())
    cur = conn.cursor()
    for title, stmt in stmts:
        try:
            cur.execute(stmt)
        except mysql.connector.Error as e:
            say(f"\nSQL ERROR in {fname}:\n{stmt[:600]}\n--> {e}")
            raise SystemExit(1)
        if cur.with_rows:
            rows = cur.fetchall()
            if title:
                cols = [d[0] for d in cur.description]
                REPORTS[title] = (cols, rows)
                say(f"\n-- {title}\n{fmt_table(cols, rows)}")
    cur.close()
    say(f"  ok  {fname}  ({time.time() - t0:.1f}s)")


# ----------------------------------------------------------------------------- staging
def stage_file(conn, table, mapping, path, src_root, fixed=None):
    header, reader = read_csv(path)
    idx = {norm(h): i for i, h in enumerate(header)}
    missing = [src for _, src, req in mapping if req and norm(src) not in idx]
    if missing:
        say(f"\nSTAGING ERROR: {os.path.relpath(path, src_root)} is missing required column(s): {', '.join(missing)}")
        say(f"Columns found: {', '.join(header[:40])}{' ...' if len(header) > 40 else ''}")
        raise SystemExit(1)
    use = [(stg, idx.get(norm(src))) for stg, src, _ in mapping]
    cols = ["source_file", "source_row"] + [stg for stg, _ in use]
    sql = f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))})"
    rel = os.path.relpath(path, src_root).replace("\\", "/")
    cur, batch, n = conn.cursor(), [], 0
    for n, row in enumerate(reader, start=1):
        vals = []
        for _, i in use:
            v = row[i].strip() if i is not None and i < len(row) else ""
            vals.append(v if v != "" else None)
        batch.append([rel, n] + vals)
        if len(batch) >= 5000:
            cur.executemany(sql, batch)
            batch = []
    if batch:
        cur.executemany(sql, batch)
    conn.commit()
    record_source(conn, rel, table, n)
    cur.close()
    say(f"  staged {table:<20} {n:>9,} rows  <- {rel}")
    return n


def record_source(conn, rel, table, file_rows):
    c = conn.cursor()
    c.execute("INSERT INTO etl_source_audit (source_file, staging_table, file_rows) VALUES (%s, %s, %s)",
              (rel, table, file_rows))
    conn.commit()
    c.close()


def choose_park_source(src_root, sites):
    """Pick the park lookup file and code column that best cover the Retrosheet site codes.
    Returns None, or a dict with path, header, rows, cover and the column index of each attribute."""
    candidates = []
    lp = find_ci(os.path.join(src_root, "lahman"), "Parks.csv")
    if lp:
        candidates.append(lp)
    for p in sorted(glob.glob(os.path.join(src_root, "retrosheet", "biodata", "**", "*.csv"), recursive=True)):
        if "park" in os.path.basename(p).lower():
            candidates.append(p)
    best = None
    for path in candidates:
        header, reader = read_csv(path)
        rows = list(reader)
        for ci, h in enumerate(header):
            vals = {r[ci].strip().upper() for r in rows if ci < len(r) and r[ci].strip()}
            cover = len(sites & vals) / len(sites) if sites else 0
            if cover > 0 and (best is None or cover > best[0]):
                best = (cover, path, header, rows, ci)
    if not best or best[0] < 0.5:
        return None
    cover, path, header, rows, code_i = best
    nh = [norm(h) for h in header]

    def pick(*names, avoid=()):
        for want in names:
            for i, h in enumerate(nh):
                if i != code_i and h == want:
                    return i
        for want in names:
            for i, h in enumerate(nh):
                if i != code_i and want in h and not any(a in h for a in avoid):
                    return i
        return None

    return {"path": path, "header": header, "rows": rows, "cover": cover, "code": code_i,
            "name": pick("parkname", "name", avoid=("alias", "aka", "nick")),
            "city": pick("city"), "state": pick("state"), "country": pick("country")}


def stage_parks(conn, src_root):
    cur = conn.cursor()
    cur.execute("SELECT DISTINCT site FROM stg_retro_plays WHERE site IS NOT NULL")
    sites = {r[0].upper() for r in cur.fetchall()}
    cur.close()
    pc = choose_park_source(src_root, sites)
    if pc is None:
        say("  WARNING  no park lookup file covers the Retrosheet site codes; park attributes will be 'Unknown'")
        return 0
    path, header, rows = pc["path"], pc["header"], pc["rows"]
    rel = os.path.relpath(path, src_root).replace("\\", "/")
    sql = ("INSERT INTO stg_park_lookup (source_file, source_row, park_code, park_name, city, state, country) "
           "VALUES (%s,%s,%s,%s,%s,%s,%s)")

    def g(r, i):
        return (r[i].strip() or None) if i is not None and i < len(r) else None

    data = [[rel, n, g(r, pc["code"]), g(r, pc["name"]), g(r, pc["city"]), g(r, pc["state"]), g(r, pc["country"])]
            for n, r in enumerate(rows, start=1)]
    cur = conn.cursor()
    cur.executemany(sql, data)
    conn.commit()
    cur.close()
    record_source(conn, rel, "stg_park_lookup", len(rows))
    say(f"  staged {'stg_park_lookup':<20} {len(data):>9,} rows  <- {rel} "
        f"(column '{header[pc['code']]}' matches {pc['cover']:.0%} of site codes)")
    return len(data)


def source_files(src_root):
    """(staging table, mapping, path) for every source file, in load order."""
    out = []
    lahman = os.path.join(src_root, "lahman")
    for table, mapping, fname in [("stg_lahman_people", PEOPLE, "People.csv"),
                                  ("stg_lahman_batting", BATTING, "Batting.csv"),
                                  ("stg_lahman_teams", TEAMS, "Teams.csv")]:
        path = find_ci(lahman, fname)
        if not path:
            say(f"\nMissing source file: sources/lahman/{fname}")
            raise SystemExit(1)
        out.append((table, mapping, path))
    for y in SEASONS:
        d = os.path.join(src_root, "retrosheet", str(y))
        plays = sorted(p for p in glob.glob(os.path.join(d, "**", "*.csv"), recursive=True)
                       if "plays" in os.path.basename(p).lower())
        if not plays:
            say(f"\nMissing Retrosheet plays file for {y} under {d}")
            raise SystemExit(1)
        out.append(("stg_retro_plays", PLAYS, plays[0]))
    return out


def stage_all(conn, src_root):
    t0 = time.time()
    for table, mapping, path in source_files(src_root):
        stage_file(conn, table, mapping, path, src_root)
    stage_parks(conn, src_root)
    say(f"  ok  staging  ({time.time() - t0:.1f}s)")


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Rebuild the baseball_dw warehouse from source files.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="dwpass")
    ap.add_argument("--sources", default=os.path.join(HERE, "sources"))
    ap.add_argument("--skip-download", action="store_true", help="use files already in ./sources")
    ap.add_argument("--from-m1", help="copy files downloaded in Milestone 1 (path to M1_Package)")
    args = ap.parse_args()
    t_start = time.time()

    if not args.skip_download:
        import get_sources
        gs_args = ["--sources", args.sources] + (["--from-m1", args.from_m1] if args.from_m1 else [])
        get_sources.main(gs_args)

    say("\n[connect] MySQL " + f"{args.user}@{args.host}:{args.port}")
    conn = mysql.connector.connect(host=args.host, port=args.port, user=args.user, password=args.password,
                                   autocommit=True, charset="utf8mb4")
    cur = conn.cursor()
    cur.execute("SELECT VERSION()")
    version = cur.fetchone()[0]
    say(f"  server version {version}")
    if not str(version).startswith("8."):
        say("  WARNING: the course requires MySQL 8")
    cur.execute("SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,"
                "NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'")
    cur.execute("SET SESSION lc_time_names = 'en_US'")
    cur.close()

    say("\n[build]")
    run_sql_file(conn, "01_ddl.sql")
    run_sql_file(conn, "02_staging.sql")
    stage_all(conn, args.sources)
    for f in ["04_reference_and_unknown.sql", "05_load_dim_date_season.sql", "06_load_dim_player.sql",
              "07_load_dim_team_scd2.sql", "08_load_dim_park.sql", "09_load_fact_player_season.sql",
              "10_load_fact_plate_appearance.sql", "11_load_agg_pa_season_park.sql",
              "12_load_fact_reconciliation.sql", "13_verify.sql"]:
        run_sql_file(conn, f)

    # Determinism evidence: checksum every warehouse table and compare with the previous run
    cur = conn.cursor()
    cur.execute("CHECKSUM TABLE dim_date, dim_season, dim_player, dim_team, dim_park, dim_outcome, dim_game_type, "
                "dim_matchup, fact_player_season, fact_plate_appearance, fact_reconciliation, agg_pa_season_park, "
                "etl_reject")
    sums = "\n".join(f"{t}\t{c}" for t, c in cur.fetchall())
    cur.close()
    conn.close()
    os.makedirs(OUT_DIR, exist_ok=True)
    ck_path = os.path.join(OUT_DIR, "table_checksums.txt")
    previous = open(ck_path, encoding="utf-8").read().strip() if os.path.exists(ck_path) else None
    with open(ck_path, "w", encoding="utf-8") as f:
        f.write(sums + "\n")
    if previous is None:
        say("\n  checksums saved (rerun to confirm the rebuild is identical)")
    elif previous == sums.strip():
        say("\n  DETERMINISM: table checksums identical to the previous run")
    else:
        say("\n  NOTE: table checksums differ from the previous run (expected only if the source files changed)")

    problems = []
    cols, rows = REPORTS.get("Load reconciliation (source rows = loaded rows + rejected rows)", ([], []))
    problems += [f"{r[0]} does not balance" for r in rows if r[4] != "YES"]
    for title, (cols, rows) in REPORTS.items():
        if title.startswith("Totals check"):
            problems += [f"Totals check failed: {r[0]}" for r in rows if r[-1] != "YES"]
        if title.startswith("Source file -> staging"):
            problems += [f"{r[0]}: source file rows != staging rows" for r in rows if r[4] != "YES"]
        if title.startswith("Grain check") and rows:
            problems.append(f"{title}: {len(rows)} duplicate grain rows")
        if title.startswith("Orphan check") and rows and rows[0][0] != 0:
            problems.append(f"{title}: {rows[0][0]} orphans")

    say("\n" + "=" * 72)
    say(f"Finished in {time.time() - t_start:.0f}s. " +
        ("ALL CHECKS PASSED: every table balances, grain checks return 0 rows, orphan checks return 0."
         if not problems else "PROBLEMS FOUND:\n  - " + "\n  - ".join(problems)))
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "verification_report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(LOG) + "\n")
    print(f"Report: {os.path.join(OUT_DIR, 'verification_report.txt')}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
get_sources.py — put every source file the warehouse needs under ./sources/

  sources/lahman/            Lahman 2025 CSVs (People, Batting, Teams, Parks).
                             Bundled in this package (CC BY-SA 3.0 permits it).
  sources/retrosheet/<year>/ Retrosheet season CSVs for 2014, 2018, 2023.
  sources/retrosheet/biodata Retrosheet biographical files (park lookup).
                             Downloaded from retrosheet.org (see NOTICE below).

Writes sources/MANIFEST.txt with the size and SHA-256 of every file, so a rerun
can be shown to use byte-identical inputs.

Optional:  --from-m1 PATH   copy files already downloaded for Milestone 1
           (PATH = the M1_Package folder that contains m1_data/).

Retrosheet notice: The information used here was obtained free of charge from
and is copyrighted by Retrosheet. Interested parties may contact Retrosheet at
20 Sunset Rd., Newark, DE 19711.
"""
import argparse
import glob
import hashlib
import os
import shutil
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SEASONS = [2014, 2018, 2023]
RETRO_SEASON_URL = "https://www.retrosheet.org/downloads/{y}/{y}csvs.zip"
RETRO_BIO_URL = "https://www.retrosheet.org/downloads/biodata.zip"
LAHMAN_FILES = ["People.csv", "Batting.csv", "Teams.csv", "Parks.csv"]


def say(msg):
    print(msg, flush=True)


def find_ci(root, name):
    """Find a file by name, case-insensitively, anywhere under root."""
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn.lower() == name.lower():
                return os.path.join(dirpath, fn)
    return None


def fetch(url, dest):
    if os.path.exists(dest) and zipfile.is_zipfile(dest):
        say(f"  cached   {os.path.relpath(dest, HERE)}")
        return True
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (course data warehouse ETL)"})
        with urllib.request.urlopen(req, timeout=180) as r:
            data = r.read()
        with open(dest, "wb") as f:
            f.write(data)
        ok = zipfile.is_zipfile(dest)
        say(f"  {'fetched ' if ok else 'BAD ZIP '} {os.path.relpath(dest, HERE)} ({len(data)/1e6:.1f} MB)")
        return ok
    except Exception as e:  # noqa: BLE001
        say(f"  FAILED   {url}: {e}")
        return False


def extract(zpath, dest_dir):
    with zipfile.ZipFile(zpath) as zf:
        for member in zf.namelist():
            target = os.path.realpath(os.path.join(dest_dir, member))
            if not target.startswith(os.path.realpath(dest_dir)):
                raise RuntimeError(f"Unsafe path in {zpath}: {member}")
        zf.extractall(dest_dir)


def copy_from_m1(m1_path, src_root):
    m1_data = os.path.join(m1_path, "m1_data")
    if not os.path.isdir(m1_data):
        sys.exit(f"--from-m1: no m1_data folder under {m1_path}")
    lahman_dst = os.path.join(src_root, "lahman")
    os.makedirs(lahman_dst, exist_ok=True)
    for name in LAHMAN_FILES:
        found = find_ci(os.path.join(m1_data, "lahman"), name)
        if found:
            shutil.copy2(found, os.path.join(lahman_dst, name))
            say(f"  copied   lahman/{name}")
    for y in SEASONS:
        z = os.path.join(m1_data, "retrosheet", str(y), f"{y}csvs.zip")
        if os.path.exists(z):
            d = os.path.join(src_root, "retrosheet", str(y))
            os.makedirs(d, exist_ok=True)
            shutil.copy2(z, os.path.join(d, f"{y}csvs.zip"))
            say(f"  copied   retrosheet/{y}/{y}csvs.zip")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default=os.path.join(HERE, "sources"))
    ap.add_argument("--from-m1", help="path to the Milestone 1 M1_Package folder")
    args = ap.parse_args(argv)
    src = args.sources
    os.makedirs(src, exist_ok=True)

    say("\n[sources] Gathering source files")
    if args.from_m1:
        copy_from_m1(args.from_m1, src)

    ok = True
    for y in SEASONS:
        d = os.path.join(src, "retrosheet", str(y))
        os.makedirs(d, exist_ok=True)
        z = os.path.join(d, f"{y}csvs.zip")
        if fetch(RETRO_SEASON_URL.format(y=y), z):
            extract(z, d)
        else:
            ok = False
    bio = os.path.join(src, "retrosheet", "biodata")
    os.makedirs(bio, exist_ok=True)
    if fetch(RETRO_BIO_URL, os.path.join(bio, "biodata.zip")):
        extract(os.path.join(bio, "biodata.zip"), bio)
    else:
        say("  note     biodata.zip unavailable; the Lahman Parks file will be used for park attributes")

    missing = [n for n in ["People.csv", "Batting.csv", "Teams.csv"] if not find_ci(os.path.join(src, "lahman"), n)]
    if missing:
        say("  MISSING  Lahman files: " + ", ".join(missing))
        say("           Download the 'Comma-delimited version' from https://sabr.org/lahman-database/ "
            "and unzip it into sources/lahman/")
        ok = False

    with open(os.path.join(src, "MANIFEST.txt"), "w", encoding="utf-8") as m:
        for path in sorted(glob.glob(os.path.join(src, "**", "*"), recursive=True)):
            if os.path.isfile(path) and not path.endswith("MANIFEST.txt"):
                m.write(f"{sha256(path)}  {os.path.getsize(path):>12}  {os.path.relpath(path, src)}\n")
    say("  wrote    sources/MANIFEST.txt")
    if not ok:
        sys.exit("Source files incomplete — see messages above.")


if __name__ == "__main__":
    main()

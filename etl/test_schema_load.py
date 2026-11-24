#!/usr/bin/env python3
"""
test_schema_load.py — prove schema_load.sql builds the warehouse on a CLEAN
MySQL 8 instance and produces the same tables as run_etl.py.

    python test_schema_load.py            (run from the etl folder)

What it does:
  1. starts a brand-new throwaway container 'dw-clean' (mysql:8.4, no data)
  2. copies etl/sources and ../schema_load.sql into it
  3. runs schema_load.sql with the MySQL client inside the container
  4. compares the CHECKSUM TABLE values with etl_output/table_checksums.txt
     (written by your last run_etl.py build)
  5. removes the container (add --keep to leave it running)

Output is saved to etl_output/schema_load_output.txt.
Needs Docker Desktop running; does not touch your dw-mysql container.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "dw-clean"
PW = "dwpass"


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def main():
    keep = "--keep" in sys.argv
    schema = os.path.join(HERE, "..", "schema_load.sql")
    sources = os.path.join(HERE, "sources")
    ref = os.path.join(HERE, "etl_output", "table_checksums.txt")
    for p, what in [(schema, "schema_load.sql (run make_schema_load.py)"), (sources, "etl/sources"),
                    (ref, "etl_output/table_checksums.txt (run run_etl.py first)")]:
        if not os.path.exists(p):
            sys.exit(f"Missing {what}")

    print(f"[1/5] starting a clean MySQL 8.4 container '{NAME}' ...")
    run(["docker", "rm", "-f", NAME])
    r = run(["docker", "run", "-d", "--name", NAME, "-e", f"MYSQL_ROOT_PASSWORD={PW}", "mysql:8.4"])
    if r.returncode != 0:
        sys.exit(r.stderr)
    t0 = time.time()
    while True:  # TCP ping succeeds only once the real server (not the init server) is up
        ok = run(["docker", "exec", NAME, "mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", f"-p{PW}", "--silent"])
        if ok.returncode == 0:
            break
        if time.time() - t0 > 240:
            sys.exit("MySQL in the clean container did not start within 4 minutes")
        time.sleep(3)
    print(f"      ready after {time.time() - t0:.0f}s")

    print("[2/5] copying sources and schema_load.sql into the container ...")
    run(["docker", "exec", NAME, "mkdir", "-p", "/work"])
    for src, dst in [(sources, f"{NAME}:/work/sources"), (schema, f"{NAME}:/work/schema_load.sql")]:
        r = run(["docker", "cp", src, dst])
        if r.returncode != 0:
            sys.exit(r.stderr)

    print("[3/5] running schema_load.sql on the clean instance ...")
    t1 = time.time()
    r = run(["docker", "exec", "-w", "/work", NAME, "sh", "-c",
             f"mysql --local-infile=1 -uroot -p{PW} -t < schema_load.sql"])
    out = r.stdout + r.stderr
    os.makedirs(os.path.join(HERE, "etl_output"), exist_ok=True)
    with open(os.path.join(HERE, "etl_output", "schema_load_output.txt"), "w", encoding="utf-8") as f:
        f.write(out)
    if r.returncode != 0:
        print(out[-3000:])
        sys.exit("schema_load.sql FAILED (full output in etl_output/schema_load_output.txt)")
    print(f"      finished in {time.time() - t1:.0f}s")

    print("[4/5] comparing table checksums with run_etl.py ...")
    got = dict(re.findall(r"\|\s*(baseball_dw\.\w+)\s*\|\s*(\d+)\s*\|", out))
    want = dict(line.split("\t") for line in open(ref, encoding="utf-8").read().split("\n") if "\t" in line)
    diffs = [t for t in want if got.get(t) != want[t].strip()]
    for t in want:
        print(f"      {t:<36} {want[t].strip():>12}  {got.get(t, 'missing'):>12}  "
              f"{'same' if t not in diffs else 'DIFFERENT'}")

    print(f"[5/5] {'keeping' if keep else 'removing'} container '{NAME}'")
    if not keep:
        run(["docker", "rm", "-f", NAME])
    if diffs:
        sys.exit(f"\nRESULT: {len(diffs)} table(s) differ. (Different source files than the last run_etl.py build?)")
    print("\nRESULT: schema_load.sql on a clean MySQL 8 instance reproduces every table exactly "
          "(CHECKSUM TABLE identical to run_etl.py).")


if __name__ == "__main__":
    main()

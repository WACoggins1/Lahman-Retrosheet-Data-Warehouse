# docs

- `er_diagram.png`: ER diagram with crow's-foot cardinality, reverse-engineered from the live `baseball_dw` database in MySQL Workbench
- `verification_report.txt`: full output of the last `run_etl.py` build (copied from `etl/etl_output/`)
- `perf_output.txt`: output of `perf_experiment.sql`
- `schema_load_test.txt`: output of `etl/test_schema_load.py` (clean-instance build, checksums identical to `run_etl.py`)

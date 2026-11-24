@echo off
REM Usage: run_demo_query.bat bq1_era_outcome_mix
REM Runs one query file against the live warehouse in the dw-mysql container.
REM -vvv echoes the SQL (with its Ci labels) before the result and prints the run time.
docker exec -i dw-mysql mysql -uroot -pdwpass -t -vvv --comments baseball_dw < "%~dp0%1.sql"

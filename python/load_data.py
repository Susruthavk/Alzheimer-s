#!/usr/bin/env python3
"""
Load the simulated ALZ-301 CSVs into PostgreSQL with pandas.

Connection: set DATABASE_URL, for example
    export DATABASE_URL=postgresql://postgres:yourpassword@localhost:5432/alz_trial
(or put that line in a .env file at the project root; see config/.env.example).

Usage:
    python python/load_data.py --reset     # (re)create schema, then load
    python python/load_data.py             # load into an existing, empty schema
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_SQL = ROOT / "sql" / "01_schema.sql"
DEFAULT_URL = "postgresql://postgres:postgres@localhost:5432/alz_trial"

# Load order matters: parents before children (foreign keys).
TABLES = [
    ("trial", "study"),
    ("trial", "study_arms"),
    ("trial", "sites"),
    ("trial", "visit_schedule"),
    ("trial", "forms"),
    ("trial", "form_schedule"),
    ("trial", "subjects"),
    ("trial", "visits"),
    ("trial", "ecrf_forms"),
    ("trial", "cognitive_assessments"),
    ("trial", "queries"),
    ("sim", "injected_issues"),
]
DATE_COLS = {
    "study": ["study_start_date", "planned_enrollment_end_date", "data_cutoff_date"],
    "sites": ["activation_date"],
    "subjects": ["consent_date", "screening_date", "randomization_date", "discontinuation_date"],
    "visits": ["visit_date"],
    "ecrf_forms": ["entered_date", "sdv_date"],
    "cognitive_assessments": ["assessment_date"],
    "queries": ["opened_date", "answered_date", "closed_date"],
}
# pandas reads nullable integer FK columns as float; keep them as integers.
INT_COLS = {"queries": ["visit_id"]}


def database_url() -> str:
    env_file = ROOT / ".env"
    if "DATABASE_URL" not in os.environ and env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.strip().startswith("DATABASE_URL="):
                os.environ["DATABASE_URL"] = line.split("=", 1)[1].strip().strip('"\'')
    url = os.environ.get("DATABASE_URL", DEFAULT_URL)
    # Use the psycopg 3 driver from requirements.txt, whatever SQLAlchemy's default is.
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


def read_table(data_dir: Path, name: str) -> pd.DataFrame:
    df = pd.read_csv(data_dir / f"{name}.csv", parse_dates=DATE_COLS.get(name, []),
                     keep_default_na=True)
    for col in DATE_COLS.get(name, []):
        df[col] = df[col].dt.date          # load as SQL date, not timestamp
    for col in INT_COLS.get(name, []):
        df[col] = df[col].astype("Int64")
    return df


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reset", action="store_true",
                        help="drop and recreate the trial and sim schemas first (deletes data)")
    parser.add_argument("--data", type=Path, default=ROOT / "data" / "simulated")
    args = parser.parse_args()

    engine = create_engine(database_url())
    try:
        with engine.connect() as conn:
            conn.execute(text("select 1"))
    except Exception as exc:   # noqa: BLE001 - show a friendly message for the common case
        sys.exit(f"Could not connect to PostgreSQL ({exc.__class__.__name__}).\n"
                 f"Check that the server is running and DATABASE_URL is right.\n{exc}")

    with engine.begin() as conn:            # one transaction: all tables load or none do
        if args.reset:
            conn.exec_driver_sql(SCHEMA_SQL.read_text())
            print("Schema recreated from", SCHEMA_SQL.relative_to(ROOT))
        for schema, name in TABLES:
            df = read_table(args.data, name)
            df.to_sql(name, conn, schema=schema, if_exists="append", index=False,
                      method="multi", chunksize=1000)
            print(f"  loaded {schema}.{name:<22} {len(df):>6} rows")
        # query_id is an identity column; move it past the loaded rows so
        # edit checks can insert new queries later.
        conn.execute(text(
            "select setval(pg_get_serial_sequence('trial.queries', 'query_id'), "
            "coalesce((select max(query_id) from trial.queries), 0) + 1, false)"))
    print("Done.")


if __name__ == "__main__":
    main()

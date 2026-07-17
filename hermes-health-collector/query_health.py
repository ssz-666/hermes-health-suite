#!/usr/bin/env python3
"""Read local Hermes health data from SQLite."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any


DEFAULT_DB_PATH = Path.home() / "HermesData" / "health" / "health.sqlite"


def rows_to_dicts(cursor: sqlite3.Cursor, rows: list[sqlite3.Row]) -> list[dict[str, Any]]:
    columns = [column[0] for column in cursor.description]
    return [dict(zip(columns, row)) for row in rows]


def main() -> None:
    parser = argparse.ArgumentParser(description="Query local Hermes health summaries.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--json", action="store_true", help="Print JSON instead of a readable table.")
    args = parser.parse_args()

    if not args.db.exists():
        raise SystemExit(f"Database does not exist yet: {args.db}")

    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        cursor = conn.execute(
            """
            SELECT
              date,
              steps,
              active_energy_kcal,
              avg_heart_rate,
              resting_heart_rate,
              hrv_sdnn,
              sleep_minutes,
              workout_minutes,
              updated_at
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT ?
            """,
            (args.days,),
        )
        rows = rows_to_dicts(cursor, cursor.fetchall())

    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return

    if not rows:
        print("No health summaries found.")
        return

    print("date        steps  kcal   avg_hr  rest_hr  hrv   sleep_min  workout_min")
    for row in rows:
        print(
            f"{row['date']}  "
            f"{row['steps'] or 0:>5}  "
            f"{row['active_energy_kcal'] or 0:>5.0f}  "
            f"{row['avg_heart_rate'] or 0:>6.1f}  "
            f"{row['resting_heart_rate'] or 0:>7.1f}  "
            f"{row['hrv_sdnn'] or 0:>5.1f}  "
            f"{row['sleep_minutes'] or 0:>9}  "
            f"{row['workout_minutes'] or 0:>11}"
        )


if __name__ == "__main__":
    main()

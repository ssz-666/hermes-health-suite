#!/usr/bin/env python3
"""Shared health analysis helpers for Hermes Health."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any


DB_PATH = Path.home() / "HermesData" / "health" / "health.sqlite"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def init_analysis_db(db_path: Path = DB_PATH) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(health_daily_summary)").fetchall()
        }
        if columns and "nap_minutes" not in columns:
            conn.execute("ALTER TABLE health_daily_summary ADD COLUMN nap_minutes INTEGER")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS health_daily_tags (
              date TEXT NOT NULL,
              tag TEXT NOT NULL,
              reason TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (date, tag)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS health_memory_insights (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              insight_key TEXT NOT NULL UNIQUE,
              title TEXT NOT NULL,
              detail TEXT NOT NULL,
              confidence REAL NOT NULL,
              sample_size INTEGER NOT NULL,
              updated_at TEXT NOT NULL
            )
            """
        )
        conn.commit()


def read_rows(limit: int = 90, db_path: Path = DB_PATH) -> list[dict[str, Any]]:
    if not db_path.exists():
        return []
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT date, steps, active_energy_kcal, avg_heart_rate, resting_heart_rate,
                   hrv_sdnn, sleep_minutes, nap_minutes, workout_minutes, updated_at
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


def values_for(rows: list[dict[str, Any]], key: str, include_zero: bool = True) -> list[float]:
    values: list[float] = []
    for row in rows:
        value = row.get(key)
        if value is None:
            continue
        if not include_zero and value == 0:
            continue
        values.append(float(value))
    return values


def avg(rows: list[dict[str, Any]], key: str, include_zero: bool = True) -> float | None:
    values = values_for(rows, key, include_zero=include_zero)
    return mean(values) if values else None


def baseline(rows: list[dict[str, Any]], key: str, min_days: int = 5, include_zero: bool = True) -> tuple[float | None, int]:
    values = values_for(rows, key, include_zero=include_zero)
    if len(values) < min_days:
        return None, len(values)
    return mean(values), len(values)


def generate_tags(today: dict[str, Any], rows: list[dict[str, Any]]) -> list[tuple[str, str]]:
    history = [row for row in rows if row["date"] != today["date"]]
    tags: list[tuple[str, str]] = []

    required = ["steps", "active_energy_kcal", "avg_heart_rate", "hrv_sdnn", "sleep_minutes"]
    missing = [key for key in required if today.get(key) is None]
    if not missing and today.get("sleep_minutes") not in (None, 0):
        tags.append(("#数据完整", "核心指标齐全。"))
    else:
        tags.append(("#数据不完整", "缺失或为 0 的字段：" + ", ".join(missing or ["sleep_minutes"])))

    hrv_base, hrv_count = baseline(history, "hrv_sdnn")
    rhr_base, rhr_count = baseline(history, "resting_heart_rate")
    if hrv_base and rhr_base and today.get("hrv_sdnn") is not None and today.get("resting_heart_rate") is not None:
        hrv_pct = (today["hrv_sdnn"] - hrv_base) / hrv_base
        rhr_diff = today["resting_heart_rate"] - rhr_base
        if hrv_pct >= 0.10 and rhr_diff <= 0:
            tags.append(("#恢复好", f"HRV 高于基线 {hrv_pct:+.0%}，静息心率相对基线 {rhr_diff:+.1f} bpm。"))
        elif hrv_pct <= -0.15 or rhr_diff >= 5:
            tags.append(("#恢复偏弱", f"HRV 相对基线 {hrv_pct:+.0%}，静息心率相对基线 {rhr_diff:+.1f} bpm。"))
    elif hrv_count < 5 or rhr_count < 5:
        tags.append(("#基线建立中", "HRV 或静息心率可用历史少于 5 天。"))

    sleep = today.get("sleep_minutes")
    if sleep is not None:
        if sleep == 0:
            tags.append(("#睡眠缺失", "睡眠为 0，可能还没同步。"))
        elif sleep < 360:
            tags.append(("#睡眠不足", "睡眠少于 6 小时。"))
        elif sleep >= 420:
            tags.append(("#睡眠充足", "睡眠达到 7 小时以上。"))

    steps_base, _ = baseline(history, "steps")
    if steps_base and today.get("steps") is not None:
        if today["steps"] >= steps_base * 1.25:
            tags.append(("#步数高", f"步数高于基线 {((today['steps'] - steps_base) / steps_base):+.0%}。"))
        elif today["steps"] <= steps_base * 0.55:
            tags.append(("#活动偏低", f"步数低于基线 {((today['steps'] - steps_base) / steps_base):+.0%}。"))

    active_base, _ = baseline(history, "active_energy_kcal")
    if active_base and today.get("active_energy_kcal") is not None:
        pct = (today["active_energy_kcal"] - active_base) / active_base if active_base else 0
        if pct >= 0.75:
            tags.append(("#活动高", f"活动能量高于基线 {pct:+.0%}。"))
        elif pct <= -0.50:
            tags.append(("#活动低", f"活动能量低于基线 {pct:+.0%}。"))

    workout = today.get("workout_minutes")
    if workout is not None:
        if workout >= 30:
            tags.append(("#训练日", "运动时间达到 30 分钟以上。"))
        elif workout <= 5:
            tags.append(("#低训练量", "运动时间不超过 5 分钟。"))

    return tags


def write_tags(date: str, tags: list[tuple[str, str]], db_path: Path = DB_PATH) -> None:
    init_analysis_db(db_path)
    now = utc_now()
    with sqlite3.connect(db_path) as conn:
        conn.execute("DELETE FROM health_daily_tags WHERE date = ?", (date,))
        conn.executemany(
            """
            INSERT INTO health_daily_tags (date, tag, reason, created_at)
            VALUES (?, ?, ?, ?)
            """,
            [(date, tag, reason, now) for tag, reason in tags],
        )
        conn.commit()


def read_tags(limit: int = 30, db_path: Path = DB_PATH) -> list[dict[str, Any]]:
    init_analysis_db(db_path)
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT date, tag, reason
            FROM health_daily_tags
            ORDER BY date DESC, tag
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]

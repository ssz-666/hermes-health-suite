#!/usr/bin/env python3
"""Generate a weekly Chinese health report for Hermes."""

from __future__ import annotations

import json
import sqlite3
import subprocess
from datetime import datetime
from pathlib import Path
from statistics import mean
from typing import Any


DB_PATH = Path.home() / "HermesData" / "health" / "health.sqlite"
JOURNAL_PATH = Path.home() / "HermesData" / "health" / "health-journal.md"

METRICS = {
    "steps": ("步数", " 步", 0),
    "active_energy_kcal": ("活动能量", " kcal", 1),
    "avg_heart_rate": ("平均心率", " bpm", 1),
    "resting_heart_rate": ("静息心率", " bpm", 1),
    "hrv_sdnn": ("HRV SDNN", " ms", 1),
    "sleep_minutes": ("睡眠", " 分钟", 0),
    "workout_minutes": ("运动", " 分钟", 0),
}


def read_rows(limit: int = 30) -> list[dict[str, Any]]:
    if not DB_PATH.exists():
        return []
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT date, steps, active_energy_kcal, avg_heart_rate, resting_heart_rate,
                   hrv_sdnn, sleep_minutes, workout_minutes, updated_at
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


def values(rows: list[dict[str, Any]], key: str, include_zero: bool = True) -> list[float]:
    output = []
    for row in rows:
        value = row.get(key)
        if value is None:
            continue
        if not include_zero and value == 0:
            continue
        output.append(float(value))
    return output


def fmt(value: Any, suffix: str = "", decimals: int = 0) -> str:
    if value is None:
        return "无数据"
    if isinstance(value, float):
        return f"{value:.{decimals}f}{suffix}"
    return f"{value}{suffix}"


def avg(rows: list[dict[str, Any]], key: str, include_zero: bool = True) -> float | None:
    data = values(rows, key, include_zero=include_zero)
    return mean(data) if data else None


def read_nutrition_rows(dates: list[str]) -> list[dict[str, Any]]:
    if not DB_PATH.exists() or not dates:
        return []
    placeholders = ",".join("?" for _ in dates)
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nutrition_meals (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              date TEXT NOT NULL,
              meal_type TEXT NOT NULL,
              food_name TEXT NOT NULL,
              calories_kcal REAL,
              protein_g REAL,
              carbs_g REAL,
              fat_g REAL,
              source TEXT NOT NULL,
              note TEXT,
              created_at TEXT NOT NULL
            )
            """
        )
        rows = conn.execute(
            f"""
            SELECT date, meal_type, food_name, calories_kcal, protein_g, carbs_g, fat_g
            FROM nutrition_meals
            WHERE date IN ({placeholders})
            ORDER BY date DESC, created_at ASC
            """,
            dates,
        ).fetchall()
    return [dict(row) for row in rows]


def best_day(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    scored = []
    for row in rows:
        score = 0.0
        if row.get("hrv_sdnn") is not None:
            score += row["hrv_sdnn"]
        if row.get("resting_heart_rate") is not None:
            score -= row["resting_heart_rate"] * 0.7
        if row.get("sleep_minutes") is not None:
            score += min(row["sleep_minutes"], 540) / 20
        scored.append((score, row))
    if not scored:
        return None
    return max(scored, key=lambda item: item[0])[1]


def build_report(rows: list[dict[str, Any]]) -> str:
    now = datetime.now()
    title_time = now.strftime("%Y-%m-%d %H:%M")
    week = rows[:7]
    previous_week = rows[7:14]

    if not week:
        return (
            f"\n---\n\n## {title_time} 健康周报\n\n"
            "本周没有健康数据。请打开 Hermes Health 同步最近 7 天。\n"
        )

    total_steps = sum(row["steps"] for row in week if row.get("steps") is not None)
    total_workout = sum(row["workout_minutes"] for row in week if row.get("workout_minutes") is not None)
    total_energy = sum(row["active_energy_kcal"] for row in week if row.get("active_energy_kcal") is not None)
    nutrition_rows = read_nutrition_rows([row["date"] for row in week])
    nutrition_days = {row["date"] for row in nutrition_rows}
    total_intake = sum(float(row.get("calories_kcal") or 0) for row in nutrition_rows)
    total_protein = sum(float(row.get("protein_g") or 0) for row in nutrition_rows)
    best = best_day(week)

    lines = [
        "\n---",
        "",
        f"## {title_time} 健康周报",
        "",
        f"覆盖日期：{week[-1]['date']} 至 {week[0]['date']}（{len(week)} 天）",
        "",
        "**本周总览**",
        f"- 总步数：{total_steps:.0f} 步",
        f"- 总活动能量：{total_energy:.1f} kcal",
        f"- 总运动时间：{total_workout:.0f} 分钟",
        f"- 平均睡眠：{fmt(avg(week, 'sleep_minutes', include_zero=False), ' 分钟', 0)}",
        f"- 平均 HRV：{fmt(avg(week, 'hrv_sdnn'), ' ms', 1)}",
        f"- 平均静息心率：{fmt(avg(week, 'resting_heart_rate'), ' bpm', 1)}",
        "",
        "**饮食与热量**",
        (
            f"- 已记录 {len(nutrition_rows)} 餐 / {len(nutrition_days)} 天；"
            f"总摄入 {total_intake:.0f} kcal；蛋白 {total_protein:.0f} g。"
            if nutrition_rows
            else "- 本周还没有餐食记录，暂不评估摄入与减脂效果。"
        ),
        "",
        "**本周日均值**",
    ]

    for key, (label, suffix, decimals) in METRICS.items():
        include_zero = key != "sleep_minutes"
        lines.append(f"- {label}：{fmt(avg(week, key, include_zero=include_zero), suffix, decimals)}")

    lines.extend(["", "**和上一周对比**"])
    if previous_week:
        for key, (label, suffix, decimals) in METRICS.items():
            include_zero = key != "sleep_minutes"
            current = avg(week, key, include_zero=include_zero)
            previous = avg(previous_week, key, include_zero=include_zero)
            if current is None or previous is None:
                change = "无法比较"
            else:
                diff = current - previous
                sign = "+" if diff > 0 else ""
                change = f"{sign}{diff:.{decimals}f}{suffix}"
            lines.append(f"- {label}：{change}")
    else:
        lines.append("- 上一周数据不足，暂时无法比较。")

    lines.extend(["", "**本周亮点 / 风险**"])
    if best:
        lines.append(f"- 综合恢复表现最好的一天：{best['date']}。")
    if values(week, "sleep_minutes", include_zero=False) and avg(week, "sleep_minutes", include_zero=False) < 390:
        lines.append("- 平均睡眠低于 6.5 小时，建议下周优先补睡眠。")
    if values(week, "hrv_sdnn") and values(previous_week, "hrv_sdnn"):
        current_hrv = avg(week, "hrv_sdnn")
        previous_hrv = avg(previous_week, "hrv_sdnn")
        if current_hrv is not None and previous_hrv is not None and current_hrv < previous_hrv * 0.85:
            lines.append("- HRV 较上一周下降明显，注意恢复压力。")
    if total_workout < 90:
        lines.append("- 本周运动时间偏少，下周可尝试增加 2-3 次轻中等活动。")
    if len(lines) > 0 and lines[-1] == "**本周亮点 / 风险**":
        lines.append("- 暂无明显风险，继续保持数据同步。")

    lines.extend(
        [
            "",
            "**下周建议**",
            "- 优先保证睡眠和规律同步数据。",
            "- 如果 HRV 和静息心率稳定，可逐步增加训练量；如果连续疲劳，优先恢复。",
            "- 饮食只做轻量提示：记录越完整，摄入与消耗建议越准。",
            "- 以上是数据观察，不是医疗诊断。",
        ]
    )
    return "\n".join(lines) + "\n"


def notify(message: str) -> None:
    script = f'display notification "{message}" with title "Hermes Health"'
    subprocess.run(["osascript", "-e", script], check=False)


def main() -> None:
    JOURNAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    rows = read_rows()
    report = build_report(rows)
    if not JOURNAL_PATH.exists():
        JOURNAL_PATH.write_text("# Health Journal\n", encoding="utf-8")
    with JOURNAL_PATH.open("a", encoding="utf-8") as handle:
        handle.write(report)
    notify("健康周报已保存。")


if __name__ == "__main__":
    main()

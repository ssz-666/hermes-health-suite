#!/usr/bin/env python3
"""Generate long-term personal health memory insights."""

from __future__ import annotations

import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any

from health_analysis import DB_PATH, init_analysis_db, read_rows


JOURNAL_PATH = Path.home() / "HermesData" / "health" / "health-journal.md"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def save_insight(key: str, title: str, detail: str, confidence: float, sample_size: int) -> None:
    init_analysis_db()
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """
            INSERT INTO health_memory_insights
              (insight_key, title, detail, confidence, sample_size, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(insight_key) DO UPDATE SET
              title = excluded.title,
              detail = excluded.detail,
              confidence = excluded.confidence,
              sample_size = excluded.sample_size,
              updated_at = excluded.updated_at
            """,
            (key, title, detail, confidence, sample_size, utc_now()),
        )
        conn.commit()


def next_day_pairs(rows: list[dict[str, Any]]) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    ordered = list(reversed(rows))
    pairs = []
    for idx in range(len(ordered) - 1):
        pairs.append((ordered[idx], ordered[idx + 1]))
    return pairs


def diff_mean(a: list[float], b: list[float]) -> float | None:
    if not a or not b:
        return None
    return mean(a) - mean(b)


def build_insights(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    insights: list[dict[str, Any]] = []
    pairs = next_day_pairs(rows)

    short_sleep_next_hrv = []
    normal_sleep_next_hrv = []
    for day, next_day in pairs:
        sleep = day.get("sleep_minutes")
        next_hrv = next_day.get("hrv_sdnn")
        if sleep is None or sleep == 0 or next_hrv is None:
            continue
        if sleep < 360:
            short_sleep_next_hrv.append(float(next_hrv))
        elif sleep >= 390:
            normal_sleep_next_hrv.append(float(next_hrv))
    diff = diff_mean(short_sleep_next_hrv, normal_sleep_next_hrv)
    sample_size = len(short_sleep_next_hrv) + len(normal_sleep_next_hrv)
    if diff is not None and sample_size >= 4:
        direction = "下降" if diff < 0 else "上升"
        insights.append(
            {
                "key": "short_sleep_next_hrv",
                "title": "短睡眠与次日 HRV",
                "detail": f"睡眠少于 6 小时后的次日 HRV 平均{direction} {abs(diff):.1f} ms。",
                "confidence": min(1.0, sample_size / 20),
                "sample_size": sample_size,
            }
        )

    high_steps_next_recovery = []
    normal_steps_next_recovery = []
    step_values = [row["steps"] for row in rows if row.get("steps") is not None]
    step_baseline = mean(step_values) if step_values else None
    for day, next_day in pairs:
        if step_baseline is None or day.get("steps") is None:
            continue
        next_hrv = next_day.get("hrv_sdnn")
        next_rhr = next_day.get("resting_heart_rate")
        if next_hrv is None or next_rhr is None:
            continue
        recovery_proxy = float(next_hrv) - float(next_rhr) * 0.6
        if day["steps"] >= step_baseline * 1.25:
            high_steps_next_recovery.append(recovery_proxy)
        else:
            normal_steps_next_recovery.append(recovery_proxy)
    diff = diff_mean(high_steps_next_recovery, normal_steps_next_recovery)
    sample_size = len(high_steps_next_recovery) + len(normal_steps_next_recovery)
    if diff is not None and sample_size >= 5:
        direction = "更好" if diff > 0 else "更弱"
        insights.append(
            {
                "key": "high_steps_next_recovery",
                "title": "高步数与次日恢复",
                "detail": f"高步数日后的次日恢复代理指标平均{direction} {abs(diff):.1f} 点。",
                "confidence": min(1.0, sample_size / 25),
                "sample_size": sample_size,
            }
        )

    active_values = [row["active_energy_kcal"] for row in rows if row.get("active_energy_kcal") is not None]
    active_baseline = mean(active_values) if active_values else None
    high_active_next_recovery = []
    normal_active_next_recovery = []
    for day, next_day in pairs:
        if active_baseline is None or day.get("active_energy_kcal") is None:
            continue
        next_hrv = next_day.get("hrv_sdnn")
        next_rhr = next_day.get("resting_heart_rate")
        if next_hrv is None or next_rhr is None:
            continue
        recovery_proxy = float(next_hrv) - float(next_rhr) * 0.6
        if day["active_energy_kcal"] >= active_baseline * 1.5:
            high_active_next_recovery.append(recovery_proxy)
        else:
            normal_active_next_recovery.append(recovery_proxy)
    diff = diff_mean(high_active_next_recovery, normal_active_next_recovery)
    sample_size = len(high_active_next_recovery) + len(normal_active_next_recovery)
    if diff is not None and sample_size >= 5:
        direction = "更好" if diff > 0 else "更弱"
        insights.append(
            {
                "key": "high_active_next_recovery",
                "title": "高活动能量与次日恢复",
                "detail": f"高活动能量日后的次日恢复代理指标平均{direction} {abs(diff):.1f} 点。",
                "confidence": min(1.0, sample_size / 25),
                "sample_size": sample_size,
            }
        )

    if not insights:
        insights.append(
            {
                "key": "insufficient_memory",
                "title": "个人健康记忆仍在建立",
                "detail": "目前样本还少。继续同步 14-30 天后，Hermes 会更可靠地总结睡眠、活动与恢复之间的个人规律。",
                "confidence": 0.2,
                "sample_size": len(rows),
            }
        )

    return insights


def append_journal(insights: list[dict[str, Any]]) -> None:
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        "\n---",
        "",
        f"## {now} 个人健康记忆更新",
        "",
    ]
    for insight in insights:
        lines.append(f"- **{insight['title']}**：{insight['detail']}（样本 {insight['sample_size']}，置信度 {insight['confidence']:.0%}）")
    lines.append("")

    if not JOURNAL_PATH.exists():
        JOURNAL_PATH.write_text("# Health Journal\n", encoding="utf-8")
    with JOURNAL_PATH.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def notify(message: str) -> None:
    subprocess.run(["osascript", "-e", f'display notification "{message}" with title "Hermes Health"'], check=False)


def main() -> None:
    init_analysis_db()
    rows = read_rows(limit=90)
    insights = build_insights(rows)
    for insight in insights:
        save_insight(
            insight["key"],
            insight["title"],
            insight["detail"],
            insight["confidence"],
            insight["sample_size"],
        )
    append_journal(insights)
    notify("个人健康记忆已更新。")


if __name__ == "__main__":
    main()

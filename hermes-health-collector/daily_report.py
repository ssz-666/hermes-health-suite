#!/usr/bin/env python3
"""Generate a data-quality-aware local health report for Hermes."""

from __future__ import annotations

import sqlite3
import subprocess
from datetime import datetime
from pathlib import Path
from statistics import mean, pstdev
from typing import Any

from health_analysis import generate_tags, init_analysis_db, write_tags


DB_PATH = Path.home() / "HermesData" / "health" / "health.sqlite"
JOURNAL_PATH = Path.home() / "HermesData" / "health" / "health-journal.md"

METRICS = {
    "steps": ("步数", " 步", 0, "higher"),
    "active_energy_kcal": ("活动能量", " kcal", 1, "higher"),
    "avg_heart_rate": ("平均心率", " bpm", 1, "neutral"),
    "resting_heart_rate": ("静息心率", " bpm", 1, "lower"),
    "hrv_sdnn": ("HRV SDNN", " ms", 1, "higher"),
    "sleep_minutes": ("睡眠", " 分钟", 0, "higher"),
    "nap_minutes": ("午睡", " 分钟", 0, "neutral"),
    "workout_minutes": ("运动", " 分钟", 0, "higher"),
}


def read_rows(limit: int = 30) -> list[dict[str, Any]]:
    if not DB_PATH.exists():
        return []

    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT
              date,
              steps,
              active_energy_kcal,
              avg_heart_rate,
              resting_heart_rate,
              hrv_sdnn,
              sleep_minutes,
              nap_minutes,
              workout_minutes,
              updated_at
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    return [dict(row) for row in rows]


def read_nutrition_day(date: str) -> dict[str, Any]:
    if not DB_PATH.exists():
        return {"meals": [], "totals": {}}

    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nutrition_profile (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              name TEXT,
              sex TEXT,
              age INTEGER,
              height_cm REAL,
              weight_kg REAL,
              target_weight_kg REAL,
              goal TEXT,
              activity_level TEXT,
              updated_at TEXT NOT NULL
            )
            """
        )
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
        profile_row = conn.execute("SELECT * FROM nutrition_profile WHERE id = 1").fetchone()
        meals = [dict(row) for row in conn.execute(
            """
            SELECT meal_type, food_name, calories_kcal, protein_g, carbs_g, fat_g
            FROM nutrition_meals
            WHERE date = ?
            ORDER BY created_at ASC
            """,
            (date,),
        )]

    profile = dict(profile_row) if profile_row else None
    intake = sum(float(meal.get("calories_kcal") or 0) for meal in meals)
    protein = sum(float(meal.get("protein_g") or 0) for meal in meals)
    carbs = sum(float(meal.get("carbs_g") or 0) for meal in meals)
    fat = sum(float(meal.get("fat_g") or 0) for meal in meals)
    bmr = None
    if profile and profile.get("weight_kg") and profile.get("height_cm") and profile.get("age"):
        base = 10 * float(profile["weight_kg"]) + 6.25 * float(profile["height_cm"]) - 5 * int(profile["age"])
        bmr = base - 161 if "女" in str(profile.get("sex") or "") else base + 5

    return {
        "profile": profile,
        "meals": meals,
        "totals": {
            "intake_kcal": intake,
            "protein_g": protein,
            "carbs_g": carbs,
            "fat_g": fat,
            "estimated_bmr_kcal": bmr,
        },
    }


def fmt(value: Any, suffix: str = "", decimals: int = 0) -> str:
    if value is None:
        return "无数据"
    if isinstance(value, float):
        return f"{value:.{decimals}f}{suffix}"
    return f"{value}{suffix}"


def delta(today: Any, previous: Any, suffix: str = "", decimals: int = 0) -> str:
    if today is None or previous is None:
        return "无法比较"
    change = today - previous
    sign = "+" if change > 0 else ""
    return f"{sign}{change:.{decimals}f}{suffix}"


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
    if not values:
        return None
    return mean(values)


def baseline_stats(rows: list[dict[str, Any]], key: str) -> dict[str, Any]:
    include_zero = key != "sleep_minutes"
    values = values_for(rows, key, include_zero=include_zero)
    if not values:
        return {"count": 0, "mean": None, "std": None}
    return {
        "count": len(values),
        "mean": mean(values),
        "std": pstdev(values) if len(values) > 1 else 0.0,
    }


def compare_to_baseline(value: Any, stats: dict[str, Any], suffix: str, decimals: int) -> str:
    if value is None:
        return "最新数据缺失"
    if stats["count"] < 5 or stats["mean"] is None:
        return f"基线不足（{stats['count']} 个可用日）"

    baseline = stats["mean"]
    diff = float(value) - baseline
    pct = (diff / baseline * 100) if baseline else 0
    sign = "+" if diff > 0 else ""
    std = stats["std"] or 0
    z_text = ""
    if std > 0:
        z = diff / std
        z_text = f"，z={z:+.1f}"
    return f"相对基线 {sign}{diff:.{decimals}f}{suffix}（{pct:+.0f}%{z_text}）"


def quality_report(today: dict[str, Any], rows: list[dict[str, Any]], now: datetime) -> tuple[int, list[str], list[str]]:
    score = 100
    warnings: list[str] = []
    notes: list[str] = []

    if today["date"] != now.strftime("%Y-%m-%d"):
        score -= 45
        warnings.append("今天还没有数据，请打开 Hermes Health 同步最近 7 天。")

    expected = ["steps", "active_energy_kcal", "avg_heart_rate", "hrv_sdnn", "sleep_minutes"]
    missing = [key for key in expected if today.get(key) is None]
    if missing:
        score -= 10 * len(missing)
        warnings.append("缺失字段：" + ", ".join(missing))

    if today.get("sleep_minutes") in (None, 0):
        score -= 15
        warnings.append("睡眠为空或 0，可能 Apple Health 还没同步睡眠数据。")

    if today.get("resting_heart_rate") is None:
        score -= 8
        notes.append("静息心率缺失；这个指标有时会晚一点生成。")

    if now.hour < 18:
        notes.append("当前还没到晚上，步数和活动能量可能只是当天部分数据。")
    elif today.get("steps") is not None and today["steps"] < 1000:
        score -= 10
        warnings.append("按当前时间看，步数明显偏低。")

    history_dates = {row["date"] for row in rows}
    if len(history_dates) < 14:
        notes.append(f"目前只有 {len(history_dates)} 天数据；积累到 14-30 天后，个人基线会更可靠。")

    sleep_values = values_for(rows[:14], "sleep_minutes", include_zero=False)
    if len(sleep_values) < 5:
        notes.append("睡眠基线较弱，因为非 0 睡眠记录少于 5 天。")

    return max(score, 0), warnings, notes


def recovery_signal(today: dict[str, Any], baseline_rows: list[dict[str, Any]]) -> tuple[int | None, list[str], list[str]]:
    components: list[int] = []
    reasons: list[str] = []
    cautions: list[str] = []

    hrv = today.get("hrv_sdnn")
    hrv_base = baseline_stats(baseline_rows, "hrv_sdnn")
    if hrv is not None and hrv_base["count"] >= 5 and hrv_base["mean"]:
        pct = (hrv - hrv_base["mean"]) / hrv_base["mean"]
        signal = 1 if pct > 0.10 else -1 if pct < -0.15 else 0
        components.append(signal)
        reasons.append(f"HRV 相对基线 {pct:+.0%}。")
        if signal < 0:
            cautions.append("HRV 明显低于基线")

    rhr = today.get("resting_heart_rate")
    rhr_base = baseline_stats(baseline_rows, "resting_heart_rate")
    if rhr is not None and rhr_base["count"] >= 5 and rhr_base["mean"]:
        diff = rhr - rhr_base["mean"]
        signal = 1 if diff < -3 else -1 if diff > 5 else 0
        components.append(signal)
        reasons.append(f"静息心率相对基线 {diff:+.1f} bpm。")
        if signal < 0:
            cautions.append("静息心率高于基线")

    sleep = today.get("sleep_minutes")
    sleep_base = baseline_stats(baseline_rows, "sleep_minutes")
    if sleep is not None and sleep_base["count"] >= 5 and sleep_base["mean"]:
        pct = (sleep - sleep_base["mean"]) / sleep_base["mean"]
        signal = 1 if pct > 0.10 else -1 if pct < -0.20 else 0
        components.append(signal)
        reasons.append(f"睡眠相对基线 {pct:+.0%}。")
        if signal < 0:
            cautions.append("睡眠低于基线")
    elif sleep is not None:
        if sleep < 360:
            components.append(-1)
            reasons.append("睡眠少于 6 小时。")
            cautions.append("睡眠时长偏短")
        elif sleep >= 420:
            components.append(1)
            reasons.append("睡眠达到 7 小时以上。")

    active = today.get("active_energy_kcal")
    active_base = baseline_stats(baseline_rows, "active_energy_kcal")
    if active is not None and active_base["count"] >= 5 and active_base["mean"]:
        pct = (active - active_base["mean"]) / active_base["mean"]
        reasons.append(f"活动能量相对基线 {pct:+.0%}。")
        if pct > 1.25:
            cautions.append("活动负荷明显高于当前基线")

    if not components:
        return None, ["HRV、静息心率、睡眠等基线还不够，暂时无法计算恢复分。"], cautions

    raw = sum(components)
    score = 70 + raw * 10
    return max(0, min(100, score)), reasons, cautions


def training_recommendation(
    recovery_score: int | None,
    quality_score: int,
    reasons: list[str],
    cautions: list[str],
) -> tuple[str, list[str]]:
    if quality_score < 70:
        return "数据不足，建议只做轻量活动或手动补同步后再判断", [
            "最新健康记录不完整，训练建议置信度较低。",
            *reasons,
        ]

    if recovery_score is None:
        return "基线不足，建议轻中等活动，避免突然加大强度", [
            "个人基线仍在建立中。",
            *reasons,
        ]

    caution_text = " ".join(cautions)
    if recovery_score >= 85 and not cautions:
        recommendation = "状态较好，可以正常训练；若主观感觉也好，可安排中高强度"
    elif recovery_score >= 75:
        recommendation = "建议正常到轻中等训练，保留一点余量"
    elif recovery_score >= 60:
        recommendation = "建议轻中等活动，避免高强度冲刺"
    else:
        recommendation = "建议恢复日，优先睡眠、散步、拉伸，避免高强度"

    explanation = [*reasons]
    if cautions:
        explanation.append(f"注意项：{caution_text}。")
    return recommendation, explanation


def professional_health_advice(
    today: dict[str, Any],
    recovery_score: int | None,
    quality_score: int,
    alerts: list[str],
    tags: list[tuple[str, str]],
) -> list[str]:
    tag_values = {tag for tag, _ in tags}
    sleep = today.get("sleep_minutes")
    active = today.get("active_energy_kcal")
    workout = today.get("workout_minutes")

    advice: list[str] = []

    if quality_score < 70:
        advice.append("数据完整度不足，今天建议按保守方案执行：轻量活动、规律进食、早点睡，先把同步和睡眠数据补稳定。")
        return advice

    if recovery_score is not None and recovery_score >= 80:
        advice.append("运动：恢复指标偏积极，可以做轻中等训练；如果主观精力也好，可加入短时间较高强度，但总量不要一次性跳太多。")
    elif recovery_score is not None and recovery_score < 60:
        advice.append("运动：今天更适合作为恢复日，优先散步、拉伸、低强度有氧，避免冲刺、力竭训练和长时间高心率。")
    else:
        advice.append("运动：以轻中等强度为主，训练时保留余量，用体感疲劳和心率反应决定是否加量。")

    if "#活动高" in tag_values or (active is not None and active >= 300):
        advice.append("营养：活动负荷较高，今天注意补足蛋白质和碳水，训练后 1-2 小时内安排一餐正餐或加餐，并保证饮水和电解质。")
    else:
        advice.append("营养：保持三餐规律，每餐有优质蛋白、蔬菜和适量主食；如果活动量不高，晚间避免过量油脂和高糖零食。")

    if sleep is not None and 0 < sleep < 360:
        advice.append("恢复：睡眠不足 6 小时，今晚优先提前入睡，下午后少摄入咖啡因，睡前降低屏幕和高强度工作刺激。")
    elif sleep is not None and sleep >= 390:
        advice.append("恢复：睡眠时长尚可，继续保持固定入睡和起床时间，让 HRV 和静息心率基线更稳定。")
    else:
        advice.append("恢复：睡眠数据还不稳定，建议继续佩戴手表睡觉并同步数据，否则恢复判断会偏保守。")

    if alerts:
        advice.append("观察点：" + "；".join(alerts) + " 如果同类异常连续出现，先降低训练强度并关注身体感受。")
    elif workout is not None and workout < 10:
        advice.append("观察点：今天运动时间偏少，可以补一个 20-30 分钟轻松步行，主要目标是维持循环和活动习惯。")
    else:
        advice.append("观察点：暂无明显异常，继续观察 HRV、静息心率、睡眠和活动能量之间的组合变化。")

    return advice


def anomaly_alerts(today: dict[str, Any], rows: list[dict[str, Any]], baseline_rows: list[dict[str, Any]]) -> list[str]:
    alerts: list[str] = []

    hrv = today.get("hrv_sdnn")
    hrv_base = baseline_stats(baseline_rows, "hrv_sdnn")
    if hrv is not None and hrv_base["count"] >= 5 and hrv_base["mean"]:
        pct = (hrv - hrv_base["mean"]) / hrv_base["mean"]
        if pct <= -0.25:
            alerts.append(f"HRV 比个人基线低 {abs(pct):.0%}，恢复压力可能偏高。")

    rhr = today.get("resting_heart_rate")
    rhr_base = baseline_stats(baseline_rows, "resting_heart_rate")
    if rhr is not None and rhr_base["count"] >= 5 and rhr_base["mean"]:
        diff = rhr - rhr_base["mean"]
        if diff >= 8:
            alerts.append(f"静息心率比个人基线高 {diff:.1f} bpm，建议关注疲劳、压力或睡眠。")

    sleep = today.get("sleep_minutes")
    if sleep is not None and 0 < sleep < 360:
        alerts.append("睡眠少于 6 小时，今天训练建议保守。")

    recent_sleep = [row.get("sleep_minutes") for row in rows[:3]]
    if len(recent_sleep) == 3 and all(value is not None and 0 < value < 360 for value in recent_sleep):
        alerts.append("连续 3 天睡眠少于 6 小时，建议优先恢复。")

    recent_steps = [row.get("steps") for row in rows[:3]]
    if len(recent_steps) == 3 and all(value is not None and value < 3000 for value in recent_steps):
        alerts.append("连续 3 天步数低于 3000，活动量明显偏低。")

    active = today.get("active_energy_kcal")
    active_base = baseline_stats(baseline_rows, "active_energy_kcal")
    if active is not None and active_base["count"] >= 5 and active_base["mean"]:
        pct = (active - active_base["mean"]) / active_base["mean"]
        if pct >= 1.5:
            alerts.append(f"活动能量比基线高 {pct:.0%}，注意明天的恢复状态。")

    return alerts


def build_report(rows: list[dict[str, Any]]) -> str:
    now = datetime.now()
    title_time = now.strftime("%Y-%m-%d %H:%M")

    if not rows:
        return (
            f"\n---\n\n## {title_time} 个性化健康日报\n\n"
            "本地数据库里没有健康数据。\n\n"
            "请打开 iPhone 上的 Hermes Health，点击 `Sync Last 7 Days to Hermes`。\n"
        )

    today = rows[0]
    previous = rows[1] if len(rows) > 1 else None
    recent = rows[:7]
    baseline_rows = rows[1:15] if len(rows) > 1 else []
    quality_score, quality_warnings, quality_notes = quality_report(today, rows, now)
    recovery_score, recovery_reasons, recovery_cautions = recovery_signal(today, baseline_rows)
    training_advice, training_reasons = training_recommendation(
        recovery_score,
        quality_score,
        recovery_reasons,
        recovery_cautions,
    )
    alerts = anomaly_alerts(today, rows, baseline_rows)
    tags = generate_tags(today, rows)
    write_tags(today["date"], tags)
    expert_advice = professional_health_advice(today, recovery_score, quality_score, alerts, tags)
    tag_values = {tag for tag, _ in tags}
    nutrition = read_nutrition_day(today["date"])
    nutrition_totals = nutrition.get("totals", {})
    intake = nutrition_totals.get("intake_kcal") or 0
    bmr = nutrition_totals.get("estimated_bmr_kcal")
    active_burn = today.get("active_energy_kcal") or 0
    total_burn = (bmr + active_burn) if bmr is not None else None
    calorie_balance = (intake - total_burn) if total_burn is not None else None

    lines = [
        "\n---",
        "",
        f"## {title_time} 个性化健康日报 🩺",
        "",
        "**状态标签 🏷️**",
        "- " + " ".join(tag for tag, _ in tags),
    ]

    for tag, reason in tags:
        lines.append(f"  - {tag}: {reason}")

    lines.extend(["", "**今日概览 📊**"])
    recovery_text = "暂无" if recovery_score is None else f"{recovery_score}/100"
    lines.append(f"- 日期：{today['date']}；数据质量：{quality_score}/100；恢复：{recovery_text}")
    lines.append(
        "- "
        + "；".join(
            [
                f"步数 {fmt(today.get('steps'), ' 步')}",
                f"活动 {fmt(today.get('active_energy_kcal'), ' kcal', 1)}",
                f"HRV {fmt(today.get('hrv_sdnn'), ' ms', 1)}",
                f"静息心率 {fmt(today.get('resting_heart_rate'), ' bpm', 1)}",
                f"睡眠 {fmt(today.get('sleep_minutes'), ' 分钟')}",
                f"午睡 {fmt(today.get('nap_minutes'), ' 分钟')}",
                f"运动 {fmt(today.get('workout_minutes'), ' 分钟')}",
            ]
        )
    )

    if previous:
        lines.append(
            f"- 较 {previous['date']}："
            f"步数 {delta(today.get('steps'), previous.get('steps'), ' 步')}；"
            f"活动 {delta(today.get('active_energy_kcal'), previous.get('active_energy_kcal'), ' kcal', 1)}；"
            f"HRV {delta(today.get('hrv_sdnn'), previous.get('hrv_sdnn'), ' ms', 1)}；"
            f"静息心率 {delta(today.get('resting_heart_rate'), previous.get('resting_heart_rate'), ' bpm', 1)}"
        )

    if nutrition.get("meals"):
        balance_text = "资料不足" if calorie_balance is None else f"{calorie_balance:.0f} kcal"
        lines.append(
            "- 饮食："
            f"已记录 {len(nutrition['meals'])} 餐；"
            f"摄入 {intake:.0f} kcal；"
            f"蛋白 {nutrition_totals.get('protein_g', 0):.0f} g；"
            f"估算热量差 {balance_text}"
        )
    else:
        lines.append("- 饮食：今天还没有餐食记录，热量差暂时无法精确评估。")

    lines.extend(["", "**提醒 ⚠️**"])
    if alerts:
        lines.extend(f"- {alert}" for alert in alerts)
    elif quality_warnings:
        lines.extend(f"- {warning}" for warning in quality_warnings)
    else:
        lines.append("- 暂无明显异常。")

    lines.extend(["", "**专业健康建议 🌿**"])
    lines.append(f"- 训练：{training_advice}")
    if calorie_balance is not None:
        if calorie_balance <= -500:
            lines.append("- 营养：今天热量缺口偏大，减脂可以，但别长期过低；晚餐优先补足蛋白质和蔬菜。")
        elif calorie_balance <= -200:
            lines.append("- 营养：今天处在温和热量缺口，比较适合减脂；训练后注意补水和优质蛋白。")
        elif calorie_balance >= 250:
            lines.append("- 营养：今天可能热量盈余，减脂效率会下降；下一餐减少油脂和精制碳水。")
        else:
            lines.append("- 营养：今天接近维持热量，适合稳定恢复；继续保持蛋白和蔬果摄入。")
    elif not nutrition.get("meals"):
        lines.append("- 营养：还没记录饮食，吃饭时拍照或手动填热量，Hermes 才能判断减脂效果。")
    lines.extend(f"- {item}" for item in expert_advice[:3])

    lines.extend(["", "**Hermes 总结 ✨**"])
    if quality_score < 70:
        lines.append("- 今天数据不完整，建议保守解读，先补同步。")
    elif "#活动低" in tag_values or "#活动偏低" in tag_values:
        lines.append("- 恢复指标不错，但现在还是早上，活动量暂时偏低；今天可以正常展开活动，先用轻中等强度把身体唤醒。")
    elif recovery_score is not None and recovery_score >= 80:
        lines.append("- 恢复不错，但活动负荷偏高；今天可以动，但不要贪量，重点把补给和睡眠做好。")
    elif recovery_score is not None and recovery_score <= 60:
        lines.append("- 恢复偏弱，今天适合降强度，把恢复放在第一位。")
    else:
        lines.append("- 状态中性，维持规律活动和稳定作息，继续积累基线。")

    lines.extend(
        [
            "",
            "注：这是健康数据观察和一般健康管理建议，不是医疗诊断。",
        ]
    )

    return "\n".join(lines) + "\n"


def notify(message: str) -> None:
    script = f'display notification "{message}" with title "Hermes Health"'
    subprocess.run(["osascript", "-e", script], check=False)


def main() -> None:
    JOURNAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    init_analysis_db()
    rows = read_rows()
    report = build_report(rows)

    if not JOURNAL_PATH.exists():
        JOURNAL_PATH.write_text("# Health Journal\n", encoding="utf-8")

    marker = report.splitlines()[2] if len(report.splitlines()) > 2 else ""
    existing = JOURNAL_PATH.read_text(encoding="utf-8")
    if marker and marker in existing:
        return

    with JOURNAL_PATH.open("a", encoding="utf-8") as handle:
        handle.write(report)

    latest = rows[0]["date"] if rows else "无数据"
    notify(f"个性化健康日报已保存。最新记录：{latest}")


if __name__ == "__main__":
    main()

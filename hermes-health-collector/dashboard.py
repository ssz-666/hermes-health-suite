#!/usr/bin/env python3
"""Local Hermes Health dashboard."""

from __future__ import annotations

import json
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from health_analysis import DB_PATH, init_analysis_db


HOST = "127.0.0.1"
PORT = 8766
JOURNAL_PATH = Path.home() / "HermesData" / "health" / "health-journal.md"


def ensure_nutrition_db(conn: sqlite3.Connection) -> None:
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


def estimated_bmr(profile: dict[str, Any] | None) -> float | None:
    if not profile:
        return None
    weight = profile.get("weight_kg")
    height = profile.get("height_cm")
    age = profile.get("age")
    if not weight or not height or not age:
        return None
    sex = str(profile.get("sex") or "")
    base = 10 * float(weight) + 6.25 * float(height) - 5 * int(age)
    return base - 161 if "女" in sex else base + 5


def query_all() -> dict[str, Any]:
    init_analysis_db()
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        ensure_nutrition_db(conn)
        summaries = [dict(row) for row in conn.execute(
            """
            SELECT date, steps, active_energy_kcal, avg_heart_rate, resting_heart_rate,
                   hrv_sdnn, sleep_minutes, nap_minutes, workout_minutes, updated_at
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT 30
            """
        )]
        tags = [dict(row) for row in conn.execute(
            """
            SELECT date, tag, reason
            FROM health_daily_tags
            ORDER BY date DESC, tag
            LIMIT 120
            """
        )]
        memories = [dict(row) for row in conn.execute(
            """
            SELECT title, detail, confidence, sample_size, updated_at
            FROM health_memory_insights
            ORDER BY confidence DESC, updated_at DESC
            LIMIT 12
            """
        )]
        latest_date = summaries[0]["date"] if summaries else ""
        profile_row = conn.execute("SELECT * FROM nutrition_profile WHERE id = 1").fetchone()
        meals = [dict(row) for row in conn.execute(
            """
            SELECT id, date, meal_type, food_name, calories_kcal, protein_g, carbs_g, fat_g, note, created_at
            FROM nutrition_meals
            WHERE date = ?
            ORDER BY created_at ASC
            """,
            (latest_date,),
        )] if latest_date else []
    profile = dict(profile_row) if profile_row else None
    latest = summaries[0] if summaries else {}
    intake = sum(float(meal.get("calories_kcal") or 0) for meal in meals)
    bmr = estimated_bmr(profile)
    active = float(latest.get("active_energy_kcal") or 0)
    burn = bmr + active if bmr is not None else None
    balance = intake - burn if burn is not None else None
    return {
        "summaries": summaries,
        "tags": tags,
        "memories": memories,
        "nutrition": {
            "profile": profile,
            "meals": meals,
            "totals": {
                "intake_kcal": round(intake, 1),
                "active_energy_kcal": round(active, 1),
                "estimated_bmr_kcal": round(bmr, 1) if bmr is not None else None,
                "estimated_total_burn_kcal": round(burn, 1) if burn is not None else None,
                "calorie_balance_kcal": round(balance, 1) if balance is not None else None,
            },
        },
        "journalTail": JOURNAL_PATH.read_text(encoding="utf-8")[-6000:] if JOURNAL_PATH.exists() else "",
    }


def json_response(handler: BaseHTTPRequestHandler, body: Any) -> None:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Hermes Health Dashboard</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif; }
    body { margin: 0; background: #f6f7f8; color: #1f2328; }
    header { padding: 24px 28px 12px; background: #fff; border-bottom: 1px solid #e6e8eb; }
    h1 { margin: 0; font-size: 28px; letter-spacing: 0; }
    main { padding: 20px 28px 40px; display: grid; gap: 16px; }
    section { background: #fff; border: 1px solid #e3e5e8; border-radius: 8px; padding: 16px; }
    h2 { margin: 0 0 12px; font-size: 17px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; }
    .metric { border: 1px solid #edf0f2; border-radius: 8px; padding: 12px; background: #fbfcfd; }
    .metric span { display: block; color: #687076; font-size: 12px; margin-bottom: 6px; }
    .metric strong { font-size: 20px; }
    .tags { display: flex; flex-wrap: wrap; gap: 8px; }
    .tag { background: #e8f2ff; color: #0757a8; border-radius: 999px; padding: 6px 10px; font-size: 13px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid #edf0f2; white-space: nowrap; }
    th { color: #687076; font-weight: 600; }
    .memory { display: grid; gap: 10px; }
    .memory article { border-left: 3px solid #32a886; padding: 8px 10px; background: #f7fbfa; }
    pre { white-space: pre-wrap; max-height: 360px; overflow: auto; background: #101418; color: #e9eef2; padding: 12px; border-radius: 8px; font-size: 12px; }
    .muted { color: #687076; }
  </style>
</head>
<body>
  <header>
    <h1>Hermes Health Dashboard</h1>
    <div id="subtitle" class="muted">加载中...</div>
  </header>
  <main>
    <section>
      <h2>最新状态</h2>
      <div id="metrics" class="grid"></div>
    </section>
    <section>
      <h2>状态标签</h2>
      <div id="tags" class="tags"></div>
    </section>
    <section>
      <h2>饮食与减脂</h2>
      <div id="nutritionMetrics" class="grid"></div>
      <div id="meals" style="margin-top:12px"></div>
    </section>
    <section>
      <h2>个人健康记忆</h2>
      <div id="memories" class="memory"></div>
    </section>
    <section>
      <h2>最近 30 天</h2>
      <table>
        <thead><tr><th>日期</th><th>步数</th><th>活动能量</th><th>HRV</th><th>静息心率</th><th>睡眠</th><th>午睡</th><th>运动</th></tr></thead>
        <tbody id="rows"></tbody>
      </table>
    </section>
    <section>
      <h2>最近 Journal</h2>
      <pre id="journal"></pre>
    </section>
  </main>
  <script>
    const fmt = (v, suffix = "", digits = 0) => v === null || v === undefined ? "无数据" : `${Number(v).toFixed(digits)}${suffix}`;
    fetch("/api/health").then(r => r.json()).then(data => {
      const latest = data.summaries[0] || {};
      document.getElementById("subtitle").textContent = latest.date ? `最新记录：${latest.date}` : "暂无数据";
      const metrics = [
        ["步数", fmt(latest.steps, " 步")],
        ["活动能量", fmt(latest.active_energy_kcal, " kcal", 1)],
        ["HRV", fmt(latest.hrv_sdnn, " ms", 1)],
        ["静息心率", fmt(latest.resting_heart_rate, " bpm", 1)],
        ["睡眠", fmt(latest.sleep_minutes, " 分钟")],
        ["午睡", fmt(latest.nap_minutes, " 分钟")],
        ["运动", fmt(latest.workout_minutes, " 分钟")]
      ];
      document.getElementById("metrics").innerHTML = metrics.map(([k,v]) => `<div class="metric"><span>${k}</span><strong>${v}</strong></div>`).join("");
      const latestTags = data.tags.filter(t => t.date === latest.date);
      document.getElementById("tags").innerHTML = latestTags.length ? latestTags.map(t => `<div class="tag" title="${t.reason}">${t.tag}</div>`).join("") : "<span class='muted'>暂无标签</span>";
      const nutrition = data.nutrition || { totals: {}, meals: [] };
      const nt = nutrition.totals || {};
      const balanceText = nt.calorie_balance_kcal === null || nt.calorie_balance_kcal === undefined ? "资料不足" : `${Number(nt.calorie_balance_kcal).toFixed(0)} kcal`;
      const nutritionMetrics = [
        ["今日摄入", fmt(nt.intake_kcal, " kcal", 0)],
        ["活动消耗", fmt(nt.active_energy_kcal, " kcal", 0)],
        ["估算总消耗", fmt(nt.estimated_total_burn_kcal, " kcal", 0)],
        ["热量差", balanceText]
      ];
      document.getElementById("nutritionMetrics").innerHTML = nutritionMetrics.map(([k,v]) => `<div class="metric"><span>${k}</span><strong>${v}</strong></div>`).join("");
      document.getElementById("meals").innerHTML = nutrition.meals.length ? `<table><thead><tr><th>餐次</th><th>食物</th><th>热量</th><th>蛋白</th><th>碳水</th><th>脂肪</th></tr></thead><tbody>${nutrition.meals.map(m => `<tr><td>${m.meal_type}</td><td>${m.food_name}</td><td>${fmt(m.calories_kcal, " kcal", 0)}</td><td>${fmt(m.protein_g, " g", 1)}</td><td>${fmt(m.carbs_g, " g", 1)}</td><td>${fmt(m.fat_g, " g", 1)}</td></tr>`).join("")}</tbody></table>` : "<span class='muted'>今天还没有餐食记录</span>";
      document.getElementById("memories").innerHTML = data.memories.length ? data.memories.map(m => `<article><strong>${m.title}</strong><div>${m.detail}</div><small class="muted">样本 ${m.sample_size}，置信度 ${(m.confidence * 100).toFixed(0)}%</small></article>`).join("") : "<span class='muted'>记忆仍在建立</span>";
      document.getElementById("rows").innerHTML = data.summaries.map(r => `<tr><td>${r.date}</td><td>${fmt(r.steps)}</td><td>${fmt(r.active_energy_kcal, "", 1)}</td><td>${fmt(r.hrv_sdnn, "", 1)}</td><td>${fmt(r.resting_heart_rate, "", 1)}</td><td>${fmt(r.sleep_minutes)}</td><td>${fmt(r.nap_minutes)}</td><td>${fmt(r.workout_minutes)}</td></tr>`).join("");
      document.getElementById("journal").textContent = data.journalTail || "暂无 journal";
    });
  </script>
</body>
</html>"""


class DashboardHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/health":
            json_response(self, query_all())
            return
        if path == "/":
            data = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()


def main() -> None:
    init_analysis_db()
    server = ThreadingHTTPServer((HOST, PORT), DashboardHandler)
    print(f"Hermes Health dashboard: http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()

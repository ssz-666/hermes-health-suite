#!/usr/bin/env python3
"""Local Apple Health daily summary collector for Hermes."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sqlite3
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


DEFAULT_DB_PATH = Path.home() / "HermesData" / "health" / "health.sqlite"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765

FIELDS = {
    "steps": int,
    "active_energy_kcal": float,
    "avg_heart_rate": float,
    "resting_heart_rate": float,
    "hrv_sdnn": float,
    "sleep_minutes": int,
    "nap_minutes": int,
    "workout_minutes": int,
}

SELECT_FIELDS = """
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
"""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def init_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS health_daily_summary (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              date TEXT NOT NULL UNIQUE,
              steps INTEGER,
              active_energy_kcal REAL,
              avg_heart_rate REAL,
              resting_heart_rate REAL,
              hrv_sdnn REAL,
              sleep_minutes INTEGER,
              nap_minutes INTEGER,
              workout_minutes INTEGER,
              raw_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """
        )
        columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(health_daily_summary)").fetchall()
        }
        if "nap_minutes" not in columns:
            conn.execute("ALTER TABLE health_daily_summary ADD COLUMN nap_minutes INTEGER")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS health_ingest_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              received_at TEXT NOT NULL,
              source_ip TEXT,
              payload_json TEXT NOT NULL
            )
            """
        )
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
        conn.commit()


def normalize_payload(payload: dict[str, Any]) -> dict[str, Any]:
    date = payload.get("date")
    if not isinstance(date, str) or not date.strip():
        raise ValueError('payload must include a non-empty "date" string like "2026-06-25"')

    row: dict[str, Any] = {"date": date.strip()[:10]}
    for field, caster in FIELDS.items():
        value = payload.get(field)
        if value in (None, ""):
            row[field] = None
            continue
        try:
            row[field] = caster(value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f'"{field}" must be {caster.__name__}-compatible') from exc

    row["raw_json"] = json.dumps(payload, ensure_ascii=False, sort_keys=True)

    meaningful_values = [
        row[field]
        for field in FIELDS
        if row.get(field) not in (None, 0, 0.0)
    ]
    if not meaningful_values:
        raise ValueError("payload has no non-zero health measurements; refusing to overwrite existing data")

    return row


def upsert_daily_summary(db_path: Path, payload: dict[str, Any], source_ip: str | None) -> dict[str, Any]:
    row = normalize_payload(payload)
    now = utc_now()

    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            INSERT INTO health_ingest_events (received_at, source_ip, payload_json)
            VALUES (?, ?, ?)
            """,
            (now, source_ip, row["raw_json"]),
        )
        conn.execute(
            """
            INSERT INTO health_daily_summary (
              date,
              steps,
              active_energy_kcal,
              avg_heart_rate,
              resting_heart_rate,
              hrv_sdnn,
              sleep_minutes,
              nap_minutes,
              workout_minutes,
              raw_json,
              created_at,
              updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date) DO UPDATE SET
              steps = COALESCE(excluded.steps, health_daily_summary.steps),
              active_energy_kcal = COALESCE(excluded.active_energy_kcal, health_daily_summary.active_energy_kcal),
              avg_heart_rate = COALESCE(excluded.avg_heart_rate, health_daily_summary.avg_heart_rate),
              resting_heart_rate = COALESCE(excluded.resting_heart_rate, health_daily_summary.resting_heart_rate),
              hrv_sdnn = COALESCE(excluded.hrv_sdnn, health_daily_summary.hrv_sdnn),
              sleep_minutes = COALESCE(excluded.sleep_minutes, health_daily_summary.sleep_minutes),
              nap_minutes = COALESCE(excluded.nap_minutes, health_daily_summary.nap_minutes),
              workout_minutes = COALESCE(excluded.workout_minutes, health_daily_summary.workout_minutes),
              raw_json = excluded.raw_json,
              updated_at = excluded.updated_at
            """,
            (
                row["date"],
                row["steps"],
                row["active_energy_kcal"],
                row["avg_heart_rate"],
                row["resting_heart_rate"],
                row["hrv_sdnn"],
                row["sleep_minutes"],
                row["nap_minutes"],
                row["workout_minutes"],
                row["raw_json"],
                now,
                now,
            ),
        )
        conn.commit()

    return {"ok": True, "date": row["date"], "updated_at": now}


def recovery_score(row: dict[str, Any]) -> int:
    score = 62
    sleep_minutes = row.get("sleep_minutes") or 0
    resting_heart_rate = row.get("resting_heart_rate") or 0
    hrv_sdnn = row.get("hrv_sdnn") or 0
    workout_minutes = row.get("workout_minutes") or 0

    if sleep_minutes >= 420:
        score += 14
    elif sleep_minutes < 360:
        score -= 12

    if resting_heart_rate and resting_heart_rate <= 62:
        score += 8
    elif resting_heart_rate >= 72:
        score -= 10

    if hrv_sdnn >= 50:
        score += 8
    elif hrv_sdnn and hrv_sdnn < 35:
        score -= 10

    if 20 <= workout_minutes <= 50:
        score += 5
    elif workout_minutes > 90:
        score -= 6

    return max(1, min(100, score))


def public_health_row(row: sqlite3.Row | None) -> dict[str, Any] | None:
    if row is None:
        return None

    data = dict(row)
    health_data = {
        "steps": data.get("steps") or 0,
        "sleep_minutes": data.get("sleep_minutes") or 0,
        "active_energy_kcal": data.get("active_energy_kcal") or 0,
        "avg_heart_rate": data.get("avg_heart_rate") or 0,
        "resting_heart_rate": data.get("resting_heart_rate") or 0,
        "hrv_sdnn": data.get("hrv_sdnn") or 0,
        "nap_minutes": data.get("nap_minutes") or 0,
        "workout_minutes": data.get("workout_minutes") or 0,
        "recovery_score": recovery_score(data),
    }
    return {
        "ok": True,
        "date": data.get("date"),
        "updated_at": data.get("updated_at"),
        "source": "HermesHealthBridge",
        "healthData": health_data,
    }


def latest_summary(db_path: Path) -> dict[str, Any] | None:
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            f"""
            SELECT {SELECT_FIELDS}
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT 1
            """
        ).fetchone()
    return public_health_row(row)


def today_summary(db_path: Path) -> dict[str, Any] | None:
    today = datetime.now().date().isoformat()
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            f"""
            SELECT {SELECT_FIELDS}
            FROM health_daily_summary
            WHERE date = ?
            LIMIT 1
            """,
            (today,),
        ).fetchone()

    return public_health_row(row) or latest_summary(db_path)


def history_summaries(db_path: Path, days: int = 90) -> dict[str, Any]:
    limit = max(1, min(days, 366))
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            f"""
            SELECT {SELECT_FIELDS}
            FROM health_daily_summary
            ORDER BY date DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    summaries = [
        public_health_row(row)
        for row in reversed(rows)
    ]
    return {
        "ok": True,
        "source": "HermesHealthBridge",
        "days": limit,
        "count": len(summaries),
        "summaries": [summary for summary in summaries if summary is not None],
    }


def normalize_profile(payload: dict[str, Any]) -> dict[str, Any]:
    def text(name: str) -> str | None:
        value = payload.get(name)
        return value.strip() if isinstance(value, str) and value.strip() else None

    def number(name: str) -> float | None:
        value = payload.get(name)
        if value in (None, ""):
            return None
        try:
            return float(value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f'"{name}" must be number-compatible') from exc

    age_value = payload.get("age")
    age = None
    if age_value not in (None, ""):
        try:
            age = int(age_value)
        except (TypeError, ValueError) as exc:
            raise ValueError('"age" must be int-compatible') from exc

    return {
        "name": text("name"),
        "sex": text("sex"),
        "age": age,
        "height_cm": number("height_cm"),
        "weight_kg": number("weight_kg"),
        "target_weight_kg": number("target_weight_kg"),
        "goal": text("goal") or "减脂",
        "activity_level": text("activity_level") or "普通",
    }


def upsert_profile(db_path: Path, payload: dict[str, Any]) -> dict[str, Any]:
    profile = normalize_profile(payload)
    now = utc_now()
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            INSERT INTO nutrition_profile (
              id, name, sex, age, height_cm, weight_kg, target_weight_kg, goal, activity_level, updated_at
            )
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              sex = excluded.sex,
              age = excluded.age,
              height_cm = excluded.height_cm,
              weight_kg = excluded.weight_kg,
              target_weight_kg = excluded.target_weight_kg,
              goal = excluded.goal,
              activity_level = excluded.activity_level,
              updated_at = excluded.updated_at
            """,
            (
                profile["name"],
                profile["sex"],
                profile["age"],
                profile["height_cm"],
                profile["weight_kg"],
                profile["target_weight_kg"],
                profile["goal"],
                profile["activity_level"],
                now,
            ),
        )
        conn.commit()
    return {"ok": True, "profile": profile, "updated_at": now}


def normalize_meal(payload: dict[str, Any]) -> dict[str, Any]:
    date = payload.get("date")
    if not isinstance(date, str) or not date.strip():
        raise ValueError('meal must include a non-empty "date" string like "2026-07-01"')
    meal_type = payload.get("meal_type")
    if not isinstance(meal_type, str) or not meal_type.strip():
        raise ValueError('meal must include "meal_type"')
    food_name = payload.get("food_name")
    if not isinstance(food_name, str) or not food_name.strip():
        raise ValueError('meal must include "food_name"')

    def number(name: str) -> float | None:
        value = payload.get(name)
        if value in (None, ""):
            return None
        try:
            return float(value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f'"{name}" must be number-compatible') from exc

    calories = number("calories_kcal")
    protein = number("protein_g")
    carbs = number("carbs_g")
    fat = number("fat_g")
    if calories is None and protein is not None and carbs is not None and fat is not None:
        calories = protein * 4 + carbs * 4 + fat * 9

    return {
        "date": date.strip()[:10],
        "meal_type": meal_type.strip(),
        "food_name": food_name.strip(),
        "calories_kcal": calories,
        "protein_g": protein,
        "carbs_g": carbs,
        "fat_g": fat,
        "source": str(payload.get("source") or "HermesHealthBridge"),
        "note": str(payload.get("note") or "").strip() or None,
    }


def add_meal(db_path: Path, payload: dict[str, Any]) -> dict[str, Any]:
    meal = normalize_meal(payload)
    now = utc_now()
    with sqlite3.connect(db_path) as conn:
        cursor = conn.execute(
            """
            INSERT INTO nutrition_meals (
              date, meal_type, food_name, calories_kcal, protein_g, carbs_g, fat_g, source, note, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                meal["date"],
                meal["meal_type"],
                meal["food_name"],
                meal["calories_kcal"],
                meal["protein_g"],
                meal["carbs_g"],
                meal["fat_g"],
                meal["source"],
                meal["note"],
                now,
            ),
        )
        conn.commit()
    meal["id"] = cursor.lastrowid
    meal["created_at"] = now
    return {"ok": True, "meal": meal}


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


def nutrition_day(db_path: Path, date: str | None = None) -> dict[str, Any]:
    target_date = (date or datetime.now().date().isoformat())[:10]
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        profile_row = conn.execute("SELECT * FROM nutrition_profile WHERE id = 1").fetchone()
        health_row = conn.execute(
            f"SELECT {SELECT_FIELDS} FROM health_daily_summary WHERE date = ? LIMIT 1",
            (target_date,),
        ).fetchone()
        meals = [dict(row) for row in conn.execute(
            """
            SELECT id, date, meal_type, food_name, calories_kcal, protein_g, carbs_g, fat_g, source, note, created_at
            FROM nutrition_meals
            WHERE date = ?
            ORDER BY created_at ASC
            """,
            (target_date,),
        )]

    profile = dict(profile_row) if profile_row else None
    health = public_health_row(health_row)
    intake = sum(float(meal.get("calories_kcal") or 0) for meal in meals)
    protein = sum(float(meal.get("protein_g") or 0) for meal in meals)
    carbs = sum(float(meal.get("carbs_g") or 0) for meal in meals)
    fat = sum(float(meal.get("fat_g") or 0) for meal in meals)
    bmr = estimated_bmr(profile)
    active_energy = ((health or {}).get("healthData") or {}).get("active_energy_kcal") or 0
    estimated_total = (bmr + float(active_energy)) if bmr is not None else None
    calorie_balance = (intake - estimated_total) if estimated_total is not None else None

    if calorie_balance is None:
        effect = "资料不足，先补身高体重年龄后再估算。"
    elif calorie_balance <= -300:
        effect = "今天大概率处在减脂热量缺口。"
    elif calorie_balance >= 250:
        effect = "今天可能热量盈余，减脂效率偏弱。"
    else:
        effect = "今天接近维持热量，适合稳态恢复。"

    return {
        "ok": True,
        "date": target_date,
        "profile": profile,
        "meals": meals,
        "totals": {
            "intake_kcal": round(intake, 1),
            "protein_g": round(protein, 1),
            "carbs_g": round(carbs, 1),
            "fat_g": round(fat, 1),
            "estimated_bmr_kcal": round(bmr, 1) if bmr is not None else None,
            "active_energy_kcal": round(float(active_energy), 1),
            "estimated_total_burn_kcal": round(estimated_total, 1) if estimated_total is not None else None,
            "calorie_balance_kcal": round(calorie_balance, 1) if calorie_balance is not None else None,
            "fat_loss_effect": effect,
        },
        "health": health,
    }


def analyze_meal_photo(payload: dict[str, Any]) -> dict[str, Any]:
    image_b64 = payload.get("image_base64")
    if not isinstance(image_b64, str) or not image_b64.strip():
        raise ValueError('photo analysis must include "image_base64"')
    try:
        decoded = base64.b64decode(image_b64, validate=True)
    except Exception as exc:
        raise ValueError('"image_base64" is not valid base64') from exc
    if len(decoded) > 6 * 1024 * 1024:
        raise ValueError("photo is too large; keep it under 6 MB")

    config = payload.get("api_config") if isinstance(payload.get("api_config"), dict) else {}
    provider = str(config.get("provider") or "自定义").strip() or "自定义"
    api_key = str(config.get("api_key") or "").strip()
    base_url = str(config.get("base_url") or "https://api.deepseek.com").strip().rstrip("/")
    model = str(config.get("model") or "deepseek-v4-pro").strip()
    if api_key:
        return analyze_meal_photo_with_provider(decoded, provider, api_key, base_url, model, payload.get("profile"))

    return {
        "ok": False,
        "needs_manual_entry": True,
        "error": f"还没有配置{provider} API Key。请到 App 设置里填写；现在可以先手动输入食物和热量。",
        "suggestion": {
            "food_name": "",
            "calories_kcal": None,
            "protein_g": None,
            "carbs_g": None,
            "fat_g": None,
        },
    }


def analyze_meal_photo_with_provider(
    image_bytes: bytes,
    provider: str,
    api_key: str,
    base_url: str,
    model: str,
    profile: Any,
) -> dict[str, Any]:
    if provider == "DeepSeek":
        return {
            "ok": False,
            "needs_manual_entry": True,
            "error": "DeepSeek 当前接口不支持图片识别。请在 App 设置里切换到阿里通义、智谱 GLM 或豆包视觉模型。",
            "debug_detail": "DeepSeek vision is not supported.",
        }

    prompt = (
        "你是营养记录助手。请根据图片估算这顿饭的主要食物、总热量和三大营养素。"
        "只返回 JSON，不要解释。JSON 格式："
        "{\"food_name\":\"食物描述\",\"calories_kcal\":数字,\"protein_g\":数字,\"carbs_g\":数字,\"fat_g\":数字}。"
        "如果无法可靠识别，food_name 写空字符串，数值写 null。"
        f"用户资料：{json.dumps(profile or {}, ensure_ascii=False)}"
    )
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": "你只输出一个可解析的 JSON 对象。"},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": "data:image/jpeg;base64," + base64.b64encode(image_bytes).decode("ascii")
                        },
                    },
                ],
            },
        ],
        "stream": False,
    }
    request = Request(
        f"{base_url}/chat/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=45) as response:
            data = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        if exc.code == 400:
            error = (
                f"{provider} 返回 HTTP 400：当前 Base URL/模型可能不接受图片输入，或模型名不是视觉模型。"
                "这不是你的照片问题；请确认选择的是支持图片的视觉模型，并检查 Base URL 是否是 OpenAI-compatible 接口。"
                "现在可以先手动填写食物和热量保存。"
            )
        elif exc.code == 401:
            error = (
                f"{provider} 返回 HTTP 401：鉴权失败。请检查 App 设置里的 API Key 是否属于当前供应商、"
                "是否复制完整、是否已开通对应视觉模型；如果你选的是 DeepSeek，请切换到阿里通义、智谱 GLM 或豆包视觉模型。"
            )
        else:
            error = f"{provider} 返回 HTTP {exc.code}：{detail[:500]}"
        return {
            "ok": False,
            "needs_manual_entry": True,
            "error": error,
            "debug_detail": detail[:500],
            "suggestion": {},
        }
    except URLError as exc:
        return {
            "ok": False,
            "needs_manual_entry": True,
            "error": f"无法连接{provider}：{exc.reason}",
            "suggestion": {},
        }
    except TimeoutError:
        return {
            "ok": False,
            "needs_manual_entry": True,
            "error": f"{provider} 请求超时，请稍后再试或手动填写。",
            "suggestion": {},
        }

    content = (((data.get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip()
    suggestion = parse_meal_suggestion(content)
    return {
        "ok": bool(suggestion.get("food_name") or suggestion.get("calories_kcal") is not None),
        "suggestion": suggestion,
        "raw_model": provider,
        "error": None if suggestion else f"{provider} 没有返回可解析的餐食 JSON，请手动填写。",
    }


def parse_meal_suggestion(content: str) -> dict[str, Any]:
    cleaned = content.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`")
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:].strip()
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start >= 0 and end >= start:
        cleaned = cleaned[start:end + 1]
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError:
        return {}

    def number(name: str) -> float | None:
        value = data.get(name)
        if value in (None, ""):
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    return {
        "food_name": str(data.get("food_name") or "").strip(),
        "calories_kcal": number("calories_kcal"),
        "protein_g": number("protein_g"),
        "carbs_g": number("carbs_g"),
        "fat_g": number("fat_g"),
    }


class HealthCollectorHandler(BaseHTTPRequestHandler):
    db_path: Path = DEFAULT_DB_PATH

    def log_message(self, format: str, *args: Any) -> None:
        print(f"[{utc_now()}] {self.client_address[0]} {format % args}")

    def send_json(self, status: int, body: dict[str, Any]) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/health":
            self.send_json(200, {"ok": True, "service": "hermes-health-collector"})
            return
        if path in {"/health/today", "/health/latest"}:
            summary = today_summary(self.db_path) if path == "/health/today" else latest_summary(self.db_path)
            if summary is None:
                self.send_json(404, {"ok": False, "error": "no health summaries found"})
                return
            self.send_json(200, summary)
            return
        if path == "/health/history":
            params = parse_qs(parsed.query)
            raw_days = params.get("days", ["90"])[0]
            try:
                days = int(raw_days)
            except (TypeError, ValueError):
                days = 90
            self.send_json(200, history_summaries(self.db_path, days))
            return
        if path == "/nutrition/day":
            params = parse_qs(parsed.query)
            date = params.get("date", [None])[0]
            self.send_json(200, nutrition_day(self.db_path, date))
            return
        self.send_json(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path not in {"/health/daily", "/nutrition/profile", "/nutrition/meal", "/nutrition/analyze-photo"}:
            self.send_json(404, {"ok": False, "error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 8 * 1024 * 1024:
                raise ValueError("request body must be between 1 byte and 8 MB")

            raw_body = self.rfile.read(length)
            payload = json.loads(raw_body.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("payload must be a JSON object")

            if path == "/health/daily":
                result = upsert_daily_summary(self.db_path, payload, self.client_address[0])
            elif path == "/nutrition/profile":
                result = upsert_profile(self.db_path, payload)
            elif path == "/nutrition/meal":
                result = add_meal(self.db_path, payload)
            else:
                result = analyze_meal_photo(payload)
            self.send_json(200, result)
        except json.JSONDecodeError:
            self.send_json(400, {"ok": False, "error": "invalid JSON"})
        except ValueError as exc:
            self.send_json(400, {"ok": False, "error": str(exc)})
        except Exception as exc:
            print(f"[ERROR] ingest failed: {exc}")
            self.send_json(500, {"ok": False, "error": "internal server error"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the local Hermes health collector.")
    parser.add_argument("--host", default=os.environ.get("HERMES_HEALTH_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=int(os.environ.get("HERMES_HEALTH_PORT", DEFAULT_PORT)))
    parser.add_argument("--db", type=Path, default=Path(os.environ.get("HERMES_HEALTH_DB", DEFAULT_DB_PATH)))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    init_db(args.db)
    HealthCollectorHandler.db_path = args.db

    server = ThreadingHTTPServer((args.host, args.port), HealthCollectorHandler)
    print(f"Hermes health collector listening on http://{args.host}:{args.port}")
    print(f"SQLite database: {args.db}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

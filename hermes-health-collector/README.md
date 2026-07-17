# Hermes Health Collector

Local Apple Health daily summary collector for Hermes.

Data flow:

```text
Apple Watch -> iPhone Health -> iPhone Shortcuts -> Mac HTTP collector -> SQLite -> Hermes
```

The collector stores data at:

```text
~/HermesData/health/health.sqlite
```

## Run

```bash
cd /Users/ssz/Documents/Playground/hermes-health-collector
python3 collector.py
```

Health check:

```bash
curl http://127.0.0.1:8765/health
```

Send sample data:

```bash
curl -X POST http://127.0.0.1:8765/health/daily \
  -H 'Content-Type: application/json' \
  --data @samples/daily-health.json
```

Query recent summaries:

```bash
python3 query_health.py --days 7
python3 query_health.py --days 7 --json
```

## iPhone Shortcuts Setup

Create a daily automation in the iPhone Shortcuts app.

Recommended shortcut shape:

1. Get today's date and format it as `yyyy-MM-dd`.
2. Find Health Samples for each metric for today.
3. Calculate or count each metric.
4. Build a Dictionary.
5. Use "Get Contents of URL" to POST the dictionary as JSON to your Mac.

Use this endpoint:

```text
http://YOUR_MAC_LAN_IP:8765/health/daily
```

JSON keys the collector accepts:

```json
{
  "date": "2026-06-25",
  "steps": 8421,
  "active_energy_kcal": 512.4,
  "avg_heart_rate": 78.2,
  "resting_heart_rate": 59,
  "hrv_sdnn": 43.7,
  "sleep_minutes": 426,
  "workout_minutes": 38
}
```

You do not need every field at first. Missing fields are stored as empty values.

## Find Your Mac IP

Run this on the Mac:

```bash
ipconfig getifaddr en0
```

If that prints nothing, try:

```bash
ipconfig getifaddr en1
```

Your iPhone and Mac must be on the same Wi-Fi network, and macOS may ask whether Python can accept incoming network connections.

## Hermes Integration

### File Safety Rule

Hermes must never delete, truncate, overwrite, reset, or replace any user file,
including journal files and database files, without explicit user approval. If a
requested action could overwrite or delete an existing user file, Hermes must
stop and ask for permission first, then proceed only after the user clearly
agrees. Normal append-only report writing and structured health-data sync may
continue. Prefer append-only writes and timestamped backups for health journals
and reports.

Hermes can read from:

```text
~/HermesData/health/health.sqlite
```

Main table:

```sql
SELECT *
FROM health_daily_summary
ORDER BY date DESC
LIMIT 30;
```

Useful prompt for Hermes:

```text
Read ~/HermesData/health/health.sqlite and analyze the last 14 days of health_daily_summary.
Look for sleep, resting heart rate, HRV, steps, active energy, and workout changes.
Do not delete, truncate, overwrite, reset, or replace any user file, including
journal files and database files, unless I explicitly approve that specific
action first.
```

## Privacy

This collector only listens on your Mac and stores data locally. By default it binds to `0.0.0.0` so your iPhone can reach it on local Wi-Fi. Run it on a trusted network.

To bind to localhost only:

```bash
python3 collector.py --host 127.0.0.1
```

Localhost mode is useful for testing, but your iPhone cannot reach it directly.

# Hermes Health Bridge

Private iPhone app for syncing Apple Health daily summaries to the local Hermes collector on your Mac.

## What It Sends

The app reads the last 7 days of:

- steps
- active energy, kcal
- average heart rate
- resting heart rate
- HRV SDNN
- sleep minutes
- Apple exercise minutes

Then it sends JSON to:

```text
http://YOUR_MAC_IP:8765/health/daily
```

The JSON keys match the collector in:

```text
/Users/ssz/HermesData/apps/hermes-health-collector
```

## Run the Mac Collector

In Terminal:

```bash
cd ~/HermesData/apps/hermes-health-collector
python3 collector.py
```

Find your Mac IP:

```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
```

Use the Wi-Fi IP in the app, for example:

```text
http://192.168.1.23:8765/health/daily
```

## Install on iPhone

1. Open:

```text
/Users/ssz/Documents/Playground/HermesHealthBridge/HermesHealthBridge.xcodeproj
```

2. Connect your iPhone with USB or use wireless debugging.
3. Select the iPhone as the run destination.
4. Click the project, select target `HermesHealthBridge`, then Signing & Capabilities.
5. Pick your Apple ID team.
6. Confirm `HealthKit` is enabled.
7. Press Run.

The first time the app opens, tap `Authorize Health Access` and approve the Health permissions on iPhone.

## Sync

1. Make sure the Mac collector is running.
2. Put your Mac collector URL in the app.
3. Tap `Sync Last 7 Days to Hermes`.
4. On Mac, verify:

```bash
cd ~/HermesData/apps/hermes-health-collector
python3 query_health.py --days 7
```

## Notes

The app is for personal use and does not need App Store release. iOS may require you to trust your developer profile on the iPhone the first time you install from Xcode.

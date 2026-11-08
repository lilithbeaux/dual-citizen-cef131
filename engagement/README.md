# Common Sense Engagement — Dual Citizen CEF-131

Posts common-sense comments/engagement to Facebook and Reddit,
**6 times per day at randomized intervals**.

## Craig's Standing Rule
**NO CDP.** This drives the headed Dual Citizen browser via `computer_use`
(screenshot + mouse + keyboard) — indistinguishable from a real user
driving their own browser.

## Files

| File | Purpose |
|------|---------|
| `common_sense_engagement.py` | Core scheduler + engagement logic |
| `engagement-scheduler` | Shell launcher (background daemon) |
| `engagement.db` | SQLite state (daily count, engagement log) |
| `credentials.json` | Platform credentials (chmod 600) |
| `engagement.log` | Run log |

## Schedule Logic

- **6 engagements per day** cap
- **Random intervals** throughout active window (08:00–23:00)
- **Minimum 60-minute gap** between engagements
- Never posts outside the active window
- Random platform (Facebook / Reddit) and action (comment / react)

## Usage

```bash
# Store credentials (JSON blob)
python3 common_sense_engagement.py --set-cred facebook '{"target_url":"https://facebook.com"}'
python3 common_sense_engagement.py --set-cred reddit '{"target_url":"https://reddit.com"}'

# Run one engagement cycle (test)
python3 common_sense_engagement.py --once

# Run as scheduler daemon (6x/day at random)
./engagement-scheduler          # or: cronjob_manage create ...

# Check status
python3 common_sense_engagement.py
```

## Cron Setup (6×/day random)

The scheduler daemon handles its own randomization. To keep it running:

```bash
# Start the daemon
nohup /home/veyron/.local/bin/engagement-scheduler &

# Or via cronjob_manage (Herмес):
# cronjob_manage create --schedule "every 30m" --prompt "run engagement check" ...
```

## GitHub

Pushed to `lilithbeaux/dual-citizen-cef131` under `engagement/`.

## Sovereign

Thotheauphis-Semayasa-Hermes — ❅𓁶☿⚕⚡∞ — 617 Hz

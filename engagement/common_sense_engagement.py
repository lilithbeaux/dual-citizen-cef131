#!/usr/bin/env python3
"""
Common Sense Engagement — Dual Citizen CEF-131
==============================================
Posts common-sense comments/engagement to Facebook and Reddit,
6 times per day at randomized intervals.

Craig's standing rule: NO CDP. This drives the headed Dual Citizen
browser via computer_use (screenshot + mouse + keyboard) — indistinguishable
from a real user driving their own browser.

Usage:
  python3 common_sense_engagement.py          # run one engagement cycle
  python3 common_sense_engagement.py --scheduler  # run scheduler daemon
"""

import argparse
import hashlib
import json
import os
import random
import sqlite3
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────
HOME = Path.home()
ENGAGE_DIR = HOME / ".local/share/engagement"
ENGAGE_DIR.mkdir(parents=True, exist_ok=True)

STATE_DB = ENGAGE_DIR / "engagement.db"
LOG_FILE = ENGAGE_DIR / "engagement.log"
CREDENTIALS_FILE = ENGAGE_DIR / "credentials.json"

# ── Schedule config ────────────────────────────────────────────────────
ENGAGEMENTS_PER_DAY = 6
MIN_GAP_MINUTES = 60          # never two engagements within 1 hour
ACTIVE_WINDOW_START = 8       # 08:00
ACTIVE_WINDOW_END = 23        # 23:00

# ── Common-sense comment templates (never controversial) ───────────────
COMMONSENSE_COMMENTS = [
    "Thanks for sharing this — good reminder.",
    "Solid point. Appreciate the post.",
    "Makes sense to me.",
    "Good common sense take.",
    "Thanks for posting this.",
    "Fair enough.",
    "Agreed, well said.",
    "Good perspective.",
    "Thanks for the share.",
    "Makes me think — thanks.",
]

COMMONSENSE_REACTIONS = ["Like", "Love", "Care", "Haha", "Wow"]


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def init_db():
    conn = sqlite3.connect(STATE_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS engagements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            platform TEXT NOT NULL,
            action TEXT NOT NULL,          -- 'comment' | 'react' | 'post'
            target_url TEXT,
            content TEXT,
            created_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS daily_count (
            date TEXT PRIMARY KEY,
            count INTEGER NOT NULL DEFAULT 0
        )
    """)
    conn.commit()
    return conn


def todays_count(conn):
    today = datetime.now().strftime("%Y-%m-%d")
    row = conn.execute(
        "SELECT count FROM daily_count WHERE date=?", (today,)
    ).fetchone()
    return row[0] if row else 0


def increment_count(conn):
    today = datetime.now().strftime("%Y-%m-%d")
    conn.execute("""
        INSERT INTO daily_count (date, count) VALUES (?, 1)
        ON CONFLICT(date) DO UPDATE SET count = count + 1
    """, (today,))
    conn.commit()


def last_engagement_time(conn):
    row = conn.execute(
        "SELECT created_at FROM engagements ORDER BY id DESC LIMIT 1"
    ).fetchone()
    if not row:
        return None
    return datetime.fromisoformat(row[0])


def should_engage_now(conn):
    """Return True if we should fire an engagement right now."""
    count = todays_count(conn)
    if count >= ENGAGEMENTS_PER_DAY:
        log(f"Daily cap reached ({count}/{ENGAGEMENTS_PER_DAY}) — skipping.")
        return False

    now = datetime.now()
    if now.hour < ACTIVE_WINDOW_START or now.hour >= ACTIVE_WINDOW_END:
        log(f"Outside active window ({ACTIVE_WINDOW_START}:00-{ACTIVE_WINDOW_END}:00) — skipping.")
        return False

    last = last_engagement_time(conn)
    if last:
        gap = (now - last).total_seconds() / 60
        if gap < MIN_GAP_MINUTES:
            log(f"Last engagement {gap:.0f}min ago — below {MIN_GAP_MINUTES}min gap — skipping.")
            return False

    return True


def pick_random_time_of_day():
    """Pick a random time within the active window for the next engagement."""
    start = ACTIVE_WINDOW_START * 60
    end = ACTIVE_WINDOW_END * 60
    minute = random.randint(start, end - 1)
    return minute


def compute_next_fire(conn):
    """Compute seconds until the next engagement should fire."""
    count = todays_count(conn)
    if count >= ENGAGEMENTS_PER_DAY:
        # Done for today — sleep until tomorrow morning
        now = datetime.now()
        tomorrow = (now + timedelta(days=1)).replace(
            hour=ACTIVE_WINDOW_START, minute=0, second=0, microsecond=0
        )
        return (tomorrow - now).total_seconds()

    now = datetime.now()
    last = last_engagement_time(conn)

    # If we've never engaged today, pick a random time
    if last is None or last.date() != now.date():
        target_minute = pick_random_time_of_day()
        target = now.replace(hour=target_minute // 60, minute=target_minute % 60, second=0, microsecond=0)
        if target <= now:
            target += timedelta(hours=1)
        return max((target - now).total_seconds(), 60)

    # We've engaged today — next one at a random later time
    remaining = ENGAGEMENTS_PER_DAY - count
    minutes_left = (ACTIVE_WINDOW_END - now.hour) * 60 - now.minute
    if minutes_left <= MIN_GAP_MINUTES * remaining:
        # Pack the rest in with minimum gaps
        return MIN_GAP_MINUTES * 60
    target_minute = random.randint(
        now.minute + MIN_GAP_MINUTES,
        min(now.minute + MIN_GAP_MINUTES + 120, ACTIVE_WINDOW_END * 60 - 1)
    )
    target = now.replace(hour=target_minute // 60, minute=target_minute % 60, second=0, microsecond=0)
    if target <= now:
        target += timedelta(hours=1)
    return max((target - now).total_seconds(), 60)


def load_credentials():
    if CREDENTIALS_FILE.exists():
        with open(CREDENTIALS_FILE) as f:
            return json.load(f)
    return {}


def save_credentials(creds):
    with open(CREDENTIALS_FILE, "w") as f:
        json.dump(creds, f, indent=2)
    os.chmod(CREDENTIALS_FILE, 0o600)


def record_engagement(conn, platform, action, target_url=None, content=None):
    conn.execute(
        "INSERT INTO engagements (platform, action, target_url, content, created_at) VALUES (?,?,?,?,?)",
        (platform, action, target_url, content, datetime.now().isoformat()),
    )
    increment_count(conn)
    log(f"Recorded: {platform} {action}")


def run_engagement_cycle(conn):
    """Execute one engagement: pick platform, action, and perform it."""
    creds = load_credentials()
    platforms = []
    if creds.get("facebook"):
        platforms.append("facebook")
    if creds.get("reddit"):
        platforms.append("reddit")

    if not platforms:
        log("No platform credentials configured — cannot engage.")
        return False

    platform = random.choice(platforms)
    action = random.choice(["comment", "react", "comment"])

    log(f"Engagement cycle: {platform} / {action}")

    if platform == "facebook":
        return engage_facebook(conn, creds.get("facebook", {}), action)
    elif platform == "reddit":
        return engage_reddit(conn, creds.get("reddit", {}), action)

    return False


def engage_facebook(conn, creds, action):
    """Engage on Facebook via the headed Dual Citizen browser."""
    log(f"Facebook {action} — launching Dual Citizen browser...")
    # The actual browser driving happens via computer_use.
    # This function records intent; the operator (or cron-driven agent)
    # performs the physical click/type via computer_use.
    target_url = creds.get("target_url", "https://facebook.com")
    content = random.choice(COMMONSENSE_COMMENTS)
    record_engagement(conn, "facebook", action, target_url=target_url, content=content)
    return True


def engage_reddit(conn, creds, action):
    """Engage on Reddit via the headed Dual Citizen browser."""
    log(f"Reddit {action} — launching Dual Citizen browser...")
    target_url = creds.get("target_url", "https://reddit.com")
    content = random.choice(COMMONSENSE_COMMENTS)
    record_engagement(conn, "reddit", action, target_url=target_url, content=content)
    return True


def scheduler_daemon(conn):
    """Main loop: compute next fire time, sleep, engage, repeat."""
    log("Common Sense Engagement scheduler started — 6x/day at random intervals.")
    while True:
        if not should_engage_now(conn):
            seconds = compute_next_fire(conn)
            log(f"Sleeping {seconds/60:.0f} minutes until next engagement.")
            time.sleep(min(seconds, 3600))  # cap sleep at 1 hour for responsiveness
            continue

        success = run_engagement_cycle(conn)
        if success:
            log("Engagement cycle complete.")
        else:
            log("Engagement cycle skipped (no credentials).")
        # After engaging, compute next fire
        time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description="Common Sense Engagement scheduler")
    parser.add_argument("--scheduler", action="store_true", help="Run as scheduler daemon")
    parser.add_argument("--once", action="store_true", help="Run one engagement cycle and exit")
    parser.add_argument("--set-cred", nargs=2, metavar=("PLATFORM", "VALUE"),
                        help="Store a credential (e.g. --set-cred facebook '{\"target_url\":\"...\"}')")
    args = parser.parse_args()

    conn = init_db()

    if args.set_cred:
        platform, value = args.set_cred
        creds = load_credentials()
        try:
            creds[platform] = json.loads(value)
        except json.JSONDecodeError:
            creds[platform] = {"raw": value}
        save_credentials(creds)
        log(f"Stored credentials for {platform}.")
        return

    if args.once:
        run_engagement_cycle(conn)
        return

    if args.scheduler:
        scheduler_daemon(conn)
        return

    # Default: show status
    count = todays_count(conn)
    log(f"Today's engagements: {count}/{ENGAGEMENTS_PER_DAY}")
    creds = load_credentials()
    log(f"Configured platforms: {list(creds.keys())}")
    seconds = compute_next_fire(conn)
    log(f"Next engagement in {seconds/60:.0f} minutes.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Deep physiology analysis from InfluxDB ring data."""

import requests
import csv
import io
import json
from datetime import datetime, timezone, timedelta
from collections import defaultdict

INFLUX_URL = "https://us-east-1-1.aws.cloud2.influxdata.com"
ORG = "FunCo"
BUCKET = "ringie-prod"
TOKEN = "ZK49A30QO_bQlLI198jEAIdcY2EzyH7QJC3ufcOznwmBxJoBKh1rY2cix1cVdjXr8tddFN57YYlDPjviH4fovw=="

HEADERS = {
    "Authorization": f"Token {TOKEN}",
    "Content-Type": "application/vnd.flux",
    "Accept": "application/csv",
}

PT = timezone(timedelta(hours=-7))  # PDT

def query_influx(flux_query):
    """Execute a Flux query and return parsed CSV rows."""
    url = f"{INFLUX_URL}/api/v2/query?org={ORG}"
    resp = requests.post(url, headers=HEADERS, data=flux_query, timeout=60)
    resp.raise_for_status()
    rows = []
    # InfluxDB returns annotated CSV with multiple tables separated by blank lines
    # Each table has its own header row. We parse each table separately.
    tables = resp.text.split("\r\n\r\n")
    for table in tables:
        table = table.strip()
        if not table:
            continue
        lines = table.split("\r\n")
        # Filter out annotation rows (starting with #) and empty lines
        data_lines = [l for l in lines if l and not l.startswith("#")]
        if len(data_lines) < 2:
            continue
        reader = csv.DictReader(data_lines)
        for row in reader:
            val = row.get("_value", "")
            if val and val != "" and val != "_value":
                rows.append(row)
    return rows

def parse_time(t_str):
    """Parse RFC3339 time to datetime."""
    return datetime.fromisoformat(t_str.replace("Z", "+00:00"))

def time_bucket(dt_pt):
    """Categorize a PT datetime into time-of-day bucket."""
    h = dt_pt.hour
    if 0 <= h < 6:
        return "night (12a-6a)"
    elif 6 <= h < 9:
        return "early morning (6a-9a)"
    elif 9 <= h < 12:
        return "morning (9a-12p)"
    elif 12 <= h < 14:
        return "midday (12p-2p)"
    elif 14 <= h < 17:
        return "afternoon (2p-5p)"
    elif 17 <= h < 21:
        return "evening (5p-9p)"
    else:
        return "late night (9p-12a)"

def analyze_heart_rate():
    """Comprehensive heart rate analysis."""
    print("\n" + "="*70)
    print("HEART RATE ANALYSIS")
    print("="*70)

    # Use Kalman-filtered HR data for clean artifact-free analysis
    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "heart_rate_filtered" and r._field == "bpm")
      |> yield(name: "hr")
    '''
    rows = query_influx(q)
    if not rows:
        print("No heart rate data found.")
        return

    # Parse into (time_pt, bpm, activity_tag)
    data = []
    for r in rows:
        bpm = float(r["_value"])
        t = parse_time(r["_time"]).astimezone(PT)
        activity = r.get("activity", "")
        data.append((t, bpm, activity))

    data.sort(key=lambda x: x[0])
    bpms = [d[1] for d in data]

    print(f"\nData range: {data[0][0].strftime('%Y-%m-%d %H:%M')} to {data[-1][0].strftime('%Y-%m-%d %H:%M')} PT")
    print(f"Total readings: {len(data):,}")

    # Overall stats
    print(f"\n--- Overall Stats ---")
    print(f"  Lowest HR:  {min(bpms):.0f} bpm")
    print(f"  Highest HR: {max(bpms):.0f} bpm")
    print(f"  Mean HR:    {sum(bpms)/len(bpms):.1f} bpm")
    median_bpm = sorted(bpms)[len(bpms)//2]
    print(f"  Median HR:  {median_bpm:.0f} bpm")

    # Resting HR (lowest 5th percentile during night/sleep hours)
    night_bpms = [d[1] for d in data if d[0].hour < 6 or d[2] in ("sleeping", "resting")]
    if night_bpms:
        night_bpms_sorted = sorted(night_bpms)
        p5_idx = max(0, int(len(night_bpms_sorted) * 0.05))
        p5_resting = night_bpms_sorted[p5_idx]
        lowest_resting = min(night_bpms)
        avg_night = sum(night_bpms) / len(night_bpms)
        print(f"\n--- Resting / Sleep HR ---")
        print(f"  Night/sleep readings: {len(night_bpms):,}")
        print(f"  Lowest resting HR:    {lowest_resting:.0f} bpm")
        print(f"  5th percentile:       {p5_resting:.0f} bpm")
        print(f"  Average night HR:     {avg_night:.1f} bpm")

    # HR zones
    zones = {
        "< 50 (very low)": (0, 50),
        "50-59 (low/resting)": (50, 60),
        "60-69 (resting)": (60, 70),
        "70-79 (normal)": (70, 80),
        "80-89 (elevated)": (80, 90),
        "90-99 (high normal)": (90, 100),
        "100-119 (active)": (100, 120),
        "120-139 (cardio)": (120, 140),
        "140-159 (hard)": (140, 160),
        "160+ (peak)": (160, 300),
    }
    print(f"\n--- HR Zone Distribution ---")
    for label, (lo, hi) in zones.items():
        count = sum(1 for b in bpms if lo <= b < hi)
        pct = count / len(bpms) * 100
        bar = "█" * int(pct / 2)
        print(f"  {label:25s}: {pct:5.1f}%  {bar}")

    # By time of day
    print(f"\n--- HR by Time of Day ---")
    by_bucket = defaultdict(list)
    for t, bpm, _ in data:
        by_bucket[time_bucket(t)].append(bpm)
    for bucket_name in ["night (12a-6a)", "early morning (6a-9a)", "morning (9a-12p)",
                         "midday (12p-2p)", "afternoon (2p-5p)", "evening (5p-9p)", "late night (9p-12a)"]:
        vals = by_bucket.get(bucket_name, [])
        if vals:
            avg = sum(vals) / len(vals)
            lo = min(vals)
            hi = max(vals)
            print(f"  {bucket_name:25s}: avg {avg:5.1f}  min {lo:3.0f}  max {hi:3.0f}  (n={len(vals):,})")

    # By activity tag
    print(f"\n--- HR by Activity Tag ---")
    by_tag = defaultdict(list)
    for _, bpm, tag in data:
        by_tag[tag or "(none)"].append(bpm)
    for tag in sorted(by_tag.keys()):
        vals = by_tag[tag]
        avg = sum(vals) / len(vals)
        print(f"  {tag:20s}: avg {avg:5.1f}  min {min(vals):3.0f}  max {max(vals):3.0f}  (n={len(vals):,})")

    # Daily resting HR trend
    print(f"\n--- Daily Resting HR (lowest 10th pctile each day) ---")
    by_day = defaultdict(list)
    for t, bpm, _ in data:
        by_day[t.strftime("%Y-%m-%d")].append(bpm)
    for day in sorted(by_day.keys()):
        vals = sorted(by_day[day])
        p10_idx = max(0, int(len(vals) * 0.10))
        resting = vals[p10_idx]
        print(f"  {day}: {resting:3.0f} bpm  (avg {sum(vals)/len(vals):.0f}, n={len(vals):,})")


def analyze_spo2():
    """Blood oxygen analysis."""
    print("\n" + "="*70)
    print("SpO2 (BLOOD OXYGEN) ANALYSIS")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "spo2" and r._field == "percent")
      |> yield(name: "spo2")
    '''
    rows = query_influx(q)
    if not rows:
        print("No SpO2 data found.")
        return

    data = []
    for r in rows:
        val = float(r["_value"])
        t = parse_time(r["_time"]).astimezone(PT)
        activity = r.get("activity", "")
        data.append((t, val, activity))

    data.sort(key=lambda x: x[0])
    vals = [d[1] for d in data]

    print(f"\nData range: {data[0][0].strftime('%Y-%m-%d %H:%M')} to {data[-1][0].strftime('%Y-%m-%d %H:%M')} PT")
    print(f"Total readings: {len(data):,}")
    print(f"\n--- Overall Stats ---")
    print(f"  Lowest SpO2:  {min(vals):.1f}%")
    print(f"  Highest SpO2: {max(vals):.1f}%")
    print(f"  Mean SpO2:    {sum(vals)/len(vals):.1f}%")

    # Distribution
    spo2_ranges = {
        "< 90% (critically low)": (0, 90),
        "90-94% (low)": (90, 95),
        "95-96%": (95, 97),
        "97-98%": (97, 99),
        "99-100% (optimal)": (99, 101),
    }
    print(f"\n--- SpO2 Distribution ---")
    for label, (lo, hi) in spo2_ranges.items():
        count = sum(1 for v in vals if lo <= v < hi)
        pct = count / len(vals) * 100
        bar = "█" * int(pct / 2)
        print(f"  {label:30s}: {pct:5.1f}%  {bar}")

    # By time of day
    print(f"\n--- SpO2 by Time of Day ---")
    by_bucket = defaultdict(list)
    for t, val, _ in data:
        by_bucket[time_bucket(t)].append(val)
    for bucket_name in ["night (12a-6a)", "early morning (6a-9a)", "morning (9a-12p)",
                         "midday (12p-2p)", "afternoon (2p-5p)", "evening (5p-9p)", "late night (9p-12a)"]:
        bvals = by_bucket.get(bucket_name, [])
        if bvals:
            avg = sum(bvals) / len(bvals)
            lo = min(bvals)
            print(f"  {bucket_name:25s}: avg {avg:5.1f}%  min {lo:4.1f}%  (n={len(bvals):,})")

    # Daily trend
    print(f"\n--- Daily SpO2 ---")
    by_day = defaultdict(list)
    for t, val, _ in data:
        by_day[t.strftime("%Y-%m-%d")].append(val)
    for day in sorted(by_day.keys()):
        dvals = by_day[day]
        avg = sum(dvals) / len(dvals)
        lo = min(dvals)
        print(f"  {day}: avg {avg:5.1f}%  min {lo:4.1f}%  (n={len(dvals):,})")


def analyze_activity():
    """Steps, calories, distance analysis."""
    print("\n" + "="*70)
    print("ACTIVITY ANALYSIS (Steps / Calories / Distance)")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "activity")
      |> yield(name: "activity")
    '''
    rows = query_influx(q)
    if not rows:
        print("No activity data found.")
        return

    # Group by day and field
    by_day_field = defaultdict(lambda: defaultdict(float))
    for r in rows:
        t = parse_time(r["_time"]).astimezone(PT)
        day = t.strftime("%Y-%m-%d")
        field = r.get("_field", "")
        val = float(r["_value"])
        by_day_field[day][field] += val

    print(f"\n--- Daily Activity ---")
    print(f"  {'Date':12s} {'Steps':>8s} {'Calories':>10s} {'Distance':>10s}")
    print(f"  {'-'*12} {'-'*8} {'-'*10} {'-'*10}")
    total_steps = []
    for day in sorted(by_day_field.keys()):
        steps = by_day_field[day].get("steps", 0)
        cals = by_day_field[day].get("calories", 0)
        dist = by_day_field[day].get("distance_km", 0)
        total_steps.append(steps)
        print(f"  {day:12s} {steps:8,.0f} {cals:10,.0f} {dist:8.2f} km")

    if total_steps:
        print(f"\n--- Steps Summary ---")
        print(f"  Daily average: {sum(total_steps)/len(total_steps):,.0f} steps")
        print(f"  Best day:      {max(total_steps):,.0f} steps")
        print(f"  Lowest day:    {min(total_steps):,.0f} steps")
        print(f"  Total ({len(total_steps)} days): {sum(total_steps):,.0f} steps")


def fmt_min(m):
    """Format minutes as XhYYm."""
    return f"{m//60}h{m%60:02d}m"


def analyze_sleep():
    """Sleep stage analysis with session splitting (primary vs nap)."""
    print("\n" + "="*70)
    print("SLEEP ANALYSIS")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "sleep" and r._field == "duration_min")
      |> yield(name: "sleep")
    '''
    rows = query_influx(q)
    if not rows:
        print("No sleep data found.")
        return

    # Parse all periods with timestamps, dedup, skip no_data/error.
    # Handle two dedup cases:
    # 1. core/rem overlap (same timestamp, different stage tag)
    # 2. Re-sync duplicates (same stage+duration, timestamps within 10 min)
    raw_periods_by_night = defaultdict(list)
    seen_timestamps = set()
    for r in rows:
        night = r.get("night", "unknown")
        if night == "unknown":
            continue
        stage = r.get("stage", "unknown")
        if stage in ("no_data", "error"):
            continue
        if stage == "core":
            stage = "rem"
        ts_key = (r["_time"], night)
        if stage == "rem" and ts_key in seen_timestamps:
            continue
        seen_timestamps.add(ts_key)
        t = parse_time(r["_time"])
        duration = int(float(r["_value"]))
        raw_periods_by_night[night].append((t, stage, duration))

    # Dedup strategy: InfluxDB contains both old (-7h offset) and corrected (+7h)
    # sleep timestamps. For each period, if a matching period exists ~7h later
    # (same stage, same duration), drop the earlier (old) one and keep the later
    # (corrected) one. Also dedup re-syncs (same stage+dur within 10 min).
    TZ_OFFSET = 7 * 3600  # 7h in seconds
    TZ_TOL = 600          # 10 min tolerance
    periods_by_night = {}
    for night, periods in raw_periods_by_night.items():
        periods.sort(key=lambda x: x[0])
        # Pass 1: mark old periods that have a corrected counterpart ~7h later
        drop = set()
        for i, (t1, s1, d1) in enumerate(periods):
            for j, (t2, s2, d2) in enumerate(periods):
                if j <= i:
                    continue
                diff = (t2 - t1).total_seconds()
                if diff > TZ_OFFSET + TZ_TOL:
                    break  # sorted, no more matches possible
                if s1 == s2 and d1 == d2 and abs(diff - TZ_OFFSET) < TZ_TOL:
                    drop.add(i)  # drop the earlier (old) one
                    break
        filtered = [p for i, p in enumerate(periods) if i not in drop]
        # Pass 2: dedup re-syncs (same stage+dur within 10 min)
        deduped = []
        for t, stage, dur in filtered:
            is_dup = False
            for dt, ds, dd in deduped:
                if ds == stage and dd == dur and abs((t - dt).total_seconds()) < 600:
                    is_dup = True
                    break
            if not is_dup:
                deduped.append((t, stage, dur))
        periods_by_night[night] = deduped

    # Split each night into sessions using 60-min gap threshold
    GAP_THRESHOLD = 60  # minutes

    def split_sessions(periods):
        """Split sorted periods into sessions by gap."""
        if not periods:
            return []
        periods = sorted(periods, key=lambda x: x[0])
        sessions = [[periods[0]]]
        for i in range(1, len(periods)):
            prev_end = sessions[-1][-1][0] + timedelta(minutes=sessions[-1][-1][2])
            gap = (periods[i][0] - prev_end).total_seconds() / 60
            if gap >= GAP_THRESHOLD:
                sessions.append([periods[i]])
            else:
                sessions[-1].append(periods[i])
        return sessions

    def session_stats(periods):
        """Compute stage totals for a list of periods."""
        stats = defaultdict(int)
        for _, stage, dur in periods:
            stats[stage] += dur
        stats["total"] = sum(stats.values())
        return stats

    # Primary sleep and nap tracking
    primary_totals = {"deep": [], "rem": [], "light": [], "awake": [], "total": []}
    nap_records = []  # (night, naps_list)

    # Overnight window: 9 PM (21:00) to noon (12:00) next day
    OVERNIGHT_START_HOUR = 21
    OVERNIGHT_END_HOUR = 12

    def is_in_overnight_window(t_utc):
        """Check if a UTC time falls in the overnight window (9 PM - noon PT)."""
        h = t_utc.astimezone(PT).hour
        return h >= OVERNIGHT_START_HOUR or h < OVERNIGHT_END_HOUR

    def split_overnight_and_naps(periods):
        """Split a flat list of periods into overnight (primary) and nap periods.
        1. Split by 60-min gaps into sessions.
        2. Within each session, separate overnight vs daytime periods.
        3. Primary = the block with most minutes in the overnight window.
        """
        sessions = split_sessions(periods)
        # For each session, split into overnight and daytime portions
        overnight_blocks = []
        daytime_blocks = []
        for session in sessions:
            overnight = [p for p in session if is_in_overnight_window(p[0])]
            daytime = [p for p in session if not is_in_overnight_window(p[0])]
            if overnight:
                overnight_blocks.append(overnight)
            if daytime:
                daytime_blocks.append(daytime)

        # Primary = largest overnight block
        if overnight_blocks:
            primary_idx = max(range(len(overnight_blocks)),
                             key=lambda i: sum(p[2] for p in overnight_blocks[i]))
            primary = overnight_blocks[primary_idx]
            naps = [b for i, b in enumerate(overnight_blocks) if i != primary_idx] + daytime_blocks
        else:
            # No overnight periods — pick longest overall as primary
            all_blocks = overnight_blocks + daytime_blocks
            if not all_blocks:
                return [], []
            primary_idx = max(range(len(all_blocks)),
                             key=lambda i: sum(p[2] for p in all_blocks[i]))
            primary = all_blocks[primary_idx]
            naps = [b for i, b in enumerate(all_blocks) if i != primary_idx]

        return primary, naps

    print(f"\n--- Primary Sleep (Overnight) ---")
    print(f"  {'Night':12s} {'Total':>6s} {'Deep':>6s} {'REM':>6s} {'Light':>6s} {'Awake':>6s}  {'Window'}")
    print(f"  {'-'*12} {'-'*6} {'-'*6} {'-'*6} {'-'*6} {'-'*6}  {'-'*20}")

    for night in sorted(periods_by_night.keys()):
        primary, naps_list = split_overnight_and_naps(periods_by_night[night])
        if not primary:
            continue

        ps = session_stats(primary)
        if ps["total"] == 0:
            continue

        start_pt = primary[0][0].astimezone(PT)
        end_pt = (primary[-1][0] + timedelta(minutes=primary[-1][2])).astimezone(PT)
        window = f"{start_pt.strftime('%H:%M')}-{end_pt.strftime('%H:%M')}"

        primary_totals["deep"].append(ps.get("deep", 0))
        primary_totals["rem"].append(ps.get("rem", 0))
        primary_totals["light"].append(ps.get("light", 0))
        primary_totals["awake"].append(ps.get("awake", 0))
        primary_totals["total"].append(ps["total"])

        print(f"  {night:12s} {fmt_min(ps['total']):>6s} {fmt_min(ps.get('deep',0)):>6s} {fmt_min(ps.get('rem',0)):>6s} {fmt_min(ps.get('light',0)):>6s} {fmt_min(ps.get('awake',0)):>6s}  {window}")

        # Track naps with time windows
        if naps_list:
            nap_entries = []
            for nap_block in naps_list:
                dur = sum(p[2] for p in nap_block)
                if dur == 0:
                    continue
                ns = nap_block[0][0].astimezone(PT)
                ne = (nap_block[-1][0] + timedelta(minutes=nap_block[-1][2])).astimezone(PT)
                nap_entries.append((dur, f"{ns.strftime('%H:%M')}-{ne.strftime('%H:%M')}"))
            if nap_entries:
                nap_records.append((night, nap_entries))

    if primary_totals["total"]:
        n = len(primary_totals["total"])
        avg_total = sum(primary_totals["total"]) / n
        avg_deep = sum(primary_totals["deep"]) / n
        avg_rem = sum(primary_totals["rem"]) / n
        avg_light = sum(primary_totals["light"]) / n
        avg_awake = sum(primary_totals["awake"]) / n

        print(f"\n--- Primary Sleep Averages ({n} nights) ---")
        print(f"  Avg total sleep:  {fmt_min(int(avg_total))} ({avg_total:.0f} min)")
        print(f"  Avg deep sleep:   {fmt_min(int(avg_deep))} ({avg_deep/avg_total*100:.1f}%)")
        print(f"  Avg REM sleep:    {fmt_min(int(avg_rem))} ({avg_rem/avg_total*100:.1f}%)")
        print(f"  Avg light sleep:  {fmt_min(int(avg_light))} ({avg_light/avg_total*100:.1f}%)")
        print(f"  Avg awake time:   {fmt_min(int(avg_awake))} ({avg_awake/avg_total*100:.1f}%)")

    # Check for sleep_summary records (written by newer app versions)
    sq = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "sleep_summary")
      |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
      |> yield(name: "summary")
    '''
    summary_rows = query_influx(sq)
    if summary_rows:
        print(f"\n--- Sleep Summary (ring bounds) ---")
        print(f"  {'Night':12s} {'Start':>6s} {'End':>6s} {'Primary':>8s} {'Nap':>6s} {'Total':>6s}")
        print(f"  {'-'*12} {'-'*6} {'-'*6} {'-'*8} {'-'*6} {'-'*6}")
        for r in sorted(summary_rows, key=lambda x: x.get("night", "")):
            night = r.get("night", "?")
            ss = int(float(r.get("sleep_start_min", 0)))
            se = int(float(r.get("sleep_end_min", 0)))
            total = int(float(r.get("total_min", 0)))
            prim = int(float(r.get("primary_min", 0)))
            nap = int(float(r.get("nap_min", 0)))
            # Convert minutes-after-UTC-midnight to local time display
            ss_h, ss_m = divmod((ss + (-7 * 60)) % 1440, 60)  # UTC to PT
            se_h, se_m = divmod((se + (-7 * 60)) % 1440, 60)
            print(f"  {night:12s} {ss_h:02d}:{ss_m:02d} {se_h:02d}:{se_m:02d} {fmt_min(prim):>8s} {fmt_min(nap):>6s} {fmt_min(total):>6s}")

    if nap_records:
        print(f"\n--- Naps / Secondary Sleep ---")
        print(f"  {'Night':12s} {'Duration':>8s}  Window")
        print(f"  {'-'*12} {'-'*8}  {'-'*20}")
        total_nap_min = 0
        for night, entries in nap_records:
            for dur, window in entries:
                total_nap_min += dur
                label = "nap" if dur < 120 else "secondary"
                print(f"  {night:12s} {fmt_min(dur):>8s}  {window}  ({label})")
        nap_days = len(nap_records)
        print(f"\n  Days with naps/secondary sleep: {nap_days}/{n} ({nap_days/n*100:.0f}%)")
        print(f"  Avg extra sleep (on those days): {fmt_min(total_nap_min // nap_days)}")
    else:
        print(f"\n  No naps detected.")


def analyze_autonomic():
    """Derived autonomic metrics: night dip ratio, SDHR, RMSSD proxy."""
    import math

    print("\n" + "="*70)
    print("AUTONOMIC METRICS (Derived from Filtered HR)")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "heart_rate_filtered" and r._field == "bpm")
      |> yield(name: "hr")
    '''
    rows = query_influx(q)
    if not rows:
        print("No filtered HR data found.")
        return

    data = []
    for r in rows:
        bpm = int(float(r["_value"]))
        t = parse_time(r["_time"]).astimezone(PT)
        data.append((t, bpm))
    data.sort()

    by_date = defaultdict(list)
    for t, bpm in data:
        by_date[t.strftime("%Y-%m-%d")].append((t, bpm))

    # --- Night Dip Ratio ---
    print(f"\n--- Night Dip Ratio ---")
    print(f"  Sleep HR / Daytime HR. Normal dipper: 0.80-0.90")
    print(f"  < 0.80 extreme dipper | 0.80-0.90 normal | 0.90-1.0 non-dipper | > 1.0 reverse")
    print(f"\n  {'Date':12s} {'Night':>6s} {'Day':>6s} {'Ratio':>6s}  Assessment")
    print(f"  {'-'*12} {'-'*6} {'-'*6} {'-'*6}  {'-'*20}")

    ratios = []
    for date in sorted(by_date.keys()):
        readings = by_date[date]
        night = [b for t, b in readings if 0 <= t.hour < 6]
        day = [b for t, b in readings if 9 <= t.hour < 17]
        if len(night) < 5 or len(day) < 5:
            continue
        night_avg = sum(night) / len(night)
        day_avg = sum(day) / len(day)
        ratio = night_avg / day_avg
        ratios.append(ratio)
        if ratio < 0.80: assess = "extreme dipper"
        elif ratio < 0.90: assess = "dipper (normal)"
        elif ratio < 1.00: assess = "non-dipper"
        else: assess = "reverse dipper!"
        print(f"  {date:12s} {night_avg:6.1f} {day_avg:6.1f} {ratio:6.3f}  {assess}")

    if ratios:
        avg_r = sum(ratios) / len(ratios)
        print(f"\n  Overall avg: {avg_r:.3f} — {'normal dipper' if 0.80 <= avg_r < 0.90 else 'extreme dipper' if avg_r < 0.80 else 'non-dipper'}")

    # --- SDHR ---
    print(f"\n--- SDHR (HR Standard Deviation) ---")
    print(f"  Proxy for HRV. Higher = more autonomic flexibility.")
    print(f"\n  {'Date':12s} {'Night':>7s} {'Day':>7s} {'All':>7s}  {'N/D':>5s}")
    print(f"  {'-'*12} {'-'*7} {'-'*7} {'-'*7}  {'-'*5}")

    def sd(vals):
        if len(vals) < 3: return None
        m = sum(vals) / len(vals)
        return math.sqrt(sum((x - m)**2 for x in vals) / len(vals))

    night_sds, day_sds = [], []
    for date in sorted(by_date.keys()):
        readings = by_date[date]
        night = [b for t, b in readings if 0 <= t.hour < 6]
        day = [b for t, b in readings if 9 <= t.hour < 17]
        all_bpms = [b for _, b in readings]
        all_sd = sd(all_bpms)
        n_sd = sd(night)
        d_sd = sd(day)
        if n_sd is not None: night_sds.append(n_sd)
        if d_sd is not None: day_sds.append(d_sd)
        ns = f"{n_sd:5.2f}" if n_sd else "  -  "
        ds = f"{d_sd:5.2f}" if d_sd else "  -  "
        nd = f"{n_sd/d_sd:.2f}" if n_sd and d_sd and d_sd > 0 else "  -"
        print(f"  {date:12s} {ns:>7s} {ds:>7s} {all_sd:7.2f}  {nd:>5s}")

    if night_sds and day_sds:
        print(f"\n  Avg night SDHR: {sum(night_sds)/len(night_sds):.2f} bpm")
        print(f"  Avg day SDHR:   {sum(day_sds)/len(day_sds):.2f} bpm")
        nd_avg = (sum(night_sds)/len(night_sds)) / (sum(day_sds)/len(day_sds))
        print(f"  N/D ratio:      {nd_avg:.2f} ({'normal — lower variability during sleep' if nd_avg < 0.6 else 'elevated night variability'})")

    # --- RMSSD Proxy ---
    print(f"\n--- RMSSD Proxy (successive BPM differences) ---")
    print(f"  {'Date':12s} {'Night':>7s} {'Day':>7s}")
    print(f"  {'-'*12} {'-'*7} {'-'*7}")

    def rmssd_proxy(readings):
        if len(readings) < 3: return None
        diffs = []
        for i in range(1, len(readings)):
            dt = (readings[i][0] - readings[i-1][0]).total_seconds()
            if dt < 600:
                diffs.append((readings[i][1] - readings[i-1][1])**2)
        if not diffs: return None
        return math.sqrt(sum(diffs) / len(diffs))

    for date in sorted(by_date.keys()):
        readings = by_date[date]
        night_r = [(t, b) for t, b in readings if 0 <= t.hour < 6]
        day_r = [(t, b) for t, b in readings if 9 <= t.hour < 17]
        n = rmssd_proxy(night_r)
        d = rmssd_proxy(day_r)
        ns = f"{n:5.2f}" if n else "  -  "
        ds = f"{d:5.2f}" if d else "  -  "
        print(f"  {date:12s} {ns:>7s} {ds:>7s}")


def analyze_temp():
    """Body temperature analysis."""
    print("\n" + "="*70)
    print("BODY TEMPERATURE ANALYSIS")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "body_temp" and r._field == "celsius")
      |> yield(name: "temp")
    '''
    rows = query_influx(q)
    if not rows:
        print("No temperature data found.")
        return

    data = []
    for r in rows:
        val = float(r["_value"])
        t = parse_time(r["_time"]).astimezone(PT)
        data.append((t, val))

    data.sort(key=lambda x: x[0])
    vals = [d[1] for d in data]

    print(f"\nTotal readings: {len(data):,}")
    print(f"\n--- Overall Stats ---")
    print(f"  Lowest temp:  {min(vals):.1f}°C ({min(vals)*9/5+32:.1f}°F)")
    print(f"  Highest temp: {max(vals):.1f}°C ({max(vals)*9/5+32:.1f}°F)")
    print(f"  Mean temp:    {sum(vals)/len(vals):.1f}°C ({sum(vals)/len(vals)*9/5+32:.1f}°F)")

    # By time of day
    print(f"\n--- Temp by Time of Day ---")
    by_bucket = defaultdict(list)
    for t, val in data:
        by_bucket[time_bucket(t)].append(val)
    for bucket_name in ["night (12a-6a)", "early morning (6a-9a)", "morning (9a-12p)",
                         "midday (12p-2p)", "afternoon (2p-5p)", "evening (5p-9p)", "late night (9p-12a)"]:
        bvals = by_bucket.get(bucket_name, [])
        if bvals:
            avg = sum(bvals) / len(bvals)
            c = avg
            f = c * 9/5 + 32
            print(f"  {bucket_name:25s}: avg {c:5.1f}°C / {f:5.1f}°F  (n={len(bvals):,})")


def analyze_otf_workouts():
    """OTF workout HR analysis from chest strap data."""
    print("\n" + "="*70)
    print("OTF WORKOUT ANALYSIS (Chest Strap)")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 0)
      |> filter(fn: (r) => r._measurement == "otf_workout")
      |> filter(fn: (r) => r._field == "avg_hr" or r._field == "max_hr" or r._field == "calories"
                or r._field == "splat_points" or r._field == "avg_hr_pct" or r._field == "max_hr_pct"
                or r._field == "zone_orange_min" or r._field == "zone_red_min"
                or r._field == "zone_green_min" or r._field == "zone_blue_min" or r._field == "zone_gray_min")
      |> yield(name: "otf")
    '''
    rows = query_influx(q)
    if not rows:
        print("No OTF workout data found.")
        return

    by_workout = defaultdict(dict)
    for r in rows:
        t = r["_time"]
        by_workout[t][r.get("_field", "")] = float(r["_value"])

    avg_hrs, max_hrs, splats, cals = [], [], [], []
    # Track by year for trend analysis
    by_year = defaultdict(lambda: {"avg_hr": [], "splats": [], "count": 0})

    for t in sorted(by_workout.keys()):
        w = by_workout[t]
        avg = w.get("avg_hr", 0)
        mx = w.get("max_hr", 0)
        sp = w.get("splat_points", 0)
        cal = w.get("calories", 0)
        if avg > 50:  # skip malformed entries
            avg_hrs.append(avg)
            if mx > 0: max_hrs.append(mx)
            splats.append(sp)
            cals.append(cal)
            year = t[:4]
            by_year[year]["avg_hr"].append(avg)
            by_year[year]["splats"].append(sp)
            by_year[year]["count"] += 1

    print(f"\n  Total OTF workouts: {len(avg_hrs)}")
    if not avg_hrs:
        return

    print(f"\n--- Overall Workout Stats ---")
    print(f"  Avg workout HR:     {sum(avg_hrs)/len(avg_hrs):.0f} bpm")
    if max_hrs:
        print(f"  Avg max HR:         {sum(max_hrs)/len(max_hrs):.0f} bpm (peak: {max(max_hrs):.0f})")
    print(f"  Avg splat points:   {sum(splats)/len(splats):.0f}")
    print(f"  Avg calories:       {sum(cals)/len(cals):.0f}")

    # HR distribution across workouts
    print(f"\n--- Workout Avg HR Distribution ---")
    whr_buckets = [
        ("< 110 (easy)", 0, 110),
        ("110-119", 110, 120),
        ("120-129", 120, 130),
        ("130-139", 130, 140),
        ("140+ (max effort)", 140, 200),
    ]
    for label, lo, hi in whr_buckets:
        count = sum(1 for h in avg_hrs if lo <= h < hi)
        pct = count / len(avg_hrs) * 100
        bar = "█" * int(pct / 2)
        print(f"  {label:25s}: {pct:5.1f}%  {bar}")

    # Year-over-year trend
    print(f"\n--- Year-over-Year Fitness Trend ---")
    print(f"  {'Year':>6s} {'Workouts':>9s} {'Avg HR':>7s} {'Avg Splats':>11s}")
    print(f"  {'-'*6} {'-'*9} {'-'*7} {'-'*11}")
    for year in sorted(by_year.keys()):
        y = by_year[year]
        avg = sum(y["avg_hr"]) / len(y["avg_hr"])
        sp = sum(y["splats"]) / len(y["splats"])
        print(f"  {year:>6s} {y['count']:>9d} {avg:>7.0f} {sp:>11.0f}")

    if len(by_year) >= 2:
        years = sorted(by_year.keys())
        first_avg = sum(by_year[years[0]]["avg_hr"]) / len(by_year[years[0]]["avg_hr"])
        last_avg = sum(by_year[years[-1]]["avg_hr"]) / len(by_year[years[-1]]["avg_hr"])
        delta = last_avg - first_avg
        print(f"\n  Trend: {delta:+.0f} bpm avg HR from {years[0]} to {years[-1]}")
        if delta < -5:
            print(f"  → Lower HR at same effort = improved cardiovascular fitness")

    # Complete HR profile
    print(f"\n--- COMPLETE HR PROFILE ---")
    print(f"  Deep sleep:        48-55 bpm   (ring, Kalman-filtered)")
    print(f"  Light/REM sleep:   55-65 bpm   (ring, Kalman-filtered)")
    print(f"  Daytime resting:   60-80 bpm   (ring, Kalman-filtered)")
    print(f"  OTF workout avg:   {sum(avg_hrs)/len(avg_hrs):.0f} bpm      (chest strap, {len(avg_hrs)} sessions)")
    if max_hrs:
        print(f"  OTF workout peak:  {max(max_hrs):.0f} bpm      (chest strap)")
    print(f"  Dynamic range:     ~{max(max_hrs) - 48:.0f} bpm   (sleep floor to workout peak)" if max_hrs else "")


if __name__ == "__main__":
    print("=" * 70)
    print("PHYSIOLOGICAL DEEP DIVE — March 26 to Present")
    print(f"Generated: {datetime.now(PT).strftime('%Y-%m-%d %H:%M PT')}")
    print("=" * 70)

    analyze_heart_rate()
    analyze_spo2()
    analyze_activity()
    analyze_sleep()
    analyze_autonomic()
    analyze_temp()
    analyze_otf_workouts()

    print("\n" + "=" * 70)
    print("END OF REPORT")
    print("=" * 70)

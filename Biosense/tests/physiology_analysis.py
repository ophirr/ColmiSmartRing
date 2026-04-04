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

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "heart_rate" and r._field == "bpm")
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

    # Dedup re-syncs: if two periods have same stage, same duration, and start
    # within 10 minutes of each other, keep only the first.
    periods_by_night = {}
    for night, periods in raw_periods_by_night.items():
        periods.sort(key=lambda x: x[0])
        deduped = []
        for t, stage, dur in periods:
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


def analyze_hrv():
    """HRV analysis."""
    print("\n" + "="*70)
    print("HRV (HEART RATE VARIABILITY) ANALYSIS")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "hrv" and r._field == "ms")
      |> yield(name: "hrv")
    '''
    rows = query_influx(q)
    if not rows:
        print("No HRV data found.")
        return

    data = []
    for r in rows:
        val = float(r["_value"])
        t = parse_time(r["_time"]).astimezone(PT)
        data.append((t, val))

    data.sort(key=lambda x: x[0])
    vals = [d[1] for d in data]

    print(f"\nTotal readings: {len(data):,}")
    print(f"Data range: {data[0][0].strftime('%Y-%m-%d %H:%M')} to {data[-1][0].strftime('%Y-%m-%d %H:%M')} PT")
    print(f"\n--- Overall Stats ---")
    print(f"  Lowest HRV:   {min(vals):.0f} ms")
    print(f"  Highest HRV:  {max(vals):.0f} ms")
    print(f"  Mean HRV:     {sum(vals)/len(vals):.1f} ms")
    median = sorted(vals)[len(vals)//2]
    print(f"  Median HRV:   {median:.0f} ms")

    # By time of day
    print(f"\n--- HRV by Time of Day ---")
    by_bucket = defaultdict(list)
    for t, val in data:
        by_bucket[time_bucket(t)].append(val)
    for bucket_name in ["night (12a-6a)", "early morning (6a-9a)", "morning (9a-12p)",
                         "midday (12p-2p)", "afternoon (2p-5p)", "evening (5p-9p)", "late night (9p-12a)"]:
        bvals = by_bucket.get(bucket_name, [])
        if bvals:
            avg = sum(bvals) / len(bvals)
            print(f"  {bucket_name:25s}: avg {avg:5.1f} ms  (n={len(bvals):,})")

    # Daily trend
    print(f"\n--- Daily HRV ---")
    by_day = defaultdict(list)
    for t, val in data:
        by_day[t.strftime("%Y-%m-%d")].append(val)
    for day in sorted(by_day.keys()):
        dvals = by_day[day]
        avg = sum(dvals) / len(dvals)
        print(f"  {day}: avg {avg:5.1f} ms  max {max(dvals):.0f} ms  (n={len(dvals):,})")


def analyze_stress():
    """Stress level analysis."""
    print("\n" + "="*70)
    print("STRESS LEVEL ANALYSIS")
    print("="*70)

    q = f'''
    from(bucket: "{BUCKET}")
      |> range(start: 2026-03-26T00:00:00Z)
      |> filter(fn: (r) => r._measurement == "stress" and r._field == "level")
      |> yield(name: "stress")
    '''
    rows = query_influx(q)
    if not rows:
        print("No stress data found.")
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
    print(f"  Lowest stress:  {min(vals):.0f}")
    print(f"  Highest stress: {max(vals):.0f}")
    print(f"  Mean stress:    {sum(vals)/len(vals):.1f}")

    # By time of day
    print(f"\n--- Stress by Time of Day ---")
    by_bucket = defaultdict(list)
    for t, val in data:
        by_bucket[time_bucket(t)].append(val)
    for bucket_name in ["night (12a-6a)", "early morning (6a-9a)", "morning (9a-12p)",
                         "midday (12p-2p)", "afternoon (2p-5p)", "evening (5p-9p)", "late night (9p-12a)"]:
        bvals = by_bucket.get(bucket_name, [])
        if bvals:
            avg = sum(bvals) / len(bvals)
            print(f"  {bucket_name:25s}: avg {avg:5.1f}  (n={len(bvals):,})")


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


if __name__ == "__main__":
    print("=" * 70)
    print("PHYSIOLOGICAL DEEP DIVE — March 26 to Present")
    print(f"Generated: {datetime.now(PT).strftime('%Y-%m-%d %H:%M PT')}")
    print("=" * 70)

    analyze_heart_rate()
    analyze_spo2()
    analyze_activity()
    analyze_sleep()
    analyze_hrv()
    analyze_stress()
    analyze_temp()

    print("\n" + "=" * 70)
    print("END OF REPORT")
    print("=" * 70)

#!/usr/bin/env python3
"""Read a harness run and report the difficulty curve it actually produced.

    tools/analyze_balance.py artifacts/economy
    tools/analyze_balance.py artifacts/economy --strict     # exit 1 on a FAIL
    tools/analyze_balance.py artifacts/a artifacts/b --diff # two runs, side by side

This is [P12]'s instrument. Balance work is measurement-driven or it is vibes,
and the difference is whether "day three should hurt" is a sentence in a design
doc or a band with a pass/fail next to it. The bands live in
`game/content/economy/difficulty_curve.tres` — one file, read by this script and
by `EconomyReport` in the simulation, so the tests and the CLI grade a run the
same way.

WHAT IT MEASURES, per campaign day, over the DARK phases only (dusk, night,
deep night), because that is when the game is played:

    margin        mean heat supply / heat demand
    trough        the single lowest such sample of the night
    frozen        worst frozen_buildings / heat_buildings
    buffer floor  lowest stored heat, against the most the grid ever banked
                  — "how much of your savings did the night take"

and, for context rather than for grading: the coldest ambient, the storm peak,
population, deaths, and the resource the city was actually short of.

Exit codes: 0 report written, 1 a graded day FAILED under --strict, 2 bad input.
"""

import argparse
import csv
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CURVE = os.path.join(ROOT, "game", "content", "economy", "difficulty_curve.tres")
CURVE_SCRIPT = os.path.join(ROOT, "game", "sim", "economy", "difficulty_curve.gd")
SCENARIO_DIR = os.path.join(ROOT, "tests", "scenarios")

NIGHT_PHASES = ("dusk", "night", "deep_night")
DAY_TICKS_FALLBACK = 9600

K_TICK = "tick"
K_DAY = "climate.day"
K_PHASE = "climate.phase"
K_STORM = "climate.storm_intensity"
K_TEMP = "climate.ambient_temp"
K_LOSS = "climate.heat_loss_mult"
K_SUPPLY = "heat.total_supply"
K_DEMAND = "heat.total_demand"
K_DEFICIT = "heat.deficit"
K_BUFFER = "heat.buffer"
K_FROZEN = "heat.frozen_buildings"
K_HEATB = "heat.buildings"
K_NETWORKS = "heat.networks"
K_BROWNOUTS = "heat.brownouts"
K_BUILDINGS = "build.buildings_total"
K_MATERIALS = "build.materials"
K_POP = "citizens.population"
K_DEAD = "citizens.dead_total"
K_FOOD = "citizens.food_days"
K_HOMELESS = "citizens.homeless"
K_WAVE = "combat.wave"
K_ENEMIES = "combat.enemies_alive"
K_LOST = "combat.structures_lost"

PASS, SOFT, FAIL, NO_DATA = "pass", "soft", "FAIL", "—"


# --------------------------------------------------------------------- curve --

def _tres_values(path):
    """Values explicitly set in a .tres [resource] block, as raw source text."""
    out = {}
    if not os.path.exists(path):
        return out
    body = open(path).read()
    at = body.find("[resource]")
    if at >= 0:
        body = body[at:]
    for m in re.finditer(r"^([a-z_][a-z0-9_]*) = (.+?)$(?=\n[a-z_]|\n\[|\Z)",
                         body, re.S | re.M):
        out[m.group(1)] = m.group(2).strip()
    return out


def _parse_literal(text):
    """The handful of Godot literal forms the curve is written in."""
    text = text.strip()
    m = re.match(r"^Packed(?:Int32|Float32|String)Array\(\[(.*)\]\)$", text, re.S)
    if m:
        return _parse_list(m.group(1))
    if text.startswith("[") and text.endswith("]"):
        return _parse_list(text[1:-1])
    if text.startswith('&"') or text.startswith('"'):
        return text.strip('&').strip('"')
    try:
        return float(text) if ("." in text or "e" in text) else int(text)
    except ValueError:
        return text


def _parse_list(inner):
    out = []
    for part in re.findall(r'"(?:[^"\\]|\\.)*"|[^,\s][^,]*', inner, re.S):
        part = part.strip().rstrip(",").strip()
        if not part:
            continue
        if part.startswith('"'):
            out.append(part[1:-1])
            continue
        try:
            out.append(float(part) if ("." in part or "e" in part) else int(part))
        except ValueError:
            out.append(part)
    return out


def _gd_exports(path):
    """`@export var name: Type = <literal>` from a GDScript file.

    Line-based with bracket counting rather than one big regex: the curve's
    arrays are written across several lines and every regex that tries to span
    them stops at the first indented line, silently returning empty bands. An
    empty band grades every day as a pass, which is the one failure mode a gate
    is not allowed to have.
    """
    out = {}
    if not os.path.exists(path):
        return out
    name, buf, depth = None, "", 0
    for line in open(path):
        if name is None:
            m = re.match(r"^@export(?:_[a-z]+)?\s+var\s+([a-z_][a-z0-9_]*)\s*:[^=]*=\s*(.*)$", line)
            if not m:
                continue
            name, buf = m.group(1), m.group(2)
        else:
            buf += "\n" + line.rstrip("\n")
        depth = buf.count("(") - buf.count(")") + buf.count("[") - buf.count("]") \
            + buf.count("{") - buf.count("}")
        if depth <= 0:
            out[name] = _parse_literal(buf)
            name, buf = None, ""
    return out


def load_curve(path):
    """The difficulty curve, .tres overrides layered onto the script defaults.

    The .tres only states what has been tuned away from the default (exactly how
    ClimateProfile works), so both files have to be read or the bands come back
    empty and every day grades as no-data — a silent green, which is the one
    thing a gate must never be.
    """
    fields = _gd_exports(CURVE_SCRIPT)
    for key, raw in _tres_values(path).items():
        if key in ("script", "resource_name"):
            continue
        fields[key] = _parse_literal(raw)

    days = fields.get("day") or [1]
    n = len(days)

    def col(name, fill):
        v = fields.get(name)
        if not isinstance(v, list):
            v = []
        return [v[i] if i < len(v) else fill for i in range(n)]

    return {
        "day_ticks": int(fields.get("day_ticks", DAY_TICKS_FALLBACK) or DAY_TICKS_FALLBACK),
        "soft": float(fields.get("soft_tolerance", 0.3) or 0.3),
        "storm_day": fields.get("storm_day") or [],
        "days": {int(d): {
            "label": col("label", "Day")[i],
            "intent": col("intent", "")[i],
            "margin": (float(col("margin_min", 0.0)[i]), float(col("margin_max", 99.0)[i])),
            "trough": (float(col("trough_min", 0.0)[i]), float(col("trough_max", 99.0)[i])),
            "frozen": (0.0, float(col("frozen_max", 1.0)[i])),
            "buffer": (float(col("buffer_floor_min", 0.0)[i]), 1.0),
        } for i, d in enumerate(days)},
    }


# ----------------------------------------------------------------- measuring --

def num(row, key, fallback=0.0):
    v = row.get(key)
    if v is None or v == "":
        return fallback
    try:
        return float(v)
    except (TypeError, ValueError):
        return fallback


def margin(supply, demand):
    return 1.0 if demand <= 0.001 else supply / demand


def band_offset(value, low, high):
    width = max(0.0001, high - low)
    if value < low:
        return (value - low) / width
    if value > high:
        return (value - high) / width
    return 0.0


def verdict(value, low, high, soft):
    off = abs(band_offset(value, low, high))
    if off <= 0.0:
        return PASS
    return SOFT if off <= soft else FAIL


def load_rows(run_dir):
    path = os.path.join(run_dir, "metrics.csv")
    if not os.path.exists(path):
        sys.stderr.write("analyze_balance: no metrics.csv in %s\n" % run_dir)
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def measure(rows, curve):
    """Fold a metric series into per-day measurements and grade each."""
    day_ticks = curve["day_ticks"]
    by_day, order = {}, []
    for row in rows:
        d = int(num(row, K_DAY)) or (1 + int(num(row, K_TICK)) // day_ticks)
        if d not in by_day:
            by_day[d] = []
            order.append(d)
        by_day[d].append(row)
    order.sort()

    peak_buffer = 0.0
    out = []
    for d in order:
        day_rows = by_day[d]
        peak_buffer = max([peak_buffer] + [num(r, K_BUFFER) for r in day_rows])
        dark = [r for r in day_rows if r.get(K_PHASE) in NIGHT_PHASES]
        margins = [margin(num(r, K_SUPPLY), num(r, K_DEMAND)) for r in dark]
        frozen = [num(r, K_FROZEN) / num(r, K_HEATB, 1.0)
                  for r in dark if num(r, K_HEATB) > 0.0]
        buffers = [num(r, K_BUFFER) for r in dark]
        last = day_rows[-1]

        entry = {
            "day": d,
            "samples": len(day_rows),
            "dark": len(dark),
            "margin": sum(margins) / len(margins) if margins else 0.0,
            "trough": min(margins) if margins else 0.0,
            "frozen": max(frozen) if frozen else 0.0,
            "buffer_floor": (min(buffers) / peak_buffer) if (buffers and peak_buffer > 0) else 0.0,
            "buffer_low": min(buffers) if buffers else 0.0,
            "storm": max(num(r, K_STORM) for r in day_rows),
            "coldest": min(num(r, K_TEMP) for r in day_rows),
            "loss_peak": max(num(r, K_LOSS) for r in day_rows),
            "demand_peak": max(num(r, K_DEMAND) for r in day_rows),
            "supply_peak": max(num(r, K_SUPPLY) for r in day_rows),
            "networks": max(int(num(r, K_NETWORKS)) for r in day_rows),
            "brownouts": max(int(num(r, K_BROWNOUTS)) for r in day_rows),
            "deficit_share": sum(1 for r in day_rows if num(r, K_DEFICIT) > 0.01) / max(1, len(day_rows)),
            "buildings": int(num(last, K_BUILDINGS)),
            "materials": num(last, K_MATERIALS),
            "pop": int(num(last, K_POP)),
            "dead": int(num(last, K_DEAD)),
            "food_days": num(last, K_FOOD),
            "homeless": int(num(last, K_HOMELESS)),
            "wave": int(num(last, K_WAVE)),
            "enemies_peak": max(int(num(r, K_ENEMIES)) for r in day_rows),
            "lost": int(num(last, K_LOST)),
            "checks": [],
            "verdict": NO_DATA,
        }

        targets = curve["days"].get(d)
        if targets and dark:
            for name, value in (("margin", entry["margin"]), ("trough", entry["trough"]),
                                ("frozen", entry["frozen"]), ("buffer", entry["buffer_floor"])):
                low, high = targets[name]
                entry["checks"].append({
                    "name": name, "value": value, "low": low, "high": high,
                    "verdict": verdict(value, low, high, curve["soft"]),
                })
            grades = [c["verdict"] for c in entry["checks"]]
            entry["verdict"] = FAIL if FAIL in grades else (SOFT if SOFT in grades else PASS)
            entry["label"] = targets["label"]
            entry["intent"] = targets["intent"]
        out.append(entry)
    return out


def phase_profile(rows):
    """Where the pressure actually sits inside a day, averaged over the run."""
    buckets = {}
    for row in rows:
        p = row.get(K_PHASE) or "?"
        b = buckets.setdefault(p, {"n": 0, "m": 0.0, "def": 0, "frozen": 0.0, "brown": 0})
        b["n"] += 1
        b["m"] += margin(num(row, K_SUPPLY), num(row, K_DEMAND))
        b["def"] += 1 if num(row, K_DEFICIT) > 0.01 else 0
        hb = num(row, K_HEATB)
        b["frozen"] += (num(row, K_FROZEN) / hb) if hb > 0 else 0.0
        b["brown"] += int(num(row, K_BROWNOUTS))
    return buckets


def bottlenecks(run_dir):
    """Per-consumer attribution out of state.json — [P02] computes it, nothing
    else reads it, so at minimum a balance report should."""
    path = os.path.join(run_dir, "state.json")
    if not os.path.exists(path):
        return []
    try:
        state = json.load(open(path))
    except (ValueError, OSError):
        return []
    heat = ((state.get("final") or {}).get("systems") or {}).get("heat") or {}
    tally = {}
    for net in heat.get("networks", []):
        for b in net.get("bottlenecks", []):
            key = (str(b.get("kind", "?")), str(b.get("reason", "?")))
            row = tally.setdefault(key, {"count": 0, "consumers": 0, "load": 0.0})
            row["count"] += 1
            row["consumers"] += int(b.get("consumers", 0))
            row["load"] += float(b.get("load", 0.0))
    return sorted(([k[0], k[1], v] for k, v in tally.items()),
                  key=lambda r: -r[2]["consumers"])


def scenario_expects(rows, run_dir):
    path = os.path.join(run_dir, "state.json")
    name = ""
    if os.path.exists(path):
        try:
            name = str(json.load(open(path)).get("scenario", ""))
        except (ValueError, OSError):
            name = ""
    if not name:
        return {}, ""
    sc = os.path.join(SCENARIO_DIR, name + ".json")
    if not os.path.exists(sc):
        return {}, name
    try:
        return json.load(open(sc)).get("expects", {}) or {}, name
    except (ValueError, OSError):
        return {}, name


# ------------------------------------------------------------------ printing --

def report(run_dir, curve, args):
    rows = load_rows(run_dir)
    if not rows:
        return 2, []
    days = measure(rows, curve)
    expects, name = scenario_expects(rows, run_dir)

    print("=" * 78)
    print(" %s   (%s, %d samples)" % (run_dir, name or "unknown scenario", len(rows)))
    print("=" * 78)

    print("\nTHE CURVE  — measured over dusk/night/deep-night of each day")
    print("  day  label            margin   trough   frozen  buf-floor  storm   coldest  verdict")
    for d in days:
        print("  %3d  %-15s %6.3f   %6.3f   %5.1f%%   %7.3f  %5.2f  %7.1f  %s" % (
            d["day"], str(d.get("label", "—"))[:15], d["margin"], d["trough"],
            d["frozen"] * 100.0, d["buffer_floor"], d["storm"], d["coldest"],
            d["verdict"]))
    for d in days:
        misses = [c for c in d["checks"] if c["verdict"] != PASS]
        if not misses:
            continue
        print("\n  day %d — %s" % (d["day"], d.get("intent", "")))
        for c in misses:
            print("      %-7s %s  %.3f is outside %.3f..%.3f (%s)" % (
                c["name"], "✗" if c["verdict"] == FAIL else "~",
                c["value"], c["low"], c["high"], c["verdict"]))

    print("\nWHERE THE PRESSURE SITS  — mean margin by phase, whole run")
    prof = phase_profile(rows)
    for phase in ("dawn", "morning", "afternoon", "dusk", "night", "deep_night"):
        b = prof.get(phase)
        if not b:
            continue
        print("  %-11s margin %6.3f   in deficit %5.1f%% of samples   frozen %4.1f%%   %d brownouts" % (
            phase, b["m"] / b["n"], 100.0 * b["def"] / b["n"],
            100.0 * b["frozen"] / b["n"], b["brown"]))

    print("\nTHE CITY  — end of each day")
    print("  day  buildings  materials      pop  dead  food-days  homeless  nets  wave  enemies  lost")
    for d in days:
        print("  %3d  %9d  %9.0f  %7d  %4d  %9.2f  %8d  %4d  %4d  %7d  %4d" % (
            d["day"], d["buildings"], d["materials"], d["pop"], d["dead"],
            d["food_days"], d["homeless"], d["networks"], d["wave"],
            d["enemies_peak"], d["lost"]))

    bn = bottlenecks(run_dir)
    if bn:
        print("\nWHAT CHOKED  — final-tick bottleneck attribution from [P02]")
        for kind, reason, v in bn[:8]:
            print("  %-22s %-10s %3d tile(s), %4d consumer(s) behind it, %.1f load" % (
                kind, reason, v["count"], v["consumers"], v["load"]))

    problems = []
    max_nets = int(expects.get("max_heat_networks", 0) or 0)
    worst_nets = max((d["networks"] for d in days), default=0)
    if max_nets and worst_nets > max_nets:
        problems.append("heat grid fragmented into %d networks, %d allowed — a scenario "
                        "with private one-node networks measures nothing"
                        % (worst_nets, max_nets))
    wanted = [int(x) for x in (expects.get("balance_days") or [])]
    graded = {d["day"] for d in days if d["verdict"] != NO_DATA}
    for w in wanted:
        if w not in graded:
            problems.append("day %d was supposed to be graded and produced no dark-phase "
                            "samples" % w)
    fails = [d for d in days if d["verdict"] == FAIL]
    for d in fails:
        problems.append("day %d (%s) missed its designed band" % (d["day"], d.get("label", "")))

    print("\nVERDICT")
    if problems:
        for p in problems:
            print("  ✗ %s" % p)
    else:
        print("  ✓ every graded day inside its designed band")
    print("")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"run": run_dir, "scenario": name, "days": days,
                       "problems": problems}, f, indent=2)
        print("  wrote %s\n" % args.json)
    return (1 if (problems and args.strict) else 0), days


def diff(a_days, b_days, a_name, b_name):
    print("=" * 78)
    print(" DIFF  %s  ->  %s" % (a_name, b_name))
    print("=" * 78)
    print("  day    margin            trough            frozen")
    b_by_day = {d["day"]: d for d in b_days}
    for a in a_days:
        b = b_by_day.get(a["day"])
        if b is None:
            continue
        print("  %3d  %6.3f -> %6.3f   %6.3f -> %6.3f   %5.1f%% -> %5.1f%%" % (
            a["day"], a["margin"], b["margin"], a["trough"], b["trough"],
            a["frozen"] * 100.0, b["frozen"] * 100.0))
    print("")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="artifacts/<run> directories")
    ap.add_argument("--curve", default=DEFAULT_CURVE,
                    help="difficulty curve .tres (default: the shipped one)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 when a graded day fails its band")
    ap.add_argument("--diff", action="store_true",
                    help="with two runs, also print a side-by-side")
    ap.add_argument("--json", default="", help="also write the report as JSON")
    args = ap.parse_args()

    curve = load_curve(args.curve)
    if not curve["days"]:
        sys.stderr.write("analyze_balance: no bands in %s — nothing to grade against\n"
                         % args.curve)
        return 2

    worst, collected = 0, []
    for run in args.runs:
        code, days = report(run, curve, args)
        worst = max(worst, code)
        collected.append((run, days))
    if args.diff and len(collected) >= 2:
        diff(collected[0][1], collected[1][1], collected[0][0], collected[1][0])
    return worst


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Fail a run on the errors the engine printed and our logger never saw.

    tools/scan_errors.py <log> [<log> ...] [--label NAME] [--quiet] [--json OUT]

Exit 0 when every error in the captured stream is covered by a qualifying entry
in tools/error_allowlist.txt, 1 otherwise.

Why this exists: game/core/harness.gd gates a run on `Log.errors`, which counts
only calls to game/core/log.gd.  Godot's own `ERROR:` / `SCRIPT ERROR:` lines go
to stderr and are counted by nobody.  A visual first_night run printed 68 String
formatting errors and a failed add_child() and still exited 0, and check.sh even
filtered `^ERROR` out of the test output before showing it to a human.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_lib as G  # noqa: E402


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--label", default="engine errors")
    ap.add_argument("--allowlist", default=os.path.join(G.ROOT, "tools", "error_allowlist.txt"))
    ap.add_argument("--quiet", action="store_true", help="print nothing when clean")
    ap.add_argument("--max-groups", type=int, default=8)
    ap.add_argument("--json", default="")
    ap.add_argument("--warnings", action="store_true", help="also list engine warnings")
    args = ap.parse_args(argv)

    records: list[G.ErrorRecord] = []
    missing: list[str] = []
    for path in args.logs:
        if not os.path.exists(path):
            missing.append(path)
            continue
        records.extend(G.parse_log_file(path))

    entries, complaints = G.load_allowlist(args.allowlist)
    scan = G.classify(records, entries, complaints)
    for path in missing:
        scan.complaints.append("no such log: %s (a stage that produced no output cannot be judged)" % path)

    blocking_groups = G.group(scan.blocking)
    tracked_groups = G.group([r for r, _ in scan.tracked])

    if args.json:
        payload = {
            "label": args.label,
            "blocking": [{"count": c, "kind": r.kind, "message": r.message,
                          "blame": r.blame, "frames": r.frames, "source": r.source}
                         for c, r in blocking_groups],
            "tracked": [{"count": c, "message": r.message} for c, r in tracked_groups],
            "warnings": len(scan.warnings),
            "complaints": scan.complaints,
            "over_budget": scan.over_budget,
            "ok": scan.ok,
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.json)) or ".", exist_ok=True)
        with open(args.json, "w") as fh:
            json.dump(payload, fh, indent=1)

    if scan.ok and args.quiet:
        return 0

    total_blocking = len(scan.blocking)
    print("")
    print(" %s — %d blocking, %d known, %d benign, %d warning(s)" % (
        args.label, total_blocking, len(scan.tracked), len(scan.benign), len(scan.warnings)))
    for c, rec in blocking_groups[: args.max_groups]:
        print("   x%-5d %s: %s" % (c, rec.kind, rec.message[:120]))
        if rec.blame:
            print("          raised by %s" % rec.blame)
            for frame in rec.frames[1:4]:
                print("            <- %s" % frame)
        elif rec.at:
            print("          at %s" % rec.at)
        if rec.source:
            print("          seen in %s" % rec.source)
    if len(blocking_groups) > args.max_groups:
        print("   ... and %d more distinct blocking error(s)" % (len(blocking_groups) - args.max_groups))
    for c, rec in tracked_groups:
        print("   known  x%-4d %s" % (c, rec.message[:100]))
    for note in scan.over_budget:
        print("   BUDGET %s" % note)
    for note in scan.complaints:
        print("   !! %s" % note)
    if args.warnings and scan.warnings:
        for c, rec in G.group(scan.warnings)[:6]:
            print("   warn   x%-4d %s" % (c, rec.message[:100]))
    return 0 if scan.ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

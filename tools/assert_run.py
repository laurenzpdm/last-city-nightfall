#!/usr/bin/env python3
"""Grade a finished run against its scenario's contract.

    tools/assert_run.py artifacts/gate/first_night [--scenario first_night]
    tools/assert_run.py artifacts/gate/*/ --show-pass

Reads state.json + metrics.csv (the harness) and gate.json (tools/gate_probe.gd)
out of the run directory and checks them against tests/gate/expectations.json.

Exit 0 only when every band held AND every check could actually run.  An
expectation that could not be evaluated is reported as UNCHECKED and fails the
run: "the assertion did not execute" is how 371 build assertions were reported
passing while never running, and it is not going to be how these pass either.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_lib as G  # noqa: E402

CONTRACT = os.path.join(G.ROOT, "tests", "gate", "expectations.json")


def grade(run: G.Run, spec: dict, defaults: dict) -> list[G.Finding]:
    findings: list[G.Finding] = []
    findings += G.check_metrics(run, spec.get("metrics") or {})
    findings += G.check_state(run, spec.get("state") or {})
    findings += G.check_implications(run, spec.get("implications") or [])
    liveness = dict(defaults.get("liveness") or {})
    liveness.update(spec.get("liveness") or {})
    findings += G.check_liveness(run, liveness)
    return findings


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dirs", nargs="+")
    ap.add_argument("--scenario", default="", help="override the scenario name for a single run dir")
    ap.add_argument("--contract", default=CONTRACT)
    ap.add_argument("--show-pass", action="store_true")
    ap.add_argument("--json", default="")
    args = ap.parse_args(argv)

    with open(args.contract) as fh:
        contract = json.load(fh)
    scenarios = contract.get("scenarios") or {}
    defaults = contract.get("$defaults") or {}

    total_fail = 0
    total_unchecked = 0
    total_pass = 0
    summary: list[dict] = []

    for run_dir in args.run_dirs:
        run_dir = run_dir.rstrip("/")
        run = G.Run(run_dir)
        name = args.scenario or run.scenario
        spec = scenarios.get(name)
        print("")
        if spec is None:
            print(" %s — FAIL: no contract in %s" % (name, os.path.relpath(args.contract, G.ROOT)))
            print("        Every shipped scenario needs expectations, or its metrics.csv is decoration.")
            total_fail += 1
            summary.append({"scenario": name, "pass": 0, "fail": 1, "unchecked": 0})
            continue
        if not run.series and not run.state:
            print(" %s — FAIL: %s holds no state.json, metrics.csv or gate.json" % (name, run_dir))
            total_fail += 1
            summary.append({"scenario": name, "pass": 0, "fail": 1, "unchecked": 0})
            continue

        findings = grade(run, spec, defaults)
        p, f, u = G.verdict(findings)
        total_pass += p
        total_fail += f
        total_unchecked += u
        head = "%s (%s, %d ticks)" % (name, os.path.relpath(run_dir, G.ROOT), run.ticks)
        G.print_findings(head, findings, show_pass=args.show_pass)
        if not run.gate:
            print("        note: no gate.json here — alerts, signals and rosters were not recorded.")
        summary.append({"scenario": name, "pass": p, "fail": f, "unchecked": u,
                        "failures": [x.check for x in findings if x.status != G.PASS]})

    print("")
    print(" scenario contracts: %d pass, %d FAIL, %d unchecked" % (total_pass, total_fail, total_unchecked))
    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)) or ".", exist_ok=True)
        with open(args.json, "w") as fh:
            json.dump({"pass": total_pass, "fail": total_fail, "unchecked": total_unchecked,
                       "scenarios": summary}, fh, indent=1)
    return 1 if (total_fail or total_unchecked) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

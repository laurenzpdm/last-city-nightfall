#!/usr/bin/env python3
"""Fail the gate when a subsystem that claims to install is not in the tree.

    tools/check_reachability.py artifacts/gate/reach [--contract tests/gate/reachability.json]

Reads the dump written by tools/reachability_probe.gd (which boots the real
game) and grades it against tests/gate/reachability.json.

The bug this exists for: the build menu was instantiated, logged as installed,
and never parented — `tree.root.add_child()` is refused while the root is
propagating NOTIFICATION_READY, and a refusal is an engine error, and an engine
error is invisible to Log.errors. 768 tests never noticed because every one of
them tests the simulation.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_lib as G  # noqa: E402

_INSTALL_CLAIM = re.compile(r"(?i)\b(installed|install|ready|attached|enabled|wired)\b")


def _find(nodes: list[dict], rule: dict) -> list[dict]:
    hits = []
    for n in nodes:
        if "script" in rule and n.get("script") == rule["script"]:
            hits.append(n)
        elif "group" in rule and rule["group"] in (n.get("groups") or []):
            hits.append(n)
        elif "name" in rule and n.get("name") == rule["name"]:
            hits.append(n)
        elif "class" in rule and n.get("class") == rule["class"]:
            hits.append(n)
    return hits


def _descendants(nodes: list[dict], path: str) -> int:
    prefix = path + "/"
    return sum(1 for n in nodes if n["path"].startswith(prefix))


def check(dump: dict, contract: dict) -> list[G.Finding]:
    out: list[G.Finding] = []
    nodes: list[dict] = dump.get("nodes") or []
    log: list[str] = [str(x) for x in (dump.get("log") or [])]

    if dump.get("headless"):
        out.append(G.Finding(G.FAIL, "the probe ran with a display",
                             "DisplayServer is headless, so boot skipped _install_view() entirely "
                             "and this dump proves nothing about reachability"))
        return out

    found: dict[str, dict] = {}
    for req in contract.get("required", []):
        rid = req["id"]
        hits = _find(nodes, req)
        why = req.get("why", "")
        owner = req.get("owner", "")
        if not hits:
            out.append(G.Finding(G.FAIL, "in the tree: %s" % rid,
                                 "not found — %s" % (req.get("script") or req.get("group") or req.get("name")),
                                 why, owner))
            continue
        node = hits[0]
        found[rid] = node
        need = int(req.get("min_descendants", 0))
        if need:
            have = _descendants(nodes, node["path"])
            if have < need:
                out.append(G.Finding(G.FAIL, "in the tree: %s" % rid,
                                     "found at %s but only %d descendant(s), expected >= %d"
                                     % (node["path"], have, need), why, owner))
                continue
        out.append(G.Finding(G.PASS, "in the tree: %s" % rid, node["path"], why, owner))

    # ── held-but-orphaned: needs no contract entry, so a new subsystem is
    #    covered the day it lands rather than the day someone remembers.
    orphan_fields = [h for h in (dump.get("held") or []) if h.get("state") == "ORPHAN"]
    if orphan_fields:
        out.append(G.Finding(G.FAIL, "boot holds nothing that is not in the tree",
                             "; ".join("%s (%s) was built and never parented"
                                       % (h["field"], h.get("script") or h.get("class"))
                                       for h in orphan_fields)))
    else:
        held = [h for h in (dump.get("held") or []) if h.get("state") == "in_tree"]
        out.append(G.Finding(G.PASS, "boot holds nothing that is not in the tree",
                             "%d subsystem reference(s), all reachable" % len(held)))

    null_fields = [h["field"] for h in (dump.get("held") or []) if h.get("state") == "null"]
    if null_fields:
        out.append(G.Finding(G.PASS, "boot fields left null", ", ".join(sorted(null_fields))))

    # ── the engine's own orphan count
    cap = int(contract.get("orphan_nodes_max", 0))
    orphans = int(dump.get("orphan_nodes", -1))
    if orphans < 0:
        out.append(G.Finding(G.UNCHECKED, "orphan node count <= %d" % cap, "not recorded by the probe"))
    else:
        out.append(G.Finding(G.PASS if orphans <= cap else G.FAIL, "orphan node count <= %d" % cap,
                             "%d orphan node(s)" % orphans, str(contract.get("$orphan_why", ""))))

    # ── claims in the log must be backed by the tree
    keywords = {k: v for k, v in (contract.get("claim_keywords") or {}).items() if not k.startswith("$")}
    unbacked: list[str] = []
    claims_seen = 0
    for line in log:
        if not _INSTALL_CLAIM.search(line):
            continue
        low = line.lower()
        for kw, rid in keywords.items():
            if kw not in low:
                continue
            claims_seen += 1
            if rid not in found:
                unbacked.append("%r claims %s, which is not in the tree" % (line.strip()[:100], rid))
    if unbacked:
        out.append(G.Finding(G.FAIL, "every install the log claims is real",
                             "%d unbacked claim(s): %s" % (len(unbacked), " | ".join(sorted(set(unbacked))[:3])),
                             str((contract.get("claim_keywords") or {}).get("$why", ""))))
    else:
        out.append(G.Finding(G.PASS, "every install the log claims is real",
                             "%d claim(s) checked against the tree" % claims_seen))

    for rule in contract.get("forbid_log", []):
        pat = re.compile(rule["match"])
        hits = [l for l in log if pat.search(l)]
        out.append(G.Finding(G.FAIL if hits else G.PASS, "log is free of %r" % rule["match"],
                             hits[0][:110] if hits else "clean", rule.get("why", "")))

    # ── the layer stack
    lo = contract.get("layer_order") or {}
    ids = lo.get("ids") or []
    resolve = lo.get("resolve") or {}
    layers: list[tuple[str, int]] = []
    missing: list[str] = []
    for rid in ids:
        hits = _find(dump.get("canvas_layers") or [], resolve.get(rid, {}))
        if not hits:
            missing.append(rid)
            continue
        layers.append((rid, int(hits[0]["layer"])))
    if missing:
        out.append(G.Finding(G.FAIL, "canvas layer stack", "no CanvasLayer for %s" % ", ".join(missing),
                             str(lo.get("why", ""))))
    inversions = [
        "%s(%d) is not under %s(%d)" % (layers[i][0], layers[i][1], layers[i + 1][0], layers[i + 1][1])
        for i in range(len(layers) - 1) if layers[i][1] >= layers[i + 1][1]
    ]
    if layers:
        out.append(G.Finding(G.FAIL if inversions else G.PASS, "canvas layer stack",
                             "; ".join(inversions) if inversions
                             else " < ".join("%s %d" % (n, v) for n, v in layers),
                             str(lo.get("why", ""))))

    # ── the sim has to be alive, or nothing above it means anything
    systems = list(dump.get("sim_systems") or [])
    out.append(G.Finding(G.PASS if dump.get("sim_alive") else G.FAIL, "the world exists after boot",
                         "%d system(s) ticking" % len(systems)))
    want = set(contract.get("expect_systems") or [])
    if want:
        absent = sorted(want - set(systems))
        out.append(G.Finding(G.FAIL if absent else G.PASS, "every sim system loaded",
                             "missing: %s (sim.gd skips a system whose script will not compile)"
                             % ", ".join(absent) if absent else ", ".join(sorted(systems)),
                             str(contract.get("$expect_systems_why", ""))))
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--contract", default=os.path.join(G.ROOT, "tests", "gate", "reachability.json"))
    ap.add_argument("--show-pass", action="store_true")
    args = ap.parse_args(argv)

    dump_path = os.path.join(args.run_dir, "reachability.json")
    if not os.path.exists(dump_path):
        print(" reachability — FAIL: the probe wrote no dump at %s" % dump_path)
        print("        A boot that produces no evidence is a boot that failed.")
        return 1
    with open(dump_path) as fh:
        dump = json.load(fh)
    with open(args.contract) as fh:
        contract = json.load(fh)

    findings = check(dump, contract)
    G.print_findings("reachability", findings, show_pass=args.show_pass)
    _, failed, unchecked = G.verdict(findings)
    return 1 if (failed or unchecked) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Shared plumbing for the gate's teeth.

Three jobs, one module, because all three are "read what the run actually did
and refuse to be lied to":

  1. ENGINE ERRORS.  Godot writes `ERROR:` / `SCRIPT ERROR:` / `USER ERROR:` to
     stderr without ever touching game/core/log.gd.  Log.errors therefore counts
     the project's own logger and NOTHING ELSE, which is how a build that
     printed 70 engine errors in a 30 second run reported CHECK GREEN.  This
     module parses the real stderr, attributes each error to the GDScript frame
     that raised it, and groups by signature.

  2. SCENARIO CONTRACTS.  metrics.csv was decoration: 24000 ticks with
     logistics.items_moved == 0 and 43 shots fired in three days both exited 0.
     A band on a named metric turns the series into a contract.

  3. LIVENESS.  A wave that never ends, an enemy that stands at full HP for an
     hour, an alert that promises a famine the numbers never deliver.  These are
     the failures a passing assertion count cannot see, because nothing asserted
     anything about them.

Nothing in here imports Godot.  It reads artifacts/ and stderr, which is
precisely what a critic is handed.
"""

from __future__ import annotations

import csv
import datetime as _dt
import json
import os
import re
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ─────────────────────────────────────────────────────────────────────────────
#  1. engine error scanning
# ─────────────────────────────────────────────────────────────────────────────

# Godot 4.7 writes these to stderr.  `USER ERROR` is push_error() from GDScript,
# `SCRIPT ERROR` is a runtime script fault, plain `ERROR` is the engine itself.
_HEADS: List[Tuple[str, "re.Pattern[str]"]] = [
    ("SCRIPT_ERROR", re.compile(r"^\s*SCRIPT ERROR:\s*(?P<msg>.*)$")),
    ("USER_ERROR", re.compile(r"^\s*USER ERROR:\s*(?P<msg>.*)$")),
    ("ENGINE_ERROR", re.compile(r"^\s*ERROR:\s*(?P<msg>.*)$")),
    ("USER_WARNING", re.compile(r"^\s*USER WARNING:\s*(?P<msg>.*)$")),
    ("ENGINE_WARNING", re.compile(r"^\s*WARNING:\s*(?P<msg>.*)$")),
    # game/core/log.gd routes >= WARN to printerr, so its lines land in the same
    # stream.  They are already counted by Log.errors; they are surfaced here so
    # one report answers "what went wrong in this run" completely.
    ("LOG_ERROR", re.compile(r"^\[ERROR\]\[t\d+\]\[(?P<tag>[^\]]*)\]\s*(?P<msg>.*)$")),
    ("LOG_WARN", re.compile(r"^\[WARN\]\[t\d+\]\[(?P<tag>[^\]]*)\]\s*(?P<msg>.*)$")),
]

_ERROR_KINDS = {"SCRIPT_ERROR", "USER_ERROR", "ENGINE_ERROR", "LOG_ERROR"}

_AT = re.compile(r"^\s*at:\s*(?P<where>.+?)\s*$")
_BT_HEAD = re.compile(r"^\s*GDScript backtrace")
_BT_FRAME = re.compile(r"^\s*\[\d+\]\s*(?P<fn>.+?)\s*\((?P<src>res://[^)]+)\)\s*$")
_SCRIPT_AT = re.compile(r"^\s*at:\s*(?P<fn>.+?)\s*\((?P<src>res://[^)]+)\)\s*$")

# Digits and floats are run-specific.  "269 resources still in use" and
# "271 resources still in use" are one problem, not two.
_NUM = re.compile(r"(?<![A-Za-z_])[-+]?\d+(?:\.\d+)?")


@dataclass
class ErrorRecord:
    kind: str
    message: str
    at: str = ""
    blame: str = ""          # top GDScript frame, "res://file.gd:78"
    frames: List[str] = field(default_factory=list)
    source: str = ""         # which log file it came out of
    line_no: int = 0

    @property
    def is_error(self) -> bool:
        return self.kind in _ERROR_KINDS

    @property
    def signature(self) -> str:
        norm = _NUM.sub("<N>", self.message.strip())
        norm = re.sub(r"\s+", " ", norm)
        return "%s|%s|%s" % (self.kind, norm[:180], self.blame)

    def one_line(self) -> str:
        where = self.blame or self.at or "?"
        return "%-14s %s   [%s]" % (self.kind, self.message[:110], where)


def parse_log_text(text: str, source: str = "") -> List[ErrorRecord]:
    """Every error/warning record in a captured stdout+stderr stream."""
    lines = text.splitlines()
    out: List[ErrorRecord] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        kind = ""
        msg = ""
        for k, pat in _HEADS:
            m = pat.match(line)
            if m:
                kind = k
                msg = m.group("msg")
                break
        if not kind:
            i += 1
            continue
        rec = ErrorRecord(kind=kind, message=msg.strip(), source=source, line_no=i + 1)
        # A record's continuation lines follow immediately, but stdout and stderr
        # interleave when a caller merges them, so scan a short window instead of
        # demanding adjacency.  Stop at the next head: two errors never nest.
        j = i + 1
        window = 0
        while j < n and window < 14:
            nxt = lines[j]
            if any(p.match(nxt) for _, p in _HEADS):
                break
            sm = _SCRIPT_AT.match(nxt)
            if sm and not rec.blame:
                rec.blame = _short_src(sm.group("src"))
                rec.at = nxt.strip()[4:]
            elif _AT.match(nxt) and not rec.at:
                rec.at = _AT.match(nxt).group("where")
            elif _BT_HEAD.match(nxt):
                pass
            else:
                fm = _BT_FRAME.match(nxt)
                if fm:
                    rec.frames.append("%s (%s)" % (fm.group("fn"), _short_src(fm.group("src"))))
                    if not rec.blame:
                        rec.blame = _short_src(fm.group("src"))
                elif nxt.strip() == "":
                    pass
                elif window > 4:
                    break
            j += 1
            window += 1
        out.append(rec)
        i += 1
    return out


def _short_src(src: str) -> str:
    return src.replace("res://", "")


def parse_log_file(path: str) -> List[ErrorRecord]:
    rel = os.path.relpath(path, ROOT)
    if rel.startswith(".."):
        rel = os.path.basename(path)
    try:
        with open(path, "r", errors="replace") as fh:
            return parse_log_text(fh.read(), source=rel)
    except OSError:
        return []


# ── the allowlist ────────────────────────────────────────────────────────────
#
# Default is FAIL.  An entry buys silence only by naming an owner, writing down
# why, and putting an expiry date on it, so a suppression cannot quietly become
# permanent the way `grep -v ERROR` did.

@dataclass
class AllowEntry:
    id: str
    match: "re.Pattern[str]"
    klass: str            # "tracked" (shown, not fatal) | "benign" (counted only)
    owner: str
    why: str
    expires: Optional[_dt.date]
    kinds: List[str] = field(default_factory=list)
    blame: Optional["re.Pattern[str]"] = None
    source: Optional["re.Pattern[str]"] = None
    at: Optional["re.Pattern[str]"] = None
    max_per_run: int = -1
    problems: List[str] = field(default_factory=list)

    def applies(self, rec: ErrorRecord) -> bool:
        if self.kinds and rec.kind not in self.kinds:
            return False
        if self.blame and not self.blame.search(rec.blame or ""):
            return False
        if self.source and not self.source.search(rec.source or ""):
            return False
        # `at:` narrows an entry to one ENGINE source location.  It exists
        # because some of Godot's own messages carry no information at all —
        # `Condition "status < 0" is true. Returning: ERR_CANT_OPEN` is emitted
        # by the ALSA driver on a container with no sound card, and by a dozen
        # unrelated subsystems for a dozen unrelated reasons.  Matching it on
        # message alone would silence all of them, which is why it was left
        # blocking and reddened `engine errors: boot` on every xvfb run.  With
        # `at: drivers/alsa/` the entry says exactly which one it excuses, and
        # the same message from anywhere else stays fatal.
        if self.at and not self.at.search(rec.at or ""):
            return False
        return bool(self.match.search(rec.message))


def load_allowlist(path: str, today: Optional[_dt.date] = None) -> Tuple[List[AllowEntry], List[str]]:
    """Entries, plus the complaints about entries that do not qualify.

    A malformed or expired entry is NOT applied.  Its errors go back to being
    blocking, which is the only way an allowlist stays honest.
    """
    today = today or _dt.date.today()
    entries: List[AllowEntry] = []
    complaints: List[str] = []
    if not os.path.exists(path):
        return entries, ["no allowlist at %s — every engine error is blocking" % path]

    blocks: List[Dict[str, str]] = []
    cur: Dict[str, str] = {}
    last_key = ""
    with open(path, "r") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.strip().startswith("#") or not line.strip():
                continue
            m = re.match(r"^(?P<k>[a-z_]+):\s*(?P<v>.*)$", line)
            if m:
                key, val = m.group("k"), m.group("v")
                if key == "id":
                    if cur:
                        blocks.append(cur)
                    cur = {}
                cur[key] = val
                last_key = key
            elif line.startswith((" ", "\t")) and last_key:
                cur[last_key] = (cur.get(last_key, "") + " " + line.strip()).strip()
    if cur:
        blocks.append(cur)

    for b in blocks:
        eid = b.get("id", "").strip()
        problems: List[str] = []
        if not eid:
            complaints.append("an allowlist block has no id: — ignored")
            continue
        for req in ("match", "class", "owner", "why", "expires"):
            if not b.get(req, "").strip():
                problems.append("missing %s:" % req)
        klass = b.get("class", "").strip()
        if klass not in ("tracked", "benign"):
            problems.append("class: must be tracked or benign, not %r" % klass)
        why = b.get("why", "").strip()
        if len(why) < 25:
            problems.append("why: is not a justification (%d chars)" % len(why))
        expires: Optional[_dt.date] = None
        if b.get("expires", "").strip():
            try:
                expires = _dt.date.fromisoformat(b["expires"].strip())
            except ValueError:
                problems.append("expires: %r is not YYYY-MM-DD" % b["expires"])
        if expires and expires < today:
            problems.append("EXPIRED on %s — it suppresses nothing now" % expires.isoformat())
        try:
            pat = re.compile(b.get("match", "(?!)"))
        except re.error as exc:
            problems.append("match: is not a regex (%s)" % exc)
            pat = re.compile("(?!)")
        blame = None
        if b.get("blame", "").strip():
            try:
                blame = re.compile(b["blame"].strip())
            except re.error as exc:
                problems.append("blame: is not a regex (%s)" % exc)
        source = None
        if b.get("source", "").strip():
            try:
                source = re.compile(b["source"].strip())
            except re.error as exc:
                problems.append("source: is not a regex (%s)" % exc)
        at = None
        if b.get("at", "").strip():
            try:
                at = re.compile(b["at"].strip())
            except re.error as exc:
                problems.append("at: is not a regex (%s)" % exc)
        entry = AllowEntry(
            id=eid, match=pat, klass=klass or "tracked",
            owner=b.get("owner", "").strip(), why=why, expires=expires,
            kinds=[k.strip() for k in b.get("kinds", "").split(",") if k.strip()],
            blame=blame, source=source, at=at,
            max_per_run=int(b["max_per_run"]) if b.get("max_per_run", "").strip().isdigit() else -1,
            problems=problems,
        )
        if problems:
            complaints.append("allowlist entry '%s' does not qualify: %s" % (eid, "; ".join(problems)))
        else:
            entries.append(entry)
    return entries, complaints


@dataclass
class ErrorScan:
    blocking: List[ErrorRecord] = field(default_factory=list)
    tracked: List[Tuple[ErrorRecord, AllowEntry]] = field(default_factory=list)
    benign: List[Tuple[ErrorRecord, AllowEntry]] = field(default_factory=list)
    warnings: List[ErrorRecord] = field(default_factory=list)
    complaints: List[str] = field(default_factory=list)
    over_budget: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.blocking and not self.over_budget and not self.complaints


def classify(records: Iterable[ErrorRecord], entries: Sequence[AllowEntry],
             complaints: Sequence[str] = ()) -> ErrorScan:
    scan = ErrorScan(complaints=list(complaints))
    counts: Dict[str, int] = {}
    for rec in records:
        if not rec.is_error:
            scan.warnings.append(rec)
            continue
        hit = next((e for e in entries if e.applies(rec)), None)
        if hit is None:
            scan.blocking.append(rec)
            continue
        counts[hit.id] = counts.get(hit.id, 0) + 1
        (scan.tracked if hit.klass == "tracked" else scan.benign).append((rec, hit))
    for e in entries:
        if e.max_per_run >= 0 and counts.get(e.id, 0) > e.max_per_run:
            scan.over_budget.append("%s: %d occurrences, budget %d" % (e.id, counts[e.id], e.max_per_run))
    return scan


def group(records: Sequence[ErrorRecord]) -> List[Tuple[int, ErrorRecord]]:
    """(count, exemplar) per unique signature, worst first."""
    buckets: Dict[str, List[ErrorRecord]] = {}
    for r in records:
        buckets.setdefault(r.signature, []).append(r)
    rows = [(len(v), v[0]) for v in buckets.values()]
    rows.sort(key=lambda t: (-t[0], t[1].message))
    return rows


# ─────────────────────────────────────────────────────────────────────────────
#  2. run artifacts
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class Series:
    name: str
    ticks: List[int]
    values: List[Any]

    @property
    def numeric(self) -> List[float]:
        return [v for v in self.values if isinstance(v, float)]

    def final(self) -> Any:
        return self.values[-1] if self.values else None

    def first(self) -> Any:
        return self.values[0] if self.values else None

    def peak(self) -> Optional[float]:
        nums = self.numeric
        return max(nums) if nums else None

    def trough(self) -> Optional[float]:
        nums = self.numeric
        return min(nums) if nums else None

    def mean(self) -> Optional[float]:
        nums = self.numeric
        return sum(nums) / len(nums) if nums else None

    def moved(self) -> bool:
        return len({repr(v) for v in self.values}) > 1

    def first_tick_above(self, bound: float) -> Optional[int]:
        for t, v in zip(self.ticks, self.values):
            if isinstance(v, float) and v > bound:
                return t
        return None

    def at(self, tick: int) -> Any:
        """The sample at or immediately before `tick`."""
        best = None
        for t, v in zip(self.ticks, self.values):
            if t <= tick:
                best = v
            else:
                break
        return best


class Run:
    """One artifacts/<run>/ directory, however it was produced."""

    def __init__(self, path: str):
        self.path = path
        self.name = os.path.basename(path.rstrip("/"))
        self.state: Dict[str, Any] = _read_json(os.path.join(path, "state.json"))
        self.gate: Dict[str, Any] = _read_json(os.path.join(path, "gate.json"))
        self.series: Dict[str, Series] = {}
        self._load_metrics(os.path.join(path, "metrics.csv"))
        self._load_gate_series()

    # -- inputs ---------------------------------------------------------------

    def _load_metrics(self, csv_path: str) -> None:
        if not os.path.exists(csv_path):
            return
        with open(csv_path, "r", newline="") as fh:
            rows = list(csv.reader(fh))
        if len(rows) < 2:
            return
        header = rows[0]
        cols: Dict[str, List[Any]] = {h: [] for h in header}
        for row in rows[1:]:
            if len(row) != len(header):
                continue
            for h, cell in zip(header, row):
                cols[h].append(_coerce(cell))
        ticks = [int(v) if isinstance(v, float) else 0 for v in cols.get("tick", [])]
        if not ticks:
            ticks = list(range(len(rows) - 1))
        for h, vals in cols.items():
            self.series[h] = Series(h, ticks[: len(vals)], vals)

    def _load_gate_series(self) -> None:
        for name, pairs in (self.gate.get("series") or {}).items():
            ticks = [int(p[0]) for p in pairs]
            vals = [_coerce_value(p[1]) for p in pairs]
            self.series.setdefault(name, Series(name, ticks, vals))

    # -- accessors ------------------------------------------------------------

    @property
    def scenario(self) -> str:
        return str(self.state.get("scenario") or self.gate.get("scenario") or self.name)

    @property
    def ticks(self) -> int:
        return int(self.state.get("ticks") or self.gate.get("ticks") or 0)

    @property
    def alerts(self) -> List[Dict[str, Any]]:
        return list(self.gate.get("alerts") or [])

    @property
    def signals(self) -> Dict[str, Any]:
        return dict(self.gate.get("signals") or {})

    @property
    def rosters(self) -> List[Dict[str, Any]]:
        """Enemy rosters over time: gate.json first, else state.json checkpoints."""
        if self.gate.get("rosters"):
            return list(self.gate["rosters"])
        out: List[Dict[str, Any]] = []
        for key, snap in sorted((self.state.get("checkpoints") or {}).items(), key=lambda kv: int(kv[0])):
            combat = ((snap.get("systems") or {}).get("combat") or {})
            enemies = combat.get("enemies") or []
            out.append({
                "tick": int(key),
                "enemies": [{"id": int(e.get("id", 0)), "hp": float(e.get("hp", 0.0)),
                             "kind": str(e.get("kind", "?")), "born": int(e.get("born", 0))}
                            for e in enemies],
            })
        final = (self.state.get("final") or {}).get("systems", {}).get("combat")
        if final:
            out.append({
                "tick": self.ticks,
                "enemies": [{"id": int(e.get("id", 0)), "hp": float(e.get("hp", 0.0)),
                             "kind": str(e.get("kind", "?")), "born": int(e.get("born", 0))}
                            for e in (final.get("enemies") or [])],
            })
        out.sort(key=lambda r: r["tick"])
        return out

    def dotted(self, path: str) -> Any:
        cur: Any = self.state
        for part in path.split("."):
            if isinstance(cur, dict):
                if part not in cur:
                    return None
                cur = cur[part]
            elif isinstance(cur, list):
                if not part.lstrip("-").isdigit():
                    return None
                cur = cur[int(part)]
            else:
                return None
        return cur


def _read_json(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _coerce(cell: str) -> Any:
    try:
        return float(cell)
    except ValueError:
        return cell


def _coerce_value(v: Any) -> Any:
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    return v


# ─────────────────────────────────────────────────────────────────────────────
#  3. findings
# ─────────────────────────────────────────────────────────────────────────────

PASS, FAIL, UNCHECKED = "pass", "FAIL", "UNCHECKED"


@dataclass
class Finding:
    status: str
    check: str
    detail: str
    why: str = ""
    owner: str = ""

    def line(self) -> str:
        mark = {PASS: "  ok  ", FAIL: " FAIL ", UNCHECKED: " ???? "}[self.status]
        return "%s %-46s %s" % (mark, self.check, self.detail)


def verdict(findings: Sequence[Finding]) -> Tuple[int, int, int]:
    p = sum(1 for f in findings if f.status == PASS)
    f_ = sum(1 for f in findings if f.status == FAIL)
    u = sum(1 for f in findings if f.status == UNCHECKED)
    return p, f_, u


# ── the expectation language ─────────────────────────────────────────────────
#
# Every operator answers one question about one named series, and every band
# carries a `why`.  A band without a why is a magic number, and a magic number
# is how "min_ticks_per_second: 35" sat under a build measuring 41 and called
# itself a gate.

_OPS = {
    "final_min": lambda s, b: (_num(s.final()) is not None and _num(s.final()) >= b,
                               "final %s" % _fmt(s.final())),
    "final_max": lambda s, b: (_num(s.final()) is not None and _num(s.final()) <= b,
                               "final %s" % _fmt(s.final())),
    "min": lambda s, b: (all(v >= b for v in s.numeric), "low %s" % _fmt(s.trough())),
    "max": lambda s, b: (all(v <= b for v in s.numeric), "high %s" % _fmt(s.peak())),
    "peak_min": lambda s, b: (s.peak() is not None and s.peak() >= b, "peak %s" % _fmt(s.peak())),
    "peak_max": lambda s, b: (s.peak() is not None and s.peak() <= b, "peak %s" % _fmt(s.peak())),
    "mean_min": lambda s, b: (s.mean() is not None and s.mean() >= b, "mean %s" % _fmt(s.mean())),
    "mean_max": lambda s, b: (s.mean() is not None and s.mean() <= b, "mean %s" % _fmt(s.mean())),
    "delta_min": lambda s, b: (_delta(s) is not None and _delta(s) >= b, "delta %s" % _fmt(_delta(s))),
    "delta_max": lambda s, b: (_delta(s) is not None and _delta(s) <= b, "delta %s" % _fmt(_delta(s))),
}


def _num(v: Any) -> Optional[float]:
    return v if isinstance(v, float) else None


def _delta(s: Series) -> Optional[float]:
    a, b = _num(s.first()), _num(s.final())
    return None if a is None or b is None else b - a


def _fmt(v: Any) -> str:
    if isinstance(v, float):
        return ("%.3f" % v).rstrip("0").rstrip(".") if abs(v) < 1e6 else "%.3g" % v
    return "none" if v is None else str(v)


def check_metrics(run: Run, spec: Dict[str, Any]) -> List[Finding]:
    out: List[Finding] = []
    for metric, band in sorted(spec.items()):
        if metric.startswith("$"):
            continue
        why = str(band.get("why", ""))
        series = run.series.get(metric)
        if series is None or not series.values:
            out.append(Finding(UNCHECKED, metric, "no such column in this run's metrics", why))
            continue
        for op, bound in sorted(band.items()):
            if op in ("why", "$why"):
                continue
            if op == "must_move":
                ok = series.moved() if bound else not series.moved()
                out.append(Finding(PASS if ok else FAIL, "%s must_move=%s" % (metric, bound),
                                   "%s..%s" % (_fmt(series.first()), _fmt(series.final())), why))
                continue
            if op == "nonzero_by":
                t = series.first_tick_above(0.0)
                ok = t is not None and t <= float(bound)
                out.append(Finding(PASS if ok else FAIL, "%s nonzero_by %s" % (metric, bound),
                                   "first >0 at %s" % (t if t is not None else "never"), why))
                continue
            if op == "in_set":
                bad = sorted({str(v) for v in series.values} - set(bound))
                out.append(Finding(PASS if not bad else FAIL, "%s in_set" % metric,
                                   "unexpected %s" % bad if bad else "all values legal", why))
                continue
            fn = _OPS.get(op)
            if fn is None:
                out.append(Finding(UNCHECKED, "%s %s" % (metric, op), "unknown operator", why))
                continue
            ok, detail = fn(series, float(bound))
            out.append(Finding(PASS if ok else FAIL, "%s %s %s" % (metric, op, _fmt(float(bound))),
                               detail, why))
    return out


def check_state(run: Run, spec: Dict[str, Any]) -> List[Finding]:
    out: List[Finding] = []
    for path, band in sorted(spec.items()):
        if path.startswith("$"):
            continue
        why = str(band.get("why", ""))
        value = run.dotted(path)
        if value is None and "exists" not in band:
            out.append(Finding(FAIL, path, "missing from state.json", why))
            continue
        for op, bound in sorted(band.items()):
            if op == "why":
                continue
            if op == "exists":
                ok = (value is not None) == bool(bound)
                out.append(Finding(PASS if ok else FAIL, "%s exists=%s" % (path, bound),
                                   "found" if value is not None else "absent", why))
            elif op in ("len_min", "len_max"):
                try:
                    size = len(value)
                except TypeError:
                    out.append(Finding(FAIL, "%s %s" % (path, op), "not a container", why))
                    continue
                ok = size >= bound if op == "len_min" else size <= bound
                out.append(Finding(PASS if ok else FAIL, "%s %s %s" % (path, op, bound),
                                   "len %d" % size, why))
            elif op in ("min", "max"):
                try:
                    num = float(value)
                except (TypeError, ValueError):
                    out.append(Finding(FAIL, "%s %s" % (path, op), "not a number: %r" % (value,), why))
                    continue
                ok = num >= bound if op == "min" else num <= bound
                out.append(Finding(PASS if ok else FAIL, "%s %s %s" % (path, op, bound),
                                   _fmt(num), why))
            elif op == "eq":
                ok = value == bound
                out.append(Finding(PASS if ok else FAIL, "%s eq %r" % (path, bound), repr(value), why))
            else:
                out.append(Finding(UNCHECKED, "%s %s" % (path, op), "unknown operator", why))
    return out


# ── liveness ─────────────────────────────────────────────────────────────────

def check_liveness(run: Run, spec: Dict[str, Any]) -> List[Finding]:
    out: List[Finding] = []
    if not spec:
        return out

    if "stalled_enemy_ticks" in spec:
        out.append(_stalled_enemies(run, int(spec["stalled_enemy_ticks"]),
                                    str(spec.get("$why_stalled", ""))))
    if spec.get("waves_must_end"):
        out.append(_waves_end(run))
    if "min_kill_ratio" in spec:
        out.append(_kill_ratio(run, float(spec["min_kill_ratio"])))
    if "min_shots_per_enemy" in spec:
        out.append(_shots_per_enemy(run, float(spec["min_shots_per_enemy"]),
                                    str(spec.get("$why_shots", ""))))
    for rule in spec.get("claims", []):
        out.extend(_claim_vs_series(run, rule))
    return out


def _stalled_enemies(run: Run, limit: int, why: str) -> Finding:
    """An enemy that exists for `limit` ticks and never loses a hit point.

    Wave 2 of first_night never ended: enemy #5000018 was born at tick 17036 and
    was still alive at 24000 at full HP.  Nothing in the build noticed, because
    "alive" is not an error and "0 damage" is not an assertion.
    """
    rosters = run.rosters
    if len(rosters) < 2:
        return Finding(UNCHECKED, "no enemy stands still for %d ticks" % limit,
                       "this run recorded no enemy roster (needs gate.json or checkpoints)", why)
    full_hp: Dict[str, float] = {}
    for snap in rosters:
        for e in snap["enemies"]:
            full_hp[e["kind"]] = max(full_hp.get(e["kind"], 0.0), e["hp"])
    seen: Dict[int, Dict[str, Any]] = {}
    for snap in rosters:
        for e in snap["enemies"]:
            rec = seen.setdefault(e["id"], {"first": snap["tick"], "kind": e["kind"],
                                            "hp_first": e["hp"], "min_hp": e["hp"]})
            rec["last"] = snap["tick"]
            rec["hp_last"] = e["hp"]
            rec["min_hp"] = min(rec["min_hp"], e["hp"])
    culprits = []
    for eid, rec in sorted(seen.items()):
        span = rec.get("last", rec["first"]) - rec["first"]
        untouched = rec["min_hp"] >= full_hp.get(rec["kind"], 0.0) - 1e-6
        if span >= limit and untouched:
            culprits.append("#%d %s alive %d ticks at full HP (%s)" % (
                eid, rec["kind"], span, _fmt(rec["min_hp"])))
    if culprits:
        return Finding(FAIL, "no enemy stands still for %d ticks" % limit,
                       "%d stalled: %s" % (len(culprits), "; ".join(culprits[:3])), why)
    return Finding(PASS, "no enemy stands still for %d ticks" % limit,
                   "%d enemies tracked over %d snapshots" % (len(seen), len(rosters)), why)


def _waves_end(run: Run) -> Finding:
    """Every wave that starts is either cleared or still legitimately young."""
    sig = run.signals
    started = sig.get("wave_started")
    cleared = sig.get("wave_cleared")
    if started is None:
        alive = run.series.get("combat.enemies_alive")
        wave = run.series.get("threat.waves_cleared")
        if alive is None or wave is None:
            return Finding(UNCHECKED, "every wave ends",
                           "needs gate.json signals or combat metrics")
        ended = _num(alive.final()) == 0.0
        return Finding(PASS if ended else FAIL, "every wave ends",
                       "run ends with %s enemies alive, %s waves cleared" % (
                           _fmt(alive.final()), _fmt(wave.final())))
    if len(started) > len(cleared or []):
        last = started[-1]
        return Finding(FAIL, "every wave ends",
                       "%d wave(s) started, %d cleared; last start at tick %s" % (
                           len(started), len(cleared or []), last.get("tick", "?")))
    return Finding(PASS, "every wave ends", "%d started, %d cleared" % (len(started), len(cleared or [])))


def _kill_ratio(run: Run, bound: float) -> Finding:
    sig = run.signals
    spawned = sig.get("enemy_spawned_count")
    killed = sig.get("enemy_killed_count")
    if spawned is None:
        s = run.series.get("threat.live")
        k = run.series.get("combat.kills")
        if s is None or k is None:
            return Finding(UNCHECKED, "kills / spawns >= %s" % bound, "no combat series in this run")
        spawned = (s.peak() or 0.0)
        killed = _num(k.final()) or 0.0
    if spawned <= 0:
        return Finding(UNCHECKED, "kills / spawns >= %s" % bound,
                       "nothing ever spawned — an unfought scenario cannot prove combat works")
    ratio = float(killed) / float(spawned)
    return Finding(PASS if ratio >= bound else FAIL, "kills / spawns >= %s" % bound,
                   "%d killed of %d spawned (%.2f)" % (killed, spawned, ratio))


def _shots_per_enemy(run: Run, bound: float, why: str = "") -> Finding:
    """A FLOOR on shots per enemy, which is a proxy and can invert.

    It was written to catch turrets that watch enemies walk past (43 shots and 19
    kills across three days).  It cannot tell that apart from guns that hit what
    they aim at: accuracy pushes this ratio DOWN, so a build whose gunnery got
    better fails the same band as a build whose gunnery does nothing.  That is
    why it carries a `why` — see $why_shots in tests/gate/expectations.json, and
    read this row next to min_kill_ratio, which moves the right way in both
    cases.
    """
    shots = run.dotted("final.systems.combat.shots_fired")
    spawned = run.signals.get("enemy_spawned_count")
    if spawned is None:
        live = run.series.get("threat.live")
        spawned = live.peak() if live else None
    if shots is None or not spawned:
        return Finding(UNCHECKED, "shots / enemy >= %s" % bound,
                       "no shot or spawn count in this run", why)
    ratio = float(shots) / float(spawned)
    return Finding(PASS if ratio >= bound else FAIL, "shots / enemy >= %s" % bound,
                   "%s shots for %s enemies (%.2f)" % (_fmt(float(shots)), _fmt(float(spawned)), ratio),
                   why)


def _claim_vs_series(run: Run, rule: Dict[str, Any]) -> List[Finding]:
    """The general form of "the UI says X while the data says not-X".

    An alert is a promise about a number.  Take the number the alert names, look
    at what that number actually did over the horizon the alert promised, and
    fail when the two disagree.  The ATTENTION panel announced "Timber runs out
    in 20 seconds" over a timber series that went 715 -> 495 -> flat.
    """
    name = str(rule.get("id", "claim"))
    why = str(rule.get("why", ""))
    if not run.gate:
        return [Finding(UNCHECKED, "alerts tell the truth: %s" % name,
                        "this run recorded no alerts (needs tools/gate_probe.gd)", why)]
    try:
        pat = re.compile(rule["match"], re.IGNORECASE)
    except (KeyError, re.error) as exc:
        return [Finding(UNCHECKED, "alerts tell the truth: %s" % name, "bad rule: %s" % exc, why)]

    if rule.get("implies_series"):
        return [_claim_implies(run, rule, pat)]

    template = str(rule.get("series", ""))
    horizon_group = str(rule.get("horizon_seconds_group", "secs"))
    default_horizon = float(rule.get("horizon_seconds", 60.0))
    frac = float(rule.get("must_fall_below_fraction", 0.25))
    hz = float(rule.get("tick_hz", 20.0))

    matched = 0
    lies: List[str] = []
    for alert in run.alerts:
        text = str(alert.get("text", ""))
        m = pat.search(text)
        if not m:
            continue
        matched += 1
        groups = {k: v for k, v in (m.groupdict() or {}).items() if v is not None}
        series_name = template.format(**{k: str(v).strip().lower().replace(" ", "_")
                                         for k, v in groups.items()}) if template else ""
        series = run.series.get(series_name)
        tick = int(alert.get("tick", 0))
        if series is None:
            lies.append("t%d %r names %s, which is not a series this build produces"
                        % (tick, text[:60], series_name or "?"))
            continue
        secs = float(groups.get(horizon_group, default_horizon))
        now = _num(series.at(tick))
        later = _num(series.at(tick + int(secs * hz)))
        if now is None or later is None:
            lies.append("t%d %r cannot be checked: %s has no sample there" % (tick, text[:60], series_name))
            continue
        if now <= 0.0:
            continue
        if later > now * frac:
            lies.append("t%d %r but %s went %s -> %s over those %.0f s"
                        % (tick, text[:60], series_name, _fmt(now), _fmt(later), secs))
    if lies:
        return [Finding(FAIL, "alerts tell the truth: %s" % name,
                        "%d contradicted: %s" % (len(lies), " | ".join(lies[:3])), why)]
    if matched == 0 and rule.get("expect_at_least_one"):
        return [Finding(FAIL, "alerts tell the truth: %s" % name,
                        "no alert ever matched %r, so the panel this rule guards never fired"
                        % rule["match"], why)]
    if matched == 0:
        return [Finding(PASS, "alerts tell the truth: %s" % name,
                        "INERT: no alert in this build has this shape yet, so the rule bit on nothing", why)]
    return [Finding(PASS, "alerts tell the truth: %s" % name,
                    "%d matching alert(s), none contradicted by the series" % matched, why)]


def _claim_implies(run: Run, rule: Dict[str, Any], pat: "re.Pattern[str]") -> Finding:
    """An alert of this shape asserts that a named series is alive right then.

    "Network 1 short 12 heat/s" while heat.deficit is 0, "Watchtower froze"
    while heat.frozen_buildings is 0, "Night 1: a handful out of the south-east"
    while nothing is on the map.  Same failure as the ATTENTION panel promising
    a famine the timber series never delivered, in the one place a headless run
    can still see it.
    """
    name = str(rule.get("id", "claim"))
    why = str(rule.get("why", ""))
    series_name = str(rule["implies_series"])
    floor = float(rule.get("implies_min", 1.0))
    window = int(rule.get("window_ticks", 40))
    series = run.series.get(series_name)
    if series is None:
        return Finding(UNCHECKED, "alerts tell the truth: %s" % name,
                       "%s is not a series this run produced" % series_name, why)
    matched = 0
    lies: List[str] = []
    for alert in run.alerts:
        text = str(alert.get("text", ""))
        if not (pat.search(text) or pat.search(str(alert.get("key", "")))):
            continue
        matched += 1
        tick = int(alert.get("tick", 0))
        best = None
        for t, v in zip(series.ticks, series.values):
            if abs(t - tick) <= window and isinstance(v, float):
                best = v if best is None else max(best, v)
        if best is None or best < floor:
            lies.append("t%d %r but %s was %s" % (tick, text[:70], series_name, _fmt(best)))
    if lies:
        return Finding(FAIL, "alerts tell the truth: %s" % name,
                       "%d contradicted: %s" % (len(lies), " | ".join(lies[:3])), why)
    if matched == 0:
        return Finding(PASS, "alerts tell the truth: %s" % name,
                       "no alert of this shape was raised in this run", why)
    return Finding(PASS, "alerts tell the truth: %s" % name,
                   "%d alert(s), all backed by %s" % (matched, series_name), why)


def check_consistency(run: Run, rules: Sequence[Dict[str, Any]]) -> List[Finding]:
    """Two counters of the same event have to agree.

    The generalised form of "the UI says X while the data says not-X", applied
    to the simulation's own reporting surface: every number a panel can print
    comes from either a metric or a Bus signal, and when those two disagree one
    of them is lying to the player.  This is how threat.waves_cleared was caught
    frozen at 1 in a run where Bus.wave_cleared fired twice and
    threat.waves_survived reached 2.
    """
    out: List[Finding] = []
    for rule in rules:
        rid = str(rule.get("id", "consistency"))
        why = str(rule.get("why", ""))
        metric = str(rule.get("metric", ""))
        signal = str(rule.get("signal", ""))
        series = run.series.get(metric)
        sig = run.signals
        if series is None:
            out.append(Finding(UNCHECKED, "counters agree: %s" % rid, "no metric %s" % metric, why))
            continue
        if not run.gate:
            out.append(Finding(UNCHECKED, "counters agree: %s" % rid,
                               "no gate.json — the signal side was never recorded", why))
            continue
        raw = sig.get(signal, sig.get(signal + "_count"))
        if raw is None:
            out.append(Finding(UNCHECKED, "counters agree: %s" % rid, "no signal %s" % signal, why))
            continue
        events = len(raw) if isinstance(raw, list) else int(raw)
        counted = _num(series.final())
        tol = float(rule.get("tolerance", 0))
        if counted is None:
            out.append(Finding(UNCHECKED, "counters agree: %s" % rid, "%s is not numeric" % metric, why))
            continue
        ok = abs(counted - events) <= tol
        out.append(Finding(PASS if ok else FAIL, "counters agree: %s" % rid,
                           "%s says %s, Bus.%s fired %d time(s)" % (metric, _fmt(counted), signal, events),
                           why))
    return out


def check_implications(run: Run, rules: Sequence[Dict[str, Any]]) -> List[Finding]:
    """If the run got itself into state A, it has to be able to reach state B.

    The one that matters: a society that raises a demand for a law, in a build
    where no law is ever signed, is a system talking to a player who has no way
    to answer it.
    """
    out: List[Finding] = []
    for rule in rules:
        rid = str(rule.get("id", "implication"))
        why = str(rule.get("why", ""))
        when = dict(rule.get("when") or {})
        then = dict(rule.get("then") or {})
        w_metric = str(when.pop("metric", ""))
        t_metric = str(then.pop("metric", ""))
        w_series = run.series.get(w_metric)
        t_series = run.series.get(t_metric)
        if w_series is None or t_series is None:
            out.append(Finding(UNCHECKED, "implication: %s" % rid,
                               "needs %s and %s" % (w_metric, t_metric), why))
            continue
        premise = check_metrics(run, {w_metric: dict(when, why=why)})
        if any(f.status == FAIL for f in premise):
            out.append(Finding(PASS, "implication: %s" % rid,
                               "premise not met (%s stayed at %s)" % (w_metric, _fmt(w_series.peak())), why))
            continue
        conclusion = check_metrics(run, {t_metric: dict(then, why=why)})
        bad = [f for f in conclusion if f.status != PASS]
        if bad:
            out.append(Finding(FAIL, "implication: %s" % rid,
                               "%s happened but %s did not (%s)" % (w_metric, t_metric, bad[0].detail), why))
        else:
            out.append(Finding(PASS, "implication: %s" % rid,
                               "%s happened and %s followed" % (w_metric, t_metric), why))
    return out


# ─────────────────────────────────────────────────────────────────────────────
#  reporting
# ─────────────────────────────────────────────────────────────────────────────

RULE = "─" * 72


def print_findings(title: str, findings: Sequence[Finding], show_pass: bool = False) -> None:
    p, f_, u = verdict(findings)
    print(" %s — %d pass, %d FAIL, %d unchecked" % (title, p, f_, u))
    for fi in findings:
        # An INERT rule passed because it matched nothing. That is worth reading
        # every time: a rule nobody can trip is not evidence of anything, and
        # hiding it behind "pass" is how a green report stops meaning green.
        if fi.status == PASS and not show_pass and not fi.detail.startswith("INERT"):
            continue
        print(fi.line())
        if fi.why and fi.status != PASS:
            print("        why this matters: %s" % fi.why)

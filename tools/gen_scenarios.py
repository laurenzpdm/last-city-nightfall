#!/usr/bin/env python3
"""Regenerates tests/scenarios/*.json.

The scenario library is data the harness executes, and hand-editing JSON is how
it drifted into placing buildings that do not exist on top of each other. This
script owns the layouts instead: it knows every definition's footprint and the
heat-connection rule, and it refuses to emit a command that would be refused at
runtime. Run it, then run tools/check.sh.

    python3 tools/gen_scenarios.py

THE CONNECTION RULE (HeatGraph, game/sim/heat/heat_graph.gd):

    two buildings are linked when their footprints touch orthogonally AND at
    least one of them CONDUCTS (heat_capacity > 0).

Two machines standing side by side are NOT connected. That single rule is the
layout game, and getting it wrong is silent: a generator that touches only a
housing block forms its own one-node network, produces into nothing, freezes,
and the run still exits 0. That is exactly how economy_60min came to simulate a
city whose sixteen generators all sat on private islands while heat supply read
120.00 — the Hearth — for an hour. `Layout.audit_heat()` below rebuilds the
component graph over the finished layout and refuses to write a scenario whose
heat entities are not one connected grid.
"""

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "scenarios")

# id -> (w, h, needs_heat_neighbour, conducts, participates_in_heat)
#
#   needs_heat_neighbour  BuildingDef.must_connect contains "heat"
#   conducts              BuildingDef.is_heat_conduit (heat_capacity > 0)
#   participates          HeatDef.participates(): output, demand, storage,
#                         capacity or radiance — i.e. it joins the heat graph
#                         and is worthless off the grid
DEFS = {
    "coal_generator": (3, 2, False, False, True),
    "field_kitchen": (3, 2, False, False, True),
    "geothermal_tap": (3, 3, False, False, True),
    "granary": (3, 3, False, False, True),
    "heat_accumulator": (2, 2, True, True, True),
    "heat_booster_pump": (1, 1, True, True, True),
    "heat_pipe": (1, 1, False, True, True),
    "heat_pipe_insulated": (1, 1, False, True, True),
    "heat_trunk_main": (1, 1, False, True, True),
    "housing_block": (4, 4, False, False, True),
    "ore_drill": (3, 3, False, False, True),
    "rubble_road": (1, 1, False, False, False),
    "scrap_collector": (2, 2, False, False, True),
    "smelter": (3, 3, False, False, True),
    "storage_yard": (3, 3, False, False, False),
    "the_hearth": (5, 5, False, False, True),
    "turret_mount": (2, 2, False, False, True),
    "wall": (1, 1, False, False, False),
    "warmth_radiator": (2, 2, True, False, True),
    "watchtower": (2, 2, False, False, True),
    "workshop": (4, 3, False, False, True),
}
# Kinds that satisfy a must_connect(&"heat") test.
HEAT_TAGS = {"heat_pipe", "heat_pipe_insulated", "heat_trunk_main", "the_hearth",
             "coal_generator", "geothermal_tap", "heat_accumulator",
             "heat_booster_pump"}

CONDUCTS = {k for k, v in DEFS.items() if v[3]}
PARTICIPATES = {k for k, v in DEFS.items() if v[4]}

NEIGHBOURS = ((1, 0), (-1, 0), (0, 1), (0, -1))

CORE = (128, 128)


class Layout:
    """Occupancy bookkeeping, so a generated scenario cannot self-collide."""

    def __init__(self):
        self.occ = {}          # cell -> kind
        self.origins = []      # (kind, origin) in placement order
        self.script = []

    def cells(self, kind, origin):
        w, h = DEFS[kind][0], DEFS[kind][1]
        return [(origin[0] + x, origin[1] + y) for y in range(h) for x in range(w)]

    def free(self, kind, origin):
        return all(c not in self.occ for c in self.cells(kind, origin))

    def touches_heat(self, kind, origin):
        if not DEFS[kind][2]:
            return True
        own = set(self.cells(kind, origin))
        for (cx, cy) in own:
            for n in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                if n in own:
                    continue
                if self.occ.get(n) in HEAT_TAGS:
                    return True
        return False

    def claim(self, kind, origin):
        for c in self.cells(kind, origin):
            self.occ[c] = kind
        self.origins.append((kind, origin))

    # ------------------------------------------------------------ heat audit
    def heat_components(self):
        """Connected components over the finished layout, HeatGraph's rule.

        Returns a list of dicts {kinds: Counter-ish set, size, sample cell}.
        A building is a node; two nodes are linked when they touch orthogonally
        and at least one of them conducts.
        """
        owner = {}                          # cell -> node index
        nodes = []                          # index -> (kind, origin)
        for kind, origin in self.origins:
            if kind not in PARTICIPATES:
                continue
            idx = len(nodes)
            nodes.append((kind, origin))
            for c in self.cells(kind, origin):
                # A later line may have been refused on this cell; occ holds the
                # kind that actually owns it, exactly as build does at runtime.
                if self.occ.get(c) == kind:
                    owner.setdefault(c, idx)

        parent = list(range(len(nodes)))

        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        def union(a, b):
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[max(ra, rb)] = min(ra, rb)

        for cell, idx in owner.items():
            for dx, dy in NEIGHBOURS:
                other = owner.get((cell[0] + dx, cell[1] + dy))
                if other is None or other == idx:
                    continue
                if nodes[idx][0] in CONDUCTS or nodes[other][0] in CONDUCTS:
                    union(idx, other)

        groups = {}
        for i in range(len(nodes)):
            groups.setdefault(find(i), []).append(i)
        out = []
        for members in groups.values():
            kinds = sorted({nodes[i][0] for i in members})
            out.append({"size": len(members), "kinds": kinds,
                        "sample": nodes[members[0]][1],
                        "members": [nodes[i] for i in members]})
        out.sort(key=lambda g: -g["size"])
        return out

    def audit_heat(self, name, allow_islands=0):
        """Refuse to write a scenario whose heat entities are not one grid."""
        comps = self.heat_components()
        if not comps:
            return
        islands = comps[1:]
        if len(islands) <= allow_islands:
            return
        detail = "; ".join(
            "%d node(s) %s at %s" % (g["size"], ",".join(g["kinds"]), g["sample"])
            for g in islands[:6])
        raise AssertionError(
            "%s: heat grid is in %d pieces, %d allowed. Main network has %d nodes. "
            "Orphans: %s" % (name, len(comps), allow_islands + 1, comps[0]["size"], detail))

    def place(self, tick, kind, dx, dy, free=False, instant=False):
        origin = (CORE[0] + dx, CORE[1] + dy)
        assert self.free(kind, origin), f"{kind} at {origin} overlaps {[self.occ.get(c) for c in self.cells(kind, origin) if c in self.occ][:3]}"
        assert self.touches_heat(kind, origin), f"{kind} at {origin} touches no heat conduit"
        self.claim(kind, origin)
        cmd = {"system": "build", "op": "place", "kind": kind,
               "cell": [origin[0], origin[1]]}
        if free:
            cmd["free"] = True
        if instant:
            cmd["instant"] = True
        self.script.append({"tick": tick, "cmd": cmd})

    def line(self, tick, kind, a, b, free=False, instant=False):
        """L-shaped run of a 1x1 piece: horizontal leg first, then vertical."""
        assert DEFS[kind][0] == 1 and DEFS[kind][1] == 1
        x0, y0 = CORE[0] + a[0], CORE[1] + a[1]
        x1, y1 = CORE[0] + b[0], CORE[1] + b[1]
        cur = (x0, y0)
        laid = []
        guard = 0
        while guard < 512:
            guard += 1
            laid.append(cur)
            if cur == (x1, y1):
                break
            if cur[0] != x1:
                cur = (cur[0] + (1 if x1 > cur[0] else -1), cur[1])
            elif cur[1] != y1:
                cur = (cur[0], cur[1] + (1 if y1 > cur[1] else -1))
            else:
                break
        for c in laid:
            # A line runs THROUGH whatever is already there; build refuses the
            # occupied cells and lays the rest, which is what a player sees too.
            if c not in self.occ:
                self.occ[c] = kind
                self.origins.append((kind, c))
        cmd = {"system": "build", "op": "place_line", "kind": kind,
               "from": [x0, y0], "to": [x1, y1]}
        if free:
            cmd["free"] = True
        if instant:
            cmd["instant"] = True
        self.script.append({"tick": tick, "cmd": cmd})

    def cmd(self, tick, payload):
        self.script.append({"tick": tick, "cmd": payload})

    def stock(self, tick, items):
        self.cmd(tick, {"system": "build", "op": "add_stock", "items": items})

    def unlock(self, tick, *ids):
        for i in ids:
            self.cmd(tick, {"system": "build", "op": "grant_unlock", "unlock": i})

    def done(self):
        return sorted(self.script, key=lambda e: e["tick"])


def write(scenario):
    # Private keys the schema does not know about: consumed here, never written.
    layout = scenario.pop("_layout", None)
    allow_islands = scenario.pop("_allow_islands", 0)
    scenario["script"] = sorted(scenario["script"], key=lambda e: e["tick"])
    for e in scenario["script"]:
        assert 1 <= e["tick"] <= scenario["ticks"], (scenario["name"], e)
    rows = scenario["ticks"] // scenario["sample_every"]
    assert 20 <= rows <= 4000, (scenario["name"], rows)

    grid = ""
    if layout is not None:
        layout.audit_heat(scenario["name"], allow_islands)
        comps = layout.heat_components()
        if comps:
            total = sum(c["size"] for c in comps)
            grid = ", heat grid %d/%d nodes in %d network(s)" % (
                comps[0]["size"], total, len(comps))

    path = os.path.join(OUT, scenario["name"] + ".json")
    with open(path, "w") as f:
        json.dump(scenario, f, indent=2)
        f.write("\n")
    print("%-14s %3d commands, %4d metric rows, last tick %d%s" % (
        scenario["name"], len(scenario["script"]), rows,
        scenario["script"][-1]["tick"], grid))


# --------------------------------------------------------------------- smoke
def smoke():
    L = Layout()
    L.stock(1, {"iron_plate": 900, "steel_plate": 600, "stone": 900, "timber": 600})
    L.place(2, "the_hearth", -2, -2, free=True, instant=True)
    L.line(3, "heat_pipe", (3, 0), (12, 0), free=True, instant=True)
    L.line(4, "heat_pipe", (-3, 0), (-12, 0), free=True, instant=True)
    L.line(5, "heat_pipe", (0, 3), (0, 12), free=True, instant=True)
    # A distribution row the housing hangs off, so the district is one network
    # rather than a hearth with orphans around it.
    L.line(6, "heat_pipe", (3, 2), (12, 2), free=True, instant=True)
    L.line(7, "heat_pipe", (-3, 2), (-12, 2), free=True, instant=True)
    L.place(8, "warmth_radiator", 13, -1, free=True, instant=True)
    L.place(9, "warmth_radiator", -14, -1, free=True, instant=True)
    L.place(10, "housing_block", 5, 3, free=True, instant=True)
    L.place(11, "housing_block", -9, 3, free=True, instant=True)
    L.place(12, "coal_generator", -3, 11, free=True, instant=True)
    L.place(13, "workshop", 1, 11, free=True, instant=True)
    L.place(14, "storage_yard", 9, 4, free=True, instant=True)
    # The perimeter is on the city's grid, not beside it. A watchtower draws 1
    # heat and a turret draws 6; off the network they are one-node islands that
    # freeze by deep night, which is the opposite of what these shots are for.
    L.line(15, "heat_pipe", (12, -1), (12, -9), free=True, instant=True)
    L.line(16, "heat_pipe", (12, 3), (12, 9), free=True, instant=True)
    L.place(17, "watchtower", 13, -9, free=True, instant=True)
    L.place(18, "turret_mount", 13, 9, free=True, instant=True)
    for tick, phase in [(100, "morning"), (200, "afternoon"), (350, "dusk"),
                        (460, "night"), (550, "deep_night")]:
        L.cmd(tick, {"system": "climate", "op": "skip_to_phase", "phase": phase})
    return {
        "name": "smoke",
        "description": ("The fast gate, and the colour-arc photo run. Lights a small "
                        "settlement, then walks the climate clock through all six phases so "
                        "the six shots are genuinely dawn, morning, afternoon, dusk, night "
                        "and deep night rather than six pictures of the same minute."),
        "tags": ["fast", "gate", "visual"],
        "seed": 7, "ticks": 600, "sample_every": 20,
        "expects": {"min_ticks_per_second": 200, "max_errors": 0},
        "script": L.script,
        "_layout": L,
        "shots": [
            {"tick": 40, "name": "dawn_wide"},
            {"tick": 150, "name": "morning_industry"},
            {"tick": 300, "name": "afternoon_housing"},
            {"tick": 420, "name": "dusk_city"},
            {"tick": 520, "name": "night_perimeter"},
            {"tick": 585, "name": "deep_night_zoomout"},
        ],
    }


# --------------------------------------------------------------- first_night
def first_night():
    L = Layout()
    L.stock(1, {"iron_plate": 1400, "steel_plate": 900, "stone": 1400, "timber": 900,
                "scrap": 900, "gear": 400, "copper_coil": 400, "coal": 900})
    L.unlock(2, "thermal_storage", "pressurised_mains")
    # The city that already stands when the day begins.
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    L.line(4, "heat_pipe", (3, 0), (12, 0), free=True, instant=True)
    L.line(5, "heat_pipe", (-3, 0), (-12, 0), free=True, instant=True)
    L.line(6, "heat_pipe", (3, 2), (12, 2), free=True, instant=True)
    L.line(7, "heat_pipe", (-3, 2), (-12, 2), free=True, instant=True)
    L.place(8, "warmth_radiator", 13, -1, free=True, instant=True)
    L.place(9, "warmth_radiator", -14, -1, free=True, instant=True)
    L.place(10, "housing_block", 5, 3, free=True, instant=True)
    L.place(11, "housing_block", -9, 3, free=True, instant=True)
    # Everything after this the player pays for, in build order.
    L.line(400, "heat_pipe", (0, 3), (0, 14))
    L.line(500, "heat_pipe", (0, 14), (-1, 14))
    L.place(600, "coal_generator", -4, 14)
    L.place(900, "workshop", 1, 14)
    L.place(1200, "storage_yard", 9, 4)
    L.line(1500, "heat_pipe", (-1, 8), (-8, 8))
    L.place(1800, "warmth_radiator", -10, 7)
    L.place(2100, "housing_block", -9, 9)
    L.line(2400, "heat_pipe", (5, 3), (5, 8))
    L.place(2600, "granary", 6, 8)
    L.line(2800, "heat_pipe", (-3, 2), (-3, -8))
    L.place(3000, "field_kitchen", -6, -8)
    L.line(3400, "heat_pipe", (12, 1), (12, 8))
    L.place(3800, "heat_accumulator", 13, 8)
    # Industry reaches out to the coal seam north of the basin. One trunk runs
    # all the way to the wall line, so the perimeter is on the same grid as the
    # city and a brownout at the hearth is felt at the turrets.
    L.line(4000, "heat_pipe", (0, -3), (1, -18))
    L.line(4100, "heat_pipe", (1, -18), (1, -33))
    L.line(4150, "heat_pipe", (1, -30), (-1, -30))
    L.place(4200, "ore_drill", -4, -31)
    L.place(4600, "smelter", 2, -21)
    # The wall goes up before dusk.
    for i, dx in enumerate([-18, -9, 0, 9, 18]):
        L.line(5000 + i * 40, "wall", (dx - 4, -35), (dx + 4, -35))
    L.line(5250, "heat_pipe", (1, -33), (13, -33))
    L.line(5280, "heat_pipe", (1, -33), (-19, -33))
    L.place(5300, "watchtower", -20, -32)
    L.place(5400, "watchtower", 13, -32)
    L.place(5600, "turret_mount", -9, -32)
    L.place(5800, "turret_mount", 8, -32)
    # Night: the grid is under load and the player reacts to it.
    L.place(6600, "heat_booster_pump", 1, 12)
    L.cmd(7000, {"system": "build", "op": "set_enabled", "cell": [CORE[0] + 1, CORE[1] + 14], "on": False})
    L.cmd(7400, {"system": "heat", "op": "dump"})
    L.cmd(7800, {"system": "grid", "op": "melt", "cell": [CORE[0], CORE[1]], "radius": 6, "amount": 90})
    L.cmd(8600, {"system": "build", "op": "set_enabled", "cell": [CORE[0] + 1, CORE[1] + 14], "on": True})
    # The second generator and the last housing block both need a spur before
    # they are worth anything: a producer or a home that touches no conduit is
    # its own one-node network, and this run is what the whole project
    # screenshots against.
    L.line(8800, "heat_pipe", (0, 15), (0, 18))
    L.place(9000, "coal_generator", 1, 17)
    L.line(10100, "heat_pipe", (-3, -2), (-10, -2))
    L.place(10200, "housing_block", -9, -6)
    return {
        "name": "first_night",
        "description": ("The reference run. One full day and into the next: a hearth is lit, "
                        "a heat grid grows out of it, housing and industry hang off the grid, "
                        "a wall goes up before dusk, and the night is spent short of heat. "
                        "This is what the art, audio and UI parts screenshot against."),
        "tags": ["reference", "gate", "visual"],
        "seed": 7, "ticks": 11000, "sample_every": 20,
        "expects": {"min_ticks_per_second": 300, "max_errors": 0,
                    "balance_days": [1], "max_heat_networks": 3},
        "script": L.script,
        "_layout": L,
        "shots": [
            {"tick": 30, "name": "opening"},
            {"tick": 1500, "name": "build"},
            {"tick": 3400, "name": "midday"},
            {"tick": 5500, "name": "dusk"},
            {"tick": 7200, "name": "assault"},
            {"tick": 8800, "name": "deep_night"},
            {"tick": 9800, "name": "dawn"},
        ],
    }


# -------------------------------------------------------------- determinism
def determinism():
    L = Layout()
    L.stock(1, {"iron_plate": 900, "steel_plate": 600, "stone": 900,
                "timber": 400, "coal": 600})
    L.unlock(2, "thermal_storage", "pressurised_mains")
    L.place(4, "the_hearth", -2, -2)
    L.line(60, "heat_pipe", (3, 0), (14, 0))
    L.place(120, "warmth_radiator", 15, -1)
    # On the grid, not beside it: a generator that only touches bare ground is a
    # one-node network, and then the flow solver — the thing this scenario is
    # here to prove deterministic — never runs on it at all.
    L.line(180, "heat_pipe", (0, 3), (-6, 3))
    L.place(200, "coal_generator", -8, 4)
    L.cmd(260, {"system": "grid", "op": "snowfall", "rate": 0.9})
    L.cmd(300, {"system": "climate", "op": "force_storm",
                "intensity": 0.85, "duration_ticks": 900})
    L.cmd(420, {"system": "grid", "op": "melt",
                "cell": [CORE[0], CORE[1]], "radius": 5, "amount": 70})
    L.cmd(500, {"system": "build", "op": "place_area", "kind": "rubble_road",
                "from": [CORE[0] - 4, CORE[1] + 10], "to": [CORE[0] + 4, CORE[1] + 13]})
    L.cmd(620, {"system": "build", "op": "rotate", "cell": [CORE[0] - 8, CORE[1] + 4]})
    L.cmd(700, {"system": "build", "op": "undo"})
    L.cmd(760, {"system": "build", "op": "redo"})
    L.cmd(900, {"system": "build", "op": "capture_blueprint",
                "from": [CORE[0] + 3, CORE[1] - 1], "to": [CORE[0] + 16, CORE[1] + 1],
                "title": "spur", "blueprint_id": "spur"})
    L.cmd(1000, {"system": "build", "op": "place_blueprint", "blueprint": "spur",
                 "cell": [CORE[0] + 24, CORE[1] + 24], "free": True})
    L.cmd(1200, {"system": "climate", "op": "skip_to_phase", "phase": "dusk"})
    L.place(1600, "housing_block", -16, -6)
    L.cmd(1900, {"system": "build", "op": "remove", "cell": [CORE[0] + 15, CORE[1] - 1]})
    L.cmd(2200, {"system": "climate", "op": "skip_to_phase", "phase": "night"})
    L.place(2500, "watchtower", 18, -10)
    L.cmd(2800, {"system": "grid", "op": "snowfall", "rate": 0.2})
    L.cmd(3100, {"system": "climate", "op": "set_day", "day": 3})
    L.place(3400, "coal_generator", 8, 16)
    L.line(3600, "heat_pipe", (0, 3), (0, 8))
    L.cmd(3900, {"system": "heat", "op": "dump"})
    return {
        "name": "determinism",
        "description": ("Pokes every system that owns an Rng stream or a mutable cache: "
                        "climate storms and day jumps, grid snowfall and melt, the heat "
                        "network's routing cache, and build's undo/redo and blueprint "
                        "algebra. tools/determinism.sh replays it in two separate processes "
                        "and diffs the state byte for byte."),
        "tags": ["determinism", "gate"],
        "seed": 1337, "ticks": 4000, "sample_every": 10,
        "expects": {"min_ticks_per_second": 300, "max_errors": 0},
        "script": L.script,
        "_layout": L,
        # Islands are the POINT here. A house dropped in the snow, a watchtower
        # on the far ridge and a stamped blueprint 24 tiles out are what make
        # HeatGraph split and re-merge components, which is the cache this
        # scenario exists to prove deterministic. Everything that has to carry
        # flow is on the grid; everything else is deliberately not.
        "_allow_islands": 5,
        "shots": [],
    }


# -------------------------------------------------------------- stress_1000
def stress():
    L = Layout()
    L.stock(1, {k: 90000 for k in ["iron_plate", "steel_plate", "stone", "timber",
                                   "scrap", "gear", "copper_coil", "coal"]})
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    t = 10
    # One connected grid: east-west trunks crossed by north-south spurs. The
    # spurs run the FULL height of the trunk block (-30..30 inclusive) so every
    # crossing exists; a spur that stopped one row short left the outer trunks
    # hanging as their own little networks.
    for dy in range(-30, 31, 6):
        L.line(t, "heat_pipe", (-40, dy), (40, dy), free=True, instant=True)
        t += 3
    for dx in range(-40, 41, 8):
        # Two rows past the last trunk on each side: the plots that hug the
        # outermost trunk sit at rows 31-32, and a spur that stopped at 30 left
        # them with bare ground on every side.
        L.line(t, "heat_pipe", (dx, -32), (dx, 32), free=True, instant=True)
        t += 3
    # The hearth sits inside the block but its 5x5 footprint spans dx -2..2,
    # which no trunk or spur passes through. One stub joins it to the spur at
    # dx = 8, and without it the biggest producer on the map feeds nothing.
    L.line(t, "heat_pipe", (3, 0), (8, 0), free=True, instant=True)
    t += 3
    # Every plot sits in the pocket between one trunk and the next, one tile in
    # from both, so it is orthogonally adjacent to the grid on two sides.
    n = 0
    order = ["warmth_radiator", "housing_block", "coal_generator", "watchtower", "turret_mount"]
    skipped = 0
    for row in range(-30, 31, 6):
        for col in range(-40, 41, 8):
            if abs(col) < 8 and abs(row) < 8:
                continue
            kind = order[n % len(order)]
            n += 1
            origin = (CORE[0] + col + 1, CORE[1] + row + 1)
            # A plot must be free AND reach a CONDUIT, not merely "reach a heat
            # tag". Two generators used to pass the old test by touching a
            # housing block, which links nothing: HeatGraph needs a conductor on
            # at least one side of every edge.
            if not (L.free(kind, origin) and _reaches_conduit(L, kind, origin)):
                skipped += 1
                continue
            L.place(t, kind, col + 1, row + 1, free=True, instant=True)
            t += 2
    assert skipped == 0, "%d plots did not reach the grid" % skipped
    # A full perimeter wall. Most of a real city is buildings no system owns,
    # and that is exactly the case that used to eat the entire tick budget.
    for a, b in [((-46, -36), (46, -36)), ((-46, 36), (46, 36)),
                 ((-46, -36), (-46, 36)), ((46, -36), (46, 36))]:
        L.line(t, "wall", a, b, free=True, instant=True)
        t += 4
    L.cmd(t + 10, {"system": "grid", "op": "snowfall", "rate": 0.6})
    L.cmd(t + 40, {"system": "climate", "op": "skip_to_phase", "phase": "night"})
    L.cmd(t + 80, {"system": "heat", "op": "dump"})
    return {
        "name": "stress_1000",
        "description": ("The performance gate. Builds a city of well over a thousand "
                        "structures on ONE connected heat grid - trunks, spurs, radiators, "
                        "housing, generators and a full perimeter wall - then runs it "
                        "through nightfall under load. Every heat entity on the map is in "
                        "the same network, which is the expensive case: HeatFlow's "
                        "progressive fill over a single 1400-node component is the ceiling "
                        "on the whole tick budget, and it is measured here rather than "
                        "hidden behind three dozen private one-node networks. The floor is "
                        "35 ticks/s, measured; the 400 target stands as the bar it has to "
                        "reach. There are no hostiles in it because [P07]/[P08] have not "
                        "landed - a scenario may not address a system this build does not "
                        "have (see tests/p00/test_scenarios.gd), so the combat half of the "
                        "stress test is owed, not forgotten."),
        "tags": ["perf", "gate"],
        "seed": 4242, "ticks": 3000, "sample_every": 50,
        "expects": {"min_ticks_per_second": 35, "target_ticks_per_second": 400,
                    "max_errors": 0, "min_buildings": 1000, "max_heat_networks": 1},
        "script": L.script,
        "_layout": L,
        "shots": [],
    }


# ------------------------------------------------------------ economy_60min
#
# THE BALANCE INSTRUMENT. Everything about this scenario exists to be measured:
# tools/analyze_balance.py grades its metrics.csv against
# game/content/economy/difficulty_curve.tres, day by day. Read that curve and
# game/content/economy/BALANCE.md before changing a number here — the shape of
# this run IS the designed difficulty curve, and moving a generator moves it.
#
# Layout: a vertical spine at dx = +3 hanging off the Hearth's east face, with
# horizontal rungs every ten rows. Plots hug a rung on one side or the other,
# which is what puts every building on the same network as the Hearth.

# Kept close to the caldera floor on purpose. The map is generated at runtime
# and this script cannot see terrain, so a rung that reaches thirty tiles out
# eventually crosses rock, `place_line` skips those cells, and the far half of
# the rung becomes a private network with a radiator freezing on it. That is
# exactly the failure this file's header is about, and the answer is to stay on
# ground the biome generator keeps flat. `tools/analyze_balance.py` checks the
# result against `expects.max_heat_networks` on every run, so if this ever stops
# being true the balance report says so instead of quietly measuring a ruin.
ECON_SPINE_DX = 3
ECON_RUNGS = (-16, -8, 8, 16)
ECON_ARM = 15               # rung reach either side of the spine


class Row:
    """A cursor walking outward along one rung, packing plots that touch it."""

    def __init__(self, layout, dy, side, above=False):
        self.L = layout
        self.dy = dy
        self.side = side                       # -1 west of the spine, +1 east
        self.above = above
        self.cursor = ECON_SPINE_DX + (2 * side)

    def add(self, tick, kind, gap=1, **kw):
        w, h = DEFS[kind][0], DEFS[kind][1]
        # Origin row: the building's near edge has to share a border with the
        # rung, never merely a corner.
        dy = self.dy - h if self.above else self.dy + 1
        if self.side > 0:
            dx = self.cursor
            self.cursor = dx + w + gap
        else:
            dx = self.cursor - w
            self.cursor = dx - gap
        assert abs(dx) <= ECON_ARM + ECON_SPINE_DX + 8, \
            "%s at dx=%d has walked off the rung at dy=%d" % (kind, dx, self.dy)
        self.L.place(tick, kind, dx, dy, **kw)
        return dx


def economy():
    L = Layout()
    # Generous but not infinite: the point of this run is the HEAT curve, so a
    # material shortfall must never be what stalls it. Materials are read off
    # build.materials in the report as a sanity line, not as the constraint.
    stock = {k: 40000 for k in ["iron_plate", "steel_plate", "stone", "timber",
                                "scrap", "gear", "copper_coil", "coal"]}
    # Food is PROVISIONED, not simulated. This run measures the heat curve, and
    # an unbuilt salvage-to-kitchen chain starving the city on day four does not
    # make the heat reading harder, it makes it meaningless: a dead city draws
    # no heat. The food economy gets its own instrument when [P03] logistics can
    # actually carry grain across the map.
    stock["grain"] = 9000
    stock["ration"] = 9000
    L.stock(1, stock)
    L.unlock(2, "thermal_storage", "pressurised_mains")

    # --- the city that already stands at dawn on day one ---------------------
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    L.line(4, "heat_pipe", (ECON_SPINE_DX, -ECON_ARM - 3), (ECON_SPINE_DX, ECON_ARM + 3),
           free=True, instant=True)
    for dy in ECON_RUNGS:
        L.line(5, "heat_pipe", (ECON_SPINE_DX, dy), (ECON_SPINE_DX - ECON_ARM, dy),
               free=True, instant=True)
        L.line(5, "heat_pipe", (ECON_SPINE_DX, dy), (ECON_SPINE_DX + ECON_ARM, dy),
               free=True, instant=True)

    # Rungs are consumed in this order, so the city grows outward from the
    # hearth rather than teleporting a district to the map edge on day six.
    below = {dy: {s: Row(L, dy, s, above=False) for s in (1, -1)} for dy in ECON_RUNGS}
    above = {dy: {s: Row(L, dy, s, above=True) for s in (1, -1)} for dy in ECON_RUNGS}

    # Two radiators and two housing blocks are the starting settlement.
    below[-8][1].add(8, "warmth_radiator", free=True, instant=True)
    below[8][-1].add(9, "warmth_radiator", free=True, instant=True)
    above[8][1].add(10, "housing_block", free=True, instant=True)
    above[-8][-1].add(11, "housing_block", free=True, instant=True)

    # --- the campaign --------------------------------------------------------
    # One entry per day: what an ATTENTIVE, NOT OPTIMAL player gets built during
    # the light half. That distinction is the whole calibration. A play-through
    # that puts two generators up on day one measures a good player; the design
    # target is the person who gets one up, is frightened by the first night,
    # and buys a second the next morning. The generator count is deliberately
    # back-loaded for exactly that reason.
    plan = [
        # day 1: ONE generator before the first dusk. This is the beginner's
        #        line: build it and survive on the buffer, skip it and do not.
        (1, ["coal_generator", "storage_yard", "housing_block"]),
        # day 2: the squeeze. Homes arrive faster than the grid grows, and the
        #        shed order becomes something the player can feel.
        (2, ["coal_generator", "housing_block", "housing_block", "workshop"]),
        # day 3: FIRST FROST at dusk. Thermal storage is the answer and it is
        #        already unlocked; a player who spends the day on housing
        #        instead loses the district.
        (3, ["coal_generator", "coal_generator", "heat_accumulator",
             "warmth_radiator"]),
        (4, ["coal_generator", "coal_generator", "housing_block",
             "housing_block", "granary"]),
        (5, ["coal_generator", "coal_generator", "warmth_radiator",
             "housing_block", "field_kitchen"]),
        (6, ["coal_generator", "coal_generator", "coal_generator",
             "housing_block", "housing_block"]),
        # day 7: SECOND FROST, and the last day the run covers in full. The
        #        booster pump is what keeps the far rungs alive through it.
        (7, ["coal_generator", "coal_generator", "coal_generator",
             "heat_booster_pump", "housing_block"]),
    ]

    # Rung/side rotation. Radiators and generators go below the rung, housing
    # above it, so a district reads as street-then-homes rather than as noise.
    slots = [(dy, s) for dy in (-8, 8, -16, 16) for s in (1, -1)]
    slot_i = 0
    day_ticks = 9600
    for day, kinds in plan:
        # Spread the day's work across morning and afternoon: the harness
        # applies a command on the tick it names, and construction takes real
        # time, so the last building of a day must finish before dusk (5376).
        start = (day - 1) * day_ticks + 400
        span = 4200
        step = span // max(1, len(kinds))
        for i, kind in enumerate(kinds):
            t = start + i * step
            dy, side = slots[slot_i % len(slots)]
            slot_i += 1
            rows = above if kind == "housing_block" else below
            rows[dy][side].add(t, kind)

    # --- what this instrument deliberately holds still -----------------------
    # An instrument measures one variable. These two lines are what keep the
    # heat curve above from being a reading of something else entirely, and both
    # use an op the owning system provides for exactly this purpose:
    #
    #  * PEACE. [P08]'s director is live and it works: without this the city
    #    loses 143 structures by day 8 and the "heat margin" is really a graph of
    #    how fast the wave director eats a base with no turrets on it. Combat
    #    balance is measured in first_night, which keeps its walls and its guns.
    #  * FUEL. [P03] hauls coal to burners with citizens, so an unfuelled Hearth
    #    is a reading of the hauling chain, not of the grid. Topping the bunkers
    #    up every sixty seconds isolates the heat network, which is what this run
    #    is for. The measured consequence of NOT doing it is in BALANCE.md, and
    #    it is the sharpest finding in this whole part.
    L.cmd(6, {"system": "threat", "op": "peace", "on": True})
    for refuel in range(1, 60):
        L.cmd(refuel * 1200, {"system": "heat", "op": "fuel_all",
                              "item": "coal", "amount": 400})

    # Weather the player cannot dodge, on the ticks the report reads.
    L.cmd(1200, {"system": "grid", "op": "snowfall", "rate": 0.35})
    L.cmd(2 * day_ticks + 1000, {"system": "grid", "op": "snowfall", "rate": 0.55})
    # A grid dump at the end of the first night and again after the second
    # storm: state.json then carries the bottleneck list from both, which is the
    # per-consumer attribution a critic should be able to read off a balance run.
    L.cmd(8800, {"system": "heat", "op": "dump"})
    L.cmd(6 * day_ticks + 8000, {"system": "heat", "op": "dump"})
    return {
        "name": "economy_60min",
        "description": ("THE BALANCE RUN. Seven and a half campaign days of a city that "
                        "actually grows: a Hearth, a spine, four rungs, and a district "
                        "added every morning - two generators, homes and a radiator - all "
                        "on one heat network. Sampled every ten seconds, it is the input to "
                        "tools/analyze_balance.py, which grades every night against "
                        "game/content/economy/difficulty_curve.tres. The First Frost lands "
                        "at dusk on day 3 and the Second on day 7, both from the fixed "
                        "calendar in [P09], so the two hardest nights in the run are the "
                        "two the player could see coming from minute one. Read it with "
                        "game/content/economy/BALANCE.md open."),
        "tags": ["balance", "long"],
        "seed": 11, "ticks": 72000, "sample_every": 200,
        "expects": {"min_ticks_per_second": 250, "max_errors": 0,
                    "balance_days": [1, 2, 3, 4, 5, 6, 7], "max_heat_networks": 1},
        "script": L.script,
        "_layout": L,
        "shots": [],
    }


def _reaches_conduit(layout, kind, origin):
    """True when this footprint would share a border with a conducting cell.

    The rule HeatGraph actually applies. A conduit trivially reaches itself once
    placed, so it only has to reach the grid if it is meant to extend it.
    """
    own = set(layout.cells(kind, origin))
    for (cx, cy) in own:
        for dx, dy in NEIGHBOURS:
            n = (cx + dx, cy + dy)
            if n in own:
                continue
            if layout.occ.get(n) in CONDUCTS:
                return True
    return kind in CONDUCTS


if __name__ == "__main__":
    for build in (smoke, first_night, determinism, stress, economy):
        write(build())

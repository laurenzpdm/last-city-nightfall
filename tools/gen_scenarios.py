#!/usr/bin/env python3
"""Regenerates tests/scenarios/*.json.

The scenario library is data the harness executes, and hand-editing JSON is how
it drifted into placing buildings that do not exist on top of each other. This
script owns the layouts instead: it knows every definition's footprint and the
heat-connection rule, and it refuses to emit a command that would be refused at
runtime. Run it, then run tools/check.sh.

    python3 tools/gen_scenarios.py
"""

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "scenarios")

# id -> (w, h, needs_heat_neighbour)
DEFS = {
    "coal_generator": (3, 2, False),
    "field_kitchen": (3, 2, False),
    "geothermal_tap": (3, 3, False),
    "granary": (3, 3, False),
    "heat_accumulator": (2, 2, True),
    "heat_booster_pump": (1, 1, True),
    "heat_pipe": (1, 1, False),
    "housing_block": (4, 4, False),
    "ore_drill": (3, 3, False),
    "rubble_road": (1, 1, False),
    "scrap_collector": (2, 2, False),
    "smelter": (3, 3, False),
    "storage_yard": (3, 3, False),
    "the_hearth": (5, 5, False),
    "turret_mount": (2, 2, False),
    "wall": (1, 1, False),
    "warmth_radiator": (2, 2, True),
    "watchtower": (2, 2, False),
    "workshop": (4, 3, False),
}
# Kinds that satisfy a must_connect(&"heat") test.
HEAT_TAGS = {"heat_pipe", "the_hearth", "coal_generator", "geothermal_tap",
             "heat_accumulator", "heat_booster_pump"}

CORE = (128, 128)


class Layout:
    """Occupancy bookkeeping, so a generated scenario cannot self-collide."""

    def __init__(self):
        self.occ = {}          # cell -> kind
        self.script = []

    def cells(self, kind, origin):
        w, h, _ = DEFS[kind]
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
    scenario["script"] = sorted(scenario["script"], key=lambda e: e["tick"])
    for e in scenario["script"]:
        assert 1 <= e["tick"] <= scenario["ticks"], (scenario["name"], e)
    rows = scenario["ticks"] // scenario["sample_every"]
    assert 20 <= rows <= 4000, (scenario["name"], rows)
    path = os.path.join(OUT, scenario["name"] + ".json")
    with open(path, "w") as f:
        json.dump(scenario, f, indent=2)
        f.write("\n")
    print("%-14s %3d commands, %4d metric rows, last tick %d" % (
        scenario["name"], len(scenario["script"]), rows,
        scenario["script"][-1]["tick"]))


# --------------------------------------------------------------------- smoke
def smoke():
    L = Layout()
    L.stock(1, {"iron_plate": 900, "steel_plate": 600, "stone": 900, "timber": 600})
    L.place(2, "the_hearth", -2, -2, free=True, instant=True)
    L.line(3, "heat_pipe", (3, 0), (12, 0), free=True, instant=True)
    L.line(4, "heat_pipe", (-3, 0), (-12, 0), free=True, instant=True)
    L.line(5, "heat_pipe", (0, 3), (0, 10), free=True, instant=True)
    L.place(6, "warmth_radiator", 13, -1, free=True, instant=True)
    L.place(7, "warmth_radiator", -14, -1, free=True, instant=True)
    L.place(8, "housing_block", 5, 3, free=True, instant=True)
    L.place(9, "housing_block", -9, 3, free=True, instant=True)
    L.place(10, "coal_generator", -3, 11, free=True, instant=True)
    L.place(11, "workshop", 1, 11, free=True, instant=True)
    L.place(12, "storage_yard", 10, 4, free=True, instant=True)
    L.place(13, "watchtower", 14, -9, free=True, instant=True)
    L.place(14, "turret_mount", 14, 9, free=True, instant=True)
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
    L.place(6, "warmth_radiator", 13, -1, free=True, instant=True)
    L.place(7, "warmth_radiator", -14, -1, free=True, instant=True)
    L.place(8, "housing_block", 5, 3, free=True, instant=True)
    L.place(9, "housing_block", -9, 3, free=True, instant=True)
    # Everything after this the player pays for, in build order.
    L.line(400, "heat_pipe", (0, 3), (0, 13))
    L.place(600, "coal_generator", -4, 14)
    L.place(900, "workshop", 1, 14)
    L.place(1200, "storage_yard", 10, 4)
    L.line(1500, "heat_pipe", (-1, 8), (-8, 8))
    L.place(1800, "warmth_radiator", -10, 7)
    L.place(2100, "housing_block", -9, 9)
    L.place(2600, "granary", 6, 8)
    L.place(3000, "field_kitchen", -4, -8)
    L.line(3400, "heat_pipe", (12, 1), (12, 8))
    L.place(3800, "heat_accumulator", 13, 8)
    # Industry reaches out to the coal seam north of the basin.
    L.line(4000, "heat_pipe", (0, -3), (-2, -18))
    L.place(4200, "ore_drill", -4, -30)
    L.place(4600, "smelter", 2, -20)
    # The wall goes up before dusk.
    for i, dx in enumerate([-18, -9, 0, 9, 18]):
        L.line(5000 + i * 40, "wall", (dx - 4, -34), (dx + 4, -34))
    L.place(5300, "watchtower", -16, -32)
    L.place(5400, "watchtower", 14, -32)
    L.place(5600, "turret_mount", -2, -32)
    L.place(5800, "turret_mount", 10, -32)
    # Night: the grid is under load and the player reacts to it.
    L.place(6600, "heat_booster_pump", 1, 12)
    L.cmd(7000, {"system": "build", "op": "set_enabled", "cell": [CORE[0] + 1, CORE[1] + 14], "on": False})
    L.cmd(7400, {"system": "heat", "op": "dump"})
    L.cmd(7800, {"system": "grid", "op": "melt", "cell": [CORE[0], CORE[1]], "radius": 6, "amount": 90})
    L.cmd(8600, {"system": "build", "op": "set_enabled", "cell": [CORE[0] + 1, CORE[1] + 14], "on": True})
    L.place(9000, "coal_generator", 4, 17)
    L.place(10200, "housing_block", -9, -6)
    return {
        "name": "first_night",
        "description": ("The reference run. One full day and into the next: a hearth is lit, "
                        "a heat grid grows out of it, housing and industry hang off the grid, "
                        "a wall goes up before dusk, and the night is spent short of heat. "
                        "This is what the art, audio and UI parts screenshot against."),
        "tags": ["reference", "gate", "visual"],
        "seed": 7, "ticks": 11000, "sample_every": 20,
        "expects": {"min_ticks_per_second": 300, "max_errors": 0},
        "script": L.script,
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
    L.place(200, "coal_generator", -7, 6)
    L.cmd(260, {"system": "grid", "op": "snowfall", "rate": 0.9})
    L.cmd(300, {"system": "climate", "op": "force_storm",
                "intensity": 0.85, "duration_ticks": 900})
    L.cmd(420, {"system": "grid", "op": "melt",
                "cell": [CORE[0], CORE[1]], "radius": 5, "amount": 70})
    L.cmd(500, {"system": "build", "op": "place_area", "kind": "rubble_road",
                "from": [CORE[0] - 4, CORE[1] + 10], "to": [CORE[0] + 4, CORE[1] + 13]})
    L.cmd(620, {"system": "build", "op": "rotate", "cell": [CORE[0] - 7, CORE[1] + 6]})
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
        "shots": [],
    }


# -------------------------------------------------------------- stress_1000
def stress():
    L = Layout()
    L.stock(1, {k: 90000 for k in ["iron_plate", "steel_plate", "stone", "timber",
                                   "scrap", "gear", "copper_coil", "coal"]})
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    t = 10
    # One connected grid: east-west trunks crossed by north-south spurs.
    for dy in range(-30, 31, 6):
        L.line(t, "heat_pipe", (-40, dy), (40, dy), free=True, instant=True)
        t += 3
    for dx in range(-40, 41, 8):
        L.line(t, "heat_pipe", (dx, -30), (dx, 30), free=True, instant=True)
        t += 3
    n = 0
    order = ["warmth_radiator", "housing_block", "coal_generator", "watchtower", "turret_mount"]
    for dy in range(-28, 29, 6):
        for dx in range(-38, 39, 8):
            if abs(dx) < 6 and abs(dy) < 6:
                continue
            kind = order[n % len(order)]
            n += 1
            origin = (CORE[0] + dx + 1, CORE[1] + dy + 1)
            if not (L.free(kind, origin) and L.touches_heat(kind, origin)):
                continue
            L.place(t, kind, dx + 1, dy + 1, free=True, instant=True)
            t += 2
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
                        "structures on one connected heat grid - trunks, spurs, radiators, "
                        "housing, generators and a full perimeter wall - then runs it "
                        "through nightfall."),
        "tags": ["perf", "gate"],
        "seed": 4242, "ticks": 3000, "sample_every": 50,
        "expects": {"min_ticks_per_second": 100, "target_ticks_per_second": 400,
                    "max_errors": 0, "min_buildings": 1000},
        "script": L.script,
        "shots": [],
    }


# ------------------------------------------------------------ economy_60min
def economy():
    L = Layout()
    L.stock(1, {k: 60000 for k in ["iron_plate", "steel_plate", "stone", "timber",
                                   "scrap", "gear", "copper_coil", "coal"]})
    L.unlock(2, "thermal_storage", "pressurised_mains")
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    for a, b in [((3, 0), (34, 0)), ((-3, 0), (-34, 0)),
                 ((0, 3), (0, 34)), ((0, -3), (0, -34))]:
        L.line(5, "heat_pipe", a, b, free=True, instant=True)
    for dy in [-24, -12, 12, 24]:
        L.line(6, "heat_pipe", (-34, dy), (34, dy), free=True, instant=True)
    t = 200
    plots = []
    for dy in [-24, -12, 12, 24]:
        for dx in [-30, -18, 18, 30]:
            plots.append((dx, dy))
    for i, (dx, dy) in enumerate(plots):
        # Radiators hug the trunk, housing and generators sit one row clear of it.
        L.place(t, "warmth_radiator", dx, dy + 1)
        t += 700
        L.place(t, "housing_block", dx + 3, dy + 1)
        t += 700
        L.place(t, "coal_generator", dx, dy + 4)
        t += 700
    for i in range(6):
        L.place(t, "workshop", -30 + i * 11, -34)
        t += 600
        L.place(t, "storage_yard", -30 + i * 11, -30)
        t += 600
    L.place(t, "heat_accumulator", 1, 20)
    t += 700
    L.place(t, "heat_booster_pump", -1, 20)
    t += 700
    L.place(t, "granary", 6, 29)
    t += 700
    L.place(t, "field_kitchen", 12, 29)
    t += 700
    L.cmd(t, {"system": "climate", "op": "skip_to_phase", "phase": "night"})
    t += 60
    L.cmd(t, {"system": "heat", "op": "dump"})
    t += 60
    L.cmd(t, {"system": "grid", "op": "snowfall", "rate": 0.5})
    t += 600
    for i in range(6):
        L.place(t, "housing_block", -30 + i * 11, 34)
        t += 700
    L.cmd(t, {"system": "heat", "op": "dump"})
    return {
        "name": "economy_60min",
        "description": ("One hour of simulated city growth on one heat grid, sampled every "
                        "ten seconds. The balance read: does supply keep up with a city that "
                        "keeps adding housing, does the deficit curve bend on the right day, "
                        "and how many nights does the grid survive as the campaign cools."),
        "tags": ["balance", "long"],
        "seed": 11, "ticks": 72000, "sample_every": 200,
        "expects": {"min_ticks_per_second": 400, "max_errors": 0},
        "script": L.script,
        "shots": [],
    }


if __name__ == "__main__":
    for build in (smoke, first_night, determinism, stress, economy):
        write(build())

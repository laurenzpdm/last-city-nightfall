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
    # --- [P03] logistics ------------------------------------------------------
    # These were missing entirely, which is WHY first_night moves zero items over
    # 11000 ticks while its contract asserts logistics.items_moved >= 1. It was
    # never a logistics bug — tests/logistics/ lays belts and moves items and
    # passes its bands. This generator simply had no vocabulary for a belt, so no
    # scenario it emits could contain one, and the flagship run that the art,
    # audio and UI parts screenshot against has no automation in it at all.
    #
    # Footprints are the ones in game/content/buildings/*.tres, which is what
    # build actually enforces. None of them take or conduct heat, and none are
    # nodes in the heat graph, so all three flags are False.
    "belt_mk1": (1, 1, False, False, False),
    "crate": (1, 1, False, False, False),
    "inserter_mk1": (1, 1, False, False, False),
    "long_arm_mk1": (1, 1, False, False, False),
    "splitter_mk1": (1, 2, False, False, False),
    "underground_mk1": (1, 1, False, False, False),
    # --------------------------------------------------------------------------
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
    "recuperator": (2, 2, False, False, True),
    "rubble_road": (1, 1, False, False, False),
    "rubble_sorter": (3, 2, False, False, True),
    "scrap_collector": (2, 2, False, False, True),
    "smelter": (3, 3, False, False, True),
    "storage_yard": (3, 3, False, False, False),
    "survey_hall": (3, 3, False, False, True),
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

    def place(self, tick, kind, dx, dy, free=False, instant=False, rot=None):
        origin = (CORE[0] + dx, CORE[1] + dy)
        assert self.free(kind, origin), f"{kind} at {origin} overlaps {[self.occ.get(c) for c in self.cells(kind, origin) if c in self.occ][:3]}"
        assert self.touches_heat(kind, origin), f"{kind} at {origin} touches no heat conduit"
        self.claim(kind, origin)
        cmd = {"system": "build", "op": "place", "kind": kind,
               "cell": [origin[0], origin[1]]}
        if rot is not None:
            cmd["rot"] = rot
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
        return laid

    def cmd(self, tick, payload):
        self.script.append({"tick": tick, "cmd": payload})

    def urgent(self, tick, cells, priority=95):
        """Marks finished-or-queued sites as the next thing the crew does.

        THE QUEUE IS A DESIGN SURFACE AND IT IS ALSO A TRAP. Sites are served
        (priority desc, tick asc, id asc) and the priorities are content: a wall
        is 85, a heat pipe 80, a coal generator 60, a belt 55, an inserter 54
        and a storage yard 40. So a city that lays its grid, its wall and its
        housing in the first two hundred ticks has, by construction, put its
        coal yard last — which is exactly what happened here: the yard finished
        at t14841, the belt carried its first item at t17620, and every burner
        in the run was starving on an empty line while 1114 units of coal went
        past on somebody's back. Marking the supply chain urgent is what a
        player does with a right-click, and it is the only reason the automation
        in this scenario is running before the first night instead of after the
        second.
        """
        for (x, y) in cells:
            self.cmd(tick, {"system": "build", "op": "set_priority",
                            "cell": [x, y], "priority": priority})

    def recipe(self, tick, origin_delta, recipe_id):
        """Names a machine's recipe by the offset it was PLACED at.

        `set_recipe` on a cell holding a construction site is a standing order
        (game/sim/production/production_system.gd), so the only correct tick to
        name a recipe on is the tick the machine goes down. Waiting for the site
        to finish is a guess about the build queue, and in the old first_night
        that guess was 6400 ticks wrong.
        """
        self.cmd(tick, {"system": "production", "op": "set_recipe",
                        "cell": [CORE[0] + origin_delta[0], CORE[1] + origin_delta[1]],
                        "recipe": recipe_id})

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
        "expects": {"min_ticks_per_second": 300, "max_errors": 0},
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
#
# THE REFERENCE RUN, AND WHAT IT USED TO BE.
#
# Driven to 24000 ticks, the old version of this scenario ended with 5 of 5
# machines stalled, `production.ipm.ration` at 0.0 for three in-game days, half
# rations declared at t15230, the population exiling the player at t22380, and
# 96% of all fuel in the run (1362 of 1413 units) carried on a porter's back.
# Tutorial lesson 05 is called "You cannot click fast enough". The run this
# whole project screenshots against had not learned it.
#
# THREE MEASURED CAUSES, all of them in this file, none of them in [P02]/[P04]:
#
#  1. BOTH COAL GENERATORS WERE FROZEN AT THE FINAL TICK, WITH FULL BUNKERS.
#     They stood at (124,142) and (129,145), 14 and 17 tiles from the Hearth's
#     footprint, where its warmth field is worth about 3 C. A burner keeps
#     itself at (ground + 11 C) and freezes at -10, so it survives only while
#     the ground under it is warmer than about -21 C; this map's ambient bottoms
#     out at -32.85. Once frozen its radiance goes to zero, which is why neither
#     ever thawed: a dead burner needs +30 C of SOMEBODY ELSE's warmth to come
#     back. economy_60min had this written down as THE WARMTH-COVER LAW and this
#     scenario had never applied it. Every burner now stands within 5 tiles of
#     the Hearth's own field, in a single row along its north face.
#
#  2. SO SUPPLY WAS THE HEARTH ALONE — 138.9 against a demand of 190.9 — and
#     [P02] sheds by priority. Industry is tier 50 and housing is tier 90, so a
#     27% shortfall does not brown the city out evenly: it takes EVERY unit away
#     from the factory. `rubble_sorter` read `power 0.0000` at every single
#     checkpoint of the run. It was not a production bug and not a heat bug; it
#     was this file building 197 heat entities against one working generator.
#
#  3. AND THE FIELD KITCHEN READ `missing_input: grain` FOREVER, because grain
#     comes from `salvaged_stores`, which is run by the sorter that never got a
#     joule. One under-built grid, and the food chain, the ration counter, hope
#     and the ending all fall out of it in that order.
#
# WHAT REPLACES IT: supply first and warm, then the chain that eats it.
#   * five coal generators in one row along the Hearth's north face, every one
#     of them inside its warmth field, each loaded by an inserter off ONE belt
#     that runs the length of the row out of a coal yard. That belt is the
#     automation pillar and it has teeth: [P03] stands the porters down for any
#     burner an arm is feeding (`_line_fed`), so if the line runs dry the
#     burners die and the run says so.
#   * a coal drill on the seam at (124,97) — measured, not guessed: a probe
#     placed a drill on every 3x3 site in the basin and read back `seam_item`,
#     and coal is the field at 30 tiles due north, behind the wall line. It
#     keeps the yard filled through a standing `request`, so the belt is fed by
#     mining rather than by the founders' pile running out on day two.
#   * the salvage strip: two rubble sorters, one on `salvaged_stores` for grain
#     and one on `sorted_rubble` for the iron ore the smelter runs on, two scrap
#     collectors keeping them in feedstock, and the field kitchen next to them.
#     scrap -> grain -> ration, closed, on the same grid, and warm.
#
# WARMTH IS THE PLACEMENT RULE HERE, not proximity to a pipe. A building's
# internal temperature is (ambient + radiated warmth + 1.6 C per unit of heat it
# is actually served) and it freezes at -10 C. That means a 1-unit watchtower
# needs +20 C of radiated cover to survive a -32 C night while a 9-unit housing
# block needs none. Every position below was checked against the smoothstep
# falloff in game/sim/heat/warmth_field.gd at the coldest ambient the run
# reaches, and anything thin is standing next to a radiator on purpose.
def first_night():
    L = Layout()
    # Materials, not a cheat code: the old stock ran dry on day two and FOUR
    # placements were refused for cost, which is why the workshop and the
    # smelter are missing from that run's building list entirely. Coal is 1800
    # because the Hearth alone burns 0.8/s and the drill does not land until the
    # afternoon.
    L.stock(1, {"iron_plate": 3200, "steel_plate": 1400, "stone": 2600,
                "timber": 2200, "scrap": 1600, "gear": 700, "copper_coil": 500,
                "coal": 1800, "grain": 1600})
    # GRAIN IS SEED STOCK, NOT A CHEAT. The kitchen turns 2 grain into 3
    # rations, so the founders' store is what feeds the city while the sorters
    # are still being built — and [P05] gates arrivals on
    # `food_days_remaining() >= 0.75`, which means a city that runs its larder
    # down stops growing, stops crewing its machines, and cannot ever climb out.
    # The old run hit food_days 0.09 and never took another arrival after t14000
    # with 36 people and 49 job slots. What the band asserts is `produced.grain`
    # AND `produced.ration`: the seed store proves nothing on its own, and the
    # sorters making more grain than the kitchen eats is the actual claim.
    L.unlock(2, "thermal_storage", "pressurised_mains")
    # The city that already stands when the day begins. UNCHANGED — the
    # "opening" shot at t=30 is what every art and UI part screenshots against.
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    L.line(4, "heat_pipe", (3, 0), (12, 0), free=True, instant=True)
    L.line(5, "heat_pipe", (-3, 0), (-12, 0), free=True, instant=True)
    L.line(6, "heat_pipe", (3, 2), (12, 2), free=True, instant=True)
    L.line(7, "heat_pipe", (-3, 2), (-12, 2), free=True, instant=True)
    L.place(8, "warmth_radiator", 13, -1, free=True, instant=True)
    L.place(9, "warmth_radiator", -14, -1, free=True, instant=True)
    L.place(10, "housing_block", 5, 3, free=True, instant=True)
    L.place(11, "housing_block", -9, 3, free=True, instant=True)

    # === SUPPLY FIRST, AND WARM =============================================
    # A main, not a pipe: five burners pushing 150 u/s past a Hearth that is not
    # a conduit would saturate a 60-capacity heat_pipe. `heat_trunk_main`
    # carries 220 and radiates its 4 C minimum along the row it makes.
    L.line(20, "heat_trunk_main", (-16, -3), (15, -3))
    # THE TWO BYPASSES, AND THE MEASUREMENT THAT PUT THEM THERE.
    #
    # The Hearth generates; it does not conduct, and [HeatFlow._route] only lets
    # a non-conductor forward heat when it is ITSELF the source. So nothing —
    # not one unit — routes through the Hearth from the burner row to the rest
    # of the city. The version of this layout without these two columns measured
    # exactly that: generator (127,123) sat at output 0.00 with a full bunker,
    # (123,123) at 7.0, while 34 consumers browned out under a 102-unit deficit.
    # The heat was real, the grid was one network, and there was no route.
    #
    # A `heat_pipe` carries 60 and a `heat_trunk_main` carries 220, so these are
    # mains: everything the north row makes has to get south down one of two
    # columns, and 2 x 60 would have stranded a third of it just as surely.
    L.line(24, "heat_trunk_main", (-16, -3), (-16, 6))
    L.line(28, "heat_trunk_main", (15, -3), (15, 6))
    # Short elbows into the founding rows as well, so the west and east streets
    # are fed from the burners and not only from the Hearth's own two faces.
    L.line(32, "heat_trunk_main", (-12, -3), (-12, -1))
    L.line(34, "heat_trunk_main", (12, -3), (12, -1))

    urgent = []
    # THE COAL YARD AND THE LINE OUT OF IT, before anything that burns: [P03]
    # stands the porters down for a burner an arm is feeding, so a burner
    # finished before its belt is a burner nobody is allowed to walk coal to.
    L.place(30, "storage_yard", -15, -8)                    # x113-115, y120-122
    urgent.append((CORE[0] - 15, CORE[1] - 8))
    L.place(40, "inserter_mk1", -12, -7, rot=0)             # yard -> belt head
    urgent.append((CORE[0] - 12, CORE[1] - 7))
    # THE LINE RUNS UNDER THE SPUR, NOT ACROSS IT. A belt is a wall: it owns
    # every tile of y121 and there is no square left for heat to cross from the
    # rung above to the main below. A sunken pair at x126/x129 buys back two
    # free tiles in the middle of the row, and the heat spur at x128 goes
    # straight down through them into the burner main.
    urgent += L.line(50, "belt_mk1", (-11, -7), (-3, -7))   # y121, x117 -> x125
    L.place(52, "underground_mk1", -2, -7, rot=0)           # x126, dives
    L.place(54, "underground_mk1", 1, -7, rot=0)            # x129, surfaces
    urgent += [(CORE[0] - 2, CORE[1] - 7), (CORE[0] + 1, CORE[1] - 7)]
    urgent += L.line(56, "belt_mk1", (2, -7), (9, -7))      # y121, x130 -> x137
    # One arm per burner, every one of them dropping south into a bunker. There
    # is no burner in the x127-129 slot and there cannot be: its only conduit
    # neighbours are the three main tiles that also touch the Hearth, and
    # [HeatFlow._route] breaks a distance tie on the LOWER building id — which
    # the Hearth wins for the rest of the game. A generator placed there
    # measured output 0.00, permanently, with a full bunker and a 41-unit
    # deficit on its own network. See the report note on [P02].
    burners = [-5, 3, -9, 7]
    for i, dx in enumerate(burners):
        L.place(60 + i * 4, "inserter_mk1", dx, -6, rot=1)
        urgent.append((CORE[0] + dx, CORE[1] - 6))
    # THE BURNER ROW. Two to three tiles off the Hearth's north face, where its
    # field is still worth 20-28 C. A burner keeps itself at (ground + 11 C) and
    # freezes at -10; this map bottoms out at -32.85, and a frozen burner stops
    # radiating, which is why the two that froze in the old run never thawed.
    # Every one of these survives a dead bunker on borrowed warmth alone.
    for i, (tick, dx) in enumerate(zip([90, 130, 420, 900], burners)):
        L.place(tick, "coal_generator", dx, -5)
        urgent.append((CORE[0] + dx, CORE[1] - 5))
    # A sixth, off the founding row on the Hearth's SOUTH face, fed by porters
    # out of the city stores. Not every burner in a real base is on the line,
    # and having one that is not is how the belt's contribution stays legible.
    L.place(1700, "coal_generator", -5, 3)                  # x123-125, y131-132
    urgent.append((CORE[0] - 5, CORE[1] + 3))
    L.place(1750, "coal_generator", -12, 3)                 # x116-118, y131-132
    urgent.append((CORE[0] - 12, CORE[1] + 3))
    L.place(1800, "coal_generator", 9, 3)                   # x137-139, y131-132
    urgent.append((CORE[0] + 9, CORE[1] + 3))

    # === AND THE HEARTH ITSELF GOES ON A LINE ==============================
    # This is the whole finding, in one place. The Hearth burns 0.83 coal a
    # second — more than every generator in the city put together — and in the
    # old run every unit of it was carried by hand: fuel_by_porter 1362 against
    # fuel_by_machine 51, which is 96% of the fuel in this game moving at
    # walking pace. Four arms off its south face and a crate the porters keep
    # topped up turn that around, and [P03]'s interlock makes it a real bet:
    # once an arm swings into a bunker the porters stand down for it, so if this
    # crate ever empties, the Hearth goes out and the run says so in
    # `logistics.lines_dry` rather than quietly covering for the mistake.
    L.place(1850, "crate", 4, 4)                            # x132, y132
    L.place(1860, "inserter_mk1", 3, 4, rot=2)              # crate -> belt
    L.line(1870, "belt_mk1", (2, 4), (-1, 4))               # y132, x130 -> x127
    for dx in (-1, 0, 1, 2):
        L.place(1880 + dx, "inserter_mk1", dx, 3, rot=3)    # belt -> the Hearth
    L.urgent(1900, [(CORE[0] + 4, CORE[1] + 4), (CORE[0] + 3, CORE[1] + 4)]
             + [(CORE[0] + dx, CORE[1] + 4) for dx in (-1, 0, 1, 2)]
             + [(CORE[0] + dx, CORE[1] + 3) for dx in (-1, 0, 1, 2)])
    L.cmd(2000, {"system": "logistics", "op": "insert",
                 "cell": [CORE[0] + 4, CORE[1] + 4], "item": "coal", "count": 350})
    L.cmd(2010, {"system": "logistics", "op": "request",
                 "cell": [CORE[0] + 4, CORE[1] + 4], "item": "coal", "amount": 350})
    L.urgent(240, urgent)
    L.cmd(1200, {"system": "logistics", "op": "insert",
                 "cell": [CORE[0] - 14, CORE[1] - 7], "item": "coal", "count": 700})
    # THE STANDING ORDER THAT MAKES THE DRILL MATTER: porters keep 600 coal in
    # the yard out of the city stores, the drill fills the city stores, the belt
    # empties the yard into six bunkers. Without it the line is one delivery.
    L.cmd(1300, {"system": "logistics", "op": "request",
                 "cell": [CORE[0] - 14, CORE[1] - 7], "item": "coal", "amount": 600})

    # === THE SALVAGE STRIP ==================================================
    # Six to eight tiles north of the Hearth, which is as far out as its field
    # is still worth 12 C. Every machine here is heat priority 50 — the tier
    # [P02] sheds FIRST — so it exists only because the burner row above went in
    # before it did. In the old run this whole strip read `power 0.0000` at
    # every checkpoint.
    L.line(140, "heat_trunk_main", (-1, -8), (-1, -4))      # x127, under the
    L.line(144, "heat_trunk_main", (0, -8), (0, -4))        # x128, sunken belt
    L.line(150, "heat_pipe", (-11, -8), (10, -8))           # y120 rung
    # Two mains down to the burner row, not one. The single spur that used to
    # carry the whole strip measured `capacity 69.0, load 69.0` — a heat_pipe
    # at 60 x 1.15 of research, saturated, with supply going spare on the other
    # side of it. A capacity bottleneck reads exactly like a supply shortage
    # from inside a machine: `no_heat`.
    L.line(160, "heat_trunk_main", (11, -8), (11, -4))      # x139
    L.line(164, "heat_trunk_main", (12, -8), (12, -4))      # x140
    # And two more through the sunken belt, which is what gives the middle of
    # the burner row a customer of its own. Mains, again for a measured reason:
    # a single heat_pipe here read `capacity 69.0, load 69.0` with five burners
    # idling on the other side of it at 7 to 14 units of a possible 33.6.
    # THE ROW IS LAID OUT RADIATOR-FIRST, NOT LEFT TO RIGHT. A 2-unit collector
    # makes 3 C of its own heat and a 6-unit sorter 15; at -32.85 C ambient they
    # need 18 and 8 more respectively, and one tile off a radiator's face is
    # worth 17.7 while four tiles is worth 6.3. Move any machine in this row two
    # tiles and it freezes on the second night — and a frozen machine radiates
    # nothing, draws nothing and therefore never thaws. That is not a soft
    # failure: it is permanent, and it is what took the westmost sorter out of
    # the previous version of this layout.
    # THE PLACEMENT TICK IS ALSO THE HIRING ORDER, AND THAT IS NOT OBVIOUS.
    # [P05] hires down `job_ids`, sorted by BUILD PRIORITY descending and then
    # by building id — and a site is filled to its staff CAPACITY, not to what
    # it requires. A scrap collector needs 2 and holds 4. So three collectors
    # placed before the sorters take twelve of the city's workers to do the work
    # of six, and a rubble sorter (build priority 60) that went down after them
    # gets nobody at all: measured, three sorters at staffing 0.00 and zero
    # crafts for a whole run while the collectors beside them ran at 1.00.
    # The strip therefore goes down FIRST — the build queue still builds the
    # coal line before it, because that is priority, not order — and there are
    # two collectors rather than three.
    L.place(170, "warmth_radiator", -8, -10)                # x120-121
    L.place(180, "rubble_sorter", -11, -10)                 # x117-119
    L.recipe(181, (-11, -10), "salvaged_stores")            # scrap -> GRAIN
    L.place(190, "rubble_sorter", -6, -10)                  # x122-124
    L.recipe(191, (-6, -10), "sorted_rubble")               # scrap -> IRON ORE
    L.place(200, "field_kitchen", 0, -10)                   # grain -> RATION
    L.place(210, "warmth_radiator", 5, -10)                 # x133-134
    L.place(220, "scrap_collector", 3, -10)                 # x131-132

    # === THE SOUTH DISTRICT =================================================
    L.line(2400, "heat_trunk_main", (-2, 3), (-2, 6))       # x126 spine
    L.line(2420, "heat_pipe", (-16, 7), (15, 7))            # y135 rung
    L.place(2500, "warmth_radiator", -8, 8)                 # x120-121
    L.place(2600, "granary", -6, 8)                         # x122-124
    L.place(2800, "survey_hall", 1, 8)                      # research is spend
    L.place(3200, "smelter", 6, 8)                          # x134-136, y136-138
    L.recipe(3201, (6, 8), "iron_plate")                    # on the sorter's ore
    L.place(3400, "housing_block", -3, 8)                   # x125-128

    # The inner ring, hanging straight off the founding rows: inside the
    # Hearth's field (15-26 C), and on the city's own grid, so a brownout at the
    # Hearth is felt at the guns.
    L.place(3600, "turret_mount", -6, -2)
    L.place(3650, "turret_mount", 5, -2)
    L.place(3700, "turret_mount", -10, -2)
    L.place(3750, "turret_mount", 9, -2)
    # AND TWO FACING THE SOUTH, WHICH THE FIRST VERSION OF THIS LAYOUT DID NOT
    # HAVE. Every gun stood on the north side, the wall is thirty tiles north,
    # and [P08] came up the south-east lane: drift hounds ate all four arms
    # loading the Hearth between t8951 and t9193 and the city spent the rest of
    # the run back on hand-carried coal. A supply chain is a structure with
    # hit points, and the automation pillar has to be defended like one.
    L.place(3800, "turret_mount", 4, 8)                     # x132-133, y136-137
    L.place(3850, "turret_mount", -11, 8)                   # x117-118, y136-137

    # === THE COAL OUTPOST ===================================================
    # The seam is at (124,97). That is measured, not guessed: a probe placed an
    # ore drill on every 3x3 site in the basin and read `seam_item` back off
    # each one. Coal is the field thirty tiles due north, behind the wall line;
    # iron is thirty-six tiles east, which is why the smelter here runs on the
    # sorter's byproduct instead. The two radiators are not decoration — a drill
    # is 8 units and a watchtower is 1, so out here the tower needs twenty
    # degrees of somebody else's warmth and gets it from one tile of clearance.
    # heat_pipe, not a main: a pipe is insulation 0.8 and loses 0.6% a tile, a
    # trunk main is 0.6 and loses 1.2%. Over nineteen tiles that is 11% against
    # 20%, and this arm never carries more than 41 of a pipe's 60.
    L.line(4000, "heat_pipe", (-1, -9), (-1, -27))
    # The outpost rung IS a main, for its 4 C of radiance rather than its
    # throughput: it is the last few degrees the watchtower needs.
    L.line(4100, "heat_trunk_main", (-1, -28), (-12, -28))
    L.place(4200, "warmth_radiator", -7, -30)               # x121-122
    L.place(4260, "warmth_radiator", -1, -30)               # x127-128
    # A drill draws 9 and is heat priority 55 — the tier [P02] sheds SECOND. The
    # instant it is shed it makes no heat of its own, and out here that is -18 C
    # inside a shell that freezes at -10. One radiator on one face was not
    # enough: measured, the drill froze on the third night, and a frozen machine
    # radiates nothing, draws nothing and therefore never thaws. Two radiators,
    # one either side, is 32 C of cover and the difference between an extraction
    # pillar and an ornament.
    L.place(4300, "ore_drill", -4, -31)                     # x124-126: COAL
    L.place(4500, "turret_mount", -9, -27)
    L.place(4560, "turret_mount", -5, -27)
    L.place(4620, "watchtower", -9, -30)                    # x119-120

    # The wall goes up before dusk. Forty-five sites at build priority 85 jump
    # the whole queue, which is why it waits until the yard, the belt and the
    # burners are standing.
    for i, dx in enumerate([-18, -9, 0, 9, 18]):
        L.line(4800 + i * 40, "wall", (dx - 4, -35), (dx + 4, -35))
    L.place(5200, "heat_accumulator", 13, 1)                # x141-142
    L.cmd(6400, {"system": "heat", "op": "dump"})
    L.cmd(7800, {"system": "grid", "op": "melt",
                 "cell": [CORE[0], CORE[1]], "radius": 6, "amount": 90})

    # === DAY TWO ============================================================
    L.cmd(10000, {"system": "logistics", "op": "insert",
                  "cell": [CORE[0] - 14, CORE[1] - 7], "item": "coal", "count": 500})
    L.place(10400, "housing_block", -15, 8)                 # x113-116
    L.cmd(14600, {"system": "heat", "op": "dump"})
    L.cmd(15400, {"system": "logistics", "op": "insert",
                  "cell": [CORE[0] - 14, CORE[1] - 7], "item": "coal", "count": 500})

    # === DAY THREE ==========================================================
    L.cmd(21000, {"system": "logistics", "op": "insert",
                  "cell": [CORE[0] - 14, CORE[1] - 7], "item": "coal", "count": 500})
    L.place(20200, "housing_block", 9, 8)                   # x137-140, y136-139
    L.place(21400, "turret_mount", -8, -2)                  # x120-121: warm ring
    L.place(21800, "heat_accumulator", -14, 1)              # x114-115, off the
    # west founding row — a second buffer for the nights this run does not
    # reach, and the only structure in the city that is worth building AFTER
    # the grid is already in surplus.
    L.cmd(22400, {"system": "heat", "op": "dump"})
    L.cmd(23000, {"system": "logistics", "op": "dump"})
    L.cmd(23200, {"system": "production", "op": "dump"})
    return {
        "name": "first_night",
        "description": ("THE REFERENCE RUN. Three full days and two nights on one heat "
                        "grid: a Hearth, six coal burners standing in its own warmth, five "
                        "of them loaded by inserters off ONE belt out of a coal yard, a "
                        "drill on the seam north of the wall keeping that yard filled "
                        "through a standing porter order, a salvage strip turning scrap "
                        "into grain into rations and scrap into ore for the smelter, homes "
                        "and shops on two rungs, and a perimeter that spends the city's own "
                        "warmth to hold the dark. This is what the art, audio and UI parts "
                        "screenshot against, and it is the run that has to prove the "
                        "automation, production and food pillars RUN rather than merely "
                        "tick."),
        "tags": ["reference", "gate", "visual"],
        "seed": 7, "ticks": 24000, "sample_every": 20,
        # Days 1 and 2 are graded. Day 3 is not: the run stops in its afternoon,
        # so that night never happens and a report over half a day would be
        # grading a fragment.
        # 373 ticks/s measured on a shared four-core box with three other
        # agents running; the floor is ~33% under that because a perf number
        # taken while somebody else compiles is noise. tools/perf.sh and the
        # integrator own the real measurement — this is only here so a run that
        # collapses to a tenth of realtime cannot pass quietly.
        "expects": {"min_ticks_per_second": 250, "max_errors": 0,
                    "balance_days": [1, 2], "max_heat_networks": 3},
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
            {"tick": 12800, "name": "second_day_factory"},
            {"tick": 15200, "name": "second_dusk"},
            {"tick": 17600, "name": "second_night"},
            {"tick": 21600, "name": "third_day_city"},
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
        "expects": {"min_ticks_per_second": 900, "max_errors": 0},
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
    # Trunks reach one column past the last plot column. A plot sits at
    # (col + 1, row + 1) and hangs off the trunk directly above it — the spurs
    # are only there to join the trunks to each other — so the plots in the
    # col = 40 column need a trunk cell at dx 41 and nothing more. Eleven pipes,
    # where extending every spur by four rows to reach the same eleven plots
    # cost forty-four and a tick per second off the perf floor.
    for dy in range(-30, 31, 6):
        L.line(t, "heat_pipe", (-40, dy), (41, dy), free=True, instant=True)
        t += 3
    for dx in range(-40, 41, 8):
        L.line(t, "heat_pipe", (dx, -30), (dx, 30), free=True, instant=True)
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
                        "hidden behind three dozen private one-node networks. "
                        "THE FLOOR IS A CONTRACT, NOT A RUBBER STAMP. It was 35 while the "
                        "build measured 41, so the gate reported green at 11% of its own "
                        "declared target and no regression could ever trip it. Measured "
                        "after the solver was rewritten around a dense per-network index: "
                        "128-132 ticks/s over three runs on an M3 Max, 7.4 ms/tick with all "
                        "eleven systems, of which heat is 6.4. The floor of 100 is ~24% "
                        "under the worst of those runs - enough that a loaded machine does "
                        "not cry wolf, tight enough that any real regression fails. The "
                        "target of 200 is 10x realtime, which is what 3x fast-forward needs "
                        "with a 5.6 ms renderer in front of it; 400 was never reachable at "
                        "20 Hz for a max-min-fair flow solve over 1400 nodes in GDScript "
                        "and pretending otherwise made the number meaningless. "
                        "There are no hostiles in it because [P07]/[P08] have not "
                        "landed - a scenario may not address a system this build does not "
                        "have (see tests/p00/test_scenarios.gd), so the combat half of the "
                        "stress test is owed, not forgotten."),
        "tags": ["perf", "gate"],
        "seed": 4242, "ticks": 3000, "sample_every": 50,
        # 6 networks, not 1: the layout lays one grid, and the runtime map has
        # rock in it that place_line skips, stranding a few pipe stubs at the
        # western edge. What matters for the perf case is that the expensive
        # component is the whole city, so the share is the real claim.
        "expects": {"min_ticks_per_second": 100, "target_ticks_per_second": 200,
                    "max_errors": 0, "min_buildings": 1000,
                    "max_heat_networks": 6, "min_main_network_share": 0.95},
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
# four horizontal rungs (dy -16, -8, +8, +16). Plots hug a rung above or below
# it, which is what puts every building on the same network as the Hearth.

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
ECON_ARM = 13               # rung reach either side of the spine
ECON_GENS_PER_LANE = 2      # see THE WARMTH-COVER LAW in economy()


class Row:
    """A cursor walking outward along one rung, packing plots that touch it."""

    def __init__(self, layout, dy, side, above=False):
        self.L = layout
        self.dy = dy
        self.side = side                       # -1 west of the spine, +1 east
        self.above = above
        self.cursor = ECON_SPINE_DX + (2 * side)

    def _next(self, kind, gap=1):
        """(origin dx, origin dy, cursor after) for the next plot, or None when
        the plot would hang off the end of the rung with nothing under it."""
        w, h = DEFS[kind][0], DEFS[kind][1]
        dy = self.dy - h if self.above else self.dy + 1
        if self.side > 0:
            dx, after = self.cursor, self.cursor + w + gap
            far = dx + w - 1
        else:
            dx, after = self.cursor - w, self.cursor - w - gap
            far = dx
        # The rung runs ECON_ARM either side of the spine. A plot whose far edge
        # is past that end touches bare ground and forms its own network.
        if self.side > 0 and far > ECON_SPINE_DX + ECON_ARM:
            return None
        if self.side < 0 and far < ECON_SPINE_DX - ECON_ARM:
            return None
        return dx, dy, after

    def fits(self, kind, gap=1):
        return self._next(kind, gap) is not None

    def add(self, tick, kind, gap=1, **kw):
        slot = self._next(kind, gap)
        assert slot is not None, \
            "%s does not fit on the %s rung at dy=%d" % (
                kind, "east" if self.side > 0 else "west", self.dy)
        dx, dy, after = slot
        self.cursor = after
        self.L.place(tick, kind, dx, dy, **kw)
        return dx


def economy():
    L = Layout()
    # Generous but not infinite: the point of this run is the HEAT curve, so a
    # material shortfall must never be what stalls it. Materials are read off
    # build.materials in the report as a sanity line, not as the constraint.
    stock = {k: 40000 for k in ["iron_plate", "steel_plate", "stone", "timber",
                                "scrap", "gear", "copper_coil", "coal"]}
    L.stock(1, stock)
    # Food is PROVISIONED, not simulated, and topped up every single day: this
    # run measures the heat curve, and an unbuilt salvage-to-kitchen chain
    # starving the city on day four does not make the heat reading harder, it
    # makes it meaningless — a dead city draws no heat. See BALANCE.md open
    # finding 1: as of this writing the population still dies on day 4 despite
    # this, which is a seam between [P05] and [P03], not a balance number.
    for day in range(1, 9):
        L.stock(max(1, (day - 1) * 9600 + 60),
                {"grain": 6000, "ration": 6000})
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

    # --- THE WARMTH-COVER LAW ------------------------------------------------
    # A coal generator keeps itself at (outside + 11 C): 1.6 C per unit of
    # self-heat, 30 output, 15% of it kept, times its 0.35 insulation bonus. It
    # freezes at -10 C. So it survives only while the ground it stands on is
    # warmer than about -21 C, and its own 10.5 C of radiance is not enough once
    # the plain passes -32. Every generator therefore has to stand inside a
    # radiator's field or the Hearth's, or it freezes solid in the small hours
    # of day three and never thaws — which is exactly what the previous version
    # of this scenario measured without noticing: THIRTEEN of fourteen
    # generators frozen at the final tick, supply pinned at the Hearth's 120.
    #
    # So a district here is radiator-first, generators beside it. See
    # game/content/economy/BALANCE.md, "The law nobody had written down".
    lanes = [(dy, s) for dy in (-8, 8, -16, 16) for s in (1, -1)]
    lane_open = []          # lanes that already have a radiator
    lane_gens = {}          # lane -> generators placed in it
    house_i = [0]

    def open_lane(tick, **kw):
        for lane in lanes:
            if lane not in lane_open:
                # gap 0 all the way down a district: the radiator's field is
                # 6.5 tiles and the second generator has to stand inside it.
                below[lane[0]][lane[1]].add(tick, "warmth_radiator", gap=0, **kw)
                lane_open.append(lane)
                lane_gens[lane] = 0
                return lane
        raise AssertionError("economy: out of rungs to open")

    def add_generator(tick):
        for lane in lane_open:
            if lane_gens[lane] < ECON_GENS_PER_LANE:
                below[lane[0]][lane[1]].add(tick, "coal_generator", gap=0)
                lane_gens[lane] += 1
                return lane
        raise AssertionError("economy: every open district is full of generators; "
                             "the plan wants a radiator before it wants another burner")

    def add_house(tick):
        for _ in range(len(lanes) * 2):
            lane = lanes[house_i[0] % len(lanes)]
            house_i[0] += 1
            row = above[lane[0]][lane[1]]
            if row.fits("housing_block"):
                row.add(tick, "housing_block")
                return lane
        raise AssertionError("economy: nowhere left to put a housing block")

    def add_extra(tick, kind):
        """Anything that is neither a generator, a radiator nor a home. It still
        has to touch the rung, so it goes in the first lane with room."""
        for rows in (above, below):
            for lane in lanes:
                row = rows[lane[0]][lane[1]]
                if row.fits(kind):
                    row.add(tick, kind)
                    return lane
        raise AssertionError("economy: nowhere left for a %s" % kind)

    # The settlement that already stands: four lit streets and four blocks.
    for i in range(4):
        open_lane(8 + i, free=True, instant=True)
    for i in range(4):
        lane = lanes[i]
        above[lane[0]][lane[1]].add(12 + i, "housing_block", free=True, instant=True)
    house_i[0] = 4

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
        (3, ["coal_generator", "coal_generator", "heat_accumulator"]),
        # days 4-5: the city grows faster than the grid. One generator each,
        #           two blocks each — this is the stretch where an attentive
        #           player is spending on homes and telling themselves the
        #           margin is fine, and it is what makes day 6 land.
        (4, ["coal_generator", "warmth_radiator",
             "housing_block", "housing_block", "granary"]),
        (5, ["coal_generator", "housing_block", "housing_block",
             "field_kitchen"]),
        # day 6: the correction. Three burners in one day, because day 5 ended
        #        thin and the player can read that off their own grid.
        (6, ["warmth_radiator", "coal_generator", "coal_generator",
             "coal_generator", "housing_block"]),
        # day 7: SECOND FROST, and the last day the run covers in full. The
        #        booster pump is what keeps the far rungs alive through it.
        (7, ["warmth_radiator", "coal_generator", "coal_generator",
             "coal_generator", "heat_booster_pump"]),
    ]

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
            if kind == "coal_generator":
                add_generator(t)
            elif kind == "warmth_radiator":
                open_lane(t)
            elif kind == "housing_block":
                add_house(t)
            else:
                add_extra(t, kind)

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
        "expects": {"min_ticks_per_second": 650, "max_errors": 0,
                    "balance_days": [1, 2, 3, 4, 5, 6, 7],
                    "max_heat_networks": 1, "min_main_network_share": 1.0},
        "script": L.script,
        "_layout": L,
        "shots": [],
    }



# ------------------------------------------------------------ the A/B pair
#
# TWO RUNS OF THE SAME DAY, PLAYED BADLY AND PLAYED WELL.
#
# Every other scenario in this file is a competent player. That is a blind
# spot: a game that only ever sees good play cannot be asked whether it NOTICES
# bad play, and "does the city tell you that you are losing, in time to do
# something about it" is the whole of the Frostpunk contract in ARCHITECTURE §0.
#
# So these two share a seed, a tick count, a starting stock and an opening
# settlement, and differ only in what the player does with the day:
#
#   careless_night  under-builds heat, never closes the food chain, lays no
#                   belt, and puts nothing on the perimeter before dusk.
#   steady_hand     does all four, on the same clock, out of the same stock.
#
# Diff the two state.json files and the difference is entirely the player's.
# `_allow_islands` is deliberately non-zero in the careless run: a player who
# drops a generator where it touches no pipe is the single most common opening
# mistake in this genre, and a scenario library that cannot express it cannot
# test whether the heat lens catches it.


def _opening_settlement(L):
    """The city that is already standing when day 1 begins. Identical in both."""
    L.stock(1, {"iron_plate": 1400, "steel_plate": 900, "stone": 1400,
                "timber": 900, "scrap": 900, "gear": 400, "copper_coil": 400,
                "coal": 900})
    L.unlock(2, "thermal_storage", "pressurised_mains")
    L.place(3, "the_hearth", -2, -2, free=True, instant=True)
    L.line(4, "heat_pipe", (3, 0), (12, 0), free=True, instant=True)
    L.line(5, "heat_pipe", (-3, 0), (-12, 0), free=True, instant=True)
    L.line(6, "heat_pipe", (3, 2), (12, 2), free=True, instant=True)
    L.line(7, "heat_pipe", (-3, 2), (-12, 2), free=True, instant=True)
    L.place(8, "warmth_radiator", 13, -1, free=True, instant=True)
    L.place(9, "warmth_radiator", -14, -1, free=True, instant=True)
    L.place(10, "housing_block", 5, 3, free=True, instant=True)
    L.place(11, "housing_block", -9, 3, free=True, instant=True)


_AB_SHOTS = [
    {"tick": 30, "name": "opening"},
    {"tick": 3400, "name": "midday"},
    {"tick": 5500, "name": "dusk"},
    {"tick": 7200, "name": "assault"},
    {"tick": 9800, "name": "dawn"},
]


def careless():
    L = Layout()
    _opening_settlement(L)

    # 1. UNDER-BUILD HEAT. The player keeps adding draw and never adds supply.
    #    Two more housing blocks, a workshop and a drill hang off the founding
    #    grid; nothing that burns anything is ever placed.
    L.line(600, "heat_pipe", (0, 3), (0, 14))
    L.place(900, "workshop", 1, 14)
    L.place(1400, "housing_block", -9, 9)
    L.line(1500, "heat_pipe", (-1, 8), (-8, 8))
    L.line(2800, "heat_pipe", (0, -3), (1, -18))
    L.place(3000, "ore_drill", 2, -19)
    L.place(3600, "housing_block", 5, 8)
    L.line(3500, "heat_pipe", (5, 3), (5, 8))

    # 2. THE GENERATOR THAT TOUCHES NOTHING. Placed in open ground twenty tiles
    #    out, connected to no pipe. It is a network of one, it produces into
    #    itself, and the only thing in the build that can say so is [P19]'s heat
    #    lens and [P17]'s "2 grids" line. That is the point of it being here.
    L.place(4200, "coal_generator", -20, 16)

    # 3. NEVER CLOSE THE FOOD CHAIN. No granary, no kitchen, no sorter. The
    #    founders' larder is all there is and it is being eaten by a population
    #    that housing keeps growing.

    # 4. AUTOMATE NOTHING. No crate, no inserter, no belt: every joule of coal
    #    in this run is carried by a person, and there is no coal_generator on
    #    the grid for them to carry it to anyway.

    # 5. IGNORE THE FIRST WAVE. Four warnings arrive between t=2700 and t=6000
    #    and the player answers none of them. No wall, no turret, no watchtower.
    #    The one gesture toward defence is made after the wave has already
    #    started, which is exactly when it is worth nothing.
    L.line(7000, "heat_pipe", (2, -3), (6, -3))
    L.place(7100, "turret_mount", 5, -5)
    return {
        "name": "careless_night",
        "description": ("PLAYED BADLY ON PURPOSE, and the control for steady_hand. "
                        "Same seed, same day, same opening settlement, same stock. This "
                        "player adds four heated buildings and no generator, drops the one "
                        "generator they own on bare ground where it joins no network, never "
                        "builds a granary, a kitchen or a sorter, lays no belt, and answers "
                        "the four wave warnings by placing a single turret after the attack "
                        "has begun. Read it against steady_hand: every difference in the two "
                        "state.json files was a decision, and the question this run asks is "
                        "whether the interface said so at the time."),
        "tags": ["reference", "visual"],
        "seed": 7, "ticks": 11000, "sample_every": 20,
        # A run this bad raises alerts by design; the gate must grade it on what
        # it measures, not refuse to finish it.
        # THE ISLAND IS THE CLAIM. Two networks is what this player built, and
        # saying so out loud is what stops the fragmentation reading as quiet.
        "expects": {"min_ticks_per_second": 600, "max_errors": 12,
                    "balance_days": [1], "max_heat_networks": 2},
        "script": L.script,
        "_layout": L,
        # The lone generator is the island, and it is the finding.
        "_allow_islands": 1,
        "shots": _AB_SHOTS,
    }


def steady():
    L = Layout()
    _opening_settlement(L)

    # 1. HEAT FIRST, AND ON THE GRID. A generator on the founding spine before
    #    anything that draws from it, a second one before dusk, and a buffer to
    #    carry the night.
    L.line(300, "heat_pipe", (0, 3), (0, 14))
    L.line(400, "heat_pipe", (0, 14), (-1, 14))
    L.place(500, "coal_generator", -4, 14)
    L.place(900, "workshop", 1, 14)
    L.line(1200, "heat_pipe", (12, 1), (12, 8))
    L.place(1400, "heat_accumulator", 13, 8)

    # 2. THE FOOD CHAIN, CLOSED, AND SAID OUT LOUD AT PLACEMENT TIME.
    #    `set_recipe` on a cell that holds a construction site is a STANDING
    #    ORDER: production remembers it and the machine is born running it. The
    #    alternative — waiting for the site to finish and then naming the
    #    recipe — is a guess about build time, and in first_night that guess was
    #    4800 ticks wrong, which is why the reference run never made a ration.
    L.line(1600, "heat_pipe", (-3, 2), (-3, -11))
    L.place(1800, "field_kitchen", -6, -8)
    L.place(2000, "rubble_sorter", -6, -11)
    L.cmd(2001, {"system": "production", "op": "set_recipe",
                 "cell": [CORE[0] - 6, CORE[1] - 11], "recipe": "salvaged_stores"})
    L.line(2400, "heat_pipe", (5, 3), (5, 8))
    L.place(2600, "granary", 6, 8)

    # 3. AUTOMATE THE THING THAT REPEATS. The founders' coal pile goes on a belt
    #    into the generator's bunker instead of onto somebody's back.
    L.place(1000, "crate", -10, 18)
    L.place(1010, "inserter_mk1", -9, 18, rot=0)
    L.line(1020, "belt_mk1", (-8, 18), (-3, 17))
    L.place(1030, "inserter_mk1", -3, 16, rot=3)
    L.cmd(1100, {"system": "logistics", "op": "insert",
                 "cell": [CORE[0] - 10, CORE[1] + 18], "item": "coal", "count": 400})
    L.cmd(6000, {"system": "logistics", "op": "insert",
                 "cell": [CORE[0] - 10, CORE[1] + 18], "item": "coal", "count": 400})

    # 4. THE PERIMETER GOES UP ON THE FIRST WARNING, NOT ON THE FIRST CASUALTY.
    #    Warning 1 lands around t=2700. Everything below is finished before the
    #    countdown reaches zero, and all of it is on the city's own grid, so a
    #    brownout at the Hearth is felt at the guns.
    L.line(2900, "heat_pipe", (2, -3), (6, -3))
    L.line(2940, "heat_pipe", (2, 3), (4, 3))
    L.line(2960, "heat_pipe", (-2, 3), (-4, 3))
    L.place(3000, "turret_mount", 5, -5)
    L.place(3040, "turret_mount", -5, -5)
    L.place(3080, "turret_mount", 3, 4)
    L.place(3120, "turret_mount", -4, 4)
    for i, dx in enumerate([-18, -9, 0, 9, 18]):
        L.line(3300 + i * 40, "wall", (dx - 4, -35), (dx + 4, -35))
    L.line(3560, "heat_pipe", (0, -3), (1, -18))
    L.line(3600, "heat_pipe", (1, -18), (1, -33))
    L.line(3700, "heat_pipe", (1, -33), (14, -33))
    L.line(3740, "heat_pipe", (1, -33), (-13, -33))
    L.place(3800, "watchtower", -12, -32)
    L.place(3900, "watchtower", 13, -32)
    L.place(4000, "turret_mount", -9, -32)
    L.place(4100, "turret_mount", 8, -32)

    # 5. THE SECOND GENERATOR, BEFORE DUSK RATHER THAN DURING THE NIGHT.
    L.line(4400, "heat_pipe", (0, 14), (0, 18))
    L.place(4600, "coal_generator", 1, 17)
    return {
        "name": "steady_hand",
        "description": ("PLAYED WELL, and the control for careless_night. The same seed, "
                        "day, opening settlement and stock, spent in the order the game is "
                        "actually asking for: heat before draw, the salvage-to-kitchen chain "
                        "closed and named while it is still a building site, one belt doing "
                        "the job a porter was doing, and the whole perimeter standing on the "
                        "city's own heat grid before the first wave's countdown runs out. "
                        "The two runs diverge on the interface as much as on the numbers, and "
                        "both halves of that are the finding."),
        "tags": ["reference", "visual"],
        "seed": 7, "ticks": 11000, "sample_every": 20,
        "expects": {"min_ticks_per_second": 600, "max_errors": 0,
                    "balance_days": [1], "max_heat_networks": 1},
        "script": L.script,
        "_layout": L,
        "shots": _AB_SHOTS,
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
    for build in (smoke, first_night, determinism, stress, economy,
                  careless, steady):
        write(build())

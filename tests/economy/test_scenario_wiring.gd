extends TestCase
## [P12] The scenario library, checked as a CITY rather than as JSON.
##
## tests/p00 already proves a scenario is well-formed and names real buildings.
## It cannot see the failure that actually happened: economy_60min placed
## sixteen coal generators, every one of them legal, every one of them touching
## only a housing block — and HeatGraph links two buildings only when at least
## one of them CONDUCTS. Sixteen private one-node networks, sixteen frozen
## generators, heat supply pinned at the Hearth's 120 for an hour, and the run
## exited 0 the whole time.
##
## So this suite rebuilds each scenario's occupancy the way build does, applies
## HeatGraph's connection rule to it, and refuses a "balance run" whose heat
## entities are not one grid.
##
## It is deliberately static. It cannot see terrain, which the runtime can
## refuse — that half is checked by tools/analyze_balance.py against
## expects.max_heat_networks on every real run.

const DIR: String = "res://tests/scenarios"
const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

var scenarios: Dictionary = {}


func before_all() -> void:
	var dir: DirAccess = DirAccess.open(DIR)
	if dir == null:
		return
	var files: Array[String] = []
	for f: String in dir.get_files():
		if f.ends_with(".json") and not f.begins_with("_"):
			files.append(f)
	files.sort()
	for f: String in files:
		var parsed: Variant = JsonCanon.load_file("%s/%s" % [DIR, f])
		if typeof(parsed) == TYPE_DICTIONARY:
			scenarios[f.get_basename()] = parsed


func _names() -> PackedStringArray:
	var keys: Array = scenarios.keys()
	keys.sort()
	var out := PackedStringArray()
	for k: Variant in keys:
		out.append(String(k))
	return out


# --- the heat grid is one grid ------------------------------------------------

func test_a_balance_scenario_builds_one_connected_heat_grid() -> void:
	if Registry.ids("buildings").is_empty():
		skip("game/content/buildings/ is empty")
		return
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		var allowed: int = int((sc.get("expects", {}) as Dictionary).get("max_heat_networks", 0))
		if allowed <= 0:
			continue          # this scenario makes no claim about its grid
		var comps: Array[Dictionary] = _components(sc)
		if comps.is_empty():
			continue
		var islands: Array[Dictionary] = comps.slice(1)
		var detail: PackedStringArray = PackedStringArray()
		for g: Dictionary in islands:
			detail.append("%d node(s) %s near %s" % [
				int(g["size"]), ", ".join(g["kinds"]), str(g["sample"])])
		assert_le(float(comps.size()), float(allowed),
			("%s claims max_heat_networks=%d and lays out %d. Main grid has %d "
			+ "node(s); orphans: %s. A heat entity that touches no conduit is a "
			+ "private network that produces into nothing and freezes.") % [
				key, allowed, comps.size(), int(comps[0]["size"]),
				"; ".join(detail) if detail.size() > 0 else "none"])


func test_every_producer_stands_where_it_can_survive_the_night() -> void:
	# THE WARMTH-COVER LAW. A coal generator holds itself at outside + 11 C and
	# freezes at -10 C, so it needs ground warmer than about -21 C. Its own
	# radiance is worth ~10 C, which stops being enough once the plain passes
	# -32 C — around day three. A generator outside a radiator's or the Hearth's
	# field freezes solid and never thaws, and the network loses it for good.
	if Registry.ids("buildings").is_empty():
		skip("game/content/buildings/ is empty")
		return
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		if not (sc.get("tags", []) as Array).has("balance"):
			continue          # only the balance instruments have to obey it
		var placed: Array[Dictionary] = _placed(sc)
		var anchors: Array[Dictionary] = []
		for p: Dictionary in placed:
			var def: BuildingDef = p["def"]
			if def.heat_radius >= 6.0:
				anchors.append(p)
		for p: Dictionary in placed:
			var def2: BuildingDef = p["def"]
			if def2.heat_produced <= 0.0 or def2.has_tag(&"unique"):
				continue
			var covered: bool = false
			for a: Dictionary in anchors:
				var a_def: BuildingDef = a["def"]
				if _centre_distance(p, a) <= a_def.heat_radius:
					covered = true
					break
			assert_true(covered,
				("%s places a %s at %s with no radiator or Hearth within reach. "
				+ "It freezes on the third night and the run measures a ruin.") % [
					key, String(def2.id), str(p["cell"])])


func test_the_reference_run_and_the_balance_run_declare_a_grid_claim() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		var tags: Array = sc.get("tags", [])
		if not (tags.has("balance") or tags.has("reference") or tags.has("perf")):
			continue
		assert_has(sc.get("expects", {}), "max_heat_networks",
			"%s is graded on its heat curve, so it has to say how many networks "
			% key + "it means to build — otherwise a fragmented grid reads as a "
			+ "quiet one")


func test_the_balance_run_says_which_days_it_grades() -> void:
	for key: String in _names():
		var sc: Dictionary = scenarios[key]
		if not (sc.get("tags", []) as Array).has("balance"):
			continue
		var days: Array = (sc.get("expects", {}) as Dictionary).get("balance_days", [])
		assert_not_empty(days,
			"%s is tagged 'balance' and names no days — tools/analyze_balance.py "
			% key + "cannot tell a day it failed to reach from a day it passed")
		var day_ticks: int = Balance.curve().day_ticks
		var reach: int = int(sc.get("ticks", 0)) / maxi(1, day_ticks)
		for d: Variant in days:
			assert_le(float(d), float(reach),
				"%s grades day %d but only runs %d whole days" % [key, int(d), reach])


# --- rebuilding the layout ----------------------------------------------------

## Every building a scenario places, in order, as {kind, def, cell, cells}.
func _placed(sc: Dictionary) -> Array[Dictionary]:
	var occ: Dictionary[Vector2i, int] = {}
	var out: Array[Dictionary] = []
	for raw: Variant in sc.get("script", []):
		var cmd: Dictionary = (raw as Dictionary).get("cmd", {})
		if String(cmd.get("system", "")) != "build":
			continue
		var op: String = String(cmd.get("op", ""))
		var kind: StringName = StringName(String(cmd.get("kind", "")))
		var def: BuildingDef = Registry.get_item("buildings", kind) as BuildingDef
		if def == null:
			continue
		match op:
			"place", "build":
				_claim(occ, out, def, BuildTypes.to_cell(cmd.get("cell", [0, 0])),
					int(cmd.get("rot", 0)))
			"place_line":
				for c: Vector2i in _line(BuildTypes.to_cell(cmd.get("from", [0, 0])),
						BuildTypes.to_cell(cmd.get("to", [0, 0]))):
					_claim(occ, out, def, c, 0)
			"place_area":
				var a: Vector2i = BuildTypes.to_cell(cmd.get("from", [0, 0]))
				var b: Vector2i = BuildTypes.to_cell(cmd.get("to", [0, 0]))
				for y: int in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
					for x: int in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
						_claim(occ, out, def, Vector2i(x, y), 0)
	return out


func _claim(occ: Dictionary[Vector2i, int], out: Array[Dictionary],
		def: BuildingDef, cell: Vector2i, rot: int) -> void:
	var cells: Array[Vector2i] = def.cells_at(cell, rot)
	for c: Vector2i in cells:
		if occ.has(c):
			return          # build refuses an occupied footprint; so do we
	var index: int = out.size()
	for c2: Vector2i in cells:
		occ[c2] = index
	out.append({"kind": def.id, "def": def, "cell": cell, "cells": cells,
		"occ": occ})


## HeatGraph's rule, applied to a finished layout. Largest component first.
func _components(sc: Dictionary) -> Array[Dictionary]:
	var placed: Array[Dictionary] = _placed(sc)
	var owner: Dictionary[Vector2i, int] = {}
	var nodes: Array[Dictionary] = []
	for p: Dictionary in placed:
		var def: BuildingDef = p["def"]
		if not _participates(def):
			continue
		var index: int = nodes.size()
		nodes.append(p)
		for c: Vector2i in p["cells"]:
			if not owner.has(c):
				owner[c] = index
	if nodes.is_empty():
		return []

	var parent: PackedInt32Array = PackedInt32Array()
	parent.resize(nodes.size())
	for i: int in nodes.size():
		parent[i] = i
	var cells: Array = owner.keys()
	cells.sort()
	for cell: Vector2i in cells:
		var a: int = owner[cell]
		for d: Vector2i in NEIGHBOURS:
			var b: int = owner.get(cell + d, -1)
			if b < 0 or b == a:
				continue
			var a_def: BuildingDef = nodes[a]["def"]
			var b_def: BuildingDef = nodes[b]["def"]
			if a_def.is_heat_conduit or b_def.is_heat_conduit:
				_union(parent, a, b)

	var groups: Dictionary[int, Array] = {}
	for i2: int in nodes.size():
		var root: int = _find(parent, i2)
		var members: Array = groups.get(root, [])
		members.append(i2)
		groups[root] = members
	var out: Array[Dictionary] = []
	for root2: Variant in EconomyDefs.sorted_keys(groups):
		var members2: Array = groups[root2]
		var kinds: PackedStringArray = PackedStringArray()
		for m: Variant in members2:
			var k: String = String(nodes[int(m)]["kind"])
			if not kinds.has(k):
				kinds.append(k)
		kinds.sort()
		out.append({"size": members2.size(), "kinds": kinds,
			"sample": nodes[int(members2[0])]["cell"]})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return int(x["size"]) > int(y["size"]))
	return out


## HeatDef.participates(), read off the BuildingDef schema.
func _participates(def: BuildingDef) -> bool:
	return def.heat_produced > 0.0 or def.heat_consumed > 0.0 \
		or (def.is_heat_conduit and def.conduit_throughput > 0.0) \
		or def.heat_radius > 0.0


func _centre_distance(a: Dictionary, b: Dictionary) -> float:
	var a_def: BuildingDef = a["def"]
	var b_def: BuildingDef = b["def"]
	var ac: Vector2 = Vector2(a["cell"]) + Vector2(a_def.size) * 0.5
	var bc: Vector2 = Vector2(b["cell"]) + Vector2(b_def.size) * 0.5
	return ac.distance_to(bc)


## The exact path BuildSystem._op_place_line walks: horizontal leg, then vertical.
func _line(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var step_x: int = signi(to.x - from.x)
	var x: int = from.x
	while x != to.x:
		path.append(Vector2i(x, from.y))
		x += step_x
	var step_y: int = signi(to.y - from.y)
	var y: int = from.y
	while y != to.y:
		path.append(Vector2i(to.x, y))
		y += step_y
	path.append(to)
	return path


func _find(parent: PackedInt32Array, a: int) -> int:
	var node: int = a
	while parent[node] != node:
		parent[node] = parent[parent[node]]
		node = parent[node]
	return node


func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra: int = _find(parent, a)
	var rb: int = _find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)

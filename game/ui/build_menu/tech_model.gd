class_name LcnTechModel
extends RefCounted
## [P18] The readable tech tree.
##
## A tech screen fails in one of two ways: it is a spreadsheet, or it is a
## spaghetti graph. This model refuses both by answering three questions per
## node, in this order:
##
##   1. WHAT does it open?        the buildings and abilities, by name
##   2. WHY NOW?                  measured against the city as it stands this
##                                minute — "your grid is 34 u/s short and this
##                                opens the Geothermal Tap" beats any tooltip
##                                that only quotes a research cost
##   3. WHAT IS IN THE WAY?       the exact prerequisites still missing
##
## Three sources, in order of preference, all duck-typed so nothing here breaks
## when [P10] lands or changes shape:
##   * `research.tree_layout()` if the research system publishes one
##   * `game/content/research/` resources scanned by Registry
##   * failing both, the tree implied by BuildingDef.unlock_id — which is a real
##     progression graph today, in a build with no research part at all.
##
## Layout is a longest-path layering: column = length of the longest chain of
## prerequisites behind a node, rows sorted by name inside a column. Stable,
## deterministic, and it puts the things you can do next on the left.

enum State { LOCKED, AVAILABLE, ACTIVE, DONE }

const MAX_DEPTH_PASSES: int = 64

## [P10] publishes six states; the screen only draws four, so the two that are
## really "started, not finished" fold onto ACTIVE and the queue is a badge.
const RESEARCH_STATE_NAMES: Array[String] = [
	"locked", "available", "queued", "active", "parked", "done",
]


class TechNode extends RefCounted:
	var id: StringName = &""
	var display_name: String = ""
	var description: String = ""
	var flavour: String = ""
	var branch: StringName = &""
	var tier: int = 1
	var cost: Dictionary = {}
	var cost_points: float = 0.0
	var prereqs: Array[StringName] = []
	var unlocks: Array[StringName] = []          ## building kinds
	var grants: Array[StringName] = []           ## non-building unlock ids
	var leads_to: Array[StringName] = []
	## Numeric payoff, as [P10] publishes it: key -> delta. Keys ending in
	## "_mult" stack as 1.0 + sum, so they read as percentages.
	var effects: Dictionary = {}
	var state: int = State.LOCKED
	## The word [P10] itself used: locked / available / queued / active / parked / done.
	var state_word: String = "locked"
	var progress: float = 0.0
	## Materials still owed before it can finish, and whether the yard has them.
	var remaining_cost: Dictionary = {}
	var affordable: bool = true
	var eta_seconds: float = -1.0
	var column: int = 0
	var row: int = 0
	## The AUTHORED "why now" line. [P10] writes one per node and the pacing
	## engine decides when to shout it; showing it is most of this screen's value.
	var urgency: String = ""
	## The pacing engine's own reason for recommending this node right now.
	var reason: String = ""
	## Filled by refresh_relevance(): derived from the city when nothing authored.
	var relevance: String = ""
	var relevance_tone: int = LcnUiStyle.Tone.DIM
	var source: StringName = &"derived"

	func is_done() -> bool:
		return state == State.DONE

	func cost_label() -> String:
		var parts: PackedStringArray = PackedStringArray()
		if not cost.is_empty():
			parts.append(LcnUiFormat.items(cost))
		if cost_points > 0.0:
			parts.append("%s insight" % LcnUiFormat.num(cost_points))
		if parts.is_empty():
			return "—"
		return "   ·   ".join(parts)

	## What is still owed, and whether the city can pay it. The single most
	## useful line on a tech screen in a game where research competes with the
	## wall for the same steel.
	func owed_label() -> String:
		if remaining_cost.is_empty():
			return ""
		return "%s%s" % [LcnUiFormat.items(remaining_cost),
			"" if affordable else "   (the yard is short)"]

	func eta_label() -> String:
		return "" if eta_seconds < 0.0 else LcnUiFormat.duration(eta_seconds)

	## The payoff in sentences. A tech screen that shows a node with no buildings
	## and no words has told the player nothing, and half of a good tree is
	## modifiers rather than unlocks.
	func effect_lines() -> PackedStringArray:
		var out: PackedStringArray = PackedStringArray()
		for k: StringName in LcnUiFormat.sorted_names(effects.keys()):
			var v: float = LcnUiFormat.as_number(effects[k])
			if is_zero_approx(v):
				continue
			var label: String = String(k)
			if label.ends_with("_mult"):
				out.append("%s %s" % [
					LcnUiFormat.item_name(StringName(label.substr(0, label.length() - 5).replace(".", " "))),
					LcnUiFormat.signed(v * 100.0) + "%"])
			elif label.ends_with("_add"):
				out.append("%s %s" % [
					LcnUiFormat.item_name(StringName(label.substr(0, label.length() - 4).replace(".", " "))),
					LcnUiFormat.signed(v)])
			else:
				out.append("%s %s" % [LcnUiFormat.item_name(StringName(label.replace(".", " "))), LcnUiFormat.signed(v)])
		return out


	## Whichever "why now" line exists: the author's beats the derived one.
	func why_now() -> String:
		if reason != "":
			return reason
		if urgency != "":
			return urgency
		return relevance


var nodes: Array[TechNode] = []
## [P10]'s current recommendation, if it makes one: {id, score, signal, reason}.
var suggestion: Dictionary = {}

var _by_id: Dictionary[StringName, TechNode] = {}
var _columns: int = 0
var _edges: Array[Dictionary] = []
var _revision: int = 0
var _source: StringName = &"none"
## True when the tree came with its own coordinates and we must not re-lay it.
var _published_layout: bool = false


# ------------------------------------------------------------------ build ----

## Assembles the tree. Any argument may be null.
func rebuild(research: Object, build_system: Object, registry: Object = null) -> void:
	nodes.clear()
	_by_id.clear()
	_edges.clear()
	_columns = 0
	_revision += 1
	_source = &"none"

	if _from_research(research):
		_source = &"research"
	elif _from_registry(registry):
		_source = &"content"
	if nodes.is_empty() and _from_buildings(build_system):
		_source = &"buildings"

	_attach_unlocked_buildings(build_system)
	_normalise_unlocks(build_system)
	_layout()
	refresh_state(research, build_system)


func revision() -> int:
	return _revision


## Where the tree came from: research / content / buildings / none. Shown in the
## panel footer, because a player deserves to know when they are looking at a
## derived tree rather than an authored one.
func source() -> StringName:
	return _source


func is_empty() -> bool:
	return nodes.is_empty()


func columns() -> int:
	return _columns


func edges() -> Array[Dictionary]:
	return _edges.duplicate()


func node(id: StringName) -> TechNode:
	return _by_id.get(id)


func nodes_in_column(column: int) -> Array[TechNode]:
	var out: Array[TechNode] = []
	for n: TechNode in nodes:
		if n.column == column:
			out.append(n)
	return out


## [P10] publishing its own layout wins over everything else. Two shapes are
## accepted: {nodes: [...], edges: [...]} and a bare array of node dictionaries.
func _from_research(research: Object) -> bool:
	if research == null or not research.has_method(&"tree_layout"):
		return false
	var raw: Variant = research.call(&"tree_layout")
	var list: Array = []
	if typeof(raw) == TYPE_DICTIONARY:
		list = (raw as Dictionary).get("nodes", [])
		suggestion = (raw as Dictionary).get("suggestion", {})
	elif typeof(raw) == TYPE_ARRAY:
		list = raw
	if list.is_empty():
		return false
	var placed: int = 0
	for entry: Variant in list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = entry
		var n := TechNode.new()
		n.id = LcnUiFormat.as_name(d.get("id", ""))
		if String(n.id) == "":
			continue
		n.display_name = LcnUiFormat.as_text(d.get("title", d.get("display_name", d.get("name", ""))))
		if n.display_name == "":
			n.display_name = LcnUiFormat.item_name(n.id)
		n.description = LcnUiFormat.as_text(d.get("description", ""))
		n.flavour = LcnUiFormat.as_text(d.get("flavour", ""))
		n.branch = LcnUiFormat.as_name(d.get("branch", ""))
		n.tier = LcnUiFormat.as_int(d.get("tier", 1))
		# A published cost may be a scalar or a bill of materials, and [P10] is
		# free to change its mind: read whichever shape actually arrived.
		for shape: Variant in [d.get("cost_items", null), d.get("cost", null)]:
			if typeof(shape) == TYPE_DICTIONARY and not (shape as Dictionary).is_empty():
				n.cost = shape
				break
		n.cost_points = LcnUiFormat.as_number(d.get("work", d.get("points", 0.0)))
		var owed: Variant = d.get("remaining_cost", null)
		if typeof(owed) == TYPE_DICTIONARY:
			n.remaining_cost = owed
		n.affordable = LcnUiFormat.as_flag(d.get("affordable", true))
		n.eta_seconds = LcnUiFormat.as_number(d.get("eta_seconds", -1.0))
		n.progress = clampf(LcnUiFormat.as_number(d.get("progress", 0.0)), 0.0, 1.0)
		n.urgency = LcnUiFormat.as_text(d.get("urgency", ""))
		n.reason = LcnUiFormat.as_text(d.get("reason", ""))
		n.prereqs = _string_names(d.get("prereqs", d.get("requires", [])))
		n.unlocks = _string_names(d.get("unlocks", d.get("buildings", [])))
		n.grants = _string_names(d.get("grants", []))
		n.leads_to = _string_names(d.get("leads_to", []))
		var payoff: Variant = d.get("effects", null)
		if typeof(payoff) == TYPE_DICTIONARY:
			n.effects = payoff
		if d.has("column") and d.has("row"):
			n.column = LcnUiFormat.as_int(d["column"])
			n.row = LcnUiFormat.as_int(d["row"])
			placed += 1
		n.state_word = LcnUiFormat.as_text(d.get("state", "locked"))
		n.state = _fold_state(n.state_word, LcnUiFormat.as_int(d.get("state_index", 0)))
		n.source = &"research"
		_add(n)
	# Only trust a published layout when EVERY node came with coordinates; a
	# half-placed tree drawn on its own numbers is worse than one we lay out.
	_published_layout = placed > 0 and placed == nodes.size()
	return not nodes.is_empty()


## Folds [P10]'s six-state vocabulary onto the four this screen draws. QUEUED and
## PARKED both mean "started but not finished", which is what ACTIVE looks like.
static func _fold_state(word: String, index: int) -> int:
	var name: String = word
	if name == "" and index >= 0 and index < RESEARCH_STATE_NAMES.size():
		name = RESEARCH_STATE_NAMES[index]
	match name:
		"done": return State.DONE
		"active", "queued", "parked": return State.ACTIVE
		"available": return State.AVAILABLE
	return State.LOCKED


func _from_registry(registry: Object) -> bool:
	if registry == null or not registry.has_method(&"all"):
		return false
	for raw: Variant in registry.call(&"all", "research"):
		var res: Resource = raw as Resource
		if res == null:
			continue
		var n := TechNode.new()
		n.id = LcnUiFormat.as_name(res.get(&"id"))
		if String(n.id) == "":
			n.id = StringName(res.resource_path.get_file().get_basename())
		if String(n.id) == "":
			continue
		for field: StringName in [&"title", &"display_name", &"name"]:
			n.display_name = LcnUiFormat.as_text(res.get(field))
			if n.display_name != "":
				break
		if n.display_name == "":
			n.display_name = LcnUiFormat.item_name(n.id)
		n.description = LcnUiFormat.as_text(res.get(&"description"))
		n.flavour = LcnUiFormat.as_text(res.get(&"flavour"))
		n.branch = LcnUiFormat.as_name(res.get(&"branch"))
		n.tier = LcnUiFormat.as_int(res.get(&"tier"))
		n.urgency = LcnUiFormat.as_text(res.get(&"urgency_line"))
		if n.cost_points <= 0.0:
			n.cost_points = LcnUiFormat.as_number(res.get(&"work"))
		for field: StringName in [&"cost", &"cost_items", &"science"]:
			var c: Variant = res.get(field)
			if typeof(c) == TYPE_DICTIONARY and not (c as Dictionary).is_empty():
				n.cost = c
				break
			if typeof(c) == TYPE_FLOAT or typeof(c) == TYPE_INT:
				n.cost_points = float(c)
		if n.cost_points <= 0.0:
			n.cost_points = LcnUiFormat.as_number(res.get(&"points"))
		n.prereqs = _first_names(res, [&"prereqs", &"requires", &"parents", &"depends_on"])
		n.unlocks = _first_names(res, [&"unlocks", &"buildings", &"unlock_buildings"])
		n.grants = _first_names(res, [&"grants"])
		var payoff: Variant = res.get(&"effects")
		if typeof(payoff) == TYPE_DICTIONARY:
			n.effects = payoff
		n.source = &"content"
		_add(n)
	return not nodes.is_empty()


## The tree implied by content alone: every distinct BuildingDef.unlock_id is a
## node, and the buildings carrying it are what it opens.
func _from_buildings(build_system: Object) -> bool:
	if build_system == null or not build_system.has_method(&"all_defs"):
		return false
	var by_unlock: Dictionary[StringName, Array] = {}
	for raw: Variant in build_system.call(&"all_defs"):
		var def: Resource = raw as Resource
		if def == null:
			continue
		var unlock := LcnUiFormat.as_name(def.get(&"unlock_id"))
		if String(unlock) == "":
			continue
		var bucket: Array = by_unlock.get(unlock, [])
		bucket.append(LcnUiFormat.as_name(def.get(&"id")))
		by_unlock[unlock] = bucket
	var keys: Array = by_unlock.keys()
	keys = LcnUiFormat.sorted_names(keys)
	for k: Variant in keys:
		var id := StringName(String(k))
		var n := TechNode.new()
		n.id = id
		n.display_name = LcnUiFormat.item_name(id)
		n.description = "Opens %d building%s." % [
			(by_unlock[id] as Array).size(), "" if (by_unlock[id] as Array).size() == 1 else "s"]
		for b: Variant in by_unlock[id]:
			n.unlocks.append(StringName(String(b)))
		n.unlocks.sort_custom(func(a: StringName, c: StringName) -> bool: return String(a) < String(c))
		n.source = &"buildings"
		_add(n)
	return not nodes.is_empty()


## Even when [P10] publishes the tree it may not list which BUILDINGS a node
## opens; the building defs know, so fill the gap from there.
func _attach_unlocked_buildings(build_system: Object) -> void:
	if build_system == null or not build_system.has_method(&"all_defs") or nodes.is_empty():
		return
	for raw: Variant in build_system.call(&"all_defs"):
		var def: Resource = raw as Resource
		if def == null:
			continue
		var unlock := LcnUiFormat.as_name(def.get(&"unlock_id"))
		if String(unlock) == "":
			continue
		var n: TechNode = _by_id.get(unlock)
		if n == null:
			continue
		var kind := LcnUiFormat.as_name(def.get(&"id"))
		if not n.unlocks.has(kind):
			n.unlocks.append(kind)
			n.unlocks.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))


## `unlocks` arrives as an unlock-id list, and [P10] includes the node's own id
## in it (a BuildingDef gates on the node id directly). Anything in there that is
## not a building belongs under "also grants" — otherwise the screen tells a
## player that researching Ballistics opens a building called Ballistics.
func _normalise_unlocks(build_system: Object) -> void:
	for n: TechNode in nodes:
		var buildings: Array[StringName] = []
		for kind: StringName in n.unlocks:
			if kind == n.id:
				continue
			var is_building: bool = false
			if build_system != null and build_system.has_method(&"def_of"):
				is_building = build_system.call(&"def_of", kind) != null
			if is_building:
				buildings.append(kind)
			elif not n.grants.has(kind):
				n.grants.append(kind)
		n.unlocks = buildings
		var kept: Array[StringName] = []
		for g: StringName in n.grants:
			if g != n.id and not n.unlocks.has(g):
				kept.append(g)
		n.grants = kept
		n.grants.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))


func _add(n: TechNode) -> void:
	if _by_id.has(n.id):
		return
	_by_id[n.id] = n
	nodes.append(n)


# ----------------------------------------------------------------- layout ----

## Longest-path layering. Cycles cannot hang it: the relaxation runs a bounded
## number of passes and whatever is left keeps the depth it reached.
func _layout() -> void:
	for n: TechNode in nodes:
		var keep: Array[StringName] = []
		for p: StringName in n.prereqs:
			if _by_id.has(p) and p != n.id:
				keep.append(p)
		n.prereqs = keep
		if not _published_layout:
			n.column = 0

	if _published_layout:
		# [P10] already placed every node in branch bands. Re-laying it out would
		# throw away the one thing a hand-authored tree has that a derived one
		# does not: lanes that mean something.
		nodes.sort_custom(_node_less)
		for n5: TechNode in nodes:
			_columns = maxi(_columns, n5.column + 1)
		_rebuild_edges()
		return

	var changed: bool = true
	var passes: int = 0
	while changed and passes < MAX_DEPTH_PASSES:
		changed = false
		passes += 1
		for n2: TechNode in nodes:
			var depth: int = 0
			for p2: StringName in n2.prereqs:
				depth = maxi(depth, (_by_id[p2] as TechNode).column + 1)
			if depth != n2.column:
				n2.column = depth
				changed = true

	nodes.sort_custom(_node_less)
	var row_of_column: Dictionary[int, int] = {}
	for n3: TechNode in nodes:
		var r: int = int(row_of_column.get(n3.column, 0))
		n3.row = r
		row_of_column[n3.column] = r + 1
		_columns = maxi(_columns, n3.column + 1)

	_rebuild_edges()


func _rebuild_edges() -> void:
	_edges.clear()
	for n4: TechNode in nodes:
		for p3: StringName in n4.prereqs:
			_edges.append({"from": String(p3), "to": String(n4.id)})
	_edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a["from"]) != String(b["from"]):
			return String(a["from"]) < String(b["from"])
		return String(a["to"]) < String(b["to"]))


static func _node_less(a: TechNode, b: TechNode) -> bool:
	if a.column != b.column:
		return a.column < b.column
	if a.display_name != b.display_name:
		return a.display_name < b.display_name
	return String(a.id) < String(b.id)


# ------------------------------------------------------------------ state ----

## Re-reads progress from the sim.
##
## When [P10] publishes a layout it is the authority on state, progress, what is
## still owed and why a node is being recommended — re-deriving any of that here
## would only produce a second, worse answer.
func refresh_state(research: Object, build_system: Object) -> void:
	if _published_layout and research != null and research.has_method(&"tree_layout"):
		_refresh_from_layout(research)
		return
	var active := StringName("")
	if research != null and research.has_method(&"current_research"):
		active = StringName(String(research.call(&"current_research")))
	for n: TechNode in nodes:
		var done: bool = _is_unlocked(n.id, research, build_system)
		n.progress = 0.0
		if research != null and research.has_method(&"progress_of"):
			n.progress = clampf(float(research.call(&"progress_of", n.id)), 0.0, 1.0)
		if done:
			n.state = State.DONE
			n.progress = 1.0
			continue
		if String(active) != "" and active == n.id:
			n.state = State.ACTIVE
			continue
		var ready: bool = true
		for p: StringName in n.prereqs:
			if not _is_unlocked(p, research, build_system):
				ready = false
				break
		n.state = State.AVAILABLE if ready else State.LOCKED


func _refresh_from_layout(research: Object) -> void:
	var raw: Variant = research.call(&"tree_layout")
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var layout: Dictionary = raw
	suggestion = layout.get("suggestion", {})
	for entry: Variant in layout.get("nodes", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = entry
		var n: TechNode = _by_id.get(LcnUiFormat.as_name(d.get("id", "")))
		if n == null:
			continue
		n.state_word = LcnUiFormat.as_text(d.get("state", n.state_word))
		n.state = _fold_state(n.state_word, LcnUiFormat.as_int(d.get("state_index", 0)))
		n.progress = clampf(LcnUiFormat.as_number(d.get("progress", 0.0)), 0.0, 1.0)
		var owed: Variant = d.get("remaining_cost", null)
		if typeof(owed) == TYPE_DICTIONARY:
			n.remaining_cost = owed
		n.affordable = LcnUiFormat.as_flag(d.get("affordable", true))
		n.eta_seconds = LcnUiFormat.as_number(d.get("eta_seconds", -1.0))
		n.reason = LcnUiFormat.as_text(d.get("reason", ""))


func _is_unlocked(id: StringName, research: Object, build_system: Object) -> bool:
	if research != null:
		for method: StringName in [&"is_completed", &"is_unlocked", &"has_unlock", &"unlocked"]:
			if research.has_method(method):
				return bool(research.call(method, id))
	if build_system != null and build_system.has_method(&"is_unlocked"):
		return bool(build_system.call(&"is_unlocked", id))
	return false


## Prerequisites still missing, by name. What the panel puts under a locked node.
func missing_prereqs(n: TechNode, research: Object, build_system: Object) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for p: StringName in n.prereqs:
		if not _is_unlocked(p, research, build_system):
			var other: TechNode = _by_id.get(p)
			out.append(other.display_name if other != null else LcnUiFormat.item_name(p))
	return out


# -------------------------------------------------------------- relevance ----

## "Why this, why now." Measures each node against the city as it stands and
## writes one sentence. This is the difference between a tech tree you read and
## a tech tree you use.
func refresh_relevance(ctx: LcnBuildFacts.Ctx) -> void:
	var deficit: float = 0.0
	var frozen: int = 0
	if ctx != null and ctx.heat != null and ctx.heat.has_method(&"totals"):
		var totals: Dictionary = ctx.heat.call(&"totals")
		deficit = float(totals.get("deficit", 0.0))
		frozen = int(totals.get("frozen", 0))
	var wave: float = -1.0
	if ctx != null and ctx.climate != null and ctx.climate.has_method(&"seconds_until_night"):
		wave = float(ctx.climate.call(&"seconds_until_night"))

	for n: TechNode in nodes:
		n.relevance = ""
		n.relevance_tone = LcnUiStyle.Tone.DIM
		if n.state == State.DONE:
			n.relevance = "Already yours."
			continue
		var best: String = ""
		var tone: int = LcnUiStyle.Tone.DIM
		for kind: StringName in n.unlocks:
			var def: Resource = _def_of(ctx, kind)
			if def == null:
				continue
			var heat_out: float = LcnUiFormat.as_number(def.get(&"heat_produced"))
			var conduit: float = LcnUiFormat.as_number(def.get(&"conduit_throughput"))
			var residents: int = LcnUiFormat.as_int(def.get(&"residents"))
			var weapon := LcnUiFormat.as_name(def.get(&"weapon_id"))
			if deficit > 0.01 and heat_out > 0.0:
				best = "The city is %s short of heat; this opens %s at %s." % [
					LcnUiFormat.rate(deficit), LcnUiFormat.as_text(def.get(&"display_name")),
					LcnUiFormat.rate(heat_out)]
				tone = LcnUiStyle.Tone.ACCENT
				break
			if frozen > 0 and conduit > 0.0:
				best = "%d building%s frozen; this opens %s, which carries %s." % [
					frozen, "" if frozen == 1 else "s", LcnUiFormat.as_text(def.get(&"display_name")),
					LcnUiFormat.rate(conduit)]
				tone = LcnUiStyle.Tone.ACCENT
				break
			if wave >= 0.0 and wave < 120.0 and String(weapon) != "":
				best = "Night falls in %s; this opens %s." % [
					LcnUiFormat.duration(wave), LcnUiFormat.as_text(def.get(&"display_name"))]
				tone = LcnUiStyle.Tone.WARN
				break
			if best == "" and residents > 0:
				best = "Housing: %s takes %d more citizens." % [
					LcnUiFormat.as_text(def.get(&"display_name")), residents]
				tone = LcnUiStyle.Tone.NEUTRAL
		if best == "" and not n.unlocks.is_empty():
			var names: PackedStringArray = PackedStringArray()
			for kind2: StringName in n.unlocks:
				var d2: Resource = _def_of(ctx, kind2)
				names.append(LcnUiFormat.as_text(d2.get(&"display_name")) if d2 != null else LcnUiFormat.item_name(kind2))
			best = "Opens %s." % LcnUiFormat.prose_list(names)
		n.relevance = best
		n.relevance_tone = tone


func _def_of(ctx: LcnBuildFacts.Ctx, kind: StringName) -> Resource:
	if ctx == null or ctx.build == null or not ctx.build.has_method(&"def_of"):
		return null
	return ctx.build.call(&"def_of", kind) as Resource


# --------------------------------------------------------------- reading -----

static func _string_names(raw: Variant) -> Array[StringName]:
	var out: Array[StringName] = []
	if typeof(raw) == TYPE_ARRAY:
		for e: Variant in (raw as Array):
			var s := StringName(String(e))
			if String(s) != "" and not out.has(s):
				out.append(s)
	elif typeof(raw) == TYPE_STRING or typeof(raw) == TYPE_STRING_NAME:
		if String(raw) != "":
			out.append(StringName(String(raw)))
	return out


static func _first_names(res: Resource, fields: Array[StringName]) -> Array[StringName]:
	for f: StringName in fields:
		var v: Variant = res.get(f)
		var got: Array[StringName] = _string_names(v)
		if not got.is_empty():
			return got
	return []

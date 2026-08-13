class_name LcnStatsJournal
extends RefCounted
## The things that happened, pinned to the tick they happened on. [P20]
##
## A curve tells you the city lost forty people on day three. It does not tell
## you that you signed CORPSE PITS ninety seconds earlier. The journal is the
## other half: every law, every finished technology, every wave, every storm and
## every death of a building, kept as a bounded list of marks that the graphs
## draw as labelled verticals.
##
## This is what turns a run into a story you can read afterwards, which is the
## whole reason the society graph exists.
##
## It listens to [Bus] and nothing else. Nothing in here can reach the
## simulation, so a journal cannot perturb a replay even in principle.

## Marks kept. Older ones are dropped from the front; a campaign that outlives
## this has already told its story.
const CAPACITY: int = 512

## Mark kinds, in ascending visual weight. The graphs draw the loud ones with a
## label and the quiet ones as a tick.
enum Kind { NOTE, RESEARCH, LAW, WAVE, STORM, LOSS, END }

var marks: Array[Dictionary] = []
## Nights seen so far, as {night, from_tick, to_tick}. `to_tick` is -1 while the
## night is still going.
var nights: Array[Dictionary] = []

var _bus: Node = null
var _connected: bool = false
var _tick_source: Node = null


func _init() -> void:
	_bus = _autoload("Bus")
	_tick_source = _autoload("SimClock")


## Starts listening. Idempotent.
func listen() -> void:
	if _connected or _bus == null:
		return
	_connected = true
	_bus.connect("law_enacted", _on_law)
	_bus.connect("research_completed", _on_research)
	_bus.connect("wave_started", _on_wave_started)
	_bus.connect("wave_cleared", _on_wave_cleared)
	_bus.connect("night_started", _on_night_started)
	_bus.connect("day_started", _on_day_started)
	_bus.connect("game_over", _on_game_over)
	_bus.connect("narrative_event", _on_narrative)


func stop() -> void:
	if not _connected or _bus == null:
		return
	_connected = false
	for pair: Array in [
		["law_enacted", _on_law], ["research_completed", _on_research],
		["wave_started", _on_wave_started], ["wave_cleared", _on_wave_cleared],
		["night_started", _on_night_started], ["day_started", _on_day_started],
		["game_over", _on_game_over], ["narrative_event", _on_narrative],
	]:
		var sig: String = pair[0]
		var cb: Callable = pair[1]
		if _bus.is_connected(sig, cb):
			_bus.disconnect(sig, cb)


func clear() -> void:
	marks.clear()
	nights.clear()


## Adds a mark by hand. The screens use this for anything not on the bus.
func add(kind: int, text: String, tick: int = -1) -> void:
	var t: int = tick if tick >= 0 else _now()
	marks.append({"tick": t, "kind": kind, "text": text})
	if marks.size() > CAPACITY:
		marks.remove_at(0)


## Marks between two ticks, oldest first. What a graph draws under its window.
func between(from_tick: int, to_tick: int, kinds: Array[int] = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in marks:
		var t: int = int(m["tick"])
		if t < from_tick or t > to_tick:
			continue
		if not kinds.is_empty() and not kinds.has(int(m["kind"])):
			continue
		out.append(m)
	return out


## Night bands overlapping a window, clipped to it. `to_tick` of an unfinished
## night is reported as the window end so the shading runs to the right edge.
func night_bands(from_tick: int, to_tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for n: Dictionary in nights:
		var a: int = int(n["from_tick"])
		var b: int = int(n["to_tick"])
		if b < 0:
			b = to_tick
		if b < from_tick or a > to_tick:
			continue
		out.append({"night": int(n["night"]), "from_tick": maxi(a, from_tick),
			"to_tick": mini(b, to_tick)})
	return out


func current_night() -> Dictionary:
	if nights.is_empty():
		return {}
	var last: Dictionary = nights[nights.size() - 1]
	return last if int(last["to_tick"]) < 0 else {}


func night_count() -> int:
	return nights.size()


static func kind_label(kind: int) -> String:
	match kind:
		Kind.RESEARCH:
			return "Research"
		Kind.LAW:
			return "Law"
		Kind.WAVE:
			return "Assault"
		Kind.STORM:
			return "Storm"
		Kind.LOSS:
			return "Loss"
		Kind.END:
			return "End"
		_:
			return "Note"


static func kind_colour(kind: int) -> Color:
	var P := preload("res://game/view/render/palette.gd")
	match kind:
		Kind.RESEARCH:
			return P.ICE_BLUE
		Kind.LAW:
			return P.WARM_CORE
		Kind.WAVE:
			return P.EMBER
		Kind.STORM:
			return P.SNOW_MID
		Kind.LOSS:
			return P.DANGER
		Kind.END:
			return P.DANGER
		_:
			return P.SNOW_SHADOW


# ================================================================ signals ====

func _on_law(id: StringName) -> void:
	add(Kind.LAW, "Signed %s" % _titlecase(String(id)))


func _on_research(id: StringName) -> void:
	add(Kind.RESEARCH, _titlecase(String(id)))


func _on_wave_started(wave: int, strength: float) -> void:
	add(Kind.WAVE, "Wave %d (%.0f)" % [wave, strength])


func _on_wave_cleared(wave: int) -> void:
	add(Kind.WAVE, "Wave %d cleared" % wave)


func _on_night_started(day: int) -> void:
	nights.append({"night": day, "from_tick": _now(), "to_tick": -1})
	add(Kind.NOTE, "Night %d" % day)


func _on_day_started(day: int) -> void:
	for i: int in range(nights.size() - 1, -1, -1):
		if int(nights[i]["to_tick"]) < 0:
			nights[i]["to_tick"] = _now()
			break
	add(Kind.NOTE, "Day %d" % day)


func _on_game_over(reason: String) -> void:
	add(Kind.END, reason)


## Only the beats that change what a curve means get a mark. A dilemma the
## player never answered is chatter; a storm arriving is why heat fell.
func _on_narrative(id: StringName, payload: Dictionary) -> void:
	var key: String = String(id)
	if key.contains("storm"):
		add(Kind.STORM, String(payload.get("title", "Storm")))
	elif key.contains("exodus") or key.contains("collapse") or key.contains("revolt"):
		add(Kind.LOSS, _titlecase(key))


func _now() -> int:
	return 0 if _tick_source == null else int(_tick_source.get("tick"))


static func _titlecase(raw: String) -> String:
	var parts: PackedStringArray = raw.replace("_", " ").split(" ", false)
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		out.append(p.substr(0, 1).to_upper() + p.substr(1))
	return " ".join(out)


func _autoload(n: String) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(n))

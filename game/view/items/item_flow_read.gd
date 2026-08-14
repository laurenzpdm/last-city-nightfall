class_name LcnItemFlowRead
extends RefCounted
## [D2] ONE SAMPLE OF THE FACTORY, TAKEN ONCE PER SIMULATION TICK.
##
## `LogisticsSystem.items_for_view()` and `belts_for_view()` have existed,
## correct and tested, since [P03] landed, and until this file nothing under
## `game/view/` had ever called either of them. The automation pillar was fully
## simulated and completely invisible. This is the call site.
##
## Sampling is on the TICK, not on the frame: the simulation moves at 20 Hz and
## the view runs at whatever the machine gives it, so re-reading the world three
## times per tick would cost three times as much and produce the same numbers.
## Between ticks the layers interpolate — see `LcnItemFlowRoot`.
##
## WHAT COMES OUT OF THE PUBLIC API
##   items      {pos, kind, lane}        every item on every belt, world pixels
##   belts      {cell, kind, rot, tier, tunnel, entrance, saturation, rate}
##
## WHAT DOES NOT, AND WHY THIS FILE READS `world` DIRECTLY FOR IT
## There is no `machines_for_view()`. Arms, splitters and the two ends of an
## underground are the moving parts a player actually watches, and none of them
## can be reached through a published accessor, so the sampler walks
## `logi.world.inserter_ids` / `splitter_ids` READ-ONLY. Nothing here writes to
## `game/sim/**`; every field taken is copied into a plain dictionary the same
## tick it is read. That gap is written up in this part's report as a request to
## [P03], and the moment `machines_for_view()` exists this drops to one call.

## What a belt tile is doing. The four states a factory is read by.
enum Flow { STARVED, FLOWING, SATURATED, BACKED_UP }

const FLOW_NAMES: Array[StringName] = [&"starved", &"flowing", &"saturated", &"backed_up"]

## A line carrying at most this fraction of its rated throughput, while holding
## items, is not moving them: it is stuck. `LogiSegment.is_backed_up()` uses 20
## blocked ticks and 0.6 saturation, which is the same judgement made from
## inside; this is that judgement made from the two numbers the view is given.
const STALL_FLOW: float = 0.06
const STALL_FILL: float = 0.42
## Compressed: items are touching. A belt at its rated throughput sits here.
const PACKED_FILL: float = 0.70
## Nearly nothing on the tile. An empty belt is a starved belt.
const EMPTY_FILL: float = 0.14

var tick: int = -1
## Cell rectangle the current `items` were culled to, and whether they were
## asked for at all. A sample is only reusable inside these.
var bounds_sampled: Rect2i = Rect2i()
var items_wanted: bool = true
var items: Array[Dictionary] = []
var belts: Array[Dictionary] = []
var arms: Array[Dictionary] = []
var splitters: Array[Dictionary] = []
## Underground pairs, one entry per pair: {from, to, dir, kind, load, rate}.
var tunnels: Array[Dictionary] = []
## Belt cell -> index into `belts`, for the item interpolator.
var by_cell: Dictionary[Vector2i, int] = {}

var counts: Array[int] = [0, 0, 0, 0]
var read_us: int = 0

var _speed_of: Dictionary[StringName, float] = {}
var _rate_of: Dictionary[StringName, float] = {}


## True when a logistics system with the two view accessors is present.
static func system() -> Object:
	if not Sim.alive:
		return null
	var logi: Object = Sim.get_system(&"logistics")
	if logi == null:
		return null
	if not logi.has_method("items_for_view") or not logi.has_method("belts_for_view"):
		return null
	return logi


## Re-reads the world if the tick has moved. `bounds` is in CELLS and is passed
## straight to [P03], which culls items to it — an off-screen belt costs nothing.
##
## `want_items` is false when the zoom has already handed over to flow density:
## `items_for_view()` allocates one Dictionary per item and is by a wide margin
## the most expensive call here, so at map scale, where no individual item is
## drawn, it is not made at all.
##
## Returns true when a new sample was taken.
func sample(logi: Object, bounds: Rect2i, force: bool = false, want_items: bool = true) -> bool:
	if logi == null:
		return false
	if not force and tick == SimClock.tick and bounds_sampled.encloses(bounds) \
			and items_wanted == want_items:
		return false
	var t0: int = Time.get_ticks_usec()
	tick = SimClock.tick
	bounds_sampled = bounds
	items_wanted = want_items
	belts = logi.call("belts_for_view")
	# The bounds are baked into the sample, so a camera that pans while the game
	# is paused MUST force a re-read — otherwise the belts the player just
	# scrolled to are drawn empty and stay empty until the next tick. That is
	# how this first shipped, and the frame suite caught it.
	items = logi.call("items_for_view", bounds) if want_items else ([] as Array[Dictionary])
	_classify(logi)
	_read_machines(logi)
	read_us = Time.get_ticks_usec() - t0
	return true


## Belts, tagged with the state a player has to be able to read at a glance.
## `flow` is 0..1 of the line's rated throughput; `fill` is how full THIS tile
## is; `state` is the verdict the colour comes from.
func _classify(logi: Object) -> void:
	by_cell.clear()
	counts = [0, 0, 0, 0]
	for i: int in belts.size():
		var b: Dictionary = belts[i]
		var cell: Vector2i = LogiTypes.to_cell(b["cell"])
		b["cell_v"] = cell
		by_cell[cell] = i
		var kind: StringName = StringName(b["kind"])
		var max_rate: float = _rated(logi, kind)
		var fill: float = float(b["saturation"])
		var flow: float = 0.0 if max_rate <= 0.0 else clampf(float(b["rate"]) / max_rate, 0.0, 1.0)
		var state: int = Flow.FLOWING
		if flow <= STALL_FLOW and fill >= STALL_FILL:
			state = Flow.BACKED_UP
		elif fill >= PACKED_FILL:
			state = Flow.SATURATED
		elif fill <= EMPTY_FILL and flow <= 0.35:
			state = Flow.STARVED
		b["fill"] = fill
		b["flow"] = flow
		b["state"] = state
		b["speed"] = _speed(logi, kind)
		counts[state] += 1


## Tiles per second one belt of this kind runs at. Cached: `def_of` is a
## dictionary lookup but this is asked once per belt tile per tick.
func _speed(logi: Object, kind: StringName) -> float:
	if _speed_of.has(kind):
		return _speed_of[kind]
	var v: float = 1.875
	if logi.has_method("def_of"):
		var def: Object = logi.call("def_of", kind)
		if def != null:
			v = maxf(0.01, float(def.get("speed")))
	_speed_of[kind] = v
	return v


func _rated(logi: Object, kind: StringName) -> float:
	if _rate_of.has(kind):
		return _rate_of[kind]
	var v: float = 0.0
	if logi.has_method("def_of"):
		var def: Object = logi.call("def_of", kind)
		if def != null and def.has_method("belt_rate"):
			v = float(def.call("belt_rate"))
	if v <= 0.0:
		v = LogiTypes.lane_rate(_speed(logi, kind)) * float(LogiTypes.LANES)
	_rate_of[kind] = v
	return v


## Arms, splitters and underground pairs. Read-only; see the header.
func _read_machines(logi: Object) -> void:
	arms.clear()
	splitters.clear()
	tunnels.clear()
	var world: Object = logi.get("world")
	if world == null:
		return
	var raw_entities: Variant = world.get("entities")
	if typeof(raw_entities) != TYPE_DICTIONARY:
		return
	var entities: Dictionary = raw_entities

	var inserter_ids: Array = world.get("inserter_ids")
	for id: int in inserter_ids:
		var arm: Object = entities.get(id)
		if arm == null:
			continue
		var half: float = maxf(0.001, float(arm.call("cycle_time")) * 0.5)
		arms.append({
			"cell": arm.get("cell"),
			"from": arm.call("source_cell"),
			"to": arm.call("target_cell"),
			"phase": int(arm.get("phase")),
			"timer": float(arm.get("timer")),
			"half": half,
			"held": int(arm.get("held")),
			"held_kind": StringName(arm.get("held_kind")),
			"hand": int(arm.call("hand_size")),
			"idle": int(arm.get("idle_ticks")),
			"enabled": bool(arm.get("enabled")),
		})

	var splitter_ids: Array = world.get("splitter_ids")
	for id: int in splitter_ids:
		var sp: Object = entities.get(id)
		if sp == null:
			continue
		splitters.append({
			"cells": sp.call("footprint"),
			"inputs": sp.call("input_cells"),
			"outputs": sp.call("output_cells"),
			"rot": int(sp.get("rot")),
			"buffered": int(sp.call("buffered")),
			"rate": float(sp.get("rate_ema")),
			"next_out": _first_int(sp.get("next_out")),
		})

	# Underground mouths come through belts_for_view already flagged; the pair
	# is the one thing only the entity knows, and a tunnel with no line drawn
	# between its ends looks like two unrelated stubs.
	for b: Dictionary in belts:
		if not bool(b.get("tunnel", false)) or not bool(b.get("entrance", false)):
			continue
		var e: Object = logi.call("entity_at", b["cell_v"]) if logi.has_method("entity_at") else null
		if e == null:
			continue
		var other: Object = entities.get(int(e.get("pair_id")))
		if other == null:
			continue
		tunnels.append({
			"from": b["cell_v"],
			"to": other.get("cell"),
			"rot": int(b["rot"]),
			"load": float(b["fill"]),
			"flow": float(b["flow"]),
			"state": int(b["state"]),
			"speed": float(b["speed"]),
		})


## First element of a small int array, 0 when there is not one.
static func _first_int(v: Variant) -> int:
	if typeof(v) != TYPE_ARRAY:
		return 0
	var a: Array = v
	return 0 if a.is_empty() else int(a[0])


## One line for the log and for the frame suites.
func summary() -> String:
	return "%d item(s) on %d belt tile(s) — %d starved, %d flowing, %d saturated, %d backed up; %d arm(s), %d splitter(s), %d tunnel(s)" % [
		items.size(), belts.size(), counts[Flow.STARVED], counts[Flow.FLOWING],
		counts[Flow.SATURATED], counts[Flow.BACKED_UP], arms.size(), splitters.size(),
		tunnels.size()]

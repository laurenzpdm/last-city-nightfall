class_name ProdMachine
extends RefCounted
## One placed machine as production sees it: a recipe, two buffers, a progress
## bar, and — the part that matters — a written reason for why it is not moving.
##
## Everything a player needs to answer "why is this thing idle?" lives on this
## object, which is exactly the contract [P19]'s overlays and [P17]'s HUD read.

enum State {
	IDLE,      ## nothing to do — no recipe chosen, or switched off
	RUNNING,   ## consuming, working, producing
	STALLED,   ## wants to run and cannot; `reason` says why
	FROZEN,    ## the heat network gave up on it; dead until it thaws
}

## Every reason a machine can stop. [P19] renders these; keep them stable.
const REASON_NONE: StringName = &""
const REASON_NO_RECIPE: StringName = &"no_recipe"
const REASON_LOCKED: StringName = &"locked"
const REASON_MISSING_INPUT: StringName = &"missing_input"
const REASON_OUTPUT_FULL: StringName = &"output_full"
const REASON_NO_HEAT: StringName = &"no_heat"
const REASON_TOO_COLD: StringName = &"too_cold"
const REASON_FROZEN: StringName = &"frozen"
const REASON_UNSTAFFED: StringName = &"unstaffed"
const REASON_DEPLETED: StringName = &"depleted"
const REASON_DISABLED: StringName = &"disabled"

var id: int = 0
var kind: StringName = &""
var cell: Vector2i = Vector2i.ZERO
var rot: int = 0
var def: ProdMachineDef = null
var footprint: Array[Vector2i] = []
var center_cell: Vector2i = Vector2i.ZERO
var world_pos: Vector2 = Vector2.ZERO

# --- what it is doing -----------------------------------------------------
var recipe_id: StringName = &""
var recipe: RecipeDef = null
## Total units one craft emits, primary plus byproducts. Cached: the "will it
## fit" test runs for every machine every tick.
var output_size: int = 0
var state: int = State.IDLE
var reason: StringName = REASON_NONE
## The specific item a REASON_MISSING_INPUT is about. Empty otherwise.
var reason_item: StringName = &""
## The last crew this machine actually had, and the tick it was last seen. A
## shop coasts on the work already on the bench for a few seconds after the last
## hand steps out — see ProductionSystem.STAFF_COAST_TICKS and `bench`.
var staff_held: float = 0.0
var staff_seen_tick: int = -1000000
## Work done on the current craft, in ticks of recipe time.
var progress: float = 0.0
## True once inputs have been consumed and the craft is genuinely under way.
var committed: bool = false
var crafts_done: int = 0
var enabled: bool = true

# --- buffers --------------------------------------------------------------
var inputs: Dictionary[StringName, int] = {}
var outputs: Dictionary[StringName, int] = {}

# --- environment, refreshed on a slow cadence ------------------------------
## 0..1 from [P02]: how much of its rated heat draw the machine is getting.
var power: float = 1.0
## 0..1 from the warmth field: cold hands work slowly.
var cold: float = 1.0
## 0..1 from [P05]: crew PRESENT, exactly as [P05] reports it, with nothing
## smoothed into it. This is the published cross-part number and
## tests/production asserts it against `citizens.staffing_of(id)` to the fourth
## decimal — read it when you want the truth about who is standing here.
var staffing: float = 1.0
## 0..1, `staffing` with the bench coast applied: what the shop can actually get
## done this tick, which is not zero the instant its one hand walks to the
## larder. This is what drives `rate` and the UNSTAFFED stall. It equals
## `staffing` whenever anybody is present, and decays to it within
## ProductionSystem.STAFF_COAST_TICKS when nobody is.
var bench: float = 1.0
## 0..1 heat-cost coupling: what fraction of the recipe's heat rate is available.
var heat_factor: float = 1.0
## The temperature the machine actually feels, in degrees Celsius.
var felt_c: float = 0.0
## Product of every factor. The speed multiplier applied to progress this tick.
var rate: float = 0.0

# --- extraction -----------------------------------------------------------
## The deposit tile this machine is working, or (-1,-1).
var seam: Vector2i = Vector2i(-1, -1)
## Grid.Res kind of that seam.
var seam_kind: int = 0
## Item the seam yields.
var seam_item: StringName = &""
## Fractional units mined but not yet whole.
var extract_acc: float = 0.0
var last_seam_search: int = -100000

# --- waste heat -----------------------------------------------------------
## Recoverable waste units banked here, waiting for a recuperator to take them.
var waste_bank: float = 0.0
## Waste units per second this machine handed to recuperators last tick.
var waste_given: float = 0.0
## Waste units per second a recuperator actually took in last tick.
var waste_taken: float = 0.0

# --- bookkeeping ----------------------------------------------------------
## Lifetime units produced per item. Drives the per-minute rates.
var produced: Dictionary[StringName, int] = {}
## Tick the current stall reason was last announced on Bus.
var announced_tick: int = -100000
var announced_reason: StringName = REASON_NONE


func setup(machine_id: int, machine_kind: StringName, origin: Vector2i, d: ProdMachineDef, rotation: int) -> void:
	id = machine_id
	kind = machine_kind
	cell = origin
	rot = rotation
	def = d
	footprint = d.footprint_at(origin, rotation)
	if footprint.is_empty():
		footprint = [origin]
	var lo: Vector2i = footprint[0]
	var hi: Vector2i = footprint[0]
	for c: Vector2i in footprint:
		lo.x = mini(lo.x, c.x)
		lo.y = mini(lo.y, c.y)
		hi.x = maxi(hi.x, c.x)
		hi.y = maxi(hi.y, c.y)
	var span: Vector2i = hi - lo + Vector2i.ONE
	center_cell = lo + Vector2i(span.x / 2, span.y / 2)
	world_pos = Vector2((float(lo.x) + float(span.x) * 0.5) * 32.0,
		(float(lo.y) + float(span.y) * 0.5) * 32.0)


## 0..1 progress on the current craft, for the little bar over the machine.
func progress_ratio() -> float:
	if recipe == null or recipe.time_ticks <= 0:
		return 0.0
	return clampf(progress / float(recipe.time_ticks), 0.0, 1.0)


## Units of `item` held across both buffers.
func held(item: StringName) -> int:
	return int(inputs.get(item, 0)) + int(outputs.get(item, 0))


func input_total() -> int:
	return _sum(inputs)


func output_total() -> int:
	return _sum(outputs)


## Room left for finished goods. A machine stalls when a craft would not fit.
func output_room() -> int:
	return maxi(0, def.output_slots - output_total())


func input_room() -> int:
	return maxi(0, def.input_slots - input_total())


## True when the input buffer already holds one full set of what the recipe asks.
func has_all_inputs() -> bool:
	if recipe == null:
		return false
	for k: StringName in recipe.sorted_inputs():
		if int(inputs.get(k, 0)) < recipe.inputs[k]:
			return false
	return true


## The first input the machine is short of, or empty when it has everything.
func first_missing_input() -> StringName:
	if recipe == null:
		return &""
	for k: StringName in recipe.sorted_inputs():
		if int(inputs.get(k, 0)) < recipe.inputs[k]:
			return k
	return &""


func add_input(item: StringName, amount: int) -> void:
	if amount <= 0:
		return
	inputs[item] = int(inputs.get(item, 0)) + amount


func add_output(item: StringName, amount: int) -> void:
	if amount <= 0:
		return
	outputs[item] = int(outputs.get(item, 0)) + amount
	produced[item] = int(produced.get(item, 0)) + amount


func take_output(item: StringName, amount: int) -> int:
	var have: int = int(outputs.get(item, 0))
	var n: int = mini(have, amount)
	if n <= 0:
		return 0
	if have - n <= 0:
		outputs.erase(item)
	else:
		outputs[item] = have - n
	return n


func consume_inputs() -> void:
	if recipe == null:
		return
	for k: StringName in recipe.sorted_inputs():
		var left: int = int(inputs.get(k, 0)) - recipe.inputs[k]
		if left <= 0:
			inputs.erase(k)
		else:
			inputs[k] = left


func is_working() -> bool:
	return state == State.RUNNING


## Sorted item ids of a buffer — every iteration that reaches state is ordered,
## and ordered ALPHABETICALLY rather than by intern pointer. See [ProdSort].
func sorted_keys(d: Dictionary[StringName, int]) -> Array[StringName]:
	return ProdSort.keys_of(d)


func to_json() -> Dictionary:
	return {
		"id": id,
		"kind": String(kind),
		"cell": [cell.x, cell.y],
		"recipe": String(recipe_id),
		"state": state,
		"reason": String(reason),
		"reason_item": String(reason_item),
		"progress": snappedf(progress, 0.001),
		"crafts": crafts_done,
		"inputs": _json(inputs),
		"outputs": _json(outputs),
		"produced": _json(produced),
		"rate": snappedf(rate, 0.0001),
		"power": snappedf(power, 0.0001),
		"cold": snappedf(cold, 0.0001),
		"heat_factor": snappedf(heat_factor, 0.0001),
		"staffing": snappedf(staffing, 0.0001),
		"bench": snappedf(bench, 0.0001),
		"staff_held": snappedf(staff_held, 0.0001),
		"staff_seen_tick": staff_seen_tick,
		"felt_c": snappedf(felt_c, 0.01),
		"seam": [seam.x, seam.y],
		"seam_item": String(seam_item),
		"waste_bank": snappedf(waste_bank, 0.001),
		"waste_given": snappedf(waste_given, 0.001),
		"waste_taken": snappedf(waste_taken, 0.001),
	}


func from_json(data: Dictionary) -> void:
	recipe_id = StringName(String(data.get("recipe", "")))
	state = int(data.get("state", State.IDLE))
	reason = StringName(String(data.get("reason", "")))
	reason_item = StringName(String(data.get("reason_item", "")))
	progress = float(data.get("progress", 0.0))
	crafts_done = int(data.get("crafts", 0))
	inputs = _items(data.get("inputs", {}))
	outputs = _items(data.get("outputs", {}))
	produced = _items(data.get("produced", {}))
	waste_bank = float(data.get("waste_bank", 0.0))
	# Environment factors are recomputed on the next tick, but a save that came
	# back with them zeroed would make the first frame after a load report every
	# machine as freezing — so they round-trip like everything else.
	rate = float(data.get("rate", 0.0))
	power = float(data.get("power", 1.0))
	cold = float(data.get("cold", 1.0))
	heat_factor = float(data.get("heat_factor", 1.0))
	staffing = float(data.get("staffing", 1.0))
	# The coast is a clock, so it has to round-trip or a load hands every shop a
	# fresh 900 ticks of bench work it never earned.
	bench = float(data.get("bench", staffing))
	staff_held = float(data.get("staff_held", 0.0))
	staff_seen_tick = int(data.get("staff_seen_tick", -1000000))
	felt_c = float(data.get("felt_c", 0.0))
	waste_given = float(data.get("waste_given", 0.0))
	waste_taken = float(data.get("waste_taken", 0.0))
	var s: Variant = data.get("seam", [-1, -1])
	if typeof(s) == TYPE_ARRAY and (s as Array).size() >= 2:
		seam = Vector2i(int((s as Array)[0]), int((s as Array)[1]))
	seam_item = StringName(String(data.get("seam_item", "")))


func _sum(d: Dictionary[StringName, int]) -> int:
	var n: int = 0
	for k: StringName in d:
		n += d[k]
	return n


func _json(d: Dictionary[StringName, int]) -> Dictionary:
	var out: Dictionary = {}
	for k: StringName in sorted_keys(d):
		if d[k] > 0:
			out[String(k)] = d[k]
	return out


func _items(v: Variant) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	if typeof(v) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = v
	for k: StringName in ProdSort.keys_of(src):
		var n: int = int(src.get(k, src.get(String(k), 0)))
		if n > 0:
			out[k] = n
	return out

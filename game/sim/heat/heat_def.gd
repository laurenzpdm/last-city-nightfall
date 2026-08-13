class_name HeatDef
extends RefCounted
## Normalized, typed view of one building definition's heat behaviour.
##
## THE POINT: no code in game/sim/heat/ knows the name of a single building.
## Everything the network does is derived from whatever Registry has under
## "buildings", read by duck typing, so [P04] and any content agent can add a
## generator, a pipe, a buffer or a consumer by dropping a .tres — and never
## touch heat code.
##
## Three spellings are understood, in this order of precedence:
##   1. a `heat` Dictionary property on the resource, keys without the prefix:
##      heat = { "output": 90.0, "capacity": 90.0, "priority": 70, "repeater": true }
##   2. explicit heat_* properties (heat_output, heat_demand, heat_capacity, ...)
##   3. the shared BuildingDef schema owned by [P11]:
##      heat_produced, heat_consumed, heat_buffer, heat_radius, heat_insulation,
##      is_heat_conduit, conduit_throughput, fuel_items, fuel_burn_rate, tags,
##      category
##
## Anything a definition leaves out is DERIVED, and the derivations are the
## design rules of the heat game, written down once:
##
##   loss per tile   = 0.030 * (1 - insulation)      insulation IS the pipe upgrade
##   radiance        = max(output*0.35, demand*1.6)  clamped 4..30 degrees
##   priority        = by category, so a shortfall sheds industry before homes
##   grid buffer     = tagged "buffer", or any generator's internal store —
##                     a plain building's heat_buffer is a LOCAL ride-through
##                     that carries it through a brownout instead of feeding others
##   charge/discharge= full in 20 s / empty in 15 s
##   ramp            = 60/output per second, so big plants spin up slowly
##   fuel per unit   = fuel_burn_rate / (output + self_burn)

const BASE_PIPE_LOSS: float = 0.030
const CHARGE_SECONDS: float = 20.0
const DISCHARGE_SECONDS: float = 15.0
const RADIANCE_MIN: float = 4.0
const RADIANCE_MAX: float = 30.0
const PASSIVE_FREEZE_C: float = -80.0   ## pipes and tanks do not "freeze"
const ACTIVE_FREEZE_C: float = -10.0

var kind: StringName = &""
var display_name: String = ""
var size: Vector2i = Vector2i.ONE
var role: StringName = &"consumer"
var res: Resource = null

# generation
var output: float = 0.0
var ramp: float = 1.0
var self_burn: float = 0.0
var fuel: StringName = &""
var fuel_per_unit: float = 0.0
var fuel_capacity: float = 100.0

# consumption
var demand: float = 0.0
var priority: int = 50
var cold_sensitivity: float = 1.0
var local_buffer: float = 0.0    ## thermal mass that rides out a brownout

# conduction
var capacity: float = 0.0
var loss_per_tile: float = 0.0
var repeater: bool = false

# storage on the grid
var storage: float = 0.0
var charge_rate: float = 0.0
var discharge_rate: float = 0.0
var leak: float = 0.0

# thermal
var radius: float = 0.0
var radiance: float = 0.0
var insulation: float = 0.35
var freeze_below: float = ACTIVE_FREEZE_C


## True when this definition has any business being in the heat graph at all.
## A building that answers false is simply not a heat entity and is ignored.
func participates() -> bool:
	return output > 0.0 or demand > 0.0 or capacity > 0.0 or storage > 0.0 or radiates()


func is_producer() -> bool:
	return output > 0.0


func is_consumer() -> bool:
	return demand > 0.0


func conducts() -> bool:
	return capacity > 0.0


func is_buffer() -> bool:
	return storage > 0.0 and discharge_rate > 0.0


func radiates() -> bool:
	return radius > 0.0 and radiance > 0.0


## Absolute cells the building occupies. Defers to the definition's own
## footprint maths when it has any, so rotated and L-shaped buildings occupy
## exactly the cells [P11] thinks they do.
func footprint_at(origin: Vector2i, rot: int) -> Array[Vector2i]:
	if res != null and res.has_method("cells_at"):
		var raw: Variant = res.call("cells_at", origin, rot)
		if typeof(raw) == TYPE_ARRAY:
			var arr: Array = raw
			if not arr.is_empty():
				var out: Array[Vector2i] = []
				for c: Variant in arr:
					if typeof(c) == TYPE_VECTOR2I:
						out.append(c)
				if not out.is_empty():
					return out
	var s: Vector2i = size
	if rot % 2 == 1:
		s = Vector2i(size.y, size.x)
	var rect: Array[Vector2i] = []
	for dx: int in s.x:
		for dy: int in s.y:
			rect.append(origin + Vector2i(dx, dy))
	return rect


static func from_resource(building_kind: StringName, source: Resource) -> HeatDef:
	var d := HeatDef.new()
	d.kind = building_kind
	d.res = source
	var over: Dictionary = {}
	if source != null and "heat" in source:
		var raw: Variant = source.get("heat")
		if typeof(raw) == TYPE_DICTIONARY:
			over = raw
	var tags: Array = []
	if source != null and "tags" in source:
		var traw: Variant = source.get("tags")
		if typeof(traw) == TYPE_ARRAY:
			tags = traw
	var category: String = _str(source, over, ["category"], "category", "")

	d.display_name = _str(source, over, ["display_name"], "display_name", String(building_kind))
	d.size = _size(source, over)
	d.role = StringName(_str(source, over, ["role"], "role", category if category != "" else "consumer"))

	# --- generation ---
	d.output = maxf(0.0, _num(source, over, ["heat_output", "heat_produced"], "output", 0.0))
	d.ramp = maxf(0.01, _num(source, over, ["heat_ramp"], "ramp",
		clampf(60.0 / maxf(d.output, 1.0), 0.25, 2.0)))

	# --- consumption ---
	d.demand = maxf(0.0, _num(source, over, ["heat_demand", "heat_consumed"], "demand", 0.0))
	d.cold_sensitivity = maxf(0.0, _num(source, over,
		["heat_cold_sensitivity"], "cold_sensitivity", 1.0))
	d.priority = clampi(int(_num(source, over, ["heat_priority"], "priority",
		float(_derive_priority(category, tags)))), 0, 100)

	# --- conduction ---
	d.insulation = clampf(_num(source, over, ["heat_insulation"], "insulation", 0.35), 0.0, 0.99)
	var explicit_cap: float = _num(source, over, ["heat_capacity"], "capacity", -1.0)
	if explicit_cap >= 0.0:
		d.capacity = explicit_cap
	elif _flag(source, over, ["is_heat_conduit"], "conduit", tags.has(&"conduit")):
		d.capacity = maxf(0.0, _num(source, over, ["conduit_throughput"], "throughput", 60.0))
	var explicit_loss: float = _num(source, over, ["heat_loss_per_tile"], "loss_per_tile", -1.0)
	d.loss_per_tile = clampf(explicit_loss if explicit_loss >= 0.0
		else BASE_PIPE_LOSS * (1.0 - d.insulation), 0.0, 0.9)
	d.repeater = _flag(source, over, ["heat_repeater"], "repeater", tags.has(&"repeater"))

	# --- storage ---
	var raw_store: float = maxf(0.0, _num(source, over,
		["heat_storage", "heat_buffer"], "storage", 0.0))
	var explicit_store: bool = _has(source, over, ["heat_storage"], "storage") \
		or _has(source, over, ["heat_discharge_rate"], "discharge_rate")
	# A generator's internal store is a spinning reserve for the whole grid.
	# Everyone else's is thermal mass that only ever helps itself.
	if raw_store > 0.0 and (explicit_store or tags.has(&"buffer") or d.output > 0.0):
		d.storage = raw_store
		d.charge_rate = _num(source, over, ["heat_charge_rate"], "charge_rate",
			raw_store / CHARGE_SECONDS)
		d.discharge_rate = _num(source, over, ["heat_discharge_rate"], "discharge_rate",
			raw_store / DISCHARGE_SECONDS)
		d.leak = clampf(_num(source, over, ["heat_leak"], "leak",
			0.02 * (1.0 - d.insulation)), 0.0, 1.0)
	else:
		d.local_buffer = raw_store

	# --- thermal ---
	d.radius = maxf(0.0, _num(source, over, ["heat_radius"], "radius", 0.0))
	var derived_radiance: float = 0.0
	if d.radius > 0.0:
		derived_radiance = clampf(maxf(d.output * 0.35, d.demand * 1.6),
			RADIANCE_MIN, RADIANCE_MAX)
	d.radiance = maxf(0.0, _num(source, over, ["heat_radiance"], "radiance", derived_radiance))
	var passive: bool = d.output <= 0.0 and d.demand <= 0.0
	d.freeze_below = _num(source, over, ["heat_freeze_below"], "freeze_below",
		PASSIVE_FREEZE_C if passive else ACTIVE_FREEZE_C)

	# --- fuel ---
	d.self_burn = maxf(0.0, _num(source, over, ["heat_self_burn"], "self_burn",
		d.output * 0.15 if d.radiates() else 0.0))
	d.fuel = StringName(_str(source, over, ["heat_fuel"], "fuel", _first_fuel(source)))
	var burn_rate: float = maxf(0.0, _num(source, over, ["fuel_burn_rate"], "fuel_burn_rate", 0.0))
	var per_unit_default: float = 0.0
	if burn_rate > 0.0:
		per_unit_default = burn_rate / maxf(d.output + d.self_burn, 1.0)
	d.fuel_per_unit = maxf(0.0, _num(source, over,
		["heat_fuel_per_unit"], "fuel_per_unit", per_unit_default))
	d.fuel_capacity = maxf(1.0, _num(source, over, ["heat_fuel_capacity"], "fuel_capacity",
		maxf(50.0, burn_rate * 180.0)))
	if d.fuel == &"":
		d.fuel_per_unit = 0.0
	return d


## Shed order. Industry goes dark before the turrets, the turrets before the
## homes — the same order a player would choose, so a brownout never feels random.
static func _derive_priority(category: String, tags: Array) -> int:
	var p: int = 50
	match category:
		"housing": p = 90
		"heat": p = 85
		"power": p = 80
		"defense": p = 75
		"extraction": p = 55
		"production": p = 50
		"logistics": p = 45
		"infrastructure": p = 40
		"storage": p = 30
	if tags.has(&"comfort"):
		p = maxi(p, 90)
	if tags.has(&"unique") or tags.has(&"landmark"):
		p = maxi(p, 95)
	if tags.has(&"turret") or tags.has(&"defense"):
		p = maxi(p, 75)
	return p


static func _first_fuel(source: Resource) -> String:
	if source == null or not ("fuel_items" in source):
		return ""
	var raw: Variant = source.get("fuel_items")
	if typeof(raw) != TYPE_ARRAY:
		return ""
	var arr: Array = raw
	if arr.is_empty():
		return ""
	return String(arr[0])


static func _has(source: Resource, over: Dictionary, props: Array, key: String) -> bool:
	if over.has(key):
		return true
	for p: String in props:
		if source != null and p in source:
			return true
	return false


static func _num(source: Resource, over: Dictionary, props: Array, key: String,
		fallback: float) -> float:
	if over.has(key):
		var ov: Variant = over[key]
		if typeof(ov) == TYPE_FLOAT or typeof(ov) == TYPE_INT:
			return float(ov)
	for p: String in props:
		if source != null and p in source:
			var v: Variant = source.get(p)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				return float(v)
	return fallback


static func _str(source: Resource, over: Dictionary, props: Array, key: String,
		fallback: String) -> String:
	if over.has(key):
		var ov: Variant = over[key]
		if typeof(ov) == TYPE_STRING or typeof(ov) == TYPE_STRING_NAME:
			return String(ov)
	for p: String in props:
		if source != null and p in source:
			var v: Variant = source.get(p)
			if (typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME) and String(v) != "":
				return String(v)
	return fallback


static func _flag(source: Resource, over: Dictionary, props: Array, key: String,
		fallback: bool) -> bool:
	if over.has(key):
		return bool(over[key])
	for p: String in props:
		if source != null and p in source:
			var v: Variant = source.get(p)
			if typeof(v) == TYPE_BOOL:
				return bool(v)
	return fallback


static func _size(source: Resource, over: Dictionary) -> Vector2i:
	var raw: Variant = null
	if over.has("size"):
		raw = over["size"]
	elif source != null and "size" in source:
		raw = source.get("size")
	elif source != null and "footprint" in source:
		raw = source.get("footprint")
	match typeof(raw):
		TYPE_VECTOR2I:
			var vi: Vector2i = raw
			return Vector2i(maxi(1, vi.x), maxi(1, vi.y))
		TYPE_VECTOR2:
			var vf: Vector2 = raw
			return Vector2i(maxi(1, int(vf.x)), maxi(1, int(vf.y)))
		TYPE_ARRAY:
			var arr: Array = raw
			if arr.size() >= 2:
				return Vector2i(maxi(1, int(arr[0])), maxi(1, int(arr[1])))
	return Vector2i.ONE

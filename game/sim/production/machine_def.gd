class_name ProdMachineDef
extends RefCounted
## Normalized, typed view of one building definition's production behaviour.
##
## THE POINT, same as [HeatDef]: no code in game/sim/production/ knows the name
## of a single building. A .tres in game/content/buildings/ becomes a machine
## purely by carrying `recipes` or `extracts`, and a content agent can add a
## crafter without touching a line of this folder.
##
## Read straight off the [P11] BuildingDef schema, with a `production`
## dictionary override understood first so a def can tune a field the shared
## schema has no room for:
##
##     production = { "reach": 14, "input_slots": 200, "waste_capture": 5.0 }

const DEFAULT_STORAGE: int = 100
## Fraction of a machine's storage_capacity reserved for finished goods. The
## rest holds inputs, so a machine can never starve itself by hoarding output.
const OUTPUT_SHARE: float = 0.4
## Tiles a machine without a `needs_ore` rule will walk to work a seam. A drill
## sits on its vein; a salvage crew fans out.
const DEFAULT_REACH: int = 14
## Waste heat units per second a recuperator can pull in. Derived from its rated
## fuel burn when the def does not say.
const DEFAULT_CAPTURE_RADIUS: float = 4.0

var kind: StringName = &""
var display_name: String = ""
var size: Vector2i = Vector2i.ONE
var tags: Array[StringName] = []
var res: Resource = null

# --- crafting -------------------------------------------------------------
## Recipe ids the definition offers, in menu order. May be empty for extractors.
var recipes: Array[StringName] = []
## Multiplier on recipe speed. 2.0 halves every craft time.
var craft_speed: float = 1.0
## Item slots for inputs and for outputs. Split out of storage_capacity.
var input_slots: int = 60
var output_slots: int = 40

# --- extraction -----------------------------------------------------------
## Item this machine pulls out of the ground. &"*" means "whatever is under it".
var extracts: StringName = &""
## Units per second at full staffing, heat and warmth.
var extract_rate: float = 0.0
## Tiles it will reach to find a seam. 0 = it must stand on one.
var reach: int = 0

# --- heat -----------------------------------------------------------------
## Rated heat draw per second. The ceiling on what a recipe's heat_cost can use.
var heat_rating: float = 0.0
## 0..1 shell quality. Shifts the cold curve: a sealed shop keeps working colder.
var insulation: float = 0.35
## Waste heat units per second this machine can take in as fuel. > 0 makes it a
## recuperator: it burns captured waste instead of coal.
var waste_capture: float = 0.0
## Tiles a recuperator reaches to collect waste heat.
var capture_radius: float = 0.0

# --- staffing -------------------------------------------------------------
var workers_required: int = 0


func is_crafter() -> bool:
	return not recipes.is_empty()


func is_extractor() -> bool:
	return String(extracts) != "" and extract_rate > 0.0


func is_recuperator() -> bool:
	return waste_capture > 0.0


## True when this definition has any business being in the production world.
func participates() -> bool:
	return is_crafter() or is_extractor() or is_recuperator()


## Absolute cells the building occupies. Defers to [P11]'s own footprint maths
## so a rotated or L-shaped machine occupies exactly the cells build thinks it
## does — production must never disagree with placement about where a thing is.
func footprint_at(origin: Vector2i, rot: int) -> Array[Vector2i]:
	if res != null and res.has_method("cells_at"):
		var raw: Variant = res.call("cells_at", origin, rot)
		if typeof(raw) == TYPE_ARRAY:
			var arr: Array = raw
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
	for dy: int in s.y:
		for dx: int in s.x:
			rect.append(origin + Vector2i(dx, dy))
	return rect


static func from_resource(building_kind: StringName, source: Resource) -> ProdMachineDef:
	var d := ProdMachineDef.new()
	d.kind = building_kind
	d.res = source
	var over: Dictionary = {}
	if source != null and "production" in source:
		var raw: Variant = source.get("production")
		if typeof(raw) == TYPE_DICTIONARY:
			over = raw

	d.display_name = _str(source, over, "display_name", "display_name", String(building_kind))
	d.size = _size(source)
	d.tags = _names(source, "tags")
	d.recipes = _names_over(source, over, "recipes", "recipes")
	d.craft_speed = maxf(0.01, _num(source, over, "craft_speed", "craft_speed", 1.0))
	d.extracts = StringName(_str(source, over, "extracts", "extracts", ""))
	d.extract_rate = maxf(0.0, _num(source, over, "extract_rate", "extract_rate", 0.0))
	d.workers_required = maxi(0, int(_num(source, over, "workers_required", "workers_required", 0.0)))
	d.heat_rating = maxf(0.0, _num(source, over, "heat_consumed", "heat_rating", 0.0))
	d.insulation = clampf(_num(source, over, "heat_insulation", "insulation", 0.35), 0.0, 0.99)

	var storage: int = maxi(0, int(_num(source, over, "storage_capacity", "storage", 0.0)))
	if storage <= 0:
		storage = DEFAULT_STORAGE
	d.output_slots = maxi(1, int(round(float(storage) * OUTPUT_SHARE)))
	d.input_slots = maxi(1, storage - d.output_slots)
	d.input_slots = maxi(1, int(_num(source, over, "", "input_slots", float(d.input_slots))))
	d.output_slots = maxi(1, int(_num(source, over, "", "output_slots", float(d.output_slots))))

	# A machine that must stand on its deposit ([P11] enforces needs_ore at
	# placement) works the tile under itself. Everything else fans out.
	var needs_ore: String = _str(source, over, "needs_ore", "needs_ore", "")
	var default_reach: int = 0 if needs_ore != "" else DEFAULT_REACH
	d.reach = maxi(0, int(_num(source, over, "", "reach", float(default_reach))))

	# Waste-heat capture is opt-in and derived from the burner fields the def
	# already carries: a machine that burns the pseudo-item "waste_heat" is a
	# recuperator, and how fast it burns it is how fast it can collect it.
	var fuel: Array[StringName] = _names(source, "fuel_items")
	if fuel.has(&"waste_heat"):
		d.waste_capture = maxf(0.0, _num(source, over, "fuel_burn_rate", "waste_capture", 0.0))
	else:
		d.waste_capture = maxf(0.0, _num(source, over, "", "waste_capture", 0.0))
	if d.waste_capture > 0.0:
		d.capture_radius = maxf(1.0, _num(source, over, "", "capture_radius", DEFAULT_CAPTURE_RADIUS))
	return d


# --- reflective reads -----------------------------------------------------

static func _num(source: Resource, over: Dictionary, prop: String, key: String, fallback: float) -> float:
	if key != "" and over.has(key):
		var v: Variant = over[key]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return float(v)
	if source != null and prop != "" and prop in source:
		var raw: Variant = source.get(prop)
		if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT:
			return float(raw)
	return fallback


static func _str(source: Resource, over: Dictionary, prop: String, key: String, fallback: String) -> String:
	if key != "" and over.has(key):
		return String(over[key])
	if source != null and prop != "" and prop in source:
		var raw: Variant = source.get(prop)
		if typeof(raw) == TYPE_STRING or typeof(raw) == TYPE_STRING_NAME:
			return String(raw)
	return fallback


static func _names(source: Resource, prop: String) -> Array[StringName]:
	var out: Array[StringName] = []
	if source == null or not (prop in source):
		return out
	var raw: Variant = source.get(prop)
	if typeof(raw) != TYPE_ARRAY:
		return out
	for v: Variant in (raw as Array):
		out.append(StringName(String(v)))
	return out


static func _names_over(source: Resource, over: Dictionary, prop: String, key: String) -> Array[StringName]:
	if over.has(key) and typeof(over[key]) == TYPE_ARRAY:
		var out: Array[StringName] = []
		for v: Variant in (over[key] as Array):
			out.append(StringName(String(v)))
		return out
	return _names(source, prop)


static func _size(source: Resource) -> Vector2i:
	if source != null and "size" in source:
		var raw: Variant = source.get("size")
		if typeof(raw) == TYPE_VECTOR2I:
			return raw
	return Vector2i.ONE

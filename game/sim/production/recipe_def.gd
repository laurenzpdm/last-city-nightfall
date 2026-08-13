class_name RecipeDef
extends Resource
## One craftable transformation. **This is the schema [P10] research gates and
## [P18] browses.**
##
## Drop a .tres of this type into `game/content/recipes/` and Registry finds it —
## there is no list to edit. Look one up with
## `Registry.get_item("recipes", &"steel_plate") as RecipeDef`.
##
## A recipe is deliberately dumb data: it states what goes in, what comes out,
## how long it takes, which machines will run it, how much heat it burns, and
## what it needs to be warm enough to run at all. Everything else — who is
## starved, who is choked, how many per minute — is computed by
## [ProductionSystem] against the live world.
##
## Three contracts other parts read:
##   * `unlock_id` — [P10] research gates a recipe by returning false for it.
##   * `tier` / `depth` / `inputs` / `outputs` — [P18] builds the browsable tree
##     from these alone; `ProdRecipeBook.depth_of()` gives the computed chain
##     depth so the tree can be laid out without walking the graph itself.
##   * `waste_heat` — [P04]'s recovery loop. A recipe that names it emits
##     capturable heat, which a recuperator standing near the machine turns back
##     into grid heat. That is what makes a tight industrial block pay off.

# ---------------------------------------------------------------- identity ---

## Stable id, unique across game/content/recipes/, matching the filename.
## Conventionally the id of the primary output.
@export var id: StringName = &""
## Player-facing name. Short enough for a recipe-browser row.
@export var display_name: String = ""
## One or two sentences: flavour plus the mechanical hint.
@export var description: String = ""
## Browser grouping: smelting, parts, components, munitions, salvage, food.
@export var category: StringName = &"parts"
## Authored progression tier 1..5. Sorts the browser and paces the tutorial.
## Distinct from the COMPUTED chain depth, which comes from the graph.
@export var tier: int = 1
## Tie-breaker inside a category, ascending.
@export var sort_order: int = 0

# ------------------------------------------------------------ the transform --

## Items consumed per craft, item id -> amount. Empty = something from nothing,
## which validate() refuses unless the recipe is tagged as extraction.
@export var inputs: Dictionary[StringName, int] = {}
## Primary items produced per craft, item id -> amount.
@export var outputs: Dictionary[StringName, int] = {}
## Secondary items produced per craft. Mechanically identical to `outputs`; kept
## apart so the browser can grey them and so a balance pass can tell a product
## from a problem. Slag is the reason this field exists.
@export var byproducts: Dictionary[StringName, int] = {}
## Work in ticks at craft speed 1.0. 20 ticks = one second.
@export var time_ticks: int = 100

# ------------------------------------------------------------- who runs it ---

## A machine may run this recipe if it carries one of these tags. Empty means
## "only the machines named in `machines`".
@export var machine_tags: Array[StringName] = []
## Explicit building ids that may run it. Empty means "any machine with a
## matching tag". Both empty is a content error.
@export var machines: Array[StringName] = []

# ------------------------------------------------------------ heat & warmth --

## Heat units burned over ONE craft. Converted to a required rate
## (`heat_cost / duration_seconds`) and compared against what the machine is
## actually being delivered — a recipe whose rate exceeds what the grid gives it
## runs proportionally slower. This is the coupling that makes the factory part
## of the heat game rather than next to it.
@export var heat_cost: float = 0.0
## Heat units thrown off as recoverable waste per craft. A recuperator within
## its reach converts this back into grid heat; uncaptured waste decays away.
@export var waste_heat: float = 0.0
## Degrees Celsius (ambient + radiant warmth + the machine's own shelter) below
## which this recipe cannot run at all. Between here and `min_temperature_c +
## ProductionSystem.COLD_BAND_C` it runs proportionally slower.
@export var min_temperature_c: float = -30.0

# ------------------------------------------------------------- progression ---

## Research id that unlocks it. Empty = available from the first minute.
@export var unlock_id: StringName = &""

# -------------------------------------------------------------- view hints ---

## Icon for the recipe browser. Empty falls back to the primary output's glyph.
@export var icon_path: String = ""
## Accent colour for the browser row and the machine's overlay badge.
@export var tint: Color = Color(0.72, 0.76, 0.84)


## Seconds of work at craft speed 1.0.
func duration_seconds() -> float:
	return float(maxi(1, time_ticks)) / 20.0


## Everything this recipe emits, primary and secondary, as one table.
func all_outputs() -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	for k: StringName in _sorted(outputs):
		out[k] = outputs[k]
	for k2: StringName in _sorted(byproducts):
		out[k2] = out.get(k2, 0) + byproducts[k2]
	return out


## Units of `item` produced per minute by one machine at speed 1.0. This is the
## number a player writes on a napkin, so it is the number the tooltip shows.
func output_per_minute(item: StringName) -> float:
	var n: int = int(outputs.get(item, 0)) + int(byproducts.get(item, 0))
	if n <= 0:
		return 0.0
	return float(n) * 60.0 / duration_seconds()


## Units of `item` consumed per minute by one machine at speed 1.0.
func input_per_minute(item: StringName) -> float:
	var n: int = int(inputs.get(item, 0))
	if n <= 0:
		return 0.0
	return float(n) * 60.0 / duration_seconds()


## Heat units per second this recipe needs while running.
func heat_rate() -> float:
	return heat_cost / duration_seconds()


## Recoverable waste heat units per second while running.
func waste_rate() -> float:
	return waste_heat / duration_seconds()


## True when a building of this kind carrying these tags is allowed to run it.
func runs_on(kind: StringName, tags: Array[StringName]) -> bool:
	if machines.has(kind):
		return true
	if machines.is_empty() and machine_tags.is_empty():
		return false
	for t: StringName in machine_tags:
		if tags.has(t):
			return true
	return false


## Item ids sorted — every iteration that reaches state has to be ordered.
func sorted_inputs() -> Array[StringName]:
	return _sorted(inputs)


func sorted_outputs() -> Array[StringName]:
	return _sorted(outputs)


func sorted_byproducts() -> Array[StringName]:
	return _sorted(byproducts)


## Content sanity check. Returns human-readable problems; empty means clean.
## [ProdRecipeBook] runs it over every recipe at world creation, so a bad .tres
## shows up in the log instead of as a mystery at minute forty.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if display_name == "":
		problems.append("missing display_name")
	if description == "":
		problems.append("missing description")
	if time_ticks <= 0:
		problems.append("time_ticks must be > 0")
	if outputs.is_empty():
		problems.append("a recipe with no outputs produces nothing")
	if machines.is_empty() and machine_tags.is_empty():
		problems.append("no machine can run it: set machines or machine_tags")
	if heat_cost < 0.0:
		problems.append("heat_cost must not be negative")
	if waste_heat < 0.0:
		problems.append("waste_heat must not be negative")
	if tier < 1 or tier > 6:
		problems.append("tier must be within 1..6, got %d" % tier)
	for k: StringName in _sorted(inputs):
		if inputs[k] <= 0:
			problems.append("non-positive input '%s'" % String(k))
		if outputs.has(k):
			problems.append("'%s' is both an input and an output" % String(k))
	for k2: StringName in _sorted(outputs):
		if outputs[k2] <= 0:
			problems.append("non-positive output '%s'" % String(k2))
	for k3: StringName in _sorted(byproducts):
		if byproducts[k3] <= 0:
			problems.append("non-positive byproduct '%s'" % String(k3))
		if inputs.has(k3):
			problems.append("'%s' is both an input and a byproduct" % String(k3))
	return problems


## JSON-safe description of the recipe, for state dumps and for [P18]'s tree.
func to_json() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"category": String(category),
		"tier": tier,
		"time_ticks": time_ticks,
		"inputs": _items_json(inputs),
		"outputs": _items_json(outputs),
		"byproducts": _items_json(byproducts),
		"heat_cost": snappedf(heat_cost, 0.001),
		"waste_heat": snappedf(waste_heat, 0.001),
		"min_temperature_c": snappedf(min_temperature_c, 0.01),
		"unlock": String(unlock_id),
		"machines": _names_json(machines),
		"machine_tags": _names_json(machine_tags),
	}


func _sorted(d: Dictionary[StringName, int]) -> Array[StringName]:
	var keys: Array = d.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


func _items_json(d: Dictionary[StringName, int]) -> Dictionary:
	var out: Dictionary = {}
	for k: StringName in _sorted(d):
		out[String(k)] = d[k]
	return out


func _names_json(a: Array[StringName]) -> Array:
	var copy: Array = []
	for n: StringName in a:
		copy.append(String(n))
	copy.sort()
	return copy

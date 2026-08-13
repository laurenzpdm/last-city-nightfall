class_name BuildingDef
extends Resource
## The definition of one buildable thing. **This is the schema every other part reads.**
##
## Drop a .tres of this type into `game/content/buildings/` and Registry finds it —
## there is no list to edit. Look it up with
## `Registry.get_item("buildings", &"coal_generator") as BuildingDef`.
##
## Fields are grouped by the part that consumes them. Adding a field is safe;
## renaming one is not, because 20 other parts read this. Every field has a
## sane default so a def only states what it actually cares about.

# ---------------------------------------------------------------- identity ---

## Stable id. Must be unique across game/content/buildings/ and match the filename.
@export var id: StringName = &""
## Player-facing name. Short enough for a build-menu row.
@export var display_name: String = ""
## One or two sentences of flavour + mechanical hint, shown in the tooltip.
@export var description: String = ""
## Build-menu grouping: power, heat, extraction, production, logistics, housing,
## storage, defense, infrastructure.
@export var category: StringName = &"infrastructure"
## Progression tier 1..4. Sorts the build menu and paces the tutorial.
@export var tier: int = 1
## Tie-breaker inside a category, ascending. Lower shows first.
@export var sort_order: int = 0
## Free-form markers other systems query: heat_source, conduit, radiator, turret,
## wall, housing, storage, crafter, extractor, comfort, unique. Cheap to extend.
@export var tags: Array[StringName] = []

# ------------------------------------------------------------- footprint ----

## Footprint in tiles before rotation. 32px per tile.
@export var size: Vector2i = Vector2i.ONE
## Optional non-rectangular footprint: relative cells inside [0, size).
## Empty means "the full size rectangle". Rotation is applied to these cells too.
@export var footprint_cells: Array[Vector2i] = []
## False for radially symmetric things; the rotate command refuses them.
@export var rotatable: bool = false
## Distinct orientations: 1 (none), 2 (pipes, walls), 4 (belts, turrets).
## Rotation input is folded modulo this, so a pipe never has a redundant 3rd state.
@export var rotation_symmetry: int = 4
## Blocks enemy and citizen pathing. Walls set this; pipes do not.
@export var blocks_movement: bool = true
## Units may walk over it (roads, catwalks, pipes). [P01] reads it for the path surface.
@export var walkable: bool = false
## How the build menu drags this out. 0 single, 1 line, 2 area.
@export_enum("Single", "Line", "Area") var drag_mode: int = 0

# ------------------------------------------------------- cost & construction -

## Materials consumed to build one, item id -> amount.
@export var cost: Dictionary[StringName, int] = {}
## Build work in ticks at one unit of build power. 20 ticks = 1 second.
@export var build_time_ticks: int = 100
## Ticks to take it apart again once demolition starts.
@export var demolish_time_ticks: int = 30
## Fraction of cost returned when demolished intact. Cancelling an unfinished
## site always refunds everything delivered, regardless of this.
@export var refund_ratio: float = 0.5
## Ongoing draw per in-game minute, item id -> amount. [P04] applies it.
@export var upkeep: Dictionary[StringName, int] = {}
## Higher jumps the construction queue. Defense and heat outrank decoration.
@export var build_priority: int = 0

# ---------------------------------------------------------------- staffing ---

## Citizens needed for full output. Below this the building runs at a fraction.
@export var workers_required: int = 0
## Hard cap of assigned citizens. Defaults to workers_required when left at 0.
@export var staff_capacity: int = 0
## Citizens this building houses. [P05] population uses it.
@export var residents: int = 0

# ------------------------------------------------------------ heat & power ---

## Heat produced per second at full output. The one resource that matters.
@export var heat_produced: float = 0.0
## Heat drawn per second to stay operational.
@export var heat_consumed: float = 0.0
## Internal heat storage in units. Buffers a building through a brown-out.
@export var heat_buffer: float = 0.0
## Radius in tiles of livable warmth projected into the world. 0 = none.
@export var heat_radius: float = 0.0
## 0..1 — how well the structure holds heat against the outside temperature.
@export var heat_insulation: float = 0.35
## Carries heat between neighbours. [P02] builds its network graph from these.
@export var is_heat_conduit: bool = false
## Heat units per second this conduit can pass. Ignored unless is_heat_conduit.
@export var conduit_throughput: float = 0.0
## Item ids this building will burn as fuel, best first.
@export var fuel_items: Array[StringName] = []
## Fuel items consumed per second while burning.
@export var fuel_burn_rate: float = 0.0

# ------------------------------------------------------ durability & combat --

## Structural hit points at completion. A site under construction scales up to it.
@export var hp: float = 200.0
## Flat damage reduction per hit. Walls trade cost for this.
@export var armor: float = 0.0
## Weapon this mount fires, resolved by [P07] combat. Empty = not a turret.
@export var weapon_id: StringName = &""
## Tiles of vision revealed. [P08] and the fog layer read it.
@export var vision_radius: float = 0.0

# --------------------------------------------------- production & storage ----

## Recipes this machine may run, resolved by [P04] against game/content/recipes/.
@export var recipes: Array[StringName] = []
## Multiplier on recipe speed.
@export var craft_speed: float = 1.0
## Ore id this building extracts in place. Empty = not an extractor.
@export var extracts: StringName = &""
## Units extracted per second at full staffing.
@export var extract_rate: float = 0.0
## Item slots of internal storage. Also the input/output buffer of a machine.
@export var storage_capacity: int = 0
## Items this store accepts. Empty = anything.
@export var storage_filter: Array[StringName] = []

# --------------------------------------------------------- placement rules ---

## Requires this deposit under the footprint. "*" means any deposit will do.
## Names come from the grid's deposit table: iron, copper, coal, sulfur, scrap, vent.
@export var needs_ore: StringName = &""
## How many footprint cells must carry that deposit. One is the Factorio rule —
## the machine covers the seam, it does not have to sit entirely on it.
@export var ore_coverage: int = 1
## Refuses uneven ground. [P01] answers what "flat" means for the terrain.
@export var needs_flat: bool = false
## Requires an orthogonally adjacent building offering at least one of these tags.
## Ghosts count, so a player can plan a whole line before any of it exists.
@export var must_connect: Array[StringName] = []
## Tags this building offers to its neighbours' must_connect checks.
@export var connects_as: Array[StringName] = []
## Terrain ids allowed under the footprint. Empty = anything buildable.
@export var allowed_terrain: Array[StringName] = []
## Terrain ids explicitly refused, even when otherwise buildable.
@export var forbidden_terrain: Array[StringName] = []
## Minimum Chebyshev gap in tiles to another building of the same kind. 0 = none.
@export var min_spacing: int = 0
## Hard cap of this kind in the city. 0 = unlimited.
@export var max_count: int = 0
## Research id that unlocks it. Empty = available from the first minute.
@export var unlock_id: StringName = &""

# -------------------------------------------------------------- view hints ---

## Texture for the build menu. Empty falls back to a generated glyph.
@export var icon_path: String = ""
## World sprite. Empty falls back to the footprint block [P13] draws.
@export var sprite_path: String = ""
## Accent colour for the ghost, the minimap and the overlays.
@export var tint: Color = Color(0.62, 0.68, 0.78)
## Light energy emitted while operational. Warm buildings glow in the dark.
@export var light_energy: float = 0.0
## Colour of that light.
@export var light_color: Color = Color(1.0, 0.62, 0.31)


## Footprint dimensions after `rot` quarter-turns clockwise.
func effective_size(rot: int) -> Vector2i:
	return BuildTypes.rotated_size(size, rot)


## Every absolute cell this building occupies when its origin is `origin`.
## Origin is the minimum corner of the rotated footprint, never the pivot.
func cells_at(origin: Vector2i, rot: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if footprint_cells.is_empty():
		var es: Vector2i = effective_size(rot)
		for y: int in es.y:
			for x: int in es.x:
				out.append(origin + Vector2i(x, y))
		return out
	for c: Vector2i in footprint_cells:
		out.append(origin + BuildTypes.rotate_cell(c, rot, size))
	return out


## Bounding rectangle of the placed footprint.
func rect_at(origin: Vector2i, rot: int) -> Rect2i:
	return Rect2i(origin, effective_size(rot))


## Rotation folded into the orientations this building actually has.
func normalize_rot(rot: int) -> int:
	var sym: int = maxi(1, rotation_symmetry)
	if not rotatable:
		return 0
	return posmod(rot, mini(4, sym)) if sym < 4 else posmod(rot, 4)


## True when the def carries this marker.
func has_tag(t: StringName) -> bool:
	return tags.has(t)


## Materials handed back for demolishing a finished one of these.
func refund_items() -> Dictionary[StringName, int]:
	return BuildTypes.scale_items(BuildTypes.to_items(cost), clampf(refund_ratio, 0.0, 1.0))


## Citizens this building can hold at most.
func effective_staff_capacity() -> int:
	return staff_capacity if staff_capacity > 0 else workers_required


## Content sanity check. Returns human-readable problems; empty means clean.
## The build system runs it over every def at world creation, so a bad .tres
## shows up in the log instead of as a mystery at minute forty.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if display_name == "":
		problems.append("missing display_name")
	if size.x <= 0 or size.y <= 0:
		problems.append("size must be positive, got %s" % str(size))
	if build_time_ticks <= 0:
		problems.append("build_time_ticks must be > 0")
	if hp <= 0.0:
		problems.append("hp must be > 0")
	if rotation_symmetry != 1 and rotation_symmetry != 2 and rotation_symmetry != 4:
		problems.append("rotation_symmetry must be 1, 2 or 4")
	if refund_ratio < 0.0 or refund_ratio > 1.0:
		problems.append("refund_ratio must be within 0..1")
	if is_heat_conduit and conduit_throughput <= 0.0:
		problems.append("conduit with no throughput")
	if String(extracts) != "" and extract_rate <= 0.0:
		problems.append("extractor with no extract_rate")
	if String(weapon_id) != "" and not has_tag(&"turret"):
		problems.append("has a weapon but is not tagged 'turret'")
	for c: Vector2i in footprint_cells:
		if c.x < 0 or c.y < 0 or c.x >= size.x or c.y >= size.y:
			problems.append("footprint cell %s outside size %s" % [str(c), str(size)])
	var cost_keys: Array = cost.keys()
	for k: Variant in cost_keys:
		if int(cost[k]) <= 0:
			problems.append("non-positive cost entry '%s'" % String(k))
	return problems

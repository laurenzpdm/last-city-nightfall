class_name LogiDef
extends Resource
## [P03] The definition of one piece of transport: a belt, an underground pair,
## a splitter, an inserter arm or a chest.
##
## Drop a .tres into `game/content/logistics/` and it exists. Nothing in
## game/sim/logistics/ knows the name of a single belt — tiers, spans, swing
## rates and capacities are all read from here, which is what lets a balance
## agent retune the whole transport ladder without touching code.
##
## These are placed through the logistics command surface
## (`{"system": &"logistics", "op": "place", "kind": &"belt_mk1", ...}`), exactly
## the way [P02] places pipes through its own. If a building of the same id ever
## appears in `game/content/buildings/`, the build system's copy takes over
## placement and this part adopts it automatically — see
## LogisticsSystem._sync_from_build.

# ---------------------------------------------------------------- identity ---

## Stable id, unique inside game/content/logistics/ and matching the filename.
@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
## belt, underground, splitter, inserter, chest.
@export var role: StringName = &"belt"
## Progression tier 1..3. Sorts the build menu and paces research.
@export var tier: int = 1
@export var sort_order: int = 0
## Materials one costs. Charged against the city stock unless placed free.
@export var cost: Dictionary[StringName, int] = {}
@export var tint: Color = Color(0.78, 0.72, 0.5)
## Research id that unlocks it. Empty means available from the first minute.
@export var unlock_id: StringName = &""

# ------------------------------------------------------------- transport -----

## Footprint before rotation. Splitters are 2x1; everything else is 1x1.
@export var size: Vector2i = Vector2i.ONE
## Belt speed in tiles per second. One lane carries speed * 4 items/s.
@export var speed: float = 1.875
## Underground only: greatest gap in tiles between entrance and exit.
@export var max_span: int = 5

# -------------------------------------------------------------- inserter -----

## Full swings per second. Items per second = swings_per_second * stack_size.
@export var swings_per_second: float = 0.83
## Items carried per swing.
@export var stack_size: int = 1
## Tiles between the inserter and what it reaches. 1 is the normal arm.
@export var reach: int = 1

# ----------------------------------------------------------------- chest -----

## Item units held. Not slots: one number the player can read off a tooltip.
@export var capacity: int = 200
## Items this container accepts. Empty means anything.
@export var filter: Array[StringName] = []
## True when the container asks the city to keep it stocked (a requester post).
@export var requests: bool = false


func role_id() -> int:
	match role:
		&"belt":
			return LogiTypes.Role.BELT
		&"underground", &"underground_belt", &"tunnel":
			return LogiTypes.Role.UNDERGROUND
		&"splitter":
			return LogiTypes.Role.SPLITTER
		&"inserter", &"arm":
			return LogiTypes.Role.INSERTER
		&"chest", &"container", &"store":
			return LogiTypes.Role.CHEST
	return LogiTypes.Role.NONE


func is_transport() -> bool:
	var r: int = role_id()
	return r == LogiTypes.Role.BELT or r == LogiTypes.Role.UNDERGROUND


func is_rotatable() -> bool:
	return role_id() != LogiTypes.Role.CHEST


## Items per second one lane of this belt carries when compressed.
func lane_rate() -> float:
	return LogiTypes.lane_rate(speed)


## Items per second the whole belt carries when both lanes are compressed.
func belt_rate() -> float:
	return lane_rate() * float(LogiTypes.LANES)


## Items per second this arm moves when it never has to wait.
func inserter_rate() -> float:
	return swings_per_second * float(maxi(1, stack_size))


## Footprint after `rot` quarter-turns clockwise.
func effective_size(rot: int) -> Vector2i:
	if posmod(rot, 2) == 1:
		return Vector2i(size.y, size.x)
	return size


## Every cell this thing covers with its origin at `origin`.
## A splitter is two tiles wide across its direction of travel.
func cells_at(origin: Vector2i, rot: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var es: Vector2i = effective_size(rot)
	for y: int in es.y:
		for x: int in es.x:
			out.append(origin + Vector2i(x, y))
	return out


## Content sanity check. Empty means clean.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if display_name == "":
		problems.append("missing display_name")
	if role_id() == LogiTypes.Role.NONE:
		problems.append("unknown role '%s'" % String(role))
	if is_transport() and speed <= 0.0:
		problems.append("a belt with no speed carries nothing")
	if role_id() == LogiTypes.Role.UNDERGROUND and max_span < 1:
		problems.append("max_span must be at least 1")
	if role_id() == LogiTypes.Role.INSERTER:
		if swings_per_second <= 0.0:
			problems.append("an arm with no swing rate never moves")
		if stack_size <= 0:
			problems.append("stack_size must be > 0")
		if reach < 1:
			problems.append("reach must be at least 1")
	if role_id() == LogiTypes.Role.CHEST and capacity <= 0:
		problems.append("a container with no capacity holds nothing")
	if size.x <= 0 or size.y <= 0:
		problems.append("size must be positive, got %s" % str(size))
	for k: Variant in cost.keys():
		if int(cost[k]) <= 0:
			problems.append("non-positive cost entry '%s'" % String(k))
	return problems

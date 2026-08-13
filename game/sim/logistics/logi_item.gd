class_name LogiItem
extends Resource
## [P03] One kind of thing that can sit on a belt, in a chest or in a furnace.
##
## Drop a .tres of this type into `game/content/logistics/` and Registry finds
## it — there is no list to edit. Look one up with
## `Registry.get_item("logistics", &"coal") as LogiItem`, or through the
## logistics system's own `item(&"coal")`, which is cached.
##
## Every other part speaks in item ids (`&"coal"`, `&"iron_plate"`), so a part
## that never touches this class still works. The definition exists so that
## stack size, fuel value and the player-facing name live in data instead of in
## somebody's constant table.

## Stable id. Unique inside game/content/logistics/ and matching the filename.
@export var id: StringName = &""
## Player-facing name.
@export var display_name: String = ""
## One line for the tooltip.
@export var description: String = ""
## Grouping for the item browser: raw, plate, component, fuel, ammo, build.
@export var category: StringName = &"raw"
## How many fit in one inventory slot. Chests measure their capacity in units,
## but an inserter's stack bonus and the UI both read this.
@export var stack_size: int = 50
## Heat units one unit of this yields when burned. 0 means it is not a fuel.
@export var fuel_value: float = 0.0
## Sorting inside a category, ascending.
@export var sort_order: int = 0
## Colour the belt renderer and the logistics lens draw it with.
@export var tint: Color = Color(0.72, 0.74, 0.78)
## Optional icon for the UI. Empty falls back to a coloured pip.
@export var icon_path: String = ""


func is_fuel() -> bool:
	return fuel_value > 0.0


## Content sanity check. Empty means clean; the system logs anything else.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(id) == "":
		problems.append("missing id")
	if display_name == "":
		problems.append("missing display_name")
	if stack_size <= 0:
		problems.append("stack_size must be > 0")
	if fuel_value < 0.0:
		problems.append("fuel_value cannot be negative")
	return problems

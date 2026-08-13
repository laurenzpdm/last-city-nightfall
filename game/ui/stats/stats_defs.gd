class_name LcnStatsDefs
extends RefCounted
## What the recorder records, and how each number should be read. [P20]
##
## One table, three consumers: the recorder declares its series from it, the
## graphs label and colour their curves from it, and the night report words its
## sentences from it. A number that is not in this table does not exist as far
## as the statistics screen is concerned, which is the point — the alternative
## is four places that disagree about whether `heat_deficit` is a level or a
## running total.
##
## KIND is the load-bearing column:
##   LEVEL    a reading, plotted as-is        (heat supply, hope, temperature)
##   COUNTER  a lifetime total, plotted as a  (kills, items produced, deaths)
##            per-minute rate by differencing
##   FLAG     0 or 1, drawn as a shaded band  (night)
##
## Storing counters as totals rather than as rates is deliberate. A total
## survives the whole-run track halving its resolution — the difference across
## a wider gap is still the honest amount that happened — whereas a stored rate
## would be a sample of a moment and would lie about everything between two
## samples.

const P := preload("res://game/view/render/palette.gd")

enum Kind { LEVEL, COUNTER, FLAG }

## Series groups, in the order the screens present them.
const G_HEAT: StringName = &"heat"
const G_SOCIETY: StringName = &"society"
const G_COMBAT: StringName = &"combat"
const G_CITY: StringName = &"city"
const G_WORLD: StringName = &"world"
const G_ITEMS: StringName = &"items"

## Prefix for the per-item series the recorder declares from the recipe book.
const P_PRODUCED: String = "p."
const P_CONSUMED: String = "c."
const P_STOCK: String = "s."

## Unit suffixes used in every read-out, so one place decides that heat is
## "/s" and production is "/min".
const U_HEAT: String = " heat/s"
const U_PER_MIN: String = "/min"
const U_NONE: String = ""


## key -> {kind, label, group, unit, colour, hint}
## Sorted iteration comes from [method ordered_keys]; a Dictionary literal is
## only ever read by key here.
static func table() -> Dictionary:
	return {
		# ---------------------------------------------------------- heat ----
		&"heat_supply": _row(Kind.LEVEL, "Supply", G_HEAT, U_HEAT, P.WARM_EDGE,
			"Heat every burner, tap and hearth is putting into the grid."),
		&"heat_demand": _row(Kind.LEVEL, "Demand", G_HEAT, U_HEAT, P.ICE_BLUE,
			"Heat every radiator, machine and turret is asking for."),
		&"heat_delivered": _row(Kind.LEVEL, "Delivered", G_HEAT, U_HEAT, P.WARM_CORE,
			"What actually arrived after pipe losses and priority."),
		&"heat_deficit": _row(Kind.LEVEL, "Deficit", G_HEAT, U_HEAT, P.DANGER,
			"Demand the grid could not meet. Above zero, something is going cold."),
		&"heat_buffer": _row(Kind.LEVEL, "Buffer", G_HEAT, U_NONE, P.CAUTION,
			"Heat banked in accumulators. This is how long a bad night can last."),
		&"heat_loss": _row(Kind.LEVEL, "Pipe loss", G_HEAT, U_HEAT, P.RUST,
			"Heat spent on the pipes themselves. Insulation and shorter runs cut it."),
		&"heat_frozen": _row(Kind.LEVEL, "Frozen", G_HEAT, U_NONE, P.DANGER,
			"Buildings that have gone below their working temperature."),
		&"heat_avg_warmth": _row(Kind.LEVEL, "Warmth", G_HEAT, " C", P.WARM_MID,
			"Average degrees of radiant warmth over the inhabited tiles."),
		&"heat_brownouts": _row(Kind.COUNTER, "Brownouts", G_HEAT, U_PER_MIN, P.EMBER,
			"Moments the grid dropped below what it had promised."),

		# ------------------------------------------------------- society ----
		&"pop": _row(Kind.LEVEL, "Population", G_SOCIETY, U_NONE, P.SNOW,
			"People alive in the city right now."),
		&"deaths": _row(Kind.COUNTER, "Deaths", G_SOCIETY, U_PER_MIN, P.DANGER,
			"People the city has lost. Every one of them is on the graph forever."),
		&"hope": _row(Kind.LEVEL, "Hope", G_SOCIETY, U_NONE, P.GOOD,
			"Belief that this place will still be here next week."),
		&"discontent": _row(Kind.LEVEL, "Discontent", G_SOCIETY, U_NONE, P.EMBER,
			"Anger at how you are running it. At 1.0 they stop obeying."),
		&"sick": _row(Kind.LEVEL, "Sick", G_SOCIETY, U_NONE, P.CAUTION,
			"People too ill to work."),
		&"homeless": _row(Kind.LEVEL, "Homeless", G_SOCIETY, U_NONE, P.RUST,
			"People with nowhere warm to sleep."),
		&"laws": _row(Kind.LEVEL, "Laws signed", G_SOCIETY, U_NONE, P.SNOW_MID,
			"Pages of the book you have put your name to."),
		&"avg_warmth": _row(Kind.LEVEL, "Body warmth", G_SOCIETY, U_NONE, P.WARM_MID,
			"How warm the average citizen actually is, 0 to 100."),
		&"avg_morale": _row(Kind.LEVEL, "Morale", G_SOCIETY, U_NONE, P.ICE_BLUE,
			"How the average citizen feels, 0 to 100."),

		# -------------------------------------------------------- combat ----
		&"kills": _row(Kind.COUNTER, "Kills", G_COMBAT, U_PER_MIN, P.WARM_EDGE,
			"Things out of the dark that did not get back up."),
		&"damage_dealt": _row(Kind.COUNTER, "Damage dealt", G_COMBAT, U_PER_MIN, P.CAUTION,
			"Damage your turrets have put into the swarm."),
		&"damage_taken": _row(Kind.COUNTER, "Damage taken", G_COMBAT, U_PER_MIN, P.DANGER,
			"Damage your buildings have absorbed."),
		&"enemies_alive": _row(Kind.LEVEL, "Enemies", G_COMBAT, U_NONE, P.EMBER,
			"How many are on the map at this moment."),
		&"structures_lost": _row(Kind.COUNTER, "Structures lost", G_COMBAT, U_PER_MIN, P.DANGER,
			"Buildings taken apart by the night."),
		&"defence_heat": _row(Kind.COUNTER, "Heat spent on defence", G_COMBAT, U_PER_MIN, P.WARM_EDGE,
			"Heat the turrets burned. It comes out of the same grid that keeps people alive."),
		&"threat": _row(Kind.LEVEL, "Threat", G_COMBAT, U_NONE, P.EMBER,
			"How hard the wave director thinks it can push you."),

		# ---------------------------------------------------------- city ----
		&"buildings": _row(Kind.LEVEL, "Buildings", G_CITY, U_NONE, P.STEEL_LIGHT,
			"Everything standing, finished or not."),
		&"machines_active": _row(Kind.LEVEL, "Machines running", G_CITY, U_NONE, P.GOOD,
			"Machines that are actually making something this second."),
		&"machines_stalled": _row(Kind.LEVEL, "Machines stalled", G_CITY, U_NONE, P.DANGER,
			"Machines that have a reason they are not moving."),
		&"crafts": _row(Kind.COUNTER, "Crafts", G_CITY, U_PER_MIN, P.WARM_CORE,
			"Completed transformations, across the whole factory."),
		&"items_moved": _row(Kind.COUNTER, "Items moved", G_CITY, U_PER_MIN, P.ICE_BLUE,
			"Items belts and arms have carried."),
		&"research": _row(Kind.LEVEL, "Research", G_CITY, U_NONE, P.ICE_BLUE,
			"Progress through the node you are working on, 0 to 1."),
		&"researched": _row(Kind.LEVEL, "Technologies", G_CITY, U_NONE, P.SNOW_MID,
			"Research nodes finished. Every one of them changed something already standing."),

		# --------------------------------------------------------- world ----
		&"temperature": _row(Kind.LEVEL, "Outside", G_WORLD, " C", P.ICE_BLUE,
			"Ambient temperature on the plain, before any warmth you make."),
		&"light": _row(Kind.LEVEL, "Daylight", G_WORLD, U_NONE, P.WARM_CORE,
			"How much sun there is, 0 to 1."),
		&"night": _row(Kind.FLAG, "Night", G_WORLD, U_NONE, P.COLD_HIGH,
			"1 while the sun is down. Every shaded band on a chart is one of these."),
		&"day": _row(Kind.LEVEL, "Day", G_WORLD, U_NONE, P.SNOW_SHADOW,
			"Which day of the campaign this is."),
		&"storm": _row(Kind.LEVEL, "Storm", G_WORLD, U_NONE, P.SNOW_MID,
			"Storm intensity, 0 to 1."),
	}


## Every core key, sorted. Per-item keys are not in here — the recorder adds
## those from the live recipe book.
static func ordered_keys() -> Array[StringName]:
	var out: Array[StringName] = []
	var keys: Array = table().keys()
	keys.sort()
	for k: StringName in keys:
		out.append(k)
	return out


static func keys_in_group(group: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	var t: Dictionary = table()
	for k: StringName in ordered_keys():
		if StringName(String((t[k] as Dictionary)["group"])) == group:
			out.append(k)
	return out


static func kind_of(key: StringName) -> int:
	var row: Dictionary = table().get(key, {})
	if row.is_empty():
		return _kind_of_item_key(key)
	return int(row["kind"])


static func label_of(key: StringName) -> String:
	var row: Dictionary = table().get(key, {})
	if not row.is_empty():
		return String(row["label"])
	return item_label(key)


static func colour_of(key: StringName) -> Color:
	var row: Dictionary = table().get(key, {})
	if not row.is_empty():
		return row["colour"]
	return item_colour(key)


static func unit_of(key: StringName) -> String:
	var row: Dictionary = table().get(key, {})
	return String(row["unit"]) if not row.is_empty() else U_PER_MIN


static func hint_of(key: StringName) -> String:
	var row: Dictionary = table().get(key, {})
	return String(row["hint"]) if not row.is_empty() else ""


# ------------------------------------------------------------- item keys ----

static func produced_key(item: StringName) -> StringName:
	return StringName(P_PRODUCED + String(item))


static func consumed_key(item: StringName) -> StringName:
	return StringName(P_CONSUMED + String(item))


static func stock_key(item: StringName) -> StringName:
	return StringName(P_STOCK + String(item))


## The item id inside a prefixed key, or the key itself if it carries no prefix.
static func item_of(key: StringName) -> StringName:
	var s: String = String(key)
	if s.length() > 2 and s[1] == ".":
		return StringName(s.substr(2))
	return key


## "iron_plate" -> "Iron Plate". The item ids are the only human-readable names
## the content ships, so the display name is derived rather than authored twice.
static func item_label(key: StringName) -> String:
	var raw: String = String(item_of(key)).replace("_", " ")
	var parts: PackedStringArray = raw.split(" ", false)
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		out.append(p.substr(0, 1).to_upper() + p.substr(1))
	return " ".join(out)


## A stable colour per item, hashed from the id so the same plate is the same
## green in every chart, in every run, forever — and never rolled, because a
## legend that reshuffles itself is worse than no legend.
static func item_colour(key: StringName) -> Color:
	var id: String = String(item_of(key))
	var h: int = 0
	for i: int in id.length():
		h = (h * 131 + id.unicode_at(i)) & 0x7FFFFFFF
	var hue: float = float(h % 997) / 997.0
	# A band of the wheel that stays legible on #05080f and never collides with
	# the ember/danger hues the alerts own.
	var c := Color.from_hsv(fmod(0.42 + hue * 0.72, 1.0), 0.52, 0.92)
	return c


static func _kind_of_item_key(key: StringName) -> int:
	var s: String = String(key)
	if s.begins_with(P_STOCK):
		return Kind.LEVEL
	return Kind.COUNTER


static func _row(kind: int, label: String, group: StringName, unit: String,
		colour: Color, hint: String) -> Dictionary:
	return {"kind": kind, "label": label, "group": group, "unit": unit,
		"colour": colour, "hint": hint}

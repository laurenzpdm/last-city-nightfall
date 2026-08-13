class_name LcnUiFormat
extends RefCounted
## [P18] Every number the build UI shows passes through here.
##
## Two reasons this is a file and not fifty inline `"%.1f" % x` calls:
##   * a player compares numbers across four panels, so 30 has to read as "30"
##     in all of them, not "30.0" in one and "30" in another;
##   * unit strings ("u/s", "/min", "tiles") are the vocabulary of the game and
##     they belong in one place where they can be translated later.
##
## Pure static functions. No state, no engine dependencies, trivially testable.

const SECONDS_PER_TICK: float = 0.05     ## SimClock.DT, mirrored so this file stays pure


## A quantity, with just enough decimals to be honest and no more.
## 0 -> "0", 0.35 -> "0.35", 4.5 -> "4.5", 30.0 -> "30", 1240 -> "1,240"
static func num(value: float) -> String:
	var a: float = absf(value)
	if a >= 1000.0:
		return group(int(round(value)))
	if a >= 100.0 or is_equal_approx(value, round(value)):
		return str(int(round(value)))
	if a >= 10.0:
		return String.num(value, 1).rstrip("0").rstrip(".")
	return String.num(value, 2).rstrip("0").rstrip(".")


## Thousands separators, because 14000 coal is unreadable and 14,000 is not.
static func group(value: int) -> String:
	var neg: bool = value < 0
	var digits: String = str(absi(value))
	var out: String = ""
	var count: int = 0
	for i: int in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if neg else out


static func signed(value: float) -> String:
	if value > 0.0:
		return "+" + num(value)
	return num(value)


## Heat and item flows are per second everywhere in this game.
static func rate(value: float, unit: String = "u/s") -> String:
	return "%s %s" % [num(value), unit]


## The same flow expressed per minute, which is how a player plans a shift.
static func per_minute(value_per_second: float, unit: String = "/min") -> String:
	return "%s%s" % [num(value_per_second * 60.0), unit]


static func percent(fraction01: float, decimals: int = 0) -> String:
	var v: float = fraction01 * 100.0
	if decimals <= 0:
		return "%d%%" % int(round(v))
	return "%s%%" % String.num(v, decimals)


## "45 s", "2:15", "1:04:30". The unit a player counts nightfall in.
static func duration(seconds: float) -> String:
	var s: int = int(round(maxf(0.0, seconds)))
	if s < 60:
		return "%d s" % s
	if s < 3600:
		return "%d:%02d" % [s / 60, s % 60]
	return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]


## Build times are authored in ticks; players think in seconds.
static func ticks_as_time(ticks: int) -> String:
	return duration(float(ticks) * SECONDS_PER_TICK)


## "iron_plate" -> "Iron Plate". Content ids are snake_case by convention and
## nothing in content carries a display name for ITEMS yet — when [P04] ships
## ItemDefs this is the single place that has to learn to ask.
static func item_name(id: StringName) -> String:
	return title_case(String(id).replace("_", " "))


static func title_case(text: String) -> String:
	var parts: PackedStringArray = text.split(" ", false)
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		if p.length() == 0:
			continue
		out.append(p.substr(0, 1).to_upper() + p.substr(1))
	return " ".join(out)


## Alphabetical order for a set of ids.
##
## THIS IS NOT PEDANTRY: Godot compares StringName by internal POINTER, not by
## text, so `dictionary.keys().sort()` on a StringName-keyed dictionary is not
## alphabetical and is not even stable between two processes. Every ordered walk
## over ids in this part goes through here, which is why two players reading the
## same tooltip see the same line.
static func sorted_names(keys: Array) -> Array[StringName]:
	var text: Array[String] = []
	for k: Variant in keys:
		text.append(String(k))
	text.sort()
	var out: Array[StringName] = []
	for s: String in text:
		out.append(StringName(s))
	return out


## "20 Iron Plate, 45 Scrap" — sorted, so the same cost always reads the same.
static func items(bill: Dictionary, separator: String = ", ") -> String:
	var parts: PackedStringArray = PackedStringArray()
	for k: StringName in sorted_names(bill.keys()):
		var amount: int = int(bill[k])
		if amount == 0:
			continue
		parts.append("%s %s" % [group(amount), item_name(StringName(String(k)))])
	if parts.is_empty():
		return "nothing"
	return separator.join(parts)


## Prose list: "a, b and c". Used in warnings, where commas alone read like code.
static func prose_list(parts: PackedStringArray, conjunction: String = "and") -> String:
	if parts.is_empty():
		return ""
	if parts.size() == 1:
		return parts[0]
	if parts.size() == 2:
		return "%s %s %s" % [parts[0], conjunction, parts[1]]
	var head: PackedStringArray = parts.slice(0, parts.size() - 1)
	return "%s %s %s" % [", ".join(head), conjunction, parts[parts.size() - 1]]


static func cell(c: Vector2i) -> String:
	return "%d, %d" % [c.x, c.y]


## "3 x 2  (6 tiles)" — the footprint line in every tooltip.
static func footprint(size: Vector2i) -> String:
	var area: int = maxi(0, size.x) * maxi(0, size.y)
	if size.x == 1 and size.y == 1:
		return "1 x 1 tile"
	return "%d x %d  (%d tiles)" % [size.x, size.y, area]


## Compass bearing from one cell to another: "14 tiles east-north-east".
static func bearing(from: Vector2i, to: Vector2i) -> String:
	var d: Vector2i = to - from
	var dist: int = int(round(Vector2(d).length()))
	if dist == 0:
		return "right here"
	var angle: float = atan2(float(d.y), float(d.x))
	var octant: int = int(round(angle / (PI / 4.0)))
	var names: Array[String] = ["east", "south-east", "south", "south-west",
		"west", "north-west", "north", "north-east"]
	return "%d tile%s %s" % [dist, "" if dist == 1 else "s", names[posmod(octant, 8)]]


## Category ids are content-authored; this is how they read in a header.
static func category_name(id: StringName) -> String:
	match id:
		&"power": return "Power"
		&"heat": return "Heat"
		&"extraction": return "Extraction"
		&"production": return "Production"
		&"logistics": return "Logistics"
		&"housing": return "Housing"
		&"storage": return "Storage"
		&"defense": return "Defence"
		&"infrastructure": return "Infrastructure"
	return title_case(String(id).replace("_", " "))


## Short tag for a progression tier, shown next to a name in the palette.
static func tier_mark(tier: int) -> String:
	return "I".repeat(clampi(tier, 1, 4)) if tier <= 3 else "IV"

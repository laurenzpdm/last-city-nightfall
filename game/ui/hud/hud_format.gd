class_name LcnHudFormat
extends RefCounted
## Numbers into language. [P17]
##
## The simulation speaks in floats with three decimals and StringName keys. A
## player does not. Every number that reaches a pixel goes through here, and the
## rules are deliberate:
##
##   * **Round to the decision.** Nobody acts on 14.237 heat per second. They act
##     on "14/s". Only values below 10 keep a decimal, and only when the decimal
##     changes what you would do.
##   * **Never print an id.** `warmth_radiator` is a file name; "Warmth Radiator"
##     is a building. Titles come from the registry when it has one.
##   * **Say what happened, not what the field is called.** "Network 5 short 0
##     heat/s" is a debug print. "The north grid is 14 heat short — the pipe at
##     (131, 128) cannot carry any more" is a sentence a human would say.
##
## Everything here is static and pure so tests can hammer it without a world.

const SECONDS_PER_MINUTE: float = 60.0


## "4:12", "0:07", "12:00". The one clock format the whole game uses.
static func clock(seconds: float) -> String:
	var s: int = int(roundf(maxf(0.0, seconds)))
	return "%d:%02d" % [s / 60, s % 60]


## Compact duration for a sentence: "in 3 minutes", "in 40 seconds", "now".
static func in_words(seconds: float) -> String:
	var s: float = maxf(0.0, seconds)
	if s < 5.0:
		return "now"
	if s < 90.0:
		return "in %d seconds" % int(roundf(s / 5.0) * 5.0)
	var m: int = int(roundf(s / SECONDS_PER_MINUTE))
	return "in %d minute%s" % [m, "" if m == 1 else "s"]


## A rate the player can act on. Below 10 keeps one decimal, above it does not.
static func rate(value: float) -> String:
	var v: float = value
	if absf(v) >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	if absf(v) >= 10.0:
		return "%d" % int(roundf(v))
	if absf(v) < 0.05:
		return "0"
	return "%.1f" % v


## A quantity inside a SENTENCE, where "0" is a lie whenever the value is not
## actually zero. `rate()` floors anything under 0.05 to "0", which is right on a
## chip and wrong in prose: "the north grid is short 0 heat/s" is the exact line
## a critic quoted back at this build. Below one unit this says so in words.
static func amount(value: float) -> String:
	var v: float = absf(value)
	if v == 0.0:
		return "0"
	if v < 1.0:
		return "under 1"
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	if v >= 10.0:
		return "%d" % int(roundf(v))
	return "%.1f" % v


## Days of something left, in the ONE wording the whole HUD uses.
##
## THE PANEL AND THE ALERT WERE ROUNDING THE SAME FLOAT DIFFERENTLY, in the same
## frame, fifteen hundred pixels apart: `artifacts/play_careless_vis/shots/
## assault.png` reads "FOOD 1.6 days" on the vitals panel and "Food runs out in
## 1.5 days" in the ATTENTION list. A player who notices has to decide which
## panel is lying, and the answer — neither, they snap to different grids — is
## not available to them. Half-day steps, because nobody plans on a tenth of a
## day and 1.6 pretends to a precision the food model does not have.
static func days(value: float) -> String:
	if value < 0.05:
		return "nothing"
	if value < 0.75:
		return "half a day"
	if value < 10.0:
		var rounded: float = snappedf(value, 0.5)
		if is_equal_approx(rounded, roundf(rounded)):
			var whole: int = int(roundf(rounded))
			return "%d day%s" % [whole, "" if whole == 1 else "s"]
		return "%.1f days" % rounded
	return "%d days" % int(roundf(value))


## "timber", "timber and stone", "timber, stone and coal". Oxford-free, because
## the HUD writes the way a person speaks.
static func list_words(words: PackedStringArray) -> String:
	var n: int = words.size()
	if n == 0:
		return ""
	if n == 1:
		return words[0]
	if n == 2:
		return "%s and %s" % [words[0], words[1]]
	var head: PackedStringArray = words.slice(0, n - 1)
	return "%s and %s" % [", ".join(head), words[n - 1]]


## Signed rate, for deltas: "+12", "-3.4", "0".
static func signed_rate(value: float) -> String:
	if absf(value) < 0.05:
		return "0"
	var body: String = rate(absf(value))
	return ("+" if value > 0.0 else "-") + body


## Whole counts, thousands-grouped: 1420 -> "1,420".
static func count(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	var c: int = 0
	for i: int in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


## Stock amounts stay readable at any size: 940, 1.4k, 21k, 1.2M.
static func stock(n: int) -> String:
	var a: int = absi(n)
	if a < 1000:
		return str(n)
	if a < 100000:
		return "%s%.1fk" % ["-" if n < 0 else "", float(a) / 1000.0]
	if a < 1000000:
		return "%s%dk" % ["-" if n < 0 else "", a / 1000]
	return "%s%.1fM" % ["-" if n < 0 else "", float(a) / 1000000.0]


## Temperature always carries its unit and its sign: "-34°C".
static func temperature(celsius: float) -> String:
	return "%d°C" % int(roundf(celsius))


static func percent(f01: float) -> String:
	return "%d%%" % int(roundf(clampf(f01, 0.0, 1.0) * 100.0))


## "(131, 128)" — a map coordinate a player can find with the camera.
static func cell(c: Vector2i) -> String:
	return "(%d, %d)" % [c.x, c.y]


## Turns `warmth_radiator` into "Warmth Radiator" when nothing better exists.
static func titleize(id: String) -> String:
	if id == "":
		return "—"
	var parts: PackedStringArray = id.replace("-", "_").split("_", false)
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		if p.length() == 0:
			continue
		out.append(p.substr(0, 1).to_upper() + p.substr(1))
	return " ".join(out)


## Display name from the content registry, falling back to a titleized id, so
## the HUD never shows a file name to a player.
static func building_title(kind: StringName) -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var reg: Node = tree.root.get_node_or_null(NodePath("Registry"))
		if reg != null:
			var res: Resource = reg.call("get_item", "buildings", kind) as Resource
			if res != null and "display_name" in res:
				var dn: String = String(res.get("display_name"))
				if dn != "":
					return dn
	return titleize(String(kind))


## Item names for the resource rail. Registry first, then a readable fallback.
static func item_title(id: StringName) -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var reg: Node = tree.root.get_node_or_null(NodePath("Registry"))
		if reg != null:
			for category: String in ["items", "resources"]:
				var res: Resource = reg.call("get_item", category, id) as Resource
				if res != null and "display_name" in res:
					var dn: String = String(res.get("display_name"))
					if dn != "":
						return dn
	return titleize(String(id))


## Compass word for a direction vector, because "north-east" is a place a player
## can look and (0.7, -0.7) is not.
static func compass(dir: Vector2) -> String:
	if dir.length_squared() < 0.0001:
		return "all sides"
	var a: float = rad_to_deg(atan2(dir.y, dir.x))
	if a < 0.0:
		a += 360.0
	var names: Array[String] = [
		"east", "south-east", "south", "south-west",
		"west", "north-west", "north", "north-east",
	]
	return names[int(roundf(a / 45.0)) % 8]


## Short compass tick for the wave dial: E, SE, S...
static func compass_short(dir: Vector2) -> String:
	if dir.length_squared() < 0.0001:
		return "•"
	var a: float = rad_to_deg(atan2(dir.y, dir.x))
	if a < 0.0:
		a += 360.0
	var names: Array[String] = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]
	return names[int(roundf(a / 45.0)) % 8]


## The wording for a heat bottleneck. This is the sentence the whole legibility
## complaint was about: the solver knows exactly which tile choked which
## consumers and why, and this is where that becomes English.
static func bottleneck_sentence(b: Dictionary) -> String:
	if b.is_empty():
		return ""
	var reason: String = String(b.get("reason", b.get("kind", "capacity")))
	var where: String = ""
	var raw: Variant = b.get("cell", null)
	if raw is Array and (raw as Array).size() >= 2:
		var arr: Array = raw as Array
		where = " at %s" % cell(Vector2i(int(arr[0]), int(arr[1])))
	var what: String = building_title(StringName(String(b.get("kind", b.get("building", "")))))
	var consumers: int = int(b.get("consumers", 0))
	match reason:
		"capacity":
			var tail: String = ""
			if consumers > 0:
				tail = ", starving %d building%s" % [consumers, "" if consumers == 1 else "s"]
			return "the %s%s cannot carry any more heat%s" % [what.to_lower(), where, tail]
		"supply":
			return "there is not enough heat being made"
		"unreachable":
			return "nothing connects it to a generator"
	return "the %s%s is the limit" % [what.to_lower(), where]


## Why a building is not working, in one clause, from [P02]'s node state and
## bottleneck attribution.
static func heat_state_words(state: int, served: float) -> String:
	match state:
		3:
			return "frozen solid"
		2:
			return "shut down"
		1:
			return "browned out at %s" % percent(served)
	return "running"

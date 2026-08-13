class_name LcnHudAlerts
extends RefCounted
## What is wrong, in the order it will kill you. [P17]
##
## An alert list is worthless the moment it becomes wallpaper, so this one obeys
## four rules:
##
##   * **Derived, not broadcast.** Most entries are recomputed from the current
##     state of the world every refresh, which means they *disappear by
##     themselves* the instant the player fixes the cause. Nothing lingers.
##   * **Grouped and counted.** Six frozen buildings are one line reading
##     "6 buildings have frozen", not six lines.
##   * **Written, not dumped.** The simulation's own wording ("Network 5 short 0
##     heat/s") is thrown away and the sentence is rebuilt from the numbers, with
##     sane rounding, a place, and — where there is one — the fix.
##   * **Actionable.** Every entry carries a world position, so clicking it puts
##     the camera on the actual problem through Bus.camera_focus_requested.
##
## Below the alerts sits a separate toast lane: momentary, severity-0 chatter
## (dusk, a blueprint stamped, a research finished) that must never be allowed
## to push a freezing district off the list.

const S := preload("res://game/ui/hud/hud_style.gd")

const MAX_VISIBLE: int = 5
const BUS_TTL_SECONDS: float = 12.0
const TOAST_TTL_SECONDS: float = 5.0
const MAX_TOASTS: int = 3
const DEATH_WINDOW_SECONDS: float = 90.0

## Lower sorts first inside the same severity. Heat before hunger before chatter,
## because on this map heat is what actually kills.
const FAMILY_RANK: Dictionary = {
	"game_over": 0, "heat_capacity": 1, "heat_supply": 2, "frozen": 3,
	"freezing": 4, "wave": 5, "dying": 6, "sick": 7, "storm": 8,
	"unrest": 9, "stock": 10, "stalled": 11, "build": 12, "other": 20,
}

var entries: Array[Dictionary] = []

var _bus: Dictionary[StringName, Dictionary] = {}
var _toasts: Array[Dictionary] = []
var _deaths: Array[float] = []
var _stall_keys: Dictionary[int, float] = {}
var _now: float = 0.0


func _init() -> void:
	var bus: Node = _autoload(&"Bus")
	if bus == null:
		return
	bus.connect(&"alert_raised", _on_alert)
	bus.connect(&"toast", _on_toast)
	bus.connect(&"citizen_died", _on_citizen_died)
	bus.connect(&"machine_stalled", _on_machine_stalled)
	bus.connect(&"placement_rejected", _on_placement_rejected)
	bus.connect(&"research_completed", _on_research_completed)
	bus.connect(&"law_enacted", _on_law_enacted)
	bus.connect(&"wave_cleared", _on_wave_cleared)
	bus.connect(&"game_over", _on_game_over)


## Rebuilds the list. `now` is in-world seconds, so alerts age at game speed.
func refresh(probe: LcnHudProbe, now: float) -> void:
	if now < _now:
		clear()
	_now = now
	var out: Array[Dictionary] = []
	_derive_heat(probe, out)
	_derive_people(probe, out)
	_derive_threat(probe, out)
	_derive_climate(probe, out)
	_derive_supplies(probe, out)
	_derive_build(probe, out)
	_carry_bus(out)
	out.sort_custom(_rank)
	entries = out
	_expire_toasts()


func clear() -> void:
	entries.clear()
	_bus.clear()
	_toasts.clear()
	_deaths.clear()
	_stall_keys.clear()


func top(n: int = MAX_VISIBLE) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in entries:
		if out.size() >= n:
			break
		out.append(e)
	return out


func hidden_count(n: int = MAX_VISIBLE) -> int:
	return maxi(0, entries.size() - n)


func worst_severity() -> int:
	var w: int = S.Sev.CALM
	for e: Dictionary in entries:
		w = maxi(w, int(e.get("sev", 0)))
	return w


func toasts() -> Array[Dictionary]:
	return _toasts


# =====================================================================  derive =

func _derive_heat(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_heat:
		return
	for stats: Dictionary in probe.short_networks:
		var deficit: float = float(stats.get("deficit", 0.0))
		var starved: int = int(stats.get("starved", 0)) + int(stats.get("brownouts", 0))
		if deficit < 0.5 and starved <= 0:
			continue
		var nid: int = int(stats.get("id", -1))
		var title: String = String(stats.get("title", "a grid"))
		var worst: Dictionary = stats.get("worst_bottleneck", {})
		var reason: String = String(worst.get("reason", "supply"))
		var sentence: String = LcnHudFormat.bottleneck_sentence(worst)
		var sev: int = S.Sev.WARN
		if starved >= 3 or deficit > maxf(4.0, float(stats.get("demand", 1.0)) * 0.35):
			sev = S.Sev.DANGER
		var head: String = "%s is %s heat short" % [
			_capitalise(title), LcnHudFormat.rate(deficit)]
		if deficit < 0.5:
			head = "%s is browning out" % _capitalise(title)
		var fix: String = "Add generation, or switch off what you can live without."
		if reason == "capacity":
			fix = "Widen the run: a booster pump or a second line past that tile."
		elif reason == "unreachable":
			fix = "Connect it: the pipe run does not reach a generator."
		out.append(_entry(
			StringName("heat_%d" % nid),
			"heat_capacity" if reason == "capacity" else "heat_supply",
			sev, head,
			("Because " + sentence + ".") if sentence != "" else
				"%d building%s are running cold." % [starved, "" if starved == 1 else "s"],
			fix, probe.network_focus(stats), 1))
	if probe.heat_frozen > 0:
		out.append(_entry(&"frozen", "frozen",
			S.Sev.DANGER if probe.heat_frozen > 2 else S.Sev.WARN,
			"%d building%s frozen solid" % [probe.heat_frozen,
				"" if probe.heat_frozen == 1 else "s have"],
			"A frozen building does nothing at all until it thaws, and a frozen "
				+ "generator takes its whole grid down with it.",
			"Get heat back to them, then wait for them to thaw.",
			Vector2.ZERO, probe.heat_frozen))


func _derive_people(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_population:
		return
	if probe.freezing > 0:
		out.append(_entry(&"freezing", "freezing",
			S.Sev.CRITICAL if probe.freezing > probe.population / 4 else S.Sev.DANGER,
			"%d citizen%s freezing" % [probe.freezing,
				"" if probe.freezing == 1 else "s are"],
			"They are standing in air cold enough to hurt them. Cold people fall "
				+ "sick, and sick people die.",
			"Get a radiator to where they live, or move them onto the grid.",
			Vector2.ZERO, probe.freezing))
	elif probe.city_is_freezing():
		out.append(_entry(&"freezing", "freezing", S.Sev.CRITICAL,
			"The city is freezing",
			"The average citizen is down to %s body warmth. Below this the cold "
				% LcnHudFormat.percent(probe.warmth01)
				+ "starts taking their health, and then it takes them.",
			"Heat where they live and where they walk, now.",
			Vector2.ZERO, 1))
	elif probe.city_is_cold():
		out.append(_entry(&"cold", "freezing", S.Sev.DANGER,
			"The city is running cold",
			"Average body warmth is %s. Under 40%% people start falling ill, and "
				% LcnHudFormat.percent(probe.warmth01)
				+ "an ill citizen who stays cold does not get better.",
			"More radiators, or shorter walks between warm buildings.",
			Vector2.ZERO, 1))
	if probe.food_days >= 0.0 and probe.food_days < 2.0 and probe.population > 0:
		out.append(_entry(&"food", "sick",
			S.Sev.CRITICAL if probe.food_days < 0.5 else S.Sev.DANGER,
			"Food runs out in %.1f days" % probe.food_days if probe.food_days >= 0.05
				else "There is no food left",
			"At this population and this ration, the kitchens have %s of meals left."
				% ("nothing" if probe.food_days < 0.05
					else "%.1f days" % probe.food_days),
			"Raise the harvest, cut the ration, or fewer mouths by morning.",
			Vector2.ZERO, 1))
	if probe.sick > 0:
		out.append(_entry(&"sick", "sick", S.Sev.WARN,
			"%d sick" % probe.sick,
			"Illness spreads in the cold and takes people out of the workforce.",
			"Warmth and food. A sick citizen who stays cold does not recover.",
			Vector2.ZERO, probe.sick))
	if probe.hungry > 0:
		out.append(_entry(&"hungry", "sick", S.Sev.WARN,
			"%d going hungry" % probe.hungry,
			"They are not being fed.",
			"Raise food production or shorten the haul to the kitchens.",
			Vector2.ZERO, probe.hungry))
	var recent: int = _recent_deaths()
	if recent > 0:
		out.append(_entry(&"dying", "dying", S.Sev.CRITICAL,
			"%d died recently" % recent,
			"People are dying in your city right now.",
			"Whatever is at the top of this list is what is killing them.",
			Vector2.ZERO, recent))
	if probe.has_society:
		if probe.hope < 0.25:
			out.append(_entry(&"hope", "unrest",
				S.Sev.DANGER if probe.hope < 0.12 else S.Sev.WARN,
				"Hope is failing",
				"At %s, people stop believing the city will last the winter."
					% LcnHudFormat.percent(probe.hope),
				"Keep them warm, keep them fed, and finish something visible.",
				Vector2.ZERO, 1))
		if probe.discontent > 0.6:
			out.append(_entry(&"discontent", "unrest",
				S.Sev.DANGER if probe.discontent > 0.8 else S.Sev.WARN,
				"Discontent is high",
				"At %s the city starts to argue with you."
					% LcnHudFormat.percent(probe.discontent),
				"Ease off the harshest laws, or give them a reason to hold on.",
				Vector2.ZERO, 1))


func _derive_threat(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if probe.wave_active and probe.enemies_alive > 0:
		out.append(_entry(&"wave_here", "wave", S.Sev.CRITICAL,
			"%d in the city" % probe.enemies_alive,
			"They are inside the perimeter.",
			"Turrets burn heat to fire — do not let the grid brown out now.",
			probe.wave_origin, probe.enemies_alive))
		return
	if probe.wave_seconds >= 0.0 and probe.wave_seconds < 120.0:
		var dir: String = LcnHudFormat.compass(probe.wave_direction)
		out.append(_entry(&"wave", "wave",
			S.Sev.DANGER if probe.wave_seconds < 45.0 else S.Sev.WARN,
			"Attack %s" % LcnHudFormat.in_words(probe.wave_seconds),
			"Wave %d comes from the %s." % [maxi(1, probe.wave_number), dir],
			"Guns on that side, and heat in the pipes that feed them.",
			probe.wave_origin, 1))


func _derive_climate(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_climate:
		return
	if probe.storm_active:
		var title: String = probe.storm_title if probe.storm_title != "" else "A storm"
		out.append(_entry(&"storm", "storm",
			S.Sev.DANGER if probe.storm_intensity > 0.6 else S.Sev.WARN,
			"%s is on the city" % title,
			"It is %s outside and every building is losing heat %.1f times as fast."
				% [LcnHudFormat.temperature(probe.ambient_c), probe.heat_loss_multiplier],
			"Burn everything you have. It passes.",
			Vector2.ZERO, 1))
	elif probe.seconds_to_storm > 0.0 and probe.seconds_to_storm < 240.0:
		out.append(_entry(&"storm_warning", "storm", S.Sev.WARN,
			"A Great Frost arrives %s" % LcnHudFormat.in_words(probe.seconds_to_storm),
			"Ambient temperature will fall hard and heat loss will roughly double.",
			"Fill the accumulators and finish anything half-built.",
			Vector2.ZERO, 1))


func _derive_supplies(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_build:
		return
	for id: StringName in probe.stock_order:
		var amount: int = probe.stock.get(id, 0)
		if amount <= 0:
			continue
		var seconds: float = probe.trend.seconds_to_zero(id)
		if seconds < 0.0 or seconds > 180.0:
			continue
		out.append(_entry(StringName("stock_%s" % id), "stock",
			S.Sev.DANGER if seconds < 60.0 else S.Sev.WARN,
			"%s runs out %s" % [LcnHudFormat.item_title(id),
				LcnHudFormat.in_words(seconds)],
			"%s left, falling by %s a minute." % [LcnHudFormat.stock(amount),
				LcnHudFormat.rate(absf(probe.trend.per_minute(id)))],
			"Mine more, make more, or stop spending it.",
			Vector2.ZERO, 1))


## [P04] may report its own stall count; the Bus signal covers the case where it
## does not. Whichever number is larger is the one the player can see on the map.
func _derive_build(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	var stalled: int = maxi(_live_stalls(), probe.stalled_machines)
	if stalled <= 0:
		return
	out.append(_entry(&"stalled", "stalled", S.Sev.INFO,
		"%d machine%s stalled" % [stalled, "" if stalled == 1 else "s"],
		"They have nothing to work with, or nowhere to put what they make.",
		"Follow the belt: it is empty at one end and full at the other.",
		Vector2.ZERO, stalled))


# ================================================================  bus intake =

func _on_alert(severity: int, key: StringName, text: String, pos: Vector2) -> void:
	# Severity 0 is chatter by definition — dusk, a stamped blueprint. It goes to
	# the toast lane, where it cannot bury a freezing district.
	if severity <= 0:
		_push_toast(text, S.Sev.INFO)
		return
	if _is_rewritten(key):
		return
	var family: String = _family_of(key)
	var existing: Dictionary = _bus.get(key, {})
	var count: int = int(existing.get("count", 0)) + 1
	_bus[key] = {
		"key": key, "family": family,
		"sev": clampi(severity + 1, S.Sev.INFO, S.Sev.CRITICAL),
		"head": _headline(text), "body": text, "fix": "",
		"focus": pos, "count": count, "at": _now,
	}


## Anything the HUD already says better, from the source numbers, is dropped on
## arrival. This is the rule that stops "Network 5 short 0 heat/s" ever reaching
## a pixel while the derived line above says it properly.
func _is_rewritten(key: StringName) -> bool:
	var k: String = String(key)
	return k.begins_with("heat_supply") or k.begins_with("heat_capacity") \
		or k == "building_froze" or k.begins_with("climate_storm") \
		or k == "climate_blizzard"


func _carry_bus(out: Array[Dictionary]) -> void:
	var keys: Array = _bus.keys()
	keys.sort()
	for k: StringName in keys:
		var e: Dictionary = _bus[k]
		if _now - float(e.get("at", 0.0)) > BUS_TTL_SECONDS:
			_bus.erase(k)
			continue
		out.append(e.duplicate())


func _on_toast(text: String) -> void:
	_push_toast(text, S.Sev.INFO)


func _on_citizen_died(_id: int, _cause: StringName) -> void:
	_deaths.append(_now)


func _on_machine_stalled(id: int, reason: StringName) -> void:
	_stall_keys[id] = _now
	if _stall_keys.size() == 1:
		_push_toast("A machine stalled: %s" % LcnHudFormat.titleize(String(reason)).to_lower(),
			S.Sev.INFO)


func _on_placement_rejected(_cell: Vector2i, reason: String) -> void:
	_push_toast("Cannot build there — %s" % reason, S.Sev.WARN)


func _on_research_completed(id: StringName) -> void:
	_push_toast("%s researched" % LcnHudFormat.titleize(String(id)), S.Sev.INFO)


func _on_law_enacted(id: StringName) -> void:
	_push_toast("%s signed into law" % LcnHudFormat.titleize(String(id)), S.Sev.INFO)


func _on_wave_cleared(wave: int) -> void:
	_push_toast("Wave %d is over" % wave, S.Sev.INFO)


func _on_game_over(reason: String) -> void:
	_bus[&"game_over"] = {
		"key": &"game_over", "family": "game_over", "sev": S.Sev.CRITICAL,
		"head": "The city is lost", "body": reason, "fix": "",
		"focus": Vector2.ZERO, "count": 1, "at": _now,
	}


func _push_toast(text: String, sev: int) -> void:
	if text.strip_edges() == "":
		return
	for t: Dictionary in _toasts:
		if String(t.get("text", "")) == text:
			t["at"] = _now
			t["count"] = int(t.get("count", 1)) + 1
			return
	_toasts.append({"text": text, "sev": sev, "at": _now, "count": 1})
	while _toasts.size() > MAX_TOASTS:
		_toasts.remove_at(0)


func _expire_toasts() -> void:
	var live: Array[Dictionary] = []
	for t: Dictionary in _toasts:
		if _now - float(t.get("at", 0.0)) <= TOAST_TTL_SECONDS:
			live.append(t)
	_toasts = live


# ====================================================================  helpers =

func _recent_deaths() -> int:
	var live: Array[float] = []
	for at: float in _deaths:
		if _now - at <= DEATH_WINDOW_SECONDS:
			live.append(at)
	_deaths = live
	return live.size()


func _live_stalls() -> int:
	var keys: Array = _stall_keys.keys()
	keys.sort()
	var n: int = 0
	for k: int in keys:
		if _now - _stall_keys[k] > 20.0:
			_stall_keys.erase(k)
		else:
			n += 1
	return n


func _entry(key: StringName, family: String, sev: int, head: String, body: String,
		fix: String, focus: Vector2, count: int) -> Dictionary:
	return {
		"key": key, "family": family, "sev": sev, "head": head, "body": body,
		"fix": fix, "focus": focus, "count": count, "at": _now,
	}


## Severity first, then how deadly the family is, then the key — so a list that
## is not changing does not reshuffle itself under the player's cursor.
func _rank(a: Dictionary, b: Dictionary) -> bool:
	var sa: int = int(a.get("sev", 0))
	var sb: int = int(b.get("sev", 0))
	if sa != sb:
		return sa > sb
	var fa: int = int(FAMILY_RANK.get(String(a.get("family", "other")), 20))
	var fb: int = int(FAMILY_RANK.get(String(b.get("family", "other")), 20))
	if fa != fb:
		return fa < fb
	return String(a.get("key", "")) < String(b.get("key", ""))


static func _family_of(key: StringName) -> String:
	var k: String = String(key)
	if k.begins_with("heat"):
		return "heat_supply"
	if k.begins_with("build"):
		return "build"
	if k.begins_with("climate"):
		return "storm"
	if k.begins_with("wave") or k.begins_with("threat"):
		return "wave"
	if k.begins_with("grid"):
		return "build"
	return "other"


## First sentence, capitalised, no trailing full stop — an alert headline is a
## label, not prose.
static func _headline(text: String) -> String:
	var t: String = text.strip_edges()
	var stop: int = t.find(". ")
	if stop > 0:
		t = t.substr(0, stop)
	t = t.trim_suffix(".")
	if t.length() > 64:
		t = t.substr(0, 61) + "…"
	return _capitalise(t)


static func _capitalise(s: String) -> String:
	if s == "":
		return s
	return s.substr(0, 1).to_upper() + s.substr(1)


static func _autoload(n: StringName) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(n))

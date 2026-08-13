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

## A stock warning must survive this long, continuously, before it is shown. It
## exists because a warning that appears and vanishes inside one breath is
## indistinguishable from a bug, and because it is the second half of the defence
## against predicting from a purchase (LcnHudTrend has the first half).
const STOCK_CONFIRM_SECONDS: float = 10.0
## Under this the stock alert has left the realm of "worth knowing".
const STOCK_HORIZON_SECONDS: float = 180.0
## More than this many stocks in trouble and they become one grouped line. Five
## separate "X runs out in Y" rows is the whole ATTENTION panel and it buries the
## wave countdown underneath them.
const STOCK_GROUP_FROM: int = 2

## Lower sorts first inside the same severity. Heat before hunger before chatter,
## because on this map heat is what actually kills.
const FAMILY_RANK: Dictionary = {
	"game_over": 0, "heat_capacity": 1, "heat_supply": 2, "frozen": 3,
	"freezing": 4, "wave": 5, "dying": 6, "sick": 7, "storm": 8,
	"council": 9, "unrest": 10, "stock": 11, "stalled": 12, "build": 13,
	"other": 20,
}
## At most this many lines from one family, so no single kind of problem can own
## the panel. The overflow is still counted in "and N more".
const MAX_PER_FAMILY: int = 2

var entries: Array[Dictionary] = []

var _bus: Dictionary[StringName, Dictionary] = {}
var _toasts: Array[Dictionary] = []
var _deaths: Array[float] = []
var _stall_keys: Dictionary[int, float] = {}
var _now: float = 0.0
## item -> the in-world second its drain was first seen. Cleared the moment the
## drain stops, which is what makes the confirmation window a window and not a
## delay that only ever runs once.
var _stock_since: Dictionary[StringName, float] = {}


## Signal -> handler, in one place so `dispose()` cannot drift from `_init`.
func _subscriptions() -> Array:
	return [
		[&"alert_raised", _on_alert],
		[&"toast", _on_toast],
		[&"citizen_died", _on_citizen_died],
		[&"machine_stalled", _on_machine_stalled],
		[&"placement_rejected", _on_placement_rejected],
		[&"research_completed", _on_research_completed],
		[&"law_enacted", _on_law_enacted],
		[&"wave_cleared", _on_wave_cleared],
		[&"game_over", _on_game_over],
	]


## Drops every Bus subscription. MUST be called when the owner goes away — see
## LcnHudProbe.dispose() for why a RefCounted on an autoload signal outlives you.
func dispose() -> void:
	var bus: Node = _autoload(&"Bus")
	if bus == null:
		return
	for pair: Array in _subscriptions():
		if bus.is_connected(pair[0], pair[1]):
			bus.disconnect(pair[0], pair[1])


func _init() -> void:
	var bus: Node = _autoload(&"Bus")
	if bus == null:
		return
	for pair: Array in _subscriptions():
		bus.connect(pair[0], pair[1])


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
	_derive_council(probe, out)
	_carry_bus(probe, out)
	out.sort_custom(_rank)
	entries = _cap_families(out)
	_expire_toasts()


## No family may own the panel. Two heat grids short is news; six is one story
## told six times, and the six push the wave countdown off the bottom.
func _cap_families(rows: Array[Dictionary]) -> Array[Dictionary]:
	var seen: Dictionary[String, int] = {}
	var kept: Array[Dictionary] = []
	var dropped: Array[Dictionary] = []
	for e: Dictionary in rows:
		var fam: String = String(e.get("family", "other"))
		var n: int = int(seen.get(fam, 0))
		seen[fam] = n + 1
		if n < MAX_PER_FAMILY:
			kept.append(e)
		else:
			dropped.append(e)
	# The overflow still exists — it goes to the bottom so "and N more" counts it.
	kept.append_array(dropped)
	return kept


func clear() -> void:
	entries.clear()
	_bus.clear()
	_toasts.clear()
	_deaths.clear()
	_stall_keys.clear()
	_stock_since.clear()


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
			_capitalise(title), LcnHudFormat.amount(deficit)]
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
			probe.frozen_focus(), probe.heat_frozen))


func _derive_people(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_population:
		return
	# One place to send the camera for anything that is an average over people:
	# the coldest house they actually sleep in. An average has no tile; the worst
	# building that produced it does, and that is where the fix goes.
	var home: Vector2 = Vector2.ZERO
	if probe.freezing > 0 or probe.city_is_cold() or probe.sick > 0 or probe.hungry > 0:
		home = probe.coldest_home_focus()
	if home == Vector2.ZERO:
		home = probe.core_focus()
	if probe.freezing > 0:
		out.append(_entry(&"freezing", "freezing",
			S.Sev.CRITICAL if probe.freezing > probe.population / 4 else S.Sev.DANGER,
			"%d citizen%s freezing" % [probe.freezing,
				"" if probe.freezing == 1 else "s are"],
			"They are standing in air cold enough to hurt them. Cold people fall "
				+ "sick, and sick people die.",
			"Get a radiator to where they live, or move them onto the grid.",
			home, probe.freezing))
	elif probe.city_is_freezing():
		out.append(_entry(&"freezing", "freezing", S.Sev.CRITICAL,
			"The city is freezing",
			"The average citizen is down to %s body warmth. Below this the cold "
				% LcnHudFormat.percent(probe.warmth01)
				+ "starts taking their health, and then it takes them.",
			"Heat where they live and where they walk, now.",
			home, 1))
	elif probe.city_is_cold():
		out.append(_entry(&"cold", "freezing", S.Sev.DANGER,
			"The city is running cold",
			"Average body warmth is %s. Under 40%% people start falling ill, and "
				% LcnHudFormat.percent(probe.warmth01)
				+ "an ill citizen who stays cold does not get better.",
			"More radiators, or shorter walks between warm buildings.",
			home, 1))
	if probe.food_days >= 0.0 and probe.food_days < 2.0 and probe.population > 0:
		out.append(_entry(&"food", "sick",
			S.Sev.CRITICAL if probe.food_days < 0.5 else S.Sev.DANGER,
			("Food runs out in %s" % _days_words(probe.food_days))
				if probe.food_days >= 0.05 else "There is no food left",
			"At this population and this ration, the kitchens have %s of meals left."
				% ("nothing" if probe.food_days < 0.05
					else _days_words(probe.food_days)),
			"Raise the harvest, cut the ration, or fewer mouths by morning.",
			home, 1))
	if probe.sick > 0:
		out.append(_entry(&"sick", "sick", S.Sev.WARN,
			"%d sick" % probe.sick,
			"Illness spreads in the cold and takes people out of the workforce.",
			"Warmth and food. A sick citizen who stays cold does not recover.",
			home, probe.sick))
	if probe.hungry > 0:
		out.append(_entry(&"hungry", "sick", S.Sev.WARN,
			"%d going hungry" % probe.hungry,
			"They are not being fed.",
			"Raise food production or shorten the haul to the kitchens.",
			home, probe.hungry))
	var recent: int = _recent_deaths()
	if recent > 0:
		out.append(_entry(&"dying", "dying", S.Sev.CRITICAL,
			"%d died recently" % recent,
			"People are dying in your city right now.",
			"Whatever is at the top of this list is what is killing them.",
			home, recent))
	if probe.has_society:
		if probe.hope < 0.25:
			out.append(_entry(&"hope", "unrest",
				S.Sev.DANGER if probe.hope < 0.12 else S.Sev.WARN,
				"Hope is failing",
				"At %s, people stop believing the city will last the winter."
					% LcnHudFormat.percent(probe.hope),
				"Keep them warm, keep them fed, and finish something visible.",
				probe.core_focus(), 1))
		if probe.discontent > 0.6:
			out.append(_entry(&"discontent", "unrest",
				S.Sev.DANGER if probe.discontent > 0.8 else S.Sev.WARN,
				"Discontent is high",
				"At %s the city starts to argue with you."
					% LcnHudFormat.percent(probe.discontent),
				"Ease off the harshest laws, or give them a reason to hold on.",
				probe.core_focus(), 1))


## "half a day", "1.5 days", "3 days" — never "2.0 days", never "0.0 days".
static func _days_words(days: float) -> String:
	if days < 0.05:
		return "nothing"
	if days < 0.75:
		return "half a day"
	if days < 10.0:
		var rounded: float = snappedf(days, 0.5)
		if is_equal_approx(rounded, roundf(rounded)):
			var whole: int = int(roundf(rounded))
			return "%d day%s" % [whole, "" if whole == 1 else "s"]
		return "%.1f days" % rounded
	return "%d days" % int(roundf(days))


func _derive_threat(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	# [P08] redacts the approach until the player has scouted it, so wave_origin
	# is legitimately zero sometimes. Falling back to the hearth keeps the row
	# clickable and still tells the truth: that is where they are coming for.
	var where: Vector2 = probe.wave_origin
	if where == Vector2.ZERO:
		where = probe.core_focus()
	if probe.wave_active and probe.enemies_alive > 0:
		out.append(_entry(&"wave_here", "wave", S.Sev.CRITICAL,
			"%d in the city" % probe.enemies_alive,
			"They are inside the perimeter.",
			"Turrets burn heat to fire — do not let the grid brown out now.",
			where, probe.enemies_alive))
		return
	if probe.wave_seconds >= 0.0 and probe.wave_seconds < 120.0:
		var body: String = "Wave %d comes from the %s." % [maxi(1, probe.wave_number),
			LcnHudFormat.compass(probe.wave_direction)]
		if not probe.wave_known:
			body = "Wave %d. Nothing has been seen yet — the direction is not known." \
				% maxi(1, probe.wave_number)
		out.append(_entry(&"wave", "wave",
			S.Sev.DANGER if probe.wave_seconds < 45.0 else S.Sev.WARN,
			"Attack %s" % LcnHudFormat.in_words(probe.wave_seconds),
			body,
			"Guns on that side, and heat in the pipes that feed them.",
			where, 1))


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
			probe.core_focus(), 1))
	elif probe.seconds_to_storm > 0.0 and probe.seconds_to_storm < 240.0:
		var coming: String = probe.next_storm_title if probe.next_storm_title != "" \
			else "A storm"
		out.append(_entry(&"storm_warning", "storm", S.Sev.WARN,
			"%s arrives %s" % [coming, LcnHudFormat.in_words(probe.seconds_to_storm)],
			"Ambient temperature will fall hard and heat loss will roughly double.",
			"Fill the accumulators and finish anything half-built.",
			probe.core_focus(), 1))


## The one that was lying. It printed "Timber runs out in 20 seconds" from a
## slope fitted through a single purchase, in red, four times over, while the
## checkpoints showed timber flat at 495 for the next three minutes.
##
## Three things changed. The rate now comes from `sustained_per_minute()`, which
## refuses to exist unless the fall is repeated rather than stepped (see
## LcnHudTrend). The warning then has to HOLD for STOCK_CONFIRM_SECONDS before it
## is allowed on screen. And more than one of them collapses into a single line,
## because four stock rows are how a wave countdown gets pushed off the panel.
func _derive_supplies(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_build:
		return
	var live: Array[Dictionary] = []
	for id: StringName in probe.stock_order:
		var amount: int = probe.stock.get(id, 0)
		if amount <= 0:
			_stock_since.erase(id)
			continue
		var seconds: float = probe.trend.seconds_to_zero(id)
		if seconds < 0.0 or seconds > STOCK_HORIZON_SECONDS:
			_stock_since.erase(id)
			continue
		var since: float = float(_stock_since.get(id, _now))
		if since > _now:            # the world restarted under us
			since = _now
		_stock_since[id] = since
		if _now - since < STOCK_CONFIRM_SECONDS:
			continue
		live.append({
			"id": id, "amount": amount, "seconds": seconds,
			"rate": absf(probe.trend.sustained_per_minute(id)),
		})
	if live.is_empty():
		return
	live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["seconds"]), float(b["seconds"])):
			return float(a["seconds"]) < float(b["seconds"])
		return String(a["id"]) < String(b["id"]))

	if live.size() >= STOCK_GROUP_FROM:
		var names: PackedStringArray = PackedStringArray()
		for row: Dictionary in live:
			names.append(LcnHudFormat.item_title(row["id"] as StringName).to_lower())
		var first: Dictionary = live[0]
		out.append(_entry(&"stock_group", "stock",
			S.Sev.DANGER if float(first["seconds"]) < 60.0 else S.Sev.WARN,
			"%s are running out" % _capitalise(LcnHudFormat.list_words(names)),
			"%s goes first — %s left, and it has been falling by %s a minute for "
				% [LcnHudFormat.item_title(first["id"] as StringName),
					LcnHudFormat.stock(int(first["amount"])),
					LcnHudFormat.amount(float(first["rate"]))]
				+ "the last %s." % LcnHudFormat.clock(
					probe.trend.span_seconds(first["id"] as StringName)),
			"Mine more, make more, or stop spending it.",
			probe.core_focus(), live.size()))
		return

	var only: Dictionary = live[0]
	var id0: StringName = only["id"]
	out.append(_entry(StringName("stock_%s" % id0), "stock",
		S.Sev.DANGER if float(only["seconds"]) < 60.0 else S.Sev.WARN,
		"%s runs out %s" % [LcnHudFormat.item_title(id0),
			LcnHudFormat.in_words(float(only["seconds"]))],
		"%s left, and it has been falling by %s a minute for the last %s." % [
			LcnHudFormat.stock(int(only["amount"])),
			LcnHudFormat.amount(float(only["rate"])),
			LcnHudFormat.clock(probe.trend.span_seconds(id0))],
		"Mine more, make more, or stop spending it.",
		probe.core_focus(), 1))


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
		probe.stalled_focus(), stalled))


## [P06] issues ultimatums with a deadline on them, and the ONLY answer to one is
## a signature in the Book of Laws. Before this the city was being given terms it
## had no way to see and no way to accept, which is the difference between a hard
## game and a broken one. The fix line names the key that opens the book.
func _derive_council(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	if not probe.has_society or probe.demands.is_empty():
		return
	for d: Dictionary in probe.demands:
		var hours: float = float(d.get("hours_left", -1.0))
		var faction: String = String(d.get("faction_name", "The council"))
		var terms: String = String(d.get("terms", ""))
		var speech: String = String(d.get("speech", ""))
		var laws: Array = d.get("laws", [])
		var sev: int = S.Sev.WARN
		if hours >= 0.0 and hours < 6.0:
			sev = S.Sev.DANGER
		if hours >= 0.0 and hours < 2.0:
			sev = S.Sev.CRITICAL
		var head: String = "%s is demanding something" % faction
		if hours >= 0.0:
			head = "%s wants an answer within %s" % [faction, _hours_words(hours)]
		var body: String = speech if speech != "" else terms
		if body == "" :
			body = "They have put terms to you and started a clock on them."
		var fix: String = "Open the Book of Laws with L."
		if not laws.is_empty():
			fix = "Open the Book of Laws with L and sign %s." % LcnHudFormat.list_words(
				_law_names(laws))
		out.append(_entry(StringName("demand_%s" % String(d.get("id", "x"))), "council",
			sev, head, body, fix, probe.core_focus(), 1))


static func _law_names(laws: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l: Variant in laws:
		out.append(LcnHudFormat.titleize(String(l)))
	return out


## Council deadlines arrive in in-world HOURS, which is not a unit the rest of
## the HUD speaks. Round to something a person would say out loud.
static func _hours_words(hours: float) -> String:
	if hours < 1.0:
		return "the hour"
	var h: int = int(roundf(hours))
	return "%d hour%s" % [h, "" if h == 1 else "s"]


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


func _carry_bus(probe: LcnHudProbe, out: Array[Dictionary]) -> void:
	var keys: Array = _bus.keys()
	keys.sort()
	for k: StringName in keys:
		var e: Dictionary = _bus[k]
		if _now - float(e.get("at", 0.0)) > BUS_TTL_SECONDS:
			_bus.erase(k)
			continue
		var row: Dictionary = e.duplicate()
		# A part that raised an alert without a position still gets a clickable
		# row — the hearth is a worse answer than the real tile and a much better
		# one than a dead entry the player learns not to click.
		if (row.get("focus", Vector2.ZERO) as Vector2) == Vector2.ZERO \
				and String(row.get("key", "")) != "game_over":
			row["focus"] = probe.core_focus()
		out.append(row)


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

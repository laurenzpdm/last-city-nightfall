class_name NarrativeEffects
extends RefCounted
## Turns a chosen option into things that actually happen to Caldera Nine.
##
## Everything goes out through another part's PUBLIC command surface, queued on
## `Sim.submit_command`, which means:
##   * it is applied at the top of the next tick, before any system runs, so a
##     decision never lands halfway through somebody's step();
##   * it appears in the same command path a scenario and the harness use, so a
##     scripted run reproduces a player's choice exactly;
##   * nothing here reaches into another part's fields.
##
## An effect addressed to a part that is not in this build is DROPPED and
## counted, never submitted. `Sim._advance` logs an error for a command to an
## absent system — correctly, because that is a broken script — and this part
## must not manufacture that error just because [P05] has not landed yet.
##
## `applied()` returns exactly what happened, in words, and that text goes into
## the journal. A consequence the player cannot read is not a consequence.

var _applied: PackedStringArray = PackedStringArray()
var _dropped: PackedStringArray = PackedStringArray()
var flags: Dictionary[StringName, float] = {}

## citizen ids the last apply() took, so a caller can name them.
var took: PackedInt32Array = PackedInt32Array()


func reset() -> void:
	_applied = PackedStringArray()
	_dropped = PackedStringArray()
	took = PackedInt32Array()


func applied() -> PackedStringArray:
	return _applied


func dropped() -> PackedStringArray:
	return _dropped


func flag(name: StringName) -> bool:
	return float(flags.get(name, 0.0)) >= 0.5


func set_flag(name: StringName, on: bool) -> void:
	flags[name] = 1.0 if on else 0.0


func flag_keys() -> Array[StringName]:
	var keys: Array = flags.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


## Applies one option. `why` is the sentence attached to every meter nudge, so
## the society ledger says "Because you opened the Drop", not "Scripted".
func apply(option: NarrativeOption, why: String) -> void:
	reset()
	for key: StringName in option.effect_keys():
		var amount: float = option.effect(key)
		if absf(amount) < 0.0001 and not String(key).begins_with("flag"):
			continue
		var parts: Array[StringName] = NarrativeDefs.split_effect(key)
		match parts[0]:
			NarrativeDefs.FX_HOPE:
				_nudge(&"hope", amount, why)
			NarrativeDefs.FX_DISCONTENT:
				_nudge(&"discontent", amount, why)
			NarrativeDefs.FX_APPROVAL:
				_approval(parts[1], amount)
			NarrativeDefs.FX_FOOD:
				_food(amount)
			NarrativeDefs.FX_DEATHS:
				_deaths(int(roundf(amount)))
			NarrativeDefs.FX_ARRIVALS:
				_arrivals(int(roundf(amount)))
			NarrativeDefs.FX_STOCK:
				_stock(parts[1], int(roundf(amount)))
			NarrativeDefs.FX_FLAG:
				set_flag(parts[1], amount >= 0.5)
				_applied.append("%s is now %s" % [String(parts[1]),
					"true" if amount >= 0.5 else "false"])
			NarrativeDefs.FX_RESEARCH:
				_research(parts[1])
			_:
				_dropped.append("unknown effect '%s'" % String(key))


# =========================================================================
#  one part each
# =========================================================================

func _nudge(meter: StringName, amount: float, why: String) -> void:
	if Sim.get_system(&"society") == null:
		_dropped.append("%s %+.1f (no society system in this build)" % [String(meter), amount])
		return
	Sim.submit_command({
		"system": &"society", "op": "nudge", "meter": meter, "amount": amount,
		"key": &"narrative", "label": "A decision you took", "reason": why,
	})
	_applied.append("%s %+.1f" % [String(meter), amount])


func _approval(faction: StringName, amount: float) -> void:
	if Sim.get_system(&"society") == null:
		_dropped.append("approval for %s (no society system)" % String(faction))
		return
	Sim.submit_command({
		"system": &"society", "op": "approval", "faction": faction, "delta": amount,
	})
	_applied.append("%s %+.0f approval" % [String(faction), amount])


func _food(amount: float) -> void:
	if Sim.get_system(&"citizens") == null:
		_dropped.append("food %+.0f (no citizens system)" % amount)
		return
	Sim.submit_command({"system": &"citizens", "op": "feed", "amount": amount})
	_applied.append("food %+.0f" % amount)


## Deterministic and named: the lowest living ids go first, so a replay takes
## the same people, and the caller can read `took` to put their names in the
## outcome line. A death this part causes is never anonymous.
func _deaths(count: int) -> void:
	if count <= 0:
		return
	var citizens: SimSystem = Sim.get_system(&"citizens")
	if citizens == null:
		_dropped.append("%d death(s) (no citizens system)" % count)
		return
	var ids: PackedInt32Array = citizens.call("citizen_ids")
	var n: int = mini(count, ids.size())
	for i: int in n:
		took.append(ids[i])
		Sim.submit_command({
			"system": &"citizens", "op": "remove", "id": ids[i], "cause": &"exhaustion",
		})
	_applied.append("%d taken" % n)


func _arrivals(count: int) -> void:
	if count <= 0:
		return
	if Sim.get_system(&"citizens") == null:
		_dropped.append("%d arrival(s) (no citizens system)" % count)
		return
	Sim.submit_command({"system": &"citizens", "op": "add", "count": count})
	_applied.append("%d walked in" % count)


func _stock(item: StringName, amount: int) -> void:
	var build: SimSystem = Sim.get_system(&"build")
	if build == null:
		_dropped.append("%s %+d (no build system)" % [String(item), amount])
		return
	if amount > 0:
		Sim.submit_command({"system": &"build", "op": "add_stock",
			"items": {String(item): amount}})
		_applied.append("%s +%d" % [String(item), amount])
		return
	# Spending is a set, not a give: BuildStock refuses to go negative and a
	# "take" the yard cannot cover has to leave the yard at zero, not at a
	# number nobody can explain.
	var stock: Object = build.get("stock")
	var have: int = 0 if stock == null else int(stock.call("count", item))
	var left: int = maxi(0, have + amount)
	Sim.submit_command({"system": &"build", "op": "set_stock",
		"items": {String(item): left}})
	_applied.append("%s %d -> %d" % [String(item), have, left])


func _research(unlock: StringName) -> void:
	if Sim.get_system(&"research") == null:
		_dropped.append("unlock '%s' (no research system)" % String(unlock))
		return
	Sim.submit_command({"system": &"research", "op": "grant", "unlock": unlock})
	_applied.append("'%s' opened" % String(unlock))


# =========================================================================
#  persistence
# =========================================================================

func serialize() -> Dictionary:
	var out: Dictionary = {}
	for k: StringName in flag_keys():
		out[String(k)] = float(flags[k])
	return out


func deserialize(data: Dictionary) -> void:
	flags.clear()
	var keys: Array = data.keys()
	keys.sort()
	for k: String in keys:
		flags[StringName(k)] = float(data[k])

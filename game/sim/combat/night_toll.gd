class_name NightToll
extends RefCounted
## [P07] What a night TAKES.
##
## The build this was written for ran three nights and cost the player nothing:
## `combat.structures_lost 0`, `combat.breaches 0`, across 24000 ticks. A city
## builder whose nights are free is a city builder with no reason to build, and
## a tower defence with no losses is a screensaver. Frostpunk's nights cost you
## people; this one costs you a radiator, a hole in the line, and the people who
## were standing in it.
##
## The rule is deliberately narrow, because a night must be legible before it is
## cruel. NOTHING here kills anyone on its own. A citizen is only ever hurt when
## a STRUCTURE THEY WERE STANDING IN comes down — a consequence of a wall the
## player did not hold, at a place the player can point at, on a building the
## player chose to put there. There is no invisible attrition and no dice roll
## the player cannot trace back to a decision.
##
## The names come from [P05], which already writes the obituary sentence the
## critics singled out ("Mira Osk, 34, stoker, died of their injuries"). This
## part supplies the cause and the place; it does not do the writing.

## Ledger rows kept. Roughly a dozen catastrophic nights; the record a critic
## reads is per-night anyway and [P08] filters it by tick.
const KEEP: int = 400
## Its own stream, so adding this roll cannot shift a single shell in the
## existing combat sequence and every replay before it stays byte-identical.
const RNG_STREAM: String = "combat_toll"
## Tiles outward from the footprint that still count as "in it when it came
## down". One: the doorway, not the street.
const APRON: int = 1

## One row per structure lost, newest last. Each carries the tick, so [P08] can
## ask what THIS night cost without either part tracking the other's clock.
var ledger: Array[Dictionary] = []
var dead_total: int = 0
var hurt_total: int = 0

var _citizens: Object = null
var _can_kill: bool = false
var _can_hurt: bool = false
var _can_find: bool = false

## Share of the people caught in a collapse who do not walk out of it. The rest
## are hurt — which is [P05]'s injury track, which is lost work and a bed in the
## infirmary, which is a cost the player feels the following morning.
var fatal_share: float = 0.34
## Injury severity handed to [P05] for the survivors.
var injury_severity: float = 45.0
## People who can be caught by one building coming down, whatever the crowd.
## A collapse is not a massacre; it is a building.
var max_caught: int = 6


func bind(citizens: Object) -> void:
	_citizens = citizens
	_can_kill = citizens != null and citizens.has_method("kill_citizen")
	_can_hurt = citizens != null and citizens.has_method("injure_citizen")
	_can_find = citizens != null and citizens.has_method("citizens_in_cell_rect")


func reset() -> void:
	ledger.clear()
	dead_total = 0
	hurt_total = 0


## A structure has just been destroyed by the enemy. Records it, and bills the
## city for whoever was inside. Returns the row it wrote.
##
## `cells` is the footprint [P11] handed over BEFORE the building was removed,
## which is why this is called from _on_structure_lost and nowhere else: a moment
## later there is nothing left to ask where it stood.
func structure_lost(tick: int, kind: StringName, label: String, tags: PackedStringArray,
		cells: Array[Vector2i]) -> Dictionary:
	var row: Dictionary = {
		"tick": tick,
		"kind": String(kind),
		"label": label if label != "" else String(kind),
		"tags": tags,
		"cell": [cells[0].x, cells[0].y] if not cells.is_empty() else [0, 0],
		"dead": [],
		"hurt": 0,
	}
	var caught: PackedInt32Array = _caught_in(cells)
	if caught.size() > 0:
		var names: Array[String] = []
		var hurt: int = 0
		var rng: RandomNumberGenerator = Rng.stream(RNG_STREAM)
		for id: int in caught:
			# Rolled BEFORE the branch, always, for every id: a roll that only
			# happens on one side of an `if` makes the stream depend on the
			# world's state and the replay stops being a replay.
			var roll: float = rng.randf()
			var who: String = _name_of(id)
			if roll < fatal_share and _can_kill:
				if bool(_citizens.call("kill_citizen", id, &"injury")):
					names.append(who)
					dead_total += 1
					continue
			if _can_hurt and bool(_citizens.call("injure_citizen", id, injury_severity)):
				hurt += 1
				hurt_total += 1
		row["dead"] = names
		row["hurt"] = hurt
	ledger.append(row)
	while ledger.size() > KEEP:
		ledger.remove_at(0)
	return row


## Everything the ledger holds from `since` onward — one night, when [P08] passes
## the tick it went dark.
func since(tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in ledger:
		if int(row.get("tick", 0)) >= tick:
			out.append(row)
	return out


## The morning's sentence: what is missing from the wall, and who is not at it.
## Empty string when the night cost nothing, so a caller can test it directly.
func summary(rows: Array[Dictionary]) -> String:
	if rows.is_empty():
		return ""
	var by_label: Dictionary[String, int] = {}
	var names: Array[String] = []
	var hurt: int = 0
	for row: Dictionary in rows:
		var label: String = String(row.get("label", "a structure"))
		by_label[label] = int(by_label.get(label, 0)) + 1
		for n: Variant in (row.get("dead", []) as Array):
			names.append(String(n))
		hurt += int(row.get("hurt", 0))
	var keys: Array = by_label.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for k: String in keys:
		var n2: int = by_label[k]
		parts.append(k if n2 == 1 else "%s x%d" % [k, n2])
	var out: String = "Gone by morning: %s." % ", ".join(parts)
	if not names.is_empty():
		names.sort()
		var who: String = ", ".join(PackedStringArray(names.slice(0, 4)))
		if names.size() > 4:
			who += " and %d more" % (names.size() - 4)
		out += " %s did not come out." % who
	if hurt > 0:
		out += " %d hurt." % hurt
	return out


## Everyone standing on the footprint, or one tile off it, when it came down.
## Sorted by [P05], capped here, so the same seed catches the same people.
func _caught_in(cells: Array[Vector2i]) -> PackedInt32Array:
	if not _can_find or cells.is_empty():
		return PackedInt32Array()
	var lo: Vector2i = cells[0]
	var hi: Vector2i = cells[0]
	for c: Vector2i in cells:
		lo.x = mini(lo.x, c.x)
		lo.y = mini(lo.y, c.y)
		hi.x = maxi(hi.x, c.x)
		hi.y = maxi(hi.y, c.y)
	var rect := Rect2i(lo - Vector2i(APRON, APRON),
		hi - lo + Vector2i(APRON * 2 + 1, APRON * 2 + 1))
	var found: PackedInt32Array = _citizens.call("citizens_in_cell_rect", rect)
	if found.size() <= max_caught:
		return found
	return found.slice(0, max_caught)


func _name_of(id: int) -> String:
	if _citizens == null or not _citizens.has_method("citizen_info"):
		return "someone"
	var info: Variant = _citizens.call("citizen_info", id)
	if typeof(info) != TYPE_DICTIONARY:
		return "someone"
	return String((info as Dictionary).get("name", "someone"))


func metrics() -> Dictionary:
	return {"toll_dead": dead_total, "toll_hurt": hurt_total, "toll_rows": ledger.size()}

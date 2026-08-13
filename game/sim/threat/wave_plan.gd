class_name WavePlan
extends RefCounted
## One composed night, start to finish.
##
## The plan is built once, at dawn of the day it belongs to, and then never
## re-rolled. That is what makes the telegraph honest: what the player is warned
## about at midday is exactly what walks out of the dark at nightfall, and a
## post-mortem of a lost night can be read straight off this object.

var wave: int = 0
var day: int = 0

## Absolute sim tick at which the attack begins.
var night_start_tick: int = 0
## Absolute sim tick after which survivors withdraw. Dawn.
var dawn_tick: int = 0

## Budget points the night was allowed...
var budget: float = 0.0
## ...and what the composer actually managed to spend. The remainder is the
## change the plain could not break; it is reported, never quietly kept.
var spent: float = 0.0
## Every multiplier that produced `budget`, as {name: value} plus a reasons
## array of plain sentences. This is the "legible in hindsight" contract.
var breakdown: Dictionary = {}

var shape: StringName = &"column"
var set_piece: bool = false
var title: String = ""
## True when this night was deliberately moved onto a Great Frost.
var storm_synced: bool = false
var storm_title: String = ""
var storm_intensity: float = 0.0

var vectors: Array[ThreatVector] = []
var groups: Array[WaveGroup] = []

## Telegraph rungs already fired, index-aligned with the profile's ladder.
var warnings_fired: int = 0
## Highest precision the player has been given so far, -1 before the first rung.
var precision: int = -1
## True once the set-piece day-ahead notice has gone out.
var notice_fired: bool = false
## False while the vectors are provisional. The plain commits to where it is
## coming from at the first warning; after that the telegraph cannot lie.
var locked: bool = false
## Composition as the composer produced it, before it was split across vectors.
## Kept so a re-lock can redistribute without re-rolling the night.
var composition: Array[Dictionary] = []


func unit_count() -> int:
	var n: int = 0
	for g: WaveGroup in groups:
		n += g.count
	return n


func kinds() -> Array[StringName]:
	var seen: Dictionary[StringName, bool] = {}
	for g: WaveGroup in groups:
		seen[g.enemy] = true
	var keys: Array = seen.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


## Units per enemy id, sorted. What the preview and the post-mortem quote.
func counts_by_kind() -> Dictionary:
	var out: Dictionary = {}
	for g: WaveGroup in groups:
		out[String(g.enemy)] = int(out.get(String(g.enemy), 0)) + g.count
	var keys: Array = out.keys()
	keys.sort()
	var sorted: Dictionary = {}
	for k: String in keys:
		sorted[k] = out[k]
	return sorted


func vector_of(index: int) -> ThreatVector:
	if index < 0 or index >= vectors.size():
		return null
	return vectors[index]


## Compass labels of every vector carrying anything, worst first.
func direction_labels() -> PackedStringArray:
	var order: Array[ThreatVector] = vectors.duplicate()
	order.sort_custom(func(a: ThreatVector, b: ThreatVector) -> bool:
		if absf(a.share - b.share) > 0.0001:
			return a.share > b.share
		return a.index < b.index)
	var out: PackedStringArray = PackedStringArray()
	for v: ThreatVector in order:
		if v.share > 0.0001:
			out.append(v.label())
	return out


## Human phrase for a list of directions: "the east", "the east and the north".
func direction_phrase(limit: int = 3) -> String:
	var labels: PackedStringArray = direction_labels()
	if labels.is_empty():
		return "the dark"
	var take: int = mini(limit, labels.size())
	if take == 1:
		return labels[0]
	var head: PackedStringArray = PackedStringArray()
	for i: int in take - 1:
		head.append(labels[i])
	return "%s and %s" % [", ".join(head), labels[take - 1]]


func band_label() -> String:
	return ThreatDefs.band_label(budget)


## Composition described by role rather than by name — what precision 2 buys.
func role_phrase() -> String:
	var by_role: Dictionary = {}
	for g: WaveGroup in groups:
		var def: EnemyDef = Registry.get_item("enemies", g.enemy) as EnemyDef
		var r: String = String(def.role) if def != null else "line"
		by_role[r] = int(by_role.get(r, 0)) + g.count
	if by_role.is_empty():
		return "movement"
	var keys: Array = by_role.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for k: String in keys:
		parts.append("%s %s" % [str(by_role[k]), k])
	return ", ".join(parts)


## Named composition — precision 3. "18 husks, 4 breakers".
func detail_phrase() -> String:
	var parts: PackedStringArray = PackedStringArray()
	var counts: Dictionary = counts_by_kind()
	var keys: Array = counts.keys()
	keys.sort()
	for k: String in keys:
		var def: EnemyDef = Registry.get_item("enemies", StringName(k)) as EnemyDef
		var name: String = def.plural() if def != null else k
		parts.append("%d %s" % [int(counts[k]), name])
	if parts.is_empty():
		return "nothing that stayed to be counted"
	return ", ".join(parts)


## Full record. Saves, the harness dump and the post-mortem read this.
func to_dict() -> Dictionary:
	var vs: Array = []
	for v: ThreatVector in vectors:
		vs.append(v.to_dict())
	var gs: Array = []
	for g: WaveGroup in groups:
		gs.append(g.to_dict())
	return {
		"wave": wave,
		"day": day,
		"night_start": night_start_tick,
		"dawn": dawn_tick,
		"budget": snappedf(budget, 0.01),
		"spent": snappedf(spent, 0.01),
		"breakdown": breakdown,
		"shape": String(shape),
		"set_piece": set_piece,
		"title": title,
		"storm_synced": storm_synced,
		"storm_title": storm_title,
		"storm_intensity": snappedf(storm_intensity, 0.001),
		"units": unit_count(),
		"composition": counts_by_kind(),
		"vectors": vs,
		"groups": gs,
		"warnings_fired": warnings_fired,
		"precision": precision,
		"notice_fired": notice_fired,
		"locked": locked,
	}


static func from_dict(d: Dictionary) -> WavePlan:
	var p := WavePlan.new()
	p.wave = int(d.get("wave", 0))
	p.day = int(d.get("day", 0))
	p.night_start_tick = int(d.get("night_start", 0))
	p.dawn_tick = int(d.get("dawn", 0))
	p.budget = float(d.get("budget", 0.0))
	p.spent = float(d.get("spent", 0.0))
	var b: Variant = d.get("breakdown", {})
	p.breakdown = b if typeof(b) == TYPE_DICTIONARY else {}
	p.shape = StringName(String(d.get("shape", "column")))
	p.set_piece = bool(d.get("set_piece", false))
	p.title = String(d.get("title", ""))
	p.storm_synced = bool(d.get("storm_synced", false))
	p.storm_title = String(d.get("storm_title", ""))
	p.storm_intensity = float(d.get("storm_intensity", 0.0))
	for raw: Variant in d.get("vectors", []):
		if typeof(raw) == TYPE_DICTIONARY:
			p.vectors.append(ThreatVector.from_dict(raw))
	for raw: Variant in d.get("groups", []):
		if typeof(raw) == TYPE_DICTIONARY:
			p.groups.append(WaveGroup.from_dict(raw))
	p.warnings_fired = int(d.get("warnings_fired", 0))
	p.precision = int(d.get("precision", -1))
	p.notice_fired = bool(d.get("notice_fired", false))
	return p

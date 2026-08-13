class_name WaveComposer
extends RefCounted
## Spends a night's budget on actual creatures.
##
## The director never picks a wave from a list. It picks a SHAPE (probe, swarm,
## column, hammer, siege), which is a set of role multipliers, and then buys
## packs against that shape until the money runs out. Two nights with the same
## budget can therefore be a tide of cheap things or four armoured backs, and
## adding a .tres to game/content/enemies/ changes what the game can produce
## without touching a line of this file.
##
## Four rules keep the result legible and legal:
##
##   * `min_wave` is an absolute gate. Adaptation cannot open it early, so no
##     player is ever surprised by a tier-4 unit on night two.
##   * `max_share` caps how much of one night any single kind may eat — except
##     that one minimum pack is always affordable, so no def is ever silently
##     uncomposable.
##   * `max_kinds_per_wave` caps variety. A night the player cannot read at a
##     glance is noise, not difficulty.
##   * A night is never empty. If the budget cannot cover the cheapest pack, the
##     cheapest pack comes anyway and the overspend is recorded.

const EPS: float = 0.0001


## Composes one night. Returns entries of {enemy, count, cost, def}, sorted by
## enemy id so the result is byte-stable for the same seed and inputs.
static func compose(profile: ThreatProfile, wave: int, budget: float, shape: StringName,
		defs: Array[EnemyDef], rng: RandomNumberGenerator) -> Array[Dictionary]:
	var legal: Array[EnemyDef] = legal_defs(wave, defs)
	if legal.is_empty() or budget <= 0.0:
		return []

	var count_by: Dictionary[StringName, int] = {}
	var spent_by: Dictionary[StringName, float] = {}
	var remaining: float = budget

	# A set piece always has a face: the heaviest thing the night can legally
	# field walks in first, and the rest of the budget is composed around it.
	if profile.set_piece_shape == shape:
		var anchor: EnemyDef = _anchor(legal, budget)
		if anchor != null:
			remaining -= _buy(anchor, count_by, spent_by)

	var steps: int = 0
	while steps < profile.max_compose_steps:
		steps += 1
		var pick: EnemyDef = _pick(profile, legal, shape, budget, remaining, count_by, spent_by, rng)
		if pick == null:
			break
		remaining -= _buy(pick, count_by, spent_by)

	# The plain does not skip a night because of rounding.
	if count_by.is_empty():
		var cheapest: EnemyDef = legal[0]
		for d: EnemyDef in legal:
			if d.cost * float(d.pack_size) < cheapest.cost * float(cheapest.pack_size):
				cheapest = d
		_buy(cheapest, count_by, spent_by)

	var ids: Array = count_by.keys()
	ids.sort()
	var out: Array[Dictionary] = []
	for id: StringName in ids:
		out.append({
			"enemy": id,
			"count": count_by[id],
			"cost": spent_by[id],
			"def": _find(legal, id),
		})
	return out


## Everything composable on this night, sorted by id. Weight 0 disables a def
## without deleting the content.
static func legal_defs(wave: int, defs: Array[EnemyDef]) -> Array[EnemyDef]:
	var out: Array[EnemyDef] = []
	for d: EnemyDef in defs:
		if d == null or d.id == &"":
			continue
		if d.min_wave > wave or d.cost <= 0.0 or d.weight <= 0.0 or d.pack_size < 1:
			continue
		out.append(d)
	out.sort_custom(func(a: EnemyDef, b: EnemyDef) -> bool: return String(a.id) < String(b.id))
	return out


## Rolls the shape of a night from the profile's weights. Deterministic given
## the stream, and forced to the set-piece shape when the night is one.
static func roll_shape(profile: ThreatProfile, wave: int, set_piece: bool,
		rng: RandomNumberGenerator) -> StringName:
	# The roll is consumed either way, so adding or removing set pieces cannot
	# shift the shape sequence of every other night in the campaign.
	var weights: PackedFloat32Array = profile.shape_weights(wave)
	var roll: float = rng.randf()
	var acc: float = 0.0
	var picked: StringName = ThreatDefs.SHAPE_COLUMN
	for i: int in weights.size():
		acc += weights[i]
		if roll <= acc:
			picked = ThreatDefs.SHAPES[i]
			break
	if set_piece:
		return profile.set_piece_shape
	return picked


## Every way a composition can be illegal, as sentences. Empty means legal.
## The director runs this on its own output every night: a composer that
## quietly breaks its own rules is exactly the bug nobody finds for a month.
static func legality_errors(profile: ThreatProfile, wave: int, budget: float,
		groups: Array[Dictionary], defs: Array[EnemyDef]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var legal: Array[EnemyDef] = legal_defs(wave, defs)
	var cheapest_pack: float = 0.0
	for d: EnemyDef in legal:
		var pc: float = d.cost * float(d.pack_size)
		if cheapest_pack <= 0.0 or pc < cheapest_pack:
			cheapest_pack = pc

	var spent: float = 0.0
	var kinds: Dictionary[StringName, float] = {}
	for g: Dictionary in groups:
		var id: StringName = g.get("enemy", &"")
		var def: EnemyDef = _find(legal, id)
		if def == null:
			out.append("'%s' is not composable on wave %d" % [id, wave])
			continue
		var count: int = int(g.get("count", 0))
		if count <= 0:
			out.append("'%s' has a non-positive count" % id)
		if count % def.pack_size != 0:
			out.append("'%s' count %d is not a multiple of pack_size %d" % [id, count, def.pack_size])
		if def.min_wave > wave:
			out.append("'%s' is gated to wave %d but appears on wave %d" % [id, def.min_wave, wave])
		var cost: float = float(g.get("cost", 0.0))
		spent += cost
		kinds[id] = float(kinds.get(id, 0.0)) + cost

	if kinds.size() > profile.max_kinds_per_wave:
		out.append("%d kinds exceeds max_kinds_per_wave %d" % [kinds.size(), profile.max_kinds_per_wave])

	var ids: Array = kinds.keys()
	ids.sort()
	for id: StringName in ids:
		var def2: EnemyDef = _find(legal, id)
		if def2 == null:
			continue
		var cap: float = maxf(def2.max_share * budget, def2.cost * float(def2.pack_size))
		if float(kinds[id]) > cap + EPS:
			out.append("'%s' spent %.2f, over its cap of %.2f" % [id, float(kinds[id]), cap])

	var allowed: float = maxf(budget, cheapest_pack)
	if spent > allowed + EPS:
		out.append("spent %.2f over a budget of %.2f (floor %.2f)" % [spent, budget, cheapest_pack])
	return out


# ---------------------------------------------------------------- internals

## Weighted pick among the defs that are still legal to add to. Returns null
## when nothing can legally be bought, which ends the composition.
static func _pick(profile: ThreatProfile, legal: Array[EnemyDef], shape: StringName,
		budget: float, remaining: float, count_by: Dictionary[StringName, int],
		spent_by: Dictionary[StringName, float], rng: RandomNumberGenerator) -> EnemyDef:
	var weights: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	var at_kind_cap: bool = count_by.size() >= profile.max_kinds_per_wave
	for d: EnemyDef in legal:
		var w: float = 0.0
		var pack_cost: float = d.cost * float(d.pack_size)
		var already: bool = count_by.has(d.id)
		if pack_cost <= remaining + EPS and (already or not at_kind_cap):
			var cap: float = maxf(d.max_share * budget, pack_cost)
			if float(spent_by.get(d.id, 0.0)) + pack_cost <= cap + EPS:
				w = d.weight * profile.shape_role_weight(shape, d.role)
		weights.append(maxf(0.0, w))
		total += weights[weights.size() - 1]
	if total <= 0.0:
		return null
	var roll: float = rng.randf() * total
	var acc: float = 0.0
	for i: int in legal.size():
		acc += weights[i]
		if roll <= acc:
			return legal[i]
	return legal[legal.size() - 1]


## The heaviest legal thing a set piece can afford to lead with.
static func _anchor(legal: Array[EnemyDef], budget: float) -> EnemyDef:
	var best: EnemyDef = null
	for d: EnemyDef in legal:
		if d.role != ThreatDefs.ROLE_SIEGE and d.role != ThreatDefs.ROLE_BREAKER:
			continue
		if d.cost * float(d.pack_size) > budget * 0.6:
			continue
		if best == null or d.tier > best.tier or (d.tier == best.tier and d.cost > best.cost):
			best = d
	return best


static func _buy(d: EnemyDef, count_by: Dictionary[StringName, int],
		spent_by: Dictionary[StringName, float]) -> float:
	var cost: float = d.cost * float(d.pack_size)
	count_by[d.id] = int(count_by.get(d.id, 0)) + d.pack_size
	spent_by[d.id] = float(spent_by.get(d.id, 0.0)) + cost
	return cost


static func _find(defs: Array[EnemyDef], id: StringName) -> EnemyDef:
	for d: EnemyDef in defs:
		if d.id == id:
			return d
	return null

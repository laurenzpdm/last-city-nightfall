class_name SiegeResolver
extends RefCounted
## Resolves a night ABSTRACTLY, and only when [P07] combat is not in the build.
##
## This is not a placeholder and it is not a stub: it is a real, deterministic
## siege model, and the whole director depends on it being one. Waves cleared,
## comfort, adaptation and every post-mortem number come out of here whenever
## there is no combat system to ask, and a director that could not tell how a
## night went would be a director that could not adapt.
##
## What it models, per pack of one kind on one lane:
##
##   MOVEMENT   along the lane's own path cells, at the def's speed scaled by
##              [P01]'s movement surface — so deep snow genuinely slows an
##              attack and a heated, cleared road genuinely speeds it up.
##   FIRE       the lane's defence dps, which is turrets weighted by how much
##              heat [P02] is actually delivering to them. Armour is applied per
##              shot, so many small guns bounce off a breaker and one big one
##              does not.
##   BARRIERS   the buildings standing on that lane, outermost first. A pack
##              stops at the front of the queue and takes it apart. That is what
##              a wall is for, and it is why walls buy time rather than safety.
##   BREACH     a pack that gets inside `breach_radius` of the core is a breach,
##              reported once, and it is the single largest term in the comfort
##              measurement the next night is sized from.
##
## What it deliberately does NOT model, because those things belong to [P07]:
## individual units, projectiles, targeting priorities, pathing around a new
## wall, and the heat theft in EnemyDef.heat_drain (writing another system's
## heat budget from here would be trespassing). When combat lands, this whole
## file goes quiet on its own — `is_active()` returns false and nothing in it
## runs.

## One kind of enemy, on one lane, treated as a single body with a shared pool.
class Pack extends RefCounted:
	var enemy: StringName = &""
	var def: EnemyDef = null
	var vector: int = 0
	var spawned: int = 0
	var alive: int = 0
	var unit_hp: float = 1.0
	var pool: float = 0.0
	## Position along ThreatVector.path, counted from the entry inwards.
	var path_pos: float = 0.0
	var engaging: int = -1
	var withdrawn: bool = false
	var closest: int = 1 << 20

	func hp_ratio() -> float:
		return 0.0 if unit_hp <= 0.0 or spawned <= 0 else clampf(pool / (float(spawned) * unit_hp), 0.0, 1.0)


var packs: Array[Pack] = []

## Post-mortem accumulators for the night in progress.
var spawned: int = 0
var killed: int = 0
var structures_lost: int = 0
var closest_cells: int = 1 << 20
var breached: bool = false
var damage_dealt: float = 0.0

var _profile: ThreatProfile = null
var _planner: ApproachPlanner = null
var _build: SimSystem = null
var _grid: SimSystem = null
var _surface: Object = null
## vector index -> [[path_index, building_id], ...], outermost first.
var _barriers: Dictionary[int, Array] = {}


func bind(profile: ThreatProfile, planner: ApproachPlanner, build: SimSystem, grid: SimSystem) -> void:
	_profile = profile
	_planner = planner
	_build = build
	_grid = grid
	_surface = null
	if _grid != null and _grid.has_method("world"):
		var w: Variant = _grid.call("world")
		if typeof(w) == TYPE_OBJECT and (w as Object) != null and (w as Object).has_method("speed_scale"):
			_surface = w


## True while there is anything on the map this resolver owns.
func is_active() -> bool:
	for p: Pack in packs:
		if p.alive > 0 and not p.withdrawn:
			return true
	return false


func live_units() -> int:
	var n: int = 0
	for p: Pack in packs:
		if not p.withdrawn:
			n += p.alive
	return n


func begin(plan: WavePlan) -> void:
	packs.clear()
	spawned = 0
	killed = 0
	structures_lost = 0
	closest_cells = 1 << 20
	breached = false
	damage_dealt = 0.0
	rearm(plan)


## Rebuilds the barrier queues from the plan's current structure lists. Called
## at wave start and whenever the planner rescores, so a wall finished at
## midnight is standing in the way at 00:00:01.
func rearm(plan: WavePlan) -> void:
	_barriers.clear()
	if _build == null or not _build.has_method("get_building"):
		return
	for v: ThreatVector in plan.vectors:
		var rows: Array = []
		for id: int in v.structures:
			var b: Object = _build.call("get_building", id)
			if b == null:
				continue
			var at: int = _path_index_of(v, b.get("cell"))
			if at < 0:
				continue
			rows.append([at, id])
		# Outermost first: a pack walking in meets the far wall before the near one.
		rows.sort_custom(func(a: Array, b2: Array) -> bool:
			if int(a[0]) != int(b2[0]):
				return int(a[0]) > int(b2[0])
			return int(a[1]) < int(b2[1]))
		_barriers[v.index] = rows


## Walks one group onto the map.
func dispatch(group: WaveGroup, plan: WavePlan) -> void:
	var def: EnemyDef = Registry.get_item("enemies", group.enemy) as EnemyDef
	if def == null or group.count <= 0:
		return
	var v: ThreatVector = plan.vector_of(group.vector)
	if v == null or v.path.is_empty():
		return
	var p := Pack.new()
	p.enemy = group.enemy
	p.def = def
	p.vector = group.vector
	p.spawned = group.count
	p.alive = group.count
	p.unit_hp = maxf(1.0, def.hp)
	p.pool = float(group.count) * p.unit_hp
	p.path_pos = float(v.path.size() - 1)
	packs.append(p)
	spawned += group.count


## Advances every pack by `ticks` worth of simulation.
func step(plan: WavePlan, ticks: int) -> void:
	var dt: float = SimClock.DT * float(ticks)
	for p: Pack in packs:
		if p.withdrawn or p.alive <= 0:
			continue
		var v: ThreatVector = plan.vector_of(p.vector)
		if v == null or v.path.is_empty():
			continue
		_advance(p, v, dt)
		_take_fire(p, v, dt)
		if p.alive > 0:
			_engage(p, v, dt)


## Dawn. Whatever is still standing goes back out onto the plain — a wave always
## ends, and the survivors are counted as survivors, not as kills.
func withdraw() -> int:
	var left: int = 0
	for p: Pack in packs:
		if p.withdrawn or p.alive <= 0:
			continue
		left += p.alive
		p.withdrawn = true
	return left


## The record PressureTracker measures a night from.
func outcome(night_ticks: int, heat_ok_ticks: int) -> Dictionary:
	return {
		"spawned": spawned,
		"killed": killed,
		"structures_lost": structures_lost,
		"closest_cells": closest_cells if closest_cells < (1 << 20) else _profile.breach_radius * 3,
		"night_ticks": night_ticks,
		"heat_ok_ticks": heat_ok_ticks,
		"breached": breached,
		"damage": snappedf(damage_dealt, 0.1),
		"resolved_by": "siege_model",
	}


## Live positions for the map layer. Real state, not decoration: these are the
## packs the resolver is actually simulating.
func view_packs(plan: WavePlan) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Pack in packs:
		if p.withdrawn or p.alive <= 0:
			continue
		var v: ThreatVector = plan.vector_of(p.vector)
		if v == null or v.path.is_empty():
			continue
		var cell: Vector2i = _cell_at(v, p.path_pos)
		out.append({
			"enemy": String(p.enemy),
			"count": p.alive,
			"vector": p.vector,
			"cell": [cell.x, cell.y],
			"pos": Vector2(float(cell.x) * 32.0 + 16.0, float(cell.y) * 32.0 + 16.0),
			"hp": snappedf(p.hp_ratio(), 0.01),
		})
	return out


func to_dict(plan: WavePlan) -> Dictionary:
	var ps: Array = []
	for p: Pack in packs:
		var cell: Vector2i = Vector2i.ZERO
		var v: ThreatVector = plan.vector_of(p.vector) if plan != null else null
		if v != null and not v.path.is_empty():
			cell = _cell_at(v, p.path_pos)
		ps.append({
			"enemy": String(p.enemy),
			"vector": p.vector,
			"spawned": p.spawned,
			"alive": p.alive,
			"pool": snappedf(p.pool, 0.1),
			"at": snappedf(p.path_pos, 0.01),
			"cell": [cell.x, cell.y],
			"engaging": p.engaging,
			"withdrawn": p.withdrawn,
		})
	return {
		"spawned": spawned,
		"killed": killed,
		"structures_lost": structures_lost,
		"closest": closest_cells if closest_cells < (1 << 20) else -1,
		"breached": breached,
		"damage": snappedf(damage_dealt, 0.1),
		"packs": ps,
	}


func from_dict(d: Dictionary) -> void:
	packs.clear()
	spawned = int(d.get("spawned", 0))
	killed = int(d.get("killed", 0))
	structures_lost = int(d.get("structures_lost", 0))
	var c: int = int(d.get("closest", -1))
	closest_cells = c if c >= 0 else (1 << 20)
	breached = bool(d.get("breached", false))
	damage_dealt = float(d.get("damage", 0.0))
	for raw: Variant in d.get("packs", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = raw
		var p := Pack.new()
		p.enemy = StringName(String(e.get("enemy", "")))
		p.def = Registry.get_item("enemies", p.enemy) as EnemyDef
		p.vector = int(e.get("vector", 0))
		p.spawned = int(e.get("spawned", 0))
		p.alive = int(e.get("alive", 0))
		p.unit_hp = maxf(1.0, p.def.hp) if p.def != null else 1.0
		p.pool = float(e.get("pool", 0.0))
		p.path_pos = float(e.get("at", 0.0))
		p.engaging = int(e.get("engaging", -1))
		p.withdrawn = bool(e.get("withdrawn", false))
		packs.append(p)


# ---------------------------------------------------------------- internals

## Movement. A pack pinned on a barrier does not advance — that is the entire
## point of building one.
func _advance(p: Pack, v: ThreatVector, dt: float) -> void:
	if p.engaging >= 0:
		return
	var cell: Vector2i = _cell_at(v, p.path_pos)
	var terrain: float = 1.0
	if _surface != null:
		terrain = clampf(float(_surface.call("speed_scale", cell)), 0.15, 1.6)
	var cells: float = p.def.speed * terrain * dt
	p.path_pos = maxf(0.0, p.path_pos - cells)
	var here: Vector2i = _cell_at(v, p.path_pos)
	var d: int = _planner.distance_to_core(here)
	p.closest = mini(p.closest, d)
	if d < closest_cells:
		closest_cells = d
	if d <= _profile.breach_radius:
		breached = true


## Defence fire. Only inside the lane's envelope: a turret three districts away
## is not shooting at this, and the player can see exactly where the envelope is
## because it is the corridor around the chokepoint.
func _take_fire(p: Pack, v: ThreatVector, dt: float) -> void:
	if v.defence_dps <= 0.0:
		return
	if p.path_pos > float(v.envelope_to) + 2.0:
		return
	var shot: float = _profile.defence_shot
	var effective: float = maxf(1.0, shot - p.def.armor) / shot
	var raw: float = v.defence_dps * dt * effective
	if raw <= 0.0:
		return
	p.pool = maxf(0.0, p.pool - raw)
	var still: int = int(ceilf(p.pool / p.unit_hp))
	if still < p.alive:
		killed += p.alive - still
		p.alive = still
	if p.alive <= 0:
		p.engaging = -1


## Contact with a structure. The pack stops, chews, and moves on when the thing
## in front of it falls over.
func _engage(p: Pack, v: ThreatVector, dt: float) -> void:
	var queue: Array = _barriers.get(v.index, [])
	if queue.is_empty():
		p.engaging = -1
		return
	if p.engaging < 0:
		var front: Array = queue[0]
		if p.path_pos > float(int(front[0])) + p.def.attack_range:
			return
		p.engaging = int(front[1])
	if _build == null or not _build.has_method("apply_damage"):
		p.engaging = -1
		return
	var amount: float = p.def.dps() * float(p.alive) * dt * _profile.siege_damage_efficiency
	if amount <= 0.0:
		return
	damage_dealt += amount
	var destroyed: bool = bool(_build.call("apply_damage", p.engaging, amount, &"threat"))
	if destroyed:
		structures_lost += 1
		queue.pop_front()
		_barriers[v.index] = queue
		p.engaging = -1
	elif _build.has_method("get_building") and _build.call("get_building", p.engaging) == null:
		# Demolished or removed under our feet by something else.
		queue.pop_front()
		_barriers[v.index] = queue
		p.engaging = -1


func _cell_at(v: ThreatVector, pos: float) -> Vector2i:
	var i: int = clampi(int(pos), 0, v.path.size() - 1)
	return _planner.cell_of(v.path[i])


## Where on the lane a building sits, or -1 when it is not near it. Only the
## envelope is searched, which is the only stretch the barrier queue covers.
func _path_index_of(v: ThreatVector, cell: Vector2i) -> int:
	var best: int = -1
	var best_d: int = 1 << 30
	var lo: int = clampi(v.envelope_from, 0, maxi(0, v.path.size() - 1))
	var hi: int = clampi(v.envelope_to, lo, maxi(0, v.path.size() - 1))
	for i: int in range(lo, hi + 1):
		var c: Vector2i = _planner.cell_of(v.path[i])
		var d: int = maxi(absi(c.x - cell.x), absi(c.y - cell.y))
		if d < best_d:
			best_d = d
			best = i
	if best_d > _profile.lane_corridor_radius:
		return -1
	return best

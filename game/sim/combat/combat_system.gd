class_name CombatSystem
extends SimSystem
## [P07] Combat — the tower-defence third of the game, and the place where the
## other two thirds get their bill.
##
## What this system owns:
##   * **the swarm** ([EnemySwarm]) — every attacker, stored as packed arrays and
##     moved off shared flow fields, so five hundred bodies cost one field lookup
##     each instead of five hundred searches;
##   * **the siege surface** ([AssaultField]) — a second cost map where a wall is
##     expensive rather than impossible, which is what makes a sealed city get
##     dug into at its weakest panel and a breached one get poured through;
##   * **the guns** ([TurretBattery]) — real target policies, a real turn rate,
##     and a heat magazine that charges at exactly the rate [P02] is serving that
##     building, so a cold wall is an unarmed wall;
##   * **the shells** ([ProjectilePool]) — travel time, lead, splash, burn;
##   * **a stand-in wave director** ([AssaultDirector]) that steps aside the
##     moment [P08] exists.
##
## What it deliberately does not own: placement (that is [P11]), the heat network
## (that is [P02]), the pressure curve (that is [P08]). Every cross-system call in
## this part goes through this file and nowhere else, and each one degrades to a
## documented fallback with a line in the log when its owner is absent.
##
## Contracts other parts use:
##   spawn(kind, cell, count) -> int          [P08] threat drives waves through this
##   enemies_alive() -> int
##   agents_for_view() -> Array[Dictionary]   [P13] renders enemies off this today
##   turret_readout() -> Array[Dictionary]    why every gun is quiet, per gun
##   enemy_render_buffer() -> Dictionary      packed arrays for [P14]
##   entity_at_cell(cell) -> int              [P16] selection

const SYSTEM_ORDER: int = 80
const NAME: StringName = &"combat"
const TAG: String = "combat"
const TILE: float = 32.0

## Enemy ids live above this so a selection or a save can never confuse one with
## a building id ([P11] mints from 1, [P02] from 1_000_000).
const ENEMY_ID_BASE: int = 5_000_000
## Ticks between rescans of [P11]'s building list for turrets.
const TURRET_SYNC_TICKS: int = 10
## Ticks between rebuilds of the tag-indexed target lists a seeker searches.
const TARGET_INDEX_TICKS: int = 30
## Largest ring radius, in tiles, of the untagged "nearest structure" search.
const SEEK_RING_MAX: int = 24
## Damage a structure must have lost before the siege surface calls it a weak point.
const WEAK_AT: float = CombatTypes.BREACH_HEALTH
## Seconds between repeated alerts of the same kind.
const ALERT_EVERY_TICKS: int = 100
## Tags a seeker may be pointed at. Anything else falls back to the ring search.
const INDEXED_TAGS: Array[StringName] = [
	&"conduit", &"turret", &"housing", &"heat_source", &"wall", &"defense",
]

var swarm: EnemySwarm = null
var battery: TurretBattery = null
var shells: ProjectilePool = null
var assault: AssaultField = null
var director: AssaultDirector = null

var wave: int = 0
var damage_taken: float = 0.0        ## structural damage the city has absorbed
var structures_lost: int = 0
var breaches: int = 0
var leaks: int = 0

var _grid: SimSystem = null
var _build: SimSystem = null
var _heat: SimSystem = null
var _climate: SimSystem = null
var _society: SimSystem = null
var _ammo_source: SimSystem = null
var _ammo_method: String = ""
var _society_method: String = ""
var _has_heat: bool = false
var _has_night: bool = false
var _core_cell: Vector2i = Vector2i.ZERO
var _map_w: int = 0
var _map_h: int = 0

var _next_id: int = ENEMY_ID_BASE
var _open_dir: PackedByteArray = PackedByteArray()
var _gcost: PackedByteArray = PackedByteArray()
var _world: Object = null

## tag -> {"id": PackedInt32Array, "x": PackedFloat32Array, "y": PackedFloat32Array}
var _target_index: Dictionary[StringName, Dictionary] = {}
var _weakened: Dictionary[int, bool] = {}
var _agents_cache: Array[Dictionary] = []
var _agents_tick: int = -1
var _discontent_carry: float = 0.0
var _last_alert_tick: Dictionary[StringName, int] = {}
var _defended: bool = false
var _defended_tick: int = -1
var _step_us: int = 0
var _content_ok: bool = false


func _init() -> void:
	order = SYSTEM_ORDER


func system_name() -> StringName:
	return NAME


# =========================================================================
# lifecycle
# =========================================================================

func setup() -> void:
	order = SYSTEM_ORDER
	swarm = EnemySwarm.new()
	battery = TurretBattery.new()
	shells = ProjectilePool.new()
	director = AssaultDirector.new()
	assault = AssaultField.new()
	wave = 0
	damage_taken = 0.0
	structures_lost = 0
	breaches = 0
	leaks = 0
	_next_id = ENEMY_ID_BASE
	_weakened.clear()
	_target_index.clear()
	_last_alert_tick.clear()
	_discontent_carry = 0.0

	for problem: String in swarm.load_defs():
		Log.error(TAG, "enemy content rejected — %s" % problem)
	for problem2: String in battery.load_weapons():
		Log.error(TAG, "weapon content rejected — %s" % problem2)
	_content_ok = swarm.def_count > 0 and battery.weapons.size() > 0
	if swarm.def_count == 0:
		Log.warn(TAG, "no enemy definitions in game/content/enemies — nothing will attack")
	if battery.weapons.is_empty():
		Log.warn(TAG, "no weapon definitions in game/content/weapons — every mount is a decoration")


func post_setup() -> void:
	_grid = Sim.get_system(&"grid")
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_climate = Sim.get_system(&"climate")
	_society = Sim.get_system(&"society")
	_has_heat = _heat != null and _heat.has_method("served_of") and _heat.has_method("has_building")
	_has_night = _climate != null and _climate.has_method("is_night")

	if _grid != null and _grid.has_method("world"):
		_world = _grid.call("world")
		if _world != null:
			_map_w = int(_world.get("width"))
			_map_h = int(_world.get("height"))
			_gcost = _world.get("cost")
		_core_cell = _grid.call("core_cell")
		var open: FlowField = _grid.call("get_field", GridSystem.CORE_FIELD)
		if open != null:
			_open_dir = open.direction
	swarm.bind_world(_map_w, _map_h, _core_cell)

	_resolve_ammo_source()
	_resolve_society()

	var threat: SimSystem = Sim.get_system(&"threat")
	director.enabled = threat == null
	Log.info(TAG, "ready — %d enemy kinds, %d weapons, grid=%s build=%s heat=%s climate=%s" % [
		swarm.def_count, battery.weapons.size(),
		str(_grid != null), str(_build != null), str(_has_heat), str(_has_night)])
	if not _has_heat:
		Log.warn(TAG, "no [P02] heat system — turret magazines charge for free, "
			+ "so nothing here costs the city any warmth")
	if _ammo_source == null:
		Log.info(TAG, "no [P03]/[P04] ammunition source — turrets run on unlimited "
			+ "ammunition until one exists")
	else:
		Log.info(TAG, "ammunition drawn from '%s' via %s()" % [
			_ammo_source.system_name(), _ammo_method])
	if director.enabled:
		Log.info(TAG, "no [P08] threat system — combat is driving its own fallback "
			+ "assault director; it opens a front only once the city has a perimeter")
	else:
		Log.info(TAG, "[P08] threat present — the fallback director stays out of the way")


func step(tick: int) -> void:
	var t0: int = Time.get_ticks_usec()   # lint:allow log + metrics-free profiling only
	if tick % TURRET_SYNC_TICKS == 0:
		_sync_turrets()
	if tick % TARGET_INDEX_TICKS == 0:
		_rebuild_target_index()

	_run_director(tick)

	if swarm.count > 0 or assault.ready:
		assault.maintain(_grid)
	if swarm.count > 0:
		swarm.reindex()
		swarm.apply_auras(self)
		swarm.step(tick, self, _gcost, _open_dir, assault, _heat if _has_heat else null, _world)
		swarm.apply_pressure(self)

	battery.step(tick, self, swarm, shells, assault)
	if shells.count > 0:
		battery.damage_dealt += shells.step(tick, swarm)

	_drain_spawn_requests(tick)
	_publish_deaths()
	if swarm.count > 0:
		swarm.compact()
	_flush_discontent()
	_step_us = Time.get_ticks_usec() - t0   # lint:allow never reaches serialize()/metrics()


# =========================================================================
# public API — [P08] threat and the scenarios drive combat through these
# =========================================================================

## Puts `count` of `kind` on the map around `cell`. Returns how many arrived.
## This is the entry point [P08] is expected to call.
func spawn(kind: StringName, cell: Vector2i, count: int = 1) -> int:
	var slot: int = swarm.def_slot(kind)
	if slot < 0:
		Log.warn(TAG, "no enemy definition '%s'" % kind)
		return 0
	return _spawn_slot(slot, Grid.cell_to_world(cell), count, SimClock.tick)


## Spawns onto the approach lane nearest `heading`, or a random lane when the
## map has none. Lanes are [P01]'s record of the old highways into the basin.
func spawn_on_lane(kind: StringName, lane_seed: int, count: int = 1) -> int:
	var slot: int = swarm.def_slot(kind)
	if slot < 0:
		return 0
	return _spawn_slot(slot, _lane_point(lane_seed), count, SimClock.tick)


func enemies_alive() -> int:
	return swarm.count


func enemy_kinds() -> Array[StringName]:
	var out: Array[StringName] = []
	for i: int in range(swarm.def_count):
		out.append(swarm.d_id[i])
	return out


func has_enemy_kind(kind: StringName) -> bool:
	return swarm.has_kind(kind)


func enemy_def(kind: StringName) -> EnemyDef:
	return swarm.def_resource(swarm.def_slot(kind))


func weapon_def(id: StringName) -> WeaponDef:
	return battery.weapon_of(id)


func turret_count() -> int:
	return battery.count()


## Fraction of turret-ticks that actually produced damage. The one number that
## answers "is my wall armed?".
func turret_uptime() -> float:
	return battery.uptime()


## Heat units the defence has burned since world creation.
func heat_spent_on_defence() -> float:
	return battery.heat_spent


## Per-gun explanation of why it is or is not shooting. The combat half of the
## legibility contract; [P17]/[P19] can render this directly.
func turret_readout() -> Array[Dictionary]:
	return battery.readout()


## Which kinds are on the map right now, by id.
func threat_census() -> Dictionary:
	return swarm.census()


## Packed arrays for [P14]: positions, headings, health fractions and def slots.
func enemy_render_buffer() -> Dictionary:
	var n: int = swarm.count
	var ids: PackedInt32Array = PackedInt32Array()
	var xs: PackedFloat32Array = PackedFloat32Array()
	var ys: PackedFloat32Array = PackedFloat32Array()
	var hx: PackedFloat32Array = PackedFloat32Array()
	var hy: PackedFloat32Array = PackedFloat32Array()
	var hp: PackedFloat32Array = PackedFloat32Array()
	var kinds: PackedInt32Array = PackedInt32Array()
	ids.resize(n)
	xs.resize(n)
	ys.resize(n)
	hx.resize(n)
	hy.resize(n)
	hp.resize(n)
	kinds.resize(n)
	for i: int in range(n):
		ids[i] = swarm.e_id[i]
		xs[i] = swarm.e_x[i]
		ys[i] = swarm.e_y[i]
		hx[i] = swarm.e_hx[i]
		hy[i] = swarm.e_hy[i]
		hp[i] = swarm.health_fraction(i)
		kinds[i] = swarm.e_def[i]
	return {"count": n, "id": ids, "x": xs, "y": ys, "hx": hx, "hy": hy,
		"health": hp, "def": kinds}


func turret_render_buffer() -> Dictionary:
	return battery.render_buffer()


func projectile_render_buffer() -> Dictionary:
	return shells.render_buffer()


## [P13]'s world model polls this every tick. `kind` is the render archetype the
## sprite factory bakes agents for, not the enemy id, so enemies draw correctly
## today with no change on the view side.
func agents_for_view() -> Array[Dictionary]:
	if _agents_tick == SimClock.tick:
		return _agents_cache
	var out: Array[Dictionary] = []
	for i: int in range(swarm.count):
		if swarm.e_hidden[i] == 1:
			continue
		out.append({
			"id": swarm.e_id[i],
			"kind": swarm.d_arch[swarm.e_def[i]],
			"pos": Vector2(swarm.e_x[i], swarm.e_y[i]),
			"threat": swarm.d_id[swarm.e_def[i]],
			"health": swarm.health_fraction(i),
		})
	_agents_cache = out
	_agents_tick = SimClock.tick
	return out


## --- selection contract ([P16] duck-types these) --------------------------

## Enemy id standing on a tile, or -1.
func entity_at_cell(cell: Vector2i) -> int:
	var centre: Vector2 = Grid.cell_to_world(cell)
	for i: int in swarm.query(centre, TILE):
		if swarm.e_state[i] == CombatTypes.EnemyState.SPENT or swarm.e_hidden[i] == 1:
			continue
		if int(swarm.e_x[i] / TILE) == cell.x and int(swarm.e_y[i] / TILE) == cell.y:
			return swarm.e_id[i]
	return -1


func entities_in_cell_rect(rect: Rect2i) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in range(swarm.count):
		if swarm.e_hidden[i] == 1:
			continue
		var c := Vector2i(int(swarm.e_x[i] / TILE), int(swarm.e_y[i] / TILE))
		if rect.has_point(c):
			out.append(swarm.e_id[i])
	out.sort()
	return out


## Everything the inspector needs about one enemy, or an empty dictionary.
func describe_enemy(enemy_id: int) -> Dictionary:
	var slot: int = swarm.slot_of(enemy_id)
	if slot < 0:
		return {}
	var d: int = swarm.e_def[slot]
	var res: EnemyDef = swarm.def_resource(d)
	return {
		"id": enemy_id,
		"kind": String(swarm.d_id[d]),
		"name": swarm.d_name[d],
		"description": res.description if res != null else "",
		"behaviour": String(CombatTypes.behaviour_name(swarm.d_behaviour[d])),
		"hp": snappedf(swarm.e_hp[slot], 0.1),
		"max_hp": snappedf(swarm.d_health[d], 0.1),
		"armour": snappedf(swarm.d_armour[d], 0.1),
		"pos": [snappedf(swarm.e_x[slot], 0.1), snappedf(swarm.e_y[slot], 0.1)],
		"target": swarm.e_target[slot],
		"burning": swarm.e_burn[slot] > 0.0,
		"hidden": swarm.e_hidden[slot] == 1,
	}


# =========================================================================
# callbacks — the only place combat touches another system
# =========================================================================

## Is this mount able to shoot, and how well is the grid feeding it?
func turret_supply(building_id: int) -> Dictionary:
	if _build == null:
		return {"running": true, "served": 1.0}
	var b: Object = _build.call("get_building", building_id)
	if b == null or not bool(b.call("is_running")):
		return {"running": false, "served": 0.0}
	if not _has_heat:
		return {"running": true, "served": 1.0}
	if not bool(_heat.call("has_building", building_id)):
		# A mount [P02] does not know about draws nothing, so it is never starved.
		return {"running": true, "served": 1.0}
	if bool(_heat.call("is_frozen", building_id)):
		return {"running": false, "served": 0.0}
	return {"running": true, "served": float(_heat.call("served_of", building_id))}


## Rounds handed to a mount. Unlimited (and logged as such at setup) until a
## logistics or production system exposes a withdrawal.
func pull_ammo(building_id: int, item: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	if _ammo_source == null or _ammo_method == "":
		return amount
	var got: Variant = _ammo_source.call(_ammo_method, building_id, item, amount)
	match typeof(got):
		TYPE_INT: return int(got)
		TYPE_FLOAT: return int(got)
	return 0


## Building standing on a tile, biased toward whichever adjacent structure is
## already the weakest — an attacker walks into a wall and hits the cracked panel
## next to it, not the one it happened to bump.
func structure_at(cell: Vector2i) -> int:
	if _build == null:
		return 0
	var here: Object = _build.call("building_at", cell)
	if here == null:
		return 0
	var best: Object = here
	var best_score: float = _softness(here)
	for n: Vector2i in Grid.DIRS4:
		var other: Object = _build.call("building_at", cell + n)
		if other == null or int(other.get("id")) == int(here.get("id")):
			continue
		if not bool(other.get("def").get("blocks_movement")):
			continue
		var s: float = _softness(other)
		if s < best_score:
			best = other
			best_score = s
	return int(best.get("id"))


## One enemy attack on one structure. Returns the damage that landed, or -1 when
## the target no longer exists so the attacker picks something else.
func enemy_attack(slot: int, building_id: int, at: Vector2) -> float:
	if _build == null:
		return -1.0
	var b: Object = _build.call("get_building", building_id)
	if b == null:
		return -1.0
	var d: int = swarm.e_def[slot]
	var raw: float = swarm.d_damage[d]
	var def: Object = b.get("def")
	var pref: StringName = swarm.d_pref[d]
	if pref != CombatTypes.PREF_ANY and bool(def.call("has_tag", pref)):
		raw *= swarm.d_pref_mult[d]
	var cells: Array = (b.get("cells") as Array).duplicate()
	var before: float = float(b.get("hp"))
	var destroyed: bool = bool(_build.call("apply_damage", building_id, raw, swarm.d_id[d]))
	var landed: float = maxf(0.0, before - float(b.get("hp")))
	damage_taken += landed

	if swarm.d_splash[d] > 0.0:
		landed += _splash_structures(building_id, at, swarm.d_splash[d], raw * 0.6, swarm.d_id[d])

	if destroyed:
		_on_structure_lost(building_id, def, cells)
	else:
		_maybe_weaken(building_id, b, def, cells)
	return landed


## Everything a siphon takes out of the magazines around it.
func siphon_turrets(centre: Vector2, radius_px: float, amount: float) -> float:
	return battery.steal(centre, radius_px, amount)


func chill_turrets(centre: Vector2, radius_px: float, power: float) -> void:
	battery.chill(centre, radius_px, power)


func note_hit(_turret_id: int, _pos: Vector2, _amount: float) -> void:
	pass


## Nearest structure worth diverting to. Tagged preferences use the maintained
## index; "any" walks rings outward off [P11]'s occupancy, which finds the
## nearest hit on the first ring that contains one.
func find_enemy_target(from: Vector2, pref: StringName, radius_px: float) -> Dictionary:
	if _build == null or radius_px <= 0.0:
		return {}
	if pref != CombatTypes.PREF_ANY and _target_index.has(pref):
		var idx: Dictionary = _target_index[pref]
		var ids: PackedInt32Array = idx["id"]
		var xs: PackedFloat32Array = idx["x"]
		var ys: PackedFloat32Array = idx["y"]
		var best: int = -1
		var best_d2: float = radius_px * radius_px
		for i: int in range(ids.size()):
			var dx: float = xs[i] - from.x
			var dy: float = ys[i] - from.y
			var d2: float = dx * dx + dy * dy
			if d2 <= best_d2:
				best_d2 = d2
				best = i
		if best >= 0:
			return {"id": ids[best], "pos": Vector2(xs[best], ys[best])}
		return {}
	return _nearest_structure(from, mini(int(radius_px / TILE), SEEK_RING_MAX))


# =========================================================================
# commands
# =========================================================================

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"spawn":
			var kind: StringName = StringName(String(cmd.get("kind", "")))
			var n: int = maxi(1, int(cmd.get("count", 1)))
			if cmd.has("at"):
				spawn(kind, _to_cell(cmd.get("at")), n)
			else:
				spawn_on_lane(kind, int(cmd.get("lane", 0)), n)
		"spawn_wave":
			_scripted_wave(float(cmd.get("strength", 1.0)), int(cmd.get("lane", 0)))
		"kill_all":
			_kill_all()
		"set_aim":
			_set_aim(cmd)
		"refit":
			_refit(cmd)
		"repair_defences":
			_repair_defences(cmd)
		"set_director":
			director.enabled = bool(cmd.get("enabled", true))
			Log.info(TAG, "fallback director %s by command" % [
				"enabled" if director.enabled else "disabled"])
		"damage_structure":
			var c: Vector2i = _to_cell(cmd.get("cell", []))
			var id: int = structure_at(c)
			if id != 0 and _build != null:
				_build.call("apply_damage", id, float(cmd.get("amount", 100.0)), &"scripted")
		_:
			Log.warn(TAG, "unknown command op '%s'" % op)


func _scripted_wave(strength: float, lane: int) -> void:
	var pool: Array[Dictionary] = swarm.rollable(_day())
	if pool.is_empty():
		return
	var budget: float = maxf(1.0, strength) * AssaultDirector.BASE_BUDGET
	var rng: RandomNumberGenerator = Rng.stream("combat_waves")
	var total: float = 0.0
	for p: Dictionary in pool:
		total += float(p["weight"])
	var guard: int = 0
	wave += 1
	Bus.wave_started.emit(wave, budget)
	while budget > 0.0 and guard < 200:
		guard += 1
		var roll: float = rng.randf() * total
		var picked: Dictionary = pool[pool.size() - 1]
		for p2: Dictionary in pool:
			roll -= float(p2["weight"])
			if roll <= 0.0:
				picked = p2
				break
		var pack: int = int(picked["pack"])
		budget -= float(picked["threat"]) * float(pack)
		_spawn_slot(int(picked["slot"]), _lane_point(lane + guard), pack, SimClock.tick)


func _kill_all() -> void:
	for i: int in range(swarm.count):
		swarm.hurt(i, swarm.e_id[i], 1.0e9, CombatTypes.Damage.BLAST, 1.0e9, SimClock.tick)
	_publish_deaths()
	swarm.compact()


func _set_aim(cmd: Dictionary) -> void:
	var policy: StringName = StringName(String(cmd.get("aim", "first")))
	var idx: int = CombatTypes.enum_of(CombatTypes.AIM_NAMES, policy, -1)
	if idx < 0:
		Log.warn(TAG, "unknown aim policy '%s'" % policy)
		return
	var ids: PackedInt32Array = _turret_ids_from(cmd)
	for id: int in ids:
		var t: TurretBattery.Turret = battery.get_turret(id)
		if t == null:
			continue
		t.aim = idx
		if _build != null:
			var b: Object = _build.call("get_building", id)
			if b != null:
				var meta: Dictionary = b.get("meta")
				meta["aim"] = String(policy)


func _refit(cmd: Dictionary) -> void:
	var weapon: StringName = StringName(String(cmd.get("weapon", "")))
	if battery.weapon_of(weapon) == null:
		Log.warn(TAG, "no weapon '%s' in game/content/weapons" % weapon)
		return
	var ids: PackedInt32Array = _turret_ids_from(cmd)
	if _build == null:
		return
	for id: int in ids:
		var b: Object = _build.call("get_building", id)
		if b == null:
			continue
		var meta: Dictionary = b.get("meta")
		meta["weapon"] = String(weapon)
	_sync_turrets()
	Log.info(TAG, "refitted %d mount(s) to %s" % [ids.size(), weapon])


## A repair order for the perimeter. Combat decides what counts as a defence and
## what is worth repairing; [P11] owns the work and charges for the materials.
func _repair_defences(cmd: Dictionary) -> void:
	if _build == null:
		return
	var repaired: int = 0
	for entry: Variant in (_build.call("buildings_with_tag", &"defense") as Array):
		var b: Object = entry
		if b == null or float(b.call("health_ratio")) >= 0.999:
			continue
		var c: Vector2i = b.get("cell")
		var result: Dictionary = _build.call("execute", {"op": &"repair", "cell": [c.x, c.y]})
		if bool(result.get("ok", false)):
			repaired += 1
			_weakened.erase(int(b.get("id")))
			assault.forget(int(b.get("id")))
	Log.info(TAG, "repair order: %d defence structure(s) queued (%s)" % [
		repaired, String(cmd.get("reason", "player order"))])


# =========================================================================
# per-tick internals
# =========================================================================

func _run_director(tick: int) -> void:
	if not director.enabled or not _content_ok:
		return
	var orders: Array[Dictionary] = director.step(
		tick, _day(), _is_night(), _is_defended(tick), swarm, swarm.count)
	if orders.is_empty():
		return
	if not _ensure_field():
		return
	for order: Dictionary in orders:
		_spawn_slot(int(order["slot"]), _lane_point(int(order["lane"])),
			int(order["count"]), tick)
	wave = director.wave


func _drain_spawn_requests(tick: int) -> void:
	var reqs: Array[Dictionary] = swarm.take_spawn_requests()
	for r: Dictionary in reqs:
		_spawn_slot(int(r["def"]), r["pos"], int(r["count"]), tick)


func _publish_deaths() -> void:
	var deaths: PackedInt32Array = swarm.take_deaths()
	var i: int = 0
	while i + 2 < deaths.size():
		Bus.enemy_killed.emit(deaths[i], Vector2(float(deaths[i + 1]), float(deaths[i + 2])))
		i += 3


func _spawn_slot(slot: int, at: Vector2, count: int, tick: int) -> int:
	if slot < 0 or count <= 0:
		return 0
	if not _ensure_field():
		return 0
	var made: int = 0
	for k: int in range(count):
		# Scatter deterministically off the id, never off an Rng draw: a draw
		# taken inside a spawn loop makes the stream depend on how many bodies a
		# wave happened to contain, and that is a replay divergence waiting.
		var id: int = _next_id
		_next_id += 1
		var ax: float = (CombatTypes.hash01(id, 17) - 0.5) * 96.0
		var ay: float = (CombatTypes.hash01(id, 91) - 0.5) * 96.0
		var pos: Vector2 = _walkable_near(at + Vector2(ax, ay))
		var i: int = swarm.spawn(slot, pos, id, tick)
		if i < 0:
			continue
		made += 1
		Bus.enemy_spawned.emit(id, swarm.d_id[slot], pos)
	return made


## Builds the siege surface the first time anything is actually going to walk on
## it. A scenario with no combat in it never pays for this.
func _ensure_field() -> bool:
	if assault.ready:
		return true
	if _grid == null:
		return false
	var t0: int = Time.get_ticks_msec()   # lint:allow log line only
	if not assault.build(_grid):
		return false
	Log.info(TAG, "siege surface built in %d ms (%d cells flooded, dig cost %d)" % [
		Time.get_ticks_msec() - t0, assault.last_visited, AssaultField.DIG_COST])
	return true


func _sync_turrets() -> void:
	if _build == null:
		return
	var seen: Dictionary[int, bool] = {}
	for entry: Variant in (_build.call("buildings_with_tag", &"turret") as Array):
		var b: Object = entry
		if b == null or not bool(b.call("is_complete")):
			continue
		var id: int = int(b.get("id"))
		var def: Object = b.get("def")
		var weapon: StringName = StringName(String(def.get("weapon_id")))
		var meta: Variant = b.get("meta")
		if typeof(meta) == TYPE_DICTIONARY and (meta as Dictionary).has("weapon"):
			weapon = StringName(String((meta as Dictionary)["weapon"]))
		if battery.weapon_of(weapon) == null:
			if String(weapon) != "":
				_warn_once(&"bad_weapon", "mount '%s' asks for weapon '%s', which does not exist" % [
					String(b.get("kind")), weapon])
			weapon = battery.default_weapon
		seen[id] = true
		if battery.install(b, weapon, b.call("world_center"), b.get("cell"),
				float(def.get("heat_buffer")), float(def.get("heat_consumed"))):
			continue
	for id2: int in battery.sorted_ids().duplicate():
		if not seen.has(id2):
			battery.remove(id2)


func _rebuild_target_index() -> void:
	if _build == null:
		return
	_target_index.clear()
	for tag: StringName in INDEXED_TAGS:
		var ids: PackedInt32Array = PackedInt32Array()
		var xs: PackedFloat32Array = PackedFloat32Array()
		var ys: PackedFloat32Array = PackedFloat32Array()
		for entry: Variant in (_build.call("buildings_with_tag", tag) as Array):
			var b: Object = entry
			if b == null or not bool(b.call("is_complete")):
				continue
			var c: Vector2 = b.call("world_center")
			ids.append(int(b.get("id")))
			xs.append(c.x)
			ys.append(c.y)
		_target_index[tag] = {"id": ids, "x": xs, "y": ys}


func _flush_discontent() -> void:
	var pending: float = swarm.discontent_raised - _discontent_carry
	if pending <= 0.01:
		return
	_discontent_carry = swarm.discontent_raised
	if _society != null and _society_method != "":
		_society.call(_society_method, pending, &"the_screaming")


# =========================================================================
# damage bookkeeping
# =========================================================================

func _splash_structures(origin_id: int, at: Vector2, radius_px: float,
		raw: float, source: StringName) -> float:
	if _build == null:
		return 0.0
	var r: int = int(ceilf(radius_px / TILE))
	var centre: Vector2i = Vector2i(int(at.x / TILE), int(at.y / TILE))
	var rect := Rect2i(centre - Vector2i(r, r), Vector2i(r * 2 + 1, r * 2 + 1))
	var total: float = 0.0
	for entry: Variant in (_build.call("buildings_in_rect", rect) as Array):
		var b: Object = entry
		if b == null or int(b.get("id")) == origin_id:
			continue
		var c: Vector2 = b.call("world_center")
		if c.distance_squared_to(at) > radius_px * radius_px:
			continue
		var cells: Array = (b.get("cells") as Array).duplicate()
		var def: Object = b.get("def")
		var id: int = int(b.get("id"))
		var before: float = float(b.get("hp"))
		var destroyed: bool = bool(_build.call("apply_damage", id, raw, source))
		var landed: float = maxf(0.0, before - float(b.get("hp")))
		total += landed
		damage_taken += landed
		if destroyed:
			_on_structure_lost(id, def, cells)
		else:
			_maybe_weaken(id, b, def, cells)
	return total


func _on_structure_lost(building_id: int, def: Object, cells: Array) -> void:
	structures_lost += 1
	_weakened.erase(building_id)
	assault.forget(building_id)
	battery.remove(building_id)
	# The one repath that must not lag a tick: the hole the player just lost.
	var typed: Array[Vector2i] = []
	for c: Vector2i in cells:
		typed.append(c)
	assault.note_cells(_grid, typed)
	var pos: Vector2 = Grid.cell_to_world(typed[0]) if not typed.is_empty() else Vector2.ZERO
	if def != null and bool(def.call("has_tag", &"wall")):
		breaches += 1
		_alert(&"breach", 1, "The wall is open.", pos)
	elif def != null and bool(def.call("has_tag", &"landmark")):
		Log.warn(TAG, "the hearth has gone out")
		Bus.game_over.emit("the hearth was torn down")
		_alert(&"hearth_lost", 1, "The hearth has gone out.", pos)
	elif def != null and bool(def.call("has_tag", &"conduit")):
		_alert(&"main_severed", 1, "A heat main has been severed.", pos)


func _maybe_weaken(building_id: int, b: Object, def: Object, cells: Array) -> void:
	if _weakened.has(building_id):
		return
	if float(b.call("health_ratio")) > WEAK_AT:
		return
	if def == null or not bool(def.get("blocks_movement")):
		return
	_weakened[building_id] = true
	var typed: Array[Vector2i] = []
	for c: Vector2i in cells:
		typed.append(c)
	assault.weaken(building_id, typed)


## Lower is softer. Armour is weighted because a low-armour panel is the cheap
## way through even when it has more hit points left.
func _softness(b: Object) -> float:
	var def: Object = b.get("def")
	return float(b.get("hp")) + float(def.get("armor")) * 6.0


# =========================================================================
# world queries
# =========================================================================

func _nearest_structure(from: Vector2, max_r: int) -> Dictionary:
	if _build == null or max_r <= 0:
		return {}
	var centre := Vector2i(int(from.x / TILE), int(from.y / TILE))
	for r: int in range(1, max_r + 1):
		var found: int = 0
		var best: Vector2i = Vector2i.ZERO
		for c: Vector2i in Grid.ring(centre, r):
			if c.x < 0 or c.y < 0 or c.x >= _map_w or c.y >= _map_h:
				continue
			var b: Object = _build.call("building_at", c)
			if b == null or not bool(b.call("is_complete")):
				continue
			found = int(b.get("id"))
			best = c
			break
		if found != 0:
			return {"id": found, "pos": Grid.cell_to_world(best)}
	return {}


## Nearest cell an attacker can actually stand on. Spawning inside a ridge would
## put a body somewhere the flow field has no opinion about.
func _walkable_near(pos: Vector2) -> Vector2:
	if _world == null:
		return pos
	var cell := Vector2i(clampi(int(pos.x / TILE), 0, maxi(_map_w - 1, 0)),
		clampi(int(pos.y / TILE), 0, maxi(_map_h - 1, 0)))
	if bool(_world.call("is_walkable", cell)):
		return pos
	var found: Vector2i = _world.call("nearest_walkable", cell, 24)
	if not bool(_world.call("is_walkable", found)):
		return pos
	return Grid.cell_to_world(found)


## A point on one of [P01]'s approach lanes, chosen by a seed so the same wave
## always comes down the same road. Falls back to the map edge.
func _lane_point(seed_value: int) -> Vector2:
	if _grid == null:
		return Grid.cell_to_world(_core_cell)
	var lanes: Array = _grid.call("approach_lanes")
	if lanes.is_empty() or _world == null:
		var ring: int = maxi(2, mini(_map_w, _map_h) / 2 - 3)
		var a: float = CombatTypes.hash01(seed_value, 7) * TAU
		var c := Vector2i(
			clampi(_core_cell.x + int(cos(a) * float(ring)), 1, maxi(_map_w - 2, 1)),
			clampi(_core_cell.y + int(sin(a) * float(ring)), 1, maxi(_map_h - 2, 1)))
		return _walkable_near(Grid.cell_to_world(c))
	var lane: Dictionary = lanes[posmod(seed_value, lanes.size())]
	var idx: int = int(lane.get("entry", -1))
	if idx < 0:
		return Grid.cell_to_world(_core_cell)
	return Grid.cell_to_world(_world.call("cell_of", idx))


func _is_defended(tick: int) -> bool:
	if tick == _defended_tick:
		return _defended
	_defended_tick = tick
	_defended = false
	if _build == null:
		return false
	if battery.count() > 0:
		_defended = true
		return true
	for tag: StringName in [&"wall", &"defense"] as Array[StringName]:
		if not (_build.call("buildings_with_tag", tag) as Array).is_empty():
			_defended = true
			return true
	return false


func _day() -> int:
	if _climate != null and _climate.has_method("day"):
		return maxi(1, int(_climate.call("day")))
	return 1


func _is_night() -> bool:
	return bool(_climate.call("is_night")) if _has_night else false


func _turret_ids_from(cmd: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if bool(cmd.get("all", false)):
		return battery.sorted_ids().duplicate()
	if cmd.has("id"):
		out.append(int(cmd["id"]))
		return out
	if cmd.has("cell") and _build != null:
		var b: Object = _build.call("building_at", _to_cell(cmd["cell"]))
		if b != null:
			out.append(int(b.get("id")))
	return out


func _alert(key: StringName, severity: int, text: String, pos: Vector2) -> void:
	var last: int = int(_last_alert_tick.get(key, -100000))
	if SimClock.tick - last < ALERT_EVERY_TICKS:
		return
	_last_alert_tick[key] = SimClock.tick
	Bus.alert_raised.emit(severity, key, text, pos)


func _warn_once(key: StringName, text: String) -> void:
	if _last_alert_tick.has(key):
		return
	_last_alert_tick[key] = SimClock.tick
	Log.warn(TAG, text)


static func _to_cell(v: Variant) -> Vector2i:
	match typeof(v):
		TYPE_VECTOR2I:
			return v
		TYPE_ARRAY:
			var a: Array = v
			if a.size() >= 2:
				return Vector2i(int(a[0]), int(a[1]))
	return Vector2i.ZERO


func _resolve_ammo_source() -> void:
	_ammo_source = null
	_ammo_method = ""
	for name: StringName in [&"logistics", &"production"] as Array[StringName]:
		var s: SimSystem = Sim.get_system(name)
		if s == null:
			continue
		for m: String in ["take_item", "withdraw_item", "withdraw", "request_item", "consume_item"]:
			if s.has_method(m):
				_ammo_source = s
				_ammo_method = m
				return


func _resolve_society() -> void:
	_society_method = ""
	if _society == null:
		return
	for m: String in ["add_discontent", "raise_discontent", "apply_discontent"]:
		if _society.has_method(m):
			_society_method = m
			return


# =========================================================================
# persistence and metrics
# =========================================================================

func serialize() -> Dictionary:
	return {
		"wave": wave,
		"next_id": _next_id,
		"kills": swarm.kills,
		"leaked": swarm.leaked,
		"damage_taken": snappedf(damage_taken, 0.01),
		"damage_dealt": snappedf(battery.damage_dealt, 0.01),
		"enemy_damage": snappedf(swarm.damage_dealt, 0.01),
		"structures_lost": structures_lost,
		"breaches": breaches,
		"leaks": leaks,
		"shots_fired": battery.shots_fired,
		"heat_spent": snappedf(battery.heat_spent, 0.01),
		"heat_stolen": snappedf(battery.heat_stolen, 0.01),
		"heat_siphoned": snappedf(swarm.heat_siphoned, 0.01),
		"discontent": snappedf(swarm.discontent_raised, 0.01),
		"enemies": swarm.serialize(),
		"projectiles": shells.serialize(),
		"turrets": battery.serialize(),
		"director": director.serialize(),
		"field": assault.stats(),
		"census": swarm.census(),
	}


func deserialize(data: Dictionary) -> void:
	wave = int(data.get("wave", 0))
	_next_id = maxi(ENEMY_ID_BASE, int(data.get("next_id", ENEMY_ID_BASE)))
	swarm.kills = int(data.get("kills", 0))
	swarm.leaked = int(data.get("leaked", 0))
	damage_taken = float(data.get("damage_taken", 0.0))
	battery.damage_dealt = float(data.get("damage_dealt", 0.0))
	swarm.damage_dealt = float(data.get("enemy_damage", 0.0))
	structures_lost = int(data.get("structures_lost", 0))
	breaches = int(data.get("breaches", 0))
	leaks = int(data.get("leaks", 0))
	battery.shots_fired = int(data.get("shots_fired", 0))
	battery.heat_spent = float(data.get("heat_spent", 0.0))
	battery.heat_stolen = float(data.get("heat_stolen", 0.0))
	swarm.heat_siphoned = float(data.get("heat_siphoned", 0.0))
	swarm.discontent_raised = float(data.get("discontent", 0.0))
	_discontent_carry = swarm.discontent_raised
	swarm.deserialize(data.get("enemies", []), SimClock.tick)
	shells.deserialize(data.get("projectiles", []))
	director.deserialize(data.get("director", {}), swarm)
	_sync_turrets()
	for entry: Variant in data.get("turrets", []):
		var t: Dictionary = entry
		battery.restore(int(t.get("id", -1)), t)
	if swarm.count > 0:
		_ensure_field()


func metrics() -> Dictionary:
	# No wall-clock column: tools/determinism.sh diffs metrics.csv, and a timing
	# number in a diffed artifact is a tripwire. _step_us lives in the log only.
	return {
		"enemies_alive": swarm.count,
		"kills": swarm.kills,
		"damage_taken": snappedf(damage_taken, 0.01),
		"damage_dealt": snappedf(battery.damage_dealt, 0.01),
		"turret_uptime": snappedf(battery.uptime(), 0.0001),
		"heat_spent_on_defence": snappedf(battery.heat_spent, 0.01),
		"turrets": battery.count(),
		"projectiles": shells.count,
		"structures_lost": structures_lost,
		"breaches": breaches,
		"wave": wave,
	}


## Microseconds the last step() took. Log and tests only — never metrics().
func last_step_usec() -> int:
	return _step_us

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
## Ticks between checks of whether the wall is actually armed.
const DEFENCE_CHECK_TICKS: int = 200
## Ticks between the self-profiling log line. Log only — see step().
const PROFILE_TICKS: int = 1000
## Ticks between "is there a perimeter yet" sweeps, until the answer is yes.
const DEFENDED_RECHECK_TICKS: int = 200
## Tags always indexed, plus whatever the loaded roster actually asks for — see
## _indexed_tags. An unlisted preference would otherwise be a silent no-op.
const INDEXED_TAGS: Array[StringName] = [
	&"conduit", &"turret", &"housing", &"heat_source", &"wall", &"defense",
]

var swarm: EnemySwarm = null
var battery: TurretBattery = null
var shells: ProjectilePool = null
var assault: AssaultField = null
var director: AssaultDirector = null
## What the night takes. See NightToll — nothing in this build cost the player
## anything before it existed.
var toll: NightToll = null

var wave: int = 0
var damage_taken: float = 0.0        ## structural damage the city has absorbed
var structures_lost: int = 0
var breaches: int = 0
## Bodies that arrived on the field without any director composing them: a
## boss's adds. Published so an artifact can say how many were on the map that
## nobody's plan ever bought.
var reinforcements: int = 0

var _grid: SimSystem = null
var _build: SimSystem = null
var _heat: SimSystem = null
var _climate: SimSystem = null
var _society: SimSystem = null
var _citizens: SimSystem = null
## [P10]. Null in a build without research; then every gun keeps its sheet value.
var _research: SimSystem = null
var _ammo_source: SimSystem = null
var _ammo_method: String = ""
var _has_withdraw: bool = false
var _has_request: bool = false
var _ammo_known: Dictionary[StringName, bool] = {}
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
var _defended_tick: int = -100000
var _index_tick: int = -100000
## [P11]'s roster_version() at the last index rebuild. See _roster_version.
var _index_count: int = -1
## False until the turret battery has been filled from [P11]'s building list at
## least once. THE OPENING SCREEN OF THE GAME DEPENDED ON THIS. The sync ran on
## `tick % TURRET_SYNC_TICKS == 0`, `game/boot.gd` seeds the settlement and then
## advances exactly ONE tick before the first frame is drawn, and 1 % 10 != 0 —
## so the battery was still empty when the HUD read it. [P17]'s alert stack asks
## `turret_count()` and printed "Nothing in this city can shoot back" over a city
## that had a turret mount in it, while [P19]'s coverage legend, which counts the
## same guns straight off the building list, printed the turret on the same
## screen. Two panels contradicting each other before the player has touched
## anything. Syncing on the first step costs one extra scan per world and makes
## the two agree from frame one.
var _turrets_synced: bool = false
var _step_us: int = 0
var _prof_total: int = 0
var _prof_max: int = 0
var _content_ok: bool = false
## Last tick something outside combat drove a spawn. While this is recent the
## fallback director keeps its hands off the night.
var _external_tick: int = -1
var _handover_logged: bool = false
## wave number -> {spawned, first_id, last_id, groups}
var _waves: Dictionary[int, Dictionary] = {}
var _tags_cache: Array[StringName] = []
## Gates ordered open or shut before the siege surface existed.
var _pending_gates: Dictionary[int, bool] = {}
## Watchdog findings said out loud so far this run.
var _watchdog_seen: int = 0


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
	toll = NightToll.new()
	toll.reset()
	wave = 0
	damage_taken = 0.0
	structures_lost = 0
	breaches = 0
	reinforcements = 0
	_next_id = ENEMY_ID_BASE
	_weakened.clear()
	_target_index.clear()
	_index_tick = -100000
	_index_count = -1
	_defended = false
	_defended_tick = -100000
	_tags_cache.clear()
	_pending_gates.clear()
	_last_alert_tick.clear()
	_waves.clear()
	_discontent_carry = 0.0
	_handover_logged = false
	_watchdog_seen = 0

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
	_citizens = Sim.get_system(&"citizens")
	toll.bind(_citizens)
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
	_rebuild_target_index()
	_research = Sim.get_system(&"research")
	if _research != null and not _research.has_method("multiplier"):
		_research = null

	# The fallback director is armed by default and stands down the moment anything
	# else actually drives a spawn through this system (see _note_external_spawn).
	# Presence alone is not enough: a threat system that exists but composes
	# nothing would otherwise leave every night empty and both parts looking dead.
	director.enabled = true
	_external_tick = -1
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
	if Sim.get_system(&"threat") == null:
		Log.info(TAG, "no [P08] threat system — combat is driving its own fallback "
			+ "assault director; it opens a front only once the city has a perimeter")
	else:
		Log.info(TAG, "[P08] threat present — the fallback director stands down as soon "
			+ "as the first wave is actually driven through spawn_group()/spawn()")


func step(tick: int) -> void:
	var t0: int = Time.get_ticks_usec()   # lint:allow log + metrics-free profiling only
	if tick % TURRET_SYNC_TICKS == 0 or not _turrets_synced:
		_turrets_synced = true
		_sync_turrets()
		_read_tech()
	# Nothing on the field means nothing is seeking, and the index is rebuilt on
	# demand the moment something is (see find_enemy_target).
	if swarm.count > 0 and tick - _index_tick >= TARGET_INDEX_TICKS:
		_rebuild_target_index()

	_run_director(tick)
	_prebuild_field(tick)

	if swarm.count > 0 or assault.ready:
		assault.maintain(_grid)
	if swarm.count > 0:
		swarm.reindex()
		swarm.apply_auras(self)
		swarm.step(tick, self, _gcost, _open_dir, assault, _heat if _has_heat else null, _world)
		swarm.apply_pressure(self)

	battery.step(tick, self, swarm, shells, assault)
	if shells.count > 0:
		battery.damage_dealt += shells.step(tick, swarm, battery)

	if tick % DEFENCE_CHECK_TICKS == 0:
		_report_defence()
	_drain_spawn_requests(tick)
	_publish_watchdog()
	_publish_deaths()
	if swarm.count > 0:
		swarm.compact()
	_flush_discontent()
	_step_us = Time.get_ticks_usec() - t0   # lint:allow never reaches serialize()/metrics()
	# Wall clock is read here and NOWHERE else, and it goes to the log only —
	# never to metrics() or serialize(), because tools/determinism.sh diffs those.
	_prof_total += _step_us
	_prof_max = maxi(_prof_max, _step_us)
	if tick % PROFILE_TICKS == 0:
		Log.debug(TAG, "step avg %.1f us, max %d us over %d ticks (%d bodies, %d guns)" % [
			float(_prof_total) / float(PROFILE_TICKS), _prof_max, PROFILE_TICKS,
			swarm.count, battery.count()])
		_prof_total = 0
		_prof_max = 0


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
	_note_external_spawn()
	return _spawn_slot(slot, Grid.cell_to_world(cell), count, SimClock.tick)


## [P08]'s group handoff: one composed wave group becomes real bodies on the
## field. Accepts `{wave, enemy, count, cell, vector, compass, path}` and returns
## a handle the director can ask about later through [method wave_status].
func spawn_group(spec: Dictionary) -> int:
	var kind: StringName = StringName(String(spec.get("enemy", "")))
	var slot: int = swarm.def_slot(kind)
	if slot < 0:
		Log.warn(TAG, "spawn_group: no enemy definition '%s'" % kind)
		return -1
	_note_external_spawn()
	var w: int = int(spec.get("wave", wave))
	wave = maxi(wave, w)
	var cell: Vector2i = _to_cell(spec.get("cell", []))
	var at: Vector2 = Grid.cell_to_world(cell) if cell != Vector2i.ZERO else _lane_point(int(spec.get("vector", 0)))
	var n: int = maxi(1, int(spec.get("count", 1)))
	var first: int = _next_id
	var made: int = _spawn_slot(slot, at, n, SimClock.tick)
	var record: Dictionary = _wave_record(w)
	record["spawned"] = int(record["spawned"]) + made
	var groups: Array = record["groups"]
	groups.append({"enemy": String(kind), "count": made, "first_id": first,
		"cell": [cell.x, cell.y], "compass": String(spec.get("compass", ""))})
	_claim_ids(record, first, _next_id)
	return first


## Single-body variant of the same handoff, for a director that has no groups.
func spawn_enemy(kind: StringName, cell: Vector2i, wave_number: int = 0) -> int:
	var first: int = _next_id
	var made: int = spawn(kind, cell, 1)
	if made > 0 and wave_number > 0:
		wave = maxi(wave, wave_number)
		var record: Dictionary = _wave_record(wave_number)
		record["spawned"] = int(record["spawned"]) + made
		_claim_ids(record, first, _next_id)
	return made


## Spawns onto the approach lane chosen by `lane_seed`. Lanes are [P01]'s record
## of the old highways into the basin.
func spawn_on_lane(kind: StringName, lane_seed: int, count: int = 1) -> int:
	var slot: int = swarm.def_slot(kind)
	if slot < 0:
		return 0
	_note_external_spawn()
	return _spawn_slot(slot, _lane_point(lane_seed), count, SimClock.tick)


## Bodies still in the fight. A retreating body is on the map and still
## shootable, but it is nobody's problem any more — counting it here is what let
## a single leftover keep every later night from ever ending.
func enemies_alive() -> int:
	return swarm.fighting_count()


## Alias [P08] duck-types for.
func live_enemy_count() -> int:
	return swarm.fighting_count()


## Everything on the map, fighting or leaving. The view draws this many.
func bodies_on_map() -> int:
	return swarm.count


## Orders the field to break off and walk back out into the dark. This is what
## dawn does. `wave_number` < 0 means everything, which is the right answer at
## dawn: last night's leftovers are exactly the thing that must not survive into
## tomorrow. Returns how many turned around.
func withdraw_wave(wave_number: int = -1) -> int:
	var tick: int = SimClock.tick
	var w: int = wave if wave_number < 0 else wave_number
	var spans: Array = (_waves.get(w, {}) as Dictionary).get("spans", [])
	var mine: int = 0
	var others: int = 0
	for i: int in range(swarm.count):
		# EVERYTHING turns around when the argument is negative — that is what
		# dawn means, and last night's leftovers are exactly the thing that must
		# not survive into tomorrow. What is COUNTED is narrower, and that
		# distinction is the whole of this function.
		var belongs: bool = _id_in_spans(spans, swarm.e_id[i])
		if wave_number >= 0 and not belongs:
			continue
		if not swarm.retreat(i, tick, &"dawn"):
			continue
		if belongs:
			mine += 1
		else:
			others += 1
	if mine + others > 0:
		Log.info(TAG, "dawn: %d body/bodies broke off and are walking back out%s" % [
			mine + others,
			"" if others == 0 else " (%d of them belonged to no wave the director sent)" % others])
	return mine


## Is `id` one of the bodies a wave put on the field through [P08]'s own handoff?
##
## THE NUMBER THIS PROTECTS. [P08] closes a night with
## `killed = spawned - withdrew`, where `spawned` is the count in its PLAN. The
## old withdraw_wave(-1) answered with every body standing on the map, so a night
## that also carried a boss's reinforcements, a scripted spawn or the previous
## assault's leftovers reported more survivors than it ever sent and the
## subtraction went to zero: `288 spawned, 0 killed, 319 walked away`, on a night
## with 406 shots fired and three structures lost. A ledger that can report more
## survivors than it sent cannot be used to grade anything.
##
## So only bodies from spawn_group()/spawn_enemy() are counted. Reinforcements a
## boss makes on the field and anything a scenario spawns by hand are still
## turned around, still shot at on the way out, and are named separately in the
## dawn line — they are simply not survivors of a plan that never bought them.
func _id_in_spans(spans: Array, id: int) -> bool:
	for s: Variant in spans:
		var pair: Array = s
		if id >= int(pair[0]) and id < int(pair[1]):
			return true
	return false


## Records the id range one handoff put on the field. Ranges are allocated
## contiguously by _spawn_slot and appended in order, so the common case merges
## into the last span and the list stays one entry per wave.
func _claim_ids(record: Dictionary, first: int, last: int) -> void:
	if last <= first:
		return
	if not record.has("spans"):
		record["spans"] = []
	var spans: Array = record["spans"]
	if not spans.is_empty() and int((spans[-1] as Array)[1]) == first:
		(spans[-1] as Array)[1] = last
		return
	spans.append([first, last])


## How one wave is going: how many were put on the field, how many are still on
## it, and how many the wall has killed. [P08] polls this to decide when a night
## is over instead of guessing.
func wave_status(wave_number: int) -> Dictionary:
	var record: Dictionary = _waves.get(wave_number, {})
	if record.is_empty():
		return {"wave": wave_number, "spawned": 0, "live": 0, "killed": 0,
			"leaving": 0, "groups": []}
	var live: int = 0
	var leaving: int = 0
	# The wave's OWN id spans, not first_id..last_id: a reinforcement or a
	# scripted spawn landing between two groups of the same night falls inside
	# that span and would be counted as a body the director sent. See
	# _id_in_spans.
	var spans: Array = record.get("spans", [])
	for i: int in range(swarm.count):
		if not _id_in_spans(spans, swarm.e_id[i]):
			continue
		if swarm.e_state[i] == CombatTypes.EnemyState.RETREATING:
			leaving += 1
		else:
			live += 1
	var spawned: int = int(record.get("spawned", 0))
	return {
		"wave": wave_number,
		"spawned": spawned,
		"live": live,
		"leaving": leaving,
		"killed": maxi(0, spawned - live - leaving),
		"groups": record.get("groups", []),
	}


func enemy_kinds() -> Array[StringName]:
	var out: Array[StringName] = []
	for i: int in range(swarm.def_count):
		out.append(swarm.d_id[i])
	return out


func has_enemy_kind(kind: StringName) -> bool:
	return swarm.has_kind(kind)


func enemy_def(kind: StringName) -> CombatEnemyDef:
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


## One-line state of the whole perimeter: how many guns exist, how many can
## actually put a round out this second, and what is stopping the rest. [P17] and
## [P19] can render this directly; the alert below is the same data, shouted.
## What the city has lost since `since_tick`, one row per structure, each with
## the names of anyone who was inside it. [P08] calls this at dawn and puts it in
## the night's post-mortem; it is the only place a player learns that a night
## cost them a person rather than a number.
func night_toll(since_tick: int = 0) -> Array[Dictionary]:
	return toll.since(since_tick)


## The same thing as one sentence, or "" when the night cost nothing.
func night_toll_line(since_tick: int = 0) -> String:
	return toll.summary(toll.since(since_tick))


func defence_report() -> Dictionary:
	var armed: int = 0
	var cold: int = 0
	var dry: int = 0
	var idle_gun: int = 0
	var off: int = 0
	var first_cold: Vector2 = Vector2.ZERO
	for id: int in battery.sorted_ids():
		var t: TurretBattery.Turret = battery.turrets[id]
		match t.idle:
			CombatTypes.Idle.NO_HEAT:
				cold += 1
				if first_cold == Vector2.ZERO:
					first_cold = t.centre
			CombatTypes.Idle.NO_AMMO:
				dry += 1
			CombatTypes.Idle.OFFLINE, CombatTypes.Idle.NO_WEAPON:
				off += 1
			CombatTypes.Idle.NO_TARGET:
				idle_gun += 1
			_:
				armed += 1
	return {
		"turrets": battery.count(),
		"armed": armed + idle_gun,
		"cold": cold,
		"dry": dry,
		"offline": off,
		"uptime": snappedf(battery.uptime(), 0.001),
		"engaged": snappedf(battery.engagement(), 0.001),
		# Raw counters as well as the ratios, so a caller can difference them
		# across a night instead of reading a lifetime average and calling it
		# tonight. A campaign-long 1% is what a perfect night looks like when it
		# is divided by fifteen thousand ticks of daylight.
		"engaged_ticks": battery.engaged_ticks,
		"ready_ticks": battery.ready_ticks,
		"live_ticks": battery.live_ticks,
		"shots": battery.shots_fired,
		"heat_spent": snappedf(battery.heat_spent, 0.1),
		"first_cold": [first_cold.x, first_cold.y],
	}


## Opens or closes a gate. A gate is any structure carrying the &"gate" tag, or
## any structure the player has marked with `meta.gate = true` — so a wall with a
## winch on it is a gate, and the moment [P11] ships a proper gate building it
## works with no change here.
##
## Combat does not (and must not) make the tile physically passable: [P11] owns
## the grid footprint, and citizens keep using the road either way. What combat
## owns is what the ATTACKERS think, and an open gate is the cheapest way in they
## will ever see.
func set_gate_open(building_id: int, open: bool) -> void:
	if _build == null:
		return
	var b: Object = _build.call("get_building", building_id)
	if b == null or not _is_gate(b):
		Log.warn(TAG, "#%d is not a gate" % building_id)
		return
	if not assault.ready and not _ensure_field():
		_pending_gates[building_id] = open
		return
	var typed: Array[Vector2i] = []
	for c: Vector2i in (b.get("cells") as Array):
		typed.append(c)
	assault.set_gate_open(building_id, typed, open)
	var meta: Dictionary = b.get("meta")
	meta["gate_open"] = open


func gate_is_open(building_id: int) -> bool:
	return assault.gate_is_open(building_id)


## Every gate the city has, and whether the dark can walk through it.
func gates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _build == null:
		return out
	for entry: Variant in (_build.call("all_buildings") as Array):
		var b: Object = entry
		if b == null or not _is_gate(b):
			continue
		var c: Vector2i = b.get("cell")
		out.append({"id": int(b.get("id")), "cell": [c.x, c.y],
			"kind": String(b.get("kind")),
			"open": assault.gate_is_open(int(b.get("id"))),
			"health": snappedf(float(b.call("health_ratio")), 0.01)})
	return out


func _is_gate(b: Object) -> bool:
	var def: Object = b.get("def")
	if def != null and bool(def.call("has_tag", &"gate")):
		return true
	var meta: Variant = b.get("meta")
	return typeof(meta) == TYPE_DICTIONARY and bool((meta as Dictionary).get("gate", false))


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
	var res: CombatEnemyDef = swarm.def_resource(d)
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
		return {"running": true, "served": 1.0, "cold": false}
	var b: Object = _build.call("get_building", building_id)
	if b == null:
		return {"running": false, "served": 0.0, "cold": false}
	var frozen: bool = _has_heat and bool(_heat.call("is_frozen", building_id))
	if not bool(b.call("is_running")):
		# A gun the heat network let freeze is COLD, not "switched off". The
		# distinction is the whole point of the readout: one is the player's
		# choice, the other is the bill for a heating plan that did not reach here.
		return {"running": false, "served": 0.0, "cold": frozen}
	if not _has_heat:
		return {"running": true, "served": 1.0, "cold": false}
	if not bool(_heat.call("has_building", building_id)):
		# A mount [P02] does not know about draws nothing, so it is never starved.
		return {"running": true, "served": 1.0, "cold": false}
	if frozen:
		return {"running": false, "served": 0.0, "cold": true}
	return {"running": true, "served": float(_heat.call("served_of", building_id)),
		"cold": false}


## Rounds handed to a mount.
##
## Two documented hooks on [P03], used the way [P03] documents them: `withdraw`
## empties whatever a belt already delivered into this building, and `request_items`
## asks the haulers to bring more. Neither exists, or the economy has never heard
## of this round, and the weapon needs no ammunition at all — a defence must not be
## disarmed by a supply chain that has not been invented yet, and the log says so
## once at setup.
func pull_ammo(building_id: int, item: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	if _ammo_source == null:
		return amount
	if not _ammo_item_exists(item):
		return amount
	var got: int = 0
	if _has_withdraw:
		got = int(_ammo_source.call("withdraw", building_id, item, amount))
	if got < amount and _has_request:
		_ammo_source.call("request_items", building_id, item, amount - got)
		if _has_withdraw:
			got += int(_ammo_source.call("withdraw", building_id, item, amount - got))
	return got


## Does the economy know this round at all? Cached per item id: the answer only
## changes when content changes, and content does not change mid-run.
func _ammo_item_exists(item: StringName) -> bool:
	if _ammo_known.has(item):
		return _ammo_known[item]
	var known: bool = false
	if _ammo_source != null and _ammo_source.has_method("item"):
		known = _ammo_source.call("item", item) != null
	elif _ammo_source != null and _ammo_source.has_method("item_ids"):
		known = (_ammo_source.call("item_ids") as Array).has(item)
	_ammo_known[item] = known
	if not known:
		_warn_once(StringName("ammo_%s" % item),
			"no '%s' in the economy — the weapons that use it run unlimited for now" % item)
	return known


## Building standing on a tile, biased toward whichever adjacent structure is
## already the weakest — an attacker walks into a wall and hits the cracked panel
## next to it, not the one it happened to bump. The hearth is the exception: see
## _is_last_resort.
func structure_at(cell: Vector2i) -> int:
	if _build == null:
		return 0
	var here: Object = _build.call("building_at", cell)
	if here == null:
		return 0
	if _is_gate(here) and assault.gate_is_open(int(here.get("id"))):
		return 0
	var best: Object = here
	var best_score: float = _softness(here)
	var best_last: bool = _is_last_resort(here)
	for n: Vector2i in Grid.DIRS4:
		var other: Object = _build.call("building_at", cell + n)
		if other == null or int(other.get("id")) == int(here.get("id")):
			continue
		if not bool(other.get("def").get("blocks_movement")):
			continue
		var s: float = _softness(other)
		var last: bool = _is_last_resort(other)
		# Anything at all beats the hearth; among equals, the softest wins.
		if (best_last and not last) or (best_last == last and s < best_score):
			best = other
			best_score = s
			best_last = last
	return int(best.get("id"))


## What an attacker walking into `cell` is allowed to CHEW ON. Everything
## structure_at answers, except that the hearth answers 0 while the city is
## still more than the hearth.
##
## THIS IS THE LINE THAT MADE EVERY NIGHT FREE. `enemy_attack` has always
## refused to let a body demolish the fire and redirected it onto the nearest
## real building instead — but the redirect never survived a tick, because the
## next step's blocker probe asked "what is in front of me", was told "the
## hearth", and set the target straight back. Attack, refuse, redirect, retarget,
## forever, at zero damage a second. Measured on a 46-body assault with the wall
## deliberately left out (tests/combat/night_takes_people_open.json): every body
## that reached the fire ended the night pressed against it in state ATTACKING,
## the hearth at 3000/3000, four housing blocks untouched at four tiles' range,
## 252 points of structural damage in a hundred seconds and not one citizen hurt.
## The rule meant to stop the fire being torn down was quietly disarming the
## whole assault the moment it got inside.
##
## Answering 0 makes the body slide past the fire instead of gluing itself to it,
## and its seek then finds the radiators, the mains and the houses around it —
## which is what "they tear the city apart to get at the warmth" was supposed to
## mean in the first place. When the hearth really is the last thing standing it
## is chewable again, and the fire goes out.
func blocker_at(cell: Vector2i) -> int:
	var id: int = structure_at(cell)
	if id == 0 or _build == null:
		return id
	var b: Object = _build.call("get_building", id)
	if _is_last_resort(b) and _city_is_more_than_the_hearth():
		return 0
	return id


## THE HEARTH FALLS LAST.
##
## A landmark is a target of last resort: nothing chooses it while anything else
## of the player's is in reach. Losing it is `Bus.game_over`, and a run that ends
## because eight hounds walked past a wall and stood on the fire is not pressure,
## it is a coin flip — the reference run did exactly that on night three, at
## t028680, and every night after it was a dead city being walked through.
##
## The fiction is the rule: they tear the city apart to get at the warmth. The
## radiators, the mains, the housing and the guns all go first, in the order the
## player left them exposed, and each one is a thing they can point at in the
## morning. When the hearth is genuinely the only thing left, it burns.
func _is_last_resort(b: Object) -> bool:
	if b == null:
		return false
	var def: Object = b.get("def")
	return def != null and bool(def.call("has_tag", &"landmark"))


## Is there anything left to lose besides the fire? One cheap count off [P11];
## the answer only matters at the moment something is standing on the hearth.
func _city_is_more_than_the_hearth() -> bool:
	if _build == null or not _build.has_method("building_count"):
		return true
	return int(_build.call("building_count")) > 1


## One enemy attack on one structure. Returns the damage that landed, or -1 when
## the target no longer exists so the attacker picks something else.
func enemy_attack(slot: int, building_id: int, at: Vector2) -> float:
	if _build == null:
		return -1.0
	var b: Object = _build.call("get_building", building_id)
	if b == null:
		return -1.0
	var def: Object = b.get("def")
	# THE HEARTH IS NOT A WALL TO CHEW ON. A body that has got as far as the fire
	# while the rest of the city still stands is INSIDE — it is past the line, it
	# has taken what it came for, and it is gone by morning. It does not stand
	# there demolishing the win condition at four damage a second, which is what
	# ended the reference run on night three (`The Hearth #1 destroyed by
	# frost_shade`, t027725) and turned the following thirty thousand ticks into
	# a dead city being walked through.
	#
	# When the hearth really is the last thing left, this does not fire and the
	# fire goes out, because at that point there is nothing else to lose.
	if _is_last_resort(b) and _city_is_more_than_the_hearth():
		# They tear the city apart to get at the warmth: whatever is standing
		# nearest the fire becomes the target instead. _nearest_structure skips
		# landmarks, so this can never point back at what it just refused.
		var instead: Dictionary = _nearest_structure(at, SEEK_RING_MAX, false)
		if not instead.is_empty():
			swarm.e_target[slot] = int(instead["id"])
			var p2: Vector2 = instead["pos"]
			swarm.e_tx[slot] = p2.x
			swarm.e_ty[slot] = p2.y
			_alert(&"inside", 1, "They are in the hearth district.", at)
			# ZERO, not -1. A negative return means "whatever you were chewing is
			# gone, pick something else", and the swarm answers it by clearing
			# e_target — which would throw away the target this line just set and
			# leave the body orbiting the fire doing nothing until dawn. That is
			# not a hypothetical: it is what the first cut of this rule did, and
			# it read as `0 structural damage` on a 48-unit set piece.
			return 0.0
		# Nothing else within two dozen tiles of the fire. It is inside, it has
		# taken what it came for, and it is gone by morning — counted as a leak
		# rather than as the wall working. Absorbing it here rather than at the
		# hearth's hit points is what stops a single body ending the run.
		swarm.absorb(slot, SimClock.tick)
		return -1.0
	var d: int = swarm.e_def[slot]
	var raw: float = swarm.d_damage[d]
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


## What a body that has walked into the hearth district turns on when it has run
## out of things it is allowed to attack. Empty only when the city really is
## nothing but its fire, in which case the swarm absorbs the body instead.
##
## HOUSING FIRST, and that is a design statement, not a heuristic. They come for
## the warmth; inside the wall the warmest thing with a door in it is a house
## with people asleep behind it. It is also the only rule in this part that makes
## a BREACH cost what a breach should cost: before it, a body that reached the
## fire with no legal target evaporated within a tile, or simply stood where the
## hearth's footprint parked it until dawn — so the hole it came through was
## free. A hole in the line now costs names, and the wall is the thing that
## decides whether it does. See tests/combat/night_takes_people_{walled,open}.json.
##
## DO NOT REPEAT THE PREMISE THAT `combat.citizens_killed` READS 0. That was true
## of [E1]'s build and is stale against this one — [P05]'s people landing switched
## the toll on, and progress/parts/F2.json records twelve named dead at 60000
## ticks on the PRE-CHANGE code at 535f1a8. It is also length-dependent: the
## integrator measured `toll_dead` 0 at gate length (first_night, 24000) on this
## build, so a run that stops at 24000 sees a toll of zero either way. Quote a
## tick count with the number or do not quote the number.
##
## Never the fire itself: _nearest_structure skips landmarks, so this can never
## hand back the target enemy_attack would refuse.
func inside_target(at: Vector2) -> Dictionary:
	var home: Dictionary = find_enemy_target(at, CombatTypes.PREF_HOUSING,
		float(SEEK_RING_MAX) * TILE)
	if not home.is_empty():
		_alert(&"inside", 1, "They are in the hearth district.", at)
		return home
	var any: Dictionary = _nearest_structure(at, SEEK_RING_MAX, false)
	if not any.is_empty():
		_alert(&"inside", 1, "They are in the hearth district.", at)
	return any


## Nearest structure worth diverting to. Tagged preferences use the maintained
## index; "any" walks rings outward off [P11]'s occupancy, which finds the
## nearest hit on the first ring that contains one.
func find_enemy_target(from: Vector2, pref: StringName, radius_px: float) -> Dictionary:
	if _build == null or radius_px <= 0.0:
		return {}
	if pref != CombatTypes.PREF_ANY:
		# Never fall through to the untagged search here. A leech that cannot find
		# a conduit must find NOTHING and keep walking, because "nearest structure"
		# would quietly turn every specialist in the roster into a generic biter —
		# which is exactly how a burrower ends up chewing on the first wall it meets.
		# Stale is as bad as missing. The timer in step() only turns over while
		# there are bodies on the field, so a seek that asks a moment after the
		# city changed shape gets a list with a demolished building still in it,
		# or without the block that was finished this morning. The index is a
		# cache of [P11]'s building list and it is invalidated by that list
		# changing size, not only by the clock.
		if not _target_index.has(pref) or _roster_version() != _index_count \
				or SimClock.tick - _index_tick >= TARGET_INDEX_TICKS:
			_rebuild_target_index()
		if not _target_index.has(pref):
			return {}

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
	# A seeking body is not allowed to CHOOSE the fire either, for the same
	# reason blocker_at will not hand it over: it would be refused on contact and
	# the body would spend the night bouncing between the refusal and the
	# redirect. When the hearth is the last thing left, it is fair game again.
	return _nearest_structure(from, mini(int(radius_px / TILE), SEEK_RING_MAX),
		not _city_is_more_than_the_hearth())


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
		"set_gate":
			var gid: int = int(cmd.get("id", -1))
			if gid < 0 and cmd.has("cell") and _build != null:
				var gb: Object = _build.call("building_at", _to_cell(cmd["cell"]))
				if gb != null:
					gid = int(gb.get("id"))
			if gid >= 0:
				set_gate_open(gid, bool(cmd.get("open", true)))
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

## Ticks of quiet before the fallback director decides nothing else is driving
## the night. Two full campaign days, so a director that only acts on some nights
## is never talked over.
const EXTERNAL_GRACE_TICKS: int = 19200


func _note_external_spawn() -> void:
	_external_tick = SimClock.tick
	if not _handover_logged:
		_handover_logged = true
		Log.info(TAG, "an external director is driving the assault — combat's fallback "
			+ "stands down")


func _wave_record(wave_number: int) -> Dictionary:
	var record: Dictionary = _waves.get(wave_number, {})
	if record.is_empty():
		record = {"spawned": 0, "first_id": _next_id, "last_id": _next_id,
			"groups": [], "spans": []}
		_waves[wave_number] = record
	record["last_id"] = _next_id
	return record


func _run_director(tick: int) -> void:
	if not director.enabled or not _content_ok:
		return
	if _external_tick >= 0 and tick - _external_tick < EXTERNAL_GRACE_TICKS:
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
		# Deliberately NOT booked to the running wave. A boss's adds are real
		# bodies and they are counted here so the artifact says how many of them
		# there were, but they are not part of any plan [P08] composed, and
		# folding them into the wave's ledger is what let a night report more
		# survivors than it sent. See _id_in_spans.
		reinforcements += _spawn_slot(int(r["def"]), r["pos"], int(r["count"]), tick)


## Ticks between the aggregated watchdog line once the first few have been said
## individually. A stall is a bug in the making; a thousand identical log lines
## is a bug nobody reads.
const WATCHDOG_LOUD: int = 6


## Says what the swarm's watchdog found. The first few are named individually
## with everything needed to reproduce them — id, kind, tile, age — because the
## whole point of this machinery is that a stalled body can never again be
## invisible. After that it is counted and reported on a timer.
func _publish_watchdog() -> void:
	var reports: Array[Dictionary] = swarm.take_reports()
	if reports.is_empty():
		return
	for r: Dictionary in reports:
		_watchdog_seen += 1
		var reason: String = String(r.get("reason", "stall"))
		if _watchdog_seen <= WATCHDOG_LOUD:
			var cell: Array = r.get("cell", [0, 0])
			Log.warn(TAG, "watchdog: %s #%d (%s) at (%d, %d) made no progress for %d tick(s) — %s" % [
				reason, int(r.get("id", 0)), String(r.get("kind", "?")),
				int(cell[0]), int(cell[1]), int(r.get("age", 0)),
				"pulled off its target (strike %d)" % int(r.get("strike", 0))
					if reason == "stall" else "sent back out into the dark"])
		elif _watchdog_seen == WATCHDOG_LOUD + 1:
			Log.warn(TAG, "watchdog: further stalls are counted, not narrated "
				+ "(combat.stalls in metrics.csv)")
	_alert(&"combat_stall", 1,
		"Something out there is not moving and not dying. %d so far tonight." % _watchdog_seen,
		Vector2.ZERO)


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


## Seconds of warning before nightfall at which the siege surface starts being
## prepared. Flooding a 256x256 map costs 83 ms in one go — the largest single
## spike in the whole build. It is now paid in slices ([AssaultField.advance]),
## which only works if it starts early enough to finish before anything walks on
## it: two minutes of warning against about a second of work.
const PREBUILD_BEFORE_NIGHT: float = 120.0
const PREBUILD_CHECK_TICKS: int = 20


## Keeps the siege surface ahead of the night. Starts the preparation when dusk
## is close and pays one slice a tick until it is up, so the player never eats
## the flood as a dropped frame.
func _prebuild_field(tick: int) -> void:
	if assault.ready:
		return
	if assault.building:
		if assault.advance():
			Log.info(TAG, "siege surface ready — prepared over %d slice(s), dig cost %d" % [
				assault.build_slices, AssaultField.DIG_COST])
		return
	if tick % PREBUILD_CHECK_TICKS != 0 or _grid == null:
		return
	if _climate == null or not _climate.has_method("seconds_until_night"):
		return
	var left: float = float(_climate.call("seconds_until_night"))
	if left <= 0.0 or left > PREBUILD_BEFORE_NIGHT:
		return
	if assault.begin(_grid):
		Log.info(TAG, "dusk in %.0f s — preparing the siege surface in slices" % left)


## Builds the siege surface RIGHT NOW, because something is about to walk on it.
## The prepared path above is the one that normally wins the race; this is the
## fallback for a body that appears on a map with no surface under it, and it is
## synchronous on purpose — a wrong route this tick is worse than a slow tick.
func _ensure_field() -> bool:
	if assault.ready:
		return true
	if _grid == null:
		return false
	var t0: int = Time.get_ticks_msec()   # lint:allow log line only
	if not assault.build(_grid):
		return false
	var build_ms: int = Time.get_ticks_msec() - t0   # lint:allow log line only, never state
	Log.info(TAG, "siege surface built in %d ms (%d cells flooded, dig cost %d)" % [
		build_ms, assault.last_visited, AssaultField.DIG_COST])
	if not _pending_gates.is_empty():
		var ids: Array = _pending_gates.keys()
		ids.sort()
		var orders: Dictionary[int, bool] = _pending_gates
		_pending_gates = {}
		for gid: int in ids:
			set_gate_open(gid, bool(orders[gid]))
	return true


## Four research keys, refreshed on the turret sync tick. A completed weapons
## node has to change what the guns already bolted down do, not only what a new
## mount would cost.
func _read_tech() -> void:
	if _research == null:
		return
	battery.tech_damage = _mult(ResearchDefs.E_TURRET_DAMAGE_MULT)
	battery.tech_rate = _mult(ResearchDefs.E_TURRET_RATE_MULT)
	battery.tech_range = _mult(ResearchDefs.E_TURRET_RANGE_MULT)
	battery.tech_pierce_add = maxf(0.0, _add(ResearchDefs.E_TURRET_PIERCE_ADD))


func _mult(key: StringName) -> float:
	var v: Variant = _research.call("multiplier", key)
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 1.0
	return clampf(float(v), 0.05, 20.0)


## The *_add keys are a plain sum in the unit of the thing, not a multiplier.
## See the suffix contract in ResearchDefs.
func _add(key: StringName) -> float:
	if not _research.has_method("modifier"):
		return 0.0
	var v: Variant = _research.call("modifier", key)
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	return float(v)


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


## Rebuilds the per-tag lists a seeker searches, in ONE pass over the building
## list rather than one pass per tag. With seventeen hundred buildings on the map
## the difference between one sweep and eight is the difference between a
## rounding error and a visible spike, and this runs on a timer.
func _rebuild_target_index() -> void:
	if _build == null:
		return
	var tags: Array[StringName] = _indexed_tags()
	_target_index.clear()
	# ACCUMULATE INTO PLAIN ARRAYS, PACK AT THE END.
	#
	# THE BUG THIS REPLACES MADE EVERY SPECIALIST IN THE ROSTER A GENERIC BITER.
	# A Packed*Array is a VALUE type: `(bucket["id"] as PackedInt32Array).append(x)`
	# appends to a temporary copy and throws it away, so this index has been empty
	# on every tick of every run since it was written. Every tagged preference
	# resolves through it, and find_enemy_target is deliberately forbidden from
	# falling through to the untagged search — so the pale stalker never looked
	# for a turret, the cinder leech never looked for a heat main, the breaker
	# never looked for a wall and the borer never looked for a generator. All four
	# walked the flow field and chewed whatever happened to block the next step,
	# which is exactly the behaviour that comment says must never happen. An
	# ordinary Array is a REFERENCE type and appends where you think it does.
	for tag: StringName in tags:
		_target_index[tag] = {"id": [], "x": [], "y": []}
	for entry: Variant in (_build.call("all_buildings") as Array):
		var b: Object = entry
		if b == null or not bool(b.call("is_complete")):
			continue
		var def: Object = b.get("def")
		if def == null:
			continue
		# The def's tag list is read ONCE per building and searched locally.
		# Asking `def.has_tag(t)` per tag is seven cross-object calls per
		# building, which at stress scale is twelve thousand reflection calls
		# for an answer that fits in one property read.
		var own: Array = def.get("tags")
		if own.is_empty():
			continue
		var c: Vector2 = Vector2.ZERO
		var have_centre: bool = false
		for tag2: StringName in tags:
			if not own.has(tag2):
				continue
			if not have_centre:
				c = b.call("world_center")
				have_centre = true
			var bucket: Dictionary = _target_index[tag2]
			(bucket["id"] as Array).append(int(b.get("id")))
			(bucket["x"] as Array).append(c.x)
			(bucket["y"] as Array).append(c.y)
	# Packed only now that nothing more is going in. See the note on the
	# accumulator above: appending to a Packed array read out of a Dictionary
	# appends to a COPY and is silently a no-op.
	for tag3: StringName in tags:
		var bucket2: Dictionary = _target_index[tag3]
		bucket2["id"] = PackedInt32Array(bucket2["id"] as Array)
		bucket2["x"] = PackedFloat32Array(bucket2["x"] as Array)
		bucket2["y"] = PackedFloat32Array(bucket2["y"] as Array)
	_index_tick = SimClock.tick
	_index_count = _roster_version()


## [P11]'s own monotonic "did anything move?" counter, or -1 when it cannot say.
## The seek index is a snapshot of the building list and this is its cache key.
##
## Deliberately NOT building_count(): one placed and one removed between two
## seeks leaves the count identical and the index holding a building that is not
## there. roster_version() exists for exactly this and costs one integer.
func _roster_version() -> int:
	if _build == null or not _build.has_method("roster_version"):
		return -1
	return int(_build.call("roster_version"))


## The tags worth maintaining a list for: the standard set plus every preference
## the roster in this build actually names.
func _indexed_tags() -> Array[StringName]:
	if not _tags_cache.is_empty():
		return _tags_cache
	_tags_cache = INDEXED_TAGS.duplicate()
	for i: int in range(swarm.def_count):
		var pref: StringName = swarm.d_pref[i]
		if pref != CombatTypes.PREF_ANY and not _tags_cache.has(pref):
			_tags_cache.append(pref)
	return _tags_cache


## Says out loud when the wall cannot shoot. A silent turret is the single most
## expensive thing a player can fail to notice, and the sim already knows exactly
## why each one is silent — none of that is worth anything until it leaves the
## simulation.
func _report_defence() -> void:
	if battery.count() == 0:
		return
	var r: Dictionary = defence_report()
	var cold: int = int(r["cold"])
	var off: int = int(r["offline"])
	var dry: int = int(r["dry"])
	if cold + off > 0:
		var pos: Array = r["first_cold"]
		var n_cold: int = cold + off
		_alert(&"turrets_cold", 1, "%d of %d guns %s no heat and cannot fire."
			% [n_cold, int(r["turrets"]), "has" if n_cold == 1 else "have"],
			Vector2(float(pos[0]), float(pos[1])))
	elif dry > 0:
		_alert(&"turrets_dry", 1, "%d of %d guns %s out of ammunition."
			% [dry, int(r["turrets"]), "is" if dry == 1 else "are"], Vector2.ZERO)


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
		# Splash does not get to do what a direct attack is forbidden to do. A
		# sapper detonating against a pipe must not take the fire out with it.
		if _is_last_resort(b) and _city_is_more_than_the_hearth():
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
	# The seek index now names a building that is not there. Drop the stamp so
	# the next seeker rebuilds instead of walking to an empty lot.
	_index_tick = -100000
	_index_count = -1
	_weakened.erase(building_id)
	assault.forget(building_id)
	battery.remove(building_id)
	# The one repath that must not lag a tick: the hole the player just lost.
	var typed: Array[Vector2i] = []
	for c: Vector2i in cells:
		typed.append(c)
	assault.note_cells(_grid, typed)
	# The bill, before anything else touches the footprint: whoever was standing
	# in it is still standing in it for exactly this long.
	var row: Dictionary = toll.structure_lost(SimClock.tick,
		StringName(String(def.get("id"))) if def != null else &"",
		String(def.get("display_name")) if def != null else "",
		_tags_of(def), typed)
	var pos: Vector2 = Grid.cell_to_world(typed[0]) if not typed.is_empty() else Vector2.ZERO
	var dead: Array = row.get("dead", [])
	if not dead.is_empty():
		Log.warn(TAG, "%s came down on %d: %s" % [
			String(row.get("label", "a structure")), dead.size(), ", ".join(PackedStringArray(
				Array(dead).map(func(v: Variant) -> String: return String(v))))])
	if def != null and bool(def.call("has_tag", &"wall")):
		breaches += 1
		_alert(&"breach", 1, "The wall is open.", pos)
	elif def != null and bool(def.call("has_tag", &"landmark")):
		Log.warn(TAG, "the hearth has gone out")
		Bus.game_over.emit("the hearth was torn down")
		_alert(&"hearth_lost", 1, "The hearth has gone out.", pos)
	elif def != null and bool(def.call("has_tag", &"conduit")):
		_alert(&"main_severed", 1, "A heat main has been severed.", pos)


## A building's tags as plain strings, for the toll ledger. [P08] and [P22] read
## it and neither of them may hold a reference to [P11]'s resource.
func _tags_of(def: Object) -> PackedStringArray:
	var out := PackedStringArray()
	if def == null:
		return out
	var raw: Variant = def.get("tags")
	if typeof(raw) != TYPE_ARRAY:
		return out
	for t: Variant in (raw as Array):
		out.append(String(t))
	return out


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

func _nearest_structure(from: Vector2, max_r: int, allow_last_resort: bool = true) -> Dictionary:
	if _build == null or max_r <= 0:
		return {}
	var centre := Vector2i(int(from.x / TILE), int(from.y / TILE))
	# The hearth is remembered and only handed back once the whole search has
	# found nothing else — see _is_last_resort.
	var fallback: Dictionary = {}
	for r: int in range(1, max_r + 1):
		var found: int = 0
		var best: Vector2i = Vector2i.ZERO
		for c: Vector2i in Grid.ring(centre, r):
			if c.x < 0 or c.y < 0 or c.x >= _map_w or c.y >= _map_h:
				continue
			var b: Object = _build.call("building_at", c)
			if b == null or not bool(b.call("is_complete")):
				continue
			if _is_last_resort(b):
				if fallback.is_empty():
					fallback = {"id": int(b.get("id")), "pos": Grid.cell_to_world(c)}
				continue
			found = int(b.get("id"))
			best = c
			break
		if found != 0:
			return {"id": found, "pos": Grid.cell_to_world(best)}
	# A caller that is redirecting something OFF the hearth must not be handed
	# the hearth back as the nearest thing to it. Not a hypothetical: the first
	# cut of this returned the fallback unconditionally, the attacker was
	# "redirected" onto what it was already standing on, and a 48-unit set piece
	# did 0 structural damage all night.
	return fallback if allow_last_resort else {}


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


## Has the player put up a perimeter at all? Cached hard, and never re-asked once
## the answer is yes: a city that has built a wall does not un-build it, and the
## question costs a full sweep of the building list to answer.
func _is_defended(tick: int) -> bool:
	if _defended:
		return true
	if tick - _defended_tick < DEFENDED_RECHECK_TICKS:
		return false
	_defended_tick = tick
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
	_has_withdraw = false
	_has_request = false
	_ammo_known.clear()
	for name: StringName in [&"logistics", &"production"] as Array[StringName]:
		var s: SimSystem = Sim.get_system(name)
		if s == null:
			continue
		var w: bool = s.has_method("withdraw")
		var r: bool = s.has_method("request_items")
		if not (w or r):
			continue
		_ammo_source = s
		_has_withdraw = w
		_has_request = r
		_ammo_method = ("withdraw+request_items" if w and r else ("withdraw" if w else "request_items"))
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
		"withdrawn": swarm.withdrawn,
		"stalls": swarm.stalls,
		"stalls_resolved": swarm.stalls_resolved,
		"retreating": swarm.retreating_count(),
		"damage_taken": snappedf(damage_taken, 0.01),
		"damage_dealt": snappedf(battery.damage_dealt, 0.01),
		"enemy_damage": snappedf(swarm.damage_dealt, 0.01),
		"structures_lost": structures_lost,
		"breaches": breaches,
		"toll_dead": toll.dead_total,
		"toll_hurt": toll.hurt_total,
		"toll_ledger": toll.ledger,
		"reinforcements": reinforcements,
		"shots_fired": battery.shots_fired,
		"heat_spent": snappedf(battery.heat_spent, 0.01),
		"heat_stolen": snappedf(battery.heat_stolen, 0.01),
		"heat_siphoned": snappedf(swarm.heat_siphoned, 0.01),
		"discontent": snappedf(swarm.discontent_raised, 0.01),
		"enemies": swarm.serialize(),
		"projectiles": shells.serialize(),
		"turrets": battery.serialize(),
		"director": director.serialize(),
		"external_tick": _external_tick,
		"field": assault.stats(),
		"gates": gates(),
		"census": swarm.census(),
	}


func deserialize(data: Dictionary) -> void:
	wave = int(data.get("wave", 0))
	_next_id = maxi(ENEMY_ID_BASE, int(data.get("next_id", ENEMY_ID_BASE)))
	swarm.kills = int(data.get("kills", 0))
	swarm.leaked = int(data.get("leaked", 0))
	swarm.withdrawn = int(data.get("withdrawn", 0))
	swarm.stalls = int(data.get("stalls", 0))
	swarm.stalls_resolved = int(data.get("stalls_resolved", 0))
	damage_taken = float(data.get("damage_taken", 0.0))
	battery.damage_dealt = float(data.get("damage_dealt", 0.0))
	swarm.damage_dealt = float(data.get("enemy_damage", 0.0))
	structures_lost = int(data.get("structures_lost", 0))
	breaches = int(data.get("breaches", 0))
	toll.dead_total = int(data.get("toll_dead", 0))
	toll.hurt_total = int(data.get("toll_hurt", 0))
	reinforcements = int(data.get("reinforcements", 0))
	toll.ledger.clear()
	for row: Variant in (data.get("toll_ledger", []) as Array):
		if typeof(row) == TYPE_DICTIONARY:
			toll.ledger.append(row)
	battery.shots_fired = int(data.get("shots_fired", 0))
	battery.heat_spent = float(data.get("heat_spent", 0.0))
	battery.heat_stolen = float(data.get("heat_stolen", 0.0))
	swarm.heat_siphoned = float(data.get("heat_siphoned", 0.0))
	swarm.discontent_raised = float(data.get("discontent", 0.0))
	_discontent_carry = swarm.discontent_raised
	swarm.deserialize(data.get("enemies", []), SimClock.tick)
	shells.deserialize(data.get("projectiles", []))
	director.deserialize(data.get("director", {}), swarm)
	_external_tick = int(data.get("external_tick", -1))
	_sync_turrets()
	for entry: Variant in data.get("turrets", []):
		var t: Dictionary = entry
		battery.restore(int(t.get("id", -1)), t)
	if swarm.count > 0:
		_ensure_field()
	for entry: Variant in data.get("gates", []):
		var g: Dictionary = entry
		if bool(g.get("open", false)):
			set_gate_open(int(g.get("id", -1)), true)


func metrics() -> Dictionary:
	# No wall-clock column: tools/determinism.sh diffs metrics.csv, and a timing
	# number in a diffed artifact is a tripwire. _step_us lives in the log only.
	return {
		"enemies_alive": swarm.fighting_count(),
		"bodies": swarm.count,
		"kills": swarm.kills,
		"withdrawn": swarm.withdrawn,
		"stalls": swarm.stalls,
		"damage_taken": snappedf(damage_taken, 0.01),
		"damage_dealt": snappedf(battery.damage_dealt, 0.01),
		"turret_uptime": snappedf(battery.uptime(), 0.0001),
		"turret_engaged": snappedf(battery.engagement(), 0.0001),
		"shots_fired": battery.shots_fired,
		"heat_spent_on_defence": snappedf(battery.heat_spent, 0.01),
		"turrets": battery.count(),
		"projectiles": shells.count,
		"structures_lost": structures_lost,
		"breaches": breaches,
		"citizens_killed": toll.dead_total,
		"citizens_hurt": toll.hurt_total,
		"reinforcements": reinforcements,
		"wave": wave,
	}


## Microseconds the last step() took. Log and tests only — never metrics().
func last_step_usec() -> int:
	return _step_us

class_name EnemySwarm
extends RefCounted
## Every enemy in the world, stored as parallel packed arrays.
##
## This is written as a structure of arrays and not as five hundred RefCounted
## objects for one reason: the brief is five hundred attackers inside a 2 ms
## slice of a 50 ms tick, and in GDScript the cost of a hot loop is dominated by
## property lookups and object headers, not by arithmetic. Here the inner loop
## touches typed [PackedFloat32Array] elements and local ints, allocates nothing,
## and calls nothing per enemy. Definitions are read out of [CombatEnemyDef] exactly
## once at world creation into a parallel def table, so a Resource property is
## never touched while the game is running.
##
## Three rules the movement obeys, in order:
##   1. If an open route to the core exists, take it — that is [P01]'s core flow
##      field, which treats structures as solid and therefore describes the gap
##      the player left.
##   2. If there is none, follow the dig gradient ([AssaultField]) and chew
##      through whatever the gradient points at, which is by construction the
##      thinnest and most damaged panel of the perimeter.
##   3. Burrowers and flyers skip both and go straight at the warm centre.
##
## The swarm never touches another system directly. Structural damage is handed
## back to [CombatSystem], which owns every cross-system call in this part.

const TILE: float = 32.0
const HALF_TILE: float = 16.0
## Coarse spatial hash cell, in tiles. Turret queries and splash both bucket on
## this; 8 keeps a 12-tile turret query at 4x4 buckets.
const BUCKET_TILES: int = 8
const BUCKET_PX: float = 256.0
## Ticks between the expensive per-enemy decisions (target seeking). Staggered by
## slot, so the cost is spread instead of spiking every tenth tick.
const THINK_PERIOD: int = 10
## How far ahead an enemy tests for something solid, in pixels.
const PROBE_PX: float = 20.0
## Attack reach is measured to the centre of the tile being hit, so every reach
## carries half a tile of slack for the tile itself.
const REACH_SLACK: float = 16.0

# ------------------------------------------------------------- the watchdog --
# A keener born on tick 17036 was still standing on tick 24000 at full health,
# parked exactly at its eight-tile reach from a storage yard nobody had a gun
# near, taking the city apart at four damage a second, for ever. It outlived its
# own night, it kept `live` above zero so no later night could ever end by
# "nothing is alive", and nothing anywhere logged a word about it.
#
# Three teeth, in order of how gentle they are:
#   1. PROGRESS. Getting closer to the hearth than ever before is progress; so
#      is landing a hit, and so is taking one. A body that has done NONE of the
#      three for STALL_TICKS is not fighting and not travelling — it is stuck —
#      so its target is dropped and it is made to look again. This deliberately
#      does not punish a breaker that spends a minute eating one wall: it is
#      hitting something, and that is the fight working.
#   2. PATIENCE. Three of those in a row and it breaks off and leaves.
#   3. LIFETIME. Whatever it is doing, nothing lives past MAX_LIFE_TICKS.
# Every one of them writes a line. A stall is now loud, bounded and countable —
# see [member stalls] and [member withdrawn].

## Ticks of no progress before a body is told to find something else.
const STALL_TICKS: int = 900
## Stalls in a row before it gives up and walks back out into the dark.
const MAX_STALLS: int = 3
## Nothing on this map lives longer than this, whatever it is doing. Six minutes
## of world time, against a night of under three.
const MAX_LIFE_TICKS: int = 7200
## Getting this much closer to the core (in px) counts as making progress.
const PROGRESS_PX: float = 24.0
## How close to the fire counts as being INSIDE, in pixels. Four tiles: the
## hearth district, not the hearth tile. The old test was one tile, and the flow
## field parks a body that has run out of targets against the hearth's own
## footprint — three tiles out — so the rule fired for nothing that actually
## happened in a run.
const INSIDE_PX: float = 128.0
## How long a body that has broken off keeps walking before it is simply gone.
const RETREAT_TICKS: int = 400
## ...and how much faster it walks while it does. They do not leave slowly.
const RETREAT_SPEED: float = 1.5

# ---------------------------------------------------------------- def table --

var def_count: int = 0
var d_id: Array[StringName] = []
var d_name: Array[String] = []
var d_arch: Array[StringName] = []
var d_res: Array[Resource] = []
var d_health: PackedFloat32Array = PackedFloat32Array()
var d_armour: PackedFloat32Array = PackedFloat32Array()
var d_speed: PackedFloat32Array = PackedFloat32Array()      ## px/s
var d_radius: PackedFloat32Array = PackedFloat32Array()     ## px
var d_damage: PackedFloat32Array = PackedFloat32Array()
var d_dtype: PackedInt32Array = PackedInt32Array()
var d_interval: PackedFloat32Array = PackedFloat32Array()
var d_reach: PackedFloat32Array = PackedFloat32Array()       ## px
var d_splash: PackedFloat32Array = PackedFloat32Array()      ## px
var d_pref_mult: PackedFloat32Array = PackedFloat32Array()
var d_pref: Array[StringName] = []
var d_seek: PackedFloat32Array = PackedFloat32Array()        ## px
var d_behaviour: PackedInt32Array = PackedInt32Array()
var d_ghost: PackedByteArray = PackedByteArray()             ## ignores walls
var d_surface: PackedFloat32Array = PackedFloat32Array()     ## px from core, -1 = always visible
var d_detonate: PackedByteArray = PackedByteArray()
var d_lifesteal: PackedFloat32Array = PackedFloat32Array()
var d_siphon: PackedFloat32Array = PackedFloat32Array()
var d_discontent: PackedFloat32Array = PackedFloat32Array()
var d_regen: PackedFloat32Array = PackedFloat32Array()
var d_regen_c: PackedFloat32Array = PackedFloat32Array()
var d_res_k: PackedFloat32Array = PackedFloat32Array()
var d_res_f: PackedFloat32Array = PackedFloat32Array()
var d_res_b: PackedFloat32Array = PackedFloat32Array()
var d_res_s: PackedFloat32Array = PackedFloat32Array()
var d_aura: PackedInt32Array = PackedInt32Array()
var d_aura_r: PackedFloat32Array = PackedFloat32Array()      ## px
var d_aura_p: PackedFloat32Array = PackedFloat32Array()
var d_spawn_def: PackedInt32Array = PackedInt32Array()
var d_spawn_n: PackedInt32Array = PackedInt32Array()
var d_spawn_frac: PackedFloat32Array = PackedFloat32Array()
var d_spawn_death: PackedByteArray = PackedByteArray()
var d_threat: PackedFloat32Array = PackedFloat32Array()
var d_weight: PackedFloat32Array = PackedFloat32Array()
var d_pack: PackedInt32Array = PackedInt32Array()
var d_min_day: PackedInt32Array = PackedInt32Array()

var _def_index: Dictionary[StringName, int] = {}

# ---------------------------------------------------------------- live set ---

var count: int = 0
var e_id: PackedInt32Array = PackedInt32Array()
var e_def: PackedInt32Array = PackedInt32Array()
var e_x: PackedFloat32Array = PackedFloat32Array()
var e_y: PackedFloat32Array = PackedFloat32Array()
var e_hx: PackedFloat32Array = PackedFloat32Array()
var e_hy: PackedFloat32Array = PackedFloat32Array()
var e_hp: PackedFloat32Array = PackedFloat32Array()
var e_cool: PackedFloat32Array = PackedFloat32Array()
var e_target: PackedInt32Array = PackedInt32Array()
var e_tx: PackedFloat32Array = PackedFloat32Array()
var e_ty: PackedFloat32Array = PackedFloat32Array()
var e_state: PackedByteArray = PackedByteArray()
var e_burn: PackedFloat32Array = PackedFloat32Array()
var e_burn_t: PackedFloat32Array = PackedFloat32Array()
var e_rally: PackedFloat32Array = PackedFloat32Array()
var e_gate: PackedFloat32Array = PackedFloat32Array()
var e_hidden: PackedByteArray = PackedByteArray()
var e_born: PackedInt32Array = PackedInt32Array()
## Ground speed multiplier under this body, resampled on its think tick. Snow
## depth moves slowly, and asking [WorldGrid] once per enemy per tick is five
## hundred cross-object calls to answer a question that changed by nothing.
var e_ground: PackedFloat32Array = PackedFloat32Array()
## WHERE THIS BODY ACTUALLY WENT LAST TICK, in px/s. Written by step() from the
## movement it really performed, zeroed before the movement runs, and read by
## every gunner that leads a shot. See [method velocity_at] for what it replaces
## and what that cost.
var e_vx: PackedFloat32Array = PackedFloat32Array()
var e_vy: PackedFloat32Array = PackedFloat32Array()
## Has this body already been counted as having got inside? One body crossing
## into the hearth district is one leak, however long it then stays there.
var e_inside: PackedByteArray = PackedByteArray()
## Watchdog: tick of the last real progress, closest-ever squared distance to the
## core, and how many times this body has already been prodded.
var e_prog: PackedInt32Array = PackedInt32Array()
var e_best: PackedFloat32Array = PackedFloat32Array()
var e_stalls: PackedByteArray = PackedByteArray()
## Tick at which a retreating body is off the map whether it got there or not.
var e_leave: PackedInt32Array = PackedInt32Array()

# ---------------------------------------------------------------- buckets ----

var bw: int = 0
var bh: int = 0
var _bucket_start: PackedInt32Array = PackedInt32Array()
var _bucket_items: PackedInt32Array = PackedInt32Array()
var _bucket_fill: PackedInt32Array = PackedInt32Array()

# ---------------------------------------------------------------- counters ---

var kills: int = 0
var leaked: int = 0            ## reached the core and stopped being ours to shoot
## Broke off and left the map. NOT a kill: the player did not earn these.
var withdrawn: int = 0
## Times the watchdog had to prod a body that was getting nowhere.
var stalls: int = 0
## ...and how many of those it eventually had to remove.
var stalls_resolved: int = 0
## Flat (id, x, y) triples for everything that died this tick.
var deaths: PackedInt32Array = PackedInt32Array()
## What the watchdog wants said out loud, drained by [CombatSystem] once a tick
## so the swarm itself never touches the log or the bus.
var reports: Array[Dictionary] = []
var damage_dealt: float = 0.0  ## to the player's structures, after their armour
var discontent_raised: float = 0.0
var heat_siphoned: float = 0.0

var _map_w: int = 0
var _map_h: int = 0
var _core_px: Vector2 = Vector2.ZERO
var _leave_px: float = 4096.0
var _spawn_queue: Array[Dictionary] = []


# =========================================================================
# definitions
# =========================================================================

## Reads every CombatEnemyDef in the registry into the def table. Returns the problems
## found, so the caller can put them in the log once instead of per spawn.
func load_defs() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var defs: Array[Resource] = Registry.all("enemies")
	var pending: Array[CombatEnemyDef] = []
	var seen: Dictionary[StringName, bool] = {}
	for res: Resource in defs:
		# Adopt foreign schemas too — see CombatEnemyDef.from_resource. Registry
		# already returns "enemies" sorted by id, so this order is stable.
		var d: CombatEnemyDef = CombatEnemyDef.from_resource(res)
		if d == null:
			continue
		if seen.has(d.id):
			problems.append("%s: two definitions claim this id" % d.id)
			continue
		seen[d.id] = true
		var bad: PackedStringArray = d.validate()
		if not bad.is_empty():
			for b: String in bad:
				problems.append("%s: %s" % [d.id, b])
			continue
		pending.append(d)
	_reset_defs(pending.size())
	for i: int in range(pending.size()):
		_install_def(i, pending[i])
	# Second pass: cross-references between definitions can only be resolved once
	# every id is in the table.
	for i2: int in range(pending.size()):
		var kind: StringName = pending[i2].spawns_kind
		d_spawn_def[i2] = int(_def_index.get(kind, -1)) if String(kind) != "" else -1
		if String(kind) != "" and d_spawn_def[i2] < 0:
			problems.append("%s: spawns_kind '%s' is not an enemy" % [pending[i2].id, kind])
	return problems


func has_kind(kind: StringName) -> bool:
	return _def_index.has(kind)


func def_slot(kind: StringName) -> int:
	return int(_def_index.get(kind, -1))


func def_resource(slot: int) -> CombatEnemyDef:
	return d_res[slot] as CombatEnemyDef if slot >= 0 and slot < def_count else null


func kind_of_slot(slot: int) -> StringName:
	return d_id[slot] if slot >= 0 and slot < def_count else &""


## Render archetype [P13]'s sprite factory bakes agents for: swarm or brute.
func arch_of_slot(slot: int) -> StringName:
	return d_arch[slot] if slot >= 0 and slot < def_count else &"swarm"


func threat_of_slot(slot: int) -> float:
	return d_threat[slot] if slot >= 0 and slot < def_count else 1.0


func pack_of_slot(slot: int) -> int:
	return d_pack[slot] if slot >= 0 and slot < def_count else 1


## Every kind that may be rolled into a wave on this day, with its weight.
func rollable(day: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: int in range(def_count):
		if d_weight[i] <= 0.0 or d_min_day[i] > day:
			continue
		out.append({"slot": i, "weight": d_weight[i], "threat": d_threat[i], "pack": d_pack[i]})
	return out


# =========================================================================
# world binding
# =========================================================================

func bind_world(map_w: int, map_h: int, core_cell: Vector2i) -> void:
	_map_w = map_w
	_map_h = map_h
	_core_px = Vector2(float(core_cell.x) * TILE + HALF_TILE, float(core_cell.y) * TILE + HALF_TILE)
	# Far enough out that a body which reaches it is off any part of the map the
	# player is looking at, close enough that leaving does not take a whole night.
	_leave_px = float(maxi(map_w, map_h)) * TILE * 0.55
	bw = maxi(1, (map_w + BUCKET_TILES - 1) / BUCKET_TILES)
	bh = maxi(1, (map_h + BUCKET_TILES - 1) / BUCKET_TILES)
	_bucket_start = PackedInt32Array()
	_bucket_start.resize(bw * bh + 1)
	_bucket_fill = PackedInt32Array()
	_bucket_fill.resize(bw * bh)


# =========================================================================
# population
# =========================================================================

## Adds one enemy at a world position. Returns its slot, or -1.
func spawn(slot_def: int, pos: Vector2, new_id: int, tick: int) -> int:
	if slot_def < 0 or slot_def >= def_count:
		return -1
	var i: int = count
	count += 1
	_grow(count)
	e_id[i] = new_id
	e_def[i] = slot_def
	e_x[i] = pos.x
	e_y[i] = pos.y
	var to_core: Vector2 = _core_px - pos
	var l: float = to_core.length()
	e_hx[i] = to_core.x / l if l > 0.001 else 1.0
	e_hy[i] = to_core.y / l if l > 0.001 else 0.0
	e_hp[i] = d_health[slot_def]
	e_cool[i] = 0.0
	e_target[i] = -1
	e_tx[i] = 0.0
	e_ty[i] = 0.0
	e_state[i] = CombatTypes.EnemyState.WALKING
	e_burn[i] = 0.0
	e_burn_t[i] = 0.0
	e_rally[i] = 0.0
	e_gate[i] = d_health[slot_def] * (1.0 - d_spawn_frac[slot_def]) if d_spawn_frac[slot_def] > 0.0 else -1.0
	e_hidden[i] = 1 if d_surface[slot_def] >= 0.0 else 0
	e_born[i] = tick
	e_ground[i] = 1.0
	e_prog[i] = tick
	e_best[i] = to_core.x * to_core.x + to_core.y * to_core.y
	e_stalls[i] = 0
	e_leave[i] = 0
	e_vx[i] = 0.0
	e_vy[i] = 0.0
	e_inside[i] = 0
	return i


## Slot holding `enemy_id`, or -1. Linear, so callers cache slots and verify with
## [method id_at] instead of looking up every tick.
func slot_of(enemy_id: int) -> int:
	for i: int in range(count):
		if e_id[i] == enemy_id:
			return i
	return -1


func id_at(slot: int) -> int:
	return e_id[slot] if slot >= 0 and slot < count else -1


func position_at(slot: int) -> Vector2:
	return Vector2(e_x[slot], e_y[slot]) if slot >= 0 and slot < count else Vector2.ZERO


func alive_at(slot: int) -> bool:
	return slot >= 0 and slot < count and e_state[slot] != CombatTypes.EnemyState.SPENT


func clear_population() -> void:
	count = 0
	_spawn_queue.clear()


# =========================================================================
# damage
# =========================================================================

## Applies one hit. Returns the damage that actually landed. `slot` must still
## hold `expect_id`; the generation check is what makes it safe to cache slots in
## projectiles across a compaction.
func hurt(slot: int, expect_id: int, raw: float, channel: int, pierce: float, tick: int) -> float:
	if slot < 0 or slot >= count or e_id[slot] != expect_id:
		return 0.0
	if e_state[slot] == CombatTypes.EnemyState.SPENT:
		return 0.0
	var d: int = e_def[slot]
	if e_hidden[slot] == 1:
		return 0.0
	var dealt: float = CombatTypes.resolve_damage(raw, _resist(d, channel), d_armour[d], pierce)
	if dealt <= 0.0:
		return 0.0
	# Being shot at is not being stuck. A body standing in a kill zone is exactly
	# where the game wants it; only the watchdog's hard lifetime applies to it.
	e_prog[slot] = tick
	e_hp[slot] -= dealt
	if e_gate[slot] >= 0.0 and e_hp[slot] <= e_gate[slot] and e_hp[slot] > 0.0:
		_queue_adds(slot, tick)
		e_gate[slot] -= d_health[d] * d_spawn_frac[d]
	if e_hp[slot] <= 0.0:
		_kill(slot, tick)
	return dealt


## Sets a burn on a slot. Burns do not stack in intensity, they refresh duration
## and keep the stronger source — otherwise two flame turrets would multiply
## rather than overlap.
func ignite(slot: int, expect_id: int, dps: float, seconds: float) -> void:
	if slot < 0 or slot >= count or e_id[slot] != expect_id or dps <= 0.0:
		return
	e_burn[slot] = maxf(e_burn[slot], dps)
	e_burn_t[slot] = maxf(e_burn_t[slot], seconds)


## Damage in a disc. Returns total damage delivered. Used by splash, by
## detonations and by the boss.
func splash(centre: Vector2, radius_px: float, raw: float, channel: int,
		pierce: float, falloff: float, tick: int) -> float:
	if radius_px <= 0.0:
		return 0.0
	var total: float = 0.0
	var r2: float = radius_px * radius_px
	for i: int in query(centre, radius_px):
		if e_state[i] == CombatTypes.EnemyState.SPENT or e_hidden[i] == 1:
			continue
		var dx: float = e_x[i] - centre.x
		var dy: float = e_y[i] - centre.y
		var dist2: float = dx * dx + dy * dy
		if dist2 > r2:
			continue
		var t: float = sqrt(dist2) / radius_px
		var scale: float = 1.0 - t * (1.0 - clampf(falloff, 0.0, 1.0))
		total += hurt(i, e_id[i], raw * scale, channel, pierce, tick)
	return total


func _kill(slot: int, tick: int) -> void:
	if e_state[slot] == CombatTypes.EnemyState.SPENT:
		return
	e_state[slot] = CombatTypes.EnemyState.SPENT
	e_hp[slot] = 0.0
	kills += 1
	deaths.append(e_id[slot])
	deaths.append(int(e_x[slot]))
	deaths.append(int(e_y[slot]))
	var d: int = e_def[slot]
	if d_spawn_death[d] == 1:
		_queue_adds(slot, tick)


## THIS ONE IS INSIDE. A body that has reached the hearth district is not
## something the guns can still answer: it is past the line, it has taken
## whatever it came for, and it is gone by morning. Counted as a leak rather
## than a kill, so the night's post-mortem cannot mistake it for the wall
## working. [CombatSystem] calls this instead of letting an attacker chew on the
## fire — see _is_last_resort.
func absorb(slot: int, tick: int) -> void:
	if slot < 0 or slot >= count:
		return
	if e_state[slot] == CombatTypes.EnemyState.SPENT:
		return
	leaked += 1
	_kill(slot, tick)


## Drains this tick's death record as flat (id, x, y) triples. [CombatSystem]
## turns them into Bus.enemy_killed so the view can put an ember where each one
## fell; the swarm itself never touches the signal bus.
func take_deaths() -> PackedInt32Array:
	if deaths.is_empty():
		return PackedInt32Array()
	var out: PackedInt32Array = deaths
	deaths = PackedInt32Array()
	return out


func _queue_adds(slot: int, _tick: int) -> void:
	var d: int = e_def[slot]
	if d_spawn_def[d] < 0 or d_spawn_n[d] <= 0:
		return
	_spawn_queue.append({
		"def": d_spawn_def[d],
		"count": d_spawn_n[d],
		"pos": Vector2(e_x[slot], e_y[slot]),
		"seed": e_id[slot],
	})


## Adds requested by phase gates and deaths this tick. Drained by [CombatSystem],
## which owns id minting.
func take_spawn_requests() -> Array[Dictionary]:
	if _spawn_queue.is_empty():
		return []
	var out: Array[Dictionary] = _spawn_queue
	_spawn_queue = []
	return out


# =========================================================================
# spatial index
# =========================================================================

## Rebuilds the bucket index. Counting sort: three linear passes and no
## allocation after the first tick.
func reindex() -> void:
	var nb: int = bw * bh
	if nb <= 0:
		return
	for b: int in range(nb):
		_bucket_fill[b] = 0
	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			continue
		_bucket_fill[_bucket_of(e_x[i], e_y[i])] += 1
	var acc: int = 0
	for b2: int in range(nb):
		_bucket_start[b2] = acc
		acc += _bucket_fill[b2]
		_bucket_fill[b2] = _bucket_start[b2]
	_bucket_start[nb] = acc
	if _bucket_items.size() < acc:
		_bucket_items.resize(maxi(acc, 64))
	for i2: int in range(count):
		if e_state[i2] == CombatTypes.EnemyState.SPENT:
			continue
		var b3: int = _bucket_of(e_x[i2], e_y[i2])
		_bucket_items[_bucket_fill[b3]] = i2
		_bucket_fill[b3] += 1


## Slots whose bucket overlaps the disc. A superset — callers still test the
## exact distance, which is cheaper than making the buckets fine-grained.
func query(centre: Vector2, radius_px: float) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if bw <= 0:
		return out
	var x0: int = clampi(int((centre.x - radius_px) / BUCKET_PX), 0, bw - 1)
	var x1: int = clampi(int((centre.x + radius_px) / BUCKET_PX), 0, bw - 1)
	var y0: int = clampi(int((centre.y - radius_px) / BUCKET_PX), 0, bh - 1)
	var y1: int = clampi(int((centre.y + radius_px) / BUCKET_PX), 0, bh - 1)
	for by: int in range(y0, y1 + 1):
		var row: int = by * bw
		for bx: int in range(x0, x1 + 1):
			var b: int = row + bx
			var s: int = _bucket_start[b]
			var e: int = _bucket_start[b + 1]
			for k: int in range(s, e):
				out.append(_bucket_items[k])
	return out


func _bucket_of(x: float, y: float) -> int:
	var bx: int = clampi(int(x / BUCKET_PX), 0, bw - 1)
	var by: int = clampi(int(y / BUCKET_PX), 0, bh - 1)
	return by * bw + bx


# =========================================================================
# the tick
# =========================================================================

## Advances every enemy one tick. `sys` receives the cross-system calls: it is
## passed in rather than stored, because two RefCounted systems holding each
## other never get released.
func step(tick: int, sys: Object, gcost: PackedByteArray, open_dir: PackedByteArray,
		assault: AssaultField, warm: Object, snow: Object) -> void:
	var dt: float = SimClock.DT
	var w: int = _map_w
	var h: int = _map_h
	var cx: float = _core_px.x
	var cy: float = _core_px.y
	var has_open: bool = open_dir.size() == w * h
	var has_assault: bool = assault != null and assault.ready
	var acost: PackedByteArray = assault.cost if has_assault else PackedByteArray()
	var afield: FlowField = assault.field if has_assault else null
	var adir: PackedByteArray = afield.direction if afield != null else PackedByteArray()

	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			continue
		var d: int = e_def[i]
		var px: float = e_x[i]
		var py: float = e_y[i]
		# Cleared HERE, before anything can `continue` past the movement block,
		# so a body that does not move this tick reports that it did not move.
		# Leaving last tick's value behind is the whole bug velocity_at names.
		e_vx[i] = 0.0
		e_vy[i] = 0.0

		# --- burning, regeneration ---------------------------------------
		if e_burn_t[i] > 0.0:
			e_burn_t[i] -= dt
			e_hp[i] -= e_burn[i] * dt
			if e_burn_t[i] <= 0.0:
				e_burn[i] = 0.0
			if e_hp[i] <= 0.0:
				_kill(i, tick)
				continue
		# --- leaving ------------------------------------------------------
		# A body that has broken off is out of the fight but still on the map,
		# still shootable, and visibly walking away. That is the whole point:
		# a night ENDS on screen instead of quietly leaving something behind.
		if e_state[i] == CombatTypes.EnemyState.RETREATING:
			var ox: float = px - cx
			var oy: float = py - cy
			var od: float = sqrt(ox * ox + oy * oy)
			if tick >= e_leave[i] or od > _leave_px:
				_depart(i)
				continue
			if od > 0.001:
				e_hx[i] = ox / od
				e_hy[i] = oy / od
			var rs: float = d_speed[d] * RETREAT_SPEED * e_ground[i] * dt
			e_x[i] = px + e_hx[i] * rs
			e_y[i] = py + e_hy[i] * rs
			e_vx[i] = e_hx[i] * rs / dt
			e_vy[i] = e_hy[i] * rs / dt
			continue

		var cell_x: int = clampi(int(px / TILE), 0, w - 1)
		var cell_y: int = clampi(int(py / TILE), 0, h - 1)
		var idx: int = cell_y * w + cell_x

		# --- surfacing ----------------------------------------------------
		if e_hidden[i] == 1:
			var ddx: float = px - cx
			var ddy: float = py - cy
			if ddx * ddx + ddy * ddy <= d_surface[d] * d_surface[d]:
				e_hidden[i] = 0

		# --- the think tick: everything that costs a cross-object call ----
		var behav: int = d_behaviour[d]
		# ONE BODY IN TEN THINKS EACH TICK, STAGGERED BY SLOT — not "only the
		# slots divisible by ten, every tick", which is what
		# `(i + tick) % THINK_PERIOD == tick % THINK_PERIOD` reduces to: that
		# condition is true exactly when i is a multiple of THINK_PERIOD and
		# does not depend on the tick at all. Nine bodies in ten therefore never
		# ran the stall watchdog, never re-read their ground speed, never
		# regenerated, never aged out, and — the reason it was finally caught —
		# NEVER LOOKED FOR A TARGET. Ten snow widows stood one tile from a
		# housing block for the last twelve hundred ticks of a night with
		# `target -1`, because seeking only happens on a think tick and their
		# slots were not multiples of ten. The cost is identical either way:
		# count/THINK_PERIOD bodies think per tick before and after.
		if (i + tick) % THINK_PERIOD == 0:
			# The watchdog runs first, so a body it prods gets to act this tick
			# rather than standing still for another half-second.
			var wx: float = px - cx
			var wy: float = py - cy
			var wd2: float = wx * wx + wy * wy
			if wd2 < e_best[i] - PROGRESS_PX * PROGRESS_PX:
				e_best[i] = wd2
				e_prog[i] = tick
				e_stalls[i] = 0
			elif tick - e_prog[i] >= STALL_TICKS:
				_stalled(i, tick, wd2)
				if e_state[i] == CombatTypes.EnemyState.RETREATING:
					continue
			if tick - e_born[i] > MAX_LIFE_TICKS:
				_expire(i, tick)
				continue
			if snow != null and d_ghost[d] == 0:
				e_ground[i] = float(snow.call("speed_scale", Vector2i(cell_x, cell_y)))
			if d_regen[d] > 0.0 and e_hp[i] < d_health[d]:
				var here: float = -40.0
				if warm != null:
					here = float(warm.call("temperature_at", Vector2i(cell_x, cell_y)))
				if here <= d_regen_c[d]:
					e_hp[i] = minf(d_health[d], e_hp[i] + d_regen[d] * dt * float(THINK_PERIOD))
			if e_target[i] < 0 and d_seek[d] > 0.0:
				var found: Dictionary = sys.call("find_enemy_target", Vector2(px, py), d_pref[d], d_seek[d])
				if not found.is_empty():
					e_target[i] = int(found["id"])
					var tp: Vector2 = found["pos"]
					e_tx[i] = tp.x
					e_ty[i] = tp.y

		# --- movement ------------------------------------------------------
		var speed: float = d_speed[d] * (1.0 + e_rally[i]) * e_ground[i]
		var dirx: float = 0.0
		var diry: float = 0.0

		if e_target[i] >= 0:
			dirx = e_tx[i] - px
			diry = e_ty[i] - py
			var td: float = sqrt(dirx * dirx + diry * diry)
			if td <= d_reach[d]:
				dirx = 0.0
				diry = 0.0
			elif td > 0.001:
				dirx /= td
				diry /= td
		elif d_ghost[d] == 1:
			dirx = cx - px
			diry = cy - py
			var cd: float = sqrt(dirx * dirx + diry * diry)
			if cd > 0.001:
				dirx /= cd
				diry /= cd
		else:
			var step_dir: int = 8
			if has_open:
				step_dir = open_dir[idx]
			if step_dir >= 8 and has_assault:
				step_dir = adir[idx]
			if step_dir < 8:
				var v: Vector2i = Grid.DIRS8[step_dir]
				dirx = float(v.x)
				diry = float(v.y)
				if step_dir % 2 == 1:
					dirx *= 0.70710678
					diry *= 0.70710678
			else:
				dirx = cx - px
				diry = cy - py
				var cd2: float = sqrt(dirx * dirx + diry * diry)
				if cd2 > 0.001:
					dirx /= cd2
					diry /= cd2

		# Smooth the heading so a field that flips between two diagonals does not
		# make the pack stutter, and offset each body across the lane so five
		# hundred attackers do not walk down one pixel-wide line.
		if dirx != 0.0 or diry != 0.0:
			var hx: float = e_hx[i] * 0.72 + dirx * 0.28
			var hy: float = e_hy[i] * 0.72 + diry * 0.28
			var hl: float = sqrt(hx * hx + hy * hy)
			if hl > 0.001:
				e_hx[i] = hx / hl
				e_hy[i] = hy / hl

		var mvx: float = 0.0
		var mvy: float = 0.0
		if (dirx != 0.0 or diry != 0.0) and speed > 0.0:
			mvx = e_hx[i] * speed * dt
			mvy = e_hy[i] * speed * dt

		# --- what is in the way -------------------------------------------
		var blocker: int = 0
		if d_ghost[d] == 0 and (mvx != 0.0 or mvy != 0.0):
			var ax: float = px + mvx + e_hx[i] * PROBE_PX
			var ay: float = py + mvy + e_hy[i] * PROBE_PX
			var acx: int = clampi(int(ax / TILE), 0, w - 1)
			var acy: int = clampi(int(ay / TILE), 0, h - 1)
			var aidx: int = acy * w + acx
			if gcost[aidx] == Grid.IMPASSABLE:
				# Terrain refuses everyone; a structure is something to chew on.
				# With the siege surface up, its cost array answers "terrain or
				# building" for free. Without it — the seconds between a spawn and
				# the surface landing — ask [P11] directly rather than letting a
				# pack mill about in front of a wall it is allowed to eat.
				# blocker_at, not structure_at: the fire is impassable but it is
				# not something to chew on while the city still stands, and a
				# body told otherwise spends the rest of the night pressed
				# against it doing nothing. See CombatSystem.blocker_at.
				if not has_assault or acost[aidx] != Grid.IMPASSABLE:
					blocker = int(sys.call("blocker_at", Vector2i(acx, acy)))
				if blocker == 0:
					# Slide along the obstacle rather than grinding into it.
					var sx: float = px + mvx
					var scx: int = clampi(int(sx / TILE), 0, w - 1)
					if gcost[cell_y * w + scx] == Grid.IMPASSABLE:
						mvx = 0.0
					var sy: float = py + mvy
					var scy: int = clampi(int(sy / TILE), 0, h - 1)
					if gcost[scy * w + cell_x] == Grid.IMPASSABLE:
						mvy = 0.0
				else:
					mvx = 0.0
					mvy = 0.0
					# Whatever is physically in the way becomes the problem, unless
					# the thing already being shelled is still inside reach — that
					# is what lets a siege engine keep lobbing over the wall it is
					# standing against instead of deadlocking on it.
					var keep: bool = false
					if e_target[i] >= 0:
						var kx: float = e_tx[i] - px
						var ky: float = e_ty[i] - py
						keep = kx * kx + ky * ky <= d_reach[d] * d_reach[d]
					if not keep:
						e_target[i] = blocker
						e_tx[i] = float(acx) * TILE + HALF_TILE
						e_ty[i] = float(acy) * TILE + HALF_TILE

		e_x[i] = px + mvx
		e_y[i] = py + mvy
		# The ONLY place a walking body's velocity is written, and it is written
		# from the movement that survived the blocker probe and the slide — not
		# from the heading it wanted. A body pinned against a wall moves zero and
		# now says zero.
		e_vx[i] = mvx / dt
		e_vy[i] = mvy / dt

		# --- attacking ------------------------------------------------------
		if e_cool[i] > 0.0:
			e_cool[i] -= dt
		if e_target[i] >= 0:
			var rx: float = e_tx[i] - e_x[i]
			var ry: float = e_ty[i] - e_y[i]
			var rd: float = sqrt(rx * rx + ry * ry)
			if rd <= d_reach[d]:
				e_state[i] = CombatTypes.EnemyState.ATTACKING
				if e_cool[i] <= 0.0:
					e_cool[i] = d_interval[d]
					var landed: float = float(sys.call("enemy_attack", i, e_target[i],
						Vector2(e_tx[i], e_ty[i])))
					if landed < 0.0:
						# Whatever it was chewing is gone. That is progress even
						# though the body has not moved a pixel, and the watchdog
						# has to be told or it would eventually pull a working
						# breaker off a wall it is halfway through.
						e_target[i] = -1
						e_prog[i] = tick
						e_stalls[i] = 0
						e_state[i] = CombatTypes.EnemyState.WALKING
					else:
						damage_dealt += landed
						if landed > 0.0:
							# Landing hits is the fight working, whether or not
							# the body has moved a pixel this minute.
							e_prog[i] = tick
						if d_lifesteal[d] > 0.0:
							e_hp[i] = minf(d_health[d], e_hp[i] + landed * d_lifesteal[d])
						if d_detonate[d] == 1:
							_kill(i, tick)
			else:
				e_state[i] = CombatTypes.EnemyState.WALKING
		else:
			e_state[i] = CombatTypes.EnemyState.WALKING
			# IT IS INSIDE, AND BEING INSIDE HAS TO COST THE CITY SOMETHING.
			#
			# This used to read `leaked += 1; _kill(i, tick)`: a body that walked
			# all the way to the fire with nothing it was allowed to attack simply
			# evaporated, and the player paid nothing at all for the hole it came
			# through. That is not a hypothetical either. On night one of the
			# reference run three drift hounds arrived at 128,131 — three tiles
			# off the hearth, which is outside the one-tile absorb radius — and so
			# they did not even evaporate: they stood there for 2600 ticks doing
			# nothing while the wall shot at them. (That stall is real and the gate
			# saw it: at 535f1a8 the first_night contract failed `no enemy stands
			# still for 2400 ticks` naming these three bodies at full HP; on this
			# build that check passes.) What must NOT be carried forward is the
			# rest of the old premise — that every structure lost was perimeter
			# furniture and combat.citizens_killed read 0. That is [E1]-era and
			# stale; see the note on CombatSystem.inside_target for what replaced
			# it and why the number depends on how long you run.
			#
			# Now it turns on the hearth district. CombatSystem.inside_target
			# picks what — housing first, because the warmth they came for is the
			# warmth people sleep in, and never the fire itself. When there is
			# genuinely nothing left but the fire it is still absorbed, which is
			# what stops one body ending a run on the win condition.
			if behav != CombatTypes.Behaviour.SIEGE:
				var lx: float = e_x[i] - cx
				var ly: float = e_y[i] - cy
				if lx * lx + ly * ly < INSIDE_PX * INSIDE_PX:
					if e_inside[i] == 0:
						e_inside[i] = 1
						leaked += 1
					var got: Dictionary = sys.call("inside_target", Vector2(e_x[i], e_y[i]))
					if got.is_empty():
						_kill(i, tick)
					else:
						e_target[i] = int(got["id"])
						var gp: Vector2 = got["pos"]
						e_tx[i] = gp.x
						e_ty[i] = gp.y
						# It has found something: that is progress, or the
						# watchdog would pull it straight back off again.
						e_prog[i] = tick
						e_stalls[i] = 0

		e_rally[i] = 0.0


## Applies support auras. Runs after movement so a rally granted this tick is
## spent next tick, which keeps the effect order independent of slot order.
func apply_auras(sys: Object) -> void:
	for i: int in range(count):
		# A thing that is running does not rally anybody and does not chill a gun.
		if e_state[i] == CombatTypes.EnemyState.SPENT \
				or e_state[i] == CombatTypes.EnemyState.RETREATING:
			continue
		var d: int = e_def[i]
		var kind: int = d_aura[d]
		if kind == CombatTypes.Aura.NONE:
			continue
		var r: float = d_aura_r[d]
		var p: float = d_aura_p[d]
		var centre: Vector2 = Vector2(e_x[i], e_y[i])
		if kind == CombatTypes.Aura.RALLY:
			var r2: float = r * r
			for j: int in query(centre, r):
				if j == i or e_state[j] == CombatTypes.EnemyState.SPENT:
					continue
				var dx: float = e_x[j] - centre.x
				var dy: float = e_y[j] - centre.y
				if dx * dx + dy * dy <= r2:
					e_rally[j] = maxf(e_rally[j], p)
		elif kind == CombatTypes.Aura.CHILL:
			sys.call("chill_turrets", centre, r, p)


## Passive per-second effects that are not damage: morale pressure and the heat a
## siphon steals out of the magazines around it.
func apply_pressure(sys: Object) -> void:
	var dt: float = SimClock.DT
	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT \
				or e_state[i] == CombatTypes.EnemyState.RETREATING:
			continue
		var d: int = e_def[i]
		if d_discontent[d] > 0.0:
			discontent_raised += d_discontent[d] * dt
		if d_siphon[d] > 0.0 and e_state[i] == CombatTypes.EnemyState.ATTACKING:
			var taken: float = float(sys.call("siphon_turrets",
				Vector2(e_x[i], e_y[i]), maxf(d_aura_r[d], 128.0), d_siphon[d] * dt))
			heat_siphoned += taken


# =========================================================================
# the watchdog
# =========================================================================

## Orders one body to break off. Returns false when it was already leaving or
## already dead. A retreating body keeps its hit points and stays shootable —
## the player is allowed to take it in the back on its way out.
func retreat(slot: int, tick: int, reason: StringName) -> bool:
	if slot < 0 or slot >= count:
		return false
	if e_state[slot] == CombatTypes.EnemyState.SPENT \
			or e_state[slot] == CombatTypes.EnemyState.RETREATING:
		return false
	e_state[slot] = CombatTypes.EnemyState.RETREATING
	e_target[slot] = -1
	e_cool[slot] = 0.0
	e_leave[slot] = tick + RETREAT_TICKS
	var to_out: Vector2 = Vector2(e_x[slot], e_y[slot]) - _core_px
	var l: float = to_out.length()
	if l > 0.001:
		e_hx[slot] = to_out.x / l
		e_hy[slot] = to_out.y / l
	if reason != &"dawn":
		reports.append({"reason": String(reason), "id": e_id[slot],
			"kind": String(d_id[e_def[slot]]),
			"cell": [int(e_x[slot] / TILE), int(e_y[slot] / TILE)],
			"age": tick - e_born[slot], "hp": snappedf(e_hp[slot], 0.1)})
	return true


## Orders everything still fighting to break off. `only_born_before` limits it to
## bodies that were already on the map at that tick, which is how a dawn
## withdrawal never sends home something that walked in a second ago.
func withdraw_all(tick: int, reason: StringName = &"dawn") -> int:
	var n: int = 0
	for i: int in range(count):
		if retreat(i, tick, reason):
			n += 1
	return n


## Bodies that are still part of the fight: not dead, not walking away. This is
## the number a wave director must poll, because a retreating body is no longer
## anybody's problem and a night that waited for it would never end.
func fighting_count() -> int:
	var n: int = 0
	for i: int in range(count):
		var s: int = e_state[i]
		if s != CombatTypes.EnemyState.SPENT and s != CombatTypes.EnemyState.RETREATING:
			n += 1
	return n


func retreating_count() -> int:
	var n: int = 0
	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.RETREATING:
			n += 1
	return n


## Drains what the watchdog wants said. [CombatSystem] owns the log and the bus.
func take_reports() -> Array[Dictionary]:
	if reports.is_empty():
		return []
	var out: Array[Dictionary] = reports
	reports = []
	return out


## No ground gained and nothing destroyed for STALL_TICKS. Prod it: drop the
## target so it looks for another way in. Three of these and it goes home.
func _stalled(slot: int, tick: int, d2: float) -> void:
	stalls += 1
	e_prog[slot] = tick
	e_best[slot] = minf(e_best[slot], d2)
	e_stalls[slot] += 1
	if e_stalls[slot] >= MAX_STALLS:
		stalls_resolved += 1
		retreat(slot, tick, &"stalled")
		return
	reports.append({"reason": "stall", "id": e_id[slot],
		"kind": String(d_id[e_def[slot]]),
		"cell": [int(e_x[slot] / TILE), int(e_y[slot] / TILE)],
		"age": tick - e_born[slot], "strike": e_stalls[slot],
		"target": e_target[slot]})
	e_target[slot] = -1
	e_state[slot] = CombatTypes.EnemyState.WALKING


## Older than any night. Whatever it is doing, it is not this campaign's problem.
func _expire(slot: int, tick: int) -> void:
	stalls_resolved += 1
	retreat(slot, tick, &"expired")


## A retreating body reaching the dark. Not a kill, and never counted as one.
func _depart(slot: int) -> void:
	if e_state[slot] == CombatTypes.EnemyState.SPENT:
		return
	e_state[slot] = CombatTypes.EnemyState.SPENT
	withdrawn += 1


## Removes the dead. Swap-remove from the back, which keeps the array dense and
## is deterministic because the sweep order is fixed.
func compact() -> int:
	var removed: int = 0
	var i: int = count - 1
	while i >= 0:
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			var last: int = count - 1
			if i != last:
				_copy_slot(last, i)
			count -= 1
			removed += 1
		i -= 1
	return removed


# =========================================================================
# read-only views
# =========================================================================

## Enemies a turret may shoot at, inside `radius_px` of `centre`.
func targetable(centre: Vector2, radius_px: float) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var r2: float = radius_px * radius_px
	for i: int in query(centre, radius_px):
		if e_state[i] == CombatTypes.EnemyState.SPENT or e_hidden[i] == 1:
			continue
		var dx: float = e_x[i] - centre.x
		var dy: float = e_y[i] - centre.y
		if dx * dx + dy * dy <= r2:
			out.append(i)
	return out


func armour_at(slot: int) -> float:
	return d_armour[e_def[slot]] if slot >= 0 and slot < count else 0.0


func health_fraction(slot: int) -> float:
	if slot < 0 or slot >= count:
		return 0.0
	var m: float = d_health[e_def[slot]]
	return clampf(e_hp[slot] / m, 0.0, 1.0) if m > 0.0 else 0.0


## Where this body ACTUALLY went last tick, in px/s. What a gunner leads by.
##
## This used to return `heading × top speed`, which is a body's INTENTION and not
## its motion. Everything that had stopped moving without entering the ATTACKING
## state still claimed to be crossing the ground at full pace: a body pinned
## against a wall by the blocker probe, one sliding along an obstacle with both
## axes zeroed, one wading through deep snow at a fraction of speed (e_ground was
## never in the answer at all), and — the case that finally showed up in a run —
## one standing at the fire with nothing it is allowed to attack.
##
## Every gun in range then led that stationary target by up to a tile and a half
## and put every shell behind it. A projectile only counts as a hit within
## `body_radius + 6px` of the target, so the lead error was three times the hit
## window and the miss was total, not partial. On night one of the reference run
## that read as **871 shots, 3128 heat on the guns and SIX hits**: three drift
## hounds stood three tiles from the hearth for 2600 ticks while the whole wall
## shot at them, and `combat.damage_dealt` sat at 0.0 the entire time. A tower
## defence whose guns cannot hit something that is standing still is not a
## difficulty curve, it is a broken gun — and it burned the player's heat, which
## is the one resource all three genres in this build share.
func velocity_at(slot: int) -> Vector2:
	if slot < 0 or slot >= count:
		return Vector2.ZERO
	return Vector2(e_vx[slot], e_vy[slot])


func census() -> Dictionary:
	var out: Dictionary = {}
	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			continue
		var k: String = String(d_id[e_def[i]])
		out[k] = int(out.get(k, 0)) + 1
	return out


func total_health() -> float:
	var s: float = 0.0
	for i: int in range(count):
		if e_state[i] != CombatTypes.EnemyState.SPENT:
			s += e_hp[i]
	return s


func serialize() -> Array:
	var out: Array = []
	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			continue
		out.append({
			"id": e_id[i],
			"kind": String(d_id[e_def[i]]),
			"x": snappedf(e_x[i], 0.01),
			"y": snappedf(e_y[i], 0.01),
			"hx": snappedf(e_hx[i], 0.001),
			"hy": snappedf(e_hy[i], 0.001),
			"hp": snappedf(e_hp[i], 0.01),
			"cool": snappedf(e_cool[i], 0.001),
			"target": e_target[i],
			"tx": snappedf(e_tx[i], 0.01),
			"ty": snappedf(e_ty[i], 0.01),
			"state": e_state[i],
			"burn": snappedf(e_burn[i], 0.01),
			"burn_t": snappedf(e_burn_t[i], 0.001),
			"gate": snappedf(e_gate[i], 0.01),
			"hidden": e_hidden[i],
			"born": e_born[i],
			"prog": e_prog[i],
			"stalls": e_stalls[i],
			"leave": e_leave[i],
			"vx": snappedf(e_vx[i], 0.01),
			"vy": snappedf(e_vy[i], 0.01),
			"inside": e_inside[i],
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return out


func deserialize(rows: Array, tick: int) -> void:
	count = 0
	for entry: Variant in rows:
		var r: Dictionary = entry
		var slot: int = def_slot(StringName(String(r.get("kind", ""))))
		if slot < 0:
			continue
		var i: int = spawn(slot, Vector2(float(r.get("x", 0.0)), float(r.get("y", 0.0))),
			int(r.get("id", 0)), int(r.get("born", tick)))
		if i < 0:
			continue
		e_hx[i] = float(r.get("hx", 1.0))
		e_hy[i] = float(r.get("hy", 0.0))
		e_hp[i] = float(r.get("hp", d_health[slot]))
		e_cool[i] = float(r.get("cool", 0.0))
		e_target[i] = int(r.get("target", -1))
		e_tx[i] = float(r.get("tx", 0.0))
		e_ty[i] = float(r.get("ty", 0.0))
		e_state[i] = int(r.get("state", CombatTypes.EnemyState.WALKING))
		e_burn[i] = float(r.get("burn", 0.0))
		e_burn_t[i] = float(r.get("burn_t", 0.0))
		e_gate[i] = float(r.get("gate", -1.0))
		e_hidden[i] = int(r.get("hidden", 0))
		e_prog[i] = int(r.get("prog", int(r.get("born", tick))))
		e_stalls[i] = int(r.get("stalls", 0))
		e_leave[i] = int(r.get("leave", 0))
		e_vx[i] = float(r.get("vx", 0.0))
		e_vy[i] = float(r.get("vy", 0.0))
		e_inside[i] = int(r.get("inside", 0))


# =========================================================================
# internals
# =========================================================================

func _resist(d: int, channel: int) -> float:
	match channel:
		CombatTypes.Damage.KINETIC: return d_res_k[d]
		CombatTypes.Damage.FLAME: return d_res_f[d]
		CombatTypes.Damage.BLAST: return d_res_b[d]
		CombatTypes.Damage.SHOCK: return d_res_s[d]
	return 1.0


func _copy_slot(from: int, to: int) -> void:
	e_id[to] = e_id[from]
	e_def[to] = e_def[from]
	e_x[to] = e_x[from]
	e_y[to] = e_y[from]
	e_hx[to] = e_hx[from]
	e_hy[to] = e_hy[from]
	e_hp[to] = e_hp[from]
	e_cool[to] = e_cool[from]
	e_target[to] = e_target[from]
	e_tx[to] = e_tx[from]
	e_ty[to] = e_ty[from]
	e_state[to] = e_state[from]
	e_burn[to] = e_burn[from]
	e_burn_t[to] = e_burn_t[from]
	e_rally[to] = e_rally[from]
	e_gate[to] = e_gate[from]
	e_hidden[to] = e_hidden[from]
	e_born[to] = e_born[from]
	e_ground[to] = e_ground[from]
	e_prog[to] = e_prog[from]
	e_best[to] = e_best[from]
	e_stalls[to] = e_stalls[from]
	e_leave[to] = e_leave[from]
	e_vx[to] = e_vx[from]
	e_vy[to] = e_vy[from]
	e_inside[to] = e_inside[from]


func _grow(need: int) -> void:
	if e_id.size() >= need:
		return
	var cap: int = maxi(64, e_id.size() * 2)
	while cap < need:
		cap *= 2
	e_id.resize(cap)
	e_def.resize(cap)
	e_x.resize(cap)
	e_y.resize(cap)
	e_hx.resize(cap)
	e_hy.resize(cap)
	e_hp.resize(cap)
	e_cool.resize(cap)
	e_target.resize(cap)
	e_tx.resize(cap)
	e_ty.resize(cap)
	e_state.resize(cap)
	e_burn.resize(cap)
	e_burn_t.resize(cap)
	e_rally.resize(cap)
	e_gate.resize(cap)
	e_hidden.resize(cap)
	e_born.resize(cap)
	e_ground.resize(cap)
	e_prog.resize(cap)
	e_best.resize(cap)
	e_stalls.resize(cap)
	e_leave.resize(cap)
	e_vx.resize(cap)
	e_vy.resize(cap)
	e_inside.resize(cap)


func _reset_defs(n: int) -> void:
	def_count = n
	_def_index.clear()
	d_id = []
	d_name = []
	d_arch = []
	d_res = []
	d_id.resize(n)
	d_name.resize(n)
	d_arch.resize(n)
	d_res.resize(n)
	d_health = _f(n)
	d_armour = _f(n)
	d_speed = _f(n)
	d_radius = _f(n)
	d_damage = _f(n)
	d_interval = _f(n)
	d_reach = _f(n)
	d_splash = _f(n)
	d_pref_mult = _f(n)
	d_seek = _f(n)
	d_surface = _f(n)
	d_lifesteal = _f(n)
	d_siphon = _f(n)
	d_discontent = _f(n)
	d_regen = _f(n)
	d_regen_c = _f(n)
	d_res_k = _f(n)
	d_res_f = _f(n)
	d_res_b = _f(n)
	d_res_s = _f(n)
	d_aura_r = _f(n)
	d_aura_p = _f(n)
	d_spawn_frac = _f(n)
	d_threat = _f(n)
	d_weight = _f(n)
	d_dtype = _i(n)
	d_behaviour = _i(n)
	d_aura = _i(n)
	d_spawn_def = _i(n)
	d_spawn_n = _i(n)
	d_pack = _i(n)
	d_min_day = _i(n)
	d_ghost = _b(n)
	d_detonate = _b(n)
	d_spawn_death = _b(n)
	d_pref = []
	d_pref.resize(n)


func _install_def(i: int, d: CombatEnemyDef) -> void:
	_def_index[d.id] = i
	d_id[i] = d.id
	d_name[i] = d.display_name
	d_arch[i] = d.render_arch
	d_res[i] = d
	d_health[i] = d.health
	d_armour[i] = d.armour
	d_speed[i] = d.speed * TILE
	d_radius[i] = d.body_radius * TILE
	d_damage[i] = d.damage
	d_dtype[i] = d.damage_channel()
	d_interval[i] = d.attack_interval
	d_reach[i] = d.attack_range * TILE + REACH_SLACK
	d_splash[i] = d.splash_radius * TILE
	d_pref_mult[i] = d.preferred_multiplier
	d_pref[i] = d.target_pref
	d_seek[i] = d.seek_radius * TILE
	d_behaviour[i] = d.behaviour_index()
	d_ghost[i] = 1 if d.ignores_walls else 0
	d_surface[i] = d.surfaces_within_tiles * TILE
	d_detonate[i] = 1 if d.detonates else 0
	d_lifesteal[i] = d.lifesteal
	d_siphon[i] = d.siphon_rate
	d_discontent[i] = d.discontent_per_second
	d_regen[i] = d.regen_per_second
	d_regen_c[i] = d.regen_below_c
	d_res_k[i] = d.resist_kinetic
	d_res_f[i] = d.resist_flame
	d_res_b[i] = d.resist_blast
	d_res_s[i] = d.resist_shock
	d_aura[i] = d.aura_index()
	d_aura_r[i] = d.aura_radius * TILE
	d_aura_p[i] = d.aura_power
	d_spawn_def[i] = -1
	d_spawn_n[i] = d.spawns_count
	d_spawn_frac[i] = d.spawns_every_fraction
	d_spawn_death[i] = 1 if d.spawns_on_death else 0
	d_threat[i] = d.threat_value
	d_weight[i] = d.wave_weight
	d_pack[i] = maxi(1, d.pack_size)
	d_min_day[i] = maxi(1, d.min_day)


static func _f(n: int) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a


static func _i(n: int) -> PackedInt32Array:
	var a: PackedInt32Array = PackedInt32Array()
	a.resize(n)
	return a


static func _b(n: int) -> PackedByteArray:
	var a: PackedByteArray = PackedByteArray()
	a.resize(n)
	return a

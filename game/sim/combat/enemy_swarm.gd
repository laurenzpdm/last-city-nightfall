class_name EnemySwarm
extends RefCounted
## Every enemy in the world, stored as parallel packed arrays.
##
## This is written as a structure of arrays and not as five hundred RefCounted
## objects for one reason: the brief is five hundred attackers inside a 2 ms
## slice of a 50 ms tick, and in GDScript the cost of a hot loop is dominated by
## property lookups and object headers, not by arithmetic. Here the inner loop
## touches typed [PackedFloat32Array] elements and local ints, allocates nothing,
## and calls nothing per enemy. Definitions are read out of [EnemyDef] exactly
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

# ---------------------------------------------------------------- buckets ----

var bw: int = 0
var bh: int = 0
var _bucket_start: PackedInt32Array = PackedInt32Array()
var _bucket_items: PackedInt32Array = PackedInt32Array()
var _bucket_fill: PackedInt32Array = PackedInt32Array()

# ---------------------------------------------------------------- counters ---

var kills: int = 0
var leaked: int = 0            ## reached the core and stopped being ours to shoot
var damage_dealt: float = 0.0  ## to the player's structures, after their armour
var discontent_raised: float = 0.0
var heat_siphoned: float = 0.0

var _map_w: int = 0
var _map_h: int = 0
var _core_px: Vector2 = Vector2.ZERO
var _spawn_queue: Array[Dictionary] = []


# =========================================================================
# definitions
# =========================================================================

## Reads every EnemyDef in the registry into the def table. Returns the problems
## found, so the caller can put them in the log once instead of per spawn.
func load_defs() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var defs: Array[Resource] = Registry.all("enemies")
	var pending: Array[EnemyDef] = []
	for res: Resource in defs:
		var d := res as EnemyDef
		if d == null:
			continue
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


func def_resource(slot: int) -> EnemyDef:
	return d_res[slot] as EnemyDef if slot >= 0 and slot < def_count else null


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
	var d: int = e_def[slot]
	if d_spawn_death[d] == 1:
		_queue_adds(slot, tick)


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
	var think_gate: int = tick % THINK_PERIOD

	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			continue
		var d: int = e_def[i]
		var px: float = e_x[i]
		var py: float = e_y[i]

		# --- burning, regeneration ---------------------------------------
		if e_burn_t[i] > 0.0:
			e_burn_t[i] -= dt
			e_hp[i] -= e_burn[i] * dt
			if e_burn_t[i] <= 0.0:
				e_burn[i] = 0.0
			if e_hp[i] <= 0.0:
				_kill(i, tick)
				continue
		if d_regen[d] > 0.0 and e_hp[i] < d_health[d]:
			var here: float = -40.0
			if warm != null:
				here = float(warm.call("temperature_at", Vector2i(int(px / TILE), int(py / TILE))))
			if here <= d_regen_c[d]:
				e_hp[i] = minf(d_health[d], e_hp[i] + d_regen[d] * dt)

		var cell_x: int = clampi(int(px / TILE), 0, w - 1)
		var cell_y: int = clampi(int(py / TILE), 0, h - 1)
		var idx: int = cell_y * w + cell_x

		# --- surfacing ----------------------------------------------------
		if e_hidden[i] == 1:
			var ddx: float = px - cx
			var ddy: float = py - cy
			if ddx * ddx + ddy * ddy <= d_surface[d] * d_surface[d]:
				e_hidden[i] = 0

		# --- deliberate target hunting ------------------------------------
		var behav: int = d_behaviour[d]
		if (i + tick) % THINK_PERIOD == think_gate and e_target[i] < 0 and d_seek[d] > 0.0:
			var found: Dictionary = sys.call("find_enemy_target", Vector2(px, py), d_pref[d], d_seek[d])
			if not found.is_empty():
				e_target[i] = int(found["id"])
				var tp: Vector2 = found["pos"]
				e_tx[i] = tp.x
				e_ty[i] = tp.y

		# --- movement ------------------------------------------------------
		var speed: float = d_speed[d] * (1.0 + e_rally[i])
		if snow != null and d_ghost[d] == 0:
			speed *= float(snow.call("speed_scale", Vector2i(cell_x, cell_y)))
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
				if has_assault and acost[aidx] != Grid.IMPASSABLE:
					blocker = int(sys.call("structure_at", Vector2i(acx, acy)))
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
					if e_target[i] < 0:
						e_target[i] = blocker
						e_tx[i] = float(acx) * TILE + HALF_TILE
						e_ty[i] = float(acy) * TILE + HALF_TILE

		e_x[i] = px + mvx
		e_y[i] = py + mvy

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
						e_target[i] = -1
						e_state[i] = CombatTypes.EnemyState.WALKING
					else:
						damage_dealt += landed
						if d_lifesteal[d] > 0.0:
							e_hp[i] = minf(d_health[d], e_hp[i] + landed * d_lifesteal[d])
						if d_detonate[d] == 1:
							_kill(i, tick)
			else:
				e_state[i] = CombatTypes.EnemyState.WALKING
		else:
			e_state[i] = CombatTypes.EnemyState.WALKING
			# Nothing left to fight and standing on the hearth: it is inside, and
			# the city has already lost whatever it was going to lose here.
			if behav != CombatTypes.Behaviour.SIEGE:
				var lx: float = e_x[i] - cx
				var ly: float = e_y[i] - cy
				if lx * lx + ly * ly < 1024.0:
					leaked += 1
					_kill(i, tick)

		e_rally[i] = 0.0


## Applies support auras. Runs after movement so a rally granted this tick is
## spent next tick, which keeps the effect order independent of slot order.
func apply_auras(sys: Object) -> void:
	for i: int in range(count):
		if e_state[i] == CombatTypes.EnemyState.SPENT:
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
		if e_state[i] == CombatTypes.EnemyState.SPENT:
			continue
		var d: int = e_def[i]
		if d_discontent[d] > 0.0:
			discontent_raised += d_discontent[d] * dt
		if d_siphon[d] > 0.0 and e_state[i] == CombatTypes.EnemyState.ATTACKING:
			var taken: float = float(sys.call("siphon_turrets",
				Vector2(e_x[i], e_y[i]), maxf(d_aura_r[d], 128.0), d_siphon[d] * dt))
			heat_siphoned += taken


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


func velocity_at(slot: int) -> Vector2:
	if slot < 0 or slot >= count:
		return Vector2.ZERO
	if e_state[slot] == CombatTypes.EnemyState.ATTACKING:
		return Vector2.ZERO
	var d: int = e_def[slot]
	var s: float = d_speed[d] * (1.0 + e_rally[slot])
	return Vector2(e_hx[slot] * s, e_hy[slot] * s)


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


func _install_def(i: int, d: EnemyDef) -> void:
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

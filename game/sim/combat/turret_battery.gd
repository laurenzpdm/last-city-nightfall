class_name TurretBattery
extends RefCounted
## Every gun on the wall, and the heat magazine behind it.
##
## **A turret with no heat is a decoration.** That sentence is the whole part.
## A mount charges a local magazine at exactly the rate the heat grid is actually
## serving that building — [HeatSystem.served_of], the same number that decides
## whether a house is warm — and every shot spends out of it. So:
##
##   * building more guns raises the city's heat demand and browns out the homes,
##     because [P02] sheds by priority and a wall full of turrets is a real load;
##   * failing to heat the wall disarms it, quietly, before the night starts;
##   * a cinder leech that reaches your trunk main takes the magazines with it.
##
## Nothing else in the codebase couples the three genres this tightly, so the
## magazine is modelled honestly: a capacity, a charge rate, a per-shot cost, and
## a reason string for every tick a gun did not fire.
##
## Targeting is a real policy, not "nearest". Five policies, per mount, stored in
## `BuildingInstance.meta.aim`, plus a turn rate the gunner physically has to
## respect — which is why a heavy mortar is a bad answer to a fast swarm even
## when the numbers say its damage per second is enormous.

const TILE: float = 32.0
## Ticks between target re-evaluations. A turret keeps its target between these
## unless it dies or leaves range, so it does not twitch between two hounds.
const RETARGET_TICKS: int = 5
## Ticks between Bus.turret_fired emissions for a sustained cone weapon. The
## signal is a VFX cue, not a damage tick, and one per frame per flamethrower is
## more than [P14] needs.
const CONE_SIGNAL_TICKS: int = 5
## Magazine floor: however small a def's heat buffer is, a mount always holds
## enough for this many shots, so a weapon is never un-fireable by construction.
const MIN_MAGAZINE_SHOTS: float = 4.0
## Rounds pulled per request once the local bin drops below this fraction.
const AMMO_REFILL_AT: float = 0.4


## One mount. Few enough of these exist that an object per turret is the right
## trade: the loop over turrets is dozens of iterations, not five hundred.
class Turret extends RefCounted:
	var id: int = 0
	var kind: StringName = &""
	var weapon: WeaponDef = null
	var weapon_id: StringName = &""
	var centre: Vector2 = Vector2.ZERO
	var cell: Vector2i = Vector2i.ZERO
	var facing: float = 0.0            ## radians
	var aim: int = CombatTypes.Aim.FIRST
	var target_slot: int = -1
	var target_id: int = -1
	var reload_left: float = 0.0
	var burst_left: int = 0
	var burst_timer: float = 0.0
	var charge: float = 0.0
	var capacity: float = 1.0
	var charge_rate: float = 0.0       ## units/s at full service
	var ammo: int = 0
	var ammo_capacity: int = 0
	var chill: float = 0.0             ## 0..1 of the charge rate stolen this tick
	var idle: int = CombatTypes.Idle.OFFLINE
	var served: float = 0.0
	var shots: int = 0
	var heat_spent: float = 0.0
	var damage_dealt: float = 0.0
	var ready_ticks: int = 0
	var live_ticks: int = 0
	var last_fired_tick: int = -1

	func magazine_fraction() -> float:
		return clampf(charge / maxf(capacity, 0.001), 0.0, 1.0)

	func to_dict() -> Dictionary:
		return {
			"id": id, "kind": String(kind), "weapon": String(weapon_id),
			"cell": [cell.x, cell.y],
			"facing": snappedf(facing, 0.0001),
			"aim": aim, "target": target_id,
			"reload": snappedf(reload_left, 0.001),
			"burst_left": burst_left, "burst_timer": snappedf(burst_timer, 0.001),
			"charge": snappedf(charge, 0.001), "capacity": snappedf(capacity, 0.001),
			"ammo": ammo, "idle": idle,
			"served": snappedf(served, 0.001),
			"shots": shots,
			"heat_spent": snappedf(heat_spent, 0.001),
			"damage": snappedf(damage_dealt, 0.01),
			"ready_ticks": ready_ticks, "live_ticks": live_ticks,
		}


var turrets: Dictionary[int, Turret] = {}
var weapons: Dictionary[StringName, WeaponDef] = {}
var default_weapon: StringName = &""

var shots_fired: int = 0
var heat_spent: float = 0.0
var heat_stolen: float = 0.0
var damage_dealt: float = 0.0
var ready_ticks: int = 0
var live_ticks: int = 0
var ammo_starved_ticks: int = 0
var heat_starved_ticks: int = 0

var _ids: PackedInt32Array = PackedInt32Array()
var _ids_dirty: bool = true
var _cone_tick: int = 0


## Loads every WeaponDef in the registry. Returns the content problems found.
func load_weapons() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	weapons.clear()
	for res: Resource in Registry.all("weapons"):
		var w := res as WeaponDef
		if w == null:
			continue
		var bad: PackedStringArray = w.validate()
		if not bad.is_empty():
			for b: String in bad:
				problems.append("%s: %s" % [w.id, b])
			continue
		weapons[w.id] = w
	var keys: Array = weapons.keys()
	keys.sort()
	default_weapon = keys[0] if not keys.is_empty() else &""
	return problems


func weapon_of(id: StringName) -> WeaponDef:
	return weapons.get(id)


func count() -> int:
	return turrets.size()


func sorted_ids() -> PackedInt32Array:
	if not _ids_dirty:
		return _ids
	var keys: Array = turrets.keys()
	keys.sort()
	_ids = PackedInt32Array()
	for k: int in keys:
		_ids.append(k)
	_ids_dirty = false
	return _ids


## Adds or refreshes a mount from its [BuildingInstance]. Returns false when the
## building carries no weapon at all.
func install(building: Object, weapon_id: StringName, centre: Vector2, cell: Vector2i,
		buffer: float, draw_rate: float) -> bool:
	var w: WeaponDef = weapons.get(weapon_id)
	if w == null:
		return false
	var id: int = int(building.get("id"))
	var t: Turret = turrets.get(id)
	if t == null:
		t = Turret.new()
		t.id = id
		t.facing = 0.0
		turrets[id] = t
		_ids_dirty = true
	t.kind = StringName(String(building.get("kind")))
	t.centre = centre
	t.cell = cell
	if t.weapon_id != weapon_id:
		# A refit empties the magazine and the bin: the barrel physically changed.
		t.weapon_id = weapon_id
		t.weapon = w
		t.charge = 0.0
		t.ammo = 0
		t.burst_left = 0
		t.reload_left = w.reload
	t.weapon = w
	t.capacity = maxf(buffer, w.heat_per_shot * MIN_MAGAZINE_SHOTS)
	t.charge_rate = draw_rate
	t.ammo_capacity = w.ammo_capacity if String(w.ammo_item) != "" else 0
	var meta: Variant = building.get("meta")
	var chosen: int = w.default_aim_index()
	if typeof(meta) == TYPE_DICTIONARY:
		var m: Dictionary = meta
		if m.has("aim"):
			chosen = CombatTypes.enum_of(CombatTypes.AIM_NAMES, StringName(String(m["aim"])), chosen)
	t.aim = chosen
	return true


func remove(id: int) -> void:
	if turrets.erase(id):
		_ids_dirty = true


func has(id: int) -> bool:
	return turrets.has(id)


func get_turret(id: int) -> Turret:
	return turrets.get(id)


## Takes `amount` heat out of every magazine within `radius_px`. This is how a
## siphon disarms a wall without ever touching it. Returns what it got.
func steal(centre: Vector2, radius_px: float, amount: float) -> float:
	var got: float = 0.0
	var r2: float = radius_px * radius_px
	for id: int in sorted_ids():
		var t: Turret = turrets[id]
		if t.centre.distance_squared_to(centre) > r2:
			continue
		var take: float = minf(t.charge, amount)
		t.charge -= take
		got += take
	heat_stolen += got
	return got


## Marks turrets inside a chill aura. Cleared at the top of every tick, so an
## aura only lasts as long as the thing projecting it.
func chill(centre: Vector2, radius_px: float, power: float) -> void:
	var r2: float = radius_px * radius_px
	for id: int in sorted_ids():
		var t: Turret = turrets[id]
		if t.centre.distance_squared_to(centre) <= r2:
			t.chill = maxf(t.chill, clampf(power, 0.0, 1.0))


# =========================================================================
# the tick
# =========================================================================

## Runs every mount. `sys` provides the cross-system answers (is this building
## running, how well is it served, is there ammunition) so the battery itself
## stays a pure combat object.
func step(tick: int, sys: Object, swarm: EnemySwarm, shells: ProjectilePool,
		assault: AssaultField) -> void:
	var dt: float = SimClock.DT
	var rng: RandomNumberGenerator = Rng.stream("combat_fire")
	_cone_tick = tick
	for id: int in sorted_ids():
		var t: Turret = turrets[id]
		var w: WeaponDef = t.weapon
		if w == null:
			t.idle = CombatTypes.Idle.NO_WEAPON
			continue
		live_ticks += 1
		t.live_ticks += 1

		# --- supply ------------------------------------------------------
		var status: Dictionary = sys.call("turret_supply", id)
		if not bool(status.get("running", false)):
			t.idle = CombatTypes.Idle.OFFLINE
			t.target_slot = -1
			t.target_id = -1
			t.chill = 0.0
			continue
		t.served = float(status.get("served", 1.0))
		if t.charge_rate > 0.0:
			var rate: float = t.charge_rate * t.served * (1.0 - t.chill)
			t.charge = minf(t.capacity, t.charge + rate * dt)
		else:
			t.charge = t.capacity
		t.chill = 0.0

		# --- ammunition --------------------------------------------------
		if t.ammo_capacity > 0 and float(t.ammo) < float(t.ammo_capacity) * AMMO_REFILL_AT:
			t.ammo += int(sys.call("pull_ammo", id, w.ammo_item, t.ammo_capacity - t.ammo))

		# --- timers ------------------------------------------------------
		if t.reload_left > 0.0:
			t.reload_left -= dt
		if t.burst_timer > 0.0:
			t.burst_timer -= dt

		# --- target ------------------------------------------------------
		var range_px: float = w.range_tiles * TILE
		if t.target_slot >= 0:
			if not swarm.alive_at(t.target_slot) or swarm.id_at(t.target_slot) != t.target_id:
				t.target_slot = -1
			elif swarm.position_at(t.target_slot).distance_squared_to(t.centre) > range_px * range_px:
				t.target_slot = -1
		if t.target_slot < 0 and (tick + id) % RETARGET_TICKS == 0:
			_acquire(t, swarm, assault, range_px, w)
		if t.target_slot < 0:
			t.idle = CombatTypes.Idle.NO_TARGET
			continue

		# --- slew --------------------------------------------------------
		var target_pos: Vector2 = swarm.position_at(t.target_slot)
		var to: Vector2 = target_pos - t.centre
		var want: float = atan2(to.y, to.x)
		var err: float = wrapf(want - t.facing, -PI, PI)
		var max_step: float = deg_to_rad(w.turn_rate) * dt
		if absf(err) <= max_step:
			t.facing = want
			err = 0.0
		else:
			t.facing = wrapf(t.facing + signf(err) * max_step, -PI, PI)
			err = wrapf(want - t.facing, -PI, PI)

		var dist: float = to.length()
		if dist < w.min_range_tiles * TILE:
			t.idle = CombatTypes.Idle.NO_TARGET
			continue
		if absf(err) > deg_to_rad(w.aim_tolerance):
			t.idle = CombatTypes.Idle.TURNING
			continue

		# --- fire --------------------------------------------------------
		if w.delivery_index() == CombatTypes.Delivery.CONE:
			_burn_cone(t, w, swarm, sys, tick, dt)
			continue
		if t.burst_left > 0:
			if t.burst_timer > 0.0:
				t.idle = CombatTypes.Idle.RELOADING
				continue
		elif t.reload_left > 0.0:
			t.idle = CombatTypes.Idle.RELOADING
			continue
		if t.charge < w.heat_per_shot:
			t.idle = CombatTypes.Idle.NO_HEAT
			heat_starved_ticks += 1
			continue
		if t.ammo_capacity > 0 and t.ammo < w.ammo_per_shot:
			t.idle = CombatTypes.Idle.NO_AMMO
			ammo_starved_ticks += 1
			continue

		if t.burst_left <= 0:
			t.burst_left = maxi(1, w.shots_per_burst)
		_fire_one(t, w, swarm, shells, sys, rng, target_pos, tick)
		t.burst_left -= 1
		if t.burst_left > 0:
			t.burst_timer = w.burst_interval
		else:
			t.reload_left = w.reload
		t.idle = CombatTypes.Idle.FIRING
		t.last_fired_tick = tick
		ready_ticks += 1
		t.ready_ticks += 1


func _acquire(t: Turret, swarm: EnemySwarm, assault: AssaultField,
		range_px: float, w: WeaponDef) -> void:
	var candidates: PackedInt32Array = swarm.targetable(t.centre, range_px)
	if candidates.is_empty():
		return
	var min_px: float = w.min_range_tiles * TILE
	var min2: float = min_px * min_px
	var best: int = -1
	var best_score: float = 0.0
	for slot: int in candidates:
		var p: Vector2 = swarm.position_at(slot)
		var d2: float = p.distance_squared_to(t.centre)
		if d2 < min2:
			continue
		var score: float = 0.0
		match t.aim:
			CombatTypes.Aim.CLOSEST:
				score = -d2
			CombatTypes.Aim.STRONGEST:
				score = swarm.e_hp[slot]
			CombatTypes.Aim.WEAKEST:
				score = -swarm.e_hp[slot]
			CombatTypes.Aim.ARMOURED:
				score = swarm.armour_at(slot)
			_:
				# FIRST: furthest along the way in, i.e. lowest remaining travel
				# cost to the core. That is what "first" has always meant in a
				# tower defence, and the assault field already knows it.
				var dist: int = FlowField.UNREACHABLE
				if assault != null and assault.ready:
					dist = assault.distance_at(Vector2i(int(p.x / TILE), int(p.y / TILE)))
				score = -float(dist) if dist != FlowField.UNREACHABLE else -1.0e9 - d2
		# Ties broken by slot so two identical hounds never flip the choice
		# between two runs of the same seed.
		if best < 0 or score > best_score:
			best = slot
			best_score = score
	if best < 0:
		return
	t.target_slot = best
	t.target_id = swarm.id_at(best)


func _fire_one(t: Turret, w: WeaponDef, swarm: EnemySwarm, shells: ProjectilePool,
		sys: Object, rng: RandomNumberGenerator, target_pos: Vector2, tick: int) -> void:
	t.charge -= w.heat_per_shot
	t.heat_spent += w.heat_per_shot
	heat_spent += w.heat_per_shot
	if t.ammo_capacity > 0:
		t.ammo -= w.ammo_per_shot
	t.shots += 1
	shots_fired += 1

	var muzzle: Vector2 = t.centre + Vector2(cos(t.facing), sin(t.facing)) * 14.0
	var aim_point: Vector2 = target_pos
	var speed_px: float = w.projectile_speed * TILE
	if w.delivery_index() == CombatTypes.Delivery.PROJECTILE and w.lead_factor > 0.0:
		var flight: float = muzzle.distance_to(target_pos) / maxf(speed_px, 1.0)
		aim_point = target_pos + swarm.velocity_at(t.target_slot) * flight * w.lead_factor
	if w.spread_degrees > 0.0:
		var jitter: float = deg_to_rad(rng.randf_range(-w.spread_degrees, w.spread_degrees))
		var rel: Vector2 = aim_point - muzzle
		aim_point = muzzle + rel.rotated(jitter)

	Bus.turret_fired.emit(t.id, muzzle, aim_point)

	if w.delivery_index() == CombatTypes.Delivery.HITSCAN:
		var d: float = swarm.hurt(t.target_slot, t.target_id, w.damage,
			w.damage_channel(), w.pierce, tick)
		if w.splash_radius > 0.0:
			d += swarm.splash(target_pos, w.splash_radius * TILE, w.damage,
				w.damage_channel(), w.pierce, w.splash_falloff, tick)
		if w.burn_dps > 0.0:
			swarm.ignite(t.target_slot, t.target_id, w.burn_dps, w.burn_seconds)
		t.damage_dealt += d
		damage_dealt += d
		sys.call("note_hit", t.id, target_pos, d)
		return

	shells.launch(muzzle, aim_point, speed_px, w.damage, w.damage_channel(), w.pierce,
		w.splash_radius * TILE, w.splash_falloff, w.burn_dps, w.burn_seconds,
		t.target_slot, t.target_id, t.id)


## A flamethrower does not fire shots; it holds a cone open and pays for it every
## tick. Everything inside the cone burns, which is precisely why it is the
## answer to a swarm and a terrible answer to one armoured thing.
func _burn_cone(t: Turret, w: WeaponDef, swarm: EnemySwarm, sys: Object,
		tick: int, dt: float) -> void:
	var cost: float = w.heat_per_shot * dt
	if t.charge < cost:
		t.idle = CombatTypes.Idle.NO_HEAT
		heat_starved_ticks += 1
		return
	if t.ammo_capacity > 0 and t.ammo < w.ammo_per_shot:
		t.idle = CombatTypes.Idle.NO_AMMO
		ammo_starved_ticks += 1
		return
	t.charge -= cost
	t.heat_spent += cost
	heat_spent += cost
	var reach: float = w.range_tiles * TILE
	var half: float = deg_to_rad(w.cone_degrees)
	var total: float = 0.0
	for slot: int in swarm.targetable(t.centre, reach):
		var p: Vector2 = swarm.position_at(slot)
		var rel: Vector2 = p - t.centre
		if absf(wrapf(atan2(rel.y, rel.x) - t.facing, -PI, PI)) > half:
			continue
		total += swarm.hurt(slot, swarm.id_at(slot), w.damage * dt,
			w.damage_channel(), w.pierce, tick)
		if w.burn_dps > 0.0:
			swarm.ignite(slot, swarm.id_at(slot), w.burn_dps, w.burn_seconds)
	t.damage_dealt += total
	damage_dealt += total
	t.shots += 1
	shots_fired += 1
	t.idle = CombatTypes.Idle.FIRING
	t.last_fired_tick = tick
	ready_ticks += 1
	t.ready_ticks += 1
	if tick % CONE_SIGNAL_TICKS == 0:
		var tip: Vector2 = t.centre + Vector2(cos(t.facing), sin(t.facing)) * reach
		Bus.turret_fired.emit(t.id, t.centre, tip)
	if total > 0.0:
		sys.call("note_hit", t.id, t.centre, total)


# =========================================================================
# readouts
# =========================================================================

## Fraction of turret-ticks in which a gun actually put damage out. The single
## number that says "is my wall armed?" — a wall of mounts with no heat reads
## near zero however many of them there are.
func uptime() -> float:
	return float(ready_ticks) / float(maxi(live_ticks, 1))


## Why every gun is quiet, worst case first. This is the combat half of the
## legibility contract [P02] set with its bottleneck attribution.
func readout() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in sorted_ids():
		var t: Turret = turrets[id]
		out.append({
			"id": id,
			"kind": String(t.kind),
			"weapon": String(t.weapon_id),
			"cell": [t.cell.x, t.cell.y],
			"idle": CombatTypes.idle_name(t.idle),
			"magazine": snappedf(t.magazine_fraction(), 0.01),
			"served": snappedf(t.served, 0.01),
			"ammo": t.ammo,
			"target": t.target_id,
			"shots": t.shots,
			"damage": snappedf(t.damage_dealt, 0.1),
			"uptime": snappedf(float(t.ready_ticks) / float(maxi(t.live_ticks, 1)), 0.001),
		})
	return out


## Compact, allocation-light view for [P13]/[P14]: where every barrel points, how
## full its magazine is, and whether it is shooting right now.
func render_buffer() -> Dictionary:
	var n: int = turrets.size()
	var ids: PackedInt32Array = PackedInt32Array()
	var xs: PackedFloat32Array = PackedFloat32Array()
	var ys: PackedFloat32Array = PackedFloat32Array()
	var facing: PackedFloat32Array = PackedFloat32Array()
	var mag: PackedFloat32Array = PackedFloat32Array()
	var state: PackedByteArray = PackedByteArray()
	ids.resize(n)
	xs.resize(n)
	ys.resize(n)
	facing.resize(n)
	mag.resize(n)
	state.resize(n)
	var i: int = 0
	for id: int in sorted_ids():
		var t: Turret = turrets[id]
		ids[i] = id
		xs[i] = t.centre.x
		ys[i] = t.centre.y
		facing[i] = t.facing
		mag[i] = t.magazine_fraction()
		state[i] = t.idle
		i += 1
	return {"count": n, "id": ids, "x": xs, "y": ys, "facing": facing,
		"magazine": mag, "idle": state}


func serialize() -> Array:
	var out: Array = []
	for id: int in sorted_ids():
		out.append(turrets[id].to_dict())
	return out


func restore(id: int, data: Dictionary) -> void:
	var t: Turret = turrets.get(id)
	if t == null:
		return
	t.facing = float(data.get("facing", 0.0))
	t.aim = int(data.get("aim", CombatTypes.Aim.FIRST))
	t.target_id = int(data.get("target", -1))
	t.target_slot = -1
	t.reload_left = float(data.get("reload", 0.0))
	t.burst_left = int(data.get("burst_left", 0))
	t.burst_timer = float(data.get("burst_timer", 0.0))
	t.charge = float(data.get("charge", 0.0))
	t.ammo = int(data.get("ammo", 0))
	t.shots = int(data.get("shots", 0))
	t.heat_spent = float(data.get("heat_spent", 0.0))
	t.damage_dealt = float(data.get("damage", 0.0))
	t.ready_ticks = int(data.get("ready_ticks", 0))
	t.live_ticks = int(data.get("live_ticks", 0))

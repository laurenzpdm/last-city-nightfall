class_name ProjectilePool
extends RefCounted
## Shells in the air, as parallel packed arrays.
##
## Every shot that is not hitscan spends real time crossing the gap, and that is
## a design decision rather than a flourish: travel time is what makes a mortar a
## bad answer to a drift hound and a good answer to a colossus, and it is why
## leading a target ([member WeaponDef.lead_factor]) is a property a weapon can be
## bad at.
##
## The flight model is deliberately not a per-tick collision sweep against five
## hundred enemies. A shot is fired at an **aim point** computed once, at the
## muzzle, from the target's velocity and the weapon's lead factor. It then flies
## in a straight line and resolves on arrival: direct damage if the intended
## target is still within its body radius of the impact, splash regardless. That
## is O(1) per projectile per tick and it produces the behaviour that matters —
## fast things get missed, slow things do not.

const MAX_LIFE: float = 6.0

var count: int = 0
var p_x: PackedFloat32Array = PackedFloat32Array()
var p_y: PackedFloat32Array = PackedFloat32Array()
var p_vx: PackedFloat32Array = PackedFloat32Array()
var p_vy: PackedFloat32Array = PackedFloat32Array()
var p_left: PackedFloat32Array = PackedFloat32Array()     ## seconds to impact
var p_damage: PackedFloat32Array = PackedFloat32Array()
var p_pierce: PackedFloat32Array = PackedFloat32Array()
var p_splash: PackedFloat32Array = PackedFloat32Array()   ## px
var p_falloff: PackedFloat32Array = PackedFloat32Array()
var p_burn: PackedFloat32Array = PackedFloat32Array()
var p_burn_t: PackedFloat32Array = PackedFloat32Array()
var p_channel: PackedInt32Array = PackedInt32Array()
var p_target: PackedInt32Array = PackedInt32Array()       ## enemy slot at fire time
var p_target_id: PackedInt32Array = PackedInt32Array()    ## generation check
var p_owner: PackedInt32Array = PackedInt32Array()        ## turret building id

var fired_total: int = 0
var hits_total: int = 0
var misses_total: int = 0


## Launches one shell toward `aim`. `flight` is derived from the weapon speed by
## the caller, because that is where the muzzle position and the spread live.
func launch(from: Vector2, aim: Vector2, speed_px: float, damage: float, channel: int,
		pierce: float, splash_px: float, falloff: float, burn: float, burn_seconds: float,
		target_slot: int, target_id: int, owner_id: int) -> void:
	var delta: Vector2 = aim - from
	var dist: float = delta.length()
	if speed_px <= 0.0:
		speed_px = 1.0
	var flight: float = minf(dist / speed_px, MAX_LIFE)
	var i: int = count
	count += 1
	_grow(count)
	p_x[i] = from.x
	p_y[i] = from.y
	var inv: float = 1.0 / maxf(dist, 0.001)
	p_vx[i] = delta.x * inv * speed_px
	p_vy[i] = delta.y * inv * speed_px
	p_left[i] = maxf(flight, 0.0001)
	p_damage[i] = damage
	p_pierce[i] = pierce
	p_splash[i] = splash_px
	p_falloff[i] = falloff
	p_burn[i] = burn
	p_burn_t[i] = burn_seconds
	p_channel[i] = channel
	p_target[i] = target_slot
	p_target_id[i] = target_id
	p_owner[i] = owner_id
	fired_total += 1


## Flies everything one tick and resolves whatever arrives. Returns the total
## damage delivered, and credits each hit back to the gun that fired it — a
## per-turret damage column is worth nothing if every shell lands in one bucket.
func step(tick: int, swarm: EnemySwarm, battery: TurretBattery = null) -> float:
	var dt: float = SimClock.DT
	var dealt: float = 0.0
	var i: int = 0
	while i < count:
		p_left[i] -= dt
		if p_left[i] > 0.0:
			p_x[i] += p_vx[i] * dt
			p_y[i] += p_vy[i] * dt
			i += 1
			continue
		# Arrival: step the last fraction of a tick so the impact point is exact.
		var over: float = dt + p_left[i]
		var ix: float = p_x[i] + p_vx[i] * over
		var iy: float = p_y[i] + p_vy[i] * over
		var impact: Vector2 = Vector2(ix, iy)
		var hit: bool = false
		var shot_damage: float = 0.0
		var slot: int = p_target[i]
		if swarm.alive_at(slot) and swarm.id_at(slot) == p_target_id[i]:
			var tp: Vector2 = swarm.position_at(slot)
			var reach: float = swarm.d_radius[swarm.e_def[slot]] + 6.0
			if tp.distance_squared_to(impact) <= reach * reach:
				var d: float = swarm.hurt(slot, p_target_id[i], p_damage[i], p_channel[i], p_pierce[i], tick)
				if d > 0.0:
					dealt += d
					shot_damage += d
					hit = true
					if p_burn[i] > 0.0:
						swarm.ignite(slot, p_target_id[i], p_burn[i], p_burn_t[i])
		if p_splash[i] > 0.0:
			var s: float = swarm.splash(impact, p_splash[i], p_damage[i], p_channel[i],
				p_pierce[i], p_falloff[i], tick)
			if s > 0.0:
				dealt += s
				shot_damage += s
				hit = true
		if hit:
			hits_total += 1
		else:
			misses_total += 1
		if battery != null and shot_damage > 0.0:
			battery.credit(p_owner[i], shot_damage)
		_remove(i)
	return dealt


## Live shells for [P14] to draw. Positions in world pixels, plus the turret that
## fired each one so a tracer can be tinted by its weapon.
func render_buffer() -> Dictionary:
	var xs: PackedFloat32Array = PackedFloat32Array()
	var ys: PackedFloat32Array = PackedFloat32Array()
	var vx: PackedFloat32Array = PackedFloat32Array()
	var vy: PackedFloat32Array = PackedFloat32Array()
	var owners: PackedInt32Array = PackedInt32Array()
	xs.resize(count)
	ys.resize(count)
	vx.resize(count)
	vy.resize(count)
	owners.resize(count)
	for i: int in range(count):
		xs[i] = p_x[i]
		ys[i] = p_y[i]
		vx[i] = p_vx[i]
		vy[i] = p_vy[i]
		owners[i] = p_owner[i]
	return {"count": count, "x": xs, "y": ys, "vx": vx, "vy": vy, "owner": owners}


func clear() -> void:
	count = 0


func serialize() -> Array:
	var out: Array = []
	for i: int in range(count):
		out.append({
			"x": snappedf(p_x[i], 0.01), "y": snappedf(p_y[i], 0.01),
			"vx": snappedf(p_vx[i], 0.01), "vy": snappedf(p_vy[i], 0.01),
			"left": snappedf(p_left[i], 0.001),
			"damage": snappedf(p_damage[i], 0.01), "pierce": snappedf(p_pierce[i], 0.01),
			"splash": snappedf(p_splash[i], 0.01), "falloff": snappedf(p_falloff[i], 0.01),
			"burn": snappedf(p_burn[i], 0.01), "burn_t": snappedf(p_burn_t[i], 0.001),
			"channel": p_channel[i], "target": p_target[i],
			"target_id": p_target_id[i], "owner": p_owner[i],
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["owner"]) != int(b["owner"]):
			return int(a["owner"]) < int(b["owner"])
		return float(a["left"]) < float(b["left"]))
	return out


func deserialize(rows: Array) -> void:
	count = 0
	for entry: Variant in rows:
		var r: Dictionary = entry
		var i: int = count
		count += 1
		_grow(count)
		p_x[i] = float(r.get("x", 0.0))
		p_y[i] = float(r.get("y", 0.0))
		p_vx[i] = float(r.get("vx", 0.0))
		p_vy[i] = float(r.get("vy", 0.0))
		p_left[i] = float(r.get("left", 0.0))
		p_damage[i] = float(r.get("damage", 0.0))
		p_pierce[i] = float(r.get("pierce", 0.0))
		p_splash[i] = float(r.get("splash", 0.0))
		p_falloff[i] = float(r.get("falloff", 0.35))
		p_burn[i] = float(r.get("burn", 0.0))
		p_burn_t[i] = float(r.get("burn_t", 0.0))
		p_channel[i] = int(r.get("channel", 0))
		p_target[i] = int(r.get("target", -1))
		p_target_id[i] = int(r.get("target_id", -1))
		p_owner[i] = int(r.get("owner", -1))


func _remove(i: int) -> void:
	var last: int = count - 1
	if i != last:
		p_x[i] = p_x[last]
		p_y[i] = p_y[last]
		p_vx[i] = p_vx[last]
		p_vy[i] = p_vy[last]
		p_left[i] = p_left[last]
		p_damage[i] = p_damage[last]
		p_pierce[i] = p_pierce[last]
		p_splash[i] = p_splash[last]
		p_falloff[i] = p_falloff[last]
		p_burn[i] = p_burn[last]
		p_burn_t[i] = p_burn_t[last]
		p_channel[i] = p_channel[last]
		p_target[i] = p_target[last]
		p_target_id[i] = p_target_id[last]
		p_owner[i] = p_owner[last]
	count -= 1


func _grow(need: int) -> void:
	if p_x.size() >= need:
		return
	var cap: int = maxi(64, p_x.size() * 2)
	while cap < need:
		cap *= 2
	p_x.resize(cap)
	p_y.resize(cap)
	p_vx.resize(cap)
	p_vy.resize(cap)
	p_left.resize(cap)
	p_damage.resize(cap)
	p_pierce.resize(cap)
	p_splash.resize(cap)
	p_falloff.resize(cap)
	p_burn.resize(cap)
	p_burn_t.resize(cap)
	p_channel.resize(cap)
	p_target.resize(cap)
	p_target_id.resize(cap)
	p_owner.resize(cap)

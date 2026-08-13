class_name CitizenPool
extends RefCounted
## [P05] The population, stored as parallel arrays and simulated in bulk.
##
## A thousand people cannot be a thousand objects. Every attribute of every
## citizen lives in one packed array indexed by SLOT, so a tick touches flat
## memory instead of chasing a thousand pointers, and the whole population
## serialises as a handful of column dumps.
##
## Two rules make this class safe to work in:
##
##  1. **Never alias a packed array.** `var h := health; h[i] = 1.0` writes to a
##     copy — Godot's packed arrays are copy-on-write value types. Every write
##     in this file goes through the member directly. That is also why the hot
##     loops live HERE rather than in the system that orchestrates them.
##  2. **Never iterate a Dictionary to decide state.** Iteration order is not
##     part of the contract; `alive` is a sorted slot list and everything walks
##     that instead.
##
## Slots are recycled: a citizen who dies frees their slot for the next arrival,
## smallest slot first, so a long campaign does not grow the arrays without end
## and two identical runs allocate identically.

# --- identity ----------------------------------------------------------------
var ids: PackedInt32Array = PackedInt32Array()
var first_name: PackedInt32Array = PackedInt32Array()
var last_name: PackedInt32Array = PackedInt32Array()
var age: PackedInt32Array = PackedInt32Array()
var age_frac: PackedFloat32Array = PackedFloat32Array()
var traits: PackedByteArray = PackedByteArray()
var born_tick: PackedInt32Array = PackedInt32Array()

# --- body --------------------------------------------------------------------
var health: PackedFloat32Array = PackedFloat32Array()
var warmth: PackedFloat32Array = PackedFloat32Array()
var hunger: PackedFloat32Array = PackedFloat32Array()
var fatigue: PackedFloat32Array = PackedFloat32Array()
var morale: PackedFloat32Array = PackedFloat32Array()
var illness: PackedFloat32Array = PackedFloat32Array()
var injury: PackedFloat32Array = PackedFloat32Array()

# --- place in the city -------------------------------------------------------
var job: PackedInt32Array = PackedInt32Array()          ## building id or -1
var home: PackedInt32Array = PackedInt32Array()         ## building id or -1
var trade: PackedByteArray = PackedByteArray()
var shift: PackedByteArray = PackedByteArray()
var hazard: PackedByteArray = PackedByteArray()         ## job can maim you
var shelter: PackedFloat32Array = PackedFloat32Array()  ## °C a roof is worth here

# --- activity ----------------------------------------------------------------
var state: PackedByteArray = PackedByteArray()
var state_since: PackedInt32Array = PackedInt32Array()
var inside: PackedByteArray = PackedByteArray()         ## standing at a door
var dest: PackedInt32Array = PackedInt32Array()         ## building id or -1
var dest_x: PackedInt32Array = PackedInt32Array()
var dest_y: PackedInt32Array = PackedInt32Array()
## Where this walk STARTED, snapped to a door when there was one. Routes are
## cached by (from, to); if the key drifted with the walker's own footsteps,
## every citizen would pay for their own copy of the same path.
var from_x: PackedInt32Array = PackedInt32Array()
var from_y: PackedInt32Array = PackedInt32Array()
var px: PackedFloat32Array = PackedFloat32Array()       ## position, cell units
var py: PackedFloat32Array = PackedFloat32Array()
var wx: PackedFloat32Array = PackedFloat32Array()       ## current waypoint
var wy: PackedFloat32Array = PackedFloat32Array()
var route: PackedInt32Array = PackedInt32Array()
var route_step: PackedInt32Array = PackedInt32Array()
var jitter_x: PackedFloat32Array = PackedFloat32Array()
var jitter_y: PackedFloat32Array = PackedFloat32Array()
var death_cause: PackedByteArray = PackedByteArray()
var eat_until: PackedInt32Array = PackedInt32Array()

# --- bookkeeping -------------------------------------------------------------
var alive: PackedInt32Array = PackedInt32Array()        ## sorted live slots
var capacity: int = 0
var by_id: Dictionary[int, int] = {}                    ## citizen id -> slot
var free_slots: PackedInt32Array = PackedInt32Array()   ## sorted, ascending

# --- outputs the system drains each tick -------------------------------------
var pending_deaths: PackedInt32Array = PackedInt32Array()
var pending_sick: PackedInt32Array = PackedInt32Array()
var pending_injured: PackedInt32Array = PackedInt32Array()
var pending_meals: PackedInt32Array = PackedInt32Array()

# --- running totals, refreshed by tally() ------------------------------------
var sum_warmth: float = 0.0
var sum_morale: float = 0.0
var sum_health: float = 0.0
var sum_hunger: float = 0.0
var sum_fatigue: float = 0.0
var count_sick: int = 0
var count_injured: int = 0
var count_working: int = 0
var count_sleeping: int = 0
var count_walking: int = 0
var count_homeless: int = 0
var count_employed: int = 0
var count_unrest: int = 0

const CAUSE_INDEX: Array[StringName] = [
	&"cold", &"starvation", &"illness", &"injury", &"old_age", &"exhaustion",
]


## Per-tick inputs the body simulation needs. One object instead of a dozen
## arguments, so adding an influence does not rewrite every call site.
class Ctx extends RefCounted:
	var tick: int = 0
	var dt: float = 0.4                  ## seconds this bucket covers
	var ambient: float = -18.0
	var wind: float = 0.0                ## 0..1 from [P09]
	var field: WarmthField = null        ## [P02]'s radiant layer, may be null
	var care_ratio: float = 0.0          ## 0..1 of the sick who have a bed
	var contagion: float = 0.0           ## 0..1 share of the city already ill
	var fatigue_mult: float = 1.0        ## shift law
	var morale_offset: float = 0.0       ## grief + [P06] hope, already summed
	var rng: RandomNumberGenerator = null
	# --- [P10] research modifiers, 1.0 in a build with no tech tree ---------
	var exposure_resist: float = 1.0     ## >1 = the cold bites slower
	var heal_mult: float = 1.0           ## >1 = the sick and hurt recover faster


# =========================================================================
#  lifecycle
# =========================================================================

func clear() -> void:
	capacity = 0
	ids = PackedInt32Array()
	first_name = PackedInt32Array()
	last_name = PackedInt32Array()
	age = PackedInt32Array()
	age_frac = PackedFloat32Array()
	traits = PackedByteArray()
	born_tick = PackedInt32Array()
	health = PackedFloat32Array()
	warmth = PackedFloat32Array()
	hunger = PackedFloat32Array()
	fatigue = PackedFloat32Array()
	morale = PackedFloat32Array()
	illness = PackedFloat32Array()
	injury = PackedFloat32Array()
	job = PackedInt32Array()
	home = PackedInt32Array()
	trade = PackedByteArray()
	shift = PackedByteArray()
	hazard = PackedByteArray()
	shelter = PackedFloat32Array()
	state = PackedByteArray()
	state_since = PackedInt32Array()
	inside = PackedByteArray()
	dest = PackedInt32Array()
	dest_x = PackedInt32Array()
	dest_y = PackedInt32Array()
	from_x = PackedInt32Array()
	from_y = PackedInt32Array()
	px = PackedFloat32Array()
	py = PackedFloat32Array()
	wx = PackedFloat32Array()
	wy = PackedFloat32Array()
	route = PackedInt32Array()
	route_step = PackedInt32Array()
	jitter_x = PackedFloat32Array()
	jitter_y = PackedFloat32Array()
	death_cause = PackedByteArray()
	eat_until = PackedInt32Array()
	alive = PackedInt32Array()
	by_id.clear()
	free_slots = PackedInt32Array()
	_clear_pending()


func population() -> int:
	return alive.size()


## Slot for a citizen id, or -1.
func slot_of(id: int) -> int:
	return by_id.get(id, -1)


func has(id: int) -> bool:
	return by_id.has(id)


## Allocates a slot and fills in everything that never changes. The caller owns
## needs, position and assignment. Returns the slot.
func spawn(id: int, first_idx: int, last_idx: int, years: int, trait_id: int, tick: int) -> int:
	var s: int = -1
	if not free_slots.is_empty():
		s = free_slots[0]
		free_slots.remove_at(0)
	else:
		s = capacity
		_grow(capacity + 1)
	ids[s] = id
	first_name[s] = first_idx
	last_name[s] = last_idx
	age[s] = years
	age_frac[s] = 0.0
	traits[s] = trait_id
	born_tick[s] = tick
	health[s] = 100.0
	warmth[s] = 62.0
	hunger[s] = 22.0
	fatigue[s] = 18.0
	morale[s] = 55.0
	illness[s] = 0.0
	injury[s] = 0.0
	job[s] = -1
	home[s] = -1
	trade[s] = CitizenDefs.Trade.LABOURER
	shift[s] = CitizenDefs.Shift.OFF
	hazard[s] = 0
	shelter[s] = 0.0
	state[s] = CitizenDefs.State.IDLE
	state_since[s] = tick
	inside[s] = 0
	dest[s] = -1
	dest_x[s] = -1
	dest_y[s] = -1
	from_x[s] = -1
	from_y[s] = -1
	route[s] = -1
	route_step[s] = 0
	death_cause[s] = 0
	eat_until[s] = 0
	# A stable per-citizen offset so a crowd at one door reads as a crowd
	# instead of one sprite. Derived from the id, never rolled, so it survives
	# a save and cannot shift a replay.
	var h: int = (id * 2654435761) & 0xFFFF
	jitter_x[s] = (float(h & 0xFF) / 255.0 - 0.5) * 2.0 * CitizenDefs.CROWD_SPREAD
	jitter_y[s] = (float((h >> 8) & 0xFF) / 255.0 - 0.5) * 2.0 * CitizenDefs.CROWD_SPREAD
	by_id[id] = s
	_insert_alive(s)
	return s


## Retires a slot. The citizen is gone; the memory of them is the system's job.
func despawn(s: int) -> void:
	if s < 0 or s >= capacity:
		return
	by_id.erase(ids[s])
	state[s] = CitizenDefs.State.DEAD
	job[s] = -1
	home[s] = -1
	dest[s] = -1
	route[s] = -1
	_remove_alive(s)
	_insert_free(s)


func _grow(n: int) -> void:
	if n <= capacity:
		return
	ids.resize(n)
	first_name.resize(n)
	last_name.resize(n)
	age.resize(n)
	age_frac.resize(n)
	traits.resize(n)
	born_tick.resize(n)
	health.resize(n)
	warmth.resize(n)
	hunger.resize(n)
	fatigue.resize(n)
	morale.resize(n)
	illness.resize(n)
	injury.resize(n)
	job.resize(n)
	home.resize(n)
	trade.resize(n)
	shift.resize(n)
	hazard.resize(n)
	shelter.resize(n)
	state.resize(n)
	state_since.resize(n)
	inside.resize(n)
	dest.resize(n)
	dest_x.resize(n)
	dest_y.resize(n)
	from_x.resize(n)
	from_y.resize(n)
	px.resize(n)
	py.resize(n)
	wx.resize(n)
	wy.resize(n)
	route.resize(n)
	route_step.resize(n)
	jitter_x.resize(n)
	jitter_y.resize(n)
	death_cause.resize(n)
	eat_until.resize(n)
	capacity = n


func _insert_alive(s: int) -> void:
	var n: int = alive.size()
	var lo: int = 0
	var hi: int = n
	while lo < hi:
		var mid: int = (lo + hi) >> 1
		if alive[mid] < s:
			lo = mid + 1
		else:
			hi = mid
	alive.insert(lo, s)


func _remove_alive(s: int) -> void:
	var idx: int = alive.bsearch(s, true)
	if idx < alive.size() and alive[idx] == s:
		alive.remove_at(idx)


func _insert_free(s: int) -> void:
	var idx: int = free_slots.bsearch(s, true)
	if idx < free_slots.size() and free_slots[idx] == s:
		return
	free_slots.insert(idx, s)


func _clear_pending() -> void:
	pending_deaths = PackedInt32Array()
	pending_sick = PackedInt32Array()
	pending_injured = PackedInt32Array()
	pending_meals = PackedInt32Array()


func drain_pending() -> void:
	_clear_pending()


# =========================================================================
#  the body — needs, sickness, injury, death
# =========================================================================

## Advances one bucket of the population: slots `alive[phase], alive[phase+n], …`
##
## This is the hot loop of the part. Everything it touches is a packed array
## indexed by a local int; the only external call per citizen is one O(1) lookup
## into [P02]'s warmth field, which is what makes a cold street lethal.
func step_needs(phase: int, buckets: int, ctx: Ctx) -> void:
	var n: int = alive.size()
	if n == 0:
		return
	var dt: float = ctx.dt
	var field: WarmthField = ctx.field
	var ambient: float = ctx.ambient
	var wind_loss: float = 1.0 + ctx.wind * CitizenDefs.WIND_CHILL
	var care: float = clampf(ctx.care_ratio, 0.0, 1.0)
	var contagion: float = ctx.contagion * CitizenDefs.CONTAGION_PER_SEC * dt
	var rng: RandomNumberGenerator = ctx.rng
	var span: float = CitizenDefs.WARM_COMFORT_C - CitizenDefs.WARM_LETHAL_C
	var exposure: float = ctx.exposure_resist
	var healing: float = ctx.heal_mult

	var i: int = phase
	while i < n:
		var s: int = alive[i]
		i += buckets
		var st: int = state[s]
		if st == CitizenDefs.State.DEAD:
			continue

		var t_id: int = traits[s]
		var bracket: int = CitizenDefs.age_bracket(age[s])
		var indoors: bool = inside[s] == 1

		# --- warmth: what the air, the roof and the heat grid add up to -------
		var felt: float = ambient
		if field != null:
			felt += field.value_at(Vector2i(int(px[s]), int(py[s])))
		if indoors:
			felt += shelter[s]
		var target: float = clampf((felt - CitizenDefs.WARM_LETHAL_C) / span, 0.0, 1.0) * 100.0
		var w: float = warmth[s]
		if target > w:
			w += (target - w) * CitizenDefs.WARM_GAIN_RATE * dt
		else:
			var loss: float = CitizenDefs.WARM_LOSS_RATE * CitizenDefs.TRAIT_COLD[t_id] \
				* dt / maxf(0.05, exposure)
			if not indoors:
				loss *= wind_loss
			w += (target - w) * minf(loss, 1.0)
		w = clampf(w, 0.0, 100.0)
		warmth[s] = w

		# --- hunger ------------------------------------------------------------
		var hu: float = hunger[s]
		var burn: float = CitizenDefs.HUNGER_PER_SEC
		if st == CitizenDefs.State.SLEEPING:
			burn *= CitizenDefs.HUNGER_SLEEP_FACTOR
		if bracket == CitizenDefs.Age.CHILD:
			burn *= CitizenDefs.HUNGER_CHILD_FACTOR
		hu = minf(100.0, hu + burn * dt)
		hunger[s] = hu
		if hu >= CitizenDefs.HUNGER_MEAL_WANT and st != CitizenDefs.State.EATING:
			pending_meals.append(s)

		# --- fatigue -----------------------------------------------------------
		var fa: float = fatigue[s]
		if st == CitizenDefs.State.SLEEPING:
			fa += (CitizenDefs.FATIGUE_SLEEP_PER_SEC if home[s] >= 0
				else CitizenDefs.FATIGUE_ROUGH_PER_SEC) * dt
		elif st == CitizenDefs.State.WORKING:
			fa += CitizenDefs.FATIGUE_WORK_PER_SEC * ctx.fatigue_mult \
				* CitizenDefs.TRAIT_WORK[t_id] * dt
		elif st == CitizenDefs.State.SICK or st == CitizenDefs.State.INJURED:
			fa += CitizenDefs.FATIGUE_ROUGH_PER_SEC * 0.5 * dt
		else:
			fa += CitizenDefs.FATIGUE_AWAKE_PER_SEC * dt
		fa = clampf(fa, 0.0, 100.0)
		fatigue[s] = fa

		# --- illness: cold, hunger, exhaustion and each other ------------------
		var ill: float = illness[s]
		var sick_gain: float = 0.0
		if w < CitizenDefs.COLD_SICK_BELOW:
			sick_gain += (CitizenDefs.COLD_SICK_BELOW - w) * CitizenDefs.COLD_SICK_PER_SEC * dt
		if hu >= CitizenDefs.HUNGER_STARVING:
			sick_gain += CitizenDefs.MALNUTRITION_SICK_PER_SEC * dt
		if fa >= CitizenDefs.FATIGUE_EXHAUSTED:
			sick_gain += CitizenDefs.EXHAUSTION_SICK_PER_SEC * dt
		sick_gain += contagion
		if sick_gain > 0.0:
			sick_gain *= CitizenDefs.TRAIT_SICK[t_id]
			if bracket == CitizenDefs.Age.ELDER:
				sick_gain *= CitizenDefs.ELDER_SICK_FACTOR
			elif bracket == CitizenDefs.Age.CHILD:
				sick_gain *= CitizenDefs.CHILD_SICK_FACTOR
		var resting: bool = st == CitizenDefs.State.SLEEPING or st == CitizenDefs.State.SICK \
			or st == CitizenDefs.State.INJURED
		if ill > 0.0 and w >= 50.0 and hu < 70.0 and resting:
			var heal: float = CitizenDefs.ILLNESS_RECOVER_PER_SEC * dt
			heal *= (1.0 + care * (CitizenDefs.CARE_RECOVERY_MULT - 1.0)) * healing
			sick_gain -= heal
		ill = clampf(ill + sick_gain, 0.0, 100.0)
		illness[s] = ill

		# --- injury heals, slowly, and faster with a medic ---------------------
		var inj: float = injury[s]
		if inj > 0.0:
			inj = maxf(0.0, inj - CitizenDefs.INJURY_HEAL_PER_SEC
				* (1.0 + care * 1.5) * healing * dt)
			injury[s] = inj

		# --- health: the sum of everything going wrong -------------------------
		var hp: float = health[s]
		var harm: float = 0.0
		if hu >= CitizenDefs.HUNGER_STARVING:
			harm += (hu - CitizenDefs.HUNGER_STARVING) * CitizenDefs.STARVE_HEALTH_PER_SEC * 0.15 * dt
			harm += CitizenDefs.STARVE_HEALTH_PER_SEC * dt
		if w <= CitizenDefs.FREEZING_BELOW:
			harm += (CitizenDefs.FREEZING_BELOW - w) * CitizenDefs.FREEZE_HEALTH_PER_SEC * dt
		if ill > CitizenDefs.ILLNESS_HARM_ABOVE:
			harm += (ill - CitizenDefs.ILLNESS_HARM_ABOVE) * CitizenDefs.ILLNESS_HEALTH_PER_SEC * dt
		if inj > CitizenDefs.INJURY_HARM_ABOVE:
			harm += (inj - CitizenDefs.INJURY_HARM_ABOVE) * CitizenDefs.INJURY_HEALTH_PER_SEC * dt
		if fa >= CitizenDefs.FATIGUE_EXHAUSTED:
			harm += CitizenDefs.EXHAUST_HEALTH_PER_SEC * dt
		if harm > 0.0:
			hp -= harm
		elif hp < 100.0:
			var rec: float = CitizenDefs.HEALTH_RECOVER_PER_SEC * dt
			if bracket == CitizenDefs.Age.ELDER:
				rec *= CitizenDefs.ELDER_RECOVER_FACTOR
			if resting:
				rec *= 1.6
			hp += rec
		hp = minf(hp, 100.0)

		# --- morale ------------------------------------------------------------
		var mt: float = CitizenDefs.MORALE_BASE
		mt += CitizenDefs.MORALE_FROM_WARMTH * (w * 0.01)
		mt += CitizenDefs.MORALE_FROM_FOOD * (1.0 - hu * 0.01)
		mt += CitizenDefs.MORALE_FROM_REST * (1.0 - fa * 0.01)
		if home[s] >= 0:
			mt += CitizenDefs.MORALE_HOUSED
		elif bracket != CitizenDefs.Age.CHILD:
			mt -= CitizenDefs.MORALE_JOBLESS_PENALTY * 0.5
		if ill >= CitizenDefs.SICK_ONSET:
			mt -= CitizenDefs.MORALE_SICK_PENALTY
		if inj >= CitizenDefs.INJURY_CLEAR:
			mt -= CitizenDefs.MORALE_INJURED_PENALTY
		if job[s] < 0 and bracket == CitizenDefs.Age.ADULT:
			mt -= CitizenDefs.MORALE_JOBLESS_PENALTY
		mt += ctx.morale_offset
		mt = clampf(mt, 0.0, 100.0)
		var mo: float = morale[s]
		var drift: float = CitizenDefs.MORALE_DRIFT_PER_SEC * dt
		if mt < mo:
			drift *= CitizenDefs.TRAIT_MORALE[t_id]
		morale[s] = clampf(mo + (mt - mo) * minf(drift, 1.0), 0.0, 100.0)

		# --- accidents ---------------------------------------------------------
		if hazard[s] == 1 and st == CitizenDefs.State.WORKING and rng != null:
			var p: float = CitizenDefs.ACCIDENT_PER_SEC * dt
			p *= 1.0 + (fa * 0.01) * CitizenDefs.ACCIDENT_FATIGUE_MULT
			p *= 1.0 + (1.0 - morale[s] * 0.01) * CitizenDefs.ACCIDENT_MORALE_MULT
			if bracket != CitizenDefs.Age.ADULT:
				p *= 1.4
			if rng.randf() < p:
				var severity: float = CitizenDefs.INJURY_MIN + rng.randf() \
					* (CitizenDefs.INJURY_MAX - CitizenDefs.INJURY_MIN)
				injury[s] = maxf(injury[s], severity)
				hp -= severity * CitizenDefs.INJURY_HEALTH_FACTOR
				pending_injured.append(s)

		# --- ageing and the end ------------------------------------------------
		age_frac[s] += dt / (CitizenDefs.DAYS_PER_YEAR * 480.0)
		if age_frac[s] >= 1.0:
			age_frac[s] -= 1.0
			age[s] += 1
		if age[s] >= CitizenDefs.OLD_AGE_FROM and rng != null and hp > 0.0:
			var q: float = CitizenDefs.OLD_AGE_PER_SEC * dt * float(age[s] - CitizenDefs.OLD_AGE_FROM + 1)
			if rng.randf() < q:
				hp = 0.0
				death_cause[s] = 4

		health[s] = hp
		if hp <= 0.0:
			health[s] = 0.0
			if death_cause[s] == 0:
				death_cause[s] = _cause_index(s, hu, w, inj, ill)
			pending_deaths.append(s)
		elif ill >= CitizenDefs.SICK_ONSET and st != CitizenDefs.State.SICK \
				and st != CitizenDefs.State.INJURED:
			pending_sick.append(s)


## Which of the many things going wrong actually killed them. Order matters:
## the player must be told the reason they could have prevented.
func _cause_index(s: int, hu: float, w: float, inj: float, ill: float) -> int:
	if hu >= CitizenDefs.HUNGER_STARVING:
		return 1
	if w <= CitizenDefs.FREEZING_BELOW:
		return 0
	if inj >= CitizenDefs.INJURY_CLEAR:
		return 3
	if ill >= CitizenDefs.SICK_CLEAR:
		return 2
	if age[s] >= CitizenDefs.OLD_AGE_FROM:
		return 4
	return 5


static func cause_of(index: int) -> StringName:
	if index < 0 or index >= CAUSE_INDEX.size():
		return CitizenDefs.CAUSE_EXHAUSTION
	return CAUSE_INDEX[index]


# =========================================================================
#  movement
# =========================================================================

## Walks everyone whose state is WALKING one tick along their route.
##
## Deliberately branch-light: the common case is "not yet at the waypoint",
## which costs eight array reads, two writes and a square root. Waypoint
## advance — the only path that touches the router — happens roughly once per
## citizen per cell walked, i.e. a few dozen times a tick for a whole city.
func step_movement(router: CitizenRouter, snow_factor: float, dt: float) -> void:
	var n: int = alive.size()
	var base: float = CitizenDefs.WALK_CELLS_PER_SEC * dt
	for i: int in n:
		var s: int = alive[i]
		if state[s] != CitizenDefs.State.WALKING:
			continue
		var dx: float = wx[s] - px[s]
		var dy: float = wy[s] - py[s]
		var d2: float = dx * dx + dy * dy
		if d2 <= CitizenDefs.ARRIVE_EPSILON2:
			px[s] = wx[s]
			py[s] = wy[s]
			_advance_waypoint(s, router)
			continue
		var spd: float = base * _speed_factor(s, snow_factor)
		var d: float = sqrt(d2)
		if spd >= d:
			px[s] = wx[s]
			py[s] = wy[s]
			_advance_waypoint(s, router)
			continue
		var inv: float = spd / d
		px[s] += dx * inv
		py[s] += dy * inv


func _speed_factor(s: int, snow_factor: float) -> float:
	var f: float = 1.0
	var bracket: int = CitizenDefs.age_bracket(age[s])
	if bracket == CitizenDefs.Age.CHILD:
		f *= CitizenDefs.WALK_CHILD_FACTOR
	elif bracket == CitizenDefs.Age.ELDER:
		f *= CitizenDefs.WALK_ELDER_FACTOR
	f *= 1.0 - CitizenDefs.WALK_FATIGUE_PENALTY * (fatigue[s] * 0.01)
	f *= 1.0 - CitizenDefs.WALK_SICK_PENALTY * (illness[s] * 0.01)
	f *= snow_factor
	return maxf(f, CitizenDefs.WALK_MIN_FACTOR)


## Pulls the next cell off the route, or lands the citizen at the destination.
func _advance_waypoint(s: int, router: CitizenRouter) -> void:
	var r: int = route[s]
	if r >= 0:
		route_step[s] += 1
		var next: Vector2i = router.waypoint(r, route_step[s])
		if next.x >= 0:
			wx[s] = float(next.x) + 0.5
			wy[s] = float(next.y) + 0.5
			return
		route[s] = -1
	# End of the line. If we are not standing on the destination the route was
	# stale — walk the last stretch straight rather than freezing in the road.
	var tx: float = float(dest_x[s]) + 0.5 + jitter_x[s]
	var ty: float = float(dest_y[s]) + 0.5 + jitter_y[s]
	var dx: float = tx - px[s]
	var dy: float = ty - py[s]
	if dx * dx + dy * dy > CitizenDefs.ARRIVE_EPSILON2:
		wx[s] = tx
		wy[s] = ty
		return
	px[s] = tx
	py[s] = ty
	state[s] = CitizenDefs.State.IDLE


## True once the citizen is standing on the tile they were sent to.
func at_destination(s: int) -> bool:
	if dest_x[s] < 0:
		return false
	var dx: float = float(dest_x[s]) + 0.5 + jitter_x[s] - px[s]
	var dy: float = float(dest_y[s]) + 0.5 + jitter_y[s] - py[s]
	return dx * dx + dy * dy <= CitizenDefs.ARRIVE_EPSILON2 * 4.0


func cell_of(s: int) -> Vector2i:
	return Vector2i(int(px[s]), int(py[s]))


func set_position(s: int, cell: Vector2i) -> void:
	px[s] = float(cell.x) + 0.5 + jitter_x[s]
	py[s] = float(cell.y) + 0.5 + jitter_y[s]
	wx[s] = px[s]
	wy[s] = py[s]


func set_state(s: int, new_state: int, tick: int) -> void:
	if state[s] == new_state:
		return
	state[s] = new_state
	state_since[s] = tick


# =========================================================================
#  aggregate
# =========================================================================

## One pass over the population for every number metrics() and the HUD report.
## Called once per tick; a thousand slots of packed reads is cheaper than
## keeping a dozen counters correct across every mutation site.
func tally() -> void:
	sum_warmth = 0.0
	sum_morale = 0.0
	sum_health = 0.0
	sum_hunger = 0.0
	sum_fatigue = 0.0
	count_sick = 0
	count_injured = 0
	count_working = 0
	count_sleeping = 0
	count_walking = 0
	count_homeless = 0
	count_employed = 0
	count_unrest = 0
	var n: int = alive.size()
	for i: int in n:
		var s: int = alive[i]
		sum_warmth += warmth[s]
		sum_morale += morale[s]
		sum_health += health[s]
		sum_hunger += hunger[s]
		sum_fatigue += fatigue[s]
		if illness[s] >= CitizenDefs.SICK_ONSET:
			count_sick += 1
		if injury[s] >= CitizenDefs.INJURY_CLEAR:
			count_injured += 1
		var st: int = state[s]
		if st == CitizenDefs.State.WORKING:
			count_working += 1
		elif st == CitizenDefs.State.SLEEPING:
			count_sleeping += 1
		elif st == CitizenDefs.State.WALKING:
			count_walking += 1
		if home[s] < 0:
			count_homeless += 1
		if job[s] >= 0:
			count_employed += 1
		if morale[s] < CitizenDefs.MORALE_UNREST_BELOW:
			count_unrest += 1


func average(sum: float) -> float:
	var n: int = alive.size()
	return 0.0 if n == 0 else sum / float(n)

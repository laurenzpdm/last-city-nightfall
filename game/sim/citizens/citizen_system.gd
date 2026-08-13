class_name CitizenSystem
extends SimSystem
## [P05] Citizens — the reason any of the other numbers matter.
##
## Frostpunk's power comes from the fact that the numbers are people. This
## system keeps a real individual behind every unit of population: a name, an
## age, a trade, a bed, a shift, a body that gets cold and hungry and tired, and
## a death with a cause that can be named in a sentence.
##
## The loop it closes, end to end:
##
##   [P09] climate says how cold the air is
##     → [P02] heat says how much of that a roof and a radiator take back,
##       per building, including whether that building is being STARVED
##     → a citizen standing there warms or freezes
##     → freezing citizens fall ill, ill citizens stop working
##     → unstaffed buildings underperform, so less heat is made
##     → the next citizen freezes faster.
##
## That is the death spiral, and it is wired to real solver output rather than
## to a radius check: `CitizenJobBoard._shelter_for` reads `HeatSystem.served_of`,
## so a browned-out district is a district where people actually die.
##
## Contracts other parts use:
##   population() / metrics()            headline numbers for [P17] HUD
##   citizen_info(id) -> Dictionary      one person, richly, for an inspector
##   citizens_in_cell_rect(rect)         click-to-inspect for [P16]/[P19]
##   staffing_of(building_id) -> float   0..1 crew present, for [P04]/[P07]
##   idle_builders() -> int              construction manpower, for [P11]
##   average_morale() / unrest_pressure() for [P06] society
##   recent_deaths(n)                    obituaries for [P22] narrative
##   agents_for_view()                   people on screen, for [P13]
##
## Performance: needs, health and behaviour run on one of CitizenDefs.NEED_BUCKETS
## rotating slices per tick, movement touches only citizens who are walking, and
## the job market re-reads [P11] once a second. `metrics()["step_us"]` reports
## what a tick of this system actually cost.

const SYSTEM_ORDER: int = 50
const TAG: String = "citizens"
const RNG_STREAM: String = "citizens"
const TILE: float = 32.0

## Fraction of the workforce put on the night rotation.
const NIGHT_EVERY: int = 3
## Ticks between presence recounts. Staffing has to react inside a second.
const PRESENCE_TICKS: int = 5
## Beds handed out per housing pass.
const MOVE_INS_PER_PASS: int = 16
## How many of the unemployed a hiring pass looks at, and how many of the
## roofless a housing pass looks at. See _collect_free_hands for why these are
## windows rather than the whole queue.
const JOBLESS_SAMPLE: int = 96
const HOMELESS_SAMPLE: int = 64
## Deaths reported to the log in full; beyond this per tick it is a summary.
const DEATH_DETAIL_CAP: int = 6

var pool: CitizenPool = CitizenPool.new()
var board: CitizenJobBoard = CitizenJobBoard.new()
var router: CitizenRouter = CitizenRouter.new()

# --- city-level state --------------------------------------------------------
var _next_id: int = 1
var _tick: int = 0
var _larder: float = 0.0
var _meal_debt: float = 0.0
var _grief: float = 0.0
var _shift_law: StringName = CitizenDefs.LAW_STANDARD
var _child_labour: bool = false
var _elder_labour: bool = false
var _hire_counter: int = 0
var _queue_cursor: int = 0
var _roster_version: int = 0

# --- totals ------------------------------------------------------------------
var _dead_total: int = 0
var _deaths_by_cause: Dictionary[StringName, int] = {}
var _arrivals_total: int = 0
var _meals_served: int = 0
var _meals_missed: int = 0
var _accidents_total: int = 0
var _sickness_total: int = 0
var _obituary: Array[Dictionary] = []
var _last_deaths: PackedInt32Array = PackedInt32Array()

# --- neighbours --------------------------------------------------------------
var _climate: SimSystem = null
var _heat: SimSystem = null
var _grid: SimSystem = null
var _build: SimSystem = null
var _society: SimSystem = null
var _stock: SimSystem = null
var _warmth: WarmthField = null
var _has_phase: bool = false
var _has_ambient: bool = false
var _has_wind: bool = false
var _has_snow: bool = false
var _has_warmth_field: bool = false
var _m_hope: String = ""
var _m_stock_count: bool = false

# --- per-tick scratch --------------------------------------------------------
var _phase: int = 1
var _ambient: float = -18.0
var _wind: float = 0.0
var _snow_factor: float = 1.0
var _ctx: CitizenPool.Ctx = CitizenPool.Ctx.new()
var _alerts: Dictionary[StringName, int] = {}
var _jobless: PackedInt32Array = PackedInt32Array()
var _homeless: PackedInt32Array = PackedInt32Array()
var _idle_builders: int = 0
var _step_us: int = 0
var _view_agents: Array[Dictionary] = []
var _view_version: int = -1
var _view_tick: int = -1


func _init() -> void:
	order = SYSTEM_ORDER


func system_name() -> StringName:
	return &"citizens"


# =========================================================================
#  lifecycle
# =========================================================================

func setup() -> void:
	order = SYSTEM_ORDER
	pool.clear()
	board.clear()
	router = CitizenRouter.new()
	_next_id = 1
	_tick = 0
	_larder = CitizenDefs.STARTING_LARDER
	_meal_debt = 0.0
	_grief = 0.0
	_shift_law = CitizenDefs.LAW_STANDARD
	_child_labour = false
	_elder_labour = false
	_hire_counter = 0
	_queue_cursor = 0
	_roster_version = 0
	_dead_total = 0
	_deaths_by_cause = {}
	_arrivals_total = 0
	_meals_served = 0
	_meals_missed = 0
	_accidents_total = 0
	_sickness_total = 0
	_obituary = []
	_alerts = {}
	_ctx = CitizenPool.Ctx.new()
	_ctx.dt = float(CitizenDefs.NEED_BUCKETS) * SimClock.DT


func post_setup() -> void:
	_climate = Sim.get_system(&"climate")
	_heat = Sim.get_system(&"heat")
	_grid = Sim.get_system(&"grid")
	_build = Sim.get_system(&"build")
	_society = Sim.get_system(&"society")
	_has_phase = _climate != null and _climate.has_method("phase_index")
	_has_ambient = _climate != null and _climate.has_method("ambient_temperature")
	_has_wind = _climate != null and _climate.has_method("wind")
	_has_snow = _climate != null and _climate.has_method("snow_depth")
	_has_warmth_field = _heat != null and _heat.has_method("warmth_field")
	if _has_warmth_field:
		_warmth = _heat.call("warmth_field")
	_m_hope = _find_method(_society, ["citizen_morale_offset", "morale_offset", "hope"], 0)
	for candidate: StringName in [&"logistics", &"production", &"economy", &"build"]:
		var s: SimSystem = Sim.get_system(candidate)
		if s != null and s.has_method("stock_count") and s.has_method("stock_take"):
			_stock = s
			_m_stock_count = true
			break
	board.bind(_build, _heat, _grid)
	router.bind(_grid)
	_found_population()
	Log.info(TAG, "ready — %d founders, climate=%s heat=%s grid=%s build=%s pathing=%s" % [
		pool.population(), str(_climate != null), str(_heat != null), str(_grid != null),
		str(_build != null), "grid" if router.has_grid() else "straight-line"])


## The founding group: whoever walked out of the last city alive. Rolled from
## Rng.stream("citizens") so two runs on one seed are the same eighteen people.
func _found_population() -> void:
	var r: RandomNumberGenerator = Rng.stream(RNG_STREAM)
	var origin: Vector2i = _core_cell()
	var children: int = int(round(float(CitizenDefs.START_POPULATION) * CitizenDefs.START_CHILD_FRACTION))
	var elders: int = int(round(float(CitizenDefs.START_POPULATION) * CitizenDefs.START_ELDER_FRACTION))
	for i: int in CitizenDefs.START_POPULATION:
		var years: int = 0
		if i < children:
			years = 5 + int(r.randi_range(0, 9))
		elif i < children + elders:
			years = CitizenDefs.ELDER_MIN_AGE + int(r.randi_range(0, 12))
		else:
			years = 18 + int(r.randi_range(0, 38))
		var slot: int = _spawn(years, r)
		# Fan the founders out around the core so they do not start stacked.
		var ring: int = 2 + (i % 4)
		var ang: int = (i * 7) % 8
		var off: Vector2i = Grid.DIRS8[ang] * ring
		pool.set_position(slot, _walkable_near(origin + off))
	_roster_version += 1


func _spawn(years: int, r: RandomNumberGenerator) -> int:
	var id: int = _next_id
	_next_id += 1
	var slot: int = pool.spawn(id,
		int(r.randi_range(0, CitizenDefs.FIRST_NAMES.size() - 1)),
		int(r.randi_range(0, CitizenDefs.LAST_NAMES.size() - 1)),
		years,
		int(r.randi_range(0, CitizenDefs.TRAIT_NAMES.size() - 1)),
		_tick)
	pool.set_position(slot, _core_cell())
	return slot


func _core_cell() -> Vector2i:
	if _grid != null and _grid.has_method("core_cell"):
		return _grid.call("core_cell")
	return Vector2i(128, 128)


# =========================================================================
#  the tick
# =========================================================================

func step(tick: int) -> void:
	var t0: int = Time.get_ticks_usec()  # lint:allow — profiling only, never serialized
	_tick = tick
	_read_world()
	router.step(tick)

	if tick % CitizenDefs.JOB_SYNC_TICKS == 0:
		_sync_city(tick)
	if tick % PRESENCE_TICKS == 0:
		board.recount_presence(pool)
		board.publish_workers()

	var bucket: int = tick % CitizenDefs.NEED_BUCKETS
	_fill_context()
	pool.step_needs(bucket, CitizenDefs.NEED_BUCKETS, _ctx)
	_resolve_pending(tick)
	_step_behaviour(bucket, tick)
	pool.step_movement(router, _snow_factor, SimClock.DT)

	if tick % CitizenDefs.ARRIVAL_INTERVAL_TICKS == 0:
		_consider_arrivals(tick)

	_grief = maxf(0.0, _grief - CitizenDefs.GRIEF_DECAY_PER_SEC * SimClock.DT)
	pool.tally()
	_step_us = Time.get_ticks_usec() - t0  # lint:allow — profiling only


## Everything the outside world says this tick, read once instead of per person.
func _read_world() -> void:
	_phase = int(_climate.call("phase_index")) if _has_phase else 1
	_ambient = float(_climate.call("ambient_temperature")) if _has_ambient else -18.0
	_wind = clampf(float(_climate.call("wind")), 0.0, 1.0) if _has_wind else 0.0
	var snow: float = clampf(float(_climate.call("snow_depth")), 0.0, 1.0) if _has_snow else 0.0
	_snow_factor = 1.0 - CitizenDefs.WALK_SNOW_PENALTY * snow
	if _warmth == null and _has_warmth_field:
		_warmth = _heat.call("warmth_field")


func _fill_context() -> void:
	var n: int = maxi(1, pool.population())
	_ctx.tick = _tick
	_ctx.dt = float(CitizenDefs.NEED_BUCKETS) * SimClock.DT
	_ctx.ambient = _ambient
	_ctx.wind = _wind
	_ctx.field = _warmth
	_ctx.contagion = clampf(float(pool.count_sick) / float(n), 0.0, 1.0)
	_ctx.care_ratio = 0.0
	if pool.count_sick + pool.count_injured > 0:
		_ctx.care_ratio = clampf(float(board.care_capacity)
			/ float(pool.count_sick + pool.count_injured), 0.0, 1.0)
	_ctx.fatigue_mult = float(CitizenDefs.law_row(_shift_law).get("fatigue", 1.0))
	_ctx.morale_offset = -_grief + float(CitizenDefs.law_row(_shift_law).get("morale", 0.0)) \
		+ _society_morale()
	_ctx.rng = Rng.stream(RNG_STREAM)


## [P06] society has not landed yet and may name its number anything. Whatever
## it hands back is folded into morale as a bounded offset: a hope figure on
## 0..100 reads as a swing around the neutral middle, an already-signed modifier
## passes through unchanged.
func _society_morale() -> float:
	if _society == null or _m_hope == "":
		return 0.0
	var v: Variant = _society.call(_m_hope)
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	var f: float = float(v)
	if _m_hope == "hope":
		return clampf((f - 50.0) * 0.4, -20.0, 20.0)
	return clampf(f, -20.0, 20.0)


# =========================================================================
#  the city: buildings, jobs, beds, food
# =========================================================================

func _sync_city(tick: int) -> void:
	var before: int = board.version
	var gone: PackedInt32Array = board.refresh(tick)
	if not gone.is_empty():
		board.release(pool, gone)
	if board.version != before:
		# A new wall or a demolition changes what "walkable" means, and a path
		# cached through the old world walks into the new one.
		router.invalidate()
	_collect_free_hands()
	if not _homeless.is_empty():
		var moved: int = board.assign_homes(pool, _homeless, MOVE_INS_PER_PASS)
		if moved > 0:
			Log.debug(TAG, "%d citizens moved into housing" % moved)
	if not _jobless.is_empty():
		var hired: int = board.assign_jobs(pool, _jobless, _child_labour, _elder_labour,
			CitizenDefs.HIRES_PER_PASS)
		if hired > 0:
			_assign_shifts()
			Log.debug(TAG, "%d citizens took a job" % hired)


## Two slot lists the matcher needs, gathered in one pass.
##
## Both are SAMPLES, not the whole queue. Hiring is O(vacancies x candidates),
## so handing a thousand jobless people to twelve vacancies is an eight
## millisecond tick; handing it a rotating window of the queue costs a
## thousandth of that and still reaches everybody, because the window moves
## every pass. The city hires the nearest of whoever is at the front today —
## which is also what a foreman would do.
func _collect_free_hands() -> void:
	var jobless: PackedInt32Array = PackedInt32Array()
	var homeless: PackedInt32Array = PackedInt32Array()
	var builders: int = 0
	var n: int = pool.alive.size()
	if n == 0:
		_jobless = jobless
		_homeless = homeless
		_idle_builders = 0
		return
	var start: int = posmod(_queue_cursor, n)
	for k: int in n:
		var s: int = pool.alive[(start + k) % n]
		if pool.home[s] < 0 and homeless.size() < HOMELESS_SAMPLE:
			homeless.append(s)
		if pool.job[s] >= 0:
			continue
		var bracket: int = CitizenDefs.age_bracket(pool.age[s])
		if pool.illness[s] >= CitizenDefs.SICK_ONSET \
				or pool.injury[s] >= CitizenDefs.INJURY_CLEAR:
			continue
		if jobless.size() < JOBLESS_SAMPLE:
			jobless.append(s)
		# Spare hands raise [P11]'s build power, but only while they are awake
		# and on the clock — which is why a city visibly builds slower at night.
		if bracket == CitizenDefs.Age.ADULT and pool.state[s] != CitizenDefs.State.SLEEPING:
			builders += 1
	_queue_cursor += JOBLESS_SAMPLE
	_jobless = jobless
	_homeless = homeless
	_idle_builders = builders


## Splits the workforce across the rotations. Deterministic by hire order, so a
## replay staffs the night shift with the same people.
func _assign_shifts() -> void:
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		if pool.job[s] < 0:
			if pool.shift[s] != CitizenDefs.Shift.OFF:
				pool.shift[s] = CitizenDefs.Shift.OFF
			continue
		if pool.shift[s] != CitizenDefs.Shift.OFF:
			continue
		_hire_counter += 1
		pool.shift[s] = CitizenDefs.Shift.NIGHT if _hire_counter % NIGHT_EVERY == 0 \
			else CitizenDefs.Shift.DAY


# =========================================================================
#  consequences: meals, sickness, injury, death
# =========================================================================

func _resolve_pending(tick: int) -> void:
	if not pool.pending_meals.is_empty():
		_serve_meals(tick)
	if not pool.pending_injured.is_empty():
		for i: int in pool.pending_injured.size():
			_on_injury(pool.pending_injured[i], tick)
	if not pool.pending_sick.is_empty():
		_sickness_total += pool.pending_sick.size()
		if pool.count_sick > 0:
			_alert(&"citizens_sick", 1,
				"%d citizens are too ill to work." % (pool.count_sick + pool.pending_sick.size()),
				_citizen_pos(pool.pending_sick[0]), tick)
	if not pool.pending_deaths.is_empty():
		_bury(tick)
	pool.drain_pending()


## Hands out meals to everyone who asked this tick, in one withdrawal. A staffed
## kitchen stretches the ration; an empty larder means someone goes without and
## the hunger keeps climbing, which is how a famine actually reads.
func _serve_meals(tick: int) -> void:
	var wanting: PackedInt32Array = pool.pending_meals
	var per_meal: float = 1.0 / (1.0 + CitizenDefs.KITCHEN_EFFICIENCY * board.kitchen_factor)
	var served: int = 0
	var missed: int = 0
	for i: int in wanting.size():
		var s: int = wanting[i]
		if pool.state[s] == CitizenDefs.State.DEAD:
			continue
		if not _take_food(per_meal):
			missed += 1
			continue
		pool.hunger[s] = maxf(0.0, pool.hunger[s] - CitizenDefs.HUNGER_MEAL_RELIEF)
		pool.eat_until[s] = tick + CitizenDefs.EAT_TICKS
		pool.set_state(s, CitizenDefs.State.EATING, tick)
		served += 1
	_meals_served += served
	_meals_missed += missed
	if missed > 0 and pool.population() > 0:
		_alert(&"citizens_no_food", 1,
			"%d citizens went without a meal — the city is out of food." % missed,
			_shelter_pos(), tick)


## Draws one meal's worth of food, from the city stock first and the founders'
## larder second. Returns false when there is nothing left anywhere.
func _take_food(amount: float) -> bool:
	_meal_debt += amount
	while _meal_debt >= 1.0:
		if not _withdraw_food_unit():
			_meal_debt -= amount
			return false
		_meal_debt -= 1.0
	return true


func _withdraw_food_unit() -> bool:
	if _stock != null:
		for item: StringName in CitizenDefs.FOOD_ITEMS:
			if int(_stock.call("stock_count", item)) > 0:
				var one: Dictionary = {}
				one[String(item)] = 1
				if bool(_stock.call("stock_take", one)):
					return true
	if _larder >= 1.0:
		_larder -= 1.0
		return true
	return false


func _on_injury(slot: int, tick: int) -> void:
	_accidents_total += 1
	var site: CitizenJobBoard.Site = board.site_of(pool.job[slot])
	var where: String = site.label if site != null else "work"
	pool.set_state(slot, CitizenDefs.State.INJURED, tick)
	_alert(StringName("citizen_injured"), 1,
		"%s was hurt at the %s." % [_name_of(slot), where], _citizen_pos(slot), tick)
	Log.info(TAG, "#%d %s injured at %s (severity %.0f)" % [
		pool.ids[slot], _name_of(slot), where, pool.injury[slot]])


## A death is an EVENT. Name, age, trade, cause, place — everything [P22] needs
## to write a sentence and everything [P06] needs to make the city angry.
func _bury(tick: int) -> void:
	var dead: PackedInt32Array = pool.pending_deaths
	_last_deaths = PackedInt32Array()
	for i: int in dead.size():
		var slot: int = dead[i]
		if not pool.by_id.has(pool.ids[slot]):
			continue
		var id: int = pool.ids[slot]
		var cause: StringName = CitizenPool.cause_of(pool.death_cause[slot])
		var record: Dictionary = {
			"tick": tick,
			"id": id,
			"name": _name_of(slot),
			"age": pool.age[slot],
			"trade": _trade_label(slot),
			"cause": String(cause),
			"cell": [int(pool.px[slot]), int(pool.py[slot])],
			"homeless": pool.home[slot] < 0,
			"employed": pool.job[slot] >= 0,
		}
		_obituary.append(record)
		if _obituary.size() > CitizenDefs.OBITUARY_KEEP:
			_obituary.remove_at(0)
		_dead_total += 1
		_deaths_by_cause[cause] = int(_deaths_by_cause.get(cause, 0)) + 1
		_grief += CitizenDefs.GRIEF_PER_DEATH
		_last_deaths.append(id)

		var sentence: String = "%s, %d, %s, %s." % [
			_name_of(slot), pool.age[slot], _trade_label(slot),
			String(CitizenDefs.CAUSE_PHRASES.get(cause, "died"))]
		Bus.citizen_died.emit(id, cause)
		Bus.alert_raised.emit(1, &"citizen_died", sentence, _citizen_pos(slot))
		if i < DEATH_DETAIL_CAP:
			Log.info(TAG, sentence)
		board.vacate(pool, slot)
		pool.despawn(slot)
	if dead.size() > DEATH_DETAIL_CAP:
		Log.warn(TAG, "%d citizens died this tick" % dead.size())
	_roster_version += 1
	_grief = minf(_grief, 45.0)


# =========================================================================
#  behaviour: where a person goes and what they do when they get there
# =========================================================================

func _step_behaviour(phase: int, tick: int) -> void:
	var n: int = pool.alive.size()
	var i: int = phase
	while i < n:
		var s: int = pool.alive[i]
		i += CitizenDefs.NEED_BUCKETS
		_decide(s, tick)


func _decide(s: int, tick: int) -> void:
	var st: int = pool.state[s]
	if st == CitizenDefs.State.DEAD:
		return
	if st == CitizenDefs.State.EATING:
		if tick < pool.eat_until[s]:
			return
		pool.set_state(s, CitizenDefs.State.IDLE, tick)

	var want: int = -1
	var purpose: int = CitizenDefs.State.IDLE
	var sick: bool = pool.illness[s] >= CitizenDefs.SICK_ONSET
	var hurt: bool = pool.injury[s] >= CitizenDefs.INJURY_CLEAR
	if sick or hurt:
		purpose = CitizenDefs.State.SICK if sick else CitizenDefs.State.INJURED
		want = board.nearest_care(pool.cell_of(s))
		if want < 0:
			want = pool.home[s]
		if want < 0:
			want = board.shelter_building
	elif _on_duty(s) and pool.job[s] >= 0:
		var site: CitizenJobBoard.Site = board.site_of(pool.job[s])
		if site != null and site.operational:
			want = pool.job[s]
			purpose = CitizenDefs.State.WORKING
	if want < 0 and purpose == CitizenDefs.State.IDLE:
		if pool.home[s] >= 0:
			want = pool.home[s]
			purpose = CitizenDefs.State.SLEEPING
		else:
			want = board.shelter_building
			purpose = CitizenDefs.State.SLEEPING if _is_rest_phase() else CitizenDefs.State.IDLE

	if want != pool.dest[s]:
		_retarget(s, want, tick)

	if pool.state[s] == CitizenDefs.State.WALKING:
		if pool.at_destination(s):
			_arrive(s, purpose, tick)
		elif pool.route[s] < 0:
			_try_route(s, tick)
		return
	if want >= 0 and not pool.at_destination(s):
		pool.set_state(s, CitizenDefs.State.WALKING, tick)
		_try_route(s, tick)
		return
	_arrive(s, purpose, tick)


func _on_duty(s: int) -> bool:
	return CitizenDefs.works_in_phase(_shift_law, pool.shift[s], _phase)


## True during the hours a citizen with nowhere to be would be sleeping.
func _is_rest_phase() -> bool:
	return _phase >= ClimateDefs.Phase.NIGHT or _phase == ClimateDefs.Phase.DAWN


func _retarget(s: int, building: int, tick: int) -> void:
	# Snap the origin of the walk to the door they are leaving. Every worker in
	# one bunkhouse then asks for the SAME (from, to) pair, which is the whole
	# reason a thousand people cost a handful of path searches.
	var origin: Vector2i = pool.cell_of(s)
	if pool.inside[s] == 1 and pool.dest[s] >= 0:
		var previous: Vector2i = board.door_of(pool.dest[s])
		if previous.x >= 0:
			origin = previous
	pool.from_x[s] = origin.x
	pool.from_y[s] = origin.y
	pool.dest[s] = building
	pool.inside[s] = 0
	pool.shelter[s] = 0.0
	pool.route[s] = -1
	pool.route_step[s] = 0
	if building < 0:
		var here: Vector2i = pool.cell_of(s)
		pool.dest_x[s] = here.x
		pool.dest_y[s] = here.y
		return
	var door: Vector2i = board.door_of(building)
	if door.x < 0:
		pool.dest[s] = -1
		return
	pool.dest_x[s] = door.x
	pool.dest_y[s] = door.y
	if not pool.at_destination(s):
		pool.set_state(s, CitizenDefs.State.WALKING, tick)
		_try_route(s, tick)


## Asks [P01] for a path, from a door when we are standing at one so that a
## whole shift shares a single search. A refusal is not a stall: the walk falls
## back to a straight line and the request is retried on the next decision.
func _try_route(s: int, tick: int) -> void:
	var target := Vector2i(pool.dest_x[s], pool.dest_y[s])
	var from := Vector2i(pool.from_x[s], pool.from_y[s])
	if from.x < 0:
		from = pool.cell_of(s)
	var r: int = router.request(from, target, tick)
	if r >= 0:
		pool.route[s] = r
		var step: int = router.entry_index(r, pool.px[s], pool.py[s]) + 1
		pool.route_step[s] = step
		var wp: Vector2i = router.waypoint(r, step)
		if wp.x >= 0:
			pool.wx[s] = float(wp.x) + 0.5
			pool.wy[s] = float(wp.y) + 0.5
			return
		pool.route[s] = -1
	pool.wx[s] = float(target.x) + 0.5 + pool.jitter_x[s]
	pool.wy[s] = float(target.y) + 0.5 + pool.jitter_y[s]


func _arrive(s: int, purpose: int, tick: int) -> void:
	var b: int = pool.dest[s]
	if b >= 0:
		var site: CitizenJobBoard.Site = board.site_of(b)
		if site != null:
			pool.inside[s] = 1
			pool.shelter[s] = site.shelter_c
	pool.route[s] = -1
	if purpose == CitizenDefs.State.SLEEPING and pool.fatigue[s] < 12.0 and not _is_rest_phase():
		pool.set_state(s, CitizenDefs.State.IDLE, tick)
		return
	pool.set_state(s, purpose, tick)


# =========================================================================
#  arrivals — the road out of the white
# =========================================================================

func _consider_arrivals(tick: int) -> void:
	if pool.population() >= CitizenDefs.MAX_POPULATION:
		return
	var spare: int = board.spare_beds()
	if spare < CitizenDefs.ARRIVAL_MIN_SPARE_BEDS:
		return
	if pool.average(pool.sum_morale) < CitizenDefs.ARRIVAL_MIN_MORALE:
		return
	if food_days_remaining() < CitizenDefs.ARRIVAL_MIN_FOOD_DAYS:
		return
	var r: RandomNumberGenerator = Rng.stream(RNG_STREAM)
	var group: int = mini(spare, int(r.randi_range(
		CitizenDefs.ARRIVAL_GROUP_MIN, CitizenDefs.ARRIVAL_GROUP_MAX)))
	if group <= 0:
		return
	var gate: Vector2i = _gate_cell()
	for i: int in group:
		var years: int = 18 + int(r.randi_range(0, 40))
		if r.randf() < 0.2:
			years = 6 + int(r.randi_range(0, 8))
		var slot: int = _spawn(years, r)
		pool.set_position(slot, _walkable_near(gate + Vector2i(i % 3, i / 3)))
		# They arrive cold and hungry. That is the point of them.
		pool.warmth[slot] = 34.0
		pool.hunger[slot] = 64.0
		pool.fatigue[slot] = 58.0
		pool.morale[slot] = 48.0
	_arrivals_total += group
	_roster_version += 1
	_alert(&"citizens_arrived", 1,
		"%d survivors reached the gate." % group, _cell_pos(gate), tick)
	Log.info(TAG, "%d survivors arrived (population %d)" % [group, pool.population()])


## Where newcomers appear: the mouth of an approach lane when [P01] knows one,
## otherwise a few tiles north of the core — and always on ground somebody can
## actually stand on. A survivor who arrives inside a wall can never path
## anywhere again, and the only symptom is a crowd that never goes to work.
func _gate_cell() -> Vector2i:
	var candidate: Vector2i = _core_cell() + Vector2i(0, -8)
	if _grid != null and _grid.has_method("approach_lanes"):
		var lanes: Array = _grid.call("approach_lanes")
		if not lanes.is_empty():
			var first: Dictionary = lanes[0]
			var v: Variant = first.get("entry", first.get("cell", null))
			if typeof(v) == TYPE_VECTOR2I:
				candidate = v
	return _walkable_near(candidate)


## The nearest tile to `cell` a person can stand on, searched in a fixed ring
## order so two runs put the same people in the same place.
func _walkable_near(cell: Vector2i, radius: int = 6) -> Vector2i:
	if _grid == null or not _grid.has_method("is_walkable"):
		return cell
	if bool(_grid.call("is_walkable", cell)):
		return cell
	for r: int in range(1, radius + 1):
		for dy: int in range(-r, r + 1):
			for dx: int in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c: Vector2i = cell + Vector2i(dx, dy)
				if bool(_grid.call("is_walkable", c)):
					return c
	return cell


# =========================================================================
#  public API
# =========================================================================

## Living citizens.
func population() -> int:
	return pool.population()


## Every living citizen id, ascending.
func citizen_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	var n: int = pool.alive.size()
	out.resize(n)
	for i: int in n:
		out[i] = pool.ids[pool.alive[i]]
	out.sort()
	return out


func has_citizen(id: int) -> bool:
	return pool.has(id)


## One person, richly enough that a UI can show a life:
## "Mara Kessler, 34, tinsmith — cold and hungry, walking to Workshop 2".
## Empty when the id is not a living citizen.
func citizen_info(id: int) -> Dictionary:
	var s: int = pool.slot_of(id)
	if s < 0:
		return {}
	var bracket: int = CitizenDefs.age_bracket(pool.age[s])
	var job_site: CitizenJobBoard.Site = board.site_of(pool.job[s])
	var home_site: CitizenJobBoard.Site = board.site_of(pool.home[s])
	var dest_site: CitizenJobBoard.Site = board.site_of(pool.dest[s])
	var condition: String = CitizenDefs.condition_phrase(pool.warmth[s], pool.hunger[s],
		pool.fatigue[s], pool.illness[s], pool.injury[s], pool.morale[s])
	var doing: String = _activity_phrase(s, dest_site)
	return {
		"id": id,
		"name": _name_of(s),
		"age": pool.age[s],
		"age_bracket": String(CitizenDefs.age_name(bracket)),
		"trait": String(CitizenDefs.TRAIT_LABELS[pool.traits[s]]),
		"profession": _trade_label(s),
		"profession_id": String(CitizenDefs.trade_name(_trade_index(s))),
		"state": String(CitizenDefs.state_name(pool.state[s])),
		"state_label": CitizenDefs.state_label(pool.state[s]),
		"state_ticks": _tick - pool.state_since[s],
		"shift": String(CitizenDefs.shift_name(pool.shift[s])),
		"on_duty": _on_duty(s),
		"health": snappedf(pool.health[s], 0.1),
		"warmth": snappedf(pool.warmth[s], 0.1),
		"hunger": snappedf(pool.hunger[s], 0.1),
		"fatigue": snappedf(pool.fatigue[s], 0.1),
		"morale": snappedf(pool.morale[s], 0.1),
		"illness": snappedf(pool.illness[s], 0.1),
		"injury": snappedf(pool.injury[s], 0.1),
		"felt_temperature": snappedf(_felt_temperature(s), 0.1),
		"job": pool.job[s],
		"job_name": job_site.label if job_site != null else "",
		"home": pool.home[s],
		"home_name": home_site.label if home_site != null else "",
		"housed": pool.home[s] >= 0,
		"indoors": pool.inside[s] == 1,
		"cell": [int(pool.px[s]), int(pool.py[s])],
		"pos": [snappedf(pool.px[s] * TILE, 0.01), snappedf(pool.py[s] * TILE, 0.01)],
		"destination": pool.dest[s],
		"destination_name": dest_site.label if dest_site != null else "",
		"condition": condition,
		"doing": doing,
		"summary": "%s, %d, %s — %s, %s" % [_name_of(s), pool.age[s],
			_trade_label(s), condition, doing],
	}


func _activity_phrase(s: int, dest_site: CitizenJobBoard.Site) -> String:
	match pool.state[s]:
		CitizenDefs.State.WALKING:
			if dest_site != null:
				return "walking to %s" % dest_site.label
			return "walking"
		CitizenDefs.State.WORKING:
			return "working at %s" % (dest_site.label if dest_site != null else "their post")
		CitizenDefs.State.SLEEPING:
			if dest_site != null and pool.home[s] == dest_site.id:
				return "asleep at %s" % dest_site.label
			return "sleeping rough"
		CitizenDefs.State.EATING:
			return "taking a meal"
		CitizenDefs.State.SICK:
			return "laid up sick"
		CitizenDefs.State.INJURED:
			return "recovering from an injury"
	return "standing about"


## Citizen id standing on a tile, or -1. For click-to-inspect.
func citizen_at_cell(cell: Vector2i) -> int:
	var best: int = -1
	var best_d: float = 1.0
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		var dx: float = pool.px[s] - (float(cell.x) + 0.5)
		var dy: float = pool.py[s] - (float(cell.y) + 0.5)
		var d: float = dx * dx + dy * dy
		if d < best_d:
			best_d = d
			best = pool.ids[s]
	return best


## Every citizen id inside a tile rectangle, ascending.
func citizens_in_cell_rect(rect: Rect2i) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		var x: int = int(pool.px[s])
		var y: int = int(pool.py[s])
		if x >= rect.position.x and x < rect.end.x and y >= rect.position.y and y < rect.end.y:
			out.append(pool.ids[s])
	out.sort()
	return out


## 0..1 fraction of the crew a building actually has on site. This is the number
## that makes an unstaffed building underperform.
func staffing_of(building_id: int) -> float:
	return board.staffing_of(building_id)


## Citizens standing in a building right now.
func workers_at(building_id: int) -> int:
	return board.present_of(building_id)


## Citizens on the roster of a building, present or not.
func assigned_to(building_id: int) -> int:
	return board.assigned_of(building_id)


## Spare hands [P11] can put on a construction site. Awake, adult, unemployed.
func idle_builders() -> int:
	return _idle_builders


func average_morale() -> float:
	return snappedf(pool.average(pool.sum_morale), 0.01)


func average_warmth() -> float:
	return snappedf(pool.average(pool.sum_warmth), 0.01)


func average_health() -> float:
	return snappedf(pool.average(pool.sum_health), 0.01)


## 0..1 share of the city bitter enough to make trouble. [P06] reads this.
func unrest_pressure() -> float:
	var n: int = pool.population()
	if n == 0:
		return 0.0
	return snappedf(clampf(float(pool.count_unrest) / float(n), 0.0, 1.0), 0.001)


func sick_count() -> int:
	return pool.count_sick


func injured_count() -> int:
	return pool.count_injured


func homeless_count() -> int:
	return pool.count_homeless


func employed_count() -> int:
	return pool.count_employed


func dead_total() -> int:
	return _dead_total


## cause -> count, sorted. What actually killed this city.
func death_toll() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = _deaths_by_cause.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = _deaths_by_cause[k]
	return out


## The last `n` obituaries, newest last. [P22] narrative turns these into text.
func recent_deaths(n: int = 8) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var start: int = maxi(0, _obituary.size() - n)
	for i: int in range(start, _obituary.size()):
		out.append((_obituary[i] as Dictionary).duplicate(true))
	return out


## Citizen ids that died on the most recent tick a death happened.
func last_deaths() -> PackedInt32Array:
	return _last_deaths


## Food units the city can still serve, stock plus the founders' larder.
func food_units() -> float:
	var total: float = _larder
	if _stock != null:
		for item: StringName in CitizenDefs.FOOD_ITEMS:
			total += float(_stock.call("stock_count", item))
	return total


## How many days the city eats for at the current population. The single number
## a HUD should put next to the heat gauge.
func food_days_remaining() -> float:
	var n: int = pool.population()
	if n <= 0:
		return 999.0
	# 480 s per day, one meal per HUNGER_MEAL_RELIEF of hunger accrued.
	var meals_per_day: float = float(n) * (CitizenDefs.HUNGER_PER_SEC * 480.0)
	meals_per_day /= maxf(1.0, CitizenDefs.HUNGER_MEAL_RELIEF)
	var per_meal: float = 1.0 / (1.0 + CitizenDefs.KITCHEN_EFFICIENCY * board.kitchen_factor)
	return snappedf(food_units() / maxf(0.001, meals_per_day * per_meal), 0.01)


func shift_law() -> StringName:
	return _shift_law


## [P06] society enacts, we obey. Returns false for a law we do not know.
func set_shift_law(law: StringName) -> bool:
	if not CitizenDefs.SHIFT_LAWS.has(law):
		Log.warn(TAG, "unknown shift law '%s'" % law)
		return false
	if _shift_law == law:
		return true
	_shift_law = law
	Log.info(TAG, "shift law is now %s" % String(CitizenDefs.law_row(law).get("label", law)))
	return true


func set_child_labour(on: bool) -> void:
	_child_labour = on


func set_elder_labour(on: bool) -> void:
	_elder_labour = on


func law_flags() -> Dictionary:
	return {
		"shift_law": String(_shift_law),
		"child_labour": _child_labour,
		"elder_labour": _elder_labour,
	}


## Adds `count` citizens at the gate. Scenarios, tests and [P22] events use it.
func add_citizens(count: int, years: int = -1) -> PackedInt32Array:
	var r: RandomNumberGenerator = Rng.stream(RNG_STREAM)
	var gate: Vector2i = _gate_cell()
	var out := PackedInt32Array()
	var room: int = CitizenDefs.MAX_POPULATION - pool.population()
	for i: int in mini(maxi(0, count), maxi(0, room)):
		var age_years: int = years if years > 0 else 18 + int(r.randi_range(0, 40))
		var slot: int = _spawn(age_years, r)
		pool.set_position(slot, _walkable_near(gate + Vector2i(i % 5, (i / 5) % 5)))
		out.append(pool.ids[slot])
	if not out.is_empty():
		_roster_version += 1
	return out


## Kills a citizen outright with a named cause. [P07] combat and [P22] narrative
## are the intended callers; a wolf in the dark is not a need decaying.
func kill_citizen(id: int, cause: StringName = CitizenDefs.CAUSE_INJURY) -> bool:
	var s: int = pool.slot_of(id)
	if s < 0:
		return false
	pool.health[s] = 0.0
	var idx: int = CitizenPool.CAUSE_INDEX.find(cause)
	pool.death_cause[s] = maxi(0, idx)
	pool.pending_deaths.append(s)
	_bury(_tick)
	pool.drain_pending()
	return true


## Hurts a citizen without killing them. [P07] combat calls this.
func injure_citizen(id: int, severity: float) -> bool:
	var s: int = pool.slot_of(id)
	if s < 0:
		return false
	pool.injury[s] = clampf(maxf(pool.injury[s], severity), 0.0, 100.0)
	pool.health[s] = maxf(0.0, pool.health[s] - severity * CitizenDefs.INJURY_HEALTH_FACTOR)
	_on_injury(s, _tick)
	return true


## Drops food into the city larder. [P03]/[P04] can hand a harvest straight over.
func give_food(units: float) -> void:
	_larder = maxf(0.0, _larder + units)


func larder() -> float:
	return snappedf(_larder, 0.01)


## Everyone on screen, for [P13]'s renderer. Keys match world_model's contract:
## {id, kind, pos}. Ids are offset by CitizenDefs.AGENT_ID_BASE so they can
## never collide with [P07]'s enemies in the renderer's agent table.
func agents_for_view() -> Array[Dictionary]:
	if _view_tick == _tick and _view_version == _roster_version:
		return _view_agents
	var n: int = pool.alive.size()
	if _view_version != _roster_version or _view_agents.size() != n:
		_view_agents = []
		_view_agents.resize(n)
		for i: int in n:
			_view_agents[i] = {"id": 0, "kind": &"citizen", "pos": Vector2.ZERO}
		_view_version = _roster_version
	for i: int in n:
		var s: int = pool.alive[i]
		var d: Dictionary = _view_agents[i]
		d["id"] = CitizenDefs.AGENT_ID_BASE + pool.ids[s]
		d["kind"] = &"worker" if pool.job[s] >= 0 else &"citizen"
		d["pos"] = Vector2(pool.px[s] * TILE, pool.py[s] * TILE)
	_view_tick = _tick
	return _view_agents


## Compact per-citizen rows for [P19]'s overlays: position, condition and the
## one number the lens is colouring by. Sorted by id.
func citizen_overlay_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		out.append({
			"id": pool.ids[s],
			"pos": Vector2(pool.px[s] * TILE, pool.py[s] * TILE),
			"state": int(pool.state[s]),
			"warmth": snappedf(pool.warmth[s] * 0.01, 0.001),
			"morale": snappedf(pool.morale[s] * 0.01, 0.001),
			"health": snappedf(pool.health[s] * 0.01, 0.001),
			"sick": pool.illness[s] >= CitizenDefs.SICK_ONSET,
			"housed": pool.home[s] >= 0,
		})
	return out


## The city in one paragraph, for a HUD panel or a critic reading state.json.
func report() -> Dictionary:
	return {
		"population": pool.population(),
		"employed": pool.count_employed,
		"homeless": pool.count_homeless,
		"sick": pool.count_sick,
		"injured": pool.count_injured,
		"working_now": pool.count_working,
		"asleep_now": pool.count_sleeping,
		"walking_now": pool.count_walking,
		"avg_warmth": average_warmth(),
		"avg_morale": average_morale(),
		"avg_health": average_health(),
		"avg_hunger": snappedf(pool.average(pool.sum_hunger), 0.01),
		"avg_fatigue": snappedf(pool.average(pool.sum_fatigue), 0.01),
		"dead_total": _dead_total,
		"deaths": death_toll(),
		"arrivals": _arrivals_total,
		"food_units": snappedf(food_units(), 0.01),
		"food_days": food_days_remaining(),
		"beds": board.total_beds,
		"jobs": board.total_capacity,
		"jobs_required": board.total_required,
		"care_capacity": board.care_capacity,
		"shift_law": String(_shift_law),
		"unrest": unrest_pressure(),
	}


# =========================================================================
#  commands
# =========================================================================

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"add":
			var ids: PackedInt32Array = add_citizens(int(cmd.get("count", 1)),
				int(cmd.get("age", -1)))
			Log.info(TAG, "spawned %d citizens on command" % ids.size())
		"remove":
			kill_citizen(int(cmd.get("id", -1)),
				StringName(String(cmd.get("cause", CitizenDefs.CAUSE_EXHAUSTION))))
		"set_shift":
			_cmd_set_shift(String(cmd.get("shift", "standard")))
		"set_law":
			var law: StringName = StringName(String(cmd.get("law", "")))
			if law == CitizenDefs.FLAG_CHILD_LABOUR:
				set_child_labour(bool(cmd.get("on", true)))
			elif law == CitizenDefs.FLAG_ELDER_LABOUR:
				set_elder_labour(bool(cmd.get("on", true)))
			else:
				set_shift_law(law)
		"feed":
			give_food(float(cmd.get("amount", 0.0)))
		"set_need":
			_cmd_set_need(cmd)
		"dump":
			_dump()
		_:
			Log.warn(TAG, "unknown command op '%s'" % op)


func _cmd_set_shift(value: String) -> void:
	var name: StringName = StringName(value)
	if CitizenDefs.SHIFT_LAWS.has(name):
		set_shift_law(name)
		return
	var target: int = -1
	if value == "day":
		target = CitizenDefs.Shift.DAY
	elif value == "night":
		target = CitizenDefs.Shift.NIGHT
	if target < 0:
		Log.warn(TAG, "set_shift: '%s' is neither a law nor a rotation" % value)
		return
	var n: int = pool.alive.size()
	for i: int in n:
		var s: int = pool.alive[i]
		if pool.job[s] >= 0:
			pool.shift[s] = target
	Log.info(TAG, "every worker moved to the %s rotation" % value)


func _cmd_set_need(cmd: Dictionary) -> void:
	var s: int = pool.slot_of(int(cmd.get("id", -1)))
	if s < 0:
		Log.warn(TAG, "set_need: no citizen %d" % int(cmd.get("id", -1)))
		return
	var need: String = String(cmd.get("need", ""))
	var value: float = clampf(float(cmd.get("value", 0.0)), 0.0, 100.0)
	match need:
		"health": pool.health[s] = value
		"warmth": pool.warmth[s] = value
		"hunger": pool.hunger[s] = value
		"fatigue": pool.fatigue[s] = value
		"morale": pool.morale[s] = value
		"illness": pool.illness[s] = value
		"injury": pool.injury[s] = value
		_: Log.warn(TAG, "set_need: unknown need '%s'" % need)


func _dump() -> void:
	var r: Dictionary = report()
	Log.info(TAG, "pop %d (%d employed, %d homeless, %d sick) warmth %.0f morale %.0f food %.1f days, %d dead" % [
		int(r["population"]), int(r["employed"]), int(r["homeless"]), int(r["sick"]),
		float(r["avg_warmth"]), float(r["avg_morale"]), float(r["food_days"]), _dead_total])


# =========================================================================
#  persistence + metrics
# =========================================================================

func serialize() -> Dictionary:
	var rows: Array = []
	for id: int in citizen_ids():
		var s: int = pool.slot_of(id)
		if s < 0:
			continue
		rows.append({
			"id": id,
			"name": _name_of(s),
			"age": pool.age[s],
			"trait": int(pool.traits[s]),
			"trade": int(pool.trade[s]),
			"shift": int(pool.shift[s]),
			"state": int(pool.state[s]),
			"job": pool.job[s],
			"home": pool.home[s],
			"dest": pool.dest[s],
			"cell": [int(pool.px[s]), int(pool.py[s])],
			"pos": [snappedf(pool.px[s], 0.001), snappedf(pool.py[s], 0.001)],
			"health": snappedf(pool.health[s], 0.01),
			"warmth": snappedf(pool.warmth[s], 0.01),
			"hunger": snappedf(pool.hunger[s], 0.01),
			"fatigue": snappedf(pool.fatigue[s], 0.01),
			"morale": snappedf(pool.morale[s], 0.01),
			"illness": snappedf(pool.illness[s], 0.01),
			"injury": snappedf(pool.injury[s], 0.01),
			"inside": pool.inside[s] == 1,
		})
	var staffing: Array = []
	for i: int in board.job_ids.size():
		var site: CitizenJobBoard.Site = board.site_of(board.job_ids[i])
		if site == null:
			continue
		staffing.append({
			"building": site.id,
			"kind": String(site.kind),
			"required": site.required,
			"assigned": site.assigned,
			"present": site.present,
			"staffing": snappedf(site.staffing(), 0.001),
			"shelter_c": snappedf(site.shelter_c, 0.01),
		})
	return {
		"citizens": rows,
		"staffing": staffing,
		"totals": report(),
		"obituary": _obituary.duplicate(true),
		"laws": law_flags(),
		"larder": snappedf(_larder, 0.01),
		"meal_debt": snappedf(_meal_debt, 0.001),
		"grief": snappedf(_grief, 0.01),
		"next_id": _next_id,
		"hire_counter": _hire_counter,
		"routes": router.cached_routes(),
	}


func deserialize(data: Dictionary) -> void:
	pool.clear()
	board.recount(pool)
	router.invalidate()
	_next_id = int(data.get("next_id", 1))
	_hire_counter = int(data.get("hire_counter", 0))
	_larder = float(data.get("larder", CitizenDefs.STARTING_LARDER))
	_meal_debt = float(data.get("meal_debt", 0.0))
	_grief = float(data.get("grief", 0.0))
	var laws: Dictionary = data.get("laws", {})
	_shift_law = StringName(String(laws.get("shift_law", CitizenDefs.LAW_STANDARD)))
	_child_labour = bool(laws.get("child_labour", false))
	_elder_labour = bool(laws.get("elder_labour", false))
	var obits: Array = data.get("obituary", [])
	_obituary = []
	for o: Variant in obits:
		if typeof(o) == TYPE_DICTIONARY:
			_obituary.append(o as Dictionary)
	for raw: Variant in data.get("citizens", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = raw
		var id: int = int(d.get("id", 0))
		var slot: int = pool.spawn(id, _first_index(String(d.get("name", ""))),
			_last_index(String(d.get("name", ""))), int(d.get("age", 30)),
			int(d.get("trait", 0)), _tick)
		pool.trade[slot] = int(d.get("trade", 0))
		pool.shift[slot] = int(d.get("shift", CitizenDefs.Shift.OFF))
		pool.state[slot] = int(d.get("state", CitizenDefs.State.IDLE))
		pool.job[slot] = int(d.get("job", -1))
		pool.home[slot] = int(d.get("home", -1))
		pool.dest[slot] = int(d.get("dest", -1))
		pool.health[slot] = float(d.get("health", 100.0))
		pool.warmth[slot] = float(d.get("warmth", 60.0))
		pool.hunger[slot] = float(d.get("hunger", 20.0))
		pool.fatigue[slot] = float(d.get("fatigue", 20.0))
		pool.morale[slot] = float(d.get("morale", 55.0))
		pool.illness[slot] = float(d.get("illness", 0.0))
		pool.injury[slot] = float(d.get("injury", 0.0))
		pool.inside[slot] = 1 if bool(d.get("inside", false)) else 0
		var pos: Array = d.get("pos", [128.0, 128.0])
		if pos.size() >= 2:
			pool.px[slot] = float(pos[0])
			pool.py[slot] = float(pos[1])
			pool.wx[slot] = pool.px[slot]
			pool.wy[slot] = pool.py[slot]
		_next_id = maxi(_next_id, id + 1)
	board.recount(pool)
	pool.tally()
	_roster_version += 1
	Log.info(TAG, "restored %d citizens" % pool.population())


func metrics() -> Dictionary:
	return {
		"population": pool.population(),
		"employed": pool.count_employed,
		"homeless": pool.count_homeless,
		"sick": pool.count_sick,
		"injured": pool.count_injured,
		"working": pool.count_working,
		"asleep": pool.count_sleeping,
		"walking": pool.count_walking,
		"dead_total": _dead_total,
		"arrivals": _arrivals_total,
		"avg_warmth": average_warmth(),
		"avg_morale": average_morale(),
		"avg_health": average_health(),
		"avg_hunger": snappedf(pool.average(pool.sum_hunger), 0.01),
		"avg_fatigue": snappedf(pool.average(pool.sum_fatigue), 0.01),
		"unrest": unrest_pressure(),
		"food_days": food_days_remaining(),
		"staffed": snappedf(_staffed_ratio(), 0.001),
		"routes": router.cached_routes(),
		"step_us": _step_us,
	}


func _staffed_ratio() -> float:
	if board.total_required <= 0:
		return 1.0
	var present: int = 0
	for i: int in board.job_ids.size():
		var site: CitizenJobBoard.Site = board.site_of(board.job_ids[i])
		if site != null and site.operational:
			present += mini(site.present, site.required)
	return clampf(float(present) / float(board.total_required), 0.0, 1.0)


# =========================================================================
#  small internals
# =========================================================================

func _name_of(slot: int) -> String:
	return CitizenDefs.compose_name(pool.first_name[slot], pool.last_name[slot])


## What to call someone. A trade if they hold one; otherwise what they are —
## "child", "pensioner", "labourer". Nobody in this city is "trade 0".
func _trade_index(slot: int) -> int:
	if pool.job[slot] >= 0:
		return pool.trade[slot]
	match CitizenDefs.age_bracket(pool.age[slot]):
		CitizenDefs.Age.CHILD:
			return CitizenDefs.Trade.CHILD
		CitizenDefs.Age.ELDER:
			return CitizenDefs.Trade.ELDER
	return pool.trade[slot]


func _trade_label(slot: int) -> String:
	return CitizenDefs.trade_label(_trade_index(slot))


func _first_index(full: String) -> int:
	var idx: int = CitizenDefs.FIRST_NAMES.find(full.get_slice(" ", 0))
	return maxi(0, idx)


func _last_index(full: String) -> int:
	var idx: int = CitizenDefs.LAST_NAMES.find(full.get_slice(" ", 1))
	return maxi(0, idx)


func _felt_temperature(slot: int) -> float:
	var t: float = _ambient
	if _warmth != null:
		t += _warmth.value_at(pool.cell_of(slot))
	if pool.inside[slot] == 1:
		t += pool.shelter[slot]
	return t


func _citizen_pos(slot: int) -> Vector2:
	return Vector2(pool.px[slot] * TILE, pool.py[slot] * TILE)


func _cell_pos(cell: Vector2i) -> Vector2:
	return Vector2((float(cell.x) + 0.5) * TILE, (float(cell.y) + 0.5) * TILE)


func _shelter_pos() -> Vector2:
	if board.shelter_cell.x >= 0:
		return _cell_pos(board.shelter_cell)
	return _cell_pos(_core_cell())


## One Bus alert per key per cooldown. Severity never exceeds 1: a city in
## trouble is gameplay, and the harness treats 2+ as a broken build.
func _alert(key: StringName, severity: int, text: String, pos: Vector2, tick: int) -> void:
	var last: int = int(_alerts.get(key, -CitizenDefs.ALERT_COOLDOWN_TICKS - 1))
	if tick - last < CitizenDefs.ALERT_COOLDOWN_TICKS:
		return
	_alerts[key] = tick
	Bus.alert_raised.emit(mini(severity, 1), key, text, pos)


## First method a neighbouring system answers to, or "". Parts land at different
## times and none of them should have to know the others' final vocabulary.
static func _find_method(system: Object, names: Array, arg_count: int) -> String:
	if system == null:
		return ""
	for n: String in names:
		if not system.has_method(n):
			continue
		for entry: Dictionary in system.get_method_list():
			if String(entry.get("name", "")) != n:
				continue
			if (entry.get("args", []) as Array).size() == arg_count:
				return n
	return ""

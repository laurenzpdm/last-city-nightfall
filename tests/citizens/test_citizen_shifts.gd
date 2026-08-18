extends TestCase
## [P05] A shift belongs to a BUILDING, not to a hire counter — and no building
## in this city closes at sunset.
##
## Two rules died to get here and this suite is written against BOTH of them.
##
## The first dealt every third hire to nights regardless of where that person
## worked and never re-cut, so `citizens.staffed` never rose above 0.64 at any
## hour and both rubble sorters sat STALLED/`unstaffed` holding a full roster.
##
## The second — the one this suite was rewritten for — read the rotation off the
## building and then gave the WHOLE crew to it, buying a second rotation only out
## of surplus. In a city that is short of hands nothing ever has surplus, so in
## practice every workshop was day-only and every gun night-only. Measured over
## 24000 ticks of `first_night`: `production.active_machines` 3.01 morning and
## 2.44 afternoon against 0.34 / 0.44 / 0.35 through dusk, night and deep night,
## all eight machines ending the run reading `unstaffed`, every belt line at
## throughput 0.0. In a game called Nightfall.
##
## The rule now: **a crew works both rotations, weighted toward the hours its
## building is for, and the shift law says how far it leans.** See
## `CitizenDefs.NIGHT_TRADES` for the decision and `CitizenJobBoard.cut_shifts`
## for the cut.
##
## Every test here goes RED with `skeleton` set to 0.0 on every shift law, which
## is exactly the roster this build shipped with before this wave — and the last
## three go red on the hire counter as well.

## priority 100, needs 2, room for 4 — a workshop that can be crewed deep
const SHOP_ID: int = 910001
## priority 90, needs 2, room for 2 — a workshop that never can
const THIN_ID: int = 910002
## priority 80, needs 1, room for 2 — the wall
const GUN_ID: int = 910003
## priority 70, needs 1, room for 1 — a second gun, added mid-test
const GUN2_ID: int = 910004

var world: SimFixture = null
var cit: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["citizens"])


func setup() -> void:
	world = SimFixture.new(7).start()
	cit = world.system(&"citizens")
	if cit == null or not world.alive():
		skip("the world did not come up in this build")


func teardown() -> void:
	if world != null:
		world.stop()


# =========================================================================
#  a board whose shape is stated here
# =========================================================================

func _board() -> CitizenJobBoard:
	var board := CitizenJobBoard.new()
	_add(board, SHOP_ID, 100, 2, 4, CitizenDefs.Trade.TINSMITH)
	_add(board, THIN_ID, 90, 2, 2, CitizenDefs.Trade.TINSMITH)
	_add(board, GUN_ID, 80, 1, 2, CitizenDefs.Trade.GUNNER)
	board._rebuild_order()
	return board


func _add(board: CitizenJobBoard, id: int, priority: int, required: int,
		capacity: int, trade: int) -> void:
	var s := CitizenJobBoard.Site.new()
	s.id = id
	s.kind = StringName("test_site_%d" % id)
	s.priority = priority
	s.required = required
	s.capacity = capacity
	s.trade = trade
	s.door = Vector2i(10 + id % 10, 10)
	s.center = s.door
	s.cell = s.door
	s.operational = true
	s.needs_door = true
	board.sites[id] = s


func _crew(pool: CitizenPool, n: int) -> PackedInt32Array:
	var slots := PackedInt32Array()
	for i: int in n:
		var s: int = pool.spawn(510000 + i, 0, 0, 30, 0, 0)
		pool.set_position(s, Vector2i(15, 10))
		slots.append(s)
	return slots


## How many of a site's crew sit on each rotation, as [day, night, off].
func _split(board: CitizenJobBoard, pool: CitizenPool, id: int) -> Array[int]:
	var out: Array[int] = [0, 0, 0]
	for i: int in pool.alive.size():
		var s: int = pool.alive[i]
		if pool.job[s] != id:
			continue
		match pool.shift[s]:
			CitizenDefs.Shift.DAY: out[0] += 1
			CitizenDefs.Shift.NIGHT: out[1] += 1
			_: out[2] += 1
	return out


# =========================================================================
#  the rule
# =========================================================================

## The whole change in one measurement. Five people across three buildings whose
## crews come out at 2, 2 and 1 — every one of them exactly the size of its
## requirement, so nothing here has a spare body to give.
##
## The rule this replaces refused to split them, on the grounds that half a crew
## covers neither end of the day properly. That is true, and it is still the
## cheaper of the two mistakes: the city it produced was asleep for the whole
## dark. A pair now posts one hand to the far rotation and works the other end
## thin, and `skeleton_crew` is where the arithmetic lives.
func test_a_crew_at_its_requirement_still_posts_a_hand_to_the_far_rotation() -> void:
	var board: CitizenJobBoard = _board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 5)
	board.assign_jobs(pool, crew, false, true, 12)

	board.cut_shifts(pool, CitizenDefs.LAW_STANDARD)

	for id: int in [SHOP_ID, THIN_ID]:
		var site: CitizenJobBoard.Site = board.sites[id]
		var split: Array[int] = _split(board, pool, id)
		assert_eq(split[0] + split[1], site.assigned,
			"everybody on %s's roster is on some rotation" % String(site.kind))
		assert_ge(float(split[1]), 1.0,
			("%s has %d of its %d on the night rotation — a workshop with nobody in "
			+ "it after dark is the whole reason the factory died at sunset")
			% [String(site.kind), split[1], site.assigned])
		assert_ge(float(split[0]), float(split[1]),
			("%s leans to the hours it exists for: %d by day against %d after dark")
			% [String(site.kind), split[0], split[1]])
	# One body cannot be in two places, and is not asked to be.
	var gun: Array[int] = _split(board, pool, GUN_ID)
	assert_eq(gun[0], 0,
		"the turret's single gunner is not split across two rotations")


## The far rotation is the shift law's, and it runs in BOTH directions from the
## default. Curfew is the old behaviour, kept — as a choice somebody signs.
func test_the_shift_law_is_the_players_lever_over_the_dark() -> void:
	var counts: Dictionary[String, int] = {}
	for law: StringName in [CitizenDefs.LAW_CURFEW, CitizenDefs.LAW_STANDARD,
			CitizenDefs.LAW_EXTENDED]:
		var board: CitizenJobBoard = _board()
		var pool := CitizenPool.new()
		var crew: PackedInt32Array = _crew(pool, 9)
		for _pass: int in 4:
			board.assign_jobs(pool, crew, false, true, 12)
		board.cut_shifts(pool, law)
		counts[String(law)] = _split(board, pool, THIN_ID)[1]

	assert_eq(counts["curfew"], 0,
		("Night Curfew is the one law that means it: the pair on the thin workshop "
		+ "sleeps through the dark, and the works stop at dusk"))
	assert_ge(float(counts["standard"]), 1.0,
		"Standard Shifts posts a hand to the dark without anybody signing anything")
	assert_ge(float(counts["extended"]), float(counts["standard"]),
		"and Extended Shifts never posts fewer")
	assert_eq(CitizenDefs.skeleton_crew(CitizenDefs.LAW_STANDARD, 1), 0,
		"one body is never split, under any law")
	assert_lt(float(CitizenDefs.skeleton_crew(CitizenDefs.LAW_STANDARD, 6)), 6.0,
		"and the primary rotation is never emptied")


## The rotation is read off the building, and the wall's hours are the dark.
## A gunner dealt to days by a counter is a gun that is manned at noon and cold
## at the hour it was built for. Leaning is not the same as closing: the workshop
## still keeps its majority in the light and the gun still keeps its majority
## after dark.
func test_the_wall_is_manned_after_dark_and_the_workshops_in_the_light() -> void:
	var board: CitizenJobBoard = _board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 5)
	board.assign_jobs(pool, crew, false, true, 12)

	board.cut_shifts(pool, CitizenDefs.LAW_STANDARD)

	var gun: Array[int] = _split(board, pool, GUN_ID)
	assert_ge(float(gun[1]), 1.0,
		"the turret's required crew is on the night rotation, not whichever "
		+ "rotation the hire counter happened to be on when they were taken on")
	assert_eq(gun[0], 0, "and its only body is not rostered to noon")
	var thin: Array[int] = _split(board, pool, THIN_ID)
	assert_ge(float(thin[0]), float(thin[1]),
		"a workshop leans to the light: %d by day against %d after dark"
		% [thin[0], thin[1]])
	assert_eq(thin[0] + thin[1], 2, "and its whole roster is on the clock somewhere")


## What `capacity` is FOR, once the rotation reads the building: hire past
## `required` and the crew covers both rotations, so the shop runs round the
## clock. This is the automation player's night shift, and it is the only thing
## that buys one.
func test_depth_buys_the_second_rotation() -> void:
	var board: CitizenJobBoard = _board()
	var pool := CitizenPool.new()
	# Nine people: enough for every requirement (2 + 2 + 1) and then to deepen.
	var crew: PackedInt32Array = _crew(pool, 9)
	for _pass: int in 4:
		board.assign_jobs(pool, crew, false, true, 12)
	board.cut_shifts(pool, CitizenDefs.LAW_STANDARD)

	var shop: CitizenJobBoard.Site = board.sites[SHOP_ID]
	assert_ge(float(shop.assigned), 4.0,
		"precondition: the spare hands deepened the workshop to its capacity")
	var split: Array[int] = _split(board, pool, SHOP_ID)
	assert_ge(float(split[0]), 2.0, "the day rotation still covers the requirement")
	assert_ge(float(split[1]), 2.0,
		"and so does the night one — a crew of four against a need of two runs the "
		+ "building around the clock, which is what hiring past `required` bought")


## A rotation dealt at hire time is worn for life: somebody re-cut onto a new
## crew by `_reassign_surplus` kept their first employer's hours, which is how a
## turret ends up crewed by a day-shift tinsmith. The cut is recomputed from the
## crews as they stand, so the hours follow the job.
func test_the_hours_follow_the_job_when_somebody_is_moved() -> void:
	var board: CitizenJobBoard = _board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 9)
	for _pass: int in 4:
		board.assign_jobs(pool, crew, false, true, 12)
	board.cut_shifts(pool, CitizenDefs.LAW_STANDARD)

	# Somebody on the deep workshop's day rotation.
	var moved: int = -1
	for i: int in pool.alive.size():
		var s: int = pool.alive[i]
		if pool.job[s] == SHOP_ID and pool.shift[s] == CitizenDefs.Shift.DAY:
			moved = s
			break
	if moved < 0:
		skip("no day-rotation worker on the deep crew to move")
		return

	# Walk them across town to a second gun that nobody has ever crewed, so the
	# rotation they end up on can only have come from the building they are
	# standing in now. One body on a night building is never split.
	_add(board, GUN2_ID, 70, 1, 1, CitizenDefs.Trade.GUNNER)
	board._rebuild_order()
	board.sites[SHOP_ID].assigned -= 1
	pool.job[moved] = GUN2_ID
	pool.trade[moved] = CitizenDefs.Trade.GUNNER
	board.sites[GUN2_ID].assigned += 1

	board.cut_shifts(pool, CitizenDefs.LAW_STANDARD)

	assert_eq(pool.shift[moved], CitizenDefs.Shift.NIGHT,
		"they work the wall's hours now, not the workshop's — a rotation handed out "
		+ "once at hire time is worn for life and belongs to the wrong building")


# =========================================================================
#  the consequence, on a live world
# =========================================================================

## Everybody a foreman could put to work today.
func _employable() -> int:
	var pool: CitizenPool = cit.get("pool")
	var n: int = 0
	for i: int in pool.alive.size():
		var s: int = pool.alive[i]
		if CitizenDefs.age_bracket(pool.age[s]) != CitizenDefs.Age.ADULT:
			continue
		if pool.illness[s] >= CitizenDefs.SICK_ONSET or pool.injury[s] >= CitizenDefs.INJURY_CLEAR:
			continue
		n += 1
	return n


func _found(kind: StringName, offset: Vector2i) -> bool:
	var build: SimSystem = world.system(&"build")
	if build == null or not build.has_method("execute"):
		return false
	var grid: SimSystem = world.system(&"grid")
	var core: Vector2i = grid.call("core_cell") if grid != null else Vector2i(128, 128)
	return bool(build.call("execute", {
		"op": "place", "kind": String(kind),
		"cell": [core.x + offset.x, core.y + offset.y],
		"free": true, "instant": true,
	}).get("ok", false))


## Buildings placed whose crew can never cover both rotations. Counted, not
## assumed: without them this suite cannot tell the two rules apart.
var _thin: int = 0


## A small city with more hands than requirements, so that anything left short is
## short because of the rotation and not because the city is poor.
func _found_a_city() -> bool:
	for _tries: int in 12:
		if _employable() >= 24:
			break
		world.cmd_now({"system": &"citizens", "op": "add", "count": 8})
		world.run(20)
	if _employable() < 24:
		return false
	if not _found(&"the_hearth", Vector2i(0, 0)):
		return false
	for h: int in 4:
		_found(&"housing_block", Vector2i(-12, -8 + h * 5))
	var shops: int = 0
	for i: int in 3:
		if _found(&"workshop", Vector2i(8, -9 + i * 4)):
			shops += 1
	# Thin crews are the whole point of the fixture. A workshop with room for
	# eight can be deep enough to cover both rotations honestly, so a city made
	# only of workshops cannot tell the two rules apart. These need one or two
	# people each and can never cover both — which is exactly the shape the hire
	# counter splits down the middle and leaves short at either end.
	_thin = 0
	for spot: Array in [[&"turret_mount", Vector2i(-6, 12)], [&"turret_mount", Vector2i(-3, 12)],
			[&"turret_mount", Vector2i(0, 12)], [&"granary", Vector2i(4, 12)],
			[&"ore_drill", Vector2i(9, 12)]]:
		if _found(spot[0], spot[1]):
			_thin += 1
	world.run(1500)
	return shops >= 2 and _thin >= 3


## The invariant, stated on the real city: **the rotation a building is FOR
## keeps the majority of its crew, and the other rotation is never empty.**
##
## Both halves have teeth and they point in opposite directions. Drop the first
## and you are back to a hire counter, which decides a person's hours from their
## position in the queue and will happily put four of a workshop's seven on
## nights and roster a turret's only gunner to noon. Drop the second and you are
## back to the roster this build shipped: `production.active_machines` 3.01 in
## the morning and 0.35 in deep night, eight machines reading `unstaffed`, the
## whole factory asleep for the hours the game is named after.
##
## Read `CitizenDefs.skeleton_crew` for the arithmetic; this states the shape.
func test_every_crew_leans_to_its_own_hours_and_none_is_dark() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	var board: CitizenJobBoard = cit.get("board")
	var pool: CitizenPool = cit.get("pool")
	world.run(400)

	# Who is on which rotation, per site, from the citizens themselves — never
	# from `site.assigned`, which is a counter and can be a body ahead of the
	# people actually standing on the roster.
	var days: Dictionary[int, int] = {}
	var nights: Dictionary[int, int] = {}
	for i: int in pool.alive.size():
		var s: int = pool.alive[i]
		var j: int = pool.job[s]
		if j < 0 or not board.sites.has(j):
			continue
		if pool.shift[s] == CitizenDefs.Shift.DAY:
			days[j] = int(days.get(j, 0)) + 1
		elif pool.shift[s] == CitizenDefs.Shift.NIGHT:
			nights[j] = int(nights.get(j, 0)) + 1

	var measured: int = 0
	var pairs: int = 0
	var deep: int = 0
	var lopsided: Array[String] = []
	var dark: Array[String] = []
	var shallow: Array[String] = []
	for i: int in board.job_ids.size():
		var id: int = board.job_ids[i]
		var site: CitizenJobBoard.Site = board.sites[id]
		var on_days: int = int(days.get(id, 0))
		var on_nights: int = int(nights.get(id, 0))
		var crew: int = on_days + on_nights
		if not site.operational or crew <= 0:
			continue
		measured += 1
		var night_site: bool = CitizenDefs.is_night_trade(site.trade)
		var on_primary: int = on_nights if night_site else on_days
		var on_far: int = on_days if night_site else on_nights
		var need: int = mini(site.required, site.capacity)
		var hours: String = "nights" if night_site else "days"
		# 1. The building still leans to its own hours: never less than half.
		if on_primary * 2 < crew:
			lopsided.append("%s(%d) works %s and has %d of its %d there"
				% [String(site.kind), id, hours, on_primary, crew])
		# 2. And a crew big enough to cover both really covers both — this is
		#    what hiring past `required` is FOR.
		if need > 0 and crew >= need * 2:
			deep += 1
			if on_far < need or on_primary < need:
				shallow.append("%s(%d) carries %d against a need of %d and still runs %d/%d"
					% [String(site.kind), id, crew, need, on_primary, on_far])
		# 3. The half this suite was rewritten for: a crew big enough to be in
		#    two places is in two places.
		if crew >= CitizenDefs.MIN_CREW_TO_SPLIT:
			pairs += 1
			if on_far <= 0:
				dark.append("%s(%d) puts all %d of its crew on %s"
					% [String(site.kind), id, crew, hours])
	assert_gt(float(measured), 4.0,
		"precondition: the city has crewed buildings to measure (found %d)" % measured)
	assert_gt(float(pairs), 2.0,
		("precondition: some of them carry two or more people (found %d) — "
		+ "without those this measures nothing") % pairs)
	assert_gt(float(deep), 0.0,
		("precondition: at least one crew is deep enough to cover both rotations "
		+ "outright (found %d)") % deep)
	assert_empty(lopsided,
		("%d of %d crewed buildings no longer lean to the rotation they exist "
		+ "for: %s") % [lopsided.size(), measured, ", ".join(lopsided)])
	assert_empty(shallow,
		("%d deep crews fail to cover their requirement on both rotations: %s")
		% [shallow.size(), ", ".join(shallow)])
	assert_empty(dark,
		("%d of %d crews with two or more hands leave the other end of the clock "
		+ "completely empty: %s") % [dark.size(), pairs, ", ".join(dark)])


## The wall and the fires, on the real city and at the hour they exist for.
## A turret needs one person; a hire counter gives that person a two-in-three
## chance of being rostered to noon, which is how a reference run reached
## nightfall with seven of ten turret mounts and five of seven generators
## reading `no crew`.
##
## A single body is never split — one gunner is on the wall, and that is the
## whole of it. A deeper night crew may spare somebody for the daylight, and
## should: the hearth reading `no crew` every morning was the other half of the
## bill the old roster ran up.
func test_the_night_trades_hold_their_requirement_after_dark() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	var board: CitizenJobBoard = cit.get("board")
	var pool: CitizenPool = cit.get("pool")
	world.run(400)

	var sites: int = 0
	var singles: int = 0
	var short: Array[String] = []
	var absent: Array[String] = []
	for i: int in board.job_ids.size():
		var id: int = board.job_ids[i]
		var site: CitizenJobBoard.Site = board.sites[id]
		if not CitizenDefs.is_night_trade(site.trade):
			continue
		var on_nights: int = 0
		var on_days: int = 0
		for k: int in pool.alive.size():
			var s: int = pool.alive[k]
			if pool.job[s] != id:
				continue
			if pool.shift[s] == CitizenDefs.Shift.NIGHT:
				on_nights += 1
			elif pool.shift[s] == CitizenDefs.Shift.DAY:
				on_days += 1
		var crew: int = on_days + on_nights
		if crew <= 0:
			continue
		sites += 1
		if crew < CitizenDefs.MIN_CREW_TO_SPLIT:
			singles += 1
			# One body on the wall is on the wall. It is never rostered to noon.
			if on_nights < 1:
				absent.append("%s(%d) has its only body on days" % [String(site.kind), id])
		if on_nights * 2 < crew:
			short.append("%s(%d) has %d of its %d after dark"
				% [String(site.kind), id, on_nights, crew])
	assert_gt(float(sites), 1.0,
		"precondition: the city has crewed defences and fires to measure (found %d)" % sites)
	assert_gt(float(singles), 0.0,
		"precondition: at least one of them is a single body (found %d)" % singles)
	assert_empty(absent,
		"%d guns and fires stand empty at the hour they exist for: %s"
		% [absent.size(), ", ".join(absent)])
	assert_empty(short,
		("%d of %d night-trade buildings send most of their crew to the daylight: %s")
		% [short.size(), sites, ", ".join(short)])


## Nobody is left holding a rotation that belongs to nothing, and every employed
## citizen is on one. A cut that forgets somebody is a person who never turns up.
func test_every_employed_citizen_is_on_exactly_one_rotation() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	world.run(600)
	var pool: CitizenPool = cit.get("pool")
	var employed: int = 0
	var stray: int = 0
	var idle_on_shift: int = 0
	for i: int in pool.alive.size():
		var s: int = pool.alive[i]
		if pool.job[s] >= 0:
			employed += 1
			if pool.shift[s] == CitizenDefs.Shift.OFF:
				stray += 1
		elif pool.shift[s] != CitizenDefs.Shift.OFF:
			idle_on_shift += 1
	assert_gt(float(employed), 4.0, "precondition: the city employs people")
	assert_eq(stray, 0, "%d employed citizens are on no rotation at all" % stray)
	assert_eq(idle_on_shift, 0,
		"%d citizens with no job are still rostered to a shift" % idle_on_shift)


# =========================================================================
#  the bill
# =========================================================================

## A crew at the bench, ready to be stepped. Working, housed, warm, fed — so the
## only thing that can move a number here is the hour.
func _bench(shift: int) -> CitizenPool:
	var pool := CitizenPool.new()
	for i: int in 8:
		var s: int = pool.spawn(520000 + i, i, i, 30, 0, 0)
		pool.set_position(s, Vector2i(15, 10))
		pool.job[s] = SHOP_ID
		pool.home[s] = SHOP_ID
		pool.shift[s] = shift
		pool.inside[s] = 1
		pool.shelter[s] = 30.0
		pool.hazard[s] = 1
		pool.set_state(s, CitizenDefs.State.WORKING, 0)
	return pool


func _ctx(dark: bool) -> CitizenPool.Ctx:
	var c := CitizenPool.Ctx.new()
	c.dt = 1.0
	c.ambient = -10.0
	c.rng = null
	c.dark = dark
	c.night_fatigue = CitizenDefs.NIGHT_FATIGUE_MULT
	c.night_accident = CitizenDefs.NIGHT_ACCIDENT_MULT
	c.night_morale = CitizenDefs.NIGHT_MORALE_PENALTY
	return c


func _step(pool: CitizenPool, ctx: CitizenPool.Ctx, seconds: int) -> void:
	for _t: int in seconds:
		pool.step_needs(0, 1, ctx)


## Read straight off the bodies. `pool.average` reads a tally another pass keeps,
## and a test that quotes a counter nobody updated is a test that asserts 0 == 0.
func _mean(values: PackedFloat32Array, pool: CitizenPool) -> float:
	var total: float = 0.0
	for i: int in pool.alive.size():
		total += values[pool.alive[i]]
	return total / maxf(1.0, float(pool.alive.size()))


## **The dark is not free, and this is the invoice.**
##
## A factory that runs all night is only a design decision if somebody pays for
## it; otherwise it is a free lunch, and a free lunch in a Frostpunk-shaped game
## is a missing mechanic. The bill is charged in two places and both are measured
## here: an hour at the bench in the dark wears a body harder than the same hour
## at noon, and standing the graveyard rotation costs morale around the clock —
## awake or asleep, because sleeping through the daylight is its own misery.
##
## Goes red the moment `ctx.dark` stops being read, which is the shape a "fix"
## that quietly deletes the cost would take.
func test_the_dark_is_not_free() -> void:
	var day: CitizenPool = _bench(CitizenDefs.Shift.DAY)
	var night: CitizenPool = _bench(CitizenDefs.Shift.NIGHT)
	_step(day, _ctx(false), 120)
	_step(night, _ctx(true), 120)

	var worn_by_day: float = _mean(day.fatigue, day)
	var worn_by_night: float = _mean(night.fatigue, night)
	assert_gt(worn_by_night, worn_by_day,
		("two hours at the same bench: %.1f fatigue by day against %.1f in the "
		+ "dark. A night shift that costs a body nothing is a night shift the "
		+ "player never has to think about") % [worn_by_day, worn_by_night])
	assert_gt(worn_by_night / maxf(worn_by_day, 0.001), 1.05,
		"and the difference is a cost, not a rounding error")

	var glad: float = _mean(day.morale, day)
	var sour: float = _mean(night.morale, night)
	assert_lt(sour, glad,
		("the graveyard rotation is unpopular: %.1f morale against %.1f on days")
		% [sour, glad])


## The same charge, stated where the shift law can reach it: the accident risk a
## hazardous bench carries is higher in the dark. [P05] owns the body; this is
## the number [P06] is buying when it signs Emergency Shift.
func test_the_law_scales_what_the_night_costs() -> void:
	assert_gt(CitizenDefs.NIGHT_FATIGUE_MULT, 1.0, "the dark wears people faster")
	assert_gt(CitizenDefs.NIGHT_ACCIDENT_MULT, 1.0, "and hurts them more often")
	assert_gt(CitizenDefs.NIGHT_MORALE_PENALTY, 0.0, "and they resent it")
	var standard: Dictionary = CitizenDefs.law_row(CitizenDefs.LAW_STANDARD)
	var curfew: Dictionary = CitizenDefs.law_row(CitizenDefs.LAW_CURFEW)
	var emergency: Dictionary = CitizenDefs.law_row(CitizenDefs.LAW_EMERGENCY)
	assert_lt(float(curfew["fatigue"]), float(standard["fatigue"]),
		"a curfew is what the city buys REST with")
	assert_gt(float(curfew["morale"]), float(standard["morale"]),
		"and morale with")
	assert_gt(float(emergency["fatigue"]), float(standard["fatigue"]),
		"and an emergency shift is the other end of the same ladder")
	assert_lt(float(emergency["morale"]), float(standard["morale"]),
		"paid for in the same currency")

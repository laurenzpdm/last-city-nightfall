extends TestCase
## [P05] A shift belongs to a BUILDING, not to a hire counter.
##
## `assign_jobs` was taught to satisfy `required` everywhere before topping up
## `capacity` anywhere, and the rosters came right: at tick 24000 of the
## reference run every site but one carried the crew it needs. The city still
## did not work, because a roster is not a body in a room. `staffing_of` reports
## `present / required`, [P04] stalls a machine outright at `staffing <= 0`, and
## the rotation was still being dealt out one hire at a time — every third
## person to take a job went on nights, wherever they worked, and never came off.
##
## The measured cost of that, over twenty minutes: `citizens.staffed` never rose
## above 0.64 at any hour. Both rubble sorters sat STALLED/`unstaffed` with full
## rosters, the smelter downstream starved on `missing_input: iron_ore`, and
## `production.chain_depth` stuck at 2 against a `chain_depth_max` of 5.
##
## Every test in this file is written to go RED against `pool.shift[s] =
## NIGHT if _hire_counter % 3 == 0 else DAY`. The first four drive
## `CitizenJobBoard.cut_shifts` on a board whose shape is stated in the test,
## because a rule about who works when is best read off a roster you control.
## The last two measure the consequence on a live world.

## priority 100, needs 2, room for 4 — a workshop that can be crewed deep
const SHOP_ID: int = 910001
## priority 90, needs 2, room for 2 — a workshop that never can
const THIN_ID: int = 910002
## priority 80, needs 1, room for 2 — the wall
const GUN_ID: int = 910003

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
## requirement, so no crew can be in two places at once.
##
## Hire-counter rotation: the fifth hire is dealt to nights regardless of where
## they work, so one of the three crews is split and that building is short at
## both ends of the day.
## Per-building rotation: each crew works one rotation, whole.
func test_a_crew_that_cannot_cover_both_rotations_is_not_split_across_them() -> void:
	var board: CitizenJobBoard = _board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 5)
	board.assign_jobs(pool, crew, false, true, 12)

	board.cut_shifts(pool)

	for id: int in [SHOP_ID, THIN_ID, GUN_ID]:
		var site: CitizenJobBoard.Site = board.sites[id]
		var split: Array[int] = _split(board, pool, id)
		assert_eq(split[0] + split[1], site.assigned,
			"everybody on %s's roster is on some rotation" % String(site.kind))
		assert_true(split[0] == 0 or split[1] == 0,
			("%s has %d on days and %d on nights against a requirement of %d — a crew "
			+ "this size cannot cover both, so splitting it leaves the building short "
			+ "at BOTH ends of the day") % [String(site.kind), split[0], split[1],
			site.required])


## The rotation is read off the building, and the wall's hours are the dark.
## A gunner dealt to days by a counter is a gun that is manned at noon and cold
## at the hour it was built for.
func test_the_wall_is_manned_after_dark_and_the_workshops_in_the_light() -> void:
	var board: CitizenJobBoard = _board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 5)
	board.assign_jobs(pool, crew, false, true, 12)

	board.cut_shifts(pool)

	var gun: Array[int] = _split(board, pool, GUN_ID)
	assert_ge(float(gun[1]), 1.0,
		"the turret's required crew is on the night rotation, not whichever "
		+ "rotation the hire counter happened to be on when they were taken on")
	assert_eq(gun[0], 0, "and nobody on that crew is rostered to noon")
	var thin: Array[int] = _split(board, pool, THIN_ID)
	assert_eq(thin[1], 0, "a workshop that cannot cover both works the light")
	assert_eq(thin[0], 2, "at its full requirement")


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
	board.cut_shifts(pool)

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
	board.cut_shifts(pool)

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

	# Walk them across town to the wall, the way a re-cut does.
	board.sites[SHOP_ID].assigned -= 1
	pool.job[moved] = GUN_ID
	pool.trade[moved] = CitizenDefs.Trade.GUNNER
	board.sites[GUN_ID].assigned += 1

	board.cut_shifts(pool)

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


## The invariant, stated on the real city: **the rotation a building is FOR is
## never left below the crew the building needs, while that building has the
## people.** Spare hands may go to the other rotation — that is what buys a
## factory its night shift — but they are spare only after the requirement is
## covered.
##
## A hire counter cannot honour this, because it decides a person's hours from
## their position in the queue and never looks at the building: it will happily
## put four of a workshop's seven on nights and leave the daylight shift below
## the requirement, and it will roster a turret's only gunner to noon.
##
## This is the same sentence as "required before capacity", one level down and
## measured in hours instead of heads.
func test_the_rotation_a_building_is_for_is_never_left_short() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	var board: CitizenJobBoard = cit.get("board")
	var pool: CitizenPool = cit.get("pool")
	world.run(400)

	# Who is on which rotation, per site, from the citizens themselves.
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
	var thin: int = 0
	var short: Array[String] = []
	for i: int in board.job_ids.size():
		var id: int = board.job_ids[i]
		var site: CitizenJobBoard.Site = board.sites[id]
		var need: int = mini(site.required, site.capacity)
		if not site.operational or need <= 0 or site.assigned <= 0:
			continue
		measured += 1
		if site.assigned < need * 2:
			thin += 1
		var night_site: bool = CitizenDefs.is_night_trade(site.trade)
		var on_primary: int = int(nights.get(id, 0)) if night_site else int(days.get(id, 0))
		# A crew smaller than the requirement cannot cover it on any rotation, and
		# the badge saying so is telling the truth.
		var owed: int = mini(need, site.assigned)
		if on_primary < owed:
			short.append("%s(%d) works %s and has %d of %d there (roster %d)"
				% [String(site.kind), id, "nights" if night_site else "days",
				on_primary, owed, site.assigned])
	assert_gt(float(measured), 4.0,
		"precondition: the city has crewed buildings to measure (found %d)" % measured)
	assert_gt(float(thin), 2.0,
		("precondition: some of them cannot cover both rotations (found %d) — "
		+ "without those this measures nothing") % thin)
	assert_empty(short,
		("%d of %d crewed buildings are below their requirement on the rotation "
		+ "they exist for: %s") % [short.size(), measured, ", ".join(short)])


## The wall and the fires, on the real city and at the hour they exist for.
## A turret needs one person; a hire counter gives that person a two-in-three
## chance of being rostered to noon, which is how a reference run reached
## nightfall with seven of ten turret mounts and five of seven generators
## reading `no crew`.
##
## Surplus is allowed to work days — a crew deep enough to cover both rotations
## should — so what is asserted is the requirement, plus the stricter rule for
## the crews that have no surplus to give.
func test_the_night_trades_hold_their_requirement_after_dark() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	var board: CitizenJobBoard = cit.get("board")
	var pool: CitizenPool = cit.get("pool")
	world.run(400)

	var sites: int = 0
	var thin: int = 0
	var short: Array[String] = []
	var daylit: Array[String] = []
	for i: int in board.job_ids.size():
		var id: int = board.job_ids[i]
		var site: CitizenJobBoard.Site = board.sites[id]
		if not CitizenDefs.is_night_trade(site.trade) or site.assigned <= 0:
			continue
		sites += 1
		var need: int = mini(site.required, site.capacity)
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
		if on_nights < mini(need, site.assigned):
			short.append("%s(%d) has %d of %d after dark (roster %d)"
				% [String(site.kind), id, on_nights, mini(need, site.assigned), site.assigned])
		# A crew with nothing to spare has no business anywhere but the dark.
		if site.assigned <= need:
			thin += 1
			if on_days > 0:
				daylit.append("%s(%d) sends %d of its %d to noon"
					% [String(site.kind), id, on_days, site.assigned])
	assert_gt(float(sites), 1.0,
		"precondition: the city has crewed defences and fires to measure (found %d)" % sites)
	assert_gt(float(thin), 0.0,
		"precondition: at least one of them has no surplus to spare (found %d)" % thin)
	assert_empty(short,
		("%d of %d night-trade buildings are below their requirement after dark: %s")
		% [short.size(), sites, ", ".join(short)])
	assert_empty(daylit,
		("%d night-trade buildings with no spare hands still roster somebody to the "
		+ "daylight, so they stand empty at the hour they exist for: %s")
		% [daylit.size(), ", ".join(daylit)])


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

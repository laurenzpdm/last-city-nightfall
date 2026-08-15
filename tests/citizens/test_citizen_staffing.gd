extends TestCase
## [P05] The city has to staff itself.
##
## `required` is how many people a building needs to RUN. `capacity` is how many
## it has room for. A matcher that only ever reads `capacity` gives the front of
## the hiring order the whole labour force, and every building finished after
## that stands dark however much slack the city has — which is precisely what a
## reference run showed at tick 24000: sixty job slots, thirty-nine of them
## required, forty-one employable people, and eight buildings on `assigned: 0`
## including the only smelter in the game.
##
## Every test here is written so that it goes RED against a single greedy
## `while site.assigned < site.capacity` loop. The first two drive the board
## directly with a synthetic crew, because a rule about ordering is best stated
## on an order you control; the last two measure the consequence on a live world.

const A_ID: int = 900001      ## priority 100, needs 4, room for 8 — the Hearth's shape
const B_ID: int = 900002      ## priority 60, needs 3, room for 6 — the smelter's shape
const C_ID: int = 900003      ## priority 45, needs 1, room for 1 — the granary's shape

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


# --- a board with three buildings and nothing else ----------------------------

## A board holding exactly three sites, in the shapes that actually starve:
## one high-priority site with twice the room it needs, and two later ones that
## the greedy loop never reaches.
func _bare_board() -> CitizenJobBoard:
	var board := CitizenJobBoard.new()
	_add_site(board, A_ID, 100, 4, 8, Vector2i(10, 10))
	_add_site(board, B_ID, 60, 3, 6, Vector2i(20, 10))
	_add_site(board, C_ID, 45, 1, 1, Vector2i(30, 10))
	board._rebuild_order()
	return board


func _add_site(board: CitizenJobBoard, id: int, priority: int, required: int,
		capacity: int, door: Vector2i) -> void:
	var s := CitizenJobBoard.Site.new()
	s.id = id
	s.kind = StringName("test_site_%d" % id)
	s.priority = priority
	s.required = required
	s.capacity = capacity
	s.door = door
	s.center = door
	s.cell = door
	s.operational = true
	s.needs_door = true
	board.sites[id] = s


## `n` healthy adults standing on one cell, all jobless. Slots are the pool's
## own, so the arrays the board writes into are the real ones.
func _crew(pool: CitizenPool, n: int) -> PackedInt32Array:
	var slots := PackedInt32Array()
	for i: int in n:
		var s: int = pool.spawn(500000 + i, 0, 0, 30, 0, 0)
		pool.set_position(s, Vector2i(15, 10))
		slots.append(s)
	return slots


func _assigned(board: CitizenJobBoard, id: int) -> int:
	return board.sites[id].assigned


# =========================================================================
#  the rule
# =========================================================================

## The whole change in one measurement. Nine people, eight required slots across
## three buildings, and room for fifteen.
##
## Greedy-to-capacity: the Hearth-shaped site takes 8, the smelter-shaped site
## gets the last 1 of 3, the granary-shaped site gets nothing.
## Required-first: 4 + 3 + 1 covers every requirement, and the ninth person then
## deepens the highest-priority crew.
func test_required_is_satisfied_everywhere_before_capacity_anywhere() -> void:
	var board: CitizenJobBoard = _bare_board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 9)

	var hired: int = board.assign_jobs(pool, crew, false, true, 12)

	assert_eq(hired, 9, "every idle pair of hands is placed")
	assert_ge(float(_assigned(board, A_ID)), 4.0, "the site that needs four has four")
	assert_ge(float(_assigned(board, B_ID)), 3.0,
		"and the site three places down the order still has its three — this is the "
		+ "assertion a greedy fill-to-capacity loop cannot pass")
	assert_ge(float(_assigned(board, C_ID)), 1.0, "and the last building in the city is manned")
	assert_eq(_assigned(board, A_ID), 5,
		"the one spare hand goes to the highest priority crew, but only after the rest run")


## A required slot that opens on a settled map. Nobody is idle — every citizen
## already has a job — so the only way the new building is ever crewed is for
## the board to take somebody back off a crew that is deeper than it needs.
##
## This is the case the reference run was actually stuck in, and it is the one
## a two-pass hire alone does not touch.
func test_a_new_building_is_crewed_out_of_another_crews_surplus() -> void:
	var board: CitizenJobBoard = _bare_board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 9)

	# Put the city in the state the greedy loop leaves it in: A full to capacity,
	# B holding the remainder, C dark. Then take C's need seriously.
	board.sites[C_ID].operational = false
	board.assign_jobs(pool, crew, false, true, 12)
	board.sites[C_ID].operational = true

	assert_eq(_assigned(board, C_ID), 0, "the new building starts with nobody")
	var idle: int = 0
	for i: int in crew.size():
		if pool.job[crew[i]] < 0:
			idle += 1
	assert_eq(idle, 0, "and the city has no idle hands left to give it")

	# No jobless queue at all: the fix has to come from the surplus or not at all.
	var moved: int = board.assign_jobs(pool, PackedInt32Array(), false, true, 12)

	assert_gt(float(moved), 0.0, "somebody is moved")
	assert_eq(_assigned(board, C_ID), 1, "the new building has the one person it needs")
	assert_ge(float(_assigned(board, A_ID)), 4.0, "not taken from a crew that would then fail")
	assert_ge(float(_assigned(board, B_ID)), 3.0, "nor from that one")
	var employed: int = 0
	for i: int in crew.size():
		if pool.job[crew[i]] >= 0:
			employed += 1
	assert_eq(employed, 9, "and nobody is dropped on the floor in the move")


## The reserve is finite and the badge has to keep telling the truth. Four people
## for eight required slots: the board fills what it can, in priority order, and
## does not invent a crew for the rest.
func test_a_city_that_is_simply_short_stays_short() -> void:
	var board: CitizenJobBoard = _bare_board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 4)

	for _pass: int in 6:
		board.assign_jobs(pool, crew, false, true, 12)

	var total: int = _assigned(board, A_ID) + _assigned(board, B_ID) + _assigned(board, C_ID)
	assert_eq(total, 4, "four people fill four slots and no more")
	assert_eq(_assigned(board, A_ID), 4, "priority decides who goes without")
	assert_eq(_assigned(board, B_ID), 0, "")
	assert_eq(_assigned(board, C_ID), 0, "")


## Repeated passes must settle. A required-first pass that hands a worker over
## and a capacity pass that takes them straight back would churn the city
## forever — and churn is not visible in a single-pass test.
func test_the_matching_settles_instead_of_oscillating() -> void:
	var board: CitizenJobBoard = _bare_board()
	var pool := CitizenPool.new()
	var crew: PackedInt32Array = _crew(pool, 9)
	board.assign_jobs(pool, crew, false, true, 12)

	var before: Array[int] = [_assigned(board, A_ID), _assigned(board, B_ID),
		_assigned(board, C_ID)]
	var churn: int = 0
	for _pass: int in 8:
		churn += board.assign_jobs(pool, PackedInt32Array(), false, true, 12)
	var after: Array[int] = [_assigned(board, A_ID), _assigned(board, B_ID),
		_assigned(board, C_ID)]

	assert_eq(churn, 0, "a settled city stops moving people around")
	assert_eq(after, before, "and the crews it settled on stay put")


# =========================================================================
#  the consequence, on a live world
# =========================================================================

## Places one building next to the core, free and finished. Returns true on a
## real placement.
func _found(kind: StringName, offset: Vector2i) -> bool:
	var build: SimSystem = world.system(&"build")
	if build == null or not build.has_method("execute"):
		return false
	var grid: SimSystem = world.system(&"grid")
	var core: Vector2i = grid.call("core_cell") if grid != null else Vector2i(128, 128)
	var result: Dictionary = build.call("execute", {
		"op": "place", "kind": String(kind),
		"cell": [core.x + offset.x, core.y + offset.y],
		"free": true, "instant": true,
	})
	return bool(result.get("ok", false))


## Everybody a foreman could actually put to work today.
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


var _early_capacity: int = 0
var _late_required: int = 0


## The shape of the reference city, compressed: a hearth and a row of workshops
## with together MORE ROOM THAN THE CITY HAS PEOPLE, and then — later, the way a
## player actually builds — three trades that each need a crew.
##
## The sizing is the test. If the early buildings could not absorb the whole
## workforce, a greedy fill-to-capacity loop would happen to leave enough behind
## to staff the late ones and this suite would go green against the bug, which is
## exactly what it did before the workshop row was sized off the population. So
## the row is grown until its capacity covers every employable adult, and the
## precondition is asserted, not hoped for.
##
## Founded in two stages, because that is the situation the reference run was
## frozen in: by the time the city wants a smelter, every pair of hands is
## already spoken for and only a re-cut can crew it.
func _found_a_city() -> bool:
	# Bounded: a fixture that will not grow a workforce is a broken fixture, not
	# a reason to spin.
	for _tries: int in 12:
		if _employable() >= 20:
			break
		world.cmd_now({"system": &"citizens", "op": "add", "count": 6})
		world.run(20)
	if _employable() < 20:
		return false

	if not _found(&"the_hearth", Vector2i(0, 0)):
		return false
	_early_capacity = 8
	for h: int in 4:
		_found(&"housing_block", Vector2i(-12, -8 + h * 5))
	# One workshop per eight employable adults, so the front of the hiring order
	# has room for the entire city and a greedy loop keeps all of it.
	var shops: int = 0
	while _early_capacity < _employable() and shops < 6:
		if not _found(&"workshop", Vector2i(8, -9 + shops * 4)):
			break
		_early_capacity += 8
		shops += 1
	if shops < 2:
		return false
	world.run(1200)

	_late_required = 0
	for spot: Array in [[&"smelter", Vector2i(-6, 10), 3], [&"survey_hall", Vector2i(-1, 10), 3],
			[&"granary", Vector2i(4, 10), 1]]:
		if _found(spot[0], spot[1]):
			_late_required += int(spot[2])
	world.run(1200)
	return _late_required >= 4


## The invariant, stated on the real city: no building may sit below the crew it
## needs while some other building is carrying more people than IT needs. That is
## the sentence "the city will not staff itself" turned into an assertion, and it
## is what was false at tick 24000.
func test_no_building_starves_while_another_is_overstaffed() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	var board: CitizenJobBoard = cit.get("board")
	# Preconditions, asserted rather than assumed. A suite that measures a
	# matching on a city with no jobs in it measures nothing at all and passes;
	# so does one whose city has labour to spare, because then even a greedy loop
	# staffs everything by accident.
	assert_gt(float(board.job_ids.size()), 3.0, "the city built job sites to measure")
	assert_gt(float(board.total_required), 8.0, "and enough of them need crews to fight over")
	assert_ge(float(_early_capacity), float(_employable()),
		"the front of the hiring order has room for every last person in the city, "
		+ "so filling it to capacity leaves the rest of the city nothing")
	assert_ge(float(_employable()), float(board.total_required),
		"and the city nevertheless has the hands to cover every requirement")

	var short: Array[String] = []
	var surplus: int = 0
	for i: int in board.job_ids.size():
		var s: CitizenJobBoard.Site = board.sites[board.job_ids[i]]
		if not s.operational:
			continue
		var need: int = mini(s.required, s.capacity)
		if s.assigned < need:
			short.append("%s(%d) has %d of %d" % [String(s.kind), s.id, s.assigned, need])
		elif s.assigned > need:
			surplus += s.assigned - need
	assert_true(short.is_empty() or surplus == 0,
		"%d building(s) short — %s — while %d worker(s) sit on crews that do not need them"
		% [short.size(), ", ".join(short), surplus])


## The same rule from the other side, and the one a player reads off the HUD:
## while the city has more capacity than it has requirements AND enough people to
## cover the requirements, nothing should be showing `no crew`.
func test_nothing_reports_no_crew_while_the_city_has_the_hands() -> void:
	if not _found_a_city():
		skip("[P11] would not place a city in this build")
		return
	var board: CitizenJobBoard = cit.get("board")
	var employed: int = 0
	var n: int = cit.get("pool").alive.size()
	var pool: CitizenPool = cit.get("pool")
	for i: int in n:
		if pool.job[pool.alive[i]] >= 0:
			employed += 1
	assert_gt(float(board.total_required), 0.0, "the city has required slots to fill")
	assert_ge(float(_early_capacity), float(_employable()),
		"the front of the hiring order has room for every last person in the city")
	assert_ge(float(employed), float(board.total_required),
		"precondition: this city employs enough people to cover every required slot "
		+ "(if it does not, the badge is honest and this rule does not apply)")
	var dark: Array[String] = []
	for i: int in board.job_ids.size():
		var s: CitizenJobBoard.Site = board.sites[board.job_ids[i]]
		if s.operational and s.required > 0 and s.assigned == 0:
			dark.append("%s(%d)" % [String(s.kind), s.id])
	assert_empty(dark,
		"%d employed for %d required slots, and these have nobody at all: %s"
		% [employed, board.total_required, ", ".join(dark)])

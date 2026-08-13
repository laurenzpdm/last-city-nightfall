extends TestCase
## [P03] Logistics.
##
## Every test here states a rule a player can feel and then measures it on a
## live world. The throughput cases in particular are written against the
## NUMBER ON THE TOOLTIP: a slat belt claims fifteen items a second, so a slat
## belt has to deliver fifteen items a second into a chest, measured over ten
## in-world seconds, with no allowance for "about".
##
## Entities are placed through the logistics command surface, so [P11] is not
## involved and each case owns exactly the layout it describes.

const O: Vector2i = Vector2i(40, 40)   ## empty ground, far from the world generator

var world: SimFixture = null
var logi: LogisticsSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["logistics"])


func setup() -> void:
	world = SimFixture.new(7).start()
	logi = world.system(&"logistics") as LogisticsSystem
	_open_the_tech_tree()


## Belt tiers are research-gated, which is a real rule with its own test below.
## Every other case here is about transport, so the gates are opened first.
func _open_the_tech_tree() -> void:
	if world.system(&"build") == null:
		return
	world.cmd({"system": &"build", "op": "grant_unlock", "unlock": "belt_gearing"})
	world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": "driven_rollers"})


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _place(kind: String, cell: Vector2i, rot: int = 0) -> int:
	var r: Dictionary = logi.place(StringName(kind), cell, rot, true)
	return int(r.get("id", -1)) if bool(r.get("ok", false)) else -1


func _line(kind: String, from: Vector2i, to: Vector2i) -> void:
	world.cmd_now({"system": &"logistics", "op": "place_line", "kind": kind,
		"from": [from.x, from.y], "to": [to.x, to.y], "free": true})


## Fills the back of a line as hard as physics allows, every tick, for `ticks`.
## This is the only honest way to measure a belt: a source that never runs out
## and never inserts an item the belt would not have accepted.
func _run_saturated(entry: Vector2i, ticks: int, kind: String = "coal") -> void:
	for _i: int in ticks:
		for lane: int in 2:
			var guard: int = 0
			while logi.world.push_onto_belt(entry, lane, StringName(kind)) and guard < 8:
				guard += 1
		world.run(1)


func _store_at(cell: Vector2i) -> LogiStore:
	var id: int = int(logi.world.store_cells.get(cell, -1))
	return logi.world.stores.get(id) if id >= 0 else null


func _segment(cell: Vector2i) -> LogiSegment:
	return logi.segment_at(cell)


# =========================================================================
# the lane — the data structure everything else stands on
# =========================================================================

## Fills a lane the only way a belt can be filled: run it, then offer an item,
## over and over. Returns how many got on.
func _fill_lane(lane: LogiLane, kind: int = 1, slack: float = 0.25, ticks: int = 400) -> int:
	var put: int = 0
	for _i: int in ticks:
		lane.advance(slack)
		if lane.insert_back(kind, slack):
			put += 1
	return put


func test_a_lane_holds_four_items_per_tile_and_never_overlaps() -> void:
	var lane := LogiLane.new(10.0)
	assert_eq(lane.capacity(), 41, "ten tiles at four per tile, plus the one on the exit line")
	assert_eq(_fill_lane(lane), 41, "and it accepts exactly that many")
	assert_empty(lane.debug_invariants(), "with every item its own width apart")


func test_a_compressed_lane_is_a_single_group() -> void:
	# The whole performance claim of this part: ten thousand items on a full belt
	# cost one subtraction per tick, because they are one group.
	var lane := LogiLane.new(64.0)
	_fill_lane(lane, 1, 0.25, 2000)
	assert_eq(lane.size(), lane.capacity(), "the lane is full")
	assert_eq(lane.group_count(), 1, "a compressed lane is one group")
	lane.advance(0.1)
	assert_eq(lane.group_count(), 1, "and stays one when it moves")
	assert_near(lane.front_pos(), 0.0, 0.0001, "the head sits on the exit and waits there")


func test_a_lane_keeps_its_order() -> void:
	var lane := LogiLane.new(6.0)
	for i: int in 12:
		lane.advance(0.25)
		assert_true(lane.insert_back(i, 0.25), "item %d fits" % i)
	for i: int in 12:
		lane.advance(10.0)
		assert_eq(lane.take_front(), i, "items leave in the order they arrived")


func test_taking_from_the_middle_splits_the_group_cleanly() -> void:
	var lane := LogiLane.new(4.0)
	for i: int in 9:
		lane.advance(0.25)
		lane.insert_back(i, 0.25)
	lane.advance(10.0)   # let them all pile up against the exit
	assert_eq(lane.size(), 9, "nine items on the lane")
	assert_eq(lane.group_count(), 1, "one compressed group to start with")
	assert_eq(lane.remove_at(4), 4, "the fifth item comes off")
	assert_eq(lane.group_count(), 2, "leaving a hole, which is two groups")
	assert_eq(lane.size(), 8, "and eight items")
	assert_empty(lane.debug_invariants(), "with the invariants intact")
	lane.advance(10.0)
	assert_eq(lane.group_count(), 1, "the hole closes when the lane runs")


func test_an_item_cannot_be_dropped_on_top_of_another() -> void:
	var lane := LogiLane.new(4.0)
	assert_true(lane.insert_at(1, 2.0), "the first drop lands")
	assert_false(lane.insert_at(2, 2.1), "a second one on the same spot is refused")
	assert_false(lane.insert_at(2, 1.9), "and so is one a hair in front")
	assert_true(lane.insert_at(2, 2.25), "exactly one spacing away is fine")
	assert_empty(lane.debug_invariants())


func test_a_lane_only_accepts_through_the_stretch_that_moved() -> void:
	# The entry rule, which is where belt throughput is actually decided: an item
	# may only come in through the stretch of belt that passed the entrance this
	# tick. Without it an empty belt would swallow a whole burst at once and
	# report a number no belt could sustain.
	var lane := LogiLane.new(40.0)
	assert_true(lane.insert_back(1, 0.09375), "the first item enters at the very back")
	assert_false(lane.insert_back(1, 0.09375), "a second cannot: nothing has moved yet")

	# A slat belt runs 0.09375 tiles a tick and items are 0.25 apart, so the
	# entrance can admit 0.375 items a tick — 7.5 a second on one lane, which is
	# exactly half of the fifteen a second on the tooltip.
	var put: int = 1
	for _i: int in 400:
		lane.advance(0.09375)
		if lane.insert_back(1, 0.09375):
			put += 1
	assert_near(float(put) / 20.0, 7.5, 0.2,
		"one lane admits 7.5 items a second (%d in twenty)" % put)


# =========================================================================
# throughput — the numbers on the tooltips
# =========================================================================

func test_belt_tiers_carry_fifteen_thirty_and_forty_five_items_a_second() -> void:
	var expected: Dictionary = {"belt_mk1": 15.0, "belt_mk2": 30.0, "belt_mk3": 45.0}
	var kinds: Array = expected.keys()
	kinds.sort()
	for kind: String in kinds:
		world.restart()
		logi = world.system(&"logistics") as LogisticsSystem
		_open_the_tech_tree()
		var entry: Vector2i = O
		_line(kind, entry, O + Vector2i(11, 0))
		var chest: int = _place("bunker_chest", O + Vector2i(12, 0))
		assert_gt(float(chest), 0.0, "%s: the chest at the end exists" % kind)
		# Fill first, and for longer than the line takes to cross: measuring
		# through the ramp-up would have quietly reported thirteen a second for a
		# belt that was carrying fifteen the whole time.
		_run_saturated(entry, 300)
		var store: LogiStore = logi.world.stores[chest]
		var before: int = store.total()
		_run_saturated(entry, 200)          # then measure ten seconds
		var rate: float = float(store.total() - before) / 10.0
		var want: float = float(expected[kind])
		assert_near(rate, want, want * 0.05,
			"%s delivers %.1f items/s, its tooltip promises %.1f" % [kind, rate, want])


func test_a_belt_with_nowhere_to_go_fills_up_and_holds_everything() -> void:
	_line("belt_mk1", O, O + Vector2i(9, 0))
	_run_saturated(O, 300)
	var seg: LogiSegment = _segment(O)
	assert_not_null(seg, "the line exists")
	assert_eq(seg.item_count(), seg.capacity_items(), "a blocked belt fills to the brim")
	assert_near(logi.saturation_of(O + Vector2i(4, 0)), 1.0, 0.001,
		"and every tile of it reads as full")
	assert_true(seg.is_backed_up(), "which is exactly what 'backed up' has to mean")
	assert_eq(logi.metrics()["backed_up_belts"], 1, "and the metric says so")


func test_a_belt_drained_slower_than_it_is_fed_backs_up_to_the_source() -> void:
	_line("belt_mk1", O, O + Vector2i(7, 0))
	var chest: int = _place("crate", O + Vector2i(9, 0))
	assert_gt(float(_place("inserter_mk1", O + Vector2i(8, 0), 0)), 0.0, "an arm at the end")
	_run_saturated(O, 400)
	var seg: LogiSegment = _segment(O)
	assert_gt(seg.saturation(), 0.9, "a 0.83/s arm cannot drain a 15/s belt")
	assert_gt(float(logi.world.stores[chest].total()), 5.0, "but it does keep moving things")
	assert_false(logi.world.push_onto_belt(O, 0, &"coal"),
		"and the back-pressure reaches all the way to whoever is feeding it")


func test_throughput_and_saturation_answer_for_the_lens() -> void:
	_line("belt_mk1", O, O + Vector2i(9, 0))
	_place("bunker_chest", O + Vector2i(10, 0))
	_run_saturated(O, 300)
	assert_between(logi.throughput_of(O + Vector2i(5, 0)), 13.0, 17.0,
		"[P19] reads items/s off a belt tile")
	assert_between(logi.saturation_of(O + Vector2i(5, 0)), 0.9, 1.0, "and how loaded it is")
	assert_eq(logi.throughput_of(O + Vector2i(0, 40)), 0.0, "empty ground carries nothing")
	assert_eq(logi.saturation_of(O + Vector2i(0, 40)), 0.0, "and is not saturated")


# =========================================================================
# topology
# =========================================================================

func test_a_corner_is_two_lines_and_carries_both_lanes_round_it() -> void:
	_line("belt_mk1", O, O + Vector2i(6, 6))          # one drag: east, then south
	var chest: int = _place("bunker_chest", O + Vector2i(6, 7))
	assert_ne(_segment(O).id, _segment(O + Vector2i(6, 3)).id,
		"a corner splits the transport line, because the two lanes travel different distances")
	assert_eq(_segment(O).sink, LogiTypes.Sink.BELT,
		"but a corner is a hand-over, not a side-load: both lanes go round")
	_run_saturated(O, 300)                     # cross the whole L first
	var store: LogiStore = logi.world.stores[chest]
	var before: int = store.total()
	_run_saturated(O, 200)
	assert_gt(float(store.total()), 200.0, "and the items go round the corner")
	assert_between(float(store.total() - before) / 10.0, 14.0, 16.0,
		"at the full fifteen a second, because nothing is lost to the bend")


func test_side_loading_merges_onto_the_near_lane_only() -> void:
	_line("belt_mk1", O, O + Vector2i(9, 0))            # the main line, running east
	_line("belt_mk1", O + Vector2i(4, 3), O + Vector2i(4, 1))  # a spur coming up from the south
	# The main line is fed in-line from behind (a geared belt, so it stays its own
	# line), which makes the spur a side-load rather than a corner: it has to
	# squeeze onto the near lane.
	_place("belt_mk2", O + Vector2i(-1, 0), 0)
	world.run(1)
	var main: LogiSegment = _segment(O + Vector2i(4, 0))
	var spur: LogiSegment = _segment(O + Vector2i(4, 3))
	assert_ne(main.id, spur.id, "the spur is its own line")
	assert_eq(spur.sink, LogiTypes.Sink.SIDE, "and it side-loads into the main one")
	# South of an eastbound belt is its right-hand side.
	assert_eq(spur.sink_lane, LogiTypes.LANE_RIGHT, "onto the near lane, which is the right one")
	for _i: int in 200:
		logi.world.push_onto_belt(O + Vector2i(4, 3), 0, &"scrap")
		logi.world.push_onto_belt(O + Vector2i(4, 3), 1, &"scrap")
		world.run(1)
	assert_gt(float(main.lanes[LogiTypes.LANE_RIGHT].size()), 0.0, "items land on the right lane")
	assert_eq(main.lanes[LogiTypes.LANE_LEFT].size(), 0,
		"and never on the far one — side-loading compresses two lanes into one")


func test_two_belts_nose_to_nose_deliver_nothing() -> void:
	_line("belt_mk1", O, O + Vector2i(4, 0))
	_place("belt_mk1", O + Vector2i(5, 0), 2)
	assert_eq(_segment(O).sink, LogiTypes.Sink.NONE,
		"a belt facing back at you is a wall, and it is meant to look like one")
	_run_saturated(O, 100)
	assert_eq(_segment(O + Vector2i(5, 0)).item_count(), 0, "nothing crosses")


# =========================================================================
# undergrounds
# =========================================================================

func test_an_underground_pair_carries_items_under_the_line_it_crosses() -> void:
	_line("belt_mk1", O, O + Vector2i(3, 0))
	_place("underground_mk1", O + Vector2i(4, 0), 0)
	_place("underground_mk1", O + Vector2i(8, 0), 0)
	# Somebody else's belt runs straight across the gap.
	_line("belt_mk1", O + Vector2i(6, -2), O + Vector2i(6, 2))
	_line("belt_mk1", O + Vector2i(9, 0), O + Vector2i(11, 0))
	var chest: int = _place("crate", O + Vector2i(12, 0))
	var tunnel: LogiSegment = _segment(O + Vector2i(4, 0))
	assert_not_null(tunnel, "the pair forms a line")
	assert_true(tunnel.is_tunnel, "and knows it is a tunnel")
	assert_near(tunnel.length, 5.0, 0.001, "five tiles long, entrance to exit")
	_run_saturated(O, 400)
	assert_gt(float(logi.world.stores[chest].total()), 100.0,
		"and the items come out the far side of somebody else's belt")


func test_an_underground_refuses_to_pair_beyond_its_span() -> void:
	_place("underground_mk1", O + Vector2i(0, 0), 0)
	_place("underground_mk1", O + Vector2i(6, 0), 0)   # mk1 spans five
	var far: LogiEntity = logi.entity_at(O + Vector2i(6, 0))
	assert_eq(far.pair_id, -1, "six tiles is one too many for a sunken belt")
	assert_true(far.is_entrance, "so it stands there as an unpaired mouth")

	_place("underground_mk3", O + Vector2i(0, 4), 0)
	_place("underground_mk3", O + Vector2i(9, 4), 0)   # mk3 spans nine
	var deep: LogiEntity = logi.entity_at(O + Vector2i(9, 4))
	assert_ne(deep.pair_id, -1, "the deep version reaches nine, which is what it is for")


func test_a_tunnel_costs_the_time_it_saves() -> void:
	# An underground is not a teleport: crossing it takes as long as walking the
	# tiles it skips, which is why a long tunnel is a real decision.
	_place("underground_mk1", O, 0)
	_place("underground_mk1", O + Vector2i(5, 0), 0)
	var chest: int = _place("crate", O + Vector2i(6, 0))
	world.run(1)                      # the layout has to exist before it can carry
	assert_true(logi.world.push_onto_belt(O, 0, &"coal"), "one item goes in")
	var arrived: int = -1
	for t: int in 200:
		world.run(1)
		if logi.world.stores[chest].total() > 0:
			arrived = t
			break
	assert_gt(float(arrived), 0.0, "the item does come out")
	# Six tiles at 1.875 tiles/s is 3.2 s, which is 64 ticks.
	assert_between(float(arrived), 55.0, 75.0,
		"and it took the time six tiles of belt would have taken (%d ticks)" % arrived)


# =========================================================================
# splitters
# =========================================================================

func test_a_splitter_splits_evenly() -> void:
	_line("belt_mk1", O, O + Vector2i(3, 0))
	_place("splitter_mk1", O + Vector2i(4, -1), 0)     # covers (4,-1) and (4,0)
	_line("belt_mk1", O + Vector2i(5, -1), O + Vector2i(7, -1))
	_line("belt_mk1", O + Vector2i(5, 0), O + Vector2i(7, 0))
	var left: int = _place("bunker_chest", O + Vector2i(8, -1))
	var right: int = _place("bunker_chest", O + Vector2i(8, 0))
	_run_saturated(O, 500)
	var a: int = logi.world.stores[left].total()
	var b: int = logi.world.stores[right].total()
	assert_gt(float(a + b), 200.0, "the splitter passed a real volume")
	assert_near(float(a), float(b), float(a + b) * 0.05,
		"and split it evenly: %d left, %d right" % [a, b])


func test_output_priority_fills_one_side_first() -> void:
	_line("belt_mk1", O, O + Vector2i(3, 0))
	var sp: int = _place("splitter_mk1", O + Vector2i(4, -1), 0)
	_line("belt_mk1", O + Vector2i(5, -1), O + Vector2i(7, -1))
	_line("belt_mk1", O + Vector2i(5, 0), O + Vector2i(7, 0))
	var left: int = _place("bunker_chest", O + Vector2i(8, -1))
	var right: int = _place("bunker_chest", O + Vector2i(8, 0))
	world.cmd_now({"system": &"logistics", "op": "set_priority", "id": sp, "output": "left"})
	# Feed one lane only, so the splitter has less than one full belt to give:
	# with priority set, all of it must go one way.
	for _i: int in 400:
		var guard: int = 0
		while logi.world.push_onto_belt(O, 0, &"coal") and guard < 4:
			guard += 1
		world.run(1)
	var a: int = logi.world.stores[left].total()
	var b: int = logi.world.stores[right].total()
	assert_gt(float(a), 50.0, "the priority side got the goods")
	assert_lt(float(b), float(a) * 0.05, "and the other side got almost nothing (%d vs %d)" % [b, a])


func test_a_filter_pulls_one_item_off_a_mixed_line() -> void:
	_line("belt_mk1", O, O + Vector2i(3, 0))
	var sp: int = _place("splitter_mk1", O + Vector2i(4, -1), 0)
	_line("belt_mk1", O + Vector2i(5, -1), O + Vector2i(7, -1))
	_line("belt_mk1", O + Vector2i(5, 0), O + Vector2i(7, 0))
	var left: int = _place("bunker_chest", O + Vector2i(8, -1))
	var right: int = _place("bunker_chest", O + Vector2i(8, 0))
	world.cmd_now({"system": &"logistics", "op": "set_filter", "id": sp,
		"item": "iron_ore", "side": LogiSplitter.Side.LEFT})
	# Strictly alternating: the counter only moves when an item actually got on,
	# so the mixed line really is half and half.
	var n: int = 0
	for _i: int in 500:
		for lane: int in 2:
			var guard: int = 0
			while guard < 4:
				var kind: StringName = &"iron_ore" if n % 2 == 0 else &"coal"
				if not logi.world.push_onto_belt(O, lane, kind):
					break
				n += 1
				guard += 1
		world.run(1)
	assert_gt(float(n), 200.0, "a real mixed load went down the line")
	var a: LogiStore = logi.world.stores[left]
	var b: LogiStore = logi.world.stores[right]
	assert_gt(float(a.count(&"iron_ore")), 50.0, "the ore all went left")
	assert_eq(a.count(&"coal"), 0, "and no coal followed it")
	assert_gt(float(b.count(&"coal")), 50.0, "the coal all went right")
	assert_eq(b.count(&"iron_ore"), 0, "and no ore followed it")


func test_a_splitter_keeps_the_lanes_apart() -> void:
	_line("belt_mk1", O, O + Vector2i(3, 0))
	_place("splitter_mk1", O + Vector2i(4, -1), 0)
	_line("belt_mk1", O + Vector2i(5, -1), O + Vector2i(7, -1))
	_line("belt_mk1", O + Vector2i(5, 0), O + Vector2i(7, 0))
	for _i: int in 200:
		logi.world.push_onto_belt(O, LogiTypes.LANE_LEFT, &"coal")
		world.run(1)
	var out_a: LogiSegment = _segment(O + Vector2i(5, -1))
	var out_b: LogiSegment = _segment(O + Vector2i(5, 0))
	assert_gt(float(out_a.lanes[LogiTypes.LANE_LEFT].size() + out_b.lanes[LogiTypes.LANE_LEFT].size()),
		0.0, "a left-lane feed comes out on left lanes")
	assert_eq(out_a.lanes[LogiTypes.LANE_RIGHT].size() + out_b.lanes[LogiTypes.LANE_RIGHT].size(), 0,
		"and never crosses to a right lane — a sorted belt stays sorted")


# =========================================================================
# arms
# =========================================================================

func test_an_arm_moves_at_its_rated_speed() -> void:
	var source: int = _place("bunker_chest", O)
	var target: int = _place("bunker_chest", O + Vector2i(2, 0))
	assert_gt(float(_place("inserter_mk1", O + Vector2i(1, 0), 0)), 0.0, "the arm is placed")
	logi.world.stores[source].insert(&"iron_plate", 1000)
	world.run(400)                                    # twenty seconds
	var moved: int = logi.world.stores[target].total()
	assert_near(float(moved) / 20.0, 0.83, 0.09,
		"a loading arm swings 0.83 times a second, and moved %d in twenty" % moved)


func test_a_stack_arm_is_worth_six_loading_arms() -> void:
	var source: int = _place("bunker_chest", O)
	var target: int = _place("bunker_chest", O + Vector2i(2, 0))
	_place("inserter_mk3", O + Vector2i(1, 0), 0)
	logi.world.stores[source].insert(&"iron_plate", 1000)
	world.run(400)
	var moved: int = logi.world.stores[target].total()
	assert_near(float(moved) / 20.0, 6.93, 0.7,
		"three at a time, 2.31 times a second: %d items in twenty seconds" % moved)


func test_an_arm_holding_a_full_hand_waits_instead_of_losing_it() -> void:
	var source: int = _place("bunker_chest", O)
	var target: int = _place("crate", O + Vector2i(2, 0))
	var arm: int = _place("inserter_mk1", O + Vector2i(1, 0), 0)
	logi.world.stores[source].insert(&"iron_plate", 1000)
	logi.world.stores[target].insert(&"stone", 400)     # a crate holds 400: it is full
	world.run(200)
	var a: LogiInserter = logi.world.entities[arm]
	assert_true(a.is_holding(), "the arm grabbed a hand and is standing there with it")
	assert_eq(logi.world.stores[target].count(&"iron_plate"), 0, "nothing went into the full crate")
	var total: int = logi.world.stores[source].count(&"iron_plate") + a.held
	assert_eq(total, 1000, "and not one plate went missing while it waited")


func test_an_arm_loads_a_belt_from_a_chest_and_unloads_it_again() -> void:
	var source: int = _place("bunker_chest", O)
	_place("inserter_mk2", O + Vector2i(1, 0), 0)
	_line("belt_mk1", O + Vector2i(2, 0), O + Vector2i(6, 0))
	_place("inserter_mk2", O + Vector2i(7, 0), 0)
	var target: int = _place("bunker_chest", O + Vector2i(8, 0))
	logi.world.stores[source].insert(&"circuit", 500)
	world.run(600)
	assert_gt(float(logi.world.stores[target].total()), 30.0,
		"chest, arm, belt, arm, chest — the shortest complete factory there is")
	var in_hands: int = 0
	for id: int in logi.world.inserter_ids:
		in_hands += (logi.world.entities[id] as LogiInserter).held
	assert_eq(logi.world.stores[source].count(&"circuit") + logi.world.stores[target].total()
		+ _segment(O + Vector2i(2, 0)).item_count() + in_hands, 500,
		"and every circuit is either in a chest, on the belt, or in an arm's hand")


func test_a_filtered_arm_only_takes_what_it_was_told_to() -> void:
	var source: int = _place("bunker_chest", O)
	var target: int = _place("bunker_chest", O + Vector2i(2, 0))
	var arm: int = _place("inserter_mk2", O + Vector2i(1, 0), 0)
	logi.world.stores[source].insert(&"coal", 200)
	logi.world.stores[source].insert(&"iron_plate", 200)
	world.cmd_now({"system": &"logistics", "op": "set_filter", "id": arm, "item": "coal"})
	world.run(400)
	var t: LogiStore = logi.world.stores[target]
	assert_gt(float(t.count(&"coal")), 20.0, "it moved the coal")
	assert_eq(t.count(&"iron_plate"), 0, "and left the plate alone")


# =========================================================================
# storage and the request layer
# =========================================================================

func test_a_chest_respects_its_capacity_and_its_filter() -> void:
	var id: int = _place("crate", O)
	var st: LogiStore = logi.world.stores[id]
	assert_eq(st.insert(&"coal", 1000), 400, "a crate takes four hundred things and no more")
	assert_eq(st.insert(&"coal", 10), 0, "and then nothing")
	st.filter = [&"grain"] as Array[StringName]
	st.clear()
	assert_eq(st.insert(&"coal", 10), 0, "a filtered store refuses what it does not want")
	assert_eq(st.insert(&"grain", 10), 10, "and takes what it does")


func test_a_requisition_post_is_kept_stocked_by_porters() -> void:
	if world.system(&"build") == null:
		skip("the city stockpile lives in [P11], which is not in this build")
		return
	var id: int = _place("requester_post", O)
	assert_true(logi.set_request(id, &"iron_plate", 120), "the post asks for a hundred and twenty")
	world.run(400)
	var st: LogiStore = logi.world.stores[id]
	assert_ge(float(st.count(&"iron_plate")), 120.0, "and the porters bring them")
	assert_false(logi.is_starved(id), "a post that is being served is not starving")


func test_a_request_nobody_can_fill_reads_as_starvation() -> void:
	var id: int = _place("requester_post", O)
	logi.set_request(id, &"circuit", 50)
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"circuit": 0}})
	world.run(60)
	assert_true(logi.is_starved(id), "asking for something the city does not have is starving")
	assert_has(logi.starved_buildings(), id, "and it is named, so a lens can point at it")


# =========================================================================
# fuel — the reason this part exists before production does
# =========================================================================

func test_a_belt_tier_stays_locked_until_it_is_researched() -> void:
	if world.system(&"build") == null:
		skip("research gates are answered by [P11] until [P10] lands")
		return
	world.restart()
	logi = world.system(&"logistics") as LogisticsSystem      # no unlocks granted
	var blocked: Dictionary = logi.can_place(&"belt_mk3", O, 0)
	assert_false(bool(blocked["ok"]), "a driven belt is not available on day one")
	assert_has(String(blocked["reason"]), "locked", "and it says why")
	assert_true(bool(logi.can_place(&"belt_mk1", O, 0)["ok"]), "a slat belt always is")
	world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": "driven_rollers"})
	assert_true(bool(logi.can_place(&"belt_mk3", O, 0)["ok"]), "research opens it")


func test_a_generator_burns_coal_that_had_to_be_delivered() -> void:
	var heat: SimSystem = world.system(&"heat")
	if heat == null or world.system(&"build") == null:
		skip("this is the [P02] handshake and needs both systems")
		return
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 500}})
	world.cmd_now({"system": &"build", "op": "place", "kind": "coal_generator",
		"cell": [O.x, O.y + 20], "free": true, "instant": true})
	world.run(40)
	var b: Object = world.system(&"build").call("building_at", Vector2i(O.x, O.y + 20))
	assert_not_null(b, "the generator is there")
	var id: int = int(b.get("id"))
	assert_gt(float(heat.call("fuel_stock_of", id)), 0.0,
		"and it has coal in it, which somebody had to carry")
	assert_gt(float(heat.call("totals")["supply"]), 0.0, "so it is actually burning")
	var left: int = int(world.system(&"build").get("stock").call("count", &"coal"))
	assert_lt(float(left), 500.0, "and the coal came out of the city's own pile (%d left)" % left)


func test_when_the_coal_runs_out_the_fire_goes_out() -> void:
	var heat: SimSystem = world.system(&"heat")
	var build: SimSystem = world.system(&"build")
	if heat == null or build == null:
		skip("this is the [P02] handshake and needs both systems")
		return
	world.cmd_now({"system": &"build", "op": "place", "kind": "coal_generator",
		"cell": [O.x, O.y + 20], "free": true, "instant": true})
	world.run(60)
	var id: int = int(build.call("building_at", Vector2i(O.x, O.y + 20)).get("id"))
	assert_gt(float(heat.call("totals")["supply"]), 0.0, "lit to start with")

	# Empty every source of coal in the world and let the bunker burn down.
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 0}})
	world.run(20)
	var node: Object = (heat.get("nodes") as Dictionary).get(id)
	node.set("fuel_stock", 0.0)
	world.run(40)
	assert_near(float(heat.call("totals")["supply"]), 0.0, 0.01,
		"no coal, no fire — which is the entire point of this system existing")
	assert_true(logi.is_starved(id), "and the generator can say why it is dark")


func test_an_arm_can_feed_a_generator_from_a_belt() -> void:
	var heat: SimSystem = world.system(&"heat")
	var build: SimSystem = world.system(&"build")
	if heat == null or build == null:
		skip("this is the [P02] handshake and needs both systems")
		return
	var gen: Vector2i = Vector2i(O.x, O.y + 20)
	world.cmd_now({"system": &"build", "op": "place", "kind": "coal_generator",
		"cell": [gen.x, gen.y], "free": true, "instant": true})
	world.run(5)
	var id: int = int(build.call("building_at", gen).get("id"))
	# Starve it, then run a belt to it and let an arm shovel.
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 0}})
	var node: Object = (heat.get("nodes") as Dictionary).get(id)
	node.set("fuel_stock", 0.0)
	world.run(10)

	var start: Vector2i = gen + Vector2i(-6, 0)
	_line("belt_mk1", start, gen + Vector2i(-2, 0))
	_place("inserter_mk1", gen + Vector2i(-1, 0), 0)   # picks up behind, drops into the furnace
	for _i: int in 300:
		logi.world.push_onto_belt(start, 0, &"coal")
		logi.world.push_onto_belt(start, 1, &"coal")
		world.run(1)
	assert_gt(float(heat.call("fuel_stock_of", id)), 0.0,
		"an arm off a belt fills a bunker with no porter in sight")
	assert_gt(float(heat.call("totals")["supply"]), 0.0, "and the generator is burning again")


# =========================================================================
# the contracts other parts stand on
# =========================================================================

func test_items_are_content_and_not_code() -> void:
	for id: String in ["coal", "iron_ore", "iron_plate", "steel_plate", "scrap", "copper_ore",
			"circuit", "ammo_shell", "insulation", "machine_part"]:
		var def: LogiItem = logi.item(StringName(id))
		assert_not_null(def, "%s is defined in game/content/logistics/" % id)
		if def != null:
			assert_ne(def.display_name, "", "%s has a name a player can read" % id)
	assert_gt(float(logi.item_ids().size()), 12.0, "and there is a real item table")
	var fuel: LogiItem = logi.item(&"coal")
	assert_gt(fuel.fuel_value, 0.0, "coal knows that it burns")


func test_a_machine_buffer_is_the_seam_production_plugs_into() -> void:
	if world.system(&"build") == null:
		skip("machine buffers come from [P11] buildings")
		return
	world.cmd_now({"system": &"build", "op": "place", "kind": "smelter",
		"cell": [O.x, O.y + 24], "free": true, "instant": true})
	world.run(5)
	var id: int = int(world.system(&"build").call("building_at", Vector2i(O.x, O.y + 24)).get("id"))
	var st: LogiStore = logi.store_of(id)
	assert_not_null(st, "[P04] finds a smelter's buffer through store_of()")
	assert_eq(logi.deposit(id, &"iron_plate", 40), 40, "it can put its output in")
	assert_eq(logi.withdraw(id, &"iron_plate", 25), 25, "and take ingredients back out")
	assert_eq(int(logi.contents_of(id).get(&"iron_plate", 0)), 15, "the arithmetic holds")


func test_nothing_is_ever_created_or_destroyed() -> void:
	# Conservation is the one property a logistics system cannot get wrong: an
	# item that quietly evaporates is a balance bug nobody will ever find.
	_line("belt_mk1", O, O + Vector2i(5, 0))
	_place("splitter_mk1", O + Vector2i(6, -1), 0)
	_line("belt_mk1", O + Vector2i(7, -1), O + Vector2i(9, -1))
	_line("belt_mk1", O + Vector2i(7, 0), O + Vector2i(9, 0))
	var a: int = _place("crate", O + Vector2i(10, -1))
	var b: int = _place("crate", O + Vector2i(10, 0))
	var put: int = 0
	for _i: int in 300:
		for lane: int in 2:
			var guard: int = 0
			while logi.world.push_onto_belt(O, lane, &"scrap") and guard < 8:
				guard += 1
				put += 1
		world.run(1)
	var on_belts: int = logi.world.items_on_belts()
	var in_chests: int = logi.world.stores[a].total() + logi.world.stores[b].total()
	var in_splitter: int = (logi.world.entities[logi.world.splitter_ids[0]] as LogiSplitter).buffered()
	assert_gt(float(put), 200.0, "a real number of items went in")
	assert_eq(on_belts + in_chests + in_splitter, put,
		"and every one of them is still somewhere: %d on belts, %d in chests, %d in the splitter"
		% [on_belts, in_chests, in_splitter])


func test_the_view_can_ask_where_every_item_is() -> void:
	_line("belt_mk1", O, O + Vector2i(9, 0))
	_run_saturated(O, 60)
	var items: Array[Dictionary] = logi.items_for_view()
	assert_not_empty(items, "[P13] draws items off this contract, so it has to exist")
	var first: Dictionary = items[0]
	for key: String in ["pos", "kind", "lane"]:
		assert_has(first, key, "an item carries %s" % key)
	var belts: Array[Dictionary] = logi.belts_for_view()
	assert_size(belts, 10, "and every belt tile is described for the lens")
	assert_has(belts[0], "saturation", "with how loaded it is")


func test_editing_a_line_does_not_spill_what_was_on_it() -> void:
	_line("belt_mk1", O, O + Vector2i(9, 0))
	_run_saturated(O, 120)
	var before: int = logi.world.items_on_belts()
	assert_gt(float(before), 20.0, "there is a real load on the line")
	# Extend it: the whole line is rebuilt underneath the items.
	_place("belt_mk1", O + Vector2i(10, 0), 0)
	world.run(1)
	assert_eq(logi.world.items_on_belts(), before, "extending a belt keeps every item on it")
	assert_eq(logi.world.spilled, 0, "and spills nothing")
	assert_eq(_segment(O).tile_count(), 11, "the line is one tile longer")


func test_the_whole_logistics_system_replays_identically() -> void:
	var script: Dictionary = {
		2: [{"system": &"logistics", "op": "place_line", "kind": "belt_mk1",
			"from": [40, 40], "to": [49, 40], "free": true}],
		4: [{"system": &"logistics", "op": "place", "kind": "splitter_mk1",
			"cell": [50, 39], "free": true}],
		6: [{"system": &"logistics", "op": "place_line", "kind": "belt_mk1",
			"from": [51, 39], "to": [54, 39], "free": true},
			{"system": &"logistics", "op": "place_line", "kind": "belt_mk1",
			"from": [51, 40], "to": [54, 40], "free": true}],
		8: [{"system": &"logistics", "op": "place", "kind": "crate",
			"cell": [55, 39], "free": true},
			{"system": &"logistics", "op": "place", "kind": "crate",
			"cell": [55, 40], "free": true}],
		10: [{"system": &"logistics", "op": "insert", "cell": [40, 40],
			"item": "coal", "count": 8}],
		30: [{"system": &"logistics", "op": "insert", "cell": [40, 40],
			"item": "iron_ore", "count": 8}],
		60: [{"system": &"logistics", "op": "insert", "cell": [41, 40],
			"item": "coal", "count": 8}],
		90: [{"system": &"logistics", "op": "remove_at", "cell": [45, 40]}],
		120: [{"system": &"logistics", "op": "place", "kind": "inserter_mk1",
			"cell": [56, 39], "free": true}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(7, 220, script)
	assert_empty(diff, "the same factory on the same seed must produce the same world")


func test_the_system_reports_what_a_critic_would_want_to_read() -> void:
	_line("belt_mk1", O, O + Vector2i(9, 0))
	_run_saturated(O, 100)
	var m: Dictionary = logi.metrics()
	for key: String in ["items_on_belts", "throughput", "starved_machines", "backed_up_belts"]:
		assert_has(m, key, "metrics carry %s" % key)
	assert_gt(float(m["items_on_belts"]), 0.0, "and the numbers are live")
	var state: Dictionary = logi.serialize()
	assert_has(state, "lines", "state.json carries the transport lines")
	assert_eq((state["lines"] as Array).size(), 1, "one line, because that is what was built")

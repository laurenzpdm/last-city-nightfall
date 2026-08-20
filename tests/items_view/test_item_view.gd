extends TestCase
## [D2] The headless half of the belt view: the sample, the classifier, the art
## table and the two pure functions the animation is built on.
##
## The frame suite (`tests/items_view/item_frames.tscn`) proves the pixels
## exist. This proves the NUMBERS behind them, and it is deliberately built so
## every check can fail:
##
##   * the classifier is exercised against a real `LogiWorld` running real
##     belts, not a hand-written dictionary — a fixture that fabricates its own
##     input is the shape of every false green this project has already shipped;
##   * the jam test feeds a dead-ended line until [P03] itself stops moving
##     items, then asserts the view calls it BACKED_UP and calls a line
##     delivering into a crate SATURATED. Swap the two thresholds and both go
##     red;
##   * the art table is asserted against `game/content/logistics/*.tres` as it
##     actually ships, so an item added with an unreadable tint fails here.

const ORIGIN: Vector2i = Vector2i(108, 133)
const LEN: int = 10

var world: SimFixture = null
var logi: Object = null
var read: LcnItemFlowRead = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["logistics"])


func setup() -> void:
	world = SimFixture.new(7).start()
	logi = Sim.get_system(&"logistics")
	read = LcnItemFlowRead.new()


func teardown() -> void:
	if world != null:
		world.stop()


# --- the art table -----------------------------------------------------------

func test_every_shipped_item_gets_a_silhouette_and_a_legible_colour() -> void:
	LcnItemArt.reset_for_tests()
	var ids: Array = Registry.ids("logistics")
	var checked: int = 0
	for id: StringName in ids:
		var res: Resource = Registry.get_item("logistics", id)
		if res == null or not (res is LogiItem):
			continue
		checked += 1
		var look: Dictionary = LcnItemArt.look(id)
		assert_between(float(look["shape"]), 0.0, float(LcnItemArt.OUTLINES.size() - 1),
			"%s resolves to a real silhouette" % String(id))
		var fill: Color = look["fill"]
		# The whole point of the lift: nothing may be drawn darker than the belt
		# it rides on. Coal ships at 0.16 luminance and would be invisible.
		assert_ge(fill.get_luminance(), LcnItemArt.MIN_LUMINANCE * 0.92,
			"%s is drawn light enough to be seen on a dark belt" % String(id))
		var rim: Color = look["rim"]
		assert_gt(rim.get_luminance(), fill.get_luminance(),
			"%s has a rim brighter than its body" % String(id))
	assert_gt(float(checked), 10.0, "the whole shipped item list was checked (%d)" % checked)


func test_the_lift_brightens_coal_without_erasing_its_hue() -> void:
	var raw := Color(0.16, 0.16, 0.18)
	var lit: Color = LcnItemArt.legible(raw)
	assert_gt(lit.get_luminance(), raw.get_luminance(), "coal is lifted off the belt")
	var bright := Color(0.85, 0.7, 0.3)
	assert_eq(LcnItemArt.legible(bright), Color(0.85, 0.7, 0.3, 1.0),
		"an already-legible tint is passed through untouched")
	# Two ores that differ only in hue must still differ after the lift, or the
	# belt stops telling iron from copper.
	var iron: Color = LcnItemArt.legible(Color(0.62, 0.44, 0.36))
	var copper: Color = LcnItemArt.legible(Color(0.72, 0.46, 0.28))
	assert_gt(absf(iron.r - copper.r) + absf(iron.g - copper.g) + absf(iron.b - copper.b),
		0.05, "iron ore and copper ore stay different colours")


func test_silhouettes_are_triangle_lists_that_scale() -> void:
	for shape: int in LcnItemArt.OUTLINES.size():
		var tris: PackedVector2Array = LcnItemArt.unit_triangles(shape)
		assert_eq(tris.size() % 3, 0, "shape %d is a whole number of triangles" % shape)
		assert_gt(float(tris.size()), 5.0, "shape %d has area" % shape)
		var small: PackedVector2Array = LcnItemArt.triangles(shape, 2.0)
		var big: PackedVector2Array = LcnItemArt.triangles(shape, 4.0)
		assert_eq(small.size(), big.size(), "the same shape at two sizes has the same vertices")
		assert_near(big[1].length(), small[1].length() * 2.0, 0.02,
			"doubling the radius doubles the geometry")


# --- the zoom contract -------------------------------------------------------

func test_items_hand_over_to_density_across_a_band_not_at_a_cliff() -> void:
	assert_near(LcnItemFlowRoot.fade_for(1.0), 1.0, 0.001, "full strength up close")
	assert_near(LcnItemFlowRoot.fade_for(LcnItemFlowRoot.FADE_HI), 1.0, 0.001, "and at the top of the band")
	assert_near(LcnItemFlowRoot.fade_for(LcnItemFlowRoot.FADE_LO), 0.0, 0.001, "gone at the bottom")
	assert_near(LcnItemFlowRoot.fade_for(0.10), 0.0, 0.001, "and stays gone below it")
	var mid: float = LcnItemFlowRoot.fade_for(
		(LcnItemFlowRoot.FADE_HI + LcnItemFlowRoot.FADE_LO) * 0.5)
	assert_between(mid, 0.2, 0.8, "the handover is a fade, not a switch (%.2f)" % mid)
	assert_lt(LcnItemFlowRoot.FADE_LO, LcnItemFlowRoot.BAND_FAR + 0.001,
		"items are gone no later than [P16]'s strategic threshold")


# --- the arm -----------------------------------------------------------------

func test_the_swing_reads_the_phase_the_simulation_is_actually_in() -> void:
	var half: float = 0.6
	assert_near(LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.WAITING, 0.0, half, 0.0),
		0.0, 0.001, "a waiting arm is parked over its source")
	assert_near(LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.OUT, half, half, 0.0),
		0.0, 0.001, "a swing that just started is still at the source")
	assert_near(LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.OUT, half * 0.5, half, 0.0),
		0.5, 0.001, "halfway through the swing is halfway across")
	# The tell that matters: OUT with the clock run out means the arm is holding
	# a hand it cannot put down, frozen over its target.
	assert_near(LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.OUT, 0.0, half, 0.0),
		1.0, 0.001, "a blocked arm sits at the far end")
	assert_near(LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.BACK, half, half, 0.0),
		1.0, 0.001, "the return starts at the target")
	assert_near(LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.BACK, 0.0, half, 0.0),
		0.0, 0.001, "and ends at the source")
	# Sub-tick interpolation moves it further than the tick alone.
	var at_tick: float = LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.OUT, half * 0.5, half, 0.0)
	var mid_frame: float = LcnMachineMotionLayer.swing_fraction(LogiInserter.Phase.OUT, half * 0.5, half, 1.0)
	assert_gt(mid_frame, at_tick, "a frame between two ticks advances the swing")


# --- the sample and the classifier ------------------------------------------

func test_the_view_accessors_return_a_factory_the_layer_can_draw() -> void:
	_lay(ORIGIN.y, true)
	world.run(4)
	_feed(ORIGIN.y, 8)
	world.run(30)
	read.sample(logi, Rect2i(), true)
	assert_gt(float(read.belts.size()), 0.0, "belts_for_view() reported the run (%d)" % read.belts.size())
	assert_gt(float(read.items.size()), 0.0, "items_for_view() reported items (%d)" % read.items.size())
	assert_eq(read.by_cell.size(), read.belts.size(), "every belt tile is indexed by cell")
	for b: Dictionary in read.belts:
		assert_true(b.has("state") and b.has("flow") and b.has("speed"),
			"every belt tile carries a drawable verdict")
		assert_gt(float(b["speed"]), 0.0, "and the speed the items on it move at")
	for it: Dictionary in read.items:
		var p: Vector2 = it["pos"]
		assert_true(p.length() > 0.0, "an item has a world position")


## The distinction the whole colour scheme rests on: full-and-moving is not
## full-and-stuck. Two lines, same belt, same items, opposite verdicts.
func test_a_delivering_line_and_a_jammed_line_are_told_apart() -> void:
	var flow_row: int = ORIGIN.y
	var jam_row: int = ORIGIN.y + 2
	_lay(flow_row, true)     # feeds a crate: it can always hand off
	_lay(jam_row, false)     # dead end: it fills and stops
	world.run(4)
	for t: int in 260:
		_feed(flow_row, 8)
		_feed(jam_row, 8)
		world.run(1)
	read.sample(logi, Rect2i(), true)

	var flow_states: Dictionary[int, int] = {}
	var jam_states: Dictionary[int, int] = {}
	for b: Dictionary in read.belts:
		var cell: Vector2i = b["cell_v"]
		var into: Dictionary = flow_states if cell.y == flow_row else jam_states
		if cell.y != flow_row and cell.y != jam_row:
			continue
		into[int(b["state"])] = int(into.get(int(b["state"]), 0)) + 1

	assert_gt(float(jam_states.get(LcnItemFlowRead.Flow.BACKED_UP, 0)), 0.0,
		"the dead-ended line is drawn as backed up (%s)" % str(jam_states))
	assert_eq(int(jam_states.get(LcnItemFlowRead.Flow.SATURATED, 0)), 0,
		"and is never mistaken for a healthy full line")
	assert_gt(float(flow_states.get(LcnItemFlowRead.Flow.SATURATED, 0))
		+ float(flow_states.get(LcnItemFlowRead.Flow.FLOWING, 0)), 0.0,
		"the delivering line is drawn as moving (%s)" % str(flow_states))
	assert_eq(int(flow_states.get(LcnItemFlowRead.Flow.BACKED_UP, 0)), 0,
		"and is never called a jam")


func test_an_empty_belt_reads_as_starved() -> void:
	_lay(ORIGIN.y, true)
	world.run(40)
	read.sample(logi, Rect2i(), true)
	var starved: int = read.counts[LcnItemFlowRead.Flow.STARVED]
	assert_eq(starved, read.belts.size(),
		"every tile of a belt nobody feeds is starved (%d of %d)" % [starved, read.belts.size()])


func test_the_four_state_colours_are_distinguishable() -> void:
	var seen: Array[Color] = []
	for s: int in 4:
		var c: Color = LcnBeltFlowLayer.state_color(s)
		for other: Color in seen:
			var d: float = absf(c.r - other.r) + absf(c.g - other.g) + absf(c.b - other.b)
			assert_gt(d, 0.18, "flow colours differ by more than a shade (%.2f)" % d)
		seen.append(c)


func test_arms_and_splitters_reach_the_view() -> void:
	_lay(ORIGIN.y, true)
	Sim.submit_command({"system": &"logistics", "op": "place", "kind": &"crate",
		"cell": [ORIGIN.x - 2, ORIGIN.y], "free": true})
	Sim.submit_command({"system": &"logistics", "op": "place", "kind": &"inserter_mk1",
		"cell": [ORIGIN.x - 1, ORIGIN.y], "rot": 0, "free": true})
	world.run(4)
	Sim.submit_command({"system": &"logistics", "op": "insert",
		"cell": [ORIGIN.x - 2, ORIGIN.y], "item": &"iron_plate", "count": 100})
	world.run(60)
	read.sample(logi, Rect2i(), true)
	assert_gt(float(read.arms.size()), 0.0, "the arm is in the sample")
	var a: Dictionary = read.arms[0]
	for key: String in ["cell", "from", "to", "phase", "timer", "half", "held"]:
		assert_true(a.has(key), "the arm sample carries '%s'" % key)
	assert_gt(float(a["half"]), 0.0, "and a swing duration to interpolate over")
	assert_ne(a["from"], a["to"], "the arm reaches from somewhere to somewhere else")


# --- helpers -----------------------------------------------------------------

func _lay(row: int, sink: bool) -> void:
	Sim.submit_command({"system": &"logistics", "op": "place_line", "kind": &"belt_mk1",
		"from": [ORIGIN.x, row], "to": [ORIGIN.x + LEN - 1, row], "rot": 0, "free": true})
	if sink:
		Sim.submit_command({"system": &"logistics", "op": "place", "kind": &"crate",
			"cell": [ORIGIN.x + LEN, row], "free": true})


func _feed(row: int, count: int) -> void:
	Sim.submit_command({"system": &"logistics", "op": "insert",
		"cell": [ORIGIN.x, row], "item": &"copper_ore", "count": count})

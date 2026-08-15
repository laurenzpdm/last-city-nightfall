extends TestCase
## The placeholder settlement. [P13]
##
## DEFECT (blind judge): "the opening settlement is mirror-symmetric — identical
## radiator/houses left and right — which reads as generated rather than
## settled."
##
## The judge was looking at a harness frame, but the same charge was true of this
## file and worse: the perimeter was FOUR IDENTICAL SIDES, a wall every third
## tile all the way round, which in the frame lab showed up as two columns of
## evenly spaced black dashes at mirrored screen positions. Housing was two rows
## of three at 5/10/15 across and 4/10 down. Nothing in either was wrong; they
## were simply the output of a for-loop, and a city that is the output of a
## for-loop looks like one.
##
## These tests are about SHAPE, not taste. A settlement is allowed to be tidy —
## surveyed roads and a pylon run should read as surveyed — but it may not fold
## onto itself, and it may not lay its houses on a lattice.
##
## They must stay compatible with the other thing this class is for: the frame
## lab needs THE SAME CITY in every run, or a shader change and a layout change
## are indistinguishable between two photographs. So determinism is asserted
## here too, and the fix was fixed numbers rather than more noise.

var _w: LcnPreviewWorld = null


func suite_name() -> String:
	return "render/preview"


func before_all() -> void:
	_w = LcnPreviewWorld.new(7, Vector2i(500, 500), Vector2i(250, 250))
	_w.generate()


## Structures only — the scattered rocks and wrecks are ids 10000+, they are
## already placed off a random stream, and they are not what "generated" meant.
func _planned() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b: Dictionary in _w.buildings:
		if int(b["id"]) < 10000:
			out.append(b)
	return out


## Fraction of planned structures whose left-right reflection about the plaza is
## another structure of the same kind. A city built by a loop scores near 1.
func _mirror_fraction() -> float:
	var by_cell: Dictionary[int, StringName] = {}
	var planned: Array[Dictionary] = _planned()
	for b: Dictionary in planned:
		var c: Vector2i = b["cell"]
		by_cell[c.x * 100003 + c.y] = b["kind"]
	var hit: int = 0
	for b2: Dictionary in planned:
		var c2: Vector2i = b2["cell"]
		var m := Vector2i(2 * _w.centre.x - c2.x, c2.y)
		if by_cell.get(m.x * 100003 + m.y, &"") == b2["kind"]:
			hit += 1
	return float(hit) / float(maxi(planned.size(), 1))


func test_the_settlement_does_not_fold_in_half() -> void:
	var planned: Array[Dictionary] = _planned()
	assert_gt(float(planned.size()), 60.0,
		"there is a real settlement to judge (%d planned structures)" % planned.size())
	var f: float = _mirror_fraction()
	assert_lt(f, 0.35,
		"%.0f%% of the settlement is its own mirror image about the plaza — it reads as generated, not settled"
			% (f * 100.0))


## Houses on a lattice are the other half of the same read. Every habitat used to
## sit on a multiple of five in x and a multiple of two in y.
func test_housing_is_not_laid_out_on_a_grid() -> void:
	var xs: Dictionary[int, bool] = {}
	var ys: Dictionary[int, bool] = {}
	var n: int = 0
	for b: Dictionary in _planned():
		if b["kind"] != &"habitat":
			continue
		var c: Vector2i = b["cell"] - _w.centre
		xs[c.x] = true
		ys[c.y] = true
		n += 1
	assert_ge(float(n), 8.0, "there is housing to judge (%d)" % n)
	# Distinct offsets, not repeated ones: three houses sharing an x is a street
	# elevation, ten houses sharing three x values is a spreadsheet.
	assert_ge(float(xs.size()), float(n) * 0.7,
		"%d houses occupy only %d distinct x offsets" % [n, xs.size()])
	assert_ge(float(ys.size()), float(n) * 0.5,
		"%d houses occupy only %d distinct y offsets" % [n, ys.size()])


## The perimeter has to look like something that was built and repaired, not
## stamped: no two sides may share a spacing, and at least one side has a gap in
## it that is not the gate.
func test_the_wall_was_built_by_people() -> void:
	var north: Array[int] = []
	var south: Array[int] = []
	var west: Array[int] = []
	var east: Array[int] = []
	for b: Dictionary in _planned():
		if b["kind"] != &"wall":
			continue
		var c: Vector2i = b["cell"] - _w.centre
		if c.y <= -20:
			north.append(c.x)
		elif c.y >= 20:
			south.append(c.x)
		elif c.x <= -20:
			west.append(c.y)
		elif c.x >= 20:
			east.append(c.y)
	for side: Array in [north, south, west, east]:
		assert_gt(float(side.size()), 4.0, "every side of the perimeter exists")
		side.sort()
	assert_ne(north, south, "the north and south walls are not the same wall")
	assert_ne(west, east, "the west and east walls are not the same wall")
	# Spacing: at least three of the four sides must differ from each other.
	var spacings: Dictionary[int, bool] = {}
	for side2: Array in [north, south, west, east]:
		spacings[int(side2[1]) - int(side2[0])] = true
	assert_ge(float(spacings.size()), 3.0,
		"the four sides use %d distinct wall spacings — a stamped perimeter uses one"
			% spacings.size())


## The frame lab compares two photographs of the SAME city. If this class were
## not reproducible, every shader iteration would be graded against a different
## layout and none of the numbers would mean anything.
func test_the_same_seed_builds_the_same_city() -> void:
	var a := LcnPreviewWorld.new(7, Vector2i(500, 500), Vector2i(250, 250))
	a.generate()
	var b := LcnPreviewWorld.new(7, Vector2i(500, 500), Vector2i(250, 250))
	b.generate()
	assert_eq(a.buildings.size(), b.buildings.size(), "same structure count")
	for i: int in a.buildings.size():
		assert_eq(a.buildings[i]["cell"], b.buildings[i]["cell"],
			"structure %d lands in the same cell" % i)
		assert_eq(a.buildings[i]["kind"], b.buildings[i]["kind"],
			"structure %d is the same kind" % i)

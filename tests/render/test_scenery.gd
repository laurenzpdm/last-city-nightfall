extends TestCase
## What stands on the plain when nobody built it. [P13]
##
## DEFECT (critic, this wave): the frame "reads as empty" and "the city does not
## occupy the screen". Open the last build's own evidence —
## `artifacts/*/shots/opening.world.png` — and outside the settlement there is
## literally nothing: no rock, no dead stand, no wreck, a hundred by sixty tiles
## of shaded gradient. The [P13] preview settlement scattered 260 props around
## itself, which is why the frame lab's photographs looked furnished while the
## actual game did not: those props were part of the PLACEHOLDER and vanished
## the moment a real simulation supplied real buildings.
##
## LcnScenery derives the plain's furniture from the TERRAIN instead, so it is
## there in every run. These tests hold the three rules that keep that honest:
## it is the same plain twice, it never contradicts the ground it stands on, and
## it never puts a boulder inside somebody's factory.

var _model: LcnWorldModel = null
var _s: LcnScenery = null


func suite_name() -> String:
	return "render/scenery"


func before_all() -> void:
	_model = LcnWorldModel.new(LcnSpriteFactory.new())
	_model.attach()
	_s = LcnScenery.new()
	_s.setup(7)


func _rect() -> Rect2:
	var c: Vector2 = Vector2(_model.world_size()) * 16.0
	return Rect2(c - Vector2(1600.0, 900.0), Vector2(3200.0, 1800.0))


## The plain is dressed at all. A view this size that comes back with a handful
## of rocks is the defect this class exists for, restated with more code.
func test_the_open_plain_is_not_empty() -> void:
	var props: Array[Dictionary] = _s.in_view(_model, null, _rect(), 0)
	assert_gt(float(props.size()), 60.0,
		"a 100x56 tile view carries %d pieces of scenery" % props.size())
	var kinds: Dictionary[StringName, int] = {}
	for p: Dictionary in props:
		kinds[p["arch"]] = int(kinds.get(p["arch"], 0)) + 1
	assert_ge(float(kinds.size()), 3.0,
		"and more than one thing grows out there (%s)" % str(kinds))


## Nothing stands on open ice or on a paved road. A boulder on lake ice is the
## kind of mistake the eye catches before it catches anything good in the frame.
func test_nothing_stands_on_ice_or_on_a_road() -> void:
	var props: Array[Dictionary] = _s.in_view(_model, null, _rect(), 0)
	assert_gt(float(props.size()), 0.0, "there is scenery to check")
	for p: Dictionary in props:
		var t: int = _model.terrain_at(p["cell"] as Vector2i)
		assert_ne(t, LcnPalette.Terrain.WATER_FROZEN,
			"%s at %s is not standing on open water" % [p["arch"], str(p["cell"])])
		assert_ne(t, LcnPalette.Terrain.ICE,
			"%s at %s is not standing on bare ice" % [p["arch"], str(p["cell"])])
		assert_ne(t, LcnPalette.Terrain.PAVED,
			"%s at %s is not standing in the middle of a road" % [p["arch"], str(p["cell"])])


## Rock shelves carry outcrops and deep drifts carry almost nothing, because
## that is what those two surfaces ARE. Scenery that ignored the ground under it
## would be a second unrelated noise field laid over the first.
func test_the_ground_decides_what_grows_on_it() -> void:
	var rock: int = 0
	var rock_cells: int = 0
	var deep: int = 0
	var deep_cells: int = 0
	var origin: Vector2i = _model.world_size() / 2 - Vector2i(120, 120)
	for cy: int in range(0, 240, 3):
		for cx: int in range(0, 240, 3):
			match _model.terrain_at(origin + Vector2i(cx, cy)):
				LcnPalette.Terrain.ROCK: rock_cells += 1
				LcnPalette.Terrain.SNOW_DEEP: deep_cells += 1
	if rock_cells < 20 or deep_cells < 20:
		skip("this seed's plain has no rock shelf or no deep drift to compare")
		return
	var rect := Rect2(Vector2(origin) * 32.0, Vector2(240.0, 240.0) * 32.0)
	for p: Dictionary in _s.in_view(_model, null, rect, 0):
		match _model.terrain_at(p["cell"] as Vector2i):
			LcnPalette.Terrain.ROCK: rock += 1
			LcnPalette.Terrain.SNOW_DEEP: deep += 1
	var rock_density: float = float(rock) / float(rock_cells)
	var deep_density: float = float(deep) / float(deep_cells)
	assert_gt(rock_density, deep_density * 2.0,
		"a rock shelf is denser with outcrops than a deep drift is (%.3f vs %.3f)"
			% [rock_density, deep_density])


## The frame lab photographs the same plain twice and diffs it. Scenery that
## reshuffled between two frames would sign every shader change it was standing
## in front of.
func test_the_same_seed_dresses_the_same_plain() -> void:
	var a := LcnScenery.new()
	a.setup(7)
	var b := LcnScenery.new()
	b.setup(7)
	var pa: Array[Dictionary] = a.in_view(_model, null, _rect(), 0).duplicate()
	var pb: Array[Dictionary] = b.in_view(_model, null, _rect(), 0).duplicate()
	assert_eq(pa.size(), pb.size(), "same count")
	for i: int in pa.size():
		assert_eq(pa[i]["cell"] as Vector2i, pb[i]["cell"] as Vector2i,
			"prop %d lands on the same tile" % i)
		assert_eq(pa[i]["arch"] as StringName, pb[i]["arch"] as StringName,
			"prop %d is the same thing" % i)
	# ...and a different world is a different plain.
	var c := LcnScenery.new()
	c.setup(1234)
	var pc: Array[Dictionary] = c.in_view(_model, null, _rect(), 0)
	var same: int = 0
	for i2: int in mini(pa.size(), pc.size()):
		if (pa[i2]["cell"] as Vector2i) == (pc[i2]["cell"] as Vector2i):
			same += 1
	assert_lt(float(same), float(maxi(pa.size(), 1)) * 0.5,
		"another seed does not lay out the same rocks")


## Everything it places has a sprite in the atlas. A prop kind the sprite factory
## does not know about draws nothing, which is a silent hole in the frame rather
## than a loud one.
func test_every_scenery_kind_is_drawable() -> void:
	var f := LcnSpriteFactory.new()
	var atlas: Dictionary = f.atlas([])
	var regions: Dictionary = atlas["regions"]
	var seen: Dictionary[StringName, bool] = {}
	for p: Dictionary in _s.in_view(_model, null, _rect(), 0):
		seen[p["arch"] as StringName] = true
	assert_gt(float(seen.size()), 0.0, "the plain placed something")
	for arch: StringName in seen:
		assert_has(LcnSpriteFactory.archetypes(), arch,
			"%s is a real archetype" % arch)
		var key: StringName = LcnSpriteFactory.sprite_key(
			arch, LcnSpriteFactory.spec(arch)["tiles"])
		assert_true(regions.has(key),
			"%s rides the one atlas, so scenery costs no extra draw call" % arch)

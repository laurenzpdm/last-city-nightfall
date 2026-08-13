extends TestCase
## The ground's data plane and the contract between it and terrain.gdshader. [P13]
##
## The ground is now generated on the GPU, which a headless test cannot execute.
## What a headless test CAN do — and what would have caught both of the defects
## this part exists to fix — is check the data the shader is fed and check that
## every uniform the renderer writes actually exists in the shader it writes to.

const SHADER_PATH: String = "res://game/view/render/terrain.gdshader"
const RENDERER_PATH: String = "res://game/view/render/terrain_renderer.gd"

var field: LcnTerrainField = null
var model: LcnWorldModel = null


func suite_name() -> String:
	return "render/terrain_field"


func setup() -> void:
	field = LcnTerrainField.new()
	field.setup(Vector2i(128, 96), 235.0)
	model = LcnWorldModel.new(LcnSpriteFactory.new())


func test_fields_are_allocated_at_their_declared_resolutions() -> void:
	assert_eq(field.size, Vector2i(128, 96), "kind field is one texel per tile")
	assert_eq((field.kind_tex as ImageTexture).get_size(), Vector2i(128, 96), "kind texture")
	assert_eq((field.snow_tex as ImageTexture).get_size(),
		Vector2i(128 / LcnTerrainField.SNOW_STEP, 96 / LcnTerrainField.SNOW_STEP), "snow texture")
	assert_eq((field.city_tex as ImageTexture).get_size(),
		Vector2i(128 / LcnTerrainField.CITY_STEP, 96 / LcnTerrainField.CITY_STEP), "city texture")
	assert_near(field.snow_scale, 255.0 / 235.0, 0.0001, "snow normaliser matches the grid's cap")


## The whole data plane for a full-size map has to be small enough that keeping
## all of it resident is obviously correct — that is what removed chunk streaming
## and with it the chunk seams.
func test_the_whole_map_fits_in_a_trivial_amount_of_memory() -> void:
	var big := LcnTerrainField.new()
	big.setup(Vector2i(512, 512), 235.0)
	var kb: int = int(big.stats()["bytes"]) / 1024
	assert_lt(float(kb), 512.0, "a 512x512 world's whole ground data plane is %d KB" % kb)
	assert_gt(float(kb), 0.0, "and it is actually allocated")


func test_kind_field_reads_terrain_and_survives_a_missing_grid() -> void:
	# No Sim attach: this is the parallel-development path, where [P01] is absent.
	var n: int = field.refresh_kind(model)
	assert_gt(float(n), 0.0, "first pass writes every chunk")
	assert_eq(field.refresh_kind(model), 0, "second pass writes none — versions unchanged")


func test_snow_refresh_is_bounded_per_call() -> void:
	var done: int = field.refresh_snow(model, 3, [])
	assert_eq(done, 3, "the round-robin honours its budget")
	var forced: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 2)]
	assert_eq(field.refresh_snow(model, 3, forced), 5, "forced chunks jump the queue on top of it")
	# Out-of-range forced chunks are dropped, not clamped onto a real chunk.
	assert_eq(field.refresh_snow(model, 0, [Vector2i(999, 999)] as Array[Vector2i]), 0,
		"a chunk outside the map is ignored")


## The melt ring around a hearth is a disc with a squared falloff, and it has to
## saturate rather than wrap when two hearths overlap.
func test_heat_stamps_are_discs_that_saturate() -> void:
	var centre := Vector2(64.0 * 32.0, 48.0 * 32.0)
	var srcs: Array[Dictionary] = [
		{"pos": centre, "radius": 320.0, "intensity": 1.0, "seed": 1},
		{"pos": centre, "radius": 320.0, "intensity": 1.0, "seed": 2},
		{"pos": centre, "radius": 320.0, "intensity": 1.0, "seed": 3},
	]
	field.refresh_sources(srcs, [] as Array[Dictionary])
	assert_near(field.heat_at(Vector2i(64, 48)), 1.0, 0.02, "three overlapping fires saturate at 1.0")
	assert_gt(field.heat_at(Vector2i(66, 48)), 0.2, "and the pool has real extent")
	assert_near(field.heat_at(Vector2i(120, 90)), 0.0, 0.001, "with nothing far away")

	field.refresh_sources([] as Array[Dictionary], [] as Array[Dictionary])
	assert_near(field.heat_at(Vector2i(64, 48)), 0.0, 0.001, "and the field clears when the fire goes out")


## DEFECT (critic, defect 3b): "there is no ambient legibility floor, so unlit
## buildings vanish entirely." The city field is that floor, so it must actually
## spread past the buildings that make it.
func test_city_presence_spreads_past_the_buildings_that_make_it() -> void:
	var b: Array[Dictionary] = [{
		"centre": Vector2(64.0 * 32.0, 48.0 * 32.0),
		"tiles": Vector2i(5, 5), "warm": 1.0,
	}]
	field.refresh_city(b)
	var at_building: float = field.city_at(Vector2i(64, 48))
	assert_gt(at_building, 0.5, "the tile a hearth stands on is fully inside the city")
	assert_gt(field.city_at(Vector2i(64 + 8, 48)), 0.05,
		"and the light it bounces reaches the next block")
	assert_lt(field.city_at(Vector2i(64 + 40, 48)), 0.05,
		"but not forty tiles out — that plain is supposed to be dark")

	field.refresh_city([] as Array[Dictionary])
	assert_near(field.city_at(Vector2i(64, 48)), 0.0, 0.001, "an empty map has no city glow")


## Cost has to be independent of how many buildings there are, because the stress
## city has 1717 of them.
func test_city_presence_cost_does_not_grow_with_the_city() -> void:
	var few: Array[Dictionary] = []
	for i: int in 8:
		few.append({"centre": Vector2(float(30 + i) * 32.0, 40.0 * 32.0),
			"tiles": Vector2i(2, 2), "warm": 0.4})
	field.refresh_city(few)
	var t_few: int = int(field.stats()["city_us"])

	var many: Array[Dictionary] = []
	for i: int in 1200:
		many.append({"centre": Vector2(float(10 + i % 100) * 32.0, float(10 + i / 100) * 32.0),
			"tiles": Vector2i(2, 2), "warm": 0.4})
	field.refresh_city(many)
	var t_many: int = int(field.stats()["city_us"])
	assert_lt(float(t_many), maxf(float(t_few) * 4.0, 12000.0),
		"150x the buildings costs %d us vs %d us — the blur dominates, not the count" % [t_many, t_few])


func test_palette_texture_encodes_every_terrain_kind() -> void:
	var img: Image = (field.palette_tex as ImageTexture).get_image()
	assert_eq(img.get_size(), Vector2i(LcnTerrainField.PAL_WIDTH, LcnTerrainField.PAL_ROWS),
		"palette texture shape")
	for k: int in LcnPalette.TERRAIN_COUNT:
		var tones: Dictionary = LcnPalette.terrain_tones(k)
		var base: Color = img.get_pixel(k, 0)
		var high: Color = img.get_pixel(k, 2)
		assert_near(base.r, (tones["base"] as Color).r, 0.01, "kind %d base row" % k)
		assert_near(high.g, (tones["high"] as Color).g, 0.01, "kind %d high row" % k)
		var sheds: bool = LcnPalette.terrain_sheds_snow(k)
		assert_near(base.a, 0.0 if sheds else 1.0, 0.01,
			"kind %d records whether snow settles on it in the base alpha" % k)


func test_noise_texture_is_four_independent_channels() -> void:
	var img: Image = (field.noise_tex as ImageTexture).get_image()
	assert_eq(img.get_width(), LcnTerrainField.NOISE_SIZE, "noise texture size")
	# Every octave in the shader reads a different channel, so the channels must
	# not correlate or the fbm collapses to one scaled octave.
	var same: int = 0
	for i: int in 400:
		var c: Color = img.get_pixel(i % 20 * 11, i / 20 * 11)
		if absf(c.r - c.g) < 0.02:
			same += 1
	assert_lt(float(same), 60.0, "r and g are independent (%d/400 collisions)" % same)


# ------------------------------------------------------- shader/renderer join --

## Every uniform the renderer writes must exist in the shader it writes to.
## A renamed uniform is otherwise silent: Godot ignores the set and the ground
## keeps rendering with whatever the last value was.
func test_every_uniform_the_renderer_sets_exists_in_the_shader() -> void:
	var src: String = FileAccess.get_file_as_string(SHADER_PATH)
	var code: String = FileAccess.get_file_as_string(RENDERER_PATH)
	assert_not_empty(src, "shader source is readable")
	assert_not_empty(code, "renderer source is readable")
	var re := RegEx.new()
	var err: int = re.compile("set_shader_parameter\\(\"([a-z_0-9]+)\"")
	assert_eq(err, OK, "regex compiles")
	var checked: int = 0
	for m: RegExMatch in re.search_all(code):
		var name: String = m.get_string(1)
		assert_true(src.contains("uniform") and src.contains(" " + name),
			"terrain.gdshader declares uniform '%s'" % name)
		checked += 1
	assert_gt(float(checked), 15.0, "and there are %d of them to keep in step" % checked)


## The shader has to stay inside what the GL Compatibility backend accepts, and
## the project ships on that backend.
func test_shader_stays_within_gl_compatibility() -> void:
	var src: String = FileAccess.get_file_as_string(SHADER_PATH)
	assert_true(src.begins_with("shader_type canvas_item;"), "it is a canvas item shader")
	for banned: String in ["textureLod(", "dFdx(", "dFdy(", "fwidth(", "texelFetch("]:
		assert_false(src.contains(banned), "no %s — unsupported or unreliable on GLES3 canvas" % banned)
	assert_true(src.contains("varying vec2 world_pos"), "world position is carried from the vertex stage")
	assert_true(src.contains("void vertex()"), "and there is a vertex stage to carry it")

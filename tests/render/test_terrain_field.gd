extends TestCase
## The ground's data plane and the contract between it and terrain.gdshader. [P13]
##
## The ground is now generated on the GPU, which a headless test cannot execute.
## What a headless test CAN do — and what would have caught both of the defects
## this part exists to fix — is check the data the shader is fed and check that
## every uniform the renderer writes actually exists in the shader it writes to.

const SHADER_PATH: String = "res://game/view/render/terrain.gdshader"
const RENDERER_PATH: String = "res://game/view/render/terrain_renderer.gd"
const POST_SHADER_PATH: String = "res://game/view/render/post_process.gdshader"
const POST_PATH: String = "res://game/view/render/post_process.gd"

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
##
## MEASURED PER TILE, not as one absolute number for one map size. The old form
## was `< 512 KB at 512x512`, which is the same claim with the map size baked
## into it: adding the wear field at one texel per tile took it to 716 KB and
## turned a guard about STREAMING into a guard about the number six. The rule
## being defended is that the plane is a couple of bytes per TILE — so it cannot
## grow with resolution, cannot need paging, and a bigger map is a bigger number
## and not a different architecture. The absolute ceiling stays as a second
## backstop, an order of magnitude above where the fields sit.
func test_the_whole_map_fits_in_a_trivial_amount_of_memory() -> void:
	var big := LcnTerrainField.new()
	big.setup(Vector2i(512, 512), 235.0)
	var bytes: int = int(big.stats()["bytes"])
	var per_tile: float = float(bytes) / float(512 * 512)
	assert_lt(per_tile, 3.5,
		"the ground's whole data plane is %.2f bytes per tile (%d KB at 512x512)"
			% [per_tile, bytes / 1024])
	assert_lt(float(bytes) / 1024.0, 1024.0,
		"and under a megabyte for the largest map the game ships (%d KB)" % (bytes / 1024))
	assert_gt(float(bytes), 0.0, "and it is actually allocated")


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


## Soot is a halo of grime AROUND industry, and only around industry — a whole
## district of chimneys must not resolve as one black crater, which is what the
## first pass's binary decal did.
func test_soot_settles_around_industry_and_nowhere_else() -> void:
	var chimney := Vector2(50.0 * 32.0, 40.0 * 32.0)
	var industry: Array[Dictionary] = [{
		"centre": chimney, "tiles": Vector2i(3, 3), "warm": 0.8,
		"soot": 0.5, "soot_radius": 3.0 * 32.0 * 1.5,
	}]
	var clean: Array[Dictionary] = [{
		"centre": Vector2(90.0 * 32.0, 40.0 * 32.0), "tiles": Vector2i(2, 2), "warm": 0.5,
		"soot": 0.0, "soot_radius": 0.0,
	}]
	field.refresh_soot(industry + clean)
	assert_gt(field.soot_at(Vector2i(50, 40)), 0.2, "the chimney's own tile is sooty")
	assert_gt(field.soot_at(Vector2i(52, 40)), 0.01, "and so is the ground beside it")
	assert_near(field.soot_at(Vector2i(62, 40)), 0.0, 0.01, "ten tiles out it is clean")
	assert_near(field.soot_at(Vector2i(90, 40)), 0.0, 0.01,
		"and a building with no chimney lays none at all")
	assert_lt(field.soot_at(Vector2i(50, 40)), 1.0,
		"and even at the stack it is grime on the ground, never a hole in it")


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
	for path: String in [SHADER_PATH, POST_SHADER_PATH]:
		var src: String = FileAccess.get_file_as_string(path)
		assert_true(src.begins_with("shader_type canvas_item;"), "%s is a canvas item shader" % path)
		for banned: String in ["textureLod(", "dFdx(", "dFdy(", "fwidth(", "texelFetch("]:
			assert_false(src.contains(banned),
				"%s: no %s — unsupported or unreliable on GLES3 canvas" % [path, banned])
	var ground: String = FileAccess.get_file_as_string(SHADER_PATH)
	assert_true(ground.contains("varying vec2 world_pos"), "world position is carried from the vertex stage")
	assert_true(ground.contains("void vertex()"), "and there is a vertex stage to carry it")


## Same contract for the post stack, which is where the heat shimmer lives.
func test_post_stack_uniforms_match_the_shader() -> void:
	var src: String = FileAccess.get_file_as_string(POST_SHADER_PATH)
	var code: String = FileAccess.get_file_as_string(POST_PATH)
	var re := RegEx.new()
	assert_eq(re.compile("set_shader_parameter\\(\"([a-z_0-9]+)\""), OK, "regex compiles")
	var checked: int = 0
	for m: RegExMatch in re.search_all(code):
		var name: String = m.get_string(1)
		assert_true(src.contains(" " + name), "post_process.gdshader declares uniform '%s'" % name)
		checked += 1
	assert_gt(float(checked), 12.0, "%d post uniforms kept in step" % checked)
	# The shimmer must be inert until the ground binds a real heat field: an
	# unbound sampler reads WHITE, which would haze the entire frame.
	assert_true(src.contains("uniform float shimmer_amount = 0.0;"),
		"shimmer defaults to off in the shader")
	assert_true(code.contains("Image.FORMAT_RGBA8"), "and to a black 1x1 texture in the script")
	assert_true(src.contains("heat_tex"), "the shimmer samples the ground's heat field")


# ------------------------------------------------------------------- wear -----
#
# THE GROUND'S MEMORY. The shader used to draw "tracks" as contour lines of a
# static noise field, revealed wherever the blurred city-presence texture was
# high — paths that appeared the instant a building was placed, ran where nobody
# had walked, and were pixel-identical at hour 3 and hour 1. The frame lab
# measures the picture; these measure the data the picture is made from, which
# is the half a headless gate can run.

## A path exists where feet fell and nowhere else. This is the whole difference
## between a real wear field and the contour lie it replaced.
func test_wear_is_written_where_feet_fall_and_nowhere_else() -> void:
	assert_eq(field.wear_at(Vector2i(40, 40)), 0.0, "a plain nobody has crossed is unmarked")
	assert_near(field.wear_mean(), 0.0, 0.0001, "and its mean is zero")
	for i: int in 6:
		field.add_wear(Vector2(40.0 * 32.0 + 16.0, 40.0 * 32.0 + 16.0), 0.45, 12)
	assert_gt(field.wear_at(Vector2i(40, 40)), 0.20,
		"six footfalls on one tile wear it visibly (%.3f)" % field.wear_at(Vector2i(40, 40)))
	assert_eq(field.wear_at(Vector2i(46, 40)), 0.0,
		"and six tiles away, where nobody walked, the snow is untouched")
	assert_gt(field.wear_mean(), 0.0, "the running mean tracks it without a full sum")


## It ACCUMULATES. A route used all day has to end up deeper than a route used
## once, or the field says the same thing at hour 3 that it said at hour 1.
func test_wear_deepens_with_use_and_saturates() -> void:
	var pos := Vector2(20.0 * 32.0 + 16.0, 20.0 * 32.0 + 16.0)
	field.add_wear(pos, 0.45, 12)
	var once: float = field.wear_at(Vector2i(20, 20))
	for i: int in 8:
		field.add_wear(pos, 0.45, 12)
	var often: float = field.wear_at(Vector2i(20, 20))
	assert_gt(often, once * 3.0,
		"a route walked nine times is deeper than one walked once (%.3f vs %.3f)" % [often, once])
	for i2: int in 200:
		field.add_wear(pos, 0.45, 12)
	assert_le(field.wear_at(Vector2i(20, 20)), 1.0, "and it cannot exceed the scale")
	assert_gt(field.wear_at(Vector2i(20, 20)), 0.90, "but it does reach the bottom of it")


## And it FORGETS, on the sim clock, so an abandoned quarter goes back under the
## snow instead of scarring the map for the rest of the campaign.
func test_wear_fades_on_the_sim_clock_and_faster_in_snow() -> void:
	var pos := Vector2(10.0 * 32.0 + 16.0, 10.0 * 32.0 + 16.0)
	for i: int in 12:
		field.add_wear(pos, 0.45, 12)
	var start: float = field.wear_at(Vector2i(10, 10))
	assert_gt(start, 0.3, "there is a path here to lose")
	# Enough sweeps that the round-robin certainly reaches row 10 several times.
	var t: float = 0.0
	for s: int in 400:
		t += 0.2
		field.decay_wear(t, 0.0)
	var calm_left: float = field.wear_at(Vector2i(10, 10))
	assert_lt(calm_left, start, "the path fades (%.3f -> %.3f)" % [start, calm_left])

	# ...and the same elapsed time with snow falling buries more of it, because
	# the decay period shortens with the weather.
	var fresh := LcnTerrainField.new()
	fresh.setup(Vector2i(128, 96), 235.0)
	for i2: int in 12:
		fresh.add_wear(pos, 0.45, 12)
	var t2: float = 0.0
	for s2: int in 400:
		t2 += 0.2
		fresh.decay_wear(t2, 1.0)
	assert_lt(fresh.wear_at(Vector2i(10, 10)), calm_left,
		"a blizzard buries a path faster than a clear afternoon (%.3f vs %.3f)"
			% [fresh.wear_at(Vector2i(10, 10)), calm_left])


## The sweep is round-robin and bounded, because it runs inside a frame. A decay
## pass that walked the whole map would be 65 536 bytes every time it fired.
func test_the_decay_sweep_is_bounded_per_call() -> void:
	assert_le(float(LcnTerrainField.WEAR_ROWS_PER_SWEEP), 64.0,
		"a sweep touches at most %d rows" % LcnTerrainField.WEAR_ROWS_PER_SWEEP)
	# Two calls one microsecond apart must not both do work: the period gate is
	# what keeps this off the frame budget on a fast machine.
	field.add_wear(Vector2(60.0 * 32.0, 4.0 * 32.0), 0.45, 40)
	field.decay_wear(100.0, 0.0)
	var after_first: float = field.wear_mean()
	field.decay_wear(100.0001, 0.0)
	assert_eq(field.wear_mean(), after_first, "a second call in the same instant is a no-op")


## The shader must never be handed an unbound wear sampler: an unset sampler2D
## reads WHITE, and a white wear field is a plain trodden flat before anyone has
## taken a step. Two independent guards, because this one is invisible when it
## goes wrong — it looks like art.
func test_an_unbound_wear_field_cannot_read_as_a_trodden_plain() -> void:
	assert_not_null(field.wear_tex, "the field always publishes a wear texture")
	assert_eq((field.wear_tex as ImageTexture).get_size(), Vector2i(128, 96),
		"one texel per tile, because a worn path is about a tile wide")
	var src: String = FileAccess.get_file_as_string(SHADER_PATH)
	assert_true(src.contains("hint_default_black"),
		"and the uniform declares hint_default_black, so an unbound sampler reads 0")
	var code: String = FileAccess.get_file_as_string(RENDERER_PATH)
	assert_true(code.contains("\"wear_tex\", field.wear_tex"),
		"the renderer binds the real field to it")


## The contour lie is GONE, not merely unused. Leaving it in the shader behind a
## dead uniform is how a build ends up drawing both.
func test_the_fake_contour_tracks_are_gone_from_the_shader() -> void:
	var src: String = FileAccess.get_file_as_string(SHADER_PATH)
	assert_true(src.contains("texture(wear_tex"), "the ground samples the wear field")
	assert_false(src.contains("float lived = smoothstep"),
		"and no longer derives a path from the building-presence blur")

extends TestCase
## Everything about [P14] that can be proved without a GPU.
##
## The pixels are asserted separately, in tests/vfx/vfx_gpu.tscn, because a
## headless process has no rendering backend and a suite that quietly asserts
## nothing is worse than no suite at all (ARCHITECTURE.md §6.1). What is checked
## here is the logic that decides WHAT to draw: the weather table, the burst
## buffer's arithmetic and its overflow policy, the classification of a building
## into an effect, the death-style mapping, and the settings contract.

const CAP: int = 8


func suite_name() -> String:
	return "vfx_logic"


# --------------------------------------------------------------- the tuning --

func test_every_weather_kind_the_sim_can_report_has_a_row() -> void:
	# ClimateDefs owns the names; if a name is added there and not here the snow
	# silently falls back and nobody finds out until a screenshot looks wrong.
	for name: StringName in [&"clear", &"overcast", &"snowfall", &"blizzard",
			&"great_frost"]:
		assert_true(LcnVfxTuning.WEATHER.has(name),
			"weather table is missing '%s'" % name)


func test_weather_rows_are_monotonic_in_severity() -> void:
	var order: Array[StringName] = [&"clear", &"overcast", &"snowfall", &"blizzard",
		&"great_frost"]
	var last_snow: float = -1.0
	var last_white: float = -1.0
	for name: StringName in order:
		var row: Dictionary = LcnVfxTuning.weather_row(name)
		assert_true(float(row["snow"]) >= last_snow,
			"%s has less snow than the kind below it" % name)
		assert_true(float(row["whiteout"]) >= last_white,
			"%s whites out less than the kind below it" % name)
		last_snow = float(row["snow"])
		last_white = float(row["whiteout"])


func test_an_unknown_weather_name_still_snows() -> void:
	var row: Dictionary = LcnVfxTuning.weather_row(&"hail_of_frogs")
	assert_true(float(row["snow"]) > 0.0,
		"an unknown weather kind must fall back to something visible")


func test_whiteout_never_reaches_opaque() -> void:
	assert_true(LcnVfxTuning.WHITEOUT_MAX < 0.8,
		"a storm may cost sight; it may not take the city away entirely")
	assert_true(LcnVfxTuning.WHITEOUT_MAX_CALM < LcnVfxTuning.WHITEOUT_MAX,
		"reduce_motion must lower the veil, not raise it")


func test_the_opening_settlement_is_classified_into_effects() -> void:
	# Every kind boot.gd places must resolve to a class, or the reference city
	# stands there with nothing coming out of it.
	var expected: Dictionary[StringName, StringName] = {
		&"the_hearth": &"furnace",
		&"coal_generator": &"furnace",
		&"workshop": &"works",
		&"warmth_radiator": &"vent",
	}
	for kind: StringName in expected:
		assert_eq(LcnVfxTuning.fx_class(kind, &"unknown"), expected[kind],
			"%s should be a %s" % [kind, expected[kind]])


func test_an_unknown_kind_falls_back_to_its_archetype() -> void:
	assert_eq(LcnVfxTuning.fx_class(&"brand_new_forge", &"coal_generator"), &"furnace",
		"a kind this table has never seen must still be classified by its sprite")
	assert_eq(LcnVfxTuning.fx_class(&"brand_new_wall", &"wall"), &"none",
		"a wall must not smoke")


func test_every_enemy_in_the_roster_has_a_death() -> void:
	var ids: Array[StringName] = Registry.ids("enemies")
	if ids.is_empty():
		return
	var styles: Dictionary[StringName, bool] = {}
	for id: StringName in ids:
		var style: StringName = LcnVfxTuning.death_style(id)
		assert_true(style == &"ice" or style == &"ember" or style == &"beast",
			"%s dies as '%s', which is not a style this part draws" % [id, style])
		styles[style] = true
	assert_true(styles.size() >= 2,
		"if every enemy in the roster dies the same way, the effect carries no information")


# ------------------------------------------------------------ burst buffer --

func _buffer(cap: int = CAP) -> LcnVfxBurst:
	var b := LcnVfxBurst.new()
	b.configure(cap, false, 0)
	return b


func test_a_burst_holds_what_it_is_given() -> void:
	var b: LcnVfxBurst = _buffer()
	for i: int in 5:
		b.emit(Vector2(float(i), 0.0), Vector2.ZERO, 1.0, 2.0, Color.WHITE,
			LcnVfxBurst.Shape.SOFT)
	assert_eq(b.count, 5, "five emitted, five live")
	b.free()


func test_a_full_burst_never_grows() -> void:
	var b: LcnVfxBurst = _buffer()
	for i: int in CAP * 4:
		b.emit(Vector2.ZERO, Vector2.ZERO, 1.0, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	assert_eq(b.count, CAP, "the buffer is a hard cap, not a target")
	assert_true(int(b.stats()["dropped"]) > 0, "overflow must be counted, not hidden")
	b.free()


func test_overflow_drops_the_particle_closest_to_death() -> void:
	var b: LcnVfxBurst = _buffer(2)
	b.emit(Vector2.ZERO, Vector2.ZERO, 0.05, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	b.emit(Vector2.ZERO, Vector2.ZERO, 5.00, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	b.emit(Vector2.ZERO, Vector2.ZERO, 3.00, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	b.step(0.1, Vector2.ZERO)
	# The 0.05 s particle was the one overwritten, so after 0.1 s both survivors
	# are still alive. If the buffer had dropped the newest instead, one of them
	# would be gone.
	assert_eq(b.count, 2, "the fading particle should have been the one sacrificed")
	b.free()


func test_particles_die_and_the_buffer_compacts() -> void:
	var b: LcnVfxBurst = _buffer()
	b.emit(Vector2.ZERO, Vector2.ZERO, 0.1, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	b.emit(Vector2.ZERO, Vector2.ZERO, 9.0, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	b.step(0.2, Vector2.ZERO)
	assert_eq(b.count, 1, "an expired particle must leave the buffer")
	b.step(20.0, Vector2.ZERO)
	assert_eq(b.count, 0, "and so must the last one")
	b.free()


func test_only_buoyant_particles_take_the_wind() -> void:
	var b: LcnVfxBurst = _buffer()
	# A masonry chip: no buoyancy, so a gale must not carry it.
	b.emit(Vector2.ZERO, Vector2.ZERO, 9.0, 2.0, Color.WHITE, LcnVfxBurst.Shape.CHIP, 0.5, 0.0)
	b.step(0.5, Vector2(400.0, 0.0))
	var chip_x: float = b.position_of(0).x
	b.free()

	var s: LcnVfxBurst = _buffer()
	# A smoke puff: buoyant, so the same gale must move it.
	s.emit(Vector2.ZERO, Vector2.ZERO, 9.0, 2.0, Color.WHITE, LcnVfxBurst.Shape.PUFF, 0.5, 30.0)
	s.step(0.5, Vector2(400.0, 0.0))
	var puff: Vector2 = s.position_of(0)
	s.free()

	assert_near(chip_x, 0.0, 1.0, "debris must not blow away")
	assert_true(puff.x > 40.0, "smoke must bend with the wind (moved %.1f px)" % puff.x)
	assert_true(puff.y < -1.0, "smoke must rise (moved %.1f px)" % puff.y)


func test_a_burst_survives_a_frame_of_zero_length() -> void:
	var b: LcnVfxBurst = _buffer()
	b.emit(Vector2.ZERO, Vector2(10.0, 10.0), 1.0, 2.0, Color.WHITE, LcnVfxBurst.Shape.SOFT)
	b.step(0.0, Vector2.ZERO)
	assert_eq(b.count, 1, "a zero-length frame must not kill a particle")
	b.free()


# ------------------------------------------------------------------- policy --

func test_shared_emitters_thin_out_as_sources_multiply() -> void:
	var one: float = LcnVfxIndustry.share_for(1)
	var many: float = LcnVfxIndustry.share_for(40)
	assert_true(one > 0.0, "one chimney must smoke")
	assert_true(many <= 1.0, "density is a ratio and must stay one")
	assert_true(many > one, "more chimneys means more of the shared buffer in use")
	assert_eq(LcnVfxIndustry.share_for(0), 0.0, "no sources, no emission")


func test_breath_is_gated_on_real_cold() -> void:
	assert_true(LcnVfxTuning.BREATH_START_C > LcnVfxTuning.BREATH_FULL_C,
		"breath must thicken as the air gets colder, not thinner")
	var mild: float = clampf(inverse_lerp(LcnVfxTuning.BREATH_START_C,
		LcnVfxTuning.BREATH_FULL_C, 12.0), 0.0, 1.0)
	var bitter: float = clampf(inverse_lerp(LcnVfxTuning.BREATH_START_C,
		LcnVfxTuning.BREATH_FULL_C, -30.0), 0.0, 1.0)
	assert_eq(mild, 0.0, "nobody steams on a mild day")
	assert_eq(bitter, 1.0, "everybody steams in a Great Frost")


func test_the_caps_are_actually_small() -> void:
	# A cap that is not a constraint is a comment. These numbers are the promise
	# that the layer cannot run away with the frame.
	assert_true(LcnVfxTuning.BURST_ADD_MAX <= 1024, "additive burst cap too generous")
	assert_true(LcnVfxTuning.BURST_MIX_MAX <= 1024, "mixed burst cap too generous")
	assert_true(LcnVfxTuning.POINTS_MAX <= 64, "emission point cap too generous")
	var snow: int = 0
	for spec: Dictionary in LcnVfxTuning.SNOW_LAYERS:
		snow += int(spec["amount"])
	assert_true(snow <= 1200, "snow buffer is %d particles, which is a budget not a look" % snow)


# ------------------------------------------------------------------- assets --

func test_the_particle_sheet_bakes_and_has_content() -> void:
	LcnArtCache.set_enabled(false)
	var sheet: ImageTexture = LcnVfxArt.atlas()
	LcnArtCache.set_enabled(true)
	assert_true(sheet != null, "no particle sheet baked")
	if sheet == null:
		return
	assert_eq(sheet.get_width(), LcnVfxArt.SHEET_W, "sheet width")
	assert_eq(sheet.get_height(), LcnVfxArt.SHEET_H, "sheet height")
	var img: Image = sheet.get_image()
	for pair: Array in [["dot", LcnVfxArt.R_DOT], ["puff", LcnVfxArt.R_PUFF],
			["chip", LcnVfxArt.R_CHIP], ["shard", LcnVfxArt.R_SHARD],
			["star", LcnVfxArt.R_STAR], ["ring", LcnVfxArt.R_RING],
			["splat", LcnVfxArt.R_SPLAT]]:
		var r: Rect2 = pair[1]
		var opaque: int = 0
		for y: int in range(int(r.position.y), int(r.position.y + r.size.y), 2):
			for x: int in range(int(r.position.x), int(r.position.x + r.size.x), 2):
				if img.get_pixel(x, y).a > 0.35:
					opaque += 1
		assert_true(opaque > 8, "region '%s' baked to nothing (%d solid px)" % [pair[0], opaque])


func test_single_textures_bake_for_every_gpu_emitter() -> void:
	LcnArtCache.set_enabled(false)
	for name: String in ["dot", "mote", "flake", "puff", "haze"]:
		var t: ImageTexture = LcnVfxArt.texture(name)
		assert_true(t != null and t.get_width() > 0, "texture '%s' did not bake" % name)
	LcnArtCache.set_enabled(true)

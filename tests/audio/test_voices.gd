extends TestCase
## [P23] The voice policy, driven with the traffic a real assault produces.
##
## The number that matters: the reference run fires 43 shots and spawns hundreds
## of bodies, and a harness frame can cover a thousand ticks. Every one of the
## five rules below exists because one of those numbers would otherwise become a
## voice count.

var _pool: LcnVoicePool = null
var _bank: LcnSoundBank = null
var _mixer: LcnAudioMixer = null


func suite_name() -> String:
	return "audio_voices"


func before_all() -> void:
	# The desk first: a cue naming a bus that does not exist would be routed to
	# Master, and the test proving cues land on the right bus would prove the
	# opposite of what it claims.
	_mixer = LcnAudioMixer.new()
	_mixer.install()
	_bank = LcnSoundBank.new()
	_bank.queue_all()
	var guard: int = 0
	while not _bank.finished() and guard < 20000:
		_bank.pump(20000)
		guard += 1


func after_all() -> void:
	if _mixer != null:
		_mixer.uninstall()
		_mixer = null


func setup() -> void:
	_pool = LcnVoicePool.new()
	var tree: SceneTree = TestEnv.tree()
	if tree != null and tree.root != null:
		tree.root.add_child(_pool)
	_pool.bind(_bank)
	_pool.begin_frame()


func teardown() -> void:
	if _pool != null:
		_pool.stop_all()
		_pool.queue_free()
		_pool = null


# --- allocation --------------------------------------------------------------

func test_a_cue_plays_and_lands_on_the_bus_its_recipe_names() -> void:
	var v: LcnVoicePool.Voice = _pool.play(&"turret_fire", Vector2(100, 100))
	assert_not_null(v, "the shot played")
	if v == null:
		return
	assert_true(v.busy, "the voice is in use")
	assert_eq(String(v.world.bus), String(LcnAudioDefs.BUS_COMBAT), "on the combat bus")
	assert_eq(v.category, &"combat", "in the combat category")
	assert_true(is_finite(v.world.volume_db), "at a finite gain")
	assert_gt(v.world.pitch_scale, 0.0, "and a positive pitch")


func test_an_unknown_cue_is_refused_without_a_fuss() -> void:
	assert_null(_pool.play(&"no_such_cue"), "unknown cue does nothing")
	assert_eq(_pool.started, 0, "and starts no voice")


func test_pitch_jitter_stays_inside_a_musical_range() -> void:
	for i: int in 40:
		_pool.begin_frame()
		var v: LcnVoicePool.Voice = _pool.play(&"turret_fire", Vector2(i * 500, 0))
		if v == null:
			continue
		assert_between(v.world.pitch_scale, 0.5, 2.0, "pitch stayed sane")


# --- rule 1: cull ------------------------------------------------------------

func test_a_sound_further_away_than_the_camera_can_see_is_never_allocated() -> void:
	_pool.has_listener = true
	_pool.listener = Vector2.ZERO
	_pool.audible_radius = 1000.0
	assert_not_null(_pool.play(&"turret_fire", Vector2(500, 0)), "near enough")
	assert_null(_pool.play(&"enemy_died", Vector2(9000, 0)), "far too far")
	assert_eq(_pool.culled_distance, 1, "and the cull was counted")


func test_culling_is_skipped_when_there_is_no_camera() -> void:
	_pool.has_listener = false
	assert_not_null(_pool.play(&"turret_fire", Vector2(9_000_000, 0)),
		"without a listener there is nothing to be far from")


# --- rule 2: coalesce --------------------------------------------------------

func test_a_volley_of_the_same_shot_becomes_one_louder_voice() -> void:
	var first: LcnVoicePool.Voice = _pool.play(&"turret_fire", Vector2(10, 10))
	assert_not_null(first)
	var opening_db: float = first.db
	for i: int in 6:
		var again: LcnVoicePool.Voice = _pool.play(&"turret_fire", Vector2(12, 10))
		assert_eq(again, first, "shot %d merged into the first" % i)
	assert_eq(_pool.started, 1, "one voice, not seven")
	assert_eq(_pool.coalesced, 6, "six merges")
	assert_gt(first.db, opening_db, "and the volley got louder")
	assert_le(first.db, float(LcnAudioDefs.CUES[&"turret_fire"]["db"])
		+ LcnAudioDefs.COALESCE_GAIN_MAX_DB + 0.001, "but only up to the ceiling")


func test_different_cues_never_merge() -> void:
	_pool.play(&"turret_fire", Vector2(10, 10))
	_pool.play(&"enemy_died", Vector2(10, 10))
	assert_eq(_pool.started, 2, "two different sounds are two voices")
	assert_eq(_pool.coalesced, 0, "nothing merged")


# --- rule 3: rate limit ------------------------------------------------------

func test_one_frame_cannot_start_more_than_the_frame_budget() -> void:
	# The harness pushes a thousand simulation ticks through a single frame.
	for i: int in 200:
		_pool.play(&"structure_hit", Vector2(i * 130, 0))
	assert_le(float(_pool.started), float(LcnAudioDefs.MAX_STARTS_PER_FRAME),
		"a frame started at most %d voices" % LcnAudioDefs.MAX_STARTS_PER_FRAME)
	assert_gt(float(_pool.rate_limited), 0.0, "and the refusals were counted")


func test_the_budget_refills_every_frame() -> void:
	for i: int in 50:
		_pool.play(&"structure_hit", Vector2(i * 130, 0))
	var after_one: int = _pool.started
	_pool.begin_frame()
	for i: int in 50:
		_pool.play(&"structure_hit", Vector2(9000 + i * 130, 0))
	assert_gt(float(_pool.started), float(after_one), "the next frame may start more")


# --- rule 4: caps ------------------------------------------------------------

func test_combat_cannot_spend_more_than_its_share_of_the_pool() -> void:
	var cap: int = int(LcnAudioDefs.CATEGORY_CAP[&"combat"])
	for frame: int in 12:
		_pool.begin_frame()
		for i: int in 6:
			_pool.play(&"structure_hit", Vector2(frame * 900 + i * 140, 0))
	var by_cat: Dictionary = _pool.active_by_category()
	assert_le(float(int(by_cat.get("combat", 0))), float(cap),
		"combat stayed inside its ceiling of %d" % cap)


func test_the_category_ceilings_sum_to_less_than_the_pool() -> void:
	# The arithmetic that makes "a big fight cannot starve the interface" true
	# rather than aspirational.
	var total: int = 0
	for k: StringName in LcnAudioDefs.CATEGORY_CAP:
		total += int(LcnAudioDefs.CATEGORY_CAP[k])
	assert_le(float(total), float(LcnAudioDefs.MAX_WORLD_VOICES + 8),
		"no category can crowd out the others")


func test_the_pool_never_grows_past_its_cap() -> void:
	for frame: int in 20:
		_pool.begin_frame()
		for i: int in 8:
			_pool.play(&"enemy_died", Vector2(frame * 700 + i * 90, i * 90))
	var r: Dictionary = _pool.report()
	assert_le(float(int(r["world_allocated"])), float(_pool.world_cap), "world pool capped")
	assert_le(float(int(r["flat_allocated"])), float(_pool.flat_cap), "flat pool capped")


# --- rule 5: stealing --------------------------------------------------------

func test_a_critical_cue_can_take_a_voice_from_furniture() -> void:
	_pool.world_cap = 3
	# Spread out beyond the coalescing radius, or these three are one voice and
	# the pool never fills up at all.
	for i: int in 3:
		_pool.begin_frame()
		_pool.play(&"enemy_hit", Vector2(i * 900, 0))      # priority AMBIENT
	assert_eq(_pool.started, 3, "three separate hits, three voices")
	_pool.begin_frame()
	var breach: LcnVoicePool.Voice = _pool.play(&"breach", Vector2(500, 500))
	assert_not_null(breach, "a breach is always heard")
	assert_gt(float(_pool.stolen), 0.0, "it took a voice from something quieter")


func test_furniture_cannot_take_a_voice_from_a_breach() -> void:
	_pool.world_cap = 2
	_pool.begin_frame()
	_pool.play(&"breach", Vector2(0, 0))
	_pool.begin_frame()
	_pool.play(&"big_one", Vector2(50, 0))
	var before: int = _pool.stolen
	_pool.begin_frame()
	var hit: LcnVoicePool.Voice = _pool.play(&"enemy_hit", Vector2(100, 0))
	assert_null(hit, "a footstep does not silence a breach")
	assert_eq(_pool.stolen, before, "and nothing was stolen")
	assert_gt(float(_pool.refused_cap), 0.0, "the refusal was counted")


# --- reporting ---------------------------------------------------------------

func test_the_report_accounts_for_every_request() -> void:
	_pool.has_listener = true
	_pool.listener = Vector2.ZERO
	_pool.audible_radius = 800.0
	for i: int in 30:
		_pool.play(&"turret_fire", Vector2(i * 400, 0))
	var r: Dictionary = _pool.report()
	var accounted: int = int(r["started"]) + int(r["coalesced"]) \
		+ int(r["culled_distance"]) + int(r["rate_limited"]) \
		+ int(r["refused_cap"]) + int(r["missing_stream"])
	assert_eq(accounted, 30, "every one of the 30 requests is in the report")
	assert_ge(float(int(r["peak_active"])), 0.0, "peak is tracked")

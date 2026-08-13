extends TestCase
## [P23] The synthesiser, against the whole catalogue.
##
## Three properties matter here and every one of them was a real bug first:
##
##   * **chunk invariance** — a stream rendered in one call must be byte-identical
##     to the same stream rendered in four hundred slices, because the bank
##     builds across frames and a sound that depends on frame timing is a sound
##     that is different on every machine.
##   * **no loop clicks** — the first bake had a seam three to four times the
##     size of the signal's own largest sample step on every sustained tonal
##     loop, caused by a filter starting from silence. A tick once every six
##     seconds is the most fatiguing thing an ambient bed can do, and it is
##     invisible to every test that only checks for NaN. This suite measures it.
##   * **finite output** — one NaN reaching AudioServer is an audible click on
##     every platform and an engine error on some.
##
## The whole catalogue is rendered once in before_all and shared, because two
## seconds of synthesis is worth paying once and not once per assertion.

const CHUNK: int = 997          ## deliberately not a power of two

var _built: Dictionary[StringName, LcnSynthJob] = {}


func suite_name() -> String:
	return "audio_synth"


func before_all() -> void:
	for key: StringName in LcnSynthRecipes.all():
		var job := LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
		while not job.advance(1 << 22):
			pass
		_built[key] = job


func _keys() -> Array[StringName]:
	var out: Array[StringName] = []
	for k: StringName in _built:
		out.append(k)
	out.sort()
	return out


# --- the catalogue itself ----------------------------------------------------

func test_the_catalogue_covers_every_cue_and_every_machine_family() -> void:
	var recipes: Dictionary = LcnSynthRecipes.all()
	assert_gt(float(recipes.size()), 30.0, "a catalogue, not a demo")
	for cue: StringName in LcnAudioDefs.CUES:
		var stream_key: StringName = LcnAudioDefs.CUES[cue].get("stream", &"")
		assert_true(recipes.has(stream_key),
			"cue '%s' names recipe '%s', which must exist" % [cue, stream_key])
	for family: StringName in LcnAudioDefs.FAMILY_PRIORITY:
		assert_true(recipes.has(StringName("mach_%s" % String(family))),
			"machine family '%s' must have a loop" % family)
	for stem: StringName in LcnMusicDirector.STEMS:
		assert_true(recipes.has(StringName("mus_%s" % String(stem))),
			"score stem '%s' must exist" % stem)


func test_every_machine_family_a_building_can_map_to_has_a_sound() -> void:
	for kind: StringName in LcnAudioDefs.KIND_FAMILY:
		var family: StringName = LcnAudioDefs.KIND_FAMILY[kind]
		assert_true(LcnSynthRecipes.has(StringName("mach_%s" % String(family))),
			"building '%s' maps to family '%s'" % [kind, family])
	for row: Array in LcnAudioDefs.TAG_FAMILY:
		assert_true(LcnSynthRecipes.has(StringName("mach_%s" % String(row[1]))),
			"tag '%s' maps to family '%s'" % [row[0], row[1]])


# --- correctness -------------------------------------------------------------

func test_every_recipe_produces_a_finite_playable_stream() -> void:
	for key: StringName in _keys():
		var job: LcnSynthJob = _built[key]
		assert_not_null(job.stream, "%s produced a stream" % key)
		if job.stream == null:
			continue
		assert_eq(job.non_finite, 0, "%s rendered no non-finite samples" % key)
		assert_gt(float(job.stream.data.size()), 0.0, "%s has audio in it" % key)
		assert_gt(job.stream.get_length(), 0.009, "%s is longer than a click" % key)
		assert_eq(job.stream.format, AudioStreamWAV.FORMAT_16_BITS, "%s is 16-bit" % key)


func test_nothing_is_silent_and_nothing_is_clipped() -> void:
	# A recipe that normalises to nothing is a recipe with a sign error in it,
	# and it would ship as a cue that plays and cannot be heard.
	for key: StringName in _keys():
		var job: LcnSynthJob = _built[key]
		if job.stream == null:
			continue
		var pcm: PackedByteArray = job.stream.data
		var peak: int = 0
		var energy: float = 0.0
		var n: int = pcm.size() / 2
		for i: int in n:
			var v: int = pcm.decode_s16(i * 2)
			peak = maxi(peak, absi(v))
			energy += float(v) * float(v)
		var rms: float = sqrt(energy / float(maxi(1, n))) / 32768.0
		assert_gt(float(peak) / 32768.0, 0.5, "%s is audible" % key)
		assert_lt(float(peak), 32768.0, "%s does not clip" % key)
		assert_gt(rms, 0.005, "%s has real energy, not one lonely spike" % key)


func test_a_recipe_renders_identically_however_it_is_sliced() -> void:
	# This is the property the whole across-frames bake rests on.
	for key: StringName in _keys():
		var chunked := LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
		var guard: int = 0
		while not chunked.advance(CHUNK) and guard < 100000:
			guard += 1
		assert_lt(float(guard), 100000.0, "%s finished in a sane number of slices" % key)
		assert_not_null(chunked.stream, "%s built in slices" % key)
		if chunked.stream == null:
			continue
		assert_eq(chunked.stream.data, _built[key].stream.data,
			"%s is byte-identical whether rendered whole or in %d-sample slices" % [key, CHUNK])


func test_the_deadline_driven_path_renders_the_same_bytes() -> void:
	# The bank does not use `advance(units)` — it uses `advance_until(clock)`, so
	# the sliced-render guarantee has to hold for THAT path or it guarantees
	# nothing about the shipping game. A 60 us deadline forces dozens of steps.
	for key: StringName in [&"hearth_bed", &"mus_hope", &"mach_press", &"sting_critical"]:
		var job := LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
		var guard: int = 0
		while not job.advance_until(Time.get_ticks_usec() + 60) and guard < 200000:
			guard += 1
		assert_lt(float(guard), 200000.0, "%s finished" % key)
		assert_eq(job.stream.data, _built[key].stream.data,
			"%s is byte-identical when rendered against a wall clock" % key)


func test_two_renders_of_the_same_recipe_are_identical() -> void:
	# Nothing in the synth may reach for Rng or the global random state.
	for key: StringName in [&"hearth_bed", &"mach_press", &"shot_light", &"mus_perc"]:
		assert_deterministic(func() -> PackedByteArray:
			var job := LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
			while not job.advance(1 << 22):
				pass
			return job.stream.data, "%s renders the same every time" % key)


# --- the thing that was actually broken --------------------------------------

func test_no_sustained_loop_clicks_at_its_loop_point() -> void:
	# The measurement, stated plainly: the step from the last sample of the loop
	# back to the first must not be dramatically larger than the steps the signal
	# already takes on its own. A bed whose seam is four times its own p99 step
	# ticks audibly once a cycle, which is exactly what the first bake did.
	#
	# Loops with a hit ON the downbeat are excluded: their first sample IS a
	# percussive attack, and a drum on the loop point is the sound rather than a
	# defect. Everything that is supposed to be continuous is measured.
	var measured: int = 0
	for key: StringName in _keys():
		var spec: Dictionary = LcnSynthRecipes.spec(key)
		if not bool(spec.get("loop", false)):
			continue
		if float(spec.get("bed", 1.0)) <= 0.0 or _hits_the_downbeat(spec):
			continue
		measured += 1
		var pcm: PackedByteArray = _built[key].stream.data
		var n: int = pcm.size() / 2
		if n < 64:
			continue
		var steps: Array[float] = []
		var prev: float = float(pcm.decode_s16(0))
		for i: int in range(1, n):
			var cur: float = float(pcm.decode_s16(i * 2))
			steps.append(absf(cur - prev))
			prev = cur
		steps.sort()
		var p99: float = steps[int(float(steps.size()) * 0.99)]
		var seam: float = absf(float(pcm.decode_s16(0)) - float(pcm.decode_s16((n - 1) * 2)))
		assert_lt(seam, maxf(p99 * 2.0, 400.0),
			"%s: loop seam %d must not tower over its own p99 step %d" % [key, int(seam), int(p99)])
	# Guards the guard: a filter on the exclusion rule that quietly matched
	# everything would turn this whole test into a pass by vacuum.
	assert_ge(float(measured), 10.0, "at least ten continuous loops were actually measured")


## Does this recipe put a transient exactly on the loop point?
func _hits_the_downbeat(spec: Dictionary) -> bool:
	for block: Dictionary in spec.get("events", []):
		for offset: Variant in block.get("offsets", []):
			if absf(float(offset)) < 0.001:
				return true
	return false


func test_a_looping_recipe_discards_a_run_up_and_a_one_shot_does_not() -> void:
	# A one-shot is SUPPOSED to start from silence; a loop must not.
	var loop_job: LcnSynthJob = _built[&"city_hum"]
	var loop_head: float = absf(float(loop_job.stream.data.decode_s16(0)))
	assert_gt(loop_head, 200.0, "a loop opens mid-signal, not from a standing start")

	var shot: LcnSynthJob = _built[&"shot_light"]
	assert_lt(absf(float(shot.stream.data.decode_s16(0))), 4000.0,
		"a one-shot opens at or near silence")


func test_a_hit_at_the_end_of_a_loop_rings_into_the_next_pass() -> void:
	# A rhythm whose last hit lands just before the loop point must not be cut
	# dead there. Asserted with a purpose-built recipe rather than by hoping one
	# of the shipped ones happens to straddle the boundary: an event at 0.98 of
	# the loop with a 0.4 s decay has three quarters of its tail past the end,
	# and that tail belongs at the head.
	var spec: Dictionary = {
		"engine": &"noise", "sr": 11025, "seconds": 1.0, "loop": true,
		"seed": 4242, "bed": 0.0,
		"events": [{"kind": &"thud", "offsets": [0.98], "hz": 90.0,
			"decay": 0.4, "amp": 0.9, "noise": 0.05}],
	}
	var job := LcnSynthJob.new(&"wrap_probe", spec)
	while not job.advance(1 << 22):
		pass
	var pcm: PackedByteArray = job.stream.data
	var n: int = pcm.size() / 2
	var head: float = 0.0
	for i: int in mini(n, 2000):
		head = maxf(head, absf(float(pcm.decode_s16(i * 2))))
	assert_gt(head, 1000.0, "the tail of the last hit wrapped onto the head of the loop")

	# ...and a one-shot must NOT wrap: a shell that rings back onto its own
	# attack is a shell that sounds like a loop.
	var once: Dictionary = spec.duplicate()
	once["loop"] = false
	var shot := LcnSynthJob.new(&"wrap_probe_once", once)
	while not shot.advance(1 << 22):
		pass
	var shot_head: float = 0.0
	for i: int in mini(shot.stream.data.size() / 2, 2000):
		shot_head = maxf(shot_head, absf(float(shot.stream.data.decode_s16(i * 2))))
	assert_lt(shot_head, 400.0, "a one-shot leaves its head alone")


func test_the_loop_flag_matches_the_recipe() -> void:
	for key: StringName in _keys():
		var spec: Dictionary = LcnSynthRecipes.spec(key)
		var want: bool = bool(spec.get("loop", false))
		var mode: int = _built[key].stream.loop_mode
		if want:
			assert_eq(mode, AudioStreamWAV.LOOP_FORWARD, "%s loops" % key)
			assert_eq(_built[key].stream.loop_end, _built[key].stream.data.size() / 2,
				"%s loops over its whole body" % key)
		else:
			assert_eq(mode, AudioStreamWAV.LOOP_DISABLED, "%s is a one-shot" % key)


# --- cost --------------------------------------------------------------------

func test_the_whole_catalogue_costs_seconds_not_minutes_and_megabytes_not_hundreds() -> void:
	var usec: int = 0
	var bytes: int = 0
	for key: StringName in _keys():
		usec += _built[key].build_usec
		bytes += _built[key].byte_size()
	assert_lt(float(usec) / 1000.0, 8000.0, "the whole bake stays under eight seconds")
	assert_lt(float(bytes) / 1048576.0, 12.0, "and under twelve megabytes resident")


func test_the_essentials_are_cheap_enough_to_bake_before_the_first_frame() -> void:
	var usec: int = 0
	for key: StringName in LcnSynthRecipes.essential():
		assert_true(LcnSynthRecipes.has(key), "essential '%s' exists" % key)
		var job := LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
		while not job.advance(1 << 22):
			pass
		usec += job.build_usec
	assert_lt(float(usec) / 1000.0, 20.0,
		"the synchronous part of the bake must not be a visible freeze")

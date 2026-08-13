extends TestCase
## [P23] The maths under the soundtrack.
##
## Everything here guards one rule: **a value that reaches a Godot audio
## property must be finite and in range.** A NaN in `volume_db`, a zero in
## `pitch_scale` or an over-Nyquist filter coefficient are all engine-level
## errors, and this part is judged on producing none of them. So the clamps are
## tested with the arguments that would actually break them, not with 0.5.


func suite_name() -> String:
	return "audio_dsp"


# --- gain --------------------------------------------------------------------

func test_a_silent_slider_is_our_silence_not_negative_infinity() -> void:
	# linear_to_db(0) is -INF and AudioServer complains about it. The whole
	# reason MIN_DB exists.
	assert_eq(LcnDsp.slider_db(0.0), LcnDsp.MIN_DB, "slider at zero")
	assert_true(is_finite(LcnDsp.slider_db(0.0)), "and it is finite")
	assert_eq(LcnDsp.gain_db(0.0), LcnDsp.MIN_DB, "gain of zero")
	assert_eq(LcnDsp.gain_db(-1.0), LcnDsp.MIN_DB, "gain of a negative")


func test_the_slider_is_monotonic_and_tops_out_at_unity() -> void:
	var last: float = -1000.0
	for i: int in 21:
		var db: float = LcnDsp.slider_db(float(i) / 20.0)
		assert_ge(db, last, "slider %d must not go backwards" % i)
		assert_le(db, LcnDsp.MAX_DB, "and never above the ceiling")
		last = db
	assert_near(LcnDsp.slider_db(1.0), 0.0, 0.001, "a full slider is unity gain")


func test_safe_replaces_every_value_that_would_be_an_engine_error() -> void:
	assert_eq(LcnDsp.safe(NAN, 1.0, 0.05, 4.0), 1.0, "NaN falls back")
	assert_eq(LcnDsp.safe(INF, 1.0, 0.05, 4.0), 1.0, "infinity falls back")
	assert_eq(LcnDsp.safe(-INF, 1.0, 0.05, 4.0), 1.0, "negative infinity falls back")
	assert_eq(LcnDsp.safe(9.0, 1.0, 0.05, 4.0), 4.0, "too high is clamped")
	assert_eq(LcnDsp.safe(0.0, 1.0, 0.05, 4.0), 0.05, "a zero pitch is clamped up")
	assert_eq(LcnDsp.safe(2.0, 1.0, 0.05, 4.0), 2.0, "a good value is untouched")


# --- filters -----------------------------------------------------------------

func test_filter_coefficients_stay_in_range_for_absurd_cutoffs() -> void:
	for sr: int in [11025, 22050, 44100]:
		for hz: float in [-500.0, 0.0, 1.0, 400.0, 9000.0, 1.0e9]:
			var a: float = LcnDsp.lp_coeff(hz, sr)
			assert_between(a, 0.0, 1.0, "lp_coeff(%f, %d)" % [hz, sr])
			assert_true(is_finite(a), "lp_coeff finite at %f" % hz)
			var f: float = LcnDsp.svf_f(hz, sr)
			assert_between(f, 0.0, 1.2, "svf_f(%f, %d)" % [hz, sr])
			assert_true(is_finite(f), "svf_f finite at %f" % hz)


func test_a_state_variable_filter_cannot_be_driven_unstable() -> void:
	# The failure mode this guards is a resonant sweep running off the top of
	# the band and turning a wind loop into a burst of NaN.
	var f: float = LcnDsp.svf_f(1.0e6, 22050)
	var q: float = LcnDsp.svf_q(0.01)
	var low: float = 0.0
	var band: float = 0.0
	for i: int in 4000:
		var x: float = sin(float(i) * 0.3)
		low += f * band
		band += f * (x - low - q * band)
	assert_true(is_finite(low) and is_finite(band), "the filter did not blow up")
	assert_lt(absf(low), 1000.0, "and it did not run away either")


# --- buffers -----------------------------------------------------------------

func test_normalise_leaves_a_silent_buffer_alone() -> void:
	var buf := PackedFloat32Array()
	buf.resize(64)
	buf.fill(0.0)
	assert_eq(LcnDsp.normalize_to(buf, 64, 0.9), 1.0, "silence is not amplified")
	assert_eq(LcnDsp.peak_of(buf, 64), 0.0, "and stays silent")


func test_normalise_hits_the_target_peak_exactly() -> void:
	var buf := PackedFloat32Array()
	buf.resize(100)
	for i: int in 100:
		buf[i] = sin(float(i) * 0.1) * 0.03
	LcnDsp.normalize_to(buf, 100, 0.89)
	assert_near(LcnDsp.peak_of(buf, 100), 0.89, 0.001, "peak after normalising")


func test_sanitize_scrubs_every_non_finite_sample_and_counts_them() -> void:
	var buf := PackedFloat32Array()
	buf.resize(6)
	buf[0] = NAN
	buf[1] = INF
	buf[2] = -INF
	buf[3] = 5.0
	buf[4] = -5.0
	buf[5] = 0.25
	assert_eq(LcnDsp.sanitize(buf, 6), 3, "three non-finite samples")
	assert_eq(buf[0], 0.0, "NaN became silence")
	assert_eq(buf[3], 1.0, "over-range clamped")
	assert_eq(buf[4], -1.0, "under-range clamped")
	assert_eq(buf[5], 0.25, "a good sample survived")


func test_a_crossfade_makes_the_head_continuous_with_the_tail() -> void:
	# body of 100 with 20 samples of overrun; the overrun is the natural
	# continuation, so after folding, sample 0 must equal sample `body`.
	var buf := PackedFloat32Array()
	buf.resize(120)
	for i: int in 120:
		buf[i] = float(i)
	LcnDsp.crossfade_loop(buf, 100, 20)
	assert_near(buf[0], 100.0, 0.001, "the head became the continuation of the tail")
	assert_near(buf[19], 19.0 * 0.95 + 119.0 * 0.05, 0.01, "and it is a ramp, not a cut")
	assert_eq(buf[50], 50.0, "the middle is untouched")


func test_a_crossfade_honours_a_start_offset() -> void:
	# The pre-roll fix depends on this: the body does not begin at sample zero.
	var buf := PackedFloat32Array()
	buf.resize(140)
	for i: int in 140:
		buf[i] = float(i)
	LcnDsp.crossfade_loop(buf, 100, 20, 20)
	assert_near(buf[20], 120.0, 0.001, "the body head folded from the body tail")
	assert_eq(buf[10], 10.0, "the discarded run-up is untouched")


func test_crossfade_refuses_a_buffer_that_is_too_short() -> void:
	var buf := PackedFloat32Array()
	buf.resize(10)
	buf.fill(1.0)
	LcnDsp.crossfade_loop(buf, 100, 20)     # must not crash or index out of range
	assert_eq(buf[0], 1.0, "left alone rather than corrupted")


# --- encoding ----------------------------------------------------------------

func test_pcm_encoding_is_lossless_within_a_quantisation_step() -> void:
	var buf := PackedFloat32Array()
	buf.resize(256)
	for i: int in 256:
		buf[i] = sin(float(i) * 0.05) * 0.9
	var pcm: PackedByteArray = LcnDsp.pcm16(buf, 256)
	assert_eq(pcm.size(), 512, "two bytes a sample")
	var worst: float = 0.0
	for i: int in 256:
		var back: float = float(pcm.decode_s16(i * 2)) / 32767.0
		worst = maxf(worst, absf(back - buf[i]))
	assert_lt(worst, 1.0 / 32000.0, "round trip is within one step")


func test_pcm_clamps_instead_of_wrapping() -> void:
	# A sample over 1.0 that wraps becomes a full-scale sign flip, which is the
	# loudest possible click. It must clamp.
	var buf := PackedFloat32Array()
	buf.resize(2)
	buf[0] = 4.0
	buf[1] = -4.0
	var pcm: PackedByteArray = LcnDsp.pcm16(buf, 2)
	assert_eq(pcm.decode_s16(0), 32767, "positive clipped, not wrapped")
	assert_eq(pcm.decode_s16(2), -32767, "negative clipped, not wrapped")


func test_a_looping_stream_declares_a_loop_over_its_whole_body() -> void:
	var buf := PackedFloat32Array()
	buf.resize(1000)
	buf.fill(0.1)
	var w: AudioStreamWAV = LcnDsp.to_wav(buf, 1000, 22050, true)
	assert_eq(w.loop_mode, AudioStreamWAV.LOOP_FORWARD, "loop mode")
	assert_eq(w.loop_begin, 0, "loop begins at the top")
	assert_eq(w.loop_end, 1000, "and ends at the last sample")
	assert_eq(w.mix_rate, 22050, "sample rate survived")
	assert_false(w.stereo, "mono")
	assert_near(w.get_length(), 1000.0 / 22050.0, 0.001, "length")

	var one: AudioStreamWAV = LcnDsp.to_wav(buf, 1000, 22050, false)
	assert_eq(one.loop_mode, AudioStreamWAV.LOOP_DISABLED, "a one-shot does not loop")


# --- pitch -------------------------------------------------------------------

func test_snapping_makes_a_tone_fit_the_loop_a_whole_number_of_times() -> void:
	for hz: float in [36.708, 73.416, 110.0, 220.7]:
		for secs: float in [6.0, 8.0, 9.6]:
			var snapped: float = LcnDsp.snap_to_loop(hz, secs)
			var cycles: float = snapped * secs
			assert_near(cycles, round(cycles), 0.0001,
				"%f Hz over %f s is a whole number of cycles" % [hz, secs])
			assert_lt(absf(snapped - hz) / hz, 0.02, "and it moved less than 2%")


func test_semitones_are_a_ratio_and_stay_sane_at_the_extremes() -> void:
	assert_near(LcnDsp.semitones(0.0), 1.0, 0.0001, "no shift")
	assert_near(LcnDsp.semitones(12.0), 2.0, 0.0001, "an octave up")
	assert_near(LcnDsp.semitones(-12.0), 0.5, 0.0001, "an octave down")
	assert_true(is_finite(LcnDsp.semitones(1.0e9)), "an absurd shift is still finite")


func test_note_frequencies_are_concert_pitch() -> void:
	assert_near(LcnDsp.note_hz(69.0), 440.0, 0.01, "A4")
	assert_near(LcnDsp.note_hz(62.0), 293.66, 0.05, "D4 — the key the game is in")

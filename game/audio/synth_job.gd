class_name LcnSynthJob
extends RefCounted
## [P23] Renders one recipe from [LcnSynthRecipes] into an AudioStreamWAV,
## **a slice at a time**.
##
## The whole catalogue is a bit under a second of GDScript. Doing that in one
## call would be a one-second freeze on the frame the game starts, so a job is a
## resumable state machine instead: `advance(n)` renders at most n samples of
## work and returns whether it finished. [LcnSoundBank] gives every frame a
## budget in microseconds and the bake finishes over the first couple of seconds
## without ever costing a dropped frame.
##
## Chunking is only safe because state is explicit. Filters, phases and the
## noise generator live in fields, are copied into locals for the inner loop and
## written back at the end of every slice, so a buffer rendered in one call is
## bit-identical to the same buffer rendered in four hundred. `tests/audio/
## test_synth.gd` asserts exactly that, because "it sounds the same" is not a
## test.
##
## Phases, in order:
##   0 CONTINUOUS  the bed — noise or partials, one slice at a time
##   1 SEAM        fold the overrun back over the head so the loop has no tick
##   2 EVENTS      transients written on top, wrapping around the loop point
##   3 SCRUB       sanitise and measure the peak, one slice at a time
##   4 ENCODE      normalise and write 16-bit PCM, one slice at a time
##
## SCRUB and ENCODE are chunked for the same reason everything else is. They
## were one atomic `_finish()` at first, three passes over the buffer with no
## budget check in them, and on a 9.6 s music stem that single call cost 30 ms —
## a dropped frame, produced by the very mechanism that exists to prevent one.
##
## Nothing in here touches the scene tree, the clock, Rng or Settings. It is
## pure arithmetic, which is why the sound of the game cannot desync a replay.

enum Phase { CONTINUOUS, SEAM, EVENTS, SCRUB, ENCODE, DONE }

var key: StringName = &""
var stream: AudioStreamWAV = null
var done: bool = false
var build_usec: int = 0
var non_finite: int = 0

## Total samples of work this job represents. Used for progress reporting only.
var work_total: int = 0
var work_done: int = 0

var _spec: Dictionary = {}
var _sr: int = LcnDsp.SR_MID
var _body: int = 0                 ## samples in the finished stream
var _xfade: int = 0
## Samples rendered BEFORE the loop body and then thrown away. A filter starts
## from silence, so the first ~50 ms of any rendered bed is a fade-in that the
## settled tail does not match — which is a click at the loop point, once every
## six seconds, forever. Measured on the first bake: the four sustained tonal
## loops all had a seam three to four times the size of their own largest
## sample-to-sample step. Rendering a quarter of a second of run-up and cutting
## it off costs a few per cent of build time and removes the click entirely.
var _pre: int = 0
var _render_len: int = 0           ## pre + body + xfade
var _loop: bool = false
var _gain: float = 1.0
var _bed: float = 1.0
var _engine: StringName = &"noise"

var _buf: PackedFloat32Array = PackedFloat32Array()
var _phase: int = Phase.CONTINUOUS
var _cursor: int = 0
var _events: Array[Dictionary] = []
var _event_index: int = 0
var _ev_i: int = 0
var _ev_env: float = 1.0
var _ev_ph: float = 0.0
var _ev_ph2: float = 0.0
var _ev_ph3: float = 0.0
var _ev_ph4: float = 0.0
var _ev_lp: float = 0.0
var _ev_bp_low: float = 0.0
var _ev_bp_band: float = 0.0
var _ev_f: float = 0.0
var _ev_dec: float = 1.0
var _ev_lp_a: float = 0.0
var _ev_bf: float = 0.0
var _ev_drop: float = 1.0
var _ev_rng: RandomNumberGenerator = null
var _tail_cursor: int = 0
var _peak: float = 0.0
var _norm: float = 1.0
var _pcm: PackedByteArray = PackedByteArray()

# --- continuous state, carried across slices ---------------------------------
var _rng: RandomNumberGenerator = null
var _brown: float = 0.0
var _lp_a: float = 0.0
var _lp_b: float = 0.0
var _hp: float = 0.0
var _svf_low: float = 0.0
var _svf_band: float = 0.0
var _bp_low: float = 0.0
var _bp_band: float = 0.0
var _sub_ph: float = 0.0
## 64-bit ON PURPOSE. These are the only fields written by the inner loop AND
## carried across a chunk boundary. Held as PackedFloat32Array they were rounded
## to single precision once per slice and left untouched inside a slice, so the
## same recipe rendered whole and rendered in 997-sample slices diverged — which
## is precisely the property the across-frames bake depends on.
var _am_ph: PackedFloat64Array = PackedFloat64Array()
var _bp_ph: PackedFloat64Array = PackedFloat64Array()
var _osc_ph: PackedFloat64Array = PackedFloat64Array()

# --- precomputed recipe terms ------------------------------------------------
var _brown_mix: float = 0.0
var _hp_a: float = 0.0
var _lp_a0: float = 1.0
var _lp_a1: float = 1.0
var _lp_svf: bool = false
var _lp_f0: float = 0.5
var _lp_f1: float = 0.5
var _lp_qd: float = 1.0
var _bp_mix: float = 0.0
var _bp_hz: float = 400.0
var _bp_qd: float = 1.0
var _bp_lfo: Array = []
var _sub_inc: float = 0.0
var _sub_amt: float = 0.0
var _am: Array = []
var _base0: float = 0.0
var _base_step: float = 0.0
var _mult: PackedFloat32Array = PackedFloat32Array()
var _amp: PackedFloat32Array = PackedFloat32Array()
var _wave: PackedInt32Array = PackedInt32Array()
var _noise_amt: float = 0.0
var _attack: int = 0
var _decay: int = 0
var _has_env: bool = false


func _init(recipe_key: StringName, spec: Dictionary) -> void:
	key = recipe_key
	_spec = spec
	_prepare()


# ================================================================== driving ==

## Work units per step of the deadline-driven path. Small enough that one
## uninterruptible step of the SLOWEST phase — five detuned partials, about 0.4
## samples per microsecond — still lands under a millisecond.
const STEP_UNITS: int = 256

## Renders up to `budget` units of work. Used by the tests and by the offline
## baker, where a wall clock is not the right unit.
func advance(budget: int) -> bool:
	if done:
		return true
	var t0: int = Time.get_ticks_usec()
	var left: int = maxi(1, budget)
	while left > 0 and not done:
		left -= _step(left)
	build_usec += Time.get_ticks_usec() - t0
	return done


## Renders until the wall clock passes `deadline_usec`, then stops. This is what
## the bank uses every frame.
##
## Two earlier versions tried to PREDICT how many samples fit in a millisecond —
## first from a benchmark constant, then from a measured, self-tuning rate — and
## both produced a dropped frame. The reason is the same both times: the phases
## of a job differ in cost by more than an order of magnitude, so any single
## figure learned from the fast ones is catastrophically wrong for the slow ones.
## The estimate reached 16 384 units while encoding and then handed that to a
## partial bank, which is how a 4 ms budget became a 40 ms frame.
##
## Nothing is predicted any more. Take a small step, look at the clock, decide
## again. It cannot be wrong on a slow machine, a fast one, or a phase nobody
## has written yet.
func advance_until(deadline_usec: int) -> bool:
	if done:
		return true
	var t0: int = Time.get_ticks_usec()
	while not done:
		_step(STEP_UNITS)
		if Time.get_ticks_usec() >= deadline_usec:
			break
	build_usec += Time.get_ticks_usec() - t0
	return done


## One step of whatever phase the job is in. Returns the units it consumed.
func _step(units: int) -> int:
	match _phase:
		Phase.CONTINUOUS:
			return _do_continuous(units)
		Phase.SEAM:
			LcnDsp.crossfade_loop(_buf, _body, _xfade, _pre)
			_phase = Phase.EVENTS
			return maxi(1, _xfade)
		Phase.EVENTS:
			return _do_events(units)
		Phase.SCRUB:
			return _do_scrub(units)
		Phase.ENCODE:
			return _do_encode(units)
	done = true
	return 1


func progress() -> float:
	if work_total <= 0:
		return 1.0
	return clampf(float(work_done) / float(work_total), 0.0, 1.0)


# ================================================================ preparing ==

func _prepare() -> void:
	_sr = maxi(4000, int(_spec.get("sr", LcnDsp.SR_MID)))
	_loop = bool(_spec.get("loop", false))
	_gain = float(_spec.get("gain", 1.0))
	_bed = float(_spec.get("bed", 1.0))
	_engine = StringName(_spec.get("engine", &"noise"))
	var seconds: float = maxf(0.01, float(_spec.get("seconds", 1.0)))
	_body = maxi(16, int(round(seconds * float(_sr))))
	_xfade = int(round(float(_spec.get("xfade", 0.0)) * float(_sr))) if _loop else 0
	_xfade = clampi(_xfade, 0, _body / 2)
	# Only a loop with a bed needs the run-up: a one-shot is SUPPOSED to start
	# from silence, and an event-only loop has no filter state to settle.
	var wants_pre: bool = _loop and float(_spec.get("bed", 1.0)) > 0.0
	_pre = mini(int(0.25 * float(_sr)), _body / 4) if wants_pre else 0
	_render_len = _pre + _body + _xfade
	_buf = PackedFloat32Array()
	_buf.resize(_render_len)
	_buf.fill(0.0)

	_rng = RandomNumberGenerator.new()
	_rng.seed = int(_spec.get("seed", 1))

	# --- shared filter / modulation terms ---
	_brown_mix = clampf(float(_spec.get("brown", 0.0)), 0.0, 1.0)
	var hp_hz: float = float(_spec.get("hp_hz", 0.0))
	_hp_a = LcnDsp.lp_coeff(hp_hz, _sr) if hp_hz > 0.0 else 0.0

	var lp0: float = float(_spec.get("lp_hz", float(_sr) * 0.45))
	var lp1: float = float(_spec.get("lp_hz_end", lp0))
	var lp_q: float = float(_spec.get("lp_q", 1.0))
	# A resonant lowpass is worth a two-pole state-variable filter, but that
	# filter only stays stable well below Nyquist. Above that the cascade of two
	# one-poles is used instead: no resonance, unconditionally stable, and the
	# only sounds that ask for a cutoff that high are noise bursts that would not
	# have shown a resonant peak anyway.
	_lp_svf = lp_q >= 1.5 and maxf(lp0, lp1) < float(_sr) * 0.10
	if _lp_svf:
		_lp_f0 = LcnDsp.svf_f(lp0, _sr)
		_lp_f1 = LcnDsp.svf_f(lp1, _sr)
		_lp_qd = LcnDsp.svf_q(lp_q)
	else:
		_lp_a0 = LcnDsp.lp_coeff(lp0, _sr)
		_lp_a1 = LcnDsp.lp_coeff(lp1, _sr)

	_bp_mix = clampf(float(_spec.get("bp_mix", 0.0)), 0.0, 1.0)
	_bp_hz = float(_spec.get("bp_hz", 400.0))
	_bp_qd = LcnDsp.svf_q(float(_spec.get("bp_q", 1.0)))
	_bp_lfo = _snap_rates(_spec.get("bp_lfo", []), seconds)
	_bp_ph = PackedFloat64Array()
	_bp_ph.resize(maxi(1, _bp_lfo.size()))
	_bp_ph.fill(0.0)

	var sub_hz: float = float(_spec.get("sub_hz", 0.0))
	_sub_amt = float(_spec.get("sub_amt", 0.0))
	if _loop and sub_hz > 0.0:
		sub_hz = LcnDsp.snap_to_loop(sub_hz, seconds)
	_sub_inc = sub_hz / float(_sr)

	# Every modulator has to complete a whole number of cycles over the body too,
	# or the loop point lands mid-swell and the bed breathes with a stutter in it.
	_am = _snap_rates(_spec.get("am", []), seconds)
	_am_ph = PackedFloat64Array()
	_am_ph.resize(maxi(1, _am.size()))
	_am_ph.fill(0.0)

	# --- tonal terms ---
	var base: float = float(_spec.get("base_hz", 110.0))
	var base_end: float = float(_spec.get("base_hz_end", base))
	_base0 = base
	_base_step = (base_end - base) / float(maxi(1, _render_len))
	var partials: Array = _spec.get("partials", [1.0])
	var amps: Array = _spec.get("amps", [])
	var waves: Array = _spec.get("waves", [])
	var detune: float = float(_spec.get("detune", 0.0))
	var n: int = mini(partials.size(), 6)
	_mult.resize(n)
	_amp.resize(n)
	_wave.resize(n)
	_osc_ph = PackedFloat64Array()
	_osc_ph.resize(maxi(1, n))
	_osc_ph.fill(0.0)
	for i: int in n:
		var m: float = float(partials[i])
		if detune != 0.0:
			m *= 1.0 + (detune / 1200.0) * (1.0 if i % 2 == 0 else -1.0)
		# A loop whose partials do not each complete a whole number of cycles
		# clicks once per loop, forever. Snapping is free and the pitch error is
		# under a cent at these lengths.
		if _loop and base_end == base:
			m = LcnDsp.snap_to_loop(base * m, seconds) / maxf(0.001, base)
		_mult[i] = m / float(_sr)
		_amp[i] = float(amps[i]) if i < amps.size() else 0.3
		_wave[i] = int(waves[i]) if i < waves.size() else 0
	_noise_amt = float(_spec.get("noise_amt", 0.0))

	_attack = int(round(float(_spec.get("attack", 0.0)) * float(_sr)))
	_decay = int(round(float(_spec.get("decay", 0.0)) * float(_sr)))
	_has_env = _decay > 0

	# --- events ---
	_events = _plan_events(seconds)

	work_total = (_render_len if _bed > 0.0 else 0) + _xfade + _body * 2
	for e: Dictionary in _events:
		work_total += int(e["len"])
	work_total = maxi(1, work_total)

	if _bed <= 0.0:
		# No bed: skip straight past the continuous pass and its seam.
		_phase = Phase.EVENTS if not _events.is_empty() else Phase.SCRUB


## [[hz, depth], ...] with every rate snapped to the loop grid. A no-op when the
## recipe is not a loop.
func _snap_rates(rows: Array, seconds: float) -> Array:
	if not _loop or rows.is_empty():
		return rows
	var out: Array = []
	for row: Array in rows:
		out.append([LcnDsp.snap_to_loop(float(row[0]), seconds), float(row[1])])
	return out


## Turns every event block into a flat, pre-rolled list. Each event carries its
## own seed, so the order they are rendered in cannot change what they sound
## like — which is what lets the renderer stop and resume between any two.
func _plan_events(seconds: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var blocks: Array = _spec.get("events", [])
	var serial: int = 0
	for bi: int in blocks.size():
		var b: Dictionary = blocks[bi]
		var kind: StringName = StringName(b.get("kind", &"click"))
		var decay: float = maxf(0.004, float(b.get("decay", 0.1)))
		var length: int = maxi(8, int(round(decay * 1.6 * float(_sr))))
		var offsets: Array = b.get("offsets", [])
		var times: Array[float] = []
		if not offsets.is_empty():
			for o: Variant in offsets:
				times.append(float(o))
		else:
			var count: int = maxi(0, int(b.get("count", 0)))
			for i: int in count:
				# Evenly spread, then jittered, so a crackle bed is irregular
				# without ever clumping into a machine-gun.
				var base_t: float = (float(i) + 0.5) / float(maxi(1, count)) * seconds
				times.append(base_t + (_rng.randf() - 0.5) * seconds / float(maxi(1, count)) * 0.9)
		var jitter: float = float(b.get("jitter", 0.0))
		for t: float in times:
			var at: float = t + (_rng.randf() - 0.5) * 2.0 * jitter
			var hz: float = float(b.get("hz", 200.0)) \
				+ (_rng.randf() - 0.5) * 2.0 * float(b.get("hz_spread", 0.0))
			var amp: float = float(b.get("amp", 0.5)) \
				+ (_rng.randf() - 0.5) * 2.0 * float(b.get("amp_spread", 0.0))
			serial += 1
			out.append({
				"kind": kind,
				"at": int(round(at * float(_sr))),
				"len": length,
				"hz": maxf(12.0, hz),
				"decay": decay,
				"amp": clampf(amp, 0.0, 1.5),
				"noise": clampf(float(b.get("noise", 0.3)), 0.0, 1.0),
				"seed": int(_spec.get("seed", 1)) * 7919 + serial,
			})
	return out


# ============================================================== continuous ==

func _do_continuous(budget: int) -> int:
	var to: int = mini(_render_len, _cursor + budget)
	var spent: int = to - _cursor
	if spent <= 0:
		_phase = Phase.SEAM if _xfade > 0 else Phase.EVENTS
		if _events.is_empty() and _phase == Phase.EVENTS:
			_phase = Phase.SCRUB
		return 1
	if _engine == &"tonal":
		_render_tonal(_cursor, to)
	else:
		_render_noise(_cursor, to)
	work_done += spent
	_cursor = to
	if _cursor >= _render_len:
		_phase = Phase.SEAM if _xfade > 0 else Phase.EVENTS
		if _events.is_empty() and _phase == Phase.EVENTS:
			_phase = Phase.SCRUB
	return spent


## Noise bed: white/brown through a highpass, a lowpass, a resonant band and a
## sine sub, amplitude-modulated by up to two LFOs. Fire, wind, roar, breath.
func _render_noise(from: int, to: int) -> void:
	# Hoisted into locals: a field read per sample is roughly a third of the
	# cost of this loop, and this loop is the whole build time of the part.
	var rng: RandomNumberGenerator = _rng
	var brown: float = _brown
	var brown_mix: float = _brown_mix
	var hp_a: float = _hp_a
	var hp: float = _hp
	var lp_svf: bool = _lp_svf
	var lp_a: float = _lp_a
	var lp_b: float = _lp_b
	var svf_low: float = _svf_low
	var svf_band: float = _svf_band
	# The band gets its OWN state. Sharing one filter's registers between the
	# lowpass and the bandpass stage is a latent cross-modulation that no recipe
	# currently triggers and every future one would.
	var bp_low: float = _bp_low
	var bp_band: float = _bp_band
	var bp_mix: float = _bp_mix
	var bp_qd: float = _bp_qd
	var sub_ph: float = _sub_ph
	var sub_inc: float = _sub_inc
	var sub_amt: float = _sub_amt
	var bed: float = _bed
	var total: float = float(maxi(1, _render_len))
	var inv_sr: float = 1.0 / float(_sr)
	var nyq: float = float(_sr) * LcnDsp.SVF_MAX_RATIO

	var n_am: int = _am.size()
	var am_hz0: float = float(_am[0][0]) * inv_sr if n_am > 0 else 0.0
	var am_d0: float = float(_am[0][1]) if n_am > 0 else 0.0
	var am_hz1: float = float(_am[1][0]) * inv_sr if n_am > 1 else 0.0
	var am_d1: float = float(_am[1][1]) if n_am > 1 else 0.0
	var am_p0: float = _am_ph[0] if _am_ph.size() > 0 else 0.0
	var am_p1: float = _am_ph[1] if _am_ph.size() > 1 else 0.0

	var n_bl: int = _bp_lfo.size()
	var bl_hz0: float = float(_bp_lfo[0][0]) * inv_sr if n_bl > 0 else 0.0
	var bl_a0: float = float(_bp_lfo[0][1]) if n_bl > 0 else 0.0
	var bl_hz1: float = float(_bp_lfo[1][0]) * inv_sr if n_bl > 1 else 0.0
	var bl_a1: float = float(_bp_lfo[1][1]) if n_bl > 1 else 0.0
	var bl_p0: float = _bp_ph[0] if _bp_ph.size() > 0 else 0.0
	var bl_p1: float = _bp_ph[1] if _bp_ph.size() > 1 else 0.0

	for i: int in range(from, to):
		var t: float = float(i) / total
		var white: float = rng.randf() * 2.0 - 1.0
		brown = brown * 0.994 + white * 0.06
		var x: float = white + (brown * 6.0 - white) * brown_mix

		if hp_a > 0.0:
			hp += (x - hp) * hp_a
			x -= hp

		if lp_svf:
			var f: float = _lp_f0 + (_lp_f1 - _lp_f0) * t
			svf_low += f * svf_band
			svf_band += f * (x - svf_low - _lp_qd * svf_band)
			x = svf_low
		else:
			var a: float = _lp_a0 + (_lp_a1 - _lp_a0) * t
			lp_a += (x - lp_a) * a
			lp_b += (lp_a - lp_b) * a
			x = lp_b

		if bp_mix > 0.0:
			var cut: float = _bp_hz
			if n_bl > 0:
				bl_p0 += bl_hz0
				if bl_p0 >= 1.0:
					bl_p0 -= 1.0
				cut *= 1.0 + bl_a0 * sin(bl_p0 * TAU)
			if n_bl > 1:
				bl_p1 += bl_hz1
				if bl_p1 >= 1.0:
					bl_p1 -= 1.0
				cut *= 1.0 + bl_a1 * sin(bl_p1 * TAU)
			var bf: float = clampf(TAU * minf(cut, nyq) * inv_sr, 0.001, LcnDsp.SVF_MAX_F)
			bp_low += bf * bp_band
			bp_band += bf * (x - bp_low - bp_qd * bp_band)
			x = x * (1.0 - bp_mix) + bp_band * bp_mix * 2.2

		if sub_amt > 0.0:
			sub_ph += sub_inc
			if sub_ph >= 1.0:
				sub_ph -= 1.0
			x += sin(sub_ph * TAU) * sub_amt

		if n_am > 0:
			am_p0 += am_hz0
			if am_p0 >= 1.0:
				am_p0 -= 1.0
			x *= 1.0 - am_d0 + am_d0 * (0.5 + 0.5 * sin(am_p0 * TAU))
		if n_am > 1:
			am_p1 += am_hz1
			if am_p1 >= 1.0:
				am_p1 -= 1.0
			x *= 1.0 - am_d1 + am_d1 * (0.5 + 0.5 * sin(am_p1 * TAU))

		if _has_env:
			x *= LcnDsp.env_ad(i, _render_len, _attack, _decay)

		_buf[i] += x * bed

	_brown = brown
	_hp = hp
	_lp_a = lp_a
	_lp_b = lp_b
	_svf_low = svf_low
	_svf_band = svf_band
	_bp_low = bp_low
	_bp_band = bp_band
	_sub_ph = sub_ph
	if _am_ph.size() > 0:
		_am_ph[0] = am_p0
	if _am_ph.size() > 1:
		_am_ph[1] = am_p1
	if _bp_ph.size() > 0:
		_bp_ph[0] = bl_p0
	if _bp_ph.size() > 1:
		_bp_ph[1] = bl_p1


## Partial bank: up to six oscillators through the same filter chain, with an
## optional glide. Drones, creature calls, stings, the score.
func _render_tonal(from: int, to: int) -> void:
	var rng: RandomNumberGenerator = _rng
	var np: int = _mult.size()
	var lp_svf: bool = _lp_svf
	var lp_a: float = _lp_a
	var lp_b: float = _lp_b
	var svf_low: float = _svf_low
	var svf_band: float = _svf_band
	var noise_amt: float = _noise_amt
	var bed: float = _bed
	var total: float = float(maxi(1, _render_len))

	var n_am: int = _am.size()
	var inv_sr: float = 1.0 / float(_sr)
	var am_hz0: float = float(_am[0][0]) * inv_sr if n_am > 0 else 0.0
	var am_d0: float = float(_am[0][1]) if n_am > 0 else 0.0
	var am_p0: float = _am_ph[0] if _am_ph.size() > 0 else 0.0

	for i: int in range(from, to):
		var t: float = float(i) / total
		var base: float = _base0 + _base_step * float(i)
		var x: float = 0.0
		for k: int in np:
			var p: float = _osc_ph[k] + base * _mult[k]
			if p >= 1.0:
				p -= float(int(p))
			_osc_ph[k] = p
			var v: float = 0.0
			match _wave[k]:
				1:
					v = p * 2.0 - 1.0
				2:
					v = 1.0 if p < 0.5 else -1.0
				3:
					v = 4.0 * absf(p - 0.5) - 1.0
				_:
					v = sin(p * TAU)
			x += v * _amp[k]
		if noise_amt > 0.0:
			x += (rng.randf() * 2.0 - 1.0) * noise_amt

		if lp_svf:
			var f: float = _lp_f0 + (_lp_f1 - _lp_f0) * t
			svf_low += f * svf_band
			svf_band += f * (x - svf_low - _lp_qd * svf_band)
			x = svf_low
		else:
			var a: float = _lp_a0 + (_lp_a1 - _lp_a0) * t
			lp_a += (x - lp_a) * a
			lp_b += (lp_a - lp_b) * a
			x = lp_b

		if n_am > 0:
			am_p0 += am_hz0
			if am_p0 >= 1.0:
				am_p0 -= 1.0
			x *= 1.0 - am_d0 + am_d0 * (0.5 + 0.5 * sin(am_p0 * TAU))

		if _has_env:
			x *= LcnDsp.env_ad(i, _render_len, _attack, _decay)

		_buf[i] += x * bed

	_lp_a = lp_a
	_lp_b = lp_b
	_svf_low = svf_low
	_svf_band = svf_band
	if _am_ph.size() > 0:
		_am_ph[0] = am_p0


# =================================================================== events ==

func _do_events(budget: int) -> int:
	var spent: int = 0
	while _event_index < _events.size() and spent < budget:
		var e: Dictionary = _events[_event_index]
		var length: int = int(e["len"])
		if _ev_i == 0:
			_begin_event(e)
		var count: int = mini(length - _ev_i, budget - spent)
		if count > 0:
			_render_event_slice(e, count)
			spent += count
			work_done += count
			_ev_i += count
		if _ev_i >= length:
			_ev_i = 0
			_event_index += 1
	if _event_index >= _events.size():
		_phase = Phase.SCRUB
	return maxi(1, spent)


## Sets up one transient's running state. Split from the render so a long event
## can be produced across several slices: a single bell partial is 15 876
## samples, which is six milliseconds of GDScript, and rendering it atomically
## made one frame cost 17 ms inside a 4 ms budget.
func _begin_event(e: Dictionary) -> void:
	_ev_rng = RandomNumberGenerator.new()
	_ev_rng.seed = int(e["seed"])
	_ev_env = 1.0
	_ev_ph = 0.0
	_ev_ph2 = 0.0
	_ev_ph3 = 0.0
	_ev_ph4 = 0.0
	_ev_lp = 0.0
	_ev_bp_low = 0.0
	_ev_bp_band = 0.0
	var hz: float = float(e["hz"])
	_ev_f = hz / float(_sr)
	_ev_dec = LcnDsp.decay_per_sample(float(e["decay"]), _sr)
	_ev_lp_a = LcnDsp.lp_coeff(hz * 1.6, _sr)
	_ev_bf = clampf(TAU * minf(hz, float(_sr) * LcnDsp.SVF_MAX_RATIO) / float(_sr),
		0.001, LcnDsp.SVF_MAX_F)
	_ev_drop = pow(0.55, 1.0 / float(maxi(1, int(e["len"]))))


## One slice of a transient, written on top of the bed and wrapped around the
## loop point, so a rhythm whose last hit rings past the end still rings into
## the next pass. All running state lives in fields, so `count` may be any size
## and the result is identical either way.
func _render_event_slice(e: Dictionary, count: int) -> void:
	var kind: StringName = e["kind"]
	var at: int = int(e["at"])
	var length: int = int(e["len"])
	var amp: float = float(e["amp"])
	var noise_mix: float = float(e["noise"])

	var rng: RandomNumberGenerator = _ev_rng
	var env: float = _ev_env
	var dec: float = _ev_dec
	var ph: float = _ev_ph
	var ph2: float = _ev_ph2
	var ph3: float = _ev_ph3
	var ph4: float = _ev_ph4
	var lp: float = _ev_lp
	var lp_a: float = _ev_lp_a
	var bp_low: float = _ev_bp_low
	var bp_band: float = _ev_bp_band
	var bf: float = _ev_bf
	var f: float = _ev_f
	var drop: float = _ev_drop
	var inv_sr: float = 1.0 / float(_sr)

	# Events are placed relative to the LOOP BODY, which begins after the
	# discarded run-up.
	var wrap: int = _body if _loop else 0
	var r2: float = 2.76 if kind == &"metal" else 1.72
	var r3: float = 5.40 if kind == &"metal" else 2.61
	var r4: float = 8.93 if kind == &"metal" else 4.17
	var burst: int = maxi(1, length / 12)

	for k: int in count:
		var i: int = _ev_i + k
		var idx: int = at + i
		if wrap > 0:
			idx = idx % wrap
			if idx < 0:
				idx += wrap
			idx += _pre
		if idx < 0 or idx >= _render_len:
			env *= dec
			continue

		var white: float = rng.randf() * 2.0 - 1.0
		var v: float = 0.0
		match kind:
			&"thud":
				# A sine that falls in pitch as it decays: the shape of anything
				# heavy meeting anything solid.
				f *= drop
				ph += f
				if ph >= 1.0:
					ph -= 1.0
				v = sin(ph * TAU) * (1.0 - noise_mix)
				lp += (white - lp) * lp_a
				v += lp * noise_mix
			&"click":
				bp_low += bf * bp_band
				bp_band += bf * (white - bp_low - 0.4 * bp_band)
				ph += f
				if ph >= 1.0:
					ph -= 1.0
				v = bp_band * 2.0 * noise_mix + sin(ph * TAU) * (1.0 - noise_mix)
			&"tick":
				bp_low += bf * bp_band
				bp_band += bf * (white - bp_low - 0.22 * bp_band)
				v = bp_band * 2.4 * noise_mix + sin(ph * TAU) * (1.0 - noise_mix)
				ph += f
				if ph >= 1.0:
					ph -= 1.0
			&"crackle":
				# Two short bursts a few milliseconds apart. One burst is a tick;
				# two is a fire.
				bp_low += bf * bp_band
				bp_band += bf * (white - bp_low - 0.28 * bp_band)
				var gate: float = 1.0 if (i < length / 3 or i > length * 2 / 3) else 0.25
				v = bp_band * 2.4 * gate
			&"chuff":
				lp += (white - lp) * lp_a
				v = lp * 2.2
			&"blip":
				f *= 1.0 + 1.4 * inv_sr
				ph += f
				if ph >= 1.0:
					ph -= 1.0
				v = sin(ph * TAU) * (1.0 - noise_mix) + white * noise_mix * 0.3
			&"clank", &"metal":
				# Inharmonic partials. Bell ratios for metal, a tighter, duller
				# set for a press.
				ph += f
				ph2 += f * r2
				ph3 += f * r3
				ph4 += f * r4
				if ph >= 1.0:
					ph -= 1.0
				if ph2 >= 1.0:
					ph2 -= 1.0
				if ph3 >= 1.0:
					ph3 -= 1.0
				if ph4 >= 1.0:
					ph4 -= 1.0
				v = sin(ph * TAU) * 0.5 + sin(ph2 * TAU) * 0.28 \
					+ sin(ph3 * TAU) * 0.14 + sin(ph4 * TAU) * 0.07
				v *= 1.0 - noise_mix
				lp += (white - lp) * 0.6
				v += lp * noise_mix * (1.0 if i < burst else 0.15)
			_:
				v = white

		_buf[idx] += v * env * amp
		env *= dec

	_ev_env = env
	_ev_ph = ph
	_ev_ph2 = ph2
	_ev_ph3 = ph3
	_ev_ph4 = ph4
	_ev_lp = lp
	_ev_bp_low = bp_low
	_ev_bp_band = bp_band
	_ev_f = f


# =================================================================== finish ==

## Scrubs non-finite samples and measures the peak, so ENCODE knows the gain.
func _do_scrub(budget: int) -> int:
	if _tail_cursor == 0 and _pre > 0:
		# Throw the run-up away. Everything after this point sees a buffer whose
		# sample zero is the first sample of the loop.
		_buf = _buf.slice(_pre, _pre + _body)
		_pre = 0
	var to: int = mini(_body, _tail_cursor + budget)
	for i: int in range(_tail_cursor, to):
		var v: float = _buf[i]
		if not is_finite(v):
			v = 0.0
			non_finite += 1
			_buf[i] = 0.0
		elif v > 1.0:
			v = 1.0
			_buf[i] = 1.0
		elif v < -1.0:
			v = -1.0
			_buf[i] = -1.0
		var a: float = absf(v)
		if a > _peak:
			_peak = a
	var spent: int = to - _tail_cursor
	work_done += spent
	_tail_cursor = to
	if _tail_cursor >= _body:
		var target: float = LcnDsp.NORMAL_PEAK * clampf(_gain, 0.05, 1.0)
		_norm = 1.0 if _peak < 0.0001 else target / _peak
		_pcm = PackedByteArray()
		_pcm.resize(_body * 2)
		_tail_cursor = 0
		_phase = Phase.ENCODE
	return maxi(1, spent)


func _do_encode(budget: int) -> int:
	var to: int = mini(_body, _tail_cursor + budget)
	for i: int in range(_tail_cursor, to):
		var v: int = int(round(clampf(_buf[i] * _norm, -1.0, 1.0) * 32767.0))
		_pcm.encode_s16(i * 2, clampi(v, -32768, 32767))
	var spent: int = to - _tail_cursor
	work_done += spent
	_tail_cursor = to
	if _tail_cursor < _body:
		return maxi(1, spent)
	stream = LcnDsp.wav_from_pcm(_pcm, _sr, _loop)
	_buf = PackedFloat32Array()
	_pcm = PackedByteArray()
	work_done = work_total
	_phase = Phase.DONE
	done = true
	return maxi(1, spent)


## Bytes the finished stream occupies. Reported by the bank.
func byte_size() -> int:
	return 0 if stream == null else stream.data.size()

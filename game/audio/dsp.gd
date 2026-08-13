class_name LcnDsp
extends RefCounted
## [P23] Pure DSP maths. No nodes, no engine state, no randomness of its own.
##
## Every function here is a deterministic function of its arguments, which is
## the whole reason this file is separate: `tests/audio/test_dsp.gd` can assert
## a rendered buffer byte for byte, and the synth above it can be rebuilt in
## chunks across frames without the seams ever showing.
##
## The house style for the whole part: **clamp at the edge, never inside the
## loop.** An over-Nyquist cutoff, a zero sample rate or a silent buffer must
## produce a quiet, finite result rather than a NaN that Godot then reports as
## an engine error from deep inside the mixer.

const SR_LOW: int = 11025          ## long beds and music: dark material, half the cost
const SR_MID: int = 22050          ## machines, weapons, interface
const MIN_DB: float = -80.0        ## our silence. Never -INF: Godot logs on that.
const MAX_DB: float = 12.0

## Peak the renderer normalises a finished buffer to. Leaves ~1 dB of headroom
## before the master limiter so a full mix never asks the limiter to work hard.
const NORMAL_PEAK: float = 0.89


# --- filters -----------------------------------------------------------------

## One-pole lowpass coefficient for `y += (x - y) * a`.
static func lp_coeff(cutoff_hz: float, sr: int) -> float:
	var rate: float = maxf(1.0, float(sr))
	var fc: float = clampf(cutoff_hz, 0.5, rate * 0.45)
	return clampf(1.0 - exp(-TAU * fc / rate), 0.0, 1.0)


## Chamberlin state-variable frequency term. Stable well below sr/4, which is
## where the clamp puts it — a resonant sweep that runs off the top of the band
## is how a "wind" loop turns into a burst of NaN.
static func svf_f(cutoff_hz: float, sr: int) -> float:
	var rate: float = maxf(1.0, float(sr))
	var fc: float = clampf(cutoff_hz, 1.0, rate * 0.22)
	return clampf(2.0 * sin(PI * fc / rate), 0.0001, 1.2)


## Damping term for the same filter. `q` is resonance: 0.7 flat, 8 whistling.
static func svf_q(q: float) -> float:
	return clampf(1.0 / maxf(0.5, q), 0.02, 2.0)


# --- gain --------------------------------------------------------------------

## A 0..1 user slider as decibels, with a taste curve. 0 is our silence (MIN_DB),
## never -INF, because AudioServer complains about the latter.
static func slider_db(value01: float) -> float:
	var v: float = clampf(value01, 0.0, 1.0)
	if v <= 0.0005:
		return MIN_DB
	return clampf(linear_to_db(pow(v, 1.55)), MIN_DB, MAX_DB)


## Any linear gain as a safe dB figure.
static func gain_db(linear: float) -> float:
	if not is_finite(linear) or linear <= 0.0001:
		return MIN_DB
	return clampf(linear_to_db(linear), MIN_DB, MAX_DB)


## Guards every value that reaches a Godot audio property. NaN into volume_db,
## pitch_scale or a filter cutoff is an engine-level error, and this part is
## judged on producing none.
static func safe(value: float, fallback: float, low: float, high: float) -> float:
	if not is_finite(value):
		return fallback
	return clampf(value, low, high)


# --- pitch -------------------------------------------------------------------

static func semitones(n: float) -> float:
	return pow(2.0, clampf(n, -48.0, 48.0) / 12.0)


## Frequency of a MIDI-ish note number. 62 is D4. The whole score sits in D.
static func note_hz(midi: float) -> float:
	return 440.0 * pow(2.0, (clampf(midi, 0.0, 127.0) - 69.0) / 12.0)


## Snaps a frequency to a whole number of cycles in the loop, so a sustained
## tone meets its own tail at the loop point with no click and no crossfade.
static func snap_to_loop(hz: float, loop_seconds: float) -> float:
	if loop_seconds <= 0.0:
		return hz
	var cycles: float = maxf(1.0, round(hz * loop_seconds))
	return cycles / loop_seconds


# --- buffers -----------------------------------------------------------------

## Folds `xf` samples of overrun back over the head of the loop. `buf` must hold
## `body + xf` samples; afterwards the first `body` of them loop seamlessly.
## This is what makes a noise bed loop without a tick every N seconds.
static func crossfade_loop(buf: PackedFloat32Array, body: int, xf: int) -> void:
	if body <= 0 or xf <= 0 or buf.size() < body + xf:
		return
	for i: int in xf:
		var t: float = float(i) / float(xf)
		buf[i] = buf[i] * t + buf[body + i] * (1.0 - t)


static func peak_of(buf: PackedFloat32Array, count: int) -> float:
	var n: int = mini(count, buf.size())
	var p: float = 0.0
	for i: int in n:
		var v: float = absf(buf[i])
		if v > p:
			p = v
	return p


## Scales a buffer to `target` peak and returns the gain applied. A silent
## buffer is left alone rather than amplified into noise.
static func normalize_to(buf: PackedFloat32Array, count: int, target: float) -> float:
	var p: float = peak_of(buf, count)
	if p < 0.0001 or not is_finite(p):
		return 1.0
	var g: float = target / p
	var n: int = mini(count, buf.size())
	for i: int in n:
		buf[i] = buf[i] * g
	return g


## Gentle saturation. Keeps transients inside the rails without the brittle
## edge of a hard clip — the difference between "industrial" and "broken".
static func soft_clip(x: float) -> float:
	if x > 1.0 or x < -1.0:
		return signf(x) * (2.0 - 1.0 / absf(x)) * 0.5 + signf(x) * 0.5
	return x - (x * x * x) / 3.0 * 0.5


## Replaces any non-finite sample with silence and reports how many there were.
## Called once per built stream: a single NaN reaching AudioServer is audible as
## a click on every platform and reads as an engine fault on some.
static func sanitize(buf: PackedFloat32Array, count: int) -> int:
	var bad: int = 0
	var n: int = mini(count, buf.size())
	for i: int in n:
		var v: float = buf[i]
		if not is_finite(v):
			buf[i] = 0.0
			bad += 1
		elif v > 1.0:
			buf[i] = 1.0
		elif v < -1.0:
			buf[i] = -1.0
	return bad


# --- encoding ----------------------------------------------------------------

## Signed 16-bit little-endian PCM, which is what AudioStreamWAV wants.
static func pcm16(buf: PackedFloat32Array, count: int) -> PackedByteArray:
	var n: int = mini(count, buf.size())
	var out := PackedByteArray()
	out.resize(n * 2)
	for i: int in n:
		var v: int = int(round(clampf(buf[i], -1.0, 1.0) * 32767.0))
		out.encode_s16(i * 2, clampi(v, -32768, 32767))
	return out


## Finished, playable stream. `looping` sets a forward loop over the whole body.
static func to_wav(buf: PackedFloat32Array, count: int, sr: int, looping: bool) -> AudioStreamWAV:
	var n: int = maxi(1, mini(count, buf.size()))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = maxi(1000, sr)
	w.stereo = false
	w.data = pcm16(buf, n)
	if looping:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	else:
		w.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return w


# --- envelopes ---------------------------------------------------------------

## Attack/decay envelope over a window, both in samples. Used by the one-shots.
static func env_ad(i: int, n: int, attack: int, decay: int) -> float:
	if n <= 0:
		return 0.0
	var a: int = maxi(1, attack)
	if i < a:
		return float(i) / float(a)
	var d: int = maxi(1, decay)
	var tail: int = i - a
	if tail >= d:
		return 0.0
	return 1.0 - float(tail) / float(d)


## Exponential decay factor per sample for a given -60 dB time in seconds.
static func decay_per_sample(seconds: float, sr: int) -> float:
	var s: float = maxf(0.001, seconds)
	return exp(-6.9078 / (s * maxf(1.0, float(sr))))

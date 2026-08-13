class_name LcnVoicePool
extends Node
## [P23] Voice allocation, limiting, stealing and distance culling.
##
## A wave is two hundred bodies and forty-three shots land in the same second.
## Without a policy that is two hundred AudioStreamPlayers, a mix that is pure
## intermodulation, and a limiter working so hard the hearth disappears. The
## policy, in the order it is applied to every request:
##
##   1. **cull**       further than [LcnAudioDefs].AUDIBLE_TILES from the camera
##                     and it is never allocated at all. Free.
##   2. **coalesce**   the same cue within 45 ms becomes ONE voice a decibel and
##                     a half louder, not two voices. This is what makes a volley
##                     sound like a volley instead of like mud.
##   3. **rate limit** at most ten starts a frame. The harness pushes a thousand
##                     ticks through a single frame, and this is the only thing
##                     between that and a wall of noise.
##   4. **cap**        every category has a ceiling and they sum to less than the
##                     pool, so combat can never starve the interface.
##   5. **steal**      at the cap, take the oldest voice of that category, and
##                     never one of a HIGHER priority than the request.
##
## Machine loops are deliberately NOT in this pool. They are persistent, one per
## family, and live in [LcnMachineChorus]; a loop that could be stolen stutters,
## and a stuttering machine loop is worse than no machine loop.

class Voice extends RefCounted:
	var flat: AudioStreamPlayer = null
	var world: AudioStreamPlayer2D = null
	var positional: bool = false
	var cue: StringName = &""
	var category: StringName = &""
	var priority: int = 0
	var started_usec: int = 0
	var db: float = 0.0
	var busy: bool = false

	func playing() -> bool:
		if positional:
			return world != null and world.playing
		return flat != null and flat.playing

	func stop() -> void:
		if positional and world != null:
			world.stop()
		elif flat != null:
			flat.stop()
		busy = false

	func set_db(value: float) -> void:
		db = value
		var v: float = LcnDsp.safe(value, -12.0, LcnDsp.MIN_DB, LcnDsp.MAX_DB)
		if positional and world != null:
			world.volume_db = v
		elif flat != null:
			flat.volume_db = v


var world_cap: int = LcnAudioDefs.MAX_WORLD_VOICES
var flat_cap: int = LcnAudioDefs.MAX_FLAT_VOICES

## Listener, in world pixels. Written every frame by [LcnAudio] from the active
## Camera2D. Culling is skipped while `has_listener` is false, which is what lets
## the headless suites exercise the rest of the policy.
var listener: Vector2 = Vector2.ZERO
var has_listener: bool = false
var audible_radius: float = LcnAudioDefs.AUDIBLE_TILES * LcnAudioDefs.TILE

# --- counters, all reported ---------------------------------------------------
var started: int = 0
var culled_distance: int = 0
var coalesced: int = 0
var rate_limited: int = 0
var stolen: int = 0
var refused_cap: int = 0
var missing_stream: int = 0
var peak_active: int = 0

var _world: Array[Voice] = []
var _flat: Array[Voice] = []
var _starts_this_frame: int = 0
var _recent: Dictionary[StringName, Array] = {}
var _bank: LcnSoundBank = null
## Pitch jitter. Its own generator on purpose: `Rng` belongs to the simulation
## and the global `randf()` is shared state. Neither may be moved by a sound.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	name = "VoicePool"
	_rng.seed = 0x5EED_A0D1


func bind(bank: LcnSoundBank) -> void:
	_bank = bank


## Call once per frame, before any play() of that frame.
func begin_frame() -> void:
	_starts_this_frame = 0
	var live: int = 0
	for v: Voice in _world:
		if v.busy and not v.playing():
			v.busy = false
		if v.busy:
			live += 1
	for v: Voice in _flat:
		if v.busy and not v.playing():
			v.busy = false
		if v.busy:
			live += 1
	if live > peak_active:
		peak_active = live


## Plays a cue from [LcnAudioDefs].CUES. `at` is a world position; pass
## `positional = false` for interface and score cues that have no place in the
## world. Returns the voice used, or null when the policy refused.
func play(cue: StringName, at: Vector2 = Vector2.ZERO, positional: bool = true,
		db_offset: float = 0.0, pitch: float = 1.0) -> Voice:
	var spec: Dictionary = LcnAudioDefs.CUES.get(cue, {})
	if spec.is_empty():
		return null
	if positional and has_listener and listener.distance_to(at) > audible_radius:
		culled_distance += 1
		return null

	var now: int = Time.get_ticks_usec()
	var merged: Voice = _try_coalesce(cue, now)
	if merged != null:
		coalesced += 1
		return merged

	if _starts_this_frame >= LcnAudioDefs.MAX_STARTS_PER_FRAME:
		rate_limited += 1
		return null

	var stream: AudioStreamWAV = null
	if _bank != null:
		stream = _bank.get_stream(spec.get("stream", &""))
	if stream == null:
		missing_stream += 1
		return null

	var category: StringName = spec.get("category", &"world")
	var priority: int = int(spec.get("priority", LcnAudioDefs.PRI_AMBIENT))
	var voice: Voice = _claim(positional, category, priority)
	if voice == null:
		return null

	var jitter: float = float(spec.get("pitch", 0.0))
	var rate: float = pitch
	if jitter > 0.0:
		rate *= LcnDsp.semitones(_rng.randf_range(-jitter, jitter))

	voice.cue = cue
	voice.category = category
	voice.priority = priority
	voice.started_usec = now
	voice.busy = true
	var bus: String = String(spec.get("bus", LcnAudioDefs.BUS_SFX))
	# A pitch_scale of zero or a NaN volume is an engine-level error, and a
	# stream player is the easiest place in a codebase to produce one by
	# accident. Everything reaching an audio property goes through LcnDsp.safe.
	var safe_pitch: float = LcnDsp.safe(rate, 1.0, 0.05, 4.0)
	if positional:
		voice.world.stream = stream
		voice.world.bus = bus
		voice.world.pitch_scale = safe_pitch
		voice.world.position = at
		voice.world.max_distance = maxf(64.0, audible_radius)
		voice.set_db(float(spec.get("db", -8.0)) + db_offset)
		voice.world.play()
	else:
		voice.flat.stream = stream
		voice.flat.bus = bus
		voice.flat.pitch_scale = safe_pitch
		voice.set_db(float(spec.get("db", -8.0)) + db_offset)
		voice.flat.play()

	_recent[cue] = [now, voice]
	_starts_this_frame += 1
	started += 1
	return voice


func stop_all() -> void:
	for v: Voice in _world:
		v.stop()
	for v: Voice in _flat:
		v.stop()


# ================================================================== policy ===

## Two of the same cue in the same instant is one louder cue.
func _try_coalesce(cue: StringName, now: int) -> Voice:
	var row: Array = _recent.get(cue, [])
	if row.size() < 2:
		return null
	if now - int(row[0]) > LcnAudioDefs.COALESCE_MS * 1000:
		return null
	var v: Voice = row[1] as Voice
	if v == null or not v.busy or v.cue != cue:
		return null
	var ceiling: float = float(LcnAudioDefs.CUES[cue].get("db", -8.0)) \
		+ LcnAudioDefs.COALESCE_GAIN_MAX_DB
	v.set_db(minf(v.db + LcnAudioDefs.COALESCE_GAIN_DB, ceiling))
	return v


func _claim(positional: bool, category: StringName, priority: int) -> Voice:
	var pool: Array[Voice] = _world if positional else _flat
	var cap: int = world_cap if positional else flat_cap

	# The category ceiling comes first: a category at its cap must recycle its
	# OWN oldest voice, never take one from a quieter category that still has
	# room. Otherwise a big wave slowly evicts the whole interface.
	if _count_category(pool, category) >= int(LcnAudioDefs.CATEGORY_CAP.get(category, 999)):
		return _steal(pool, category, priority, true)

	for v: Voice in pool:
		if not v.busy:
			return v
	if pool.size() < cap:
		var fresh: Voice = _make(positional)
		pool.append(fresh)
		return fresh
	return _steal(pool, category, priority, false)


func _count_category(pool: Array[Voice], category: StringName) -> int:
	var n: int = 0
	for v: Voice in pool:
		if v.busy and v.category == category:
			n += 1
	return n


## Lowest priority first, then oldest. Never takes a voice from something more
## important than the thing asking: a footstep cannot silence a breach.
func _steal(pool: Array[Voice], category: StringName, priority: int, same_category: bool) -> Voice:
	var best: Voice = null
	for v: Voice in pool:
		if not v.busy:
			if not same_category:
				return v
			continue
		if v.priority > priority:
			continue
		if same_category and v.category != category:
			continue
		if best == null or v.priority < best.priority \
				or (v.priority == best.priority and v.started_usec < best.started_usec):
			best = v
	if best == null:
		refused_cap += 1
		return null
	best.stop()
	stolen += 1
	return best


func _make(positional: bool) -> Voice:
	var v := Voice.new()
	v.positional = positional
	if positional:
		var p := AudioStreamPlayer2D.new()
		p.name = "World%d" % _world.size()
		p.attenuation = 1.4
		p.panning_strength = 0.7
		p.max_distance = maxf(64.0, audible_radius)
		p.max_polyphony = 1
		v.world = p
		add_child(p)
	else:
		var p := AudioStreamPlayer.new()
		p.name = "Flat%d" % _flat.size()
		p.max_polyphony = 1
		v.flat = p
		add_child(p)
	return v


# ================================================================== reading ==

func active_count() -> int:
	var n: int = 0
	for v: Voice in _world:
		if v.busy:
			n += 1
	for v: Voice in _flat:
		if v.busy:
			n += 1
	return n


func active_by_category() -> Dictionary:
	var out: Dictionary = {}
	for v: Voice in _world:
		if v.busy:
			out[String(v.category)] = int(out.get(String(v.category), 0)) + 1
	return out


func report() -> Dictionary:
	return {
		"world_allocated": _world.size(),
		"world_cap": world_cap,
		"flat_allocated": _flat.size(),
		"flat_cap": flat_cap,
		"active": active_count(),
		"peak_active": peak_active,
		"by_category": active_by_category(),
		"started": started,
		"coalesced": coalesced,
		"stolen": stolen,
		"culled_distance": culled_distance,
		"rate_limited": rate_limited,
		"refused_cap": refused_cap,
		"missing_stream": missing_stream,
	}

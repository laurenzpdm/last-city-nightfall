class_name LcnAudio
extends Node
## [P23] The audio director. One node, one process callback, the whole soundtrack.
##
## [codeblock]
##   var audio := LcnAudio.new()
##   parent_already_in_the_tree.add_child(audio)   # that is the installation
##   audio.report()                                # what the desk is doing
## [/codeblock]
##
## WHAT IT DOES, in order, once a frame:
##   1. spends 2.5 ms baking the next few sounds until the catalogue is done
##   2. moves the listener to the camera
##   3. re-reads the simulation five times a second through [LcnAudioProbe]
##   4. lets the beds, the machine chorus and the score follow those readings
##   5. drains the cue queue through [LcnVoicePool]'s limiter
##
## EVENTS NEVER PLAY A SOUND DIRECTLY. Every Bus signal appends one small
## dictionary to a bounded queue and returns. This matters more than it looks:
## Bus signals are emitted from inside `SimSystem.step()`, and a harness run
## pushes eleven thousand ticks through about ten frames — so a handler that
## started a voice would be starting thousands of them inside one frame, from
## inside the simulation's own call stack. Appending to a ring buffer costs
## nanoseconds and cannot perturb a tick.
##
## NOTHING HERE CAN MOVE A REPLAY. No `Rng` stream is touched, no command is
## submitted, no sim state is written. The only direction of travel is sim → mix.
##
## Installed by `game/content/audio/audio_bootstrap.tres` — see
## [LcnAudioBootstrap] for why it is a resource and not a line in `boot.gd`.

const GROUP: StringName = &"lcn_audio"
const NODE_NAME: String = "LcnAudio"

## Cues waiting to be played. Bounded: a harness frame can queue thousands and
## the oldest are the least interesting.
const MAX_PENDING: int = 192

## Seconds between the summary line written to the log.
const SUMMARY_SECONDS: float = 20.0

## Seconds between repeats of a cue that fires on a per-entity signal. Without
## these a hundred citizens freezing on the same tick is a hundred bells.
const THROTTLE: Dictionary[StringName, float] = {
	&"enemy_call": 2.2,
	&"enemy_call_near": 1.1,
	&"machine_stall": 1.5,
	&"froze": 1.2,
	&"death": 2.5,
	&"structure_hit": 0.12,
	&"enemy_hit": 0.1,
	&"build_removed": 0.25,
	&"ui_click": 0.06,
}

var mixer: LcnAudioMixer = null
var bank: LcnSoundBank = null
var pool: LcnVoicePool = null
var beds: LcnAmbienceBeds = null
var chorus: LcnMachineChorus = null
var music: LcnMusicDirector = null
var probe: LcnAudioProbe = null

## Microseconds the last frame's whole audio update took. The perf suite reads it.
var last_update_usec: int = 0
var peak_update_usec: int = 0

var _pending: Array[Dictionary] = []
var _dropped: int = 0
var _played: int = 0
var _last_at: Dictionary[StringName, int] = {}
var _bound: bool = false
var _ready_logged: bool = false
var _report_written: bool = false
var _frames: int = 0
var _since_summary: float = 0.0
var _world_seed: int = -0x7FFFFFFF
## Peak microseconds per stage of the frame, so a slow frame can be attributed
## instead of argued about.
var _stage_usec: Dictionary[StringName, int] = {&"bake": 0, &"probe": 0, &"layers": 0, &"voices": 0}


static func current() -> LcnAudio:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as LcnAudio


func _ready() -> void:
	name = NODE_NAME
	add_to_group(GROUP)
	process_priority = 40          ## after the camera has moved this frame

	mixer = LcnAudioMixer.new()
	mixer.install()

	bank = LcnSoundBank.new()
	var warm_usec: int = bank.warm_up()

	pool = LcnVoicePool.new()
	add_child(pool)
	pool.bind(bank)

	beds = LcnAmbienceBeds.new()
	add_child(beds)
	beds.setup(bank)

	chorus = LcnMachineChorus.new()
	add_child(chorus)
	chorus.setup(bank)

	music = LcnMusicDirector.new()
	add_child(music)
	music.setup(bank)

	probe = LcnAudioProbe.new()
	probe.bind()

	_connect_bus()
	_bind_world()
	# When the harness is driving, the mix writes its own artifact next to the
	# screenshots. A critic should not have to take a builder's word for what
	# was audible at the moment a shot was taken.
	var harness: Node = _autoload(&"Harness")
	if harness != null and harness.has_signal(&"finished") \
			and not harness.is_connected(&"finished", _on_harness_finished):
		harness.connect(&"finished", _on_harness_finished)
	if harness != null and bool(harness.get("active")) and bool(harness.get("visual")):
		# A visual harness run pushes eleven thousand ticks through about fourteen
		# frames, so a per-frame bake budget bakes one stream and the artifact
		# reports a silent game — which would be a lie about the build rather than
		# a fact about it. The run is not real time and nobody is listening to it,
		# so it pays for the whole catalogue up front and the audio.json next to
		# the screenshots describes a mix that actually exists.
		bank.eager_budget_usec = 250_000
		bank.budget_usec = 250_000
	Log.info("audio", "installed: %d buses, %d/%d streams baked in %.0f ms, %d voice slots" % [
		AudioServer.bus_count, bank.ready_count(),
		bank.ready_count() + bank.pending_count(),
		float(warm_usec) / 1000.0, pool.world_cap + pool.flat_cap])


func _exit_tree() -> void:
	# A RefCounted subscribed to an autoload signal never dies, so every
	# connection made here is dropped here.
	_disconnect_bus()
	if pool != null:
		pool.stop_all()


# ================================================================== wiring ===

func _connect_bus() -> void:
	if _bound:
		return
	var bus: Node = _autoload(&"Bus")
	if bus == null:
		return
	for pair: Array in _subscriptions():
		if not bus.has_signal(pair[0]):
			continue
		if not bus.is_connected(pair[0], pair[1]):
			bus.connect(pair[0], pair[1])
	_bound = true


func _disconnect_bus() -> void:
	var bus: Node = _autoload(&"Bus")
	if bus == null:
		return
	for pair: Array in _subscriptions():
		if bus.has_signal(pair[0]) and bus.is_connected(pair[0], pair[1]):
			bus.disconnect(pair[0], pair[1])
	_bound = false


func _subscriptions() -> Array[Array]:
	return [
		[&"world_ready", _on_world_ready],
		[&"turret_fired", _on_turret_fired],
		[&"enemy_killed", _on_enemy_killed],
		[&"enemy_spawned", _on_enemy_spawned],
		[&"structure_damaged", _on_structure_damaged],
		[&"building_placed", _on_building_placed],
		[&"building_removed", _on_building_removed],
		[&"building_froze", _on_building_froze],
		[&"machine_stalled", _on_machine_stalled],
		[&"placement_rejected", _on_placement_rejected],
		[&"citizen_died", _on_citizen_died],
		[&"law_enacted", _on_law_enacted],
		[&"research_completed", _on_research_completed],
		[&"alert_raised", _on_alert],
		[&"wave_started", _on_wave_started],
		[&"wave_cleared", _on_wave_cleared],
		[&"night_started", _on_night],
		[&"day_started", _on_day],
		[&"build_selection_changed", _on_selection_changed],
		[&"overlay_mode_changed", _on_overlay_changed],
	]


func _bind_world() -> void:
	if probe != null:
		probe.bind()
	var sim: Node = _autoload(&"Sim")
	if sim == null or not bool(sim.get("alive")) or chorus == null:
		return
	chorus.bind(sim.call("get_system", &"build") as SimSystem,
		sim.call("get_system", &"production") as SimSystem)


# ================================================================= per-frame =

func _process(delta: float) -> void:
	var t0: int = Time.get_ticks_usec()
	_frames += 1

	_watch_for_a_new_world()
	bank.pump()
	var t_bake: int = Time.get_ticks_usec()
	pool.begin_frame()
	_track_listener()
	probe.update(delta)
	var t_probe: int = Time.get_ticks_usec()

	mixer.storm01 = probe.storm01
	mixer.hearth01 = probe.hearth01
	mixer.factory01 = probe.factory01
	mixer.update(delta)

	beds.update(delta, probe)
	chorus.update(delta, probe)
	music.update(delta, probe)
	var t_layers: int = Time.get_ticks_usec()

	_drain()

	# Attributed, not guessed. The first version of this loop peaked at 16 ms and
	# three different subsystems were plausible suspects; the split says which.
	var now: int = Time.get_ticks_usec()
	_stage_usec[&"bake"] = maxi(_stage_usec[&"bake"], t_bake - t0)
	_stage_usec[&"probe"] = maxi(_stage_usec[&"probe"], t_probe - t_bake)
	_stage_usec[&"layers"] = maxi(_stage_usec[&"layers"], t_layers - t_probe)
	_stage_usec[&"voices"] = maxi(_stage_usec[&"voices"], now - t_layers)

	if not _ready_logged and bank.finished():
		_ready_logged = true
		Log.info("audio", "bake complete: %s" % JSON.stringify(bank.report()))

	# One dense line every twenty seconds of play. A silent subsystem is very
	# easy to ship — this is how a session log answers "was there any sound"
	# without anyone having to be in the room.
	_since_summary += delta
	if _since_summary >= SUMMARY_SECONDS:
		_since_summary = 0.0
		Log.info("audio", summary())

	last_update_usec = Time.get_ticks_usec() - t0
	if last_update_usec > peak_update_usec:
		peak_update_usec = last_update_usec


## A load, a restart or a test fixture replaces every SimSystem in the world.
## The probe notices on its own; the machine chorus holds direct references and
## would otherwise keep playing the previous city's factory over the new one.
func _watch_for_a_new_world() -> void:
	var rng: Node = _autoload(&"Rng")
	var seed_now: int = 0 if rng == null else int(rng.get("seed_value"))
	if seed_now == _world_seed:
		return
	_world_seed = seed_now
	_pending.clear()
	if pool != null:
		pool.stop_all()
	_bind_world()


## The listener is the camera, and the camera is found through the viewport
## rather than through [P16]'s class, so the mix does not stop panning the day
## somebody renames a node.
func _track_listener() -> void:
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var cam: Camera2D = vp.get_camera_2d()
	if cam == null:
		pool.has_listener = false
		chorus.has_listener = false
		return
	var at: Vector2 = cam.get_screen_center_position()
	pool.listener = at
	pool.has_listener = true
	chorus.listener = at
	chorus.has_listener = true
	# A zoomed-out camera hears further: the audible radius follows what the
	# player can actually see, so a sound never comes from off-screen silence.
	var zoom: float = maxf(0.05, minf(cam.zoom.x, cam.zoom.y))
	var half: float = float(vp.get_visible_rect().size.length()) * 0.5 / zoom
	pool.audible_radius = clampf(half * 1.35, 480.0, 6000.0)


## Spends the frame's cue budget. The pool applies the actual limiting; this
## only decides the ORDER, which is by priority so a breach is never the cue
## that got dropped because sixty footsteps were queued in front of it.
func _drain() -> void:
	if _pending.is_empty():
		return
	if _pending.size() > 2:
		_pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["priority"]) > int(b["priority"]))
	var budget: int = LcnAudioDefs.MAX_STARTS_PER_FRAME
	while not _pending.is_empty() and budget > 0:
		var c: Dictionary = _pending.pop_front()
		budget -= 1
		if pool.play(c["cue"], c["at"], bool(c["positional"]),
				float(c.get("db", 0.0)), float(c.get("pitch", 1.0))) != null:
			_played += 1
	# Anything still queued at the end of the frame is stale by definition: it
	# describes a moment that has already gone.
	if not _pending.is_empty():
		_dropped += _pending.size()
		_pending.clear()


# =================================================================== cueing ==

## The single entry point for "make this noise". Safe to call from inside a sim
## tick: it appends and returns.
func cue(key: StringName, at: Vector2 = Vector2.ZERO, positional: bool = true,
		db: float = 0.0, pitch: float = 1.0) -> void:
	if not LcnAudioDefs.CUES.has(key):
		return
	if not _passes_throttle(key):
		return
	if _pending.size() >= MAX_PENDING:
		_pending.pop_front()
		_dropped += 1
	_pending.append({
		"cue": key, "at": at, "positional": positional, "db": db, "pitch": pitch,
		"priority": int(LcnAudioDefs.CUES[key].get("priority", 1)),
	})


func _passes_throttle(key: StringName) -> bool:
	var gap: float = float(THROTTLE.get(key, 0.0))
	if gap <= 0.0:
		return true
	var now: int = Time.get_ticks_msec()
	var last: int = int(_last_at.get(key, -100000))
	if now - last < int(gap * 1000.0):
		return false
	_last_at[key] = now
	return true


# ================================================================= handlers ==
#
# Every one of these runs inside a simulation tick. They append and return.

func _on_world_ready() -> void:
	_bind_world.call_deferred()


func _on_harness_finished() -> void:
	write_run_report()


func _on_turret_fired(_id: int, from: Vector2, to: Vector2) -> void:
	# Reach is the only thing distinguishing a light gun from a heavy one until
	# [P07] puts a weapon class on the signal.
	var heavy: bool = from.distance_squared_to(to) > 360000.0
	cue(&"turret_fire_heavy" if heavy else &"turret_fire", from)


func _on_enemy_killed(_id: int, pos: Vector2) -> void:
	cue(&"enemy_died", pos)


func _on_enemy_spawned(_id: int, kind: StringName, pos: Vector2) -> void:
	var s: String = String(kind)
	# Something big announces itself before the player can see it, which is the
	# only warning they get in the dark.
	if s.contains("brute") or s.contains("titan") or s.contains("hulk") \
			or s.contains("breaker") or s.contains("siege"):
		cue(&"big_one", pos)
		return
	cue(&"enemy_call", pos)


func _on_structure_damaged(_id: int, amount: float, pos: Vector2) -> void:
	cue(&"structure_hit", pos, true, clampf(amount * 0.12, -6.0, 4.0))


func _on_building_placed(_id: int, _kind: StringName, cell: Vector2i) -> void:
	cue(&"build_place", _cell_to_world(cell))


func _on_building_removed(_id: int, cell: Vector2i) -> void:
	cue(&"build_removed", _cell_to_world(cell))


func _on_building_froze(id: int) -> void:
	cue(&"froze", _building_pos(id))


func _on_machine_stalled(id: int, _reason: StringName) -> void:
	cue(&"machine_stall", _building_pos(id))


func _on_placement_rejected(_cell: Vector2i, _reason: String) -> void:
	cue(&"ui_deny", Vector2.ZERO, false)


func _on_citizen_died(_id: int, _cause: StringName) -> void:
	cue(&"death", Vector2.ZERO, false)


func _on_law_enacted(_id: StringName) -> void:
	cue(&"law_signed", Vector2.ZERO, false)


func _on_research_completed(_id: StringName) -> void:
	cue(&"research_done", Vector2.ZERO, false)


func _on_alert(severity: int, _key: StringName, _text: String, pos: Vector2) -> void:
	var positional: bool = pos != Vector2.ZERO
	cue(LcnAudioDefs.alert_cue(severity), pos, positional)
	if mixer != null:
		mixer.duck(severity)


func _on_wave_started(_wave: int, _strength: float) -> void:
	cue(&"wave_horn", Vector2.ZERO, false)


func _on_wave_cleared(_wave: int) -> void:
	cue(&"wave_cleared", Vector2.ZERO, false)


func _on_night(_day: int) -> void:
	cue(&"nightfall", Vector2.ZERO, false)


func _on_day(_day: int) -> void:
	cue(&"daybreak", Vector2.ZERO, false)


func _on_selection_changed(_kind: StringName) -> void:
	cue(&"ui_click", Vector2.ZERO, false)


func _on_overlay_changed(_mode: StringName) -> void:
	cue(&"ui_click", Vector2.ZERO, false)


# ================================================================== helpers ==

func _cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5) * LcnAudioDefs.TILE


func _building_pos(id: int) -> Vector2:
	var sim: Node = _autoload(&"Sim")
	if sim == null or not bool(sim.get("alive")):
		return Vector2.ZERO
	var build: SimSystem = sim.call("get_system", &"build") as SimSystem
	if build == null or not build.has_method("get_building"):
		return Vector2.ZERO
	var b: Object = build.call("get_building", id)
	if b == null or not b.has_method("world_center"):
		return Vector2.ZERO
	return b.call("world_center")


func _autoload(n: StringName) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(String(n)))


# ================================================================== reading ==

## Everything a critic needs to judge the mix without listening to it.
func report() -> Dictionary:
	return {
		"frames": _frames,
		"update_usec": last_update_usec,
		"peak_update_usec": peak_update_usec,
		"cues_played": _played,
		"peak_stage_usec": _stage_usec,
		"cues_dropped": _dropped,
		"pending": _pending.size(),
		"mixer": mixer.report() if mixer != null else {},
		"bank": bank.report() if bank != null else {},
		"voices": pool.report() if pool != null else {},
		"beds": beds.report() if beds != null else {},
		"machines": chorus.report() if chorus != null else {},
		"music": music.report() if music != null else {},
		"probe": probe.report() if probe != null else {},
	}


## One log line dense enough to diagnose the mix from a harness log.
func summary() -> String:
	if pool == null or music == null or chorus == null or probe == null:
		return "audio not assembled"
	var v: Dictionary = pool.report()
	var m: Dictionary = music.report()
	return ("buses=%d voices=%d/%d peak=%d played=%d coalesced=%d stolen=%d "
		+ "culled=%d machines=%d stems=%s hearth=%.2f storm=%.2f factory=%.2f") % [
		AudioServer.bus_count, int(v["active"]), int(v["world_cap"]) + int(v["flat_cap"]),
		int(v["peak_active"]), _played, int(v["coalesced"]), int(v["stolen"]),
		int(v["culled_distance"]), chorus.audible_families(),
		JSON.stringify(m["stems"]), probe.hearth01, probe.storm01, probe.factory01]


## Writes artifacts/<out>/audio.json when the harness is driving, so the mix
## lands in the same folder as the screenshots and a critic can read what was
## audible at the moment each shot was taken.
func write_run_report() -> bool:
	if _report_written:
		return false
	var out: String = ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	if out == "":
		return false
	_report_written = true
	var base: String = ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/audio.json", FileAccess.WRITE)
	if f == null:
		Log.warn("audio", "could not write %s/audio.json" % out)
		return false
	f.store_string(JSON.stringify(report(), "  "))
	Log.info("audio", "run report → %s/audio.json — %s" % [out, summary()])
	return true

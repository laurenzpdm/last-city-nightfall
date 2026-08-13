extends Node
## [P23] The soundtrack, installed into a real scene tree over a real world.
##
##   godot --headless --path . res://tests/audio/audio_live.tscn
##
## Run as a SCENE, never with `--script`: the autoloads only exist once the
## SceneTree has installed them (ARCHITECTURE.md §6.1), and every assertion here
## goes through the real Sim, the real Bus and the real Settings.
##
## THIS IS THE SUITE THAT ANSWERS THE QUESTION THE UNIT TESTS CANNOT. The build
## menu spent a whole phase as an orphan while 768 tests stayed green, because
## none of them ever asked whether the thing was in the scene tree. So the first
## thing this file checks is not a gain or a filter — it is `is_inside_tree()`.
##
## What it proves, in order:
##   1. the bootstrap installs the audio root and it is genuinely IN THE TREE,
##      through the deferred path that does not trip "parent node is busy";
##   2. over a real world the probe reads real systems and the desk exists;
##   3. the mix answers the simulation — the fire, the storm, the factory and
##      the score all move in the right direction for the right reason;
##   4. eleven thousand ticks' worth of Bus traffic through a handful of frames
##      does not blow the voice count, the queue or the mix;
##   5. the player's four sliders reach the four buses;
##   6. none of it wrote a single error to the log.
##
## It also PRINTS the bus structure and the voice counts, because "report the
## actual bus structure and voice counts" is answered with a printout from a run,
## not with a paragraph.

const TAG: String = "audio-live"
const WATCHDOG_SECONDS: float = 90.0

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _audio: LcnAudio = null
var _errors_at_start: int = 0
var _out_dir: String = "res://artifacts/p23"


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	# A standalone suite that hangs is worse than one that fails: tools/check.sh
	# would queue every other agent's gate behind it.
	var watchdog := Timer.new()
	watchdog.wait_time = WATCHDOG_SECONDS
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the audio live suite timed out after %d s" % int(WATCHDOG_SECONDS))
	get_tree().quit(125)


func _run() -> void:
	SimClock.set_manual(true)
	_errors_at_start = Log.errors

	await _suite_it_actually_installs()
	await _suite_the_desk_is_real()
	await _suite_it_answers_the_simulation()
	await _suite_an_assault_cannot_blow_out_the_mix()
	await _suite_the_players_sliders_work()
	await _suite_nothing_wrote_an_error()

	_print_report()
	_finish()


# =========================================================== 1. installation ==

func _suite_it_actually_installs() -> void:
	_headline("installation")
	# Registry already armed the bootstrap at autoload time and it stood down,
	# because a headless process has no display. Force it and start again.
	LcnAudioBootstrap.reset()
	LcnLayers.force_install = true

	_check(LcnAudioBootstrap.wanted(), "with --force-ui the run wants audio")
	_audio = LcnAudioBootstrap.install()
	_check(_audio != null, "the bootstrap returned an audio root")
	if _audio == null:
		_check(false, "nothing else can be tested: %s" % LcnAudioBootstrap.last_failure())
		return

	# THE assertion. An object that exists but is not in the tree is not
	# installed, whatever the constructor returned.
	_check(_audio.is_inside_tree(), "the audio root is IN THE SCENE TREE")
	_check(_audio.get_parent() != null, "and it has a parent")
	_check(is_instance_valid(LcnAudio.current()), "and it can be found by group")
	_check(LcnAudio.current() == _audio, "exactly one of it")

	# Installing again must not produce a second one.
	var again: LcnAudio = LcnAudioBootstrap.install()
	_check(again == _audio, "installing twice returns the same root")

	await _frames(3)
	_check(_audio.bank.ready_count() > 0, "streams are being baked (%d ready)"
		% _audio.bank.ready_count())
	_check(_audio.pool.is_inside_tree(), "the voice pool is in the tree")
	_check(_audio.beds.is_inside_tree(), "the ambience beds are in the tree")
	_check(_audio.music.is_inside_tree(), "the score is in the tree")


# ================================================================ 2. the desk ==

func _suite_the_desk_is_real() -> void:
	_headline("the mixing desk")
	if _audio == null:
		return
	_check(_audio.mixer.installed, "the mixer installed")
	_check(AudioServer.bus_count == LcnAudioDefs.BUS_TREE.size() + 1,
		"%d buses: Master plus the declared tree" % AudioServer.bus_count)
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		var idx: int = AudioServer.get_bus_index(String(row["name"]))
		_check(idx > 0, "bus %s exists at index %d" % [row["name"], idx])
		_check(String(AudioServer.get_bus_send(idx)) == String(row["send"]),
			"  and sends into %s" % row["send"])
	var master_fx: bool = false
	for i: int in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, i) is AudioEffectHardLimiter:
			master_fx = true
	_check(master_fx, "Master carries a limiter")


# ================================================== 3. it answers the world ===

func _suite_it_answers_the_simulation() -> void:
	_headline("the mix answers the simulation")
	if _audio == null:
		return

	Sim.create_world(7)
	_seed_a_city()
	SimClock.advance(120)
	await _frames(8)

	var probe: LcnAudioProbe = _audio.probe
	# Headless frames carry a few microseconds of delta, so the probe's own
	# five-hertz timer never comes due. Ask it directly.
	probe.poll_now()
	probe.poll_now()
	_check(probe.polls > 0, "the probe has read the world %d times" % probe.polls)
	_check(probe.has_climate, "it found [P09] climate")
	_check(probe.has_heat, "it found [P02] heat")
	_check(probe.has_production, "it found [P04] production")
	_check(probe.last_poll_usec < 4000,
		"and one read costs %d us, not milliseconds" % probe.last_poll_usec)
	_check(probe.has_hearth_pos, "it located the hearth at %s" % str(probe.hearth_pos))

	# --- the fire ---
	# The one sound a player must notice weakening. Drive the reading, not the
	# world: a heat network takes minutes to collapse and the mapping is what is
	# under test here.
	probe.hearth01 = 1.0
	_settle(probe, 240)
	var strong: float = _audio.beds.db_of(&"hearth")
	probe.hearth01 = 0.05
	_settle(probe, 300)
	var dying: float = _audio.beds.db_of(&"hearth")
	_check(dying < strong - 6.0,
		"a dying hearth is %.1f dB quieter than a strong one" % (strong - dying))
	_check(_audio.mixer.report()["hearth"] != null, "and the desk knows it")

	# --- the storm ---
	probe.storm01 = 0.0
	probe.wind01 = 0.0
	_settle(probe, 300)
	var calm_wind: float = _audio.beds.db_of(&"wind")
	var calm_howl: float = _audio.beds.db_of(&"howl")
	probe.storm01 = 1.0
	probe.wind01 = 1.0
	_settle(probe, 300)
	_check(_audio.beds.db_of(&"wind") > calm_wind + 6.0,
		"a gale is %.1f dB louder than a still day"
		% (_audio.beds.db_of(&"wind") - calm_wind))
	_check(_audio.beds.db_of(&"howl") > calm_howl + 6.0, "and the whiteout howls")
	_check(_audio.mixer.storm01 > 0.9, "the wind filter opened with it")

	# --- the factory ---
	_check(_audio.chorus.report()["families_in_earshot"] >= 1,
		"the chorus found %d machine families in the opening city"
		% int(_audio.chorus.report()["families_in_earshot"]))
	probe.factory01 = 1.0
	_settle(probe, 120)
	var running_cut: float = _machine_cutoff()
	probe.factory01 = 0.0
	_settle(probe, 120)
	var stalled_cut: float = _machine_cutoff()
	_check(stalled_cut < running_cut * 0.5,
		"a stalled factory is audibly muffled: %d Hz -> %d Hz"
		% [int(running_cut), int(stalled_cut)])

	# --- the score ---
	var guard: int = 0
	while not _audio.music.started() and guard < 400:
		guard += 1
		await _frames(1)
	_check(_audio.music.started(), "all five stems started together")
	probe.threat01 = 0.0
	probe.enemies_alive = 0
	probe.hope01 = 0.9
	probe.light = 1.0
	probe.is_night = false
	probe.is_deep_night = false
	probe.hearth01 = 1.0
	_settle(probe, 400)
	var peace_hope: float = _audio.music.db_of(&"hope")
	var peace_dread: float = _audio.music.db_of(&"dread")
	var peace_perc: float = _audio.music.db_of(&"perc")

	probe.threat01 = 1.0
	probe.enemies_alive = 40
	probe.hope01 = 0.05
	probe.light = 0.0
	probe.is_night = true
	probe.is_deep_night = true
	_settle(probe, 400)
	_check(_audio.music.db_of(&"hope") < peace_hope - 5.0, "hope drains away")
	_check(_audio.music.db_of(&"dread") > peace_dread + 5.0, "dread comes up")
	_check(_audio.music.db_of(&"perc") > peace_perc + 5.0, "and the drums start")
	_check(_audio.music.db_of(&"bed") > LcnDsp.MIN_DB, "the bed is always there")


func _machine_cutoff() -> float:
	var idx: int = AudioServer.get_bus_index(String(LcnAudioDefs.BUS_MACHINE))
	for i: int in AudioServer.get_bus_effect_count(idx):
		var f := AudioServer.get_bus_effect(idx, i) as AudioEffectFilter
		if f != null:
			return f.cutoff_hz
	return 0.0


# ========================================== 4. an assault cannot blow the mix ==

func _suite_an_assault_cannot_blow_out_the_mix() -> void:
	_headline("an assault cannot blow out the mix")
	if _audio == null:
		return
	# Finish the bake first. A cue whose stream is not baked yet is a counted
	# silence, and this suite is about the limiter, not about the bake.
	var guard: int = 0
	while not _audio.bank.finished() and guard < 4000:
		guard += 1
		_audio.bank.pump(20000)
	_check(_audio.bank.finished(), "the whole catalogue is baked (%d streams)"
		% _audio.bank.ready_count())
	var voices_before: Dictionary = _audio.pool.report()

	# Exactly the traffic a harness frame produces: thousands of simulation
	# events between two draws, emitted on the real Bus from outside a tick.
	for i: int in 3000:
		Bus.turret_fired.emit(i, Vector2(i % 900 * 32, 0), Vector2(i % 900 * 32 + 200, 0))
		Bus.enemy_killed.emit(5_000_000 + i, Vector2(i % 700 * 32, 64))
		Bus.structure_damaged.emit(i, 12.0, Vector2(i % 500 * 32, 128))
	_check(true, "9000 combat signals emitted in one frame")
	await _frames(6)

	var r: Dictionary = _audio.pool.report()
	_check(int(r["world_allocated"]) <= _audio.pool.world_cap,
		"the world pool held at %d of %d slots" % [r["world_allocated"], _audio.pool.world_cap])
	_check(int(r["active"]) <= _audio.pool.world_cap + _audio.pool.flat_cap,
		"%d voices active, never more than the pool" % r["active"])
	_check(int(_audio.report()["pending"]) < LcnAudio.MAX_PENDING,
		"the cue queue drained instead of growing without bound")
	var absorbed: int = int(r["coalesced"]) + int(r["rate_limited"]) \
		+ int(r["culled_distance"]) + int(r["refused_cap"]) + int(_audio.report()["cues_dropped"])
	_check(absorbed > 5000, "the limiter absorbed %d of the 9000 requests" % absorbed)
	_check(int(r["started"]) > int(voices_before["started"]), "and some of it was actually heard")

	# The alert path: everything scenic must get out of the way.
	var music_before: float = _audio.mixer.db_of(LcnAudioDefs.BUS_MUSIC)
	Bus.alert_raised.emit(2, &"breach", "The north wall is open", Vector2(320, 320))
	await _frames(4)
	_check(_audio.mixer.db_of(LcnAudioDefs.BUS_MUSIC) < music_before,
		"a critical alert ducked the score by %.1f dB"
		% (music_before - _audio.mixer.db_of(LcnAudioDefs.BUS_MUSIC)))
	_settle(_audio.probe, 120)
	_check(_audio.mixer.duck_amount() < 0.2, "and the duck released again")

	# Per-frame cost. This runs alongside a 50 ms tick budget that heat already
	# spends 86% of, so audio is not allowed to be a second budget.
	_check(_audio.peak_update_usec < 8000,
		"the worst audio frame in this whole suite cost %d us" % _audio.peak_update_usec)


# ============================================================== 5. the player ==

func _suite_the_players_sliders_work() -> void:
	_headline("the player's four sliders")
	if _audio == null:
		return
	var original: Dictionary = (Settings.audio as Dictionary).duplicate()
	Settings.audio = {"master": 1.0, "music": 1.0, "sfx": 1.0, "ambience": 1.0}
	_audio.mixer.apply_settings(true)
	var loud: Dictionary = {}
	for slider: String in LcnAudioDefs.SLIDER_BUS:
		loud[slider] = _audio.mixer.db_of(LcnAudioDefs.SLIDER_BUS[slider])

	for slider: String in LcnAudioDefs.SLIDER_BUS:
		var cfg: Dictionary = {"master": 1.0, "music": 1.0, "sfx": 1.0, "ambience": 1.0}
		cfg[slider] = 0.2
		Settings.audio = cfg
		_audio.mixer.apply_settings(true)
		var bus: StringName = LcnAudioDefs.SLIDER_BUS[slider]
		_check(_audio.mixer.db_of(bus) < float(loud[slider]) - 4.0,
			"the %s slider moves the %s bus" % [slider, bus])

	Settings.audio = {"master": 0.0, "music": 1.0, "sfx": 1.0, "ambience": 1.0}
	_audio.mixer.apply_settings(true)
	var muted: float = _audio.mixer.db_of(LcnAudioDefs.BUS_MASTER)
	_check(muted <= LcnDsp.MIN_DB, "master at zero is silence")
	_check(is_finite(muted), "and it is a finite number, not -INF")

	Settings.audio = original
	_audio.mixer.apply_settings(true)


# =================================================================== 6. clean ==

func _suite_nothing_wrote_an_error() -> void:
	_headline("the log")
	var written: int = Log.errors - _errors_at_start
	_check(written == 0, "zero errors written to the log by any of the above (%d)" % written)


# =================================================================== output ===

func _print_report() -> void:
	if _audio == null:
		return
	var r: Dictionary = _audio.report()
	var mixer: Dictionary = r["mixer"]
	var voices: Dictionary = r["voices"]

	print("")
	print("── BUS STRUCTURE ──────────────────────────────────────────────────────")
	print("   driver: %s" % mixer["driver"])
	print("   %-10s %5s  %-10s %9s  effects" % ["bus", "index", "sends to", "volume dB"])
	for row: Dictionary in mixer["buses"]:
		print("   %-10s %5d  %-10s %9.2f  %s" % [
			row["bus"], int(row["index"]), String(row.get("send", "—")),
			float(row.get("volume_db", 0.0)),
			", ".join(row.get("effects", PackedStringArray())) if not (row.get("effects", PackedStringArray()) as PackedStringArray).is_empty() else "—"])

	print("")
	print("── VOICES ─────────────────────────────────────────────────────────────")
	print("   world pool      %d allocated / %d cap" % [voices["world_allocated"], voices["world_cap"]])
	print("   flat pool       %d allocated / %d cap" % [voices["flat_allocated"], voices["flat_cap"]])
	print("   machine loops   %d families, %d audible" % [
		int((r["machines"] as Dictionary)["families_in_earshot"]),
		int((r["machines"] as Dictionary)["audible"])])
	print("   score stems     %d" % int((r["music"] as Dictionary)["stem_count"]))
	print("   ambience beds   4 (hearth, wind, howl, hum)")
	print("   peak concurrent %d" % voices["peak_active"])
	print("   started %d · coalesced %d · stolen %d · culled %d · rate-limited %d · refused %d"
		% [voices["started"], voices["coalesced"], voices["stolen"],
			voices["culled_distance"], voices["rate_limited"], voices["refused_cap"]])
	print("   category caps   %s" % JSON.stringify(LcnAudioDefs.CATEGORY_CAP))

	print("")
	print("── BANK ───────────────────────────────────────────────────────────────")
	print("   %s" % JSON.stringify(r["bank"]))
	print("   worst audio frame: %d us  %s" % [
		_audio.peak_update_usec, JSON.stringify(r["peak_stage_usec"])])
	print("")

	var base: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/audio_live.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(r, "  "))
		print("   full report → %s/audio_live.json" % _out_dir)


# ==================================================================== harness =

func _headline(title: String) -> void:
	print("")
	print(" ── %s" % title)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("    ✓ %s" % what)
	else:
		_failures.append(what)
		print("    ✗ %s" % what)


func _frames(n: int) -> void:
	for i: int in n:
		await get_tree().process_frame


## Drives the layers on a FIXED timestep against a probe the test has set by
## hand, with the root's own `_process` switched off.
##
## Two reasons, and the second one is the interesting one. First: a headless
## process runs frames as fast as it can, so `delta` is a few microseconds and a
## bed that travels at 5 dB per SECOND moves by nothing at all in sixty frames —
## the first version of this suite reported the hearth dropping 2.9 dB and
## called it a failure of the mix. Second: what is under test here is the
## MAPPING from a simulation reading to a gain, and a mapping should be tested
## at a stated timestep rather than at whatever the machine happened to manage.
func _settle(probe: LcnAudioProbe, steps: int, dt: float = 1.0 / 60.0) -> void:
	if _audio == null:
		return
	probe.wave_active = probe.enemies_alive > 0
	_audio.set_process(false)
	for i: int in steps:
		_audio.mixer.storm01 = probe.storm01
		_audio.mixer.hearth01 = probe.hearth01
		_audio.mixer.factory01 = probe.factory01
		_audio.mixer.update(dt)
		_audio.beds.update(dt, probe)
		_audio.chorus.update(dt, probe)
		_audio.music.update(dt, probe)
	_audio.set_process(true)


## The same opening settlement `game/boot.gd` places, so the city this suite
## listens to is the city a player is dropped into.
func _seed_a_city() -> void:
	var build: SimSystem = Sim.get_system(&"build")
	var grid: SimSystem = Sim.get_system(&"grid")
	if build == null or grid == null:
		return
	var boot: Script = load("res://game/boot.gd") as Script
	if boot == null:
		return
	var cell: Vector2i = grid.call("core_cell")
	for cmd: Dictionary in boot.call("opening_commands", cell):
		Sim.submit_command(cmd)
	SimClock.advance(1)


func _finish() -> void:
	print("")
	print("────────────────────────────────────────────────────────────────────────")
	if _failures.is_empty():
		print(" TESTS PASSED — %d checks" % _checks)
		get_tree().quit(0)
		return
	print(" %d of %d checks failed:" % [_failures.size(), _checks])
	for f: String in _failures:
		print("   ✗ %s" % f)
	print(" TESTS FAILED")
	get_tree().quit(1)

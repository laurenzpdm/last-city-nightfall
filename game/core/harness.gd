class_name LcnHarness
extends Node
## Automated-run driver. Inert unless --harness is on the command line.
##
## `class_name` so `tests/gate/` can hold the beat vocabulary below to the same
## standard as everything else without instantiating the autoload.
##
## This is the thing that lets a critic judge the ACTUAL BUILD instead of a
## builder's summary: it plays a scripted scenario against the real simulation
## and writes out state, per-tick metrics, the log, and real screenshots.
##
##   godot --headless -- --harness --scenario=first_night --ticks=12000 --out=artifacts/a
##   godot          -- --harness --visual --scenario=first_night --out=artifacts/vis
##
## A visual run QUITS when the last shot is written, exactly like a headless one.
## Pass --stay-open when a human wants to keep playing the scenario afterwards.

## ── A BEAT IS NAMED FOR A MOMENT, AND THE NAME IS THE CONTRACT ────────────────
##
## A scenario's `shots` array names its beats — `midday`, `dusk`, `deep_night`,
## `second_night`, `assault` — and pins each one to a hand-written sim tick.
## Those ticks were written when a run began at tick 0 of day 1. It does not:
## `ClimateProfile.opening_tick` is 2016 and every beat slid by most of a phase.
## Measured on the shipped build (`artifacts/G4_base/metrics.csv`, first_night,
## seed 7): `midday` photographed DUSK, `dusk` photographed NIGHT, `deep_night`
## photographed MORNING OF DAY 2, `second_dusk` photographed NIGHT,
## `second_night` photographed DAWN OF DAY 3, and `assault` was taken at t7200
## when the last enemy had died at t6800. Six of eleven, for four waves, with
## nothing in any artifact saying so — so every art and interface judgement made
## from those frames was made about a moment the label denied.
##
## The tick is now a HINT and the name is the CONTRACT. Before the run, the
## harness asks [P09] where the clock will actually be (`ClimateForecast`, which
## walks the profile and the scenario's own `skip_to_phase` commands) and moves
## each beat to the nearest tick that is genuinely the phase and the day its name
## claims. A beat already standing in the right phase does not move. A claim the
## scenario never reaches is NOT PHOTOGRAPHED AT ALL — a missing file with the
## reason in `state.json` beats a PNG whose name is a lie — and the standing list
## of those is `tests/gate/screenshot_paths.json` -> misnamed_beats, which is
## owned, asserted and not allowed to grow.
##
## `tests/gate/test_shot_beats.gd` holds this whole path — vocabulary, forecast
## and re-aim — against a live `ClimateSystem`, so `deep_night` cannot be
## photographed at morning without the gate going red.
##
## Phase words a beat name may use, and the [P09] phase each one claims.
## `deep_night` is matched before `night`, and `midday`/`noon` claim AFTERNOON
## because that is the phase the sun peaks in (`sun_key_progress` 0.44, and
## afternoon spans day progress 0.32–0.56).
const BEAT_PHASE_WORDS: Dictionary = {
	"dawn": ClimateDefs.Phase.DAWN,
	"sunrise": ClimateDefs.Phase.DAWN,
	"morning": ClimateDefs.Phase.MORNING,
	"midday": ClimateDefs.Phase.AFTERNOON,
	"noon": ClimateDefs.Phase.AFTERNOON,
	"afternoon": ClimateDefs.Phase.AFTERNOON,
	"dusk": ClimateDefs.Phase.DUSK,
	"sunset": ClimateDefs.Phase.DUSK,
	"nightfall": ClimateDefs.Phase.DUSK,
	"night": ClimateDefs.Phase.NIGHT,
	"midnight": ClimateDefs.Phase.DEEP_NIGHT,
}

## Ordinals a beat name may use for the campaign day. `second_dusk` is dusk on
## day two, and a beat that says so must not be photographed on day three.
const BEAT_DAY_WORDS: Dictionary = {
	"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
	"sixth": 6, "seventh": 7,
}

## Words that claim the world rather than the clock: there must be something
## alive and hostile in the frame. Not predictable from a profile — [P08] decides
## when a wave lands — so these fire live, at the first tick from the beat's
## re-aimed position where the claim is true.
const BEAT_LIVE_WORDS: Array[String] = ["assault", "battle", "siege", "attack", "raid"]

## The layer at or above which nothing may be in a harness photograph. The HUD,
## the story card, the guide strip and [P18]'s panels are all legitimately what a
## player is looking at; a surface that has STOPPED THE WORLD never is.
const SHOT_CEILING: int = LcnLayers.MODAL - 1

signal finished()

var active: bool = false
var visual: bool = false
var stay_open: bool = false

var _scenario: Dictionary = {}
var _out_dir: String = "res://artifacts/run"
var _ticks: int = 6000
var _seed: int = 7
var _sample_every: int = 20
var _script_by_tick: Dictionary[int, Array] = {}
## One row per shot: {name, asked, tick, claim, fired, phase, day, live, ok, why}.
## `asked` is what the scenario wrote; `tick` is where the beat's own name put it.
var _beats: Array[Dictionary] = []
## Re-aimed tick -> indices into `_beats`, for the ones with no live claim.
var _beats_by_tick: Dictionary[int, Array] = {}
var _shutter: LcnShutter = null
var _metric_keys: PackedStringArray = PackedStringArray()
var _metric_rows: Array[PackedStringArray] = []
var _checkpoints: Dictionary = {}
var _errors: PackedStringArray = PackedStringArray()
## Tick the run ended on, and why. -1 while the city is still somebody's.
##
## THE RUN CAN END LONG BEFORE THE TICK BUDGET DOES, AND THE ARTIFACTS DID NOT
## SAY SO. `LcnPlayController` stops the clock on `Bus.game_over` for a human,
## and deliberately not here — `SimClock` is manual in a harness run, so a
## scenario replays to its last tick whatever happens, which is what keeps
## determinism cheap. What was missing is the sentence saying it happened.
##
## Measured on `economy_60min`: the council was put out of its own gate at
## t=31000, [P22] wrote the epilogue "The City Did Not Stand", and the harness
## then simulated 41,000 further ticks — four more days, four more waves
## (including one of 172 units), eight children dead of fever — and wrote a
## `final` state of a city that had been over for two thirds of the run, with
## `errors: []` and nothing anywhere in `state.json` to say which two thirds.
## Every critic reading those artifacts is reading a corpse and grading a city.
var _end_tick: int = -1
var _end_reason: String = ""


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.has("--harness"):
		return
	active = true
	visual = args.has("--visual")
	stay_open = args.has("--stay-open")
	Log.capture = true
	Log.min_level = Log.Level.DEBUG
	for a: String in args:
		if a.begins_with("--scenario="):
			_load_scenario(a.substr(11))
		elif a.begins_with("--ticks="):
			_ticks = int(a.substr(8))
		elif a.begins_with("--seed="):
			_seed = int(a.substr(7))
		elif a.begins_with("--out="):
			_out_dir = a.substr(6)
		elif a.begins_with("--sample="):
			_sample_every = maxi(1, int(a.substr(9)))
	call_deferred("_run")


func _load_scenario(name: String) -> void:
	var path: String = name if name.begins_with("res://") else "res://tests/scenarios/%s.json" % name
	if not FileAccess.file_exists(path):
		push_error("harness: no scenario at %s" % path)
		return
	var txt: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("harness: scenario %s is not valid JSON" % path)
		return
	_scenario = parsed
	_seed = int(_scenario.get("seed", _seed))
	_ticks = int(_scenario.get("ticks", _ticks))
	_sample_every = maxi(1, int(_scenario.get("sample_every", _sample_every)))
	for entry: Dictionary in _scenario.get("script", []):
		var t: int = int(entry.get("tick", 0))
		var arr: Array = _script_by_tick.get(t, [])
		arr.append(entry.get("cmd", {}))
		_script_by_tick[t] = arr
	for shot: Dictionary in _scenario.get("shots", []):
		var beat_name: String = String(shot.get("name", "shot"))
		# An explicit `phase` / `day` on the shot wins over anything read out of
		# its name: a scenario author who states the claim outright should not
		# have to spell it in the filename too.
		var claim: Dictionary = beat_claim(beat_name)
		if shot.has("phase"):
			claim["phase"] = ClimateDefs.PHASE_NAMES.find(
				StringName(String(shot.get("phase", ""))))
		if shot.has("day"):
			claim["day"] = int(shot.get("day", -1))
		_beats.append({
			"name": beat_name,
			"asked": int(shot.get("tick", 0)),
			"tick": int(shot.get("tick", 0)),
			"claim": claim,
			"fired": -1, "phase": "", "day": -1, "live": 0,
			# `ok` is "this photograph is what its name says". `fatal` is "and
			# that is THIS run's fault": a beat the scenario could have delivered
			# and did not fails the run, while a beat whose scenario never
			# reaches the moment it names is somebody else's one-line fix and is
			# carried in tests/gate/screenshot_paths.json instead.
			"ok": true, "fatal": true, "why": "",
		})


## WHAT A BEAT NAME PROMISES. Returns {phase:int, day:int, live:bool}, with -1
## for "claims nothing about this". Static, and public, because `tests/gate/`
## asserts the vocabulary against every shipped scenario and a parser that only
## its own author can call is a parser nobody checks.
##
## `deep_night` is two tokens and has to be looked for before `night`, or every
## deep-night beat in the repository silently claims the wrong phase — which is
## the same class of one-word slip that put the tour in front of a main menu.
static func beat_claim(beat_name: String) -> Dictionary:
	var tokens: PackedStringArray = beat_name.to_lower().split("_", false)
	var phase: int = -1
	var day: int = -1
	var live: bool = false
	for i: int in tokens.size():
		var w: String = tokens[i]
		if w == "deep" and i + 1 < tokens.size() and tokens[i + 1] == "night":
			phase = ClimateDefs.Phase.DEEP_NIGHT
			continue
		if w == "night" and i > 0 and tokens[i - 1] == "deep":
			continue
		if phase < 0 and BEAT_PHASE_WORDS.has(w):
			phase = int(BEAT_PHASE_WORDS[w])
		if day < 0 and BEAT_DAY_WORDS.has(w):
			day = int(BEAT_DAY_WORDS[w])
		if day < 0 and w.begins_with("day") and w.length() > 3 and w.substr(3).is_valid_int():
			day = int(w.substr(3))
		if BEAT_LIVE_WORDS.has(w):
			live = true
	return {"phase": phase, "day": day, "live": live}


func _run() -> void:
	var t0: int = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir + "/shots"))

	SimClock.set_manual(true)
	Sim.create_world(_seed)
	Bus.alert_raised.connect(_on_alert)
	Bus.game_over.connect(_on_game_over)
	_aim_the_beats()

	var checkpoint_every: int = maxi(1, _ticks / 8)
	for t: int in range(1, _ticks + 1):
		for cmd: Dictionary in _script_by_tick.get(t, []):
			Sim.submit_command(cmd)
		SimClock.advance(1)
		if t % _sample_every == 0:
			_sample()
		if t % checkpoint_every == 0:
			_checkpoints[str(t)] = Sim.serialize()
		if visual:
			for idx: int in _beats_by_tick.get(t, []):
				await _shoot(idx)
			await _fire_live_beats(t)
	if visual:
		_close_the_beats()

	var wall_ms: int = Time.get_ticks_msec() - t0
	# A logged error IS a run error. Counting only severity>=2 Bus alerts meant
	# the gate could never fire: nothing in the build emits above severity 1.
	#
	# TOTAL, not a delta from the start of the tick loop. The delta version
	# excluded everything that happened before `_run` — which is to say the
	# entire installation of the view and the entire construction of the world.
	# Boot can now report "the build menu is not in the scene tree" as an ERROR,
	# and under the old arithmetic the harness would still have exited 0.
	var logged: int = Log.errors
	if logged > 0:
		_errors.append("%d error(s) written to the log" % logged)
	# The engine's own count of nodes that exist and are in no tree. A settled
	# run has none; anything above zero was built and then dropped — which is
	# the general shape of the orphan-CanvasLayer bug, without needing a list of
	# subsystems to keep up to date.
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	if orphans > 0:
		_errors.append("%d orphan node(s) at the end of the run" % orphans)
	var allowed: int = int((_scenario.get("expects", {}) as Dictionary).get("max_errors", 0))
	var failed: bool = _errors.size() > allowed
	_write_outputs(wall_ms)
	var ending: String = ""
	if _end_tick >= 0:
		ending = " — THE RUN ENDED AT t%d (%s) and %d tick(s) were simulated after it" % [
			_end_tick, _end_reason, _ticks - _end_tick]
	Log.info("harness", "done in %d ms (%d ticks), %d error(s), allowed %d%s" % [
		wall_ms, _ticks, _errors.size(), allowed, ending])
	finished.emit()
	if visual and stay_open:
		Log.info("harness", "--stay-open: the window is yours")
		return
	get_tree().quit(1 if failed else 0)


func _sample() -> void:
	var m: Dictionary = Sim.collect_metrics()
	if _metric_keys.is_empty():
		var keys: Array = m.keys()
		keys.sort()
		_metric_keys = PackedStringArray(keys)
	var row := PackedStringArray()
	for k: String in _metric_keys:
		row.append(str(m.get(k, "")))
	_metric_rows.append(row)


# =========================================================== aiming a beat ==

## Moves every beat to the tick its own NAME asks for. Runs once, after the
## world exists (so the live [P09] profile is the one consulted) and before the
## first tick, because a photograph cannot be taken again afterwards.
func _aim_the_beats() -> void:
	if _beats.is_empty():
		return
	_beats_by_tick.clear()
	var climate: SimSystem = Sim.by_name.get(&"climate")
	var profile: ClimateProfile = null
	if climate != null and climate.has_method(&"profile"):
		profile = climate.call(&"profile") as ClimateProfile
	var forecast: ClimateForecast = null
	if profile != null:
		forecast = ClimateForecast.of(profile, _script_by_tick, _ticks)
	for i: int in _beats.size():
		var b: Dictionary = _beats[i]
		var claim: Dictionary = b["claim"]
		var phase: int = int(claim["phase"])
		var day: int = int(claim["day"])
		if (phase >= 0 or day >= 0) and forecast == null:
			b["ok"] = false
			b["why"] = ("claims %s but this build has no climate profile to aim by"
				% _claim_text(claim))
		elif phase >= 0 or day >= 0:
			var want: int = aim(forecast, claim, int(b["asked"]))
			if want < 0:
				# UNREACHABLE, so it is NOT PHOTOGRAPHED. There is no honest tick
				# for a beat called `dawn_wide` in a 600-tick scenario that begins
				# in the morning and never comes back round, and taking the
				# picture anyway is precisely the four-wave defect this file is
				# closing. A warning and a missing file, with the reason recorded
				# in `state.json`, beats a PNG whose name is a lie.
				#
				# Not an error: the fix lives in the scenario, which is somebody
				# else's file, and a run that goes red for another part's data
				# stops being a gate and becomes an obstacle. The standing list of
				# these is `tests/gate/screenshot_paths.json` -> misnamed_beats,
				# which is asserted, owned and not allowed to grow.
				b["ok"] = false
				b["fatal"] = false
				b["why"] = ("claims %s, and this scenario never gets there in %d tick(s) "
					+ "— no photograph was taken rather than one with a false name") % [
					_claim_text(claim), _ticks]
				Log.warn("harness", "beat '%s': %s" % [String(b["name"]), String(b["why"])])
			else:
				b["tick"] = want
				if want != b["asked"]:
					Log.info("harness", "beat '%s' asked for t%d, which is %s — re-aimed to t%d, which is %s"
						% [String(b["name"]), int(b["asked"]),
							_moment_text(forecast, int(b["asked"])),
							want, _moment_text(forecast, want)])
		_beats[i] = b
		if bool(claim["live"]) or not bool(b["ok"]):
			continue
		var arr: Array = _beats_by_tick.get(int(b["tick"]), [])
		arr.append(i)
		_beats_by_tick[int(b["tick"])] = arr
	var claimed: int = 0
	var moved: int = 0
	for b2: Dictionary in _beats:
		var c2: Dictionary = b2["claim"]
		if int(c2["phase"]) >= 0 or int(c2["day"]) >= 0 or bool(c2["live"]):
			claimed += 1
		if int(b2["tick"]) != int(b2["asked"]):
			moved += 1
	Log.info("harness", "%d beat(s), %d of them named for a moment, %d re-aimed onto it"
		% [_beats.size(), claimed, moved])


## THE TICK A BEAT IS ACTUALLY PHOTOGRAPHED AT, or -1 when the scenario never
## reaches the moment the beat is named for.
##
## Static and public so `tests/gate/test_shot_beats.gd` can ask the SAME function
## the harness asks and hold its answer against a live `ClimateSystem`. A test
## that re-implements the aiming it is checking proves only that two copies of
## one mistake agree.
static func aim(forecast: ClimateForecast, claim: Dictionary, asked: int) -> int:
	if forecast == null:
		return -1
	return forecast.nearest(asked, int(claim["phase"]), int(claim["day"]))


static func _claim_text(claim: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if int(claim["phase"]) >= 0:
		parts.append(ClimateDefs.phase_label(int(claim["phase"])))
	if int(claim["day"]) >= 0:
		parts.append("day %d" % int(claim["day"]))
	if bool(claim["live"]):
		parts.append("something alive and hostile in the frame")
	return " on ".join(parts) if not parts.is_empty() else "nothing in particular"


static func _moment_text(f: ClimateForecast, tick: int) -> String:
	if f == null or f.phase_at(tick) < 0:
		return "outside the run"
	return "%s of day %d" % [ClimateDefs.phase_label(f.phase_at(tick)), f.day_at(tick)]


## Beats whose claim is about the WORLD and not the clock. [P08] decides when a
## wave lands, so these cannot be planned: the beat is armed at its re-aimed tick
## and fires at the first tick from there where the claim is actually true.
##
## `assault` at t7200 in `first_night` is why this exists. The last enemy of the
## first night died at t6800, so the beat photographed an empty snowfield and a
## critic wrote "assault shows after the battle" — accurately.
func _fire_live_beats(t: int) -> void:
	var armed: Array[int] = []
	for i: int in _beats.size():
		var b: Dictionary = _beats[i]
		if int(b["fired"]) >= 0 or not bool(b["ok"]):
			continue
		if bool((b["claim"] as Dictionary)["live"]) and t >= int(b["tick"]):
			armed.append(i)
	# Asked once, not once per beat, and not at all on the overwhelming majority
	# of ticks where nothing is waiting: this runs 24000 times a run.
	if armed.is_empty() or _live_enemies() <= 0:
		return
	for idx: int in armed:
		await _shoot(idx)


## Enemies the player would see coming. Asked of [P07] first because that is
## what is actually drawn; [P08]'s count is the fallback for a build with no
## combat system in it.
func _live_enemies() -> int:
	var combat: SimSystem = Sim.by_name.get(&"combat")
	if combat != null and combat.has_method(&"live_enemy_count"):
		return int(combat.call(&"live_enemy_count"))
	var threat: SimSystem = Sim.by_name.get(&"threat")
	if threat != null and threat.has_method(&"metrics"):
		return int((threat.call(&"metrics") as Dictionary).get("live", 0))
	return 0


## A beat that never fired is a beat whose name was a promise the run did not
## keep, and it is a RUN FAILURE — not a missing file somebody notices later.
func _close_the_beats() -> void:
	for i: int in _beats.size():
		var b: Dictionary = _beats[i]
		if int(b["fired"]) >= 0:
			continue
		if bool(b["ok"]):
			b["ok"] = false
			b["why"] = ("armed at t%d and never fired — %s was never true before the run ended"
				% [int(b["tick"]), _claim_text(b["claim"])])
		_beats[i] = b
	for b2: Dictionary in _beats:
		if bool(b2["ok"]) or not bool(b2["fatal"]):
			continue
		_errors.append("beat '%s': %s" % [String(b2["name"]), String(b2["why"])])
		Log.error("harness", "beat '%s': %s" % [String(b2["name"]), String(b2["why"])])
	if _shutter == null:
		return
	for g: String in _shutter.failures():
		_errors.append("shutter: %s" % g)
		Log.error("harness", "GUARD %s" % g)
	for u: String in _shutter.unchecked():
		Log.info("harness", "UNCHECKED %s — the viewport handed back no image" % u)


# ============================================================== the shutter ==

func _shoot(index: int) -> void:
	var b: Dictionary = _beats[index]
	var name: String = String(b["name"])
	# Two frames, not one: the first lets _process see the new sim state and
	# stream in any terrain the camera just moved onto, the second draws it.
	# Shooting after a single frame photographs the previous tick.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	if _shutter == null:
		_shutter = LcnShutter.new(SHOT_CEILING, "the running game", LcnLayers.MODAL)
	# WHAT THE PHOTOGRAPH IS OF, recorded FROM THE RUNNING WORLD at the instant
	# the shutter opens. The re-aim above is a prediction; this is the fact, and
	# the two are compared below. A prediction nobody checks against the weather
	# is a horoscope, and this project has already shipped four waves of frames
	# labelled with a phase they were not showing.
	var climate: SimSystem = Sim.by_name.get(&"climate")
	var phase: String = ""
	var day: int = -1
	if climate != null and climate.has_method(&"phase_of_day"):
		phase = String(climate.call(&"phase_of_day"))
		day = int(climate.call(&"day"))
	b["fired"] = SimClock.tick
	b["phase"] = phase
	b["day"] = day
	b["live"] = _live_enemies()
	var claim: Dictionary = b["claim"]
	var want_phase: int = int(claim["phase"])
	if want_phase >= 0 and phase != String(ClimateDefs.phase_name(want_phase)):
		b["ok"] = false
		b["why"] = "named for %s and photographed at %s" % [
			ClimateDefs.phase_label(want_phase), phase]
	elif int(claim["day"]) >= 0 and day != int(claim["day"]):
		b["ok"] = false
		b["why"] = "named for day %d and photographed on day %d" % [int(claim["day"]), day]
	elif bool(claim["live"]) and int(b["live"]) <= 0:
		b["ok"] = false
		b["why"] = "named for a battle and photographed with nothing alive in the frame"
	_beats[index] = b

	var img: Image = _shutter.shoot(get_tree(), name)
	_shutter.restore()
	_save(img, name)
	Log.info("harness", "shot %s at t%d — %s of day %d, %d hostile(s) alive%s" % [
		name, int(b["fired"]), phase, day, int(b["live"]),
		"" if bool(b["ok"]) else "  ** %s **" % String(b["why"])])

	# A card sitting over the middle of the screen is what a player sees, so the
	# shot above keeps it. But [P22]'s event cards are opaque and undismissed for
	# the whole of an automated run — nobody is here to press Read — so EVERY
	# frame this tour produced was a photograph of a panel rather than of the
	# game. A critic judging the build by its screenshots was judging the modal.
	#
	# So take the world as well, with the modal layers hidden for the capture and
	# restored immediately. Presentation only: NarrativeCard.dismiss_current()
	# exists and would be the honest way to put a card away, but it answers a
	# dilemma by taking its first option, and a visual run that makes a decision a
	# headless run of the same scenario does not would break determinism — the
	# rule this whole harness exists to protect.
	if not _anything_over_the_world():
		return
	# STRIP FIRST, THEN LET IT REDRAW, THEN READ. `visible = false` does not
	# reach into a frame the GPU has already drawn, so hiding and reading in one
	# breath produces the frame WITH the chrome still in it under a filename
	# promising it was taken off. That is exactly what these eleven files were
	# for a whole round of this wave — measured at 1 to 4 grey levels away from
	# the shot they were supposed to differ from — and the DIFF guard is what
	# noticed. Same shutter, lower ceiling: here the picture is the CITY, so
	# everything from the story card up comes off. `forbidden` does not move; a
	# stopped world is never in a harness frame either way.
	var world_shot: String = name + ".world"
	_shutter.ceiling = LcnLayers.NARRATIVE - 1
	_shutter.strip(get_tree(), world_shot)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var world_img: Image = _shutter.capture(get_tree(), world_shot)
	_shutter.ceiling = SHOT_CEILING
	_shutter.restore()
	_save(world_img, world_shot)
	Log.info("harness", "shot %s — the city with the chrome taken off" % world_shot)


func _anything_over_the_world() -> bool:
	for cl: CanvasLayer in _all_canvas_layers(get_tree().root):
		if cl.visible and cl.layer >= LcnLayers.NARRATIVE:
			return true
	return false


func _save(img: Image, name: String) -> void:
	if img == null:
		# UNCHECKED, not an error: the shutter already recorded it, and a display
		# server that hands back nothing is a fact about the machine.
		return
	img.save_png(ProjectSettings.globalize_path("%s/shots/%s.png" % [_out_dir, name]))


func _all_canvas_layers(from: Node) -> Array[CanvasLayer]:
	var out: Array[CanvasLayer] = []
	for child: Node in from.get_children():
		var cl := child as CanvasLayer
		if cl != null:
			out.append(cl)
		out.append_array(_all_canvas_layers(child))
	return out


func _on_alert(severity: int, key: StringName, text: String, _pos: Vector2) -> void:
	if severity >= 2:
		_errors.append("[t%d] %s: %s" % [SimClock.tick, key, text])


## The city stopped being anybody's. Recorded once — a run can raise it twice
## (the hearth falls and then the last citizen dies) and the moment that matters
## is the first one.
func _on_game_over(reason: String) -> void:
	if _end_tick >= 0:
		return
	_end_tick = SimClock.tick
	_end_reason = reason
	Log.info("harness", ("THE RUN IS OVER at t%d (%s). The clock is manual in a "
		+ "harness run, so the remaining ticks still replay — everything after "
		+ "this line is a city with nobody running it.") % [_end_tick, reason])


## One row per beat, in the order the scenario wrote them: what it asked for,
## where its own name put it, and what the running world says it photographed.
func _beat_report() -> Array:
	var out: Array = []
	# A headless run photographs nothing, and a `shots` block full of rows that
	# never fired reads like eleven failures rather than like a run with no
	# camera in it.
	if not visual:
		return out
	for b: Dictionary in _beats:
		var claim: Dictionary = b["claim"]
		out.append({
			"name": b["name"],
			"asked_tick": b["asked"],
			"aimed_tick": b["tick"],
			"fired_tick": b["fired"],
			"claims": _claim_text(claim),
			# A SHOT TAKEN AFTER THE ENDING IS A PHOTOGRAPH OF A CORPSE, AND THE
			# ROW SAID `ok: true` ABOUT IT. `artifacts/play1/shots/
			# third_day_city.png` fired at t21600 on a run that ended at
			# t20980; the frame has [P22]'s "The City Did Not Stand" card in the
			# middle of it and every panel around that card still forecasting
			# the next wave. `ended` at the top of this file says the run
			# stopped; only this line can say WHICH photographs are after it.
			"photographed": ("%s of day %d, %d hostile(s) alive%s" % [
				String(b["phase"]), int(b["day"]), int(b["live"]),
				"" if _end_tick < 0 or int(b["fired"]) < _end_tick
					else " — AFTER THE RUN ENDED (%s at t%d)" % [_end_reason, _end_tick]])
				if int(b["fired"]) >= 0 else "nothing — it never fired",
			"ok": b["ok"],
			"fails_the_run": b["fatal"],
			"why": b["why"],
		})
	return out


func _write_outputs(wall_ms: int) -> void:
	var base: String = ProjectSettings.globalize_path(_out_dir)

	var sf := FileAccess.open(base + "/state.json", FileAccess.WRITE)
	if sf != null:
		sf.store_string(JSON.stringify({
			"scenario": _scenario.get("name", "adhoc"),
			"seed": _seed, "ticks": _ticks,
			"wall_ms": wall_ms,
			# Top level, beside "errors", because it is the same kind of fact: a
			# reader deciding whether to trust `final` has to see it without
			# knowing that [P06] keeps a `verdict` block.
			"ended": {} if _end_tick < 0 else {
				"tick": _end_tick, "reason": _end_reason,
				"ticks_simulated_after": _ticks - _end_tick,
			},
			# WHAT EACH PHOTOGRAPH IS ACTUALLY OF. Top level, beside "errors",
			# because a critic reading `shots/dusk.png` has no other way to find
			# out that it was taken at night — which is what every one of these
			# files said for four waves.
			"shots": _beat_report(),
			"final": Sim.serialize(),
			"checkpoints": _checkpoints,
			"errors": _errors,
		}, "  "))

	var mf := FileAccess.open(base + "/metrics.csv", FileAccess.WRITE)
	if mf != null:
		mf.store_line(",".join(_metric_keys))
		for row: PackedStringArray in _metric_rows:
			mf.store_line(",".join(row))

	var lf := FileAccess.open(base + "/log.txt", FileAccess.WRITE)
	if lf != null:
		for line: String in Log.drain():
			lf.store_line(line)

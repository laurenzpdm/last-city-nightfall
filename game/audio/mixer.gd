class_name LcnAudioMixer
extends RefCounted
## [P23] The desk. Builds the bus graph, wires it to Settings.audio, and owns
## every gain that moves at runtime.
##
## The graph is created in code rather than shipped as a bus layout, because
## `project.godot` is integrator-owned and a ten-bus layout resource is exactly
## the kind of shared file twenty parts cannot edit at once. `AudioServer` can
## build the same thing at boot in well under a millisecond, and building it in
## code means `tests/audio/test_mixer.gd` can assert the graph instead of
## trusting a binary.
##
##   Master ── limiter
##     ├─ Music     ← compressor, sidechained to Alert
##     ├─ Ambience  ← compressor, sidechained to Alert
##     │    ├─ Wind    ← bandpass, cutoff and resonance driven by the storm
##     │    └─ Hearth  ← lowpass, closing as the fire weakens
##     └─ Sfx
##          ├─ Machine ← lowpass + compressor: the factory goes dull when it stalls
##          ├─ Combat
##          ├─ Ui
##          └─ Alert
##
## Godot only lets a bus send to a LOWER index, so the creation order in
## [LcnAudioDefs].BUS_TREE is the graph. Everything is idempotent: a second
## install finds the buses by name and rewires nothing.
##
## THE FOUR SLIDERS the player owns are master / music / ambience / sfx, read
## from `Settings.audio` on a slow poll. Every other gain in here is the game
## talking, and it is applied on top of the player's setting, never instead.

## Buses dip this far under a critical alert, and recover over RECOVER seconds.
const DUCK_DB: float = -7.0
const DUCK_ATTACK: float = 0.06
const DUCK_RECOVER: float = 0.9

## Wind filter travel, from a still day to a whiteout.
const WIND_CUT_CALM: float = 320.0
const WIND_CUT_GALE: float = 1500.0
const WIND_Q_CALM: float = 0.8
const WIND_Q_GALE: float = 6.0

## Hearth filter travel. A dying fire loses its top before it loses its volume,
## which is why a player notices it before the meter does.
const HEARTH_CUT_STRONG: float = 1400.0
const HEARTH_CUT_DYING: float = 220.0

## Machine filter travel. A stalled factory is muffled, not silent — the player
## must still be able to hear where it is.
const MACHINE_CUT_RUNNING: float = 9000.0
const MACHINE_CUT_STALLED: float = 700.0

var installed: bool = false

## Live 0..1 readings the layers push in. Kept here so `report()` is the one
## place a critic has to look to see what the desk thinks is going on.
var storm01: float = 0.0
var hearth01: float = 1.0
var factory01: float = 1.0

var _index: Dictionary[StringName, int] = {}
var _base_db: Dictionary[StringName, float] = {}
var _slider_db: Dictionary[StringName, float] = {}
var _duck: float = 0.0
var _duck_target: float = 0.0
var _wind_filter: AudioEffectFilter = null
var _hearth_filter: AudioEffectFilter = null
var _machine_filter: AudioEffectFilter = null
var _settings_poll: float = 0.0
var _last_settings: Dictionary = {}


# ================================================================== install ==

## Idempotent. Creates any bus that is missing, leaves any that exists alone.
func install() -> void:
	_index.clear()
	_index[LcnAudioDefs.BUS_MASTER] = 0
	_base_db[LcnAudioDefs.BUS_MASTER] = 0.0
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		var name: StringName = row["name"]
		var idx: int = AudioServer.get_bus_index(String(name))
		if idx < 0:
			idx = AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, String(name))
		AudioServer.set_bus_send(idx, String(row["send"]))
		_index[name] = idx
		_base_db[name] = float(row["db"])
		AudioServer.set_bus_volume_db(idx, float(row["db"]))
	_install_effects()
	installed = true
	apply_settings(true)
	Log.info("audio", "mixer: %d buses — %s" % [_index.size(), bus_summary()])


func _install_effects() -> void:
	# A limiter on the master is not polish, it is the thing that stops a
	# hundred-body assault from clipping the whole mix into mush.
	var master: int = _index[LcnAudioDefs.BUS_MASTER]
	if _effect_index(master, "AudioEffectHardLimiter") < 0:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.8
		lim.pre_gain_db = 0.0
		lim.release = 0.12
		AudioServer.add_bus_effect(master, lim)

	# Everything that is scenery ducks under everything that is news.
	for name: StringName in LcnAudioDefs.DUCKED_BUSES:
		var idx: int = _index.get(name, -1)
		if idx < 0 or _effect_index(idx, "AudioEffectCompressor") >= 0:
			continue
		var comp := AudioEffectCompressor.new()
		comp.threshold = -20.0
		comp.ratio = 5.0
		comp.attack_us = 12000.0
		comp.release_ms = 260.0
		comp.gain = 0.0
		comp.sidechain = String(LcnAudioDefs.BUS_ALERT)
		AudioServer.add_bus_effect(idx, comp)

	_wind_filter = _ensure_filter(LcnAudioDefs.BUS_WIND, true, WIND_CUT_CALM, WIND_Q_CALM)
	_hearth_filter = _ensure_filter(LcnAudioDefs.BUS_HEARTH, false, HEARTH_CUT_STRONG, 1.0)
	_machine_filter = _ensure_filter(LcnAudioDefs.BUS_MACHINE, false, MACHINE_CUT_RUNNING, 1.0)


func _ensure_filter(bus: StringName, band: bool, cutoff: float, res: float) -> AudioEffectFilter:
	var idx: int = _index.get(bus, -1)
	if idx < 0:
		return null
	var want: String = "AudioEffectBandPassFilter" if band else "AudioEffectLowPassFilter"
	var at: int = _effect_index(idx, want)
	if at >= 0:
		return AudioServer.get_bus_effect(idx, at) as AudioEffectFilter
	var fx: AudioEffectFilter = AudioEffectBandPassFilter.new() if band else AudioEffectLowPassFilter.new()
	fx.cutoff_hz = cutoff
	fx.resonance = res
	AudioServer.add_bus_effect(idx, fx, 0)
	return fx


func _effect_index(bus: int, class_name_wanted: String) -> int:
	for i: int in AudioServer.get_bus_effect_count(bus):
		var fx: AudioEffect = AudioServer.get_bus_effect(bus, i)
		if fx != null and fx.get_class() == class_name_wanted:
			return i
	return -1


## Removes every bus this mixer created. Only the tests need this; a running
## game keeps its desk for the life of the process.
func uninstall() -> void:
	var names: Array[StringName] = []
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		names.append(row["name"])
	names.reverse()
	for name: StringName in names:
		var idx: int = AudioServer.get_bus_index(String(name))
		if idx > 0:
			AudioServer.remove_bus(idx)
	_index.clear()
	_wind_filter = null
	_hearth_filter = null
	_machine_filter = null
	installed = false


# ================================================================== per-frame =

func update(delta: float) -> void:
	if not installed:
		return
	_settings_poll -= delta
	if _settings_poll <= 0.0:
		_settings_poll = 0.5
		apply_settings(false)

	# Ducking: fast down, slow back up, because the opposite reads as a pump.
	var rate: float = DUCK_ATTACK if _duck_target > _duck else DUCK_RECOVER
	_duck = move_toward(_duck, _duck_target, delta / maxf(0.01, rate))
	_duck_target = maxf(0.0, _duck_target - delta / DUCK_RECOVER)
	for name: StringName in LcnAudioDefs.DUCKED_BUSES:
		_write_db(name, _duck * DUCK_DB)

	_shape_filters()


## An alert of this severity just spoke. Everything scenic gets out of its way.
func duck(severity: int) -> void:
	var want: float = 0.35 if severity <= 0 else (0.7 if severity == 1 else 1.0)
	_duck_target = maxf(_duck_target, want)


func _shape_filters() -> void:
	if _wind_filter != null:
		var s: float = clampf(storm01, 0.0, 1.0)
		_wind_filter.cutoff_hz = LcnDsp.safe(
			lerpf(WIND_CUT_CALM, WIND_CUT_GALE, s * s), WIND_CUT_CALM, 40.0, 12000.0)
		_wind_filter.resonance = LcnDsp.safe(
			lerpf(WIND_Q_CALM, WIND_Q_GALE, s), WIND_Q_CALM, 0.1, 12.0)
	if _hearth_filter != null:
		var h: float = clampf(hearth01, 0.0, 1.0)
		_hearth_filter.cutoff_hz = LcnDsp.safe(
			lerpf(HEARTH_CUT_DYING, HEARTH_CUT_STRONG, h * h), HEARTH_CUT_STRONG, 60.0, 16000.0)
	if _machine_filter != null:
		var f: float = clampf(factory01, 0.0, 1.0)
		_machine_filter.cutoff_hz = LcnDsp.safe(
			lerpf(MACHINE_CUT_STALLED, MACHINE_CUT_RUNNING, f * f),
			MACHINE_CUT_RUNNING, 120.0, 16000.0)


# ================================================================== settings ==

## Reads Settings.audio and writes the four player-facing gains.
## `force` skips the "nothing changed" shortcut.
func apply_settings(force: bool) -> void:
	var audio: Dictionary = _read_settings()
	if not force and audio == _last_settings:
		return
	_last_settings = audio.duplicate()
	for slider: String in LcnAudioDefs.SLIDER_BUS:
		var bus: StringName = LcnAudioDefs.SLIDER_BUS[slider]
		var value: float = float(audio.get(slider, 0.8))
		_slider_db[bus] = LcnDsp.slider_db(value)
		_write_db(bus, 0.0)
	if bool(audio.get("muted", false)):
		_write_absolute(LcnAudioDefs.BUS_MASTER, LcnDsp.MIN_DB)


func _read_settings() -> Dictionary:
	# Resolved by node name, not by naming the autoload: this file is loaded by
	# tests that run before the autoloads exist, and a hard reference would make
	# the whole part fail to compile there.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var node: Node = null
	if tree != null and tree.root != null:
		node = tree.root.get_node_or_null(NodePath("Settings"))
	if node == null:
		return {"master": 0.9, "music": 0.7, "sfx": 0.9, "ambience": 0.8}
	var d: Variant = node.get("audio")
	if typeof(d) != TYPE_DICTIONARY:
		return {"master": 0.9, "music": 0.7, "sfx": 0.9, "ambience": 0.8}
	return (d as Dictionary).duplicate()


# ==================================================================== gains ==

## Player setting + this bus's design trim + whatever the game is doing to it.
func _write_db(bus: StringName, offset_db: float) -> void:
	var idx: int = _index.get(bus, -1)
	if idx < 0:
		return
	var total: float = float(_base_db.get(bus, 0.0)) \
		+ float(_slider_db.get(bus, 0.0)) + offset_db
	AudioServer.set_bus_volume_db(idx, LcnDsp.safe(total, 0.0, LcnDsp.MIN_DB, LcnDsp.MAX_DB))


func _write_absolute(bus: StringName, db: float) -> void:
	var idx: int = _index.get(bus, -1)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, LcnDsp.safe(db, 0.0, LcnDsp.MIN_DB, LcnDsp.MAX_DB))


func bus_index(bus: StringName) -> int:
	return _index.get(bus, -1)


func db_of(bus: StringName) -> float:
	var idx: int = _index.get(bus, -1)
	return LcnDsp.MIN_DB if idx < 0 else AudioServer.get_bus_volume_db(idx)


func duck_amount() -> float:
	return _duck


func bus_summary() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		var name: StringName = row["name"]
		parts.append("%s→%s" % [String(name), String(row["send"])])
	return " ".join(parts)


## The whole desk, for the log line and for artifacts/<run>/audio.json.
func report() -> Dictionary:
	var buses: Array[Dictionary] = []
	var names: Array[StringName] = [LcnAudioDefs.BUS_MASTER]
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		names.append(row["name"])
	for name: StringName in names:
		var idx: int = AudioServer.get_bus_index(String(name))
		if idx < 0:
			buses.append({"bus": String(name), "index": -1, "present": false})
			continue
		var fx: PackedStringArray = PackedStringArray()
		for i: int in AudioServer.get_bus_effect_count(idx):
			var e: AudioEffect = AudioServer.get_bus_effect(idx, i)
			if e != null:
				fx.append(e.get_class().replace("AudioEffect", ""))
		buses.append({
			"bus": String(name),
			"index": idx,
			"present": true,
			"send": String(AudioServer.get_bus_send(idx)) if idx > 0 else "",
			"volume_db": snappedf(AudioServer.get_bus_volume_db(idx), 0.01),
			"effects": fx,
		})
	return {
		"installed": installed,
		"driver": AudioServer.get_driver_name(),
		"bus_count": AudioServer.bus_count,
		"buses": buses,
		"duck": snappedf(_duck, 0.001),
		"storm": snappedf(storm01, 0.001),
		"hearth": snappedf(hearth01, 0.001),
		"factory": snappedf(factory01, 0.001),
		"settings": _last_settings,
	}

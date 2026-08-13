class_name LcnMachineChorus
extends Node
## [P23] The factory, as an instrument you can diagnose by ear.
##
## THIS IS A LEGIBILITY FEATURE, not decoration. Factorio's contract is that a
## player can read their base; this part extends the contract to a player who is
## looking somewhere else. Every machine family has its own rhythm, and a family
## that stops running does not go silent — it slows down, detunes and goes dull,
## because "I cannot hear the presses any more" is a much weaker signal than
## "the presses are dragging".
##
## ONE VOICE PER FAMILY, never one per machine. A city with four hundred
## workshops is four hundred copies of the same 1.6 s loop, which is a comb
## filter, not a factory. Instead each family gets a single looping voice placed
## at the running machine of that family NEAREST THE CAMERA, with its gain set
## by how many of them are running in earshot. Walk towards the smelters and the
## smelters get louder; that is the whole illusion and it costs ten voices.
##
## WHAT THE PLAYER HEARS WHEN IT STALLS, in three independent channels so it
## survives a bad mix, a small speaker or a distracted player:
##   * **rate**    pitch_scale falls to 0.7 — the rhythm audibly drags
##   * **gain**    the family drops ~9 dB
##   * **timbre**  [LcnAudioMixer] closes a lowpass across the whole machine bus
##
## Cost: one roster walk every RESCAN_TICKS, and that walk is skipped entirely
## when [P11]'s `roster_version()` says nothing has moved.

const RESCAN_SECONDS: float = 0.5
const RUN_DB: float = 0.0
const STALL_DB: float = -9.0
const SLEW_DB: float = 9.0
const PITCH_RUNNING: float = 1.0
const PITCH_STALLED: float = 0.70
## Machines beyond this many tiles are not counted towards a family's gain.
const EARSHOT_TILES: float = 40.0


class FamilyVoice extends RefCounted:
	var family: StringName = &""
	var player: AudioStreamPlayer2D = null
	var db: float = LcnDsp.MIN_DB
	var target_db: float = LcnDsp.MIN_DB
	var pitch: float = 1.0
	var running: int = 0
	var total: int = 0
	var started: bool = false


var listener: Vector2 = Vector2.ZERO
var has_listener: bool = false

var _bank: LcnSoundBank = null
var _voices: Dictionary[StringName, FamilyVoice] = {}
var _build: SimSystem = null
var _production: SimSystem = null
var _accum: float = 0.0
var _roster_seen: int = -1
var _scans: int = 0
var _last_scan_usec: int = 0
var _families_seen: int = 0


func _ready() -> void:
	name = "MachineChorus"


func setup(bank: LcnSoundBank) -> void:
	_bank = bank


func bind(build: SimSystem, production: SimSystem) -> void:
	_build = build
	_production = production
	_roster_seen = -1


func update(delta: float, probe: LcnAudioProbe) -> void:
	_accum += delta
	if _accum >= RESCAN_SECONDS:
		_accum = 0.0
		_rescan(probe)
	_slew(delta)


# =================================================================== scanning =

func _rescan(probe: LcnAudioProbe) -> void:
	if _build == null or not _build.has_method("all_buildings"):
		return
	# [P11] keeps a monotonic roster counter precisely so a puller can ask "did
	# anything move?" for the price of one integer compare. A steady city costs
	# nothing here at all — but the gains still have to follow the CAMERA, so a
	# skipped rescan only skips the roster walk, not the mix.
	var version: int = -1
	if _build.has_method("roster_version"):
		version = int(_build.call("roster_version"))
	var t0: int = Time.get_ticks_usec()

	var tally: Dictionary[StringName, Array] = {}     ## family -> [running, total, nearest_d2, pos]
	var buildings: Array = _build.call("all_buildings")
	var reach: float = EARSHOT_TILES * LcnAudioDefs.TILE
	var reach2: float = reach * reach
	for b: Variant in buildings:
		var inst: Object = b as Object
		if inst == null:
			continue
		var def: Object = inst.get("def") as Object
		var kind: StringName = StringName(inst.get("kind"))
		var tags: Array = def.get("tags") if def != null else []
		var family: StringName = LcnAudioDefs.family_of(kind, tags)
		if family == &"":
			continue
		var pos: Vector2 = inst.call("world_center") if inst.has_method("world_center") else Vector2.ZERO
		var d2: float = 0.0
		if has_listener:
			d2 = listener.distance_squared_to(pos)
			if d2 > reach2:
				continue
		var running: bool = _is_running(inst)
		var row: Array = tally.get(family, [0, 0, INF, Vector2.ZERO])
		row[1] = int(row[1]) + 1
		if running:
			row[0] = int(row[0]) + 1
			# The voice sits on the nearest RUNNING machine: a family the player
			# has walked up to should be heard where they are looking.
			if d2 < float(row[2]):
				row[2] = d2
				row[3] = pos
		elif float(row[2]) == INF:
			row[3] = pos
		tally[family] = row

	_families_seen = tally.size()
	_apply(tally, probe)
	_roster_seen = version
	_scans += 1
	_last_scan_usec = Time.get_ticks_usec() - t0


func _is_running(inst: Object) -> bool:
	# A machine is running when [P04] says it is crafting — ProdMachine.State
	# .RUNNING, which is 1. Compared as an integer rather than through the class
	# so this part still compiles on a build where [P04] is mid-edit.
	if _production != null and _production.has_method("state_of") \
			and _production.has_method("has_machine"):
		var id: int = int(inst.get("id"))
		if bool(_production.call("has_machine", id)):
			return int(_production.call("state_of", id)) == 1
	if inst.has_method("is_running"):
		return bool(inst.call("is_running"))
	return false


## Turns the tally into gains. Families compete for [LcnAudioDefs].
## MAX_MACHINE_LOOPS voices, resolved by the declared priority order so the mix
## stays stable instead of flickering between two equally loud families.
func _apply(tally: Dictionary[StringName, Array], probe: LcnAudioProbe) -> void:
	var wanted: Array[StringName] = []
	for family: StringName in LcnAudioDefs.FAMILY_PRIORITY:
		if tally.has(family):
			wanted.append(family)
	for family: StringName in tally:
		if not wanted.has(family):
			wanted.append(family)
	# The belt family is the one thing here that must not lie. Nothing is on a
	# belt in this build, so if logistics reports no movement the belts are not
	# heard even where they stand.
	if not probe.belts_moving:
		wanted.erase(&"belt")

	var used: int = 0
	for family: StringName in wanted:
		var row: Array = tally[family]
		var running: int = int(row[0])
		var total: int = int(row[1])
		var pos: Vector2 = row[3]
		if used >= LcnAudioDefs.MAX_MACHINE_LOOPS:
			_silence(family)
			continue
		used += 1
		var v: FamilyVoice = _voice_for(family)
		v.running = running
		v.total = total
		if total <= 0:
			v.target_db = LcnDsp.MIN_DB
			continue
		var run_rate: float = float(running) / float(total)
		# Loudness by count, but logarithmically: three presses are clearly more
		# than one, thirty are not clearly more than ten.
		var crowd: float = clampf(log(float(maxi(1, running)) + 1.0) / log(9.0), 0.0, 1.0)
		var base: float = float(LcnAudioDefs.FAMILY_DB.get(family, -8.0))
		if running <= 0:
			# Standing but not working: quiet, dragging, still locatable.
			v.target_db = base + STALL_DB - 4.0
			v.pitch = PITCH_STALLED
		else:
			v.target_db = base + lerpf(STALL_DB, RUN_DB, run_rate) + lerpf(-8.0, 0.0, crowd)
			v.pitch = lerpf(PITCH_STALLED, PITCH_RUNNING, run_rate)
		if v.player != null:
			v.player.position = pos
		_ensure_started(v)

	for family: StringName in _voices:
		if not tally.has(family) or (not wanted.has(family)):
			_silence(family)


func _silence(family: StringName) -> void:
	var v: FamilyVoice = _voices.get(family)
	if v != null:
		v.target_db = LcnDsp.MIN_DB
		v.running = 0
		v.total = 0


func _voice_for(family: StringName) -> FamilyVoice:
	var v: FamilyVoice = _voices.get(family)
	if v != null:
		return v
	v = FamilyVoice.new()
	v.family = family
	var p := AudioStreamPlayer2D.new()
	p.name = "Machine_%s" % String(family)
	p.bus = String(LcnAudioDefs.BUS_MACHINE)
	p.volume_db = LcnDsp.MIN_DB
	p.max_distance = EARSHOT_TILES * LcnAudioDefs.TILE * 1.2
	p.attenuation = 1.6
	p.panning_strength = 0.8
	p.max_polyphony = 1
	v.player = p
	add_child(p)
	_voices[family] = v
	return v


func _ensure_started(v: FamilyVoice) -> void:
	if v.started or _bank == null or v.player == null:
		return
	var s: AudioStreamWAV = _bank.get_stream(StringName("mach_%s" % String(v.family)))
	if s == null:
		return
	v.player.stream = s
	v.player.play()
	v.started = true


func _slew(delta: float) -> void:
	var step: float = SLEW_DB * maxf(0.0, delta)
	for family: StringName in _voices:
		var v: FamilyVoice = _voices[family]
		if v.player == null:
			continue
		if v.db <= LcnDsp.MIN_DB + 0.5 and v.target_db > LcnDsp.MIN_DB + 0.5:
			v.db = v.target_db - 10.0
		v.db = move_toward(v.db, v.target_db, step)
		v.player.volume_db = LcnDsp.safe(v.db, LcnDsp.MIN_DB, LcnDsp.MIN_DB, LcnDsp.MAX_DB)
		v.player.pitch_scale = LcnDsp.safe(v.pitch, 1.0, 0.05, 4.0)
		# Nothing audible stays playing at silence: a loop nobody can hear is
		# still a voice, a mixer slot and a resample every frame.
		if v.started and v.db <= LcnDsp.MIN_DB + 0.5 and v.target_db <= LcnDsp.MIN_DB + 0.5:
			v.player.stop()
			v.started = false


func audible_families() -> int:
	var n: int = 0
	for family: StringName in _voices:
		if _voices[family].db > LcnDsp.MIN_DB + 1.0:
			n += 1
	return n


func report() -> Dictionary:
	var rows: Array[Dictionary] = []
	var keys: Array[StringName] = []
	for k: StringName in _voices:
		keys.append(k)
	keys.sort()
	for k: StringName in keys:
		var v: FamilyVoice = _voices[k]
		rows.append({
			"family": String(k),
			"running": v.running,
			"total": v.total,
			"db": snappedf(v.db, 0.01),
			"pitch": snappedf(v.pitch, 0.001),
			"playing": v.started,
		})
	return {
		"families_in_earshot": _families_seen,
		"voices": rows,
		"audible": audible_families(),
		"scans": _scans,
		"scan_usec": _last_scan_usec,
	}

class_name LcnMusicDirector
extends Node
## [P23] The score, mixed by the simulation.
##
## There are no music cues in this game. Five stems of the same length start
## together on the first frame and never stop; what changes is how loud each one
## is, and that is a continuous function of the state of the city. The player
## never hears a track begin, because none ever does.
##
##   bed     the drone under everything. Always on. Volume by night and threat.
##   pulse   a heartbeat every 1.2 s. Rises with threat and with the dark.
##   hope    an open D-minor pad. The only warm thing in the mix, and it is
##           bought with hope, daylight and a fed population.
##   dread   a minor-second cluster with a tremolo. Threat and bodies on the map.
##   perc    industrial percussion. Only during an assault, and it stops the
##           moment the last one is dead.
##
## WHY STEMS AND NOT TRACKS: a threat meter that crosses 0.6 must not cause a
## musical event, because the player did not do anything at 0.6. Continuous
## crossfades mean the score is always exactly as bad as the situation, and the
## player reads it without ever noticing they are reading it.
##
## The stems stay sample-locked because they are the same length, started in the
## same frame, at pitch 1.0. Nothing here ever changes a stem's pitch.

const SLEW_DB: float = 4.0
const BED_DB: float = -10.0
const PULSE_DB: float = -13.0
const HOPE_DB: float = -14.0
const DREAD_DB: float = -11.0
const PERC_DB: float = -13.0

const STEMS: Array[StringName] = [&"bed", &"pulse", &"hope", &"dread", &"perc"]

var _bank: LcnSoundBank = null
var _players: Dictionary[StringName, AudioStreamPlayer] = {}
var _db: Dictionary[StringName, float] = {}
var _target: Dictionary[StringName, float] = {}
var _started: bool = false
var _start_attempts: int = 0


func _ready() -> void:
	name = "MusicDirector"


func setup(bank: LcnSoundBank) -> void:
	_bank = bank
	for stem: StringName in STEMS:
		var p := AudioStreamPlayer.new()
		p.name = "Stem_%s" % String(stem)
		p.bus = String(LcnAudioDefs.BUS_MUSIC)
		p.volume_db = LcnDsp.MIN_DB
		add_child(p)
		_players[stem] = p
		_db[stem] = LcnDsp.MIN_DB
		_target[stem] = LcnDsp.MIN_DB


## All five or none: a stem that joins two seconds late is a stem that is two
## seconds out of phase with the other four for the rest of the session.
func _try_start() -> void:
	if _started or _bank == null:
		return
	_start_attempts += 1
	var streams: Dictionary[StringName, AudioStreamWAV] = {}
	for stem: StringName in STEMS:
		var s: AudioStreamWAV = _bank.get_stream(StringName("mus_%s" % String(stem)))
		if s == null:
			return
		streams[stem] = s
	for stem: StringName in STEMS:
		var p: AudioStreamPlayer = _players[stem]
		p.stream = streams[stem]
		p.pitch_scale = 1.0
		p.play()
	_started = true
	Log.info("audio", "score: %d stems started in sync (%d attempts)" % [
		STEMS.size(), _start_attempts])


func update(delta: float, probe: LcnAudioProbe) -> void:
	_try_start()

	var threat: float = clampf(probe.threat01, 0.0, 1.0) if probe.has_threat else 0.0
	var fight: float = clampf(float(probe.enemies_alive) / 12.0, 0.0, 1.0)
	var dark: float = 1.0 - clampf(probe.light, 0.0, 1.0) if probe.has_climate else 0.0
	if probe.is_deep_night:
		dark = maxf(dark, 0.85)
	var hope: float = clampf(probe.hope01, 0.0, 1.0) if probe.has_society else 0.5
	var cold_fire: float = 1.0 - clampf(probe.hearth01, 0.0, 1.0) if probe.has_heat else 0.0

	# The bed is the only stem that is always up, and it leans on the dark.
	_target[&"bed"] = BED_DB + lerpf(-6.0, 0.0, maxf(dark, threat))

	# The pulse is the clock the player feels rather than reads.
	var urgency: float = clampf(maxf(threat, fight) * 0.7 + dark * 0.5, 0.0, 1.0)
	_target[&"pulse"] = LcnDsp.MIN_DB if urgency < 0.12 \
		else PULSE_DB + lerpf(-14.0, 0.0, urgency)

	# Hope has to be EARNED and it has to be spendable: daylight, a fed and
	# willing population, and a fire that is still strong. Any one of those
	# failing takes it away, which is what makes it worth protecting.
	var warmth: float = clampf(hope * (1.0 - dark * 0.75) * (1.0 - cold_fire), 0.0, 1.0)
	_target[&"hope"] = LcnDsp.MIN_DB if warmth < 0.12 \
		else HOPE_DB + lerpf(-16.0, 0.0, warmth)

	# Dread answers the threat director and the bodies actually on the map.
	var menace: float = clampf(threat * 0.65 + fight * 0.55 + cold_fire * 0.3, 0.0, 1.0)
	_target[&"dread"] = LcnDsp.MIN_DB if menace < 0.10 \
		else DREAD_DB + lerpf(-18.0, 0.0, menace)

	# Percussion is the assault itself. No enemies, no drums.
	_target[&"perc"] = LcnDsp.MIN_DB if not probe.wave_active \
		else PERC_DB + lerpf(-10.0, 0.0, fight)

	_slew(delta)


func _slew(delta: float) -> void:
	var step: float = SLEW_DB * maxf(0.0, delta)
	for stem: StringName in STEMS:
		var want: float = _target[stem]
		var now: float = _db[stem]
		if now <= LcnDsp.MIN_DB + 0.5 and want > LcnDsp.MIN_DB + 0.5:
			now = want - 14.0
		now = move_toward(now, want, step)
		_db[stem] = now
		var p: AudioStreamPlayer = _players[stem]
		if p != null:
			p.volume_db = LcnDsp.safe(now, LcnDsp.MIN_DB, LcnDsp.MIN_DB, LcnDsp.MAX_DB)


func started() -> bool:
	return _started


func db_of(stem: StringName) -> float:
	return float(_db.get(stem, LcnDsp.MIN_DB))


func report() -> Dictionary:
	var rows: Dictionary = {}
	for stem: StringName in STEMS:
		rows[String(stem)] = snappedf(_db[stem], 0.01)
	return {"started": _started, "stems": rows, "stem_count": STEMS.size()}

class_name LcnAmbienceBeds
extends Node
## [P23] The room: the hearth, the wind, and the hum of a city that is working.
##
## Four voices that never stop and never get stolen. Everything about them is a
## gain or a filter cutoff, driven by the probe, so the ambience is a continuous
## reading of the world rather than a sequence of triggered events. A player
## should never be able to say "that sound started" about any of them.
##
## THE HEARTH IS THE ANCHOR of the whole mix and it is the one thing here that
## is positional: it is a place, it pans as the camera moves, and it stays
## audible from anywhere in the city because its radius is the map. As the fire
## weakens the [LcnAudioMixer] closes a lowpass over it AND this layer pulls its
## gain down, so it loses its top end before it loses its body — which is what
## makes a player look at the heat panel a few seconds before the alert fires.
##
## THE WIND does the opposite: it grows. A still day is a distant band of noise;
## a whiteout is that same noise with the filter wide open and a second, high-Q
## voice howling over it. The storm never fades in as a new sound — it is always
## there, it just stops being ignorable.
##
## THE HUM is the city's own working sound and it is the reward for building
## one. It rises with machines that are actually running and drops away at
## night, so a base that goes quiet in the dark is doing it audibly.

const HEARTH_RADIUS: float = 4200.0     ## the fire carries across the whole city
const HEARTH_DB_STRONG: float = -5.0
const HEARTH_DB_DYING: float = -19.0
const WIND_DB_CALM: float = -26.0
const WIND_DB_GALE: float = -6.0
const HOWL_DB: float = -13.0
const HUM_DB_BUSY: float = -14.0
## How fast a bed may travel, in dB per second. Slow on purpose: a bed that
## tracks the sim tightly reads as a mistake.
const SLEW_DB: float = 5.0

var hearth: AudioStreamPlayer2D = null
var wind: AudioStreamPlayer = null
var howl: AudioStreamPlayer = null
var hum: AudioStreamPlayer = null

var _bank: LcnSoundBank = null
var _targets: Dictionary[StringName, float] = {}
var _current: Dictionary[StringName, float] = {}
var _started: Dictionary[StringName, bool] = {}


func _ready() -> void:
	name = "AmbienceBeds"


func setup(bank: LcnSoundBank) -> void:
	_bank = bank
	hearth = AudioStreamPlayer2D.new()
	hearth.name = "Hearth"
	hearth.bus = String(LcnAudioDefs.BUS_HEARTH)
	hearth.max_distance = HEARTH_RADIUS
	hearth.attenuation = 0.6
	hearth.panning_strength = 0.35
	hearth.volume_db = LcnDsp.MIN_DB
	add_child(hearth)

	wind = _make_flat("Wind", LcnAudioDefs.BUS_WIND)
	howl = _make_flat("Howl", LcnAudioDefs.BUS_WIND)
	hum = _make_flat("CityHum", LcnAudioDefs.BUS_AMBIENCE)

	for k: StringName in [&"hearth", &"wind", &"howl", &"hum"]:
		_current[k] = LcnDsp.MIN_DB
		_targets[k] = LcnDsp.MIN_DB
		_started[k] = false


func _make_flat(node_name: String, bus: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = node_name
	p.bus = String(bus)
	p.volume_db = LcnDsp.MIN_DB
	add_child(p)
	return p


## Reads the probe and moves every bed towards where the world says it should be.
func update(delta: float, probe: LcnAudioProbe) -> void:
	_ensure_playing()

	# --- the fire ---
	var health: float = clampf(probe.hearth01, 0.0, 1.0) if probe.has_heat else 1.0
	_targets[&"hearth"] = lerpf(HEARTH_DB_DYING, HEARTH_DB_STRONG, health * health)
	if probe.has_hearth_pos:
		hearth.position = probe.hearth_pos
	# A weak fire also slows down: the crackle rate is the pitch of the loop.
	hearth.pitch_scale = LcnDsp.safe(lerpf(0.82, 1.0, health), 1.0, 0.05, 4.0)

	# --- the weather ---
	var gale: float = clampf(maxf(probe.wind01, probe.storm01), 0.0, 1.0) if probe.has_climate else 0.12
	# Night is windier than the numbers say, because night is the thing the
	# player is afraid of and the mix is allowed to agree with them.
	if probe.is_night:
		gale = clampf(gale + 0.12, 0.0, 1.0)
	_targets[&"wind"] = lerpf(WIND_DB_CALM, WIND_DB_GALE, gale)
	var storm: float = clampf(probe.storm01, 0.0, 1.0)
	# The howl only exists above half a gale, and it arrives from silence, so a
	# whiteout genuinely sounds like something new rather than louder.
	_targets[&"howl"] = LcnDsp.MIN_DB if storm < 0.35 \
		else lerpf(-30.0, HOWL_DB, clampf((storm - 0.35) / 0.65, 0.0, 1.0))
	howl.pitch_scale = LcnDsp.safe(lerpf(0.9, 1.25, storm), 1.0, 0.05, 4.0)

	# --- the city ---
	var busy: float = 0.0
	if probe.has_production and probe.machines > 0:
		busy = clampf(float(probe.machines_active) / float(probe.machines), 0.0, 1.0)
		busy *= clampf(float(probe.machines) / 6.0, 0.15, 1.0)
	# A city asleep is a city that has stopped making its own noise.
	var awake: float = 1.0 if not probe.is_night else 0.45
	if probe.is_deep_night:
		awake = 0.22
	var hum_level: float = busy * awake
	_targets[&"hum"] = LcnDsp.MIN_DB if hum_level < 0.02 \
		else lerpf(-34.0, HUM_DB_BUSY, hum_level)

	_slew(delta)


func _ensure_playing() -> void:
	_start(&"hearth", hearth, &"hearth_bed")
	_start(&"wind", wind, &"wind_bed")
	_start(&"howl", howl, &"wind_howl")
	_start(&"hum", hum, &"city_hum")


func _start(key: StringName, player: Node, stream_key: StringName) -> void:
	if bool(_started.get(key, false)) or player == null or _bank == null:
		return
	var s: AudioStreamWAV = _bank.get_stream(stream_key)
	if s == null:
		return
	player.set("stream", s)
	player.call("play")
	_started[key] = true


## Every bed moves at a bounded rate. This is the difference between weather and
## a volume automation curve somebody can hear working.
func _slew(delta: float) -> void:
	var step: float = SLEW_DB * maxf(0.0, delta)
	for key: StringName in _targets:
		var want: float = _targets[key]
		var now: float = _current[key]
		# Coming up from true silence should not take fourteen seconds.
		if now <= LcnDsp.MIN_DB + 0.5 and want > LcnDsp.MIN_DB + 0.5:
			now = want - 12.0
		var next: float = move_toward(now, want, step)
		_current[key] = next
		var node: Node = _player_for(key)
		if node != null:
			node.set("volume_db", LcnDsp.safe(next, LcnDsp.MIN_DB, LcnDsp.MIN_DB, LcnDsp.MAX_DB))


func _player_for(key: StringName) -> Node:
	match key:
		&"hearth":
			return hearth
		&"wind":
			return wind
		&"howl":
			return howl
		&"hum":
			return hum
	return null


func db_of(key: StringName) -> float:
	return float(_current.get(key, LcnDsp.MIN_DB))


func report() -> Dictionary:
	return {
		"hearth_db": snappedf(db_of(&"hearth"), 0.01),
		"wind_db": snappedf(db_of(&"wind"), 0.01),
		"howl_db": snappedf(db_of(&"howl"), 0.01),
		"hum_db": snappedf(db_of(&"hum"), 0.01),
		"playing": {
			"hearth": _started.get(&"hearth", false),
			"wind": _started.get(&"wind", false),
			"howl": _started.get(&"howl", false),
			"hum": _started.get(&"hum", false),
		},
	}

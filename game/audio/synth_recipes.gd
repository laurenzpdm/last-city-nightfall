class_name LcnSynthRecipes
extends RefCounted
## [P23] Every sound in the game, written down as numbers.
##
## There is no sample library. Each entry here is a recipe [LcnSynthJob] renders
## into an AudioStreamWAV at runtime, which means the whole soundtrack is about
## nine kilobytes of source and nothing to license, lose or forget to commit.
## The constraint IS the art direction: filtered noise, sine and saw, nothing
## that pretends to be a recording, everything tuned to D so the beds and the
## score never argue.
##
## TWO ENGINES do all the work, plus an event layer that both can carry:
##   &"noise"  — white/brown noise through a lowpass, a resonant band and a sine
##               sub. Fire, wind, roaring machines, impacts, breath.
##   &"tonal"  — up to six partials (sine/saw/square/triangle) through a filter,
##               with an optional glide. Drones, calls, stings, the score.
##   events    — scheduled transients written on top: thuds, clanks, clicks,
##               chuffs, bell partials. This is where rhythm comes from.
##
## LOOPS ARE SEAMLESS BY CONSTRUCTION, not by luck. Tonal partial frequencies and
## every LFO rate are snapped to a whole number of cycles in the loop; noise beds
## get a crossfaded tail; event tails wrap around the loop point. A tick every
## six seconds is the single most fatiguing thing an ambient bed can do.
##
## Schema (everything optional except `engine`, `seconds`):
##   engine, sr, seconds, loop, xfade, seed, gain, bed
##   noise:  brown, lp_hz, lp_hz_end, hp_hz, bp_hz, bp_q, bp_mix, bp_lfo,
##           sub_hz, sub_amt, am
##   tonal:  base_hz, base_hz_end, partials, amps, waves, detune, noise_amt,
##           lp_hz, lp_hz_end, lp_q, am
##   both:   attack, decay  (absent = a flat loop)
##   events: Array of {kind, offsets|count, jitter, hz, hz_spread, decay, amp,
##                     amp_spread, noise}
##
## Waves: 0 sine, 1 saw, 2 square, 3 triangle.

## D minor, because a city freezing to death is not in a major key.
const D1: float = 36.708
const D2: float = 73.416
const A1: float = 55.0
const A2: float = 110.0
const F2: float = 87.307
const D3: float = 146.832

const MUSIC_LOOP: float = 9.6      ## four bars of 2.4 s
const MUSIC_SR: int = LcnDsp.SR_LOW

static var _cache: Dictionary[StringName, Dictionary] = {}


## The whole catalogue, built once per process.
static func all() -> Dictionary[StringName, Dictionary]:
	if _cache.is_empty():
		_build()
	return _cache


static func has(key: StringName) -> bool:
	return all().has(key)


static func spec(key: StringName) -> Dictionary:
	return all().get(key, {})


## Baked synchronously, before the first frame. Deliberately just one, and the
## cheapest one in the catalogue: a click is what the very first keypress needs,
## and everything else can afford to arrive a few frames later on the bank's
## budget. The hearth bed used to be in here for the good reason that the fire is
## the floor of the whole mix — and it cost 94 ms on the frame the audio root
## entered the tree, which is a stutter traded for a third of a second nobody
## could have noticed.
static func essential() -> Array[StringName]:
	return [&"click"]


static func _build() -> void:
	var r: Dictionary[StringName, Dictionary] = {}

	# ======================================================== ambience beds ===
	# The hearth. Brown noise for the body of the fire, a sine sub for the mass
	# of it, and twenty-six crackles that stop it being a hum. Everything else
	# in the mix is allowed to move; this does not.
	r[&"hearth_bed"] = {
		"engine": &"noise", "sr": LcnDsp.SR_LOW, "seconds": 6.0, "loop": true,
		"xfade": 0.5, "seed": 8101, "gain": 1.0,
		"brown": 0.88, "lp_hz": 320.0, "hp_hz": 24.0,
		"bp_hz": 190.0, "bp_q": 1.3, "bp_mix": 0.28,
		"sub_hz": 43.7, "sub_amt": 0.42,
		"am": [[0.16667, 0.26], [0.5, 0.13]],
		"events": [
			{"kind": &"crackle", "count": 26, "hz": 1500.0, "hz_spread": 900.0,
				"decay": 0.09, "amp": 0.26, "amp_spread": 0.16, "noise": 0.92},
			{"kind": &"chuff", "count": 5, "hz": 420.0, "hz_spread": 180.0,
				"decay": 0.35, "amp": 0.18, "amp_spread": 0.08, "noise": 1.0},
		],
	}
	# Wind. A resonant band wandering over three snapped LFOs, so it breathes on
	# its own before the storm ever touches the filter on the bus.
	r[&"wind_bed"] = {
		"engine": &"noise", "sr": LcnDsp.SR_LOW, "seconds": 8.0, "loop": true,
		"xfade": 0.8, "seed": 8102, "gain": 1.0,
		"brown": 0.34, "lp_hz": 1600.0, "hp_hz": 40.0,
		"bp_hz": 430.0, "bp_q": 2.3, "bp_mix": 0.72,
		"bp_lfo": [[0.125, 0.55], [0.375, 0.28]],
		"sub_hz": 61.0, "sub_amt": 0.16,
		"am": [[0.125, 0.30], [0.25, 0.16]],
	}
	# The whiteout voice. Only audible above half a gale, and it is the reason a
	# storm is frightening rather than merely loud.
	r[&"wind_howl"] = {
		"engine": &"noise", "sr": LcnDsp.SR_LOW, "seconds": 8.0, "loop": true,
		"xfade": 0.8, "seed": 8103, "gain": 1.0,
		"brown": 0.10, "lp_hz": 3200.0, "hp_hz": 260.0,
		"bp_hz": 880.0, "bp_q": 7.5, "bp_mix": 1.0,
		"bp_lfo": [[0.25, 0.50], [0.125, 0.34]],
		"am": [[0.25, 0.42]],
	}
	# A working city, heard from inside it. Rises with machines actually running.
	r[&"city_hum"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 6.0, "loop": true,
		"seed": 8104, "gain": 1.0,
		"base_hz": D1, "partials": [1.0, 2.0, 3.0, 4.0],
		"amps": [0.50, 0.30, 0.15, 0.07], "waves": [1, 0, 0, 0],
		"detune": 7.0, "noise_amt": 0.05, "lp_hz": 330.0, "lp_q": 0.9,
		"am": [[0.33333, 0.12]],
	}

	# ============================================================ the clock ===
	r[&"night_drain"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 5.0, "loop": false,
		"seed": 8110, "gain": 1.0,
		"base_hz": 110.0, "base_hz_end": 41.2,
		"partials": [1.0, 1.5, 2.0], "amps": [0.55, 0.26, 0.15], "waves": [0, 0, 1],
		"lp_hz": 900.0, "lp_hz_end": 170.0, "lp_q": 1.4,
		"attack": 0.6, "decay": 4.4, "noise_amt": 0.04,
	}
	r[&"dawn_lift"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 4.0, "loop": false,
		"seed": 8111, "gain": 1.0,
		"base_hz": D2, "base_hz_end": A2,
		"partials": [1.0, 2.0, 3.0], "amps": [0.45, 0.28, 0.16], "waves": [0, 0, 0],
		"lp_hz": 300.0, "lp_hz_end": 1900.0, "lp_q": 1.1,
		"attack": 1.2, "decay": 2.8,
	}

	# ============================================================= machines ===
	# Ten families. Each has a RATE the player can hear stop: the rhythmic ones
	# gate out, the roaring ones lose their flutter, and the machine bus closes
	# a lowpass over all of them when the factory stalls.
	r[&"mach_burner"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 2.0, "loop": true,
		"xfade": 0.25, "seed": 8201,
		"brown": 0.62, "lp_hz": 640.0, "hp_hz": 30.0,
		"bp_hz": 250.0, "bp_q": 1.6, "bp_mix": 0.30,
		"sub_hz": 41.0, "sub_amt": 0.34,
		"am": [[4.0, 0.44], [7.0, 0.20]],
	}
	r[&"mach_smelter"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 2.0, "loop": true,
		"xfade": 0.25, "seed": 8202,
		"brown": 0.42, "lp_hz": 1100.0, "hp_hz": 55.0,
		"bp_hz": 2600.0, "bp_q": 1.1, "bp_mix": 0.24,
		"sub_hz": 48.0, "sub_amt": 0.28,
		"am": [[1.0, 0.26], [3.5, 0.14]],
	}
	r[&"mach_press"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 1.6, "loop": true,
		"xfade": 0.2, "seed": 8203, "bed": 0.16,
		"brown": 0.6, "lp_hz": 520.0, "am": [[1.25, 0.5]],
		"events": [
			{"kind": &"clank", "offsets": [0.0, 0.8], "hz": 92.0,
				"decay": 0.34, "amp": 0.85, "noise": 0.22},
			{"kind": &"click", "offsets": [0.12, 0.92], "hz": 2400.0,
				"decay": 0.05, "amp": 0.22, "noise": 0.85},
		],
	}
	r[&"mach_assembler"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.6, "loop": true,
		"seed": 8204, "bed": 0.30,
		"base_hz": 180.0, "partials": [1.0, 2.0, 3.0], "amps": [0.4, 0.16, 0.07],
		"waves": [1, 0, 0], "lp_hz": 900.0, "lp_q": 1.2, "am": [[8.75, 0.4]],
		"events": [
			{"kind": &"tick", "offsets": [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4],
				"hz": 1900.0, "hz_spread": 500.0, "decay": 0.035, "amp": 0.30,
				"amp_spread": 0.1, "noise": 0.7},
		],
	}
	r[&"mach_drill"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 2.0, "loop": true,
		"xfade": 0.25, "seed": 8205,
		"brown": 0.5, "lp_hz": 1700.0, "hp_hz": 45.0,
		"bp_hz": 790.0, "bp_q": 2.8, "bp_mix": 0.68,
		"sub_hz": 88.0, "sub_amt": 0.30,
		"am": [[21.0, 0.55], [3.0, 0.20]],
	}
	r[&"mach_sorter"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 1.6, "loop": true,
		"xfade": 0.2, "seed": 8206, "bed": 0.34,
		"brown": 0.4, "lp_hz": 1300.0, "bp_hz": 900.0, "bp_q": 1.6, "bp_mix": 0.4,
		"events": [
			{"kind": &"tick", "count": 22, "jitter": 0.03, "hz": 1600.0,
				"hz_spread": 900.0, "decay": 0.045, "amp": 0.34, "amp_spread": 0.2,
				"noise": 0.8},
		],
	}
	r[&"mach_pump"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 1.6, "loop": true,
		"xfade": 0.2, "seed": 8207, "bed": 0.14,
		"brown": 0.7, "lp_hz": 400.0,
		"events": [
			{"kind": &"chuff", "offsets": [0.0, 0.4, 0.8, 1.2], "hz": 640.0,
				"decay": 0.13, "amp": 0.55, "noise": 1.0},
			{"kind": &"thud", "offsets": [0.0, 0.4, 0.8, 1.2], "hz": 52.0,
				"decay": 0.17, "amp": 0.45, "noise": 0.05},
		],
	}
	r[&"mach_kitchen"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 2.4, "loop": true,
		"xfade": 0.3, "seed": 8208, "bed": 0.55,
		"brown": 0.72, "lp_hz": 430.0, "am": [[0.41667, 0.22]],
		"events": [
			{"kind": &"blip", "count": 14, "hz": 430.0, "hz_spread": 260.0,
				"decay": 0.08, "amp": 0.26, "amp_spread": 0.12, "noise": 0.15},
		],
	}
	r[&"mach_radiator"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 2.4, "loop": true,
		"xfade": 0.3, "seed": 8209, "bed": 0.5,
		"brown": 0.55, "lp_hz": 540.0, "am": [[0.83333, 0.18]],
		"events": [
			{"kind": &"tick", "offsets": [0.0, 0.6, 1.2, 1.8], "hz": 1250.0,
				"decay": 0.03, "amp": 0.20, "noise": 0.5},
		],
	}
	r[&"mach_belt"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 1.6, "loop": true,
		"xfade": 0.2, "seed": 8210,
		"brown": 0.56, "lp_hz": 1150.0, "hp_hz": 40.0,
		"bp_hz": 380.0, "bp_q": 1.8, "bp_mix": 0.58,
		"sub_hz": 62.0, "sub_amt": 0.20,
		"am": [[12.5, 0.34]],
	}

	# =============================================================== combat ===
	r[&"shot_light"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.24, "loop": false,
		"seed": 8301, "brown": 0.2, "hp_hz": 480.0,
		"lp_hz": 5400.0, "lp_hz_end": 900.0,
		"attack": 0.002, "decay": 0.235,
		"events": [{"kind": &"thud", "offsets": [0.0], "hz": 150.0,
			"decay": 0.10, "amp": 0.55, "noise": 0.12}],
	}
	r[&"shot_heavy"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.46, "loop": false,
		"seed": 8302, "brown": 0.36, "hp_hz": 120.0,
		"lp_hz": 3400.0, "lp_hz_end": 420.0,
		"attack": 0.003, "decay": 0.455,
		"events": [{"kind": &"thud", "offsets": [0.0], "hz": 78.0,
			"decay": 0.30, "amp": 0.92, "noise": 0.18}],
	}
	r[&"impact_soft"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.26, "loop": false,
		"seed": 8303, "brown": 0.62, "lp_hz": 800.0, "lp_hz_end": 380.0,
		"attack": 0.004, "decay": 0.25,
		"events": [{"kind": &"thud", "offsets": [0.0], "hz": 108.0,
			"decay": 0.12, "amp": 0.40, "noise": 0.2}],
	}
	r[&"impact_metal"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.42, "loop": false,
		"seed": 8304, "bed": 0.35, "brown": 0.25, "hp_hz": 700.0, "lp_hz": 4200.0,
		"attack": 0.002, "decay": 0.12,
		"events": [{"kind": &"metal", "offsets": [0.0], "hz": 430.0,
			"decay": 0.38, "amp": 0.85, "noise": 0.12}],
	}
	r[&"death_rattle"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.5, "loop": false,
		"seed": 8305, "brown": 0.5, "lp_hz": 2300.0, "lp_hz_end": 560.0,
		"bp_hz": 700.0, "bp_q": 3.0, "bp_mix": 0.66,
		"am": [[18.0, 0.6]], "attack": 0.01, "decay": 0.49,
	}
	r[&"breach_groan"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.7, "loop": false,
		"seed": 8306, "base_hz": 130.0, "base_hz_end": 55.0,
		"partials": [1.0, 1.48, 2.02, 2.51], "amps": [0.45, 0.28, 0.18, 0.10],
		"waves": [1, 0, 0, 1], "lp_hz": 1100.0, "lp_hz_end": 220.0, "lp_q": 2.2,
		"am": [[5.5, 0.3]], "noise_amt": 0.12, "attack": 0.05, "decay": 1.65,
	}
	r[&"call_far"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.6, "loop": false,
		"seed": 8307, "base_hz": 168.0, "base_hz_end": 104.0,
		"partials": [1.0, 1.5, 2.51], "amps": [0.45, 0.28, 0.16],
		"waves": [1, 0, 0], "lp_hz": 1400.0, "lp_hz_end": 460.0, "lp_q": 3.6,
		"am": [[6.0, 0.24]], "noise_amt": 0.06, "attack": 0.28, "decay": 1.32,
	}
	r[&"call_near"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.2, "loop": false,
		"seed": 8308, "base_hz": 214.0, "base_hz_end": 86.0,
		"partials": [1.0, 1.5, 2.02, 3.01], "amps": [0.42, 0.26, 0.18, 0.09],
		"waves": [1, 1, 0, 0], "lp_hz": 2700.0, "lp_hz_end": 540.0, "lp_q": 4.4,
		"am": [[9.0, 0.3]], "noise_amt": 0.12, "attack": 0.04, "decay": 1.16,
	}
	# The specific dread of something big: two partials a sixth of a hertz apart,
	# so the whole sound breathes in and out on its own beat frequency.
	r[&"dread_swell"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 3.2, "loop": false,
		"seed": 8309, "base_hz": 27.5, "base_hz_end": 36.7,
		"partials": [1.0, 1.0062, 2.0, 3.02], "amps": [0.55, 0.50, 0.18, 0.08],
		"waves": [0, 0, 0, 1], "lp_hz": 420.0, "lp_hz_end": 950.0, "lp_q": 1.6,
		"am": [[0.3125, 0.32]], "attack": 1.6, "decay": 1.6,
	}

	# ============================================================ the city ====
	r[&"thud_wood"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.32, "loop": false,
		"seed": 8401, "bed": 0.22, "brown": 0.7, "lp_hz": 700.0,
		"attack": 0.002, "decay": 0.12,
		"events": [
			{"kind": &"thud", "offsets": [0.0], "hz": 120.0, "decay": 0.20,
				"amp": 0.8, "noise": 0.25},
			{"kind": &"click", "offsets": [0.0], "hz": 900.0, "decay": 0.04,
				"amp": 0.30, "noise": 0.8},
		],
	}
	r[&"rubble"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.58, "loop": false,
		"seed": 8402, "brown": 0.7, "lp_hz": 950.0, "attack": 0.005, "decay": 0.56,
		"events": [{"kind": &"tick", "count": 9, "hz": 1500.0, "hz_spread": 900.0,
			"decay": 0.05, "amp": 0.30, "amp_spread": 0.15, "noise": 0.85}],
	}
	r[&"chord_soft"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 0.85, "loop": false,
		"seed": 8403, "base_hz": D3, "partials": [1.0, 1.5, 2.0],
		"amps": [0.40, 0.28, 0.16], "waves": [0, 0, 0],
		"lp_hz": 1500.0, "lp_q": 1.0, "attack": 0.02, "decay": 0.82,
	}
	r[&"stall_sigh"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 0.95, "loop": false,
		"seed": 8404, "base_hz": 122.0, "base_hz_end": 70.0,
		"partials": [1.0, 2.0, 3.0], "amps": [0.45, 0.20, 0.09], "waves": [1, 0, 0],
		"lp_hz": 820.0, "lp_hz_end": 250.0, "lp_q": 1.6,
		"noise_amt": 0.12, "attack": 0.03, "decay": 0.91,
	}
	r[&"freeze_crack"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.62, "loop": false,
		"seed": 8405, "bed": 0.5, "brown": 0.08, "hp_hz": 2400.0, "lp_hz": 9000.0,
		"attack": 0.002, "decay": 0.18,
		"events": [{"kind": &"tick", "count": 7, "hz": 3200.0, "hz_spread": 2200.0,
			"decay": 0.03, "amp": 0.5, "amp_spread": 0.25, "noise": 0.75}],
	}
	# A bell for a death. It is the only sound in the game with a real overtone
	# series, and it is used exactly once per person.
	r[&"toll"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 2.6, "loop": false,
		"seed": 8406, "base_hz": D2, "partials": [1.0, 2.0, 2.76, 5.40],
		"amps": [0.50, 0.28, 0.13, 0.06], "waves": [0, 0, 0, 0],
		"lp_hz": 950.0, "lp_q": 1.0, "attack": 0.008, "decay": 2.55,
	}

	# ============================================================ interface ===
	r[&"click"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.055, "loop": false,
		"seed": 8501, "bed": 0.0,
		"events": [{"kind": &"click", "offsets": [0.0], "hz": 2100.0,
			"decay": 0.028, "amp": 0.7, "noise": 0.55}],
	}
	r[&"panel_open"] = {
		"engine": &"noise", "sr": LcnDsp.SR_MID, "seconds": 0.30, "loop": false,
		"seed": 8502, "brown": 0.2, "hp_hz": 300.0,
		"lp_hz": 900.0, "lp_hz_end": 2800.0,
		"bp_hz": 1200.0, "bp_q": 2.0, "bp_mix": 0.55,
		"attack": 0.01, "decay": 0.29,
	}
	r[&"deny"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 0.24, "loop": false,
		"seed": 8503, "base_hz": 92.0, "partials": [1.0, 1.06, 2.0],
		"amps": [0.40, 0.34, 0.10], "waves": [2, 2, 0],
		"lp_hz": 700.0, "lp_q": 1.2, "attack": 0.004, "decay": 0.23,
	}
	r[&"confirm"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 0.32, "loop": false,
		"seed": 8504, "base_hz": 220.0, "base_hz_end": 330.0,
		"partials": [1.0, 2.0], "amps": [0.42, 0.18], "waves": [0, 0],
		"lp_hz": 2400.0, "lp_q": 1.0, "attack": 0.006, "decay": 0.31,
	}
	r[&"law_chord"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 1.9, "loop": false,
		"seed": 8505, "base_hz": D2, "partials": [1.0, 1.5, 1.78, 3.0],
		"amps": [0.40, 0.28, 0.20, 0.08], "waves": [0, 0, 0, 1],
		"lp_hz": 1200.0, "lp_q": 1.1, "attack": 0.12, "decay": 1.78,
	}
	r[&"research_shine"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.5, "loop": false,
		"seed": 8506, "base_hz": 293.7, "base_hz_end": 440.0,
		"partials": [1.0, 1.5, 2.0, 3.0], "amps": [0.34, 0.24, 0.18, 0.09],
		"waves": [0, 0, 0, 0], "lp_hz": 1800.0, "lp_hz_end": 3600.0, "lp_q": 1.3,
		"attack": 0.05, "decay": 1.45,
	}

	# =============================================================== alerts ===
	# Graded on purpose: one tone, then a beating minor second, then a tritone
	# with a sub under it. The player learns the severity before reading a word.
	r[&"sting_info"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 0.58, "loop": false,
		"seed": 8601, "base_hz": 220.0, "partials": [1.0, 2.0],
		"amps": [0.40, 0.14], "waves": [0, 0], "lp_hz": 1800.0, "lp_q": 1.0,
		"attack": 0.01, "decay": 0.56,
	}
	r[&"sting_warn"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.05, "loop": false,
		"seed": 8602, "base_hz": 233.1, "partials": [1.0, 1.0595, 2.0],
		"amps": [0.40, 0.34, 0.12], "waves": [0, 0, 0],
		"lp_hz": 2000.0, "lp_q": 1.2, "am": [[6.0, 0.55]],
		"attack": 0.008, "decay": 1.02,
	}
	r[&"sting_critical"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_MID, "seconds": 1.65, "loop": false,
		"seed": 8603, "base_hz": 155.6, "partials": [1.0, 1.414, 2.0, 2.83],
		"amps": [0.38, 0.34, 0.18, 0.09], "waves": [1, 1, 0, 0],
		"lp_hz": 2600.0, "lp_hz_end": 900.0, "lp_q": 2.0,
		"am": [[7.5, 0.62]], "attack": 0.005, "decay": 1.6,
		"events": [{"kind": &"thud", "offsets": [0.0], "hz": 44.0,
			"decay": 1.0, "amp": 0.7, "noise": 0.05}],
	}
	r[&"war_horn"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 2.5, "loop": false,
		"seed": 8604, "base_hz": 55.0, "base_hz_end": 51.9,
		"partials": [1.0, 1.5, 2.0, 3.0, 4.0],
		"amps": [0.45, 0.30, 0.20, 0.10, 0.05], "waves": [1, 1, 0, 0, 0],
		"lp_hz": 700.0, "lp_hz_end": 1400.0, "lp_q": 1.4,
		"attack": 0.35, "decay": 2.1, "noise_amt": 0.05,
	}
	r[&"relief"] = {
		"engine": &"tonal", "sr": LcnDsp.SR_LOW, "seconds": 2.2, "loop": false,
		"seed": 8605, "base_hz": A2, "partials": [1.0, 1.5, 2.0, 2.5],
		"amps": [0.34, 0.24, 0.18, 0.10], "waves": [0, 0, 0, 0],
		"lp_hz": 400.0, "lp_hz_end": 1700.0, "lp_q": 1.1,
		"attack": 0.5, "decay": 1.7,
	}

	# ================================================================ score ===
	# Five stems, one loop length, started together and mixed by the simulation.
	# Nothing here is "triggered" — the score is a continuous reading of the
	# state of the city, and the player never hears a cue fire.
	r[&"mus_bed"] = {
		"engine": &"tonal", "sr": MUSIC_SR, "seconds": MUSIC_LOOP, "loop": true,
		"seed": 8701, "base_hz": D1, "partials": [1.0, 2.0, 3.0, 4.0],
		"amps": [0.50, 0.30, 0.15, 0.07], "waves": [1, 0, 0, 0],
		"detune": 5.0, "lp_hz": 250.0, "lp_q": 1.0, "am": [[0.10417, 0.18]],
	}
	r[&"mus_pulse"] = {
		"engine": &"noise", "sr": MUSIC_SR, "seconds": MUSIC_LOOP, "loop": true,
		"seed": 8702, "bed": 0.0,
		"events": [{"kind": &"thud",
			"offsets": [0.0, 1.2, 2.4, 3.6, 4.8, 6.0, 7.2, 8.4],
			"hz": 41.0, "decay": 0.5, "amp": 0.8, "noise": 0.06}],
	}
	r[&"mus_hope"] = {
		"engine": &"tonal", "sr": MUSIC_SR, "seconds": MUSIC_LOOP, "loop": true,
		"seed": 8703, "base_hz": D2, "partials": [1.0, 1.5, 2.0, 2.378, 3.0],
		"amps": [0.30, 0.26, 0.20, 0.20, 0.11], "waves": [0, 0, 0, 0, 0],
		"detune": 3.5, "lp_hz": 950.0, "lp_q": 1.0, "am": [[0.10417, 0.28]],
	}
	r[&"mus_dread"] = {
		"engine": &"tonal", "sr": MUSIC_SR, "seconds": MUSIC_LOOP, "loop": true,
		"seed": 8704, "base_hz": D2, "partials": [1.0, 1.0595, 1.587, 2.0],
		"amps": [0.30, 0.28, 0.22, 0.14], "waves": [1, 1, 0, 0],
		"detune": 6.0, "lp_hz": 540.0, "lp_q": 1.6, "am": [[3.75, 0.42]],
	}
	r[&"mus_perc"] = {
		"engine": &"noise", "sr": MUSIC_SR, "seconds": MUSIC_LOOP, "loop": true,
		"seed": 8705, "bed": 0.0,
		"events": [
			{"kind": &"metal", "offsets": [0.0, 2.4, 4.8, 7.2], "hz": 190.0,
				"decay": 0.9, "amp": 0.5, "noise": 0.15},
			{"kind": &"clank", "offsets": [1.2, 3.6, 6.0, 8.4], "hz": 78.0,
				"decay": 0.42, "amp": 0.34, "noise": 0.2},
			{"kind": &"tick", "offsets": [0.6, 1.8, 3.0, 4.2, 5.4, 6.6, 7.8, 9.0],
				"hz": 1400.0, "decay": 0.05, "amp": 0.13, "noise": 0.7},
		],
	}

	_cache = r

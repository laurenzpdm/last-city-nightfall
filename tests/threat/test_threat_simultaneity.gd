extends TestCase
## [P08] THE NIGHT HAS TO HAPPEN.
##
## Everything here is pinned from one measured 24000-tick run of first_night,
## three nights, 34 spawns, counted rather than inferred:
##
##     combat.enemies_alive   max 4        on every night of the campaign
##     [feel] wave 1 felt at strength 0.01
##
## Both numbers came from constants that could not tell one night from another.
## `pulse_max_units = 4` split every packet into fours at every difficulty for
## ever, so night two's announced "column out of the south-east (28 units)"
## arrived as four bodies, dead in 120 ticks, four more 340 ticks later, eight
## times over. `level_reference_budget = 620.0` divided every night's budget by
## a day-45 army, so the opening week — 8.0, 30.0, 54.0 — landed on the player
## at 0.01, 0.069 and 0.23 of the meter that drives the shake, the edge pulse
## and the mix.
##
## These tests are about the SHAPE of a night rather than its balance: how many
## bodies may share one moment, and how hard that moment reads. If a future
## tuning pass wants gentler nights it may move the numbers; it may not go back
## to a campaign whose eighth night looks exactly like its first.

const HORIZON: int = 20

var world: SimFixture = null
var threat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["threat"])


func setup() -> void:
	world = SimFixture.new(31).start()
	threat = world.system(&"threat")


func teardown() -> void:
	if world != null:
		world.stop()


func _profile() -> ThreatProfile:
	return threat.call("profile") as ThreatProfile


func _plan() -> WavePlan:
	return threat.call("plan") as WavePlan


func _state() -> String:
	return String((threat.call("serialize") as Dictionary).get("state", ""))


func _run_to_night(limit: int = 12000) -> bool:
	for _i: int in limit / 20:
		world.run(20)
		if _state() == "active":
			return true
	return false


## The most bodies that walk in on any single tick of a plan — which is what
## `combat.enemies_alive` peaks at, minus whatever the guns have already killed.
func _peak_arrival(p: WavePlan) -> int:
	var by_tick: Dictionary[int, int] = {}
	for g: WaveGroup in p.groups:
		by_tick[g.delay_ticks] = int(by_tick.get(g.delay_ticks, 0)) + g.count
	var peak: int = 0
	for k: int in by_tick.keys():
		peak = maxi(peak, by_tick[k])
	return peak


## What the director would put on one arrival moment of night `n`, using only
## the profile's own rules, so the whole campaign can be checked without living
## through forty in-world days.
func _peak_for(n: int, units: int, budget: float) -> int:
	var p: ThreatProfile = _profile()
	var e: int = p.echelon_count(n, units, budget)
	return (units + e - 1) / e


# --- simultaneity -------------------------------------------------------------

func test_an_arrival_grows_with_the_night_it_belongs_to() -> void:
	# THE regression. A flat cap makes night eight indistinguishable from night
	# one at the only moment that matters — the moment they come over the ridge.
	var p: ThreatProfile = _profile()
	var first: int = p.pulse_units(p.base_budget(1))
	var eighth: int = p.pulse_units(p.base_budget(8))
	assert_gt(float(eighth), float(first) * 2.5,
		("an arrival on night eight (%d bodies) must dwarf one on night one (%d). "
		+ "A constant 4 for the whole campaign is the drip this build shipped.")
		% [eighth, first])
	for n: int in range(2, HORIZON):
		assert_ge(float(p.pulse_units(p.base_budget(n))),
			float(p.pulse_units(p.base_budget(n - 1))),
			"and it never shrinks as the campaign escalates (night %d)" % n)


func test_a_mid_campaign_night_puts_a_wall_of_them_on_the_map_at_once() -> void:
	# Budgets and unit counts taken from a real 60000-tick run of first_night:
	# night 3 composed 48 units on 142 budget, night 5 71 on 110, night 7 198 on
	# 413. Under the shipped `pulse_max_units = 4` every one of those arrived
	# four at a time.
	var cases: Array[Dictionary] = [
		{"night": 3, "units": 48, "budget": 142.0, "floor": 12},
		{"night": 5, "units": 71, "budget": 110.0, "floor": 10},
		{"night": 7, "units": 198, "budget": 413.0, "floor": 24},
	]
	for c: Dictionary in cases:
		var peak: int = _peak_for(int(c["night"]), int(c["units"]), float(c["budget"]))
		assert_ge(float(peak), float(c["floor"]),
			("night %d (%d units, budget %.0f) must land at least %d at once; "
			+ "it lands %d") % [int(c["night"]), int(c["units"]), float(c["budget"]),
			int(c["floor"]), peak])


func test_no_single_moment_can_flood_the_map() -> void:
	# The other direction, and the reason there is a ceiling at all: a night is
	# a fight, not a frame spike. Nothing may drop a thousand bodies on one tick
	# however large the budget grows.
	var p: ThreatProfile = _profile()
	assert_le(float(p.pulse_units(99999.0)), float(p.pulse_units_max),
		"the arrival ceiling holds against any budget")
	assert_le(float(_peak_for(40, 4000, 9000.0)), 4000.0 / 2.0,
		"a four-thousand-unit night is still cut into pieces")


func test_a_real_night_arrives_in_echelons_and_loses_nobody() -> void:
	# The end-to-end version, against the plan the director actually composed.
	assert_true(_run_to_night(), "the fixture must reach a night")
	var p: WavePlan = _plan()
	assert_not_null(p, "there is a plan")
	if p.unit_count() <= 1:
		skip("a one-unit night has no echelons")
		return

	var moments: Dictionary[int, int] = {}
	var total: int = 0
	for g: WaveGroup in p.groups:
		moments[g.delay_ticks] = int(moments.get(g.delay_ticks, 0)) + g.count
		total += g.count
	assert_eq(total, p.unit_count(),
		"packing a night into echelons must not lose or invent a body — the "
		+ "telegraph promised this exact roster")
	assert_ge(float(moments.size()), 2.0,
		"even the teaching night arrives in more than one wave")
	assert_eq(moments.size(), _profile().echelon_count(p.wave, total, p.budget),
		"and in exactly as many as the profile says it should")

	# Every group in an echelon shares a tick. That is the whole difference
	# between a wave and a metronome, so it is asserted rather than assumed.
	var seen: Dictionary[int, int] = {}
	for g2: WaveGroup in p.groups:
		if seen.has(g2.echelon):
			assert_eq(g2.delay_ticks, seen[g2.echelon],
				"echelon %d must land on ONE tick" % g2.echelon)
		else:
			seen[g2.echelon] = g2.delay_ticks


# --- how hard a night reads ----------------------------------------------------

func test_the_first_nightfall_is_actually_felt() -> void:
	# `[feel] wave 1 felt at strength 0.01` is the line this exists to make
	# impossible. Everything downstream — shake, vignette, the mix — multiplies
	# by this number, so 0.01 is indistinguishable from no night at all.
	var p: ThreatProfile = _profile()
	var s1: float = p.strength_of(p.base_budget(1), 1)
	assert_gt(s1, 0.30,
		"the first nightfall in a game called Nightfall must land above 0.30; "
		+ "it landed at 0.01 against a day-45 constant")
	assert_le(s1, 0.85, "but the teaching night is not the loudest night there is")


func test_an_ordinary_night_reads_the_same_wherever_it_falls_in_the_curve() -> void:
	# The point of normalising against the night's OWN expected budget: an
	# on-curve night is an on-curve night. Late nights read higher only by the
	# declared campaign gain, never by two orders of magnitude.
	var p: ThreatProfile = _profile()
	var lo: float = p.strength_of(p.base_budget(2), 2)
	var hi: float = p.strength_of(p.base_budget(12), 12)
	assert_gt(hi, lo, "a late ordinary night still reads heavier than an early one")
	assert_le(hi - lo, p.level_campaign_gain + 0.001,
		"but by the declared campaign gain and not one point more")


func test_a_set_piece_reads_louder_than_the_night_it_replaces_and_a_lull_softer() -> void:
	var p: ThreatProfile = _profile()
	for n: int in [3, 7, 12]:
		var ordinary: float = p.strength_of(p.base_budget(n), n)
		var piece: float = p.strength_of(p.base_budget(n) * p.set_piece_multiplier, n)
		var lull: float = p.strength_of(p.base_budget(n) * p.lull_factor, n)
		assert_gt(piece, ordinary + 0.04,
			"night %d as a set piece has to be legibly bigger" % n)
		assert_lt(lull, ordinary - 0.02,
			"and a lull has to be legibly smaller, or the contrast does nothing" % [])


func test_the_reading_stays_inside_its_own_range() -> void:
	var p: ThreatProfile = _profile()
	for n: int in range(1, 60):
		for mult: float in [0.0, 0.2, 1.0, 1.55, 4.0, 40.0]:
			var v: float = p.strength_of(p.base_budget(n) * mult, n)
			assert_between(v, 0.0, 1.0,
				"strength_of(night %d x%.2f) must stay 0..1" % [n, mult])


func test_the_meter_moves_the_moment_the_first_night_is_live() -> void:
	# threat_level() is what the HUD, the audio mix and [P10]'s pacing all read.
	# Under the old divisor a live night one sat at 0.35 — the floor of the
	# formula — which is to say it carried no information at all.
	assert_true(_run_to_night(), "the fixture must reach a night")
	var live: float = float(threat.call("threat_level"))
	assert_gt(live, 0.45,
		"a night in progress must read above the formula's own floor; it read "
		+ "0.35 + 0.65 * 0.01 before")
	assert_between(live, 0.0, 1.0, "and stay a 0..1 number")

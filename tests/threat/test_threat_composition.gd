extends TestCase
## [P08] Threat Director — composition legality and approach selection.
##
## The composer is allowed to surprise the player. It is not allowed to break
## its own rules: a gated creature must never arrive early, a single kind must
## never eat a night, a zero-weight boss must never turn up on a Tuesday, and
## no approach may ever carry more of a night than the declared cap.

const NIGHTS: int = 30

var world: SimFixture = null
var threat: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["threat"])


func setup() -> void:
	world = SimFixture.new(11).start()
	threat = world.system(&"threat")


func teardown() -> void:
	if world != null:
		world.stop()


func _profile() -> ThreatProfile:
	return threat.call("profile") as ThreatProfile


func _units() -> Array[ThreatUnit]:
	return threat.call("units")


func _rng(name: String) -> RandomNumberGenerator:
	return Rng.stream(name)


## Composes one night in isolation, off its own stream, so a test never
## disturbs the campaign the fixture is running.
func _compose(night: int, budget: float, shape: StringName, salt: String = "") -> Array[Dictionary]:
	return WaveComposer.compose(_profile(), night, budget, shape, _units(),
		_rng("test_compose_%d_%s%s" % [night, shape, salt]))


# --- legality ------------------------------------------------------------------

func test_every_composed_night_is_legal() -> void:
	if _units().is_empty():
		skip("game/content/enemies/ is empty in this build")
		return
	var p: ThreatProfile = _profile()
	for night: int in range(1, NIGHTS):
		var budget: float = p.base_budget(night)
		for shape: StringName in ThreatDefs.SHAPES:
			var groups: Array[Dictionary] = _compose(night, budget, shape)
			var errors: PackedStringArray = WaveComposer.legality_errors(
				p, night, budget, groups, _units())
			assert_empty(errors, "night %d as %s: %s" % [night, shape, ", ".join(errors)])


func test_gates_are_absolute() -> void:
	if _units().is_empty():
		skip("game/content/enemies/ is empty in this build")
		return
	# Even at an absurd budget, nothing may arrive before the night its content
	# author gated it to. This is the promise adaptation is not allowed to break.
	for night: int in range(1, 8):
		for shape: StringName in ThreatDefs.SHAPES:
			for group: Dictionary in _compose(night, 5000.0, shape, "rich"):
				var unit: ThreatUnit = WaveComposer.find(_units(), group["enemy"])
				assert_not_null(unit, "composed '%s' is not in the roster" % group["enemy"])
				if unit != null:
					assert_le(float(unit.min_wave), float(night),
						"'%s' is gated to night %d and appeared on night %d"
						% [unit.id, unit.min_wave, night])


func test_a_night_is_never_empty() -> void:
	if _units().is_empty():
		skip("game/content/enemies/ is empty in this build")
		return
	for budget: float in [0.5, 1.0, 3.0, 8.0]:
		var groups: Array[Dictionary] = _compose(1, budget, ThreatDefs.SHAPE_COLUMN, "poor")
		assert_not_empty(groups, "a budget of %.1f still has to send something" % budget)


func test_a_zero_budget_sends_nothing() -> void:
	assert_empty(_compose(5, 0.0, ThreatDefs.SHAPE_COLUMN, "zero"),
		"peace is peace; a budget of nothing composes nothing")


func test_placed_only_units_never_roll_in() -> void:
	var placed: Array[ThreatUnit] = []
	for u: ThreatUnit in _units():
		if u.weight <= 0.0:
			placed.append(u)
	if placed.is_empty():
		skip("this roster has no placed-only units")
		return
	for night: int in range(1, NIGHTS):
		for shape: StringName in [ThreatDefs.SHAPE_SWARM, ThreatDefs.SHAPE_COLUMN,
				ThreatDefs.SHAPE_HAMMER, ThreatDefs.SHAPE_PROBE]:
			for group: Dictionary in _compose(night, 4000.0, shape, "roll"):
				for u2: ThreatUnit in placed:
					assert_ne(group["enemy"], u2.id,
						"'%s' is placed-only and must never be rolled into a %s night"
						% [u2.id, shape])


func test_a_set_piece_places_its_anchor() -> void:
	var heavy: Array[ThreatUnit] = []
	for u: ThreatUnit in _units():
		if u.role == ThreatDefs.ROLE_SIEGE or u.role == ThreatDefs.ROLE_BREAKER:
			heavy.append(u)
	if heavy.is_empty():
		skip("this roster has nothing heavy enough to anchor a set piece")
		return
	var groups: Array[Dictionary] = _compose(12, 900.0, _profile().set_piece_shape, "anchor")
	var found: bool = false
	for g: Dictionary in groups:
		for u2: ThreatUnit in heavy:
			if g["enemy"] == u2.id:
				found = true
	assert_true(found, "a set piece has to have a face")


func test_variety_is_capped() -> void:
	if _units().is_empty():
		skip("game/content/enemies/ is empty in this build")
		return
	var p: ThreatProfile = _profile()
	for night: int in range(4, NIGHTS):
		for shape: StringName in ThreatDefs.SHAPES:
			var groups: Array[Dictionary] = _compose(night, 3000.0, shape, "wide")
			assert_le(float(groups.size()), float(p.max_kinds_per_wave),
				"night %d as %s fielded %d kinds" % [night, shape, groups.size()])


func test_shape_actually_changes_the_night() -> void:
	if _units().size() < 3:
		skip("need a few kinds before shape can express anything")
		return
	var swarmy: Dictionary = _role_mix(_compose(14, 400.0, ThreatDefs.SHAPE_SWARM, "mix"))
	var heavy: Dictionary = _role_mix(_compose(14, 400.0, ThreatDefs.SHAPE_HAMMER, "mix"))
	assert_ne(swarmy, heavy, "a swarm night and a hammer night must not be the same night")


func _role_mix(groups: Array[Dictionary]) -> Dictionary:
	var out: Dictionary = {}
	for g: Dictionary in groups:
		var u: ThreatUnit = WaveComposer.find(_units(), g["enemy"])
		if u == null:
			continue
		out[String(u.role)] = int(out.get(String(u.role), 0)) + int(g["count"])
	return out


func test_composition_is_deterministic() -> void:
	# Reseeded from scratch each run, exactly the way a replay does it: the
	# composer must be a pure function of (profile, night, budget, shape,
	# roster, stream position) and of nothing else.
	var produce: Callable = func() -> Array:
		Rng.reset(4242)
		var out: Array = []
		for night: int in range(1, 16):
			var shape: StringName = WaveComposer.roll_shape(_profile(), night, false,
				Rng.stream("threat"))
			var groups: Array[Dictionary] = WaveComposer.compose(_profile(), night,
				_profile().base_budget(night), shape, _units(), Rng.stream("threat"))
			out.append(String(shape))
			for g: Dictionary in groups:
				out.append([String(g["enemy"]), int(g["count"])])
		return out
	assert_deterministic(produce, "the same seed must compose the same campaign")


func test_a_different_seed_composes_a_different_campaign() -> void:
	if _units().size() < 3:
		skip("need a few kinds before a seed can express anything")
		return
	var run: Callable = func(s: int) -> Array:
		Rng.reset(s)
		var out: Array = []
		for night: int in range(1, 16):
			var shape: StringName = WaveComposer.roll_shape(_profile(), night, false,
				Rng.stream("threat"))
			for g: Dictionary in WaveComposer.compose(_profile(), night,
					_profile().base_budget(night), shape, _units(), Rng.stream("threat")):
				out.append([String(g["enemy"]), int(g["count"])])
		return out
	assert_ne(run.call(1), run.call(2), "two seeds must not produce the same campaign")


# --- the roster adapter ---------------------------------------------------------

func test_the_roster_is_adapted_not_invented() -> void:
	var ids: PackedStringArray = PackedStringArray()
	for u: ThreatUnit in _units():
		ids.append(String(u.id))
		assert_gt(u.cost, 0.0, "'%s' must cost something to field" % u.id)
		assert_ge(float(u.pack_size), 1.0, "'%s' must arrive in whole packs" % u.id)
		assert_true(ThreatDefs.is_role(u.role), "'%s' has role '%s'" % [u.id, u.role])
		assert_between(u.max_share, 0.05, 1.0, "'%s' share cap" % u.id)
	for id: StringName in Registry.ids("enemies"):
		assert_has(ids, String(id),
			"'%s' is in game/content/enemies/ but the director cannot field it" % id)


func test_roles_cover_the_shape_vocabulary() -> void:
	if _units().is_empty():
		skip("game/content/enemies/ is empty in this build")
		return
	var seen: Dictionary = {}
	for u: ThreatUnit in _units():
		seen[String(u.role)] = true
	assert_ge(float(seen.size()), 3.0,
		"a roster that fills fewer than three roles cannot express a shape: %s" % str(seen.keys()))


# --- approach vectors ------------------------------------------------------------

func test_the_world_offers_approaches() -> void:
	var vs: Array = threat.call("vectors")
	assert_not_empty(vs, "every world must offer somewhere for them to come from")
	for v: Dictionary in vs:
		assert_between(float(v["defence"]), 0.0, 1.0, "defence rating is 0..1")
		assert_gt(float(v["cells"]), 0.0, "an approach must have a road on it")


func test_shares_sum_to_one_and_respect_the_cap() -> void:
	var p: ThreatProfile = _profile()
	var planner := ApproachPlanner.new()
	planner.bind(p, world.system(&"grid"), world.system(&"build"), world.system(&"heat"))
	planner.build_vectors()
	for night: int in range(1, NIGHTS):
		var vs: Array[ThreatVector] = planner.select(night, false, Rng.stream("test_vectors_%d" % night))
		if vs.is_empty():
			continue
		var total: float = 0.0
		for v: ThreatVector in vs:
			total += v.share
			if vs.size() > 1:
				assert_le(v.share, maxf(p.vector_share_cap, 1.0 / float(vs.size())) + 0.001,
					"night %d: no single approach may carry %.2f of it" % [night, v.share])
		assert_near(total, 1.0, 0.001, "night %d: the shares must be a whole night" % night)


func test_early_nights_come_down_one_road() -> void:
	var p: ThreatProfile = _profile()
	assert_eq(p.vector_count(1, false), p.vectors_base, "night 1 opens one front")
	assert_near(p.probe_share(1), 0.0, 0.0001, "night 1 does not probe; it teaches")
	assert_near(p.probe_share(2), 0.0, 0.0001, "night 2 does not probe either")


func test_probing_ramps_in_and_stops() -> void:
	var p: ThreatProfile = _profile()
	var previous: float = -1.0
	for night: int in range(1, NIGHTS):
		var s: float = p.probe_share(night)
		assert_ge(s, previous, "the probe share must never go backwards")
		assert_le(s, p.probe_share_max + 0.0001, "and never exceed the declared maximum")
		previous = s
	assert_near(p.probe_share(NIGHTS), p.probe_share_max, 0.0001,
		"by the late campaign the flanks are fully committed")


func test_the_probe_finds_the_weak_side() -> void:
	var p: ThreatProfile = _profile()
	var planner := ApproachPlanner.new()
	planner.bind(p, world.system(&"grid"), world.system(&"build"), world.system(&"heat"))
	planner.build_vectors()
	var cands: Array[ThreatVector] = planner.candidates()
	if cands.size() < 2:
		skip("this map has only one approach, so there is no weak side to find")
		return
	var vs: Array[ThreatVector] = planner.select(20, false, Rng.stream("test_probe"))
	var probe: ThreatVector = null
	var main: ThreatVector = null
	for v: ThreatVector in vs:
		if v.role == ThreatVector.ROLE_PROBE:
			probe = v
		elif v.role == ThreatVector.ROLE_MAIN:
			main = v
	if probe == null:
		skip("no probe vector was opened on this map")
		return
	# The probe is defined as the least-defended approach that is not the main
	# road. Anything else would make the "turtling one side is punished" promise
	# a slogan rather than a rule.
	var weakest: float = 2.0
	for c: ThreatVector in cands:
		if main != null and c.lane == main.lane:
			continue
		weakest = minf(weakest, c.defence)
	assert_near(probe.defence, weakest, 0.0001,
		"the probe must be aimed at the weakest side that is not the main road")


func test_the_main_road_is_the_fastest_road() -> void:
	var planner := ApproachPlanner.new()
	planner.bind(_profile(), world.system(&"grid"), world.system(&"build"), world.system(&"heat"))
	planner.build_vectors()
	var cands: Array[ThreatVector] = planner.candidates()
	if cands.size() < 2:
		skip("this map has only one approach")
		return
	var vs: Array[ThreatVector] = planner.select(1, false, Rng.stream("test_main"))
	assert_size(vs, 1, "night 1 opens exactly one front")
	var fastest: int = 1 << 30
	for c: ThreatVector in cands:
		fastest = mini(fastest, c.travel)
	assert_eq(vs[0].travel, fastest, "the obvious attack comes down the fastest road")

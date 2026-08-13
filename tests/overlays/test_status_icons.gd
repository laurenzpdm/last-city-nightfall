extends TestCase
## [P19] The always-on legibility layer's judgement, tested without a screen.
##
## The layer's entire value is its editorial policy: WHICH problem a building is
## accused of when several are true at once, and — just as important — when it
## says nothing at all. "A healthy base is silent" is a design claim, so it is
## asserted here on a synthetic snapshot where every state can be set exactly,
## including states a real run only reaches after twenty minutes of night.

var pal: LcnOverlayPalette
var icons: LcnStatusIcons
var snap: LcnOverlaySnapshot


func suite_name() -> String:
	return "overlay_status"


func setup() -> void:
	pal = LcnOverlayPalette.new("off", false, false)
	snap = LcnOverlaySnapshot.new()
	icons = LcnStatusIcons.new()
	icons.snap = snap
	icons.pal = pal
	icons.alt = false


func teardown() -> void:
	icons.free()


## Builds one building, optionally with a matching heat node, entirely by hand.
## `workers` of -1 means "no citizen system exists", which is what the snapshot
## reports until [P05] staffs anything.
func _building(kind: StringName, flags: int = 0, hp: float = 1.0,
		need: int = 0, workers: int = -1) -> int:
	var i: int = snap.bld_count
	snap.bld_count = i + 1
	snap.bld_id.append(100 + i)
	snap.bld_x.append(i * 4)
	snap.bld_y.append(0)
	snap.bld_w.append(2)
	snap.bld_h.append(2)
	snap.bld_state.append(0)
	snap.bld_workers.append(workers)
	snap.bld_need.append(need)
	snap.bld_flags.append(flags)
	snap.bld_hp.append(hp)
	snap.bld_progress.append(0.4)
	snap.bld_reach.append(0.0)
	snap.bld_kind.append(kind)
	snap.bld_row[100 + i] = i
	return i


func _heat_node(for_row: int, node_flags: int, served: float = 1.0) -> void:
	var i: int = snap.node_count
	snap.node_count = i + 1
	snap.node_id.append(snap.bld_id[for_row])
	snap.node_x.append(snap.bld_x[for_row])
	snap.node_y.append(0)
	snap.node_w.append(2)
	snap.node_h.append(2)
	snap.node_slot.append(0)
	snap.node_net.append(1)
	snap.node_state.append(0)
	snap.node_flags.append(node_flags)
	snap.node_dirs.append(0)
	snap.node_link.append(0)
	snap.node_choke.append(0)
	snap.node_bx.append(-1)
	snap.node_by.append(-1)
	snap.node_served.append(served)
	snap.node_load.append(0.0)
	snap.node_temp.append(12.0)
	snap.node_freeze.append(-10.0)
	snap.node_demand.append(5.0)
	snap.node_output.append(0.0)
	snap.node_fuel.append(1.0)
	snap.node_eta.append(1.0)
	snap.node_cool.append(0.0)
	snap.node_kind.append(snap.bld_kind[for_row])
	snap.node_row[snap.bld_id[for_row]] = i
	snap.bld_flags[for_row] |= LcnOverlaySnapshot.B_HEAT


# =========================================================================

## The headline claim of the whole part: a base that is fine is not decorated.
func test_a_healthy_building_says_nothing() -> void:
	var b: int = _building(&"housing_block")
	_heat_node(b, LcnOverlayDefs.F_CONSUMER, 1.0)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.NONE,
		"a served, staffed, undamaged building draws no badge at all")


func test_a_starved_building_screams() -> void:
	var b: int = _building(&"housing_block")
	_heat_node(b, LcnOverlayDefs.F_CONSUMER, 0.1)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.NO_HEAT)
	assert_eq(LcnOverlayDefs.problem_severity(icons.problem_of(b)), 2, "and it is critical")


func test_a_brownout_warns_but_does_not_scream() -> void:
	var b: int = _building(&"workshop")
	_heat_node(b, LcnOverlayDefs.F_CONSUMER, 0.6)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.BROWNOUT)
	assert_eq(LcnOverlayDefs.problem_severity(icons.problem_of(b)), 1)


## Worst wins, exactly once. A frozen workshop is not also told it is cold and
## understaffed — that is what keeps a dying district readable.
func test_frozen_outranks_everything_else() -> void:
	var b: int = _building(&"workshop", 0, 0.2, 4, 0)
	_heat_node(b, LcnOverlayDefs.F_CONSUMER | LcnOverlayDefs.F_FROZEN
		| LcnOverlayDefs.F_STARVED_FUEL, 0.0)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.FROZEN,
		"one badge, and it is the one that matters")


func test_no_grid_outranks_merely_starved() -> void:
	var b: int = _building(&"warmth_radiator")
	_heat_node(b, LcnOverlayDefs.F_CONSUMER | LcnOverlayDefs.F_NO_NETWORK, 0.0)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.UNPOWERED,
		"'you never connected it' is a different bug from 'the grid is short'")


func test_fuel_starvation_is_called_out_on_the_generator() -> void:
	var b: int = _building(&"coal_generator")
	_heat_node(b, LcnOverlayDefs.F_PRODUCER | LcnOverlayDefs.F_STARVED_FUEL, 1.0)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.NO_FUEL)


## A construction site is not a wreck and not understaffed. Before this rule the
## reference run drew a red alarm over every ghost in the build queue.
func test_a_construction_site_is_quiet_until_you_ask() -> void:
	var b: int = _building(&"heat_pipe", LcnOverlaySnapshot.B_GHOST, 0.15, 2, 0)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.NONE, "silent by default")
	icons.alt = true
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.BUILDING, "and calm when asked")
	assert_eq(LcnOverlayDefs.problem_severity(LcnOverlayDefs.Problem.BUILDING), 0,
		"a build site never pulses")


## Until [P05] staffs anything every building reports zero crew. Badging them
## all would be noise, so -1 means "nobody knows" and nothing is claimed.
func test_no_crew_is_not_reported_without_a_citizen_system() -> void:
	var b: int = _building(&"workshop", 0, 1.0, 4, -1)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.NONE)
	var c: int = _building(&"smelter", 0, 1.0, 4, 1)
	assert_eq(icons.problem_of(c), LcnOverlayDefs.Problem.NO_WORKER,
		"but a real shortfall is reported")


func test_damage_is_reported_only_when_it_is_real() -> void:
	var whole: int = _building(&"wall", 0, 1.0)
	assert_eq(icons.problem_of(whole), LcnOverlayDefs.Problem.NONE)
	var scratched: int = _building(&"wall", 0, 0.8)
	assert_eq(icons.problem_of(scratched), LcnOverlayDefs.Problem.NONE,
		"a scratch is not an alarm")
	var wrecked: int = _building(&"wall", 0, 0.3)
	assert_eq(icons.problem_of(wrecked), LcnOverlayDefs.Problem.DAMAGED)


func test_a_disabled_building_is_not_accused_of_being_cold() -> void:
	var b: int = _building(&"smelter")
	_heat_node(b, LcnOverlayDefs.F_CONSUMER | LcnOverlayDefs.F_DISABLED, 0.0)
	assert_eq(icons.problem_of(b), LcnOverlayDefs.Problem.NONE,
		"you switched it off on purpose")


## Only severity 1 and 2 are allowed to move. Everything else is calm by
## contract, and reduce_motion silences even those.
func test_only_problems_pulse() -> void:
	assert_eq(LcnOverlayDefs.problem_severity(LcnOverlayDefs.Problem.NONE), 0)
	assert_eq(LcnOverlayDefs.problem_severity(LcnOverlayDefs.Problem.BUILDING), 0)
	for p: int in [LcnOverlayDefs.Problem.NO_HEAT, LcnOverlayDefs.Problem.FROZEN,
			LcnOverlayDefs.Problem.UNPOWERED, LcnOverlayDefs.Problem.DAMAGED]:
		assert_eq(LcnOverlayDefs.problem_severity(p), 2, "%s is critical" % LcnOverlayDefs.problem_label(p))


func test_every_problem_has_a_word_and_a_severity() -> void:
	for p: int in LcnOverlayDefs.PROBLEM_COUNT:
		assert_between(float(LcnOverlayDefs.problem_severity(p)), 0.0, 2.0)
		if p != LcnOverlayDefs.Problem.NONE:
			assert_ne(LcnOverlayDefs.problem_label(p), "", "problem %d has a label" % p)


func test_problem_colours_separate_by_severity() -> void:
	var calm: Color = icons.problem_color(LcnOverlayDefs.Problem.BUILDING)
	var warn: Color = icons.problem_color(LcnOverlayDefs.Problem.BROWNOUT)
	var bad: Color = icons.problem_color(LcnOverlayDefs.Problem.NO_HEAT)
	var frozen: Color = icons.problem_color(LcnOverlayDefs.Problem.FROZEN)
	assert_gt(LcnOverlayPalette.separation(calm, bad), 0.2, "calm and critical differ")
	assert_gt(LcnOverlayPalette.separation(warn, bad), 0.15, "warning and critical differ")
	assert_gt(LcnOverlayPalette.separation(frozen, bad), 0.2, "frozen is not just another red")


# --- mode vocabulary -------------------------------------------------------

func test_every_lens_has_an_id_a_title_and_a_blurb() -> void:
	for m: int in range(1, LcnOverlayDefs.MODE_COUNT):
		assert_ne(String(LcnOverlayDefs.mode_id(m)), "", "lens %d has an id" % m)
		assert_ne(LcnOverlayDefs.mode_title(m), "", "lens %d has a title" % m)
		assert_ne(LcnOverlayDefs.mode_blurb(m), "", "lens %d explains itself" % m)
		assert_eq(LcnOverlayDefs.mode_from_id(LcnOverlayDefs.mode_id(m)), m, "round trip")


func test_unknown_ids_fall_back_to_no_lens() -> void:
	assert_eq(LcnOverlayDefs.mode_from_id(&"nonsense"), LcnOverlayDefs.Mode.NONE)
	assert_eq(LcnOverlayDefs.mode_title(999), "")

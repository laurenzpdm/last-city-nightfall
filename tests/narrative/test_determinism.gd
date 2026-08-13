extends TestCase
## [P22] The winter is replayable.
##
## Narrative lives outside game/sim/**, so `tools/lint_sim.sh` does not grep it.
## That makes this suite the only thing standing between a rolled flavour line
## and a build where two runs of the same seed diverge, which is the one claim
## the whole project is built on. It checks the property dynamically, which is
## stronger than any grep: two whole worlds, same seed, byte-compared.

var world: SimFixture


func before_all() -> void:
	LcnNarrativeBootstrap.hook()


func setup() -> void:
	world = SimFixture.new(11).start()
	LcnNarrativeBootstrap.ensure()


func teardown() -> void:
	world.stop()


func test_two_runs_of_the_same_seed_are_identical() -> void:
	var diff: PackedStringArray = SimFixture.replay_diff(11, 900)
	assert_empty(diff, "the world diverged: %s" % ", ".join(diff))


func test_two_runs_that_answer_the_same_way_are_identical() -> void:
	var script: Dictionary = {
		200: [{"system": &"narrative", "op": "raise", "event": &"the_delegation"}],
		240: [{"system": &"narrative", "op": "choose", "event": &"the_delegation",
			"option": 0}],
		400: [{"system": &"narrative", "op": "raise", "event": &"the_drop"}],
		440: [{"system": &"narrative", "op": "choose", "event": &"the_drop",
			"option": 1}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(11, 800, script)
	assert_empty(diff, "answering a dilemma desynced the run: %s" % ", ".join(diff))


## The flavour deck is shuffled. If it were shuffled off anything but a named
## Rng stream, this is where it would show.
func test_the_flavour_is_rolled_off_a_named_stream() -> void:
	var a: PackedStringArray = _lines_after(11, 2400)
	var b: PackedStringArray = _lines_after(11, 2400)
	assert_eq(a, b, "the same seed said different things")
	var c: PackedStringArray = _lines_after(12, 2400)
	assert_ne(a, c, "every seed says exactly the same things, so nothing is rolled")


## Adding a roll here must never shift another system's sequence. Two worlds,
## one of which has been made to draw extra flavour, still agree everywhere else.
func test_a_narrative_roll_does_not_disturb_another_system() -> void:
	var plain: Dictionary = SimFixture.replay(13, 400)
	var fx: SimFixture = SimFixture.new(13).start()
	LcnNarrativeBootstrap.ensure()
	var n: NarrativeSystem = fx.system(&"narrative") as NarrativeSystem
	assert_not_null(n)
	for i: int in 40:
		n._draw(NarrativeFlavour.BANK_LOG, NarrativeFlavour.bank(NarrativeFlavour.BANK_LOG))
	fx.run(400)
	var noisy: Dictionary = fx.state()
	fx.stop()
	for part: String in ["heat", "climate", "citizens", "threat", "society"]:
		var a: Variant = ((plain.get("systems", {}) as Dictionary)).get(part)
		var b: Variant = ((noisy.get("systems", {}) as Dictionary)).get(part)
		if a == null or b == null:
			continue
		assert_eq(JsonCanon.canon(b), JsonCanon.canon(a),
			"forty narrative rolls moved [%s]" % part)


# =========================================================================
#  the lint game/sim/** gets and this folder does not
# =========================================================================

## `tools/lint_sim.sh` greps game/sim/** for the things §3 forbids. This part
## runs inside the tick and lives at game/narrative/, so that grep never sees
## it. The same rules are enforced here instead, over the files that step().
##
## The presenter and the installer are deliberately exempt and named: one draws
## and one touches the scene tree, which is exactly what a view file is for.
const SIM_SIDE_EXEMPT: Array[String] = [
	"narrative_card.gd", "narrative_bootstrap.gd", "_write_the_events.gd",
]

const FORBIDDEN: Array[Array] = [
	["randf(", "a bare randf() is not replayable; use Rng.stream()"],
	["randi(", "a bare randi() is not replayable; use Rng.stream()"],
	["randomize(", "reseeding the global generator destroys every replay"],
	["Time.get_ticks", "wall clock in the tick; use SimClock"],
	["Input.", "input belongs in view/ and ui/"],
	["InputMap.", "input belongs in view/ and ui/"],
	["Settings.", "a user setting must never reach a simulation decision"],
	["OS.get_cmdline", "a command line flag must never reach a simulation decision"],
	["func _process", "a system advances through step(tick), never a frame callback"],
	["get_tree(", "the sim does not know the scene tree exists"],
	["print(", "use Log.info; print() is invisible to the harness"],
]


func test_the_ticking_half_of_this_part_obeys_section_three() -> void:
	var files: PackedStringArray = _sim_side_files()
	assert_ge(float(files.size()), 8.0, "the lint found almost nothing to lint")
	for path: String in files:
		var text: String = FileAccess.get_file_as_string(path)
		assert_ne(text, "", "could not read %s" % path)
		var code: PackedStringArray = _code_lines(text)
		for rule: Array in FORBIDDEN:
			var needle: String = String(rule[0])
			var offender: String = ""
			for i: int in code.size():
				if code[i].contains(needle):
					offender = "line %d: %s" % [i + 1, code[i]]
					break
			assert_eq(offender, "", "%s — %s (%s)" % [
				path.get_file(), String(rule[1]), offender])


func _sim_side_files() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open("res://game/narrative")
	if dir == null:
		return out
	for f: String in dir.get_files():
		if not f.ends_with(".gd") or SIM_SIDE_EXEMPT.has(f):
			continue
		out.append("res://game/narrative/" + f)
	out.sort()
	return out


## Code only. A rule that fires on the sentence explaining the rule would make
## every one of these comments unwritable.
func _code_lines(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line: String in text.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("#"):
			continue
		var hash_at: int = trimmed.find("#")
		out.append(trimmed if hash_at < 0 else trimmed.substr(0, hash_at))
	return out


func _lines_after(world_seed: int, ticks: int) -> PackedStringArray:
	var fx: SimFixture = SimFixture.new(world_seed).start()
	LcnNarrativeBootstrap.ensure()
	fx.run(ticks)
	var n: NarrativeSystem = fx.system(&"narrative") as NarrativeSystem
	var out := PackedStringArray()
	if n != null:
		for row: Dictionary in n.journal.feed:
			out.append(String(row.get("text", "")))
	fx.stop()
	return out

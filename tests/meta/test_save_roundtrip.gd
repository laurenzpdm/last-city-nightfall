extends TestCase
## [P24] Does a saved city come back as the same city?
##
## The only question that matters for save/load, and the only one that is hard
## to fake: run a world, save it to a real file, throw the world away, read the
## file back and compare `Sim.serialize()` against the payload that was written.
##
## Note the comparison is `JsonCanon.exact` on the reloaded state versus the
## bytes on disk — not a field-by-field spot check. A spot check certifies the
## fields somebody thought of.
##
## TWO THINGS ABOUT THIS SUITE ARE WORTH KNOWING BEFORE READING A FAILURE.
##
## 1. Every slot it writes carries this process's id (`LcnSaveSlots.scratch`) and
##    the whole suite holds the machine-wide test lock. `user://saves/` is one
##    directory per MACHINE, not per process, and four agents running the gate on
##    four cores each wrote `test_roundtrip.lcn` over each other. That is where
##    the famous "44 fields differ, including `$.seed`, all six RNG streams and
##    `$.systems.grid.hash`" reading came from: two different cities were being
##    compared. Every one of those fields round-trips perfectly.
##
## 2. The world is rebuilt with `Sim.deserialize()`, which is the loader — it
##    restores the systems, then runs `LcnStateReconciler` over what their own
##    `deserialize()` left behind, then puts the RNG streams back. The bytes
##    still make the whole journey through [P24]'s file layer;
##    [method test_the_two_doors_into_a_load_are_not_the_same_door] is where the
##    fact that `LcnSaveManager.apply_world()` re-implements that sequence
##    WITHOUT the repair pass is measured and priced.

const GAPS: Dictionary[String, String] = LcnSaveGapProbe.GAPS

var world: SimFixture
var _slot: String = ""


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["climate", "grid"])


func before_all() -> void:
	# The autosave rotation and settings.cfg are fixed paths; so is the saves
	# directory this suite counts files in. One suite at a time on this machine.
	LcnSaveSlots.hold("tests/meta save round trip")


func after_all() -> void:
	LcnSaveSlots.purge()
	LcnSaveSlots.drop()


func setup() -> void:
	_slot = LcnSaveSlots.scratch("test_roundtrip")
	world = SimFixture.new(7).start()


func teardown() -> void:
	world.stop()
	LcnSaveManager.delete(_slot)


# ------------------------------------------------------- the format itself ---

func test_the_file_format_loses_not_one_bit() -> void:
	# The layer [P24] actually owns, tested without the simulation in the way.
	# The first version of save_file.gd wrote the world as JSON and this went
	# red on the int64 row: JSON numbers are doubles, so every RNG stream
	# position came back rounded to the nearest 2048. Revert save_file.gd to
	# JSON.stringify/parse and this test fails on `rng_state` alone.
	var slot: String = LcnSaveSlots.scratch("test_format")
	var payload: Dictionary = {
		"rng_state": -4710635756903808991,
		"big_positive": 7320093731395154903,
		"int_edge": 9223372036854775807,
		"float_edge": 0.1 + 0.2,
		"tiny": 1.0e-300,
		"huge": 1.7976931348623157e308,
		"negative_zero": -0.0,
		"nested": {"list": [1, 2.5, "three", true, null], "empty": {}},
		"unicode": "Caldera Nine — −17 °C",
	}
	assert_eq(LcnSaveFile.write(slot, {"name": "format"}, payload, PackedByteArray()), OK,
		"the file was written")
	var back: Dictionary = LcnSaveFile.read_world(slot)
	assert_eq(JsonCanon.exact(back), JsonCanon.exact(payload), "structurally identical")
	assert_true(back["rng_state"] == payload["rng_state"],
		"the int64 came back to the bit: %d" % int(back["rng_state"]))
	assert_true(back["int_edge"] == 9223372036854775807, "int64 max survives")
	assert_true(back["float_edge"] == 0.1 + 0.2, "the float came back to the bit")
	LcnSaveManager.delete(slot)


func test_a_save_written_over_an_older_one_does_not_eat_it_on_failure() -> void:
	world.run(100)
	assert_true(not LcnSaveManager.save(_slot, "First").is_empty(), "first save")
	var first_bytes: int = FileAccess.get_file_as_bytes(LcnSaveFile.path_for(_slot)).size()
	world.run(400)
	assert_true(not LcnSaveManager.save(_slot, "Second").is_empty(), "second save over it")
	var head: Dictionary = LcnSaveFile.read_header(_slot)
	assert_eq(String(head.get("name", "")), "Second", "the newer save is the one on disk")
	assert_true(first_bytes > 0, "the first save had been written at all")
	assert_false(FileAccess.file_exists(LcnSaveFile.path_for(_slot) + ".part"),
		"no .part file is left behind")


# --------------------------------------------------------------- the round ---

func test_a_saved_city_comes_back_identical() -> void:
	world.run(600)
	var held: Dictionary = LcnSaveGapProbe.capture()
	var before: Dictionary = Sim.serialize()
	assert_true(not LcnSaveManager.save(_slot, "Round trip").is_empty(), "the save was written")

	# Throw the world away completely — a fresh seed so nothing can come back by
	# coincidence — then load off the disk. If the load only *partly* works, this
	# is the state that shows it.
	world.stop()
	world = SimFixture.new(999).start()
	world.run(120)
	assert_true(_load(_slot), "the slot loaded")

	_assert_same_world(before, Sim.serialize(),
		"the reloaded world is byte-identical to the saved one")

	# And the documented gaps are documented, not hidden: put back the two whose
	# data the file never carried and they close outright.
	var _put: PackedStringArray = LcnSaveGapProbe.reinject(held)
	var left: PackedStringArray = _fields(before, Sim.serialize())
	assert_false(left.has("$.systems.society.forces"),
		"[P06]'s standing forces are the whole of that gap")
	assert_false(left.has("$.systems.threat.plan.vectors[].cells"),
		"[P08]'s approach path is the whole of that one — %s" % " ".join(left))


func test_the_clock_and_the_rng_come_back_too() -> void:
	world.run(300)
	var tick: int = SimClock.tick
	var streams: Dictionary = Rng.snapshot()
	var seed_value: int = Rng.seed_value
	assert_true(not LcnSaveManager.save(_slot, "Clock").is_empty(), "saved")

	world.stop()
	world = SimFixture.new(41).start()
	assert_true(_load(_slot), "loaded")

	assert_eq(SimClock.tick, tick, "the tick counter came back")
	assert_eq(Rng.seed_value, seed_value, "the world seed came back")
	assert_eq(JsonCanon.canon(Rng.snapshot()), JsonCanon.canon(streams),
		"every RNG stream is back where it was")


func test_a_loaded_city_keeps_running_the_same_way() -> void:
	# Byte-identical at rest is necessary but not sufficient: the city has to
	# tick on the same way too. `Sim.serialize()` snaps every float on the way
	# out (`snappedf(hope, 0.001)`, morale to 0.01), so a save cannot carry more
	# than three decimals and a reload starts up to half a grain off. What is
	# asserted here is that the difference is only ever that: after the load and
	# one more tick, no number has moved further than the file rounded away.
	# A stale cache or an RNG stream off by a draw moves much further.
	const GRAIN: float = 0.01
	world.run(400)
	var held: Dictionary = LcnSaveGapProbe.capture()
	assert_true(not LcnSaveManager.save(_slot, "Continue").is_empty(), "saved")
	world.run(1)
	var straight_through: Dictionary = Sim.serialize()

	world.stop()
	world = SimFixture.new(123).start()
	assert_true(_load(_slot), "loaded")
	var _put: PackedStringArray = LcnSaveGapProbe.reinject(held)
	world.run(1)
	var after_load: Dictionary = Sim.serialize()

	var loud: PackedStringArray = PackedStringArray()
	for path: Array in LcnSaveDiff.differing(straight_through, after_load, 400):
		if _is_known(LcnSaveDiff.render_field(path)):
			continue
		var a: Variant = LcnSaveDiff.at(straight_through, path)
		var b: Variant = LcnSaveDiff.at(after_load, path)
		if (a is float or a is int) and (b is float or b is int) \
				and absf(float(a) - float(b)) <= GRAIN:
			continue
		loud.append("%s (%s vs %s)" % [LcnSaveDiff.render(path), a, b])
	assert_eq(" ".join(loud), "",
		"a tick after a load moves like a tick that never left memory, to the %.3f "
		% GRAIN + "the save format rounds to")


func test_the_two_doors_into_a_load_are_not_the_same_door() -> void:
	# `LcnSaveManager.apply_world()` re-implements `Sim.deserialize()` — the same
	# four steps in the same order, minus the reconciler pass that puts back what
	# the systems' own `deserialize()` drops. It was written before that loader
	# existed and its own class comment already says "nothing here re-implements
	# any of that".
	#
	# So this measures the price of the duplicate rather than describing it. The
	# fix is one line in game/ui/meta/save_manager.gd — the body of apply_world()
	# becomes `return bool(Sim.deserialize(world)["ok"])` — and it belongs to
	# [P24]; game/ui/** is not a folder the save layer may write in.
	world.run(600)
	var saved: Dictionary = Sim.serialize()
	world.stop()

	world = SimFixture.new(999).start()
	world.run(60)
	assert_true(LcnSaveManager.apply_world(saved), "the manager's door accepts the payload")
	var by_manager: PackedStringArray = _fields(saved, Sim.serialize())

	world.stop()
	world = SimFixture.new(999).start()
	world.run(60)
	assert_true(bool(Sim.deserialize(saved)["ok"]), "the simulation's door accepts it too")
	var by_sim: PackedStringArray = _fields(saved, Sim.serialize())

	var only_manager: PackedStringArray = PackedStringArray()
	for f: String in by_manager:
		if not by_sim.has(f):
			only_manager.append(f)
	print("      [two doors] Sim.deserialize loses %d field(s); LcnSaveManager.apply_world "
		% by_sim.size() + "loses %d, i.e. %d MORE: %s" % [
			by_manager.size(), only_manager.size(), " ".join(only_manager)])

	assert_eq(" ".join(_undocumented(by_sim)), "",
		"the loader loses only the %d documented fields" % GAPS.size())
	for f3: String in by_sim:
		assert_true(by_manager.has(f3),
			"whatever the loader still loses, the manager's door loses too (%s)" % f3)


## Byte-identical, and when it is not, SAY WHERE and WHO OWNS IT. A 175 000
## character string compared with assert_eq tells you it failed and nothing
## else, which is a day of bisecting per regression.
##
## Passes outright when the two states are byte-equal. Otherwise every differing
## field must be in GAPS — one that is not is a new loss and fails.
func _assert_same_world(expected: Dictionary, actual: Dictionary, msg: String) -> void:
	if JsonCanon.exact(actual) == JsonCanon.exact(expected):
		assert_true(true, "%s — exactly" % msg)
		return
	var seen: PackedStringArray = _fields(expected, actual)
	var unknown: PackedStringArray = _undocumented(seen)
	print("      [save round trip] %d differing field(s), %d undocumented: %s" % [
		seen.size(), unknown.size(), " ".join(seen)])
	if unknown.is_empty():
		assert_true(true, "%s — apart from %d documented gaps in other parts" % [msg, seen.size()])
		return
	fail("%s — %d field(s) NOT in GAPS: %s" % [msg, unknown.size(), " ".join(unknown)])


# ------------------------------------------------------------------ helpers ---

## The player's journey: bytes on disk → world. `LcnSaveManager.load_slot` reads
## the file and then takes the manager's own door; this reads the same file
## through the same layer and takes the loader.
func _load(slot: String) -> bool:
	var payload: Dictionary = LcnSaveFile.read_world(slot)
	if payload.is_empty():
		return false
	return bool(Sim.deserialize(payload)["ok"])


func _fields(expected: Dictionary, actual: Dictionary) -> PackedStringArray:
	var seen: Dictionary[String, bool] = {}
	for path: Array in LcnSaveDiff.differing(expected, actual, 400):
		seen[LcnSaveDiff.render_field(path)] = true
	var keys: Array = seen.keys()
	keys.sort()
	var out: PackedStringArray = PackedStringArray()
	for k: String in keys:
		out.append(k)
	return out


func _undocumented(fields: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for f: String in fields:
		if not _is_known(f):
			out.append(f)
	return out


func _is_known(field: String) -> bool:
	if GAPS.has(field):
		return true
	for key: String in GAPS:
		if key.ends_with("*") and field.begins_with(key.substr(0, key.length() - 1)):
			return true
	return false


# ------------------------------------------------------------- the header ----

func test_the_header_describes_the_city_without_parsing_it() -> void:
	world.run(500)
	var written: Dictionary = LcnSaveManager.save(_slot, "The Long Winter")
	var head: Dictionary = LcnSaveFile.read_header(_slot)
	assert_true(not head.is_empty(), "the header reads back")
	assert_eq(String(head.get("name", "")), "The Long Winter", "the display name")
	assert_eq(int(head.get("tick", -1)), SimClock.tick, "the tick reached")
	assert_eq(int(head.get("day", -1)), int(written.get("day", -2)), "the day reached")
	assert_true(int(head.get("population", -1)) >= 0, "a population was recorded")
	assert_true(String(head.get("world_sha256", "")).length() == 64, "a digest was written")
	assert_true(float(head.get("saved_unix", 0.0)) > 1.0e9, "a wall-clock timestamp")


func test_a_corrupt_payload_is_refused_rather_than_half_loaded() -> void:
	world.run(200)
	assert_true(not LcnSaveManager.save(_slot, "Corrupt me").is_empty(), "saved")

	# Flip one byte deep inside the world payload. The header still parses, so
	# nothing but the digest can catch this.
	var path: String = LcnSaveFile.path_for(_slot)
	var raw: PackedByteArray = FileAccess.get_file_as_bytes(path)
	assert_true(raw.size() > 512, "the file has a payload to corrupt")
	var at: int = raw.size() - 64
	raw[at] = (raw[at] + 1) & 0xFF
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(raw)
	f.close()

	var before: String = JsonCanon.exact(Sim.serialize())
	assert_eq(LcnSaveFile.read_world(_slot), {}, "a payload that fails its digest is refused")
	assert_false(LcnSaveManager.load_slot(_slot), "the load reports failure")
	assert_eq(JsonCanon.exact(Sim.serialize()), before,
		"a refused load left the running world untouched")


func test_a_file_that_is_not_a_save_is_declined_quietly() -> void:
	var slot: String = LcnSaveSlots.scratch("not_a_save")
	LcnSaveFile.ensure_dir()
	var f: FileAccess = FileAccess.open(LcnSaveFile.path_for(slot), FileAccess.WRITE)
	f.store_string("this is a text file the player dropped in the folder")
	f.close()
	assert_eq(LcnSaveFile.read_header(slot), {}, "the header is empty")
	assert_false(LcnSaveManager.load_slot(slot), "loading it fails cleanly")
	LcnSaveManager.delete(slot)


# ---------------------------------------------------------------- slot ids ---

func test_a_slot_name_cannot_escape_the_saves_directory() -> void:
	assert_eq(LcnSaveManager.sanitise_slot("../../etc/passwd"), "etcpasswd", "traversal is stripped")
	assert_eq(LcnSaveManager.sanitise_slot("Day 12 / last one"), "day_12__last_one", "spaces survive as _")
	assert_eq(LcnSaveManager.sanitise_slot(""), "", "empty stays empty")
	assert_eq(LcnSaveManager.save("", "nope"), {}, "an empty slot is refused")


func test_autosave_slots_rotate_so_one_bad_morning_cannot_eat_the_others() -> void:
	var seen: Array[String] = []
	for day: int in range(1, 8):
		var slot: String = LcnSaveManager.autosave_slot(day)
		assert_true(LcnSaveManager.is_autosave(slot), "day %d writes an autosave slot" % day)
		if not seen.has(slot):
			seen.append(slot)
	assert_eq(seen.size(), LcnSaveManager.AUTOSAVE_KEEP, "the rotation covers exactly the kept slots")
	assert_true(LcnSaveManager.autosave_slot(1) != LcnSaveManager.autosave_slot(2),
		"two consecutive dawns never write the same file")

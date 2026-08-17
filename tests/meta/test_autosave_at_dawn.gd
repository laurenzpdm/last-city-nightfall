extends TestCase
## [P24] The autosave fires at dawn, and does not fire when it would do harm.
##
## Dawn rather than a wall-clock timer: a timer saves halfway through a wave,
## mid-placement, with three buildings on fire, and the save a player reaches for
## after a bad night is the one taken BEFORE it. `Bus.day_started` is the beat
## the simulation already has.
##
## What would make this go red: connecting to the wrong signal; saving on day 1
## (which [P09] emits during setup, before the city exists); one dawn overwriting
## the previous dawn; the autosave running inside a harness replay and touching
## the disk during a determinism run.

var world: SimFixture
var auto: LcnAutosave


## A TestCase is a RefCounted, not a Node: it has no get_tree(). The autosave is
## a Node and needs a real tree to run its _ready in.
func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["climate"])


## The autosave writes FIXED slot ids (`autosave_1..3`) and one test counts every
## autosave file on the machine. `user://saves/` is one directory per machine,
## not one per process, so four agents running the gate at once each rotated the
## same three files and the count came out anything but three. The lock makes
## them take turns; it is broken automatically if a killed process leaves it.
func before_all() -> void:
	LcnSaveSlots.hold("tests/meta autosave rotation")


func after_all() -> void:
	LcnSaveSlots.drop()


func setup() -> void:
	world = SimFixture.new(7).start()
	auto = LcnAutosave.new()
	_tree().root.add_child(auto)


func teardown() -> void:
	auto.queue_free()
	world.stop()
	for i: int in range(1, LcnSaveManager.AUTOSAVE_KEEP + 1):
		var _d: bool = LcnSaveManager.delete("%s_%d" % [LcnSaveManager.AUTOSAVE_PREFIX, i])


func test_a_dawn_writes_a_save() -> void:
	world.run(400)
	var before: int = auto.saves_written
	Bus.day_started.emit(2)
	assert_eq(auto.saves_written, before + 1, "the dawn of day 2 wrote a save")
	assert_true(LcnSaveManager.exists(auto.last_slot), "the file is on disk: %s" % auto.last_slot)
	var head: Dictionary = LcnSaveFile.read_header(auto.last_slot)
	assert_eq(String(head.get("name", "")), "Dawn of day 2", "and it is named after the morning")
	assert_true(bool(head.get("autosave", false)), "it is marked as an autosave")
	assert_eq(int(head.get("tick", -1)), SimClock.tick, "it holds the tick it was taken at")


func test_the_first_dawn_of_the_world_does_not_write_an_empty_city() -> void:
	# [P09] emits day_started(1) from inside setup(), before boot has placed a
	# single building. An autosave there writes an empty morning over the last
	# real one, which is the worst thing this file could do.
	var before: int = auto.saves_written
	Bus.day_started.emit(1)
	assert_eq(auto.saves_written, before, "day 1 is not autosaved")


func test_three_mornings_land_in_three_different_files() -> void:
	world.run(400)
	var written: Array[String] = []
	for day: int in [2, 3, 4]:
		world.run(300)
		Bus.day_started.emit(day)
		written.append(auto.last_slot)
	assert_eq(written.size(), 3, "three dawns")
	assert_eq(written[0] != written[1] and written[1] != written[2], true,
		"three consecutive dawns wrote three different files: %s" % str(written))
	for slot: String in written:
		assert_true(LcnSaveManager.exists(slot), "%s survived the next dawn" % slot)


func test_the_rotation_comes_back_round_rather_than_growing_forever() -> void:
	world.run(400)
	for day: int in range(2, 9):
		world.run(300)
		Bus.day_started.emit(day)
	var autosaves: int = 0
	for head: Dictionary in LcnSaveManager.slots():
		if bool(head.get("autosave", false)):
			autosaves += 1
	assert_eq(autosaves, LcnSaveManager.AUTOSAVE_KEEP,
		"seven mornings leave exactly %d autosave files" % LcnSaveManager.AUTOSAVE_KEEP)


func test_two_dawns_in_the_same_breath_only_write_once() -> void:
	world.run(400)
	var before: int = auto.saves_written
	Bus.day_started.emit(2)
	Bus.day_started.emit(3)
	assert_eq(auto.saves_written, before + 1,
		"a second day_started on the same tick is ignored — a re-emitted signal "
		+ "must not cost a 300 kB write")


func test_an_autosave_can_be_loaded_back() -> void:
	world.run(500)
	Bus.day_started.emit(2)
	var slot: String = auto.last_slot
	var saved: Dictionary = Sim.serialize()
	world.stop()
	world = SimFixture.new(31).start()
	assert_true(LcnSaveManager.load_slot(slot), "the autosave loads")
	assert_eq(int(saved.get("tick", -1)), SimClock.tick, "back at the morning it was taken")


func test_it_is_switched_off_inside_a_harness_replay() -> void:
	# The determinism replay must not touch the disk, and a 300 kB write every
	# in-world day would show up in the tick budget as a mystery.
	assert_false(Harness.active, "this suite is not itself a harness run")
	var was: bool = Harness.active
	Harness.active = true
	var guarded := LcnAutosave.new()
	_tree().root.add_child(guarded)
	assert_false(guarded.enabled, "the autosave stood down for the harness")
	var before: int = guarded.saves_written
	Bus.day_started.emit(5)
	assert_eq(guarded.saves_written, before, "and it wrote nothing")
	guarded.queue_free()
	Harness.active = was

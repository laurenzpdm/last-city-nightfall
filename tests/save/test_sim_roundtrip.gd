extends TestCase
## Does the SIMULATION come back? Not "does a file get written" — does the world
## that comes out of `Sim.deserialize()` equal the world that went into
## `Sim.serialize()`, field for field.
##
## ARCHITECTURE.md §0.4 calls determinism non-negotiable, and a save is the one
## place a player leaves the simulation and comes back to it. A reload that lands
## somewhere else is the same defect as a `randf()` in a step function, only
## slower to notice. So this suite is not allowed a gap list it can grow: every
## field that does not come back is named here with the part that owns it, the
## file it is in, and the reason — and two of the four are DISPROVED as excuses
## by [method test_putting_back_what_the_file_never_carried_closes_both_of_them],
## which puts that state back by hand and demands the difference go to zero.
##
## What would make this suite go red, and each has been run against this build:
##   * deleting the reconciler pass from `Sim.deserialize()` — 40 fields, FAIL
##   * `_is_improvement()` returning true unconditionally — the search keeps
##     wrong guesses, unrelated fields break, FAIL
##   * removing `LcnStateReconciler._congruent()` — the narrative queue is
##     refilled with six-key projections of eleven-key cards; this suite's
##     [method test_a_repair_may_never_hand_a_system_a_shape_it_cannot_read] goes
##     red and the next `_push()` after a load dies on `'priority'`

const TICKS: int = 600

## The fields that do not come back, each with its owner, its file and its fix —
## written down once, in `tests/save/save_gaps.gd`, and read by both round-trip
## suites. A SUBSET assertion, never an allowlist: a divergence that is not on
## the list fails this suite, and the suite prints everything it saw, so the list
## can only shrink by being fixed.
const GAPS: Dictionary[String, String] = LcnSaveGapProbe.GAPS


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["climate", "grid"])


func _fresh(world_seed: int) -> SimFixture:
	return SimFixture.new(world_seed).start()


# ------------------------------------------------------------- the contract --

func test_a_world_reloaded_is_the_world_that_was_saved() -> void:
	var world: SimFixture = _fresh(7)
	world.run(TICKS)
	var saved: Dictionary = Sim.serialize()

	# Throw it away for a world built on a different seed, so nothing can come
	# back by coincidence, then rebuild from the payload alone.
	world.stop()
	world = _fresh(999)
	world.run(120)

	var report: Dictionary = Sim.deserialize(saved)
	assert_true(bool(report["ok"]), "the payload was accepted")
	var unknown: PackedStringArray = _unknown(LcnSaveDiff.differing(saved, Sim.serialize(), 400))
	assert_eq(" ".join(unknown), "",
		"every field came back except the %d documented ones — %d repaired by the reconciler" % [
			GAPS.size(), (report["repaired"] as PackedStringArray).size()])
	var told: PackedStringArray = PackedStringArray()
	for field: String in (report["unrestored"] as PackedStringArray):
		if not _is_known(field):
			told.append(field)
	assert_eq(" ".join(told), "",
		"and the load says so itself rather than logging a clean bill of health")
	world.stop()


func test_putting_back_what_the_file_never_carried_closes_both_of_them() -> void:
	# The question a gap list always leaves open is whether it is really all of
	# it. This settles it: lift [P06]'s standing forces and [P08]'s approach
	# paths out of the live world, load the save into a fresh one, put ONLY
	# those back, and demand the difference between the two states disappear.
	# If anything else were quietly lost, this comparison would still fail and
	# would name it.
	var world: SimFixture = _fresh(7)
	world.run(TICKS)
	var held: Dictionary = LcnSaveGapProbe.capture()
	var saved: Dictionary = Sim.serialize()
	world.stop()

	world = _fresh(999)
	world.run(120)
	assert_true(bool(Sim.deserialize(saved)["ok"]), "the payload was accepted")
	var before: PackedStringArray = _named(LcnSaveDiff.differing(saved, Sim.serialize(), 400))
	assert_true(before.has("$.systems.society.forces"), "society's forces are missing to begin with")
	assert_true(before.has("$.systems.threat.plan.vectors[].cells"),
		"and so is the approach path — %s" % " ".join(before))

	var put: PackedStringArray = LcnSaveGapProbe.reinject(held)
	assert_true(put.size() >= 2, "the probe actually wrote something: %s" % " ".join(put))
	var after: PackedStringArray = _named(LcnSaveDiff.differing(saved, Sim.serialize(), 400))
	assert_false(after.has("$.systems.society.forces"),
		"putting the forces back closes that gap outright")
	assert_false(after.has("$.systems.threat.plan.vectors[].cells"),
		"and so does putting the approach path back")
	world.stop()


func test_the_clock_the_seed_and_every_rng_stream_come_back() -> void:
	var world: SimFixture = _fresh(11)
	world.run(TICKS)
	var tick: int = SimClock.tick
	var seed_value: int = Rng.seed_value
	var streams: Dictionary = Rng.snapshot()
	assert_true(streams.size() >= 1, "the run drew on %d stream(s)" % streams.size())
	var saved: Dictionary = Sim.serialize()

	world.stop()
	world = _fresh(41)
	world.run(50)
	assert_true(bool(Sim.deserialize(saved)["ok"]), "the payload was accepted")

	assert_eq(SimClock.tick, tick, "the tick counter")
	assert_eq(Rng.seed_value, seed_value, "the world seed")
	var after: Dictionary = Rng.snapshot()
	var names: Array = streams.keys()
	names.sort()
	for n: String in names:
		assert_eq(int(after.get(n, -1)), int(streams[n]),
			"stream '%s' is back on the exact draw it was on" % n)
	world.stop()


func test_serializing_the_world_does_not_draw_a_random_number() -> void:
	# `Sim.deserialize()` puts the RNG streams back LAST, after the reconciler,
	# because the reconciler calls `sys.serialize()` dozens of times per load and
	# a stream walked by those calls would come back off by that many draws.
	#
	# Moving `Rng.restore()` earlier turns NOTHING red on this build, and the
	# reason is worth pinning down rather than leaving as a comment somebody has
	# to trust: no `serialize()` in this build draws. That is the invariant the
	# ordering is insurance for, so it is the invariant that gets a test — if a
	# part ever reaches for `Rng.stream(...)` while describing itself, this names
	# the stream instead of a save silently coming back a few draws along.
	var world: SimFixture = _fresh(29)
	world.run(200)
	var before: Dictionary = Rng.snapshot()
	assert_true(before.size() >= 1, "the run drew on %d stream(s)" % before.size())
	for _i: int in 5:
		var _s: Dictionary = Sim.serialize()
	assert_eq(JsonCanon.canon(Rng.snapshot()), JsonCanon.canon(before),
		"five full serializations later, every stream is on the same draw")
	world.stop()


func test_a_load_is_idempotent() -> void:
	# Loading the same payload into a world that is already that world must be a
	# no-op. It is the one exactness claim in this suite that no rounding can
	# soften, and it fails the moment a deserialize() or a repair depends on
	# what the world happened to hold before it ran.
	var world: SimFixture = _fresh(13)
	world.run(TICKS)
	var saved: Dictionary = Sim.serialize()
	world.stop()

	world = _fresh(999)
	world.run(60)
	assert_true(bool(Sim.deserialize(saved)["ok"]), "first load")
	var once: String = JsonCanon.exact(Sim.serialize())
	assert_true(bool(Sim.deserialize(saved)["ok"]), "second load of the same payload")
	assert_eq(JsonCanon.exact(Sim.serialize()), once, "the second load changed nothing")
	world.stop()


func test_the_first_tick_after_a_load_moves_by_no_more_than_the_file_rounded_away() -> void:
	# THE HONEST CEILING ON ALL OF THIS, and it is not a gap anybody can close in
	# game/sim/save/: `Sim.serialize()` is a REPORT before it is a save format.
	# Every part snaps its floats on the way out (`snappedf(hope_value, 0.001)`,
	# morale to 0.01), so a load starts from values that are up to half a grain
	# away from the ones the running city had, and an integrator turns that into
	# a visible difference over a night.
	#
	# What this test pins down is that the difference is ONLY that: one tick
	# after a load, no number has moved further than the file's own coarsest
	# grain. A system that diverged for a behavioural reason — a missing cache, a
	# stale neighbour, an RNG stream off by a draw — moves much further than
	# 0.01 in one tick, and this goes red with the field named.
	const GRAIN: float = 0.01
	var world: SimFixture = _fresh(23)
	world.run(400)
	var held: Dictionary = LcnSaveGapProbe.capture()
	var saved: Dictionary = Sim.serialize()
	world.run(1)
	var straight: Dictionary = Sim.serialize()
	world.stop()

	world = _fresh(123)
	world.run(80)
	assert_true(bool(Sim.deserialize(saved)["ok"]), "the payload was accepted")
	# The two gaps whose data the file never carried are put back by hand, so
	# what is measured below is the rounding and nothing else.
	var _put: PackedStringArray = LcnSaveGapProbe.reinject(held)
	world.run(1)

	var loud: PackedStringArray = PackedStringArray()
	for path: Array in LcnSaveDiff.differing(straight, Sim.serialize(), 400):
		var field: String = LcnSaveDiff.render_field(path)
		if _is_known(field):
			continue
		var a: Variant = LcnSaveDiff.at(straight, path)
		var b: Variant = LcnSaveDiff.at(Sim.serialize(), path)
		if (a is float or a is int) and (b is float or b is int) \
				and absf(float(a) - float(b)) <= GRAIN:
			continue
		loud.append("%s (%s vs %s)" % [LcnSaveDiff.render(path), a, b])
	assert_eq(" ".join(loud), "",
		"one tick after a load, nothing has moved further than the %.3f the file rounded away" % GRAIN)
	world.stop()


# ------------------------------------------------------------- the mechanism --

func test_the_reconciler_is_doing_the_work_and_not_the_deserializers() -> void:
	# A guard against the day somebody deletes the reconciler pass because "the
	# tests pass anyway". They pass BECAUSE of it: this asserts it repairs a
	# non-trivial number of fields, so removing it cannot be silent.
	var world: SimFixture = _fresh(7)
	world.run(TICKS)
	var saved: Dictionary = Sim.serialize()
	world.stop()
	world = _fresh(999)
	world.run(120)
	var report: Dictionary = Sim.deserialize(saved)
	var repaired: PackedStringArray = report["repaired"]
	assert_true(repaired.size() >= 8,
		"the reconciler put back %d field(s) the systems' own deserialize() dropped: %s" % [
			repaired.size(), " ".join(repaired)])
	world.stop()


func test_a_repair_may_never_hand_a_system_a_shape_it_cannot_read() -> void:
	# THE BUG THIS RULE WAS WRITTEN FOR, kept as a unit test because the failure
	# it prevents is silent in every other suite: `serialize()` is very often a
	# PROJECTION. NarrativeSystem writes six keys of a pending card and the live
	# card carries eleven. A repair verified only by re-serializing accepts the
	# projection — the field goes green — and the next `_push()` after the load
	# dies on `Invalid access to property or key 'priority'`.
	assert_false(LcnStateReconciler._congruent(
			{"id": "x", "priority": 3, "seq": 1}, {"id": "x", "seq": 1}),
		"a record that would lose a key is refused")
	assert_true(LcnStateReconciler._congruent(
			{"id": "x", "priority": 3}, {"id": "x", "priority": 9}),
		"the same record with a different value is fine — that is what a repair IS")
	assert_true(LcnStateReconciler._congruent({}, {"cold": 0.1, "wave": 0.2}),
		"a table the load left empty has no key to lose, so it comes back")
	assert_false(LcnStateReconciler._congruent([], [{"id": "x"}]),
		"a list of records cannot be built against elements that are not there")
	assert_true(LcnStateReconciler._congruent([], [1.0, 2.0, 3.0]),
		"a list of numbers cannot be a projection of itself, so it can")
	assert_false(LcnStateReconciler._congruent({"a": {"deep": 1, "keep": 2}}, {"a": {"deep": 1}}),
		"and the rule reaches all the way down")


func test_a_loaded_city_keeps_running_at_all() -> void:
	# Two hundred ticks past the load, and the point is not the assertions at the
	# bottom — it is that the engine gets to raise. A repair that hands a system
	# a shape it cannot read does not fail a comparison; it fails the NEXT thing
	# that touches the value, which is why the narrative queue's projection bug
	# survived every round-trip assertion in this file and only showed up as
	# `Invalid access to property or key 'priority'` on tick 401. Nothing here
	# counts engine errors — `tools/scan_errors.py` reads this suite's log and
	# does, and it can only do that if something actually runs after a load.
	var world: SimFixture = _fresh(23)
	world.run(400)
	var saved: Dictionary = Sim.serialize()
	world.stop()

	world = _fresh(999)
	world.run(60)
	assert_true(bool(Sim.deserialize(saved)["ok"]), "loaded")
	var at: int = SimClock.tick
	world.run(200)
	assert_eq(SimClock.tick, at + 200, "and ran on for two hundred ticks")
	assert_true(Sim.alive, "with a world still standing at the end of them")
	world.stop()


func test_a_payload_with_no_systems_block_is_refused_without_touching_the_world() -> void:
	var world: SimFixture = _fresh(7)
	world.run(100)
	var before: String = JsonCanon.exact(Sim.serialize())
	var report: Dictionary = Sim.deserialize({"tick": 5, "seed": 2})
	assert_false(bool(report["ok"]), "a payload with no systems is refused")
	assert_eq(JsonCanon.exact(Sim.serialize()), before, "the running world was left alone")
	world.stop()


func test_a_save_naming_a_system_this_build_lacks_is_named_not_swallowed() -> void:
	var world: SimFixture = _fresh(7)
	world.run(100)
	var saved: Dictionary = Sim.serialize()
	(saved["systems"] as Dictionary)["orbital_mirror"] = {"panels": 3}
	var report: Dictionary = Sim.deserialize(saved)
	assert_true(bool(report["ok"]), "the rest of the city still loads")
	assert_eq(_join(report["absent"]), "orbital_mirror",
		"the missing pillar is named in the report")
	world.stop()


func test_the_bytes_on_disk_are_the_same_world_too() -> void:
	# The whole journey a player actually makes: memory → file → memory. This
	# uses [P24]'s file layer read-only, so a change to the container (digest,
	# compression, a format bump) is caught here as well as in tests/meta.
	var slot: String = LcnSaveSlots.scratch("sim_roundtrip")
	LcnSaveSlots.hold("tests/save disk round trip")
	var world: SimFixture = _fresh(5)
	world.run(TICKS)
	var saved: Dictionary = Sim.serialize()
	assert_true(not LcnSaveManager.save(slot, "Through the disk").is_empty(), "written")

	world.stop()
	world = _fresh(777)
	world.run(60)

	var from_disk: Dictionary = LcnSaveFile.read_world(slot)
	assert_true(not from_disk.is_empty(), "the file read back")
	assert_true(bool(Sim.deserialize(from_disk)["ok"]), "and rebuilt the world")
	assert_eq(" ".join(_unknown(LcnSaveDiff.differing(saved, Sim.serialize(), 400))), "",
		"the city that came off the disk is the city that went on")
	LcnSaveManager.delete(slot)
	LcnSaveSlots.drop()
	world.stop()


# ------------------------------------------------------------------ helpers --

## Every differing FIELD, array indices collapsed, sorted.
func _named(diff: Array) -> PackedStringArray:
	var seen: Dictionary[String, bool] = {}
	for path: Array in diff:
		seen[LcnSaveDiff.render_field(path)] = true
	var keys: Array = seen.keys()
	keys.sort()
	var out: PackedStringArray = PackedStringArray()
	for k: String in keys:
		out.append(k)
	return out


## The differing fields that are NOT documented in GAPS. Prints the whole list
## either way: a residue nobody can read is a residue nobody can fix.
func _unknown(diff: Array) -> PackedStringArray:
	var all: PackedStringArray = _named(diff)
	var out: PackedStringArray = PackedStringArray()
	for field: String in all:
		if not _is_known(field):
			out.append(field)
	if not all.is_empty():
		print("      [sim round trip] %d field(s) differ, %d undocumented: %s" % [
			all.size(), out.size(), " ".join(all)])
	return out


func _is_known(field: String) -> bool:
	if GAPS.has(field):
		return true
	for key: String in GAPS:
		if key.ends_with("*") and field.begins_with(key.substr(0, key.length() - 1)):
			return true
	return false


func _join(v: Variant) -> String:
	return " ".join(v as PackedStringArray)

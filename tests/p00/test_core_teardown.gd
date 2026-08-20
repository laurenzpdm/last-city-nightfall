extends TestCase
## Destroying a world actually destroys it.
##
## `Sim.teardown()` used to clear two arrays and call it done. It was not done:
## every sim system holds its neighbours — heat points at build, build points at
## citizens, citizens point back at heat, and their helper objects hold systems
## too — so the eleven of them form a reference ring, and a ring of RefCounted in
## a language with no cycle collector never dies. Measured in one process, three
## worlds built and torn down: 2030 objects at rest, then 2287 · 2471 · 2655 after
## each teardown. Every world ever created, still resident, still holding a share
## of the content registry. At exit that read as 812 leaked ObjectDB instances and
## 256 resources still in use, both allowlisted in tools/error_allowlist.txt with
## an expiry nobody had met.
##
## This suite is the reason it cannot come back. It lives in tests/p00/ for the
## reason test_core_contracts.gd gives: nobody owns game/core/ except the
## integrator, so its guarantees need a guard that belongs to no part.
##
## The sharp assertion is the weak reference one. An object count is a
## measurement and can be argued with; `weakref(system).get_ref() == null` after
## teardown is the claim itself — the old world is GONE — and it goes red the
## moment the cycle-breaking in `Sim._release_world` is removed.

var world: SimFixture = null


func setup() -> void:
	world = SimFixture.new(4242).start()
	if not world.alive():
		skip("the world did not come up in this build")


func teardown() -> void:
	if world != null:
		world.stop()


func test_teardown_actually_frees_every_system() -> void:
	var sim: Node = TestEnv.sim()
	var names: PackedStringArray = world.system_names()
	assert_gt(float(names.size()), 3.0, "there are systems in this build to free")

	# Weak references only. One strong reference held here would keep the very
	# object under test alive and turn this suite into the kind that cannot fail.
	var watchers: Array[WeakRef] = []
	var watched: PackedStringArray = PackedStringArray()
	for n: String in names:
		var s: SimSystem = world.system(StringName(n))
		if s == null:
			continue
		watchers.append(weakref(s))
		watched.append(n)
		s = null

	world.run(20)
	sim.call("teardown")

	var survivors: PackedStringArray = PackedStringArray()
	for i: int in watchers.size():
		if watchers[i].get_ref() != null:
			survivors.append(watched[i])
	assert_eq(survivors.size(), 0,
		"every system is freed by teardown; still alive: %s" % ", ".join(survivors))


func test_building_a_world_over_and_over_does_not_grow_the_process() -> void:
	var sim: Node = TestEnv.sim()
	var clock: Node = TestEnv.clock()
	sim.call("teardown")

	# One warm-up cycle first: the very first world loads scripts and content the
	# process then keeps on purpose, and counting that as a leak would be wrong.
	sim.call("create_world", 4242)
	clock.call("advance", 10)
	sim.call("teardown")
	var settled: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))

	for i: int in 3:
		sim.call("create_world", 4242)
		clock.call("advance", 10)
		sim.call("teardown")
	var after: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))

	var growth: int = after - settled
	print("    [core] three more worlds built and destroyed: %+d objects (%d -> %d)"
		% [growth, settled, after])
	# Three uncollected worlds were +550 objects. A handful either way is the
	# test framework's own churn, not a world that refused to die.
	assert_lt(float(growth), 100.0,
		"three build/destroy cycles leave the process where they found it, not %+d objects heavier"
			% growth)


func test_a_torn_down_world_is_not_still_wired_to_its_neighbours() -> void:
	var sim: Node = TestEnv.sim()
	var citizens: SimSystem = world.system(&"citizens")
	var heat: SimSystem = world.system(&"heat")
	if citizens == null or heat == null:
		skip("this build has no citizens or no heat")
	var watch_heat: WeakRef = weakref(heat)
	heat = null

	sim.call("teardown")
	# citizens is still held HERE, on purpose: it is the one strong reference left
	# in the process. If teardown left its neighbour pointers intact, that single
	# reference would keep heat — and through heat the rest of the ring — alive.
	assert_true(watch_heat.get_ref() == null,
		"a reference to one system does not keep the whole world resident")
	assert_not_null(citizens, "and the system the caller still holds is untouched")

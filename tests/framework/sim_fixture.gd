class_name SimFixture
extends RefCounted
## A deterministic world in a box.
##
## Sim, SimClock and Rng are autoloads, which means they are global state that
## outlives a test. Every suite should go through a fixture so no test can ever
## inherit the world the previous test left behind.
##
##     var world: SimFixture
##     func setup() -> void:  world = SimFixture.new(7).start()
##     func teardown() -> void: world.stop()
##     func test_x() -> void:  world.cmd({...}).run(200)

var seed_value: int = 7

var _sim: Node = null
var _clock: Node = null
var _started: bool = false


func _init(world_seed: int = 7) -> void:
	seed_value = world_seed


## Creates a fresh world and puts the clock in manual mode. Chainable.
func start() -> SimFixture:
	_sim = TestEnv.sim()
	_clock = TestEnv.clock()
	if _sim == null or _clock == null:
		return self
	_clock.call("set_manual", true)
	_sim.call("create_world", seed_value)
	_started = true
	return self


## Tears the world down. Safe to call twice, safe to call after a failed start.
func stop() -> void:
	if _sim != null and _started:
		_sim.call("teardown")
	if _clock != null:
		_clock.call("reset")
	_started = false


## Throws the current world away and creates a clean one on the same seed.
## Creating a world is expensive (worldgen), so a suite that only reads should
## build one in before_all() and call this from the handful of tests that need
## a pristine tick counter or a pristine Rng.
func restart() -> SimFixture:
	stop()
	return start()


## Restarts only if something else destroyed or reseeded the world. Cheap when
## nothing happened, correct when the previous test did something rude — which
## is what makes a shared world safe to use from setup().
func ensure() -> SimFixture:
	if not alive():
		return start()
	var rng: Node = TestEnv.rng()
	if rng != null and int(rng.get("seed_value")) != seed_value:
		return restart()
	return self


func alive() -> bool:
	return _started and _sim != null and bool(_sim.get("alive"))


## Advance exactly n simulation ticks. Chainable.
func run(ticks: int) -> SimFixture:
	if _clock != null and ticks > 0:
		_clock.call("advance", ticks)
	return self


## Advance whole in-world seconds (20 ticks each). Chainable.
func run_seconds(seconds: float) -> SimFixture:
	return run(int(round(seconds * 20.0)))


## Queue a command exactly as view/ and ui/ would. Applied next tick. Chainable.
func cmd(command: Dictionary) -> SimFixture:
	if _sim != null:
		_sim.call("submit_command", command)
	return self


## Queue a command and immediately tick so its effect is visible. Chainable.
func cmd_now(command: Dictionary) -> SimFixture:
	return cmd(command).run(1)


func tick() -> int:
	return 0 if _clock == null else int(_clock.get("tick"))


func seconds() -> float:
	return 0.0 if _clock == null else float(_clock.call("seconds"))


func system(n: StringName) -> SimSystem:
	if _sim == null:
		return null
	return _sim.call("get_system", n) as SimSystem


func has_system(n: StringName) -> bool:
	return system(n) != null


func system_names() -> PackedStringArray:
	return TestEnv.system_names()


func state() -> Dictionary:
	if _sim == null:
		return {}
	return _sim.call("serialize")


func metrics() -> Dictionary:
	if _sim == null:
		return {}
	return _sim.call("collect_metrics")


func metric(key: String, fallback: float = 0.0) -> float:
	var m: Dictionary = metrics()
	if not m.has(key):
		return fallback
	return float(m[key])


## Canonical text of the whole world. Two equal strings mean two equal worlds.
func canon() -> String:
	return JsonCanon.canon(state())


func state_hash() -> String:
	return JsonCanon.hash_of(state())


## Signals emitted by Bus while `action` runs, as {signal_name: count}.
func count_bus_signals(names: PackedStringArray, action: Callable) -> Dictionary:
	var bus: Node = TestEnv.bus()
	var counts: Dictionary = {}
	if bus == null:
		return counts
	var probes: Array = []
	for n: String in names:
		counts[n] = 0
		if not bus.has_signal(n):
			continue
		var arity: int = _signal_arity(bus, StringName(n))
		if arity < 0 or arity > 5:
			continue
		var probe: TestCase._SignalProbe = TestCase._SignalProbe.new()
		var cb: Callable = Callable(probe, "h%d" % arity)
		bus.connect(n, cb)
		probes.append({"name": n, "probe": probe, "cb": cb})
	action.call()
	for entry: Dictionary in probes:
		var p: TestCase._SignalProbe = entry["probe"]
		counts[String(entry["name"])] = p.count
		bus.disconnect(String(entry["name"]), entry["cb"])
	return counts


# --- determinism helpers -----------------------------------------------------

## Runs the same seed and the same command script twice from scratch and returns
## every state divergence. An empty result is the whole point of this project.
##
## `script_by_tick` maps tick -> Array[Dictionary] of commands, the same shape
## the harness builds from a scenario file.
static func replay_diff(world_seed: int, ticks: int, script_by_tick: Dictionary = {}, limit: int = 20) -> PackedStringArray:
	var a: Dictionary = replay(world_seed, ticks, script_by_tick)
	var b: Dictionary = replay(world_seed, ticks, script_by_tick)
	# An empty diff is the project's hardest claim, so it must never be reachable
	# by producing nothing. If the world failed to start, both replays are {} and
	# every assert_empty(diff) downstream would go green on a broken build.
	if a.is_empty() or b.is_empty():
		return PackedStringArray([
			"replay produced no state at all — the world failed to start, so this "
			+ "run proves nothing about determinism"])
	if not a.has("systems") or (a["systems"] as Dictionary).is_empty():
		return PackedStringArray(["replay produced a world with no systems in it"])
	return JsonCanon.diff(a, b, PackedStringArray(), limit)


## One scripted run, returned as serialized state. Leaves no world behind.
static func replay(world_seed: int, ticks: int, script_by_tick: Dictionary = {}) -> Dictionary:
	var fx: SimFixture = SimFixture.new(world_seed).start()
	if not fx.alive():
		fx.stop()
		return {}
	var keys: Array = script_by_tick.keys()
	keys.sort()
	var next: int = 0
	for t: int in range(1, ticks + 1):
		while next < keys.size() and int(keys[next]) == t:
			for c: Variant in script_by_tick[keys[next]]:
				fx.cmd(c as Dictionary)
			next += 1
		fx.run(1)
	var out: Dictionary = fx.state()
	fx.stop()
	return out


func _signal_arity(emitter: Object, signal_name: StringName) -> int:
	for s: Dictionary in emitter.get_signal_list():
		if StringName(s.get("name", "")) == signal_name:
			var args: Array = s.get("args", [])
			return args.size()
	return -1

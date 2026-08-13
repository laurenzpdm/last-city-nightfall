class_name TestCase
extends RefCounted
## Base class for every test suite in this repo. Dependency-free on purpose:
## no GUT, no gdUnit4, nothing to install, nothing to keep in sync with Godot.
##
## Write a suite as `tests/<part>/test_<thing>.gd`:
##
##     extends TestCase
##
##     var world: SimFixture
##
##     func requires_systems() -> PackedStringArray:
##         return PackedStringArray(["heat"])          # skip until [P02] lands
##
##     func setup() -> void:
##         world = SimFixture.new(7).start()
##
##     func teardown() -> void:
##         world.stop()
##
##     func test_heat_reaches_the_far_end() -> void:
##         world.run(200)
##         assert_near(world.metrics()["heat.total"], 480.0, 0.5, "steady state")
##
## Every method named `test_*` with no arguments is a test. They run in sorted
## order so a suite behaves the same on every machine.
##
## Assertions never abort the test — they record and continue, so one run tells
## you everything that is wrong instead of only the first thing.

const FRAMEWORK_DIR: String = "res://tests/framework/"
const DEFAULT_EPSILON: float = 1.0e-6

## --- runner protocol. Prefixed so a suite's own fields can never collide. ---
var _lcn_failures: Array[Dictionary] = []
var _lcn_asserts: int = 0
var _lcn_test: String = ""
var _lcn_skip: String = ""
var _lcn_suite_path: String = ""


# --- overridables ------------------------------------------------------------

## Display name for the suite. Defaults to the file name.
func suite_name() -> String:
	if _lcn_suite_path == "":
		return "suite"
	return _lcn_suite_path.get_file().get_basename()


## Sim system names this suite needs. If any is absent the whole suite is
## skipped instead of failing — twenty parts are built in parallel and a test
## must never go red because its dependency has not landed yet.
func requires_systems() -> PackedStringArray:
	return PackedStringArray()


## res:// paths this suite needs. Same skip-not-fail contract as above.
func requires_files() -> PackedStringArray:
	return PackedStringArray()


## Once per suite, before the first test.
func before_all() -> void:
	pass


## Once per suite, after the last test. Runs even if tests failed.
func after_all() -> void:
	pass


## Before every test method.
func setup() -> void:
	pass


## After every test method. Runs even if the test failed or skipped.
func teardown() -> void:
	pass


# --- assertions --------------------------------------------------------------

## Deep structural equality. Key order is irrelevant; 3 and 3.0 are equal.
func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	var a: String = JsonCanon.canon(actual)
	var e: String = JsonCanon.canon(expected)
	if a == e:
		return true
	# Dumping two 40 KB state blobs into the console helps nobody. When both
	# sides are containers, report the paths that differ instead.
	if _lcn_is_container(actual) and _lcn_is_container(expected):
		var d: PackedStringArray = JsonCanon.diff(expected, actual, PackedStringArray(), 8)
		if not d.is_empty():
			return _lcn_fail("assert_eq", msg, "no difference",
				"%d difference(s):\n      %s" % [d.size(), "\n      ".join(d)])
	return _lcn_fail("assert_eq", msg, JsonCanon.preview(expected), JsonCanon.preview(actual))


func assert_ne(actual: Variant, forbidden: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if JsonCanon.canon(actual) != JsonCanon.canon(forbidden):
		return true
	return _lcn_fail("assert_ne", msg, "anything but " + JsonCanon.preview(forbidden), JsonCanon.preview(actual))


func assert_true(value: bool, msg: String = "") -> bool:
	_lcn_asserts += 1
	if value:
		return true
	return _lcn_fail("assert_true", msg, "true", "false")


func assert_false(value: bool, msg: String = "") -> bool:
	_lcn_asserts += 1
	if not value:
		return true
	return _lcn_fail("assert_false", msg, "false", "true")


func assert_null(value: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if value == null:
		return true
	return _lcn_fail("assert_null", msg, "null", JsonCanon.preview(value))


func assert_not_null(value: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if value != null:
		return true
	return _lcn_fail("assert_not_null", msg, "a value", "null")


## Float comparison with an explicit tolerance. Use this for anything the sim
## integrates over time; exact float equality across builds is a trap.
func assert_near(actual: float, expected: float, epsilon: float = DEFAULT_EPSILON, msg: String = "") -> bool:
	_lcn_asserts += 1
	if is_nan(actual) or is_nan(expected):
		return _lcn_fail("assert_near", msg, JsonCanon.num(expected), JsonCanon.num(actual))
	if absf(actual - expected) <= epsilon:
		return true
	return _lcn_fail("assert_near", msg,
		"%s ± %s" % [JsonCanon.num(expected), JsonCanon.num(epsilon)],
		"%s  (off by %s)" % [JsonCanon.num(actual), JsonCanon.num(absf(actual - expected))])


func assert_gt(actual: float, bound: float, msg: String = "") -> bool:
	_lcn_asserts += 1
	if actual > bound:
		return true
	return _lcn_fail("assert_gt", msg, "> " + JsonCanon.num(bound), JsonCanon.num(actual))


func assert_ge(actual: float, bound: float, msg: String = "") -> bool:
	_lcn_asserts += 1
	if actual >= bound:
		return true
	return _lcn_fail("assert_ge", msg, ">= " + JsonCanon.num(bound), JsonCanon.num(actual))


func assert_lt(actual: float, bound: float, msg: String = "") -> bool:
	_lcn_asserts += 1
	if actual < bound:
		return true
	return _lcn_fail("assert_lt", msg, "< " + JsonCanon.num(bound), JsonCanon.num(actual))


func assert_le(actual: float, bound: float, msg: String = "") -> bool:
	_lcn_asserts += 1
	if actual <= bound:
		return true
	return _lcn_fail("assert_le", msg, "<= " + JsonCanon.num(bound), JsonCanon.num(actual))


func assert_between(actual: float, low: float, high: float, msg: String = "") -> bool:
	_lcn_asserts += 1
	if actual >= low and actual <= high:
		return true
	return _lcn_fail("assert_between", msg,
		"%s .. %s" % [JsonCanon.num(low), JsonCanon.num(high)], JsonCanon.num(actual))


## Membership. Works for Dictionary keys, Array elements and String substrings.
func assert_has(container: Variant, item: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if _lcn_contains(container, item):
		return true
	return _lcn_fail("assert_has", msg,
		"container holding " + JsonCanon.preview(item), JsonCanon.preview(container))


func assert_has_not(container: Variant, item: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if not _lcn_contains(container, item):
		return true
	return _lcn_fail("assert_has_not", msg,
		"container without " + JsonCanon.preview(item), JsonCanon.preview(container))


func assert_size(container: Variant, expected: int, msg: String = "") -> bool:
	_lcn_asserts += 1
	var n: int = _lcn_size(container)
	if n == expected:
		return true
	return _lcn_fail("assert_size", msg, str(expected), "%d  in %s" % [n, JsonCanon.preview(container, 120)])


func assert_empty(container: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if _lcn_size(container) == 0:
		return true
	return _lcn_fail("assert_empty", msg, "empty", JsonCanon.preview(container))


func assert_not_empty(container: Variant, msg: String = "") -> bool:
	_lcn_asserts += 1
	if _lcn_size(container) > 0:
		return true
	return _lcn_fail("assert_not_empty", msg, "at least one entry", "empty")


## The operation must report a failure through the project's error channel.
##
## GDScript cannot catch engine errors, so "throws" here means the code under
## test emitted `Log.error(...)` — which is exactly how every system in this
## repo signals a rejected operation. `expect` is matched as a substring.
func assert_throws(action: Callable, expect: String = "", msg: String = "") -> bool:
	_lcn_asserts += 1
	var errors: PackedStringArray = _lcn_errors_from(action)
	if errors.is_empty():
		return _lcn_fail("assert_throws", msg,
			"a logged ERROR" + ("" if expect == "" else " containing '%s'" % expect),
			"the operation completed without reporting an error")
	if expect == "":
		return true
	for line: String in errors:
		if line.contains(expect):
			return true
	return _lcn_fail("assert_throws", msg,
		"a logged ERROR containing '%s'" % expect, "\n      ".join(errors))


## The operation must NOT report an error. Use it to prove a happy path is quiet.
func assert_no_errors(action: Callable, msg: String = "") -> bool:
	_lcn_asserts += 1
	var errors: PackedStringArray = _lcn_errors_from(action)
	if errors.is_empty():
		return true
	return _lcn_fail("assert_no_errors", msg, "no logged ERROR", "\n      ".join(errors))


## `produce` must return byte-identical data every time it is called.
## This is the assertion that guards the project's single hardest rule.
func assert_deterministic(produce: Callable, msg: String = "", runs: int = 2) -> bool:
	_lcn_asserts += 1
	if runs < 2:
		runs = 2
	var first: Variant = produce.call()
	for i: int in range(1, runs):
		var again: Variant = produce.call()
		var d: PackedStringArray = JsonCanon.diff(first, again, PackedStringArray(), 6)
		if not d.is_empty():
			return _lcn_fail("assert_deterministic", msg,
				"run 1 == run %d" % (i + 1),
				"diverged at %d path(s):\n      %s" % [d.size(), "\n      ".join(d)])
	return true


## `action` must emit `signal_name` on `emitter` at least `times` times.
func assert_signal_emitted(emitter: Object, signal_name: StringName, action: Callable, times: int = 1, msg: String = "") -> bool:
	_lcn_asserts += 1
	var probe: _SignalProbe = _lcn_watch(emitter, signal_name, action)
	if probe == null:
		return _lcn_fail("assert_signal_emitted", msg,
			"signal '%s' on %s" % [signal_name, emitter], "no such signal")
	if probe.count >= times:
		return true
	return _lcn_fail("assert_signal_emitted", msg,
		"'%s' emitted >= %d time(s)" % [signal_name, times], "emitted %d time(s)" % probe.count)


## `action` must not emit `signal_name` on `emitter`.
func assert_signal_not_emitted(emitter: Object, signal_name: StringName, action: Callable, msg: String = "") -> bool:
	_lcn_asserts += 1
	var probe: _SignalProbe = _lcn_watch(emitter, signal_name, action)
	if probe == null:
		return _lcn_fail("assert_signal_not_emitted", msg,
			"signal '%s' on %s" % [signal_name, emitter], "no such signal")
	if probe.count == 0:
		return true
	return _lcn_fail("assert_signal_not_emitted", msg,
		"'%s' silent" % signal_name, "emitted %d time(s), last args %s" % [probe.count, JsonCanon.preview(probe.args)])


## Arguments of the last emission of `signal_name` during `action`, or [].
func capture_signal_args(emitter: Object, signal_name: StringName, action: Callable) -> Array:
	var probe: _SignalProbe = _lcn_watch(emitter, signal_name, action)
	return [] if probe == null else probe.args


## Unconditional failure. For "we should never get here" branches.
func fail(msg: String) -> bool:
	_lcn_asserts += 1
	return _lcn_fail("fail", msg, "unreachable", "reached")


## Abandon the current test without failing. Use for genuinely unmet
## preconditions, never to hide a bug.
func skip(reason: String) -> void:
	if _lcn_skip == "":
		_lcn_skip = reason


## Skip the test unless the named sim system exists. Returns true when present,
## so a test body can early-out: `if not need_system(&"heat"): return`
func need_system(n: StringName) -> bool:
	if TestEnv.system_is_built(n):
		return true
	skip("sim system '%s' is not built yet" % n)
	return false


## Same idea for content and scripts owned by another part.
func need_file(path: String) -> bool:
	if ResourceLoader.exists(path) or FileAccess.file_exists(path):
		return true
	skip("missing '%s'" % path)
	return false


# --- runner protocol ---------------------------------------------------------

func _lcn_prepare(path: String) -> void:
	_lcn_suite_path = path


## Every zero-argument `test_*` method, sorted for stable ordering.
func _lcn_test_methods() -> PackedStringArray:
	var names: Array[String] = []
	for m: Dictionary in get_method_list():
		var n: String = String(m.get("name", ""))
		if not n.begins_with("test_"):
			continue
		var args: Array = m.get("args", [])
		if args.size() != 0:
			continue
		if names.has(n):
			continue
		names.append(n)
	names.sort()
	return PackedStringArray(names)


## Runs one test method and returns its result record. Never throws.
func _lcn_run_test(method: String) -> Dictionary:
	_lcn_failures = []
	_lcn_asserts = 0
	_lcn_skip = ""
	_lcn_test = method
	var t0: int = Time.get_ticks_usec()
	setup()
	if _lcn_skip == "":
		call(method)
	teardown()
	var usec: int = Time.get_ticks_usec() - t0
	return {
		"test": method,
		"asserts": _lcn_asserts,
		"failures": _lcn_failures.duplicate(true),
		"skip": _lcn_skip,
		"usec": usec,
	}


# --- internals ---------------------------------------------------------------

func _lcn_fail(kind: String, msg: String, expected: String, actual: String) -> bool:
	var where: Dictionary = _lcn_where()
	_lcn_failures.append({
		"kind": kind,
		"msg": msg,
		"expected": expected,
		"actual": actual,
		"file": String(where.get("source", _lcn_suite_path)),
		"line": int(where.get("line", 0)),
		"func": String(where.get("function", _lcn_test)),
	})
	return false


## First stack frame outside the framework — i.e. the line the author wrote.
func _lcn_where() -> Dictionary:
	var st: Array = get_stack()
	for frame: Dictionary in st:
		var src: String = String(frame.get("source", ""))
		if src == "" or src.begins_with(FRAMEWORK_DIR):
			continue
		return frame
	return {}


func _lcn_errors_from(action: Callable) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	# Capture at ERROR level only: Log echoes everything it captures to stdout,
	# and a test run should not be buried under the INFO chatter of the code
	# it is exercising.
	for line: String in TestEnv.capture_log(action, TestEnv.LOG_ERROR):
		if line.begins_with("[ERROR]"):
			out.append(line)
	return out


func _lcn_watch(emitter: Object, signal_name: StringName, action: Callable) -> _SignalProbe:
	if emitter == null or not emitter.has_signal(signal_name):
		return null
	var arity: int = _lcn_signal_arity(emitter, signal_name)
	if arity < 0 or arity > 5:
		return null
	var probe: _SignalProbe = _SignalProbe.new()
	var cb: Callable = Callable(probe, "h%d" % arity)
	emitter.connect(signal_name, cb)
	action.call()
	emitter.disconnect(signal_name, cb)
	return probe


func _lcn_signal_arity(emitter: Object, signal_name: StringName) -> int:
	for s: Dictionary in emitter.get_signal_list():
		if StringName(s.get("name", "")) == signal_name:
			var args: Array = s.get("args", [])
			return args.size()
	return -1


func _lcn_is_container(v: Variant) -> bool:
	var t: int = typeof(v)
	return t == TYPE_DICTIONARY or t == TYPE_ARRAY


func _lcn_contains(container: Variant, item: Variant) -> bool:
	match typeof(container):
		TYPE_DICTIONARY:
			var d: Dictionary = container
			if d.has(item):
				return true
			var needle: String = JsonCanon.canon(item)
			for k: Variant in d.keys():
				if JsonCanon.canon(k) == needle:
					return true
			return false
		TYPE_STRING, TYPE_STRING_NAME:
			return String(container).contains(String(item))
		TYPE_NIL:
			return false
		_:
			var needle2: String = JsonCanon.canon(item)
			for v: Variant in container:
				if JsonCanon.canon(v) == needle2:
					return true
			return false


func _lcn_size(container: Variant) -> int:
	match typeof(container):
		TYPE_NIL:
			return 0
		TYPE_DICTIONARY:
			return (container as Dictionary).size()
		TYPE_STRING, TYPE_STRING_NAME:
			return String(container).length()
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return -1
		_:
			var n: int = 0
			for _v: Variant in container:
				n += 1
			return n


## Signal spy. One handler per arity because GDScript lambdas are fixed-arity
## and Godot rejects a callable whose signature does not match the signal.
class _SignalProbe extends RefCounted:
	var count: int = 0
	var args: Array = []

	func h0() -> void:
		count += 1
		args = []

	func h1(a: Variant) -> void:
		count += 1
		args = [a]

	func h2(a: Variant, b: Variant) -> void:
		count += 1
		args = [a, b]

	func h3(a: Variant, b: Variant, c: Variant) -> void:
		count += 1
		args = [a, b, c]

	func h4(a: Variant, b: Variant, c: Variant, d: Variant) -> void:
		count += 1
		args = [a, b, c, d]

	func h5(a: Variant, b: Variant, c: Variant, d: Variant, e: Variant) -> void:
		count += 1
		args = [a, b, c, d, e]

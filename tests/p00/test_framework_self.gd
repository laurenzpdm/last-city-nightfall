extends TestCase
## The test framework testing itself.
##
## Everything in this repo is judged by this rig, so the rig has to be provably
## right: an assertion that silently passes when it should fail is worse than no
## assertion at all. Each case drives a throwaway TestCase and inspects the
## failure records it produced.

class _Probe extends TestCase:
	var setup_calls: int = 0
	var teardown_calls: int = 0
	var ran: PackedStringArray = PackedStringArray()

	func setup() -> void:
		setup_calls += 1

	func teardown() -> void:
		teardown_calls += 1

	func test_b_second() -> void:
		ran.append("b")

	func test_a_first() -> void:
		ran.append("a")

	func test_with_arg(_x: int) -> void:
		ran.append("never")

	func not_a_test() -> void:
		ran.append("never")


var probe: _Probe


func setup() -> void:
	probe = _Probe.new()
	probe._lcn_prepare("res://tests/p00/test_framework_self.gd")


func _failures() -> Array[Dictionary]:
	return probe._lcn_failures


func _fail_count() -> int:
	return probe._lcn_failures.size()


# --- discovery & lifecycle ---------------------------------------------------

func test_discovers_only_zero_arg_test_methods_in_sorted_order() -> void:
	var methods: PackedStringArray = probe._lcn_test_methods()
	assert_eq(methods, PackedStringArray(["test_a_first", "test_b_second"]),
		"only zero-argument test_* methods, alphabetically")


func test_setup_and_teardown_wrap_every_test() -> void:
	probe._lcn_run_test("test_a_first")
	probe._lcn_run_test("test_b_second")
	assert_eq(probe.setup_calls, 2, "setup runs once per test")
	assert_eq(probe.teardown_calls, 2, "teardown runs once per test")
	assert_eq(probe.ran, PackedStringArray(["a", "b"]), "both bodies ran")


func test_result_record_carries_counts_and_timing() -> void:
	var r: Dictionary = probe._lcn_run_test("test_a_first")
	assert_eq(String(r["test"]), "test_a_first")
	assert_eq(r["skip"], "")
	assert_empty(r["failures"])
	assert_ge(float(r["usec"]), 0.0, "elapsed time is recorded")


# --- pass / fail behaviour ---------------------------------------------------

func test_passing_assertions_record_nothing() -> void:
	probe.assert_eq(1, 1)
	probe.assert_eq({"b": 2, "a": [1, 2]}, {"a": [1, 2], "b": 2})
	probe.assert_eq(3, 3.0)
	probe.assert_true(true)
	probe.assert_false(false)
	probe.assert_near(0.1 + 0.2, 0.3, 1e-9)
	probe.assert_ne("a", "b")
	probe.assert_null(null)
	probe.assert_not_null(0)
	probe.assert_gt(2.0, 1.0)
	probe.assert_ge(1.0, 1.0)
	probe.assert_lt(1.0, 2.0)
	probe.assert_le(1.0, 1.0)
	probe.assert_between(5.0, 1.0, 10.0)
	probe.assert_has([1, 2, 3], 2)
	probe.assert_has({"k": 1}, "k")
	probe.assert_has("frozen plain", "plain")
	probe.assert_has_not([1, 2], 9)
	probe.assert_size([1, 2, 3], 3)
	probe.assert_size({"a": 1}, 1)
	probe.assert_empty([])
	probe.assert_not_empty([0])
	assert_eq(_fail_count(), 0, "not one of those should have failed")
	assert_eq(probe._lcn_asserts, 22, "every assertion is counted")


func test_failing_assertions_are_all_recorded_not_just_the_first() -> void:
	probe.assert_eq(1, 2)
	probe.assert_true(false)
	probe.assert_near(1.0, 2.0, 0.1)
	assert_eq(_fail_count(), 3, "assertions never abort the test")


func test_failure_names_the_authors_file_and_line_not_the_framework() -> void:
	probe.assert_eq(41, 42, "answer drifted")
	assert_eq(_fail_count(), 1)
	var f: Dictionary = _failures()[0]
	assert_eq(String(f["file"]), "res://tests/p00/test_framework_self.gd",
		"blames the test file, never tests/framework/*")
	assert_gt(float(f["line"]), 0.0, "a real line number")
	assert_eq(String(f["func"]), "test_failure_names_the_authors_file_and_line_not_the_framework")
	assert_eq(String(f["kind"]), "assert_eq")
	assert_eq(String(f["msg"]), "answer drifted")
	assert_eq(String(f["expected"]), "42")
	assert_eq(String(f["actual"]), "41")


func test_deep_equality_sees_through_key_order_and_int_float() -> void:
	probe.assert_eq({"z": 1, "a": {"n": [1, 2, 3]}}, {"a": {"n": [1, 2, 3]}, "z": 1})
	probe.assert_eq([1.0, 2.0], [1, 2])
	assert_eq(_fail_count(), 0, "structural equality ignores ordering and int/float")
	probe.assert_eq({"a": 1}, {"a": 1, "b": 2})
	assert_eq(_fail_count(), 1, "a missing key is still a difference")


func test_near_reports_how_far_off_it_was() -> void:
	probe.assert_near(9.5, 10.0, 0.1, "heat budget")
	assert_eq(_fail_count(), 1)
	assert_has(String(_failures()[0]["actual"]), "off by", "the message quantifies the miss")


func test_assert_size_and_empty_reject_wrong_containers() -> void:
	probe.assert_size([1, 2], 3)
	probe.assert_empty([1])
	probe.assert_not_empty({})
	assert_eq(_fail_count(), 3)


# --- error channel -----------------------------------------------------------

func test_assert_throws_catches_a_logged_error() -> void:
	var refuse: Callable = func() -> void: Log.error("p00", "placement refused: occupied")
	probe.assert_throws(refuse, "occupied")
	assert_eq(_fail_count(), 0, "a logged ERROR satisfies assert_throws")


func test_assert_throws_fails_when_nothing_went_wrong() -> void:
	var quiet: Callable = func() -> void: Log.info("p00", "all good")
	probe.assert_throws(quiet)
	assert_eq(_fail_count(), 1, "silence is a failure for assert_throws")
	assert_has(String(_failures()[0]["actual"]), "without reporting an error")


func test_assert_throws_fails_on_the_wrong_error() -> void:
	var wrong: Callable = func() -> void: Log.error("p00", "out of bounds")
	probe.assert_throws(wrong, "occupied")
	assert_eq(_fail_count(), 1, "the substring has to match")


func test_assert_no_errors_flags_a_noisy_happy_path() -> void:
	var quiet: Callable = func() -> void: Log.info("p00", "quiet")
	var noisy: Callable = func() -> void: Log.error("p00", "boom")
	probe.assert_no_errors(quiet)
	assert_eq(_fail_count(), 0)
	probe.assert_no_errors(noisy)
	assert_eq(_fail_count(), 1)


func test_log_capture_is_restored_afterwards() -> void:
	var lg: Node = TestEnv.logger()
	var before_capture: bool = bool(lg.get("capture"))
	var before_level: int = int(lg.get("min_level"))
	var noisy: Callable = func() -> void: Log.error("p00", "x")
	probe.assert_throws(noisy)
	assert_eq(bool(lg.get("capture")), before_capture, "capture flag restored")
	assert_eq(int(lg.get("min_level")), before_level, "log level restored")


# --- determinism -------------------------------------------------------------

func test_assert_deterministic_passes_on_a_pure_function() -> void:
	var pure: Callable = func() -> Variant: return {"tick": 5, "heat": [1.5, 2.5]}
	probe.assert_deterministic(pure)
	assert_eq(_fail_count(), 0)


func test_assert_deterministic_catches_drift_and_names_the_path() -> void:
	var counter: Array[int] = [0]
	var drifting: Callable = func() -> Variant:
		counter[0] += 1
		return {"systems": {"heat": {"charge": 10.0 + float(counter[0])}}}
	probe.assert_deterministic(drifting)
	assert_eq(_fail_count(), 1, "a value that moves between runs must fail")
	var actual: String = String(_failures()[0]["actual"])
	assert_has(actual, "$.systems.heat.charge", "the exact divergent key path is reported")


func test_assert_deterministic_runs_the_producer_the_requested_number_of_times() -> void:
	var calls: Array[int] = [0]
	var counted: Callable = func() -> Variant:
		calls[0] += 1
		return {"stable": true}
	probe.assert_deterministic(counted, "", 5)
	assert_eq(calls[0], 5)
	assert_eq(_fail_count(), 0)


# --- signals -----------------------------------------------------------------

func test_signal_assertions_watch_the_real_bus() -> void:
	var shout: Callable = func() -> void: Bus.toast.emit("hello")
	var nothing: Callable = func() -> void: pass

	probe.assert_signal_emitted(Bus, &"toast", shout)
	assert_eq(_fail_count(), 0, "an emitted signal satisfies the assertion")

	probe.assert_signal_emitted(Bus, &"toast", nothing)
	assert_eq(_fail_count(), 1, "a silent signal fails the assertion")

	probe.assert_signal_not_emitted(Bus, &"toast", nothing)
	assert_eq(_fail_count(), 1, "silence satisfies assert_signal_not_emitted")

	probe.assert_signal_not_emitted(Bus, &"toast", shout)
	assert_eq(_fail_count(), 2, "an unexpected emission fails")


func test_signal_assertion_handles_multi_argument_signals() -> void:
	var place: Callable = func() -> void: Bus.building_placed.emit(12, &"coal_generator", Vector2i(4, 5))
	var args: Array = probe.capture_signal_args(Bus, &"building_placed", place)
	assert_eq(args.size(), 3, "all three signal arguments are captured")
	assert_eq(args[0], 12)
	assert_eq(String(args[1]), "coal_generator")
	assert_eq(args[2], Vector2i(4, 5))


func test_signal_probe_disconnects_after_the_action() -> void:
	var shout: Callable = func() -> void: Bus.toast.emit("a")
	probe.assert_signal_emitted(Bus, &"toast", shout)
	assert_eq(Bus.get_signal_connection_list(&"toast").size(), 0,
		"the framework leaves no listener behind on Bus")


# --- skipping ----------------------------------------------------------------

func test_skip_marks_the_test_without_failing_it() -> void:
	var skipper: _Probe = _Probe.new()
	skipper._lcn_prepare("res://tests/p00/test_framework_self.gd")
	skipper.skip("dependency missing")
	var r: Dictionary = skipper._lcn_run_test("test_a_first")
	assert_eq(String(r["skip"]), "", "skip is cleared at the start of each test")

	probe.skip("first reason")
	probe.skip("second reason")
	assert_eq(probe._lcn_skip, "first reason", "the first reason wins")


func test_need_system_skips_when_a_part_is_absent() -> void:
	assert_false(probe.need_system(&"definitely_not_a_real_system"))
	assert_has(probe._lcn_skip, "definitely_not_a_real_system")
	assert_eq(_fail_count(), 0, "an unbuilt dependency is a skip, never a failure")


func test_need_file_skips_when_a_path_is_absent() -> void:
	assert_true(probe.need_file("res://tests/framework/test_case.gd"))
	assert_eq(probe._lcn_skip, "")
	assert_false(probe.need_file("res://game/sim/nope/nope.gd"))
	assert_has(probe._lcn_skip, "nope")


# --- canonicalisation --------------------------------------------------------

func test_canon_is_key_order_independent_and_stable() -> void:
	var a: Dictionary = {"b": 1, "a": 2, "c": {"y": [1, 2], "x": "s"}}
	var b: Dictionary = {"c": {"x": "s", "y": [1, 2]}, "a": 2, "b": 1}
	assert_eq(JsonCanon.canon(a), JsonCanon.canon(b))
	assert_eq(JsonCanon.hash_of(a).length(), 64, "sha256 hex")


func test_canon_normalises_numbers_without_hiding_real_differences() -> void:
	assert_eq(JsonCanon.num(3.0), "3", "integral floats collapse to their int form")
	assert_eq(JsonCanon.num(-0.5), "-0.5")
	assert_eq(JsonCanon.num(INF), "Inf")
	assert_eq(JsonCanon.num(-INF), "-Inf")
	assert_eq(JsonCanon.num(NAN), "NaN")
	assert_ne(JsonCanon.num(0.1), JsonCanon.num(0.100000001))


func test_diff_compares_floats_exactly_even_when_canon_rounds_them() -> void:
	# canon() rounds to 12 decimals for readable assertions. The determinism
	# tripwire must not inherit that tolerance, or drift hides in the last bits.
	var a: float = 0.1
	var b: float = 0.1 + 1.0e-16
	assert_eq(JsonCanon.num(a), JsonCanon.num(b), "canon text is deliberately equal here")
	var d: PackedStringArray = JsonCanon.diff({"charge": a}, {"charge": b})
	assert_eq(d.size(), 1, "diff still sees the last-bit difference")
	assert_has(d[0], "$.charge")


func test_diff_treats_two_nans_as_equal() -> void:
	assert_empty(JsonCanon.diff({"x": NAN}, {"x": NAN}), "NaN != NaN would make every run look broken")


func test_canon_sorts_integer_keys_numerically() -> void:
	var d: Dictionary = {}
	for i: int in [10, 2, 1, 20]:
		d[i] = i
	assert_eq(JsonCanon.canon(d).find("\"#00000000000000000001\""), 1,
		"key 1 comes before key 2 and key 10")


func test_diff_reports_the_first_divergent_path() -> void:
	var a: Dictionary = {"systems": {"heat": {"nets": [{"charge": 1.0}, {"charge": 2.0}]}}}
	var b: Dictionary = {"systems": {"heat": {"nets": [{"charge": 1.0}, {"charge": 2.5}]}}}
	var d: PackedStringArray = JsonCanon.diff(a, b)
	assert_eq(d.size(), 1)
	assert_has(d[0], "$.systems.heat.nets[1].charge")


func test_diff_reports_missing_keys_and_length_changes() -> void:
	var d: PackedStringArray = JsonCanon.diff({"a": 1}, {"a": 1, "b": 2})
	assert_eq(d.size(), 1)
	assert_has(d[0], "missing in a")

	var d2: PackedStringArray = JsonCanon.diff({"xs": [1, 2]}, {"xs": [1, 2, 3]})
	assert_has(d2[0], "length a=2 b=3")


func test_diff_ignore_list_drops_volatile_fields() -> void:
	var a: Dictionary = {"wall_ms": 12, "final": {"tick": 600}}
	var b: Dictionary = {"wall_ms": 908, "final": {"tick": 600}}
	assert_not_empty(JsonCanon.diff(a, b), "without the ignore list it differs")
	assert_empty(JsonCanon.diff(a, b, PackedStringArray(["wall_ms"])),
		"wall_ms is wall-clock noise, not state")


func test_strip_removes_ignored_keys_recursively() -> void:
	var stripped: Variant = JsonCanon.strip(
		{"wall_ms": 1, "runs": [{"wall_ms": 2, "tick": 5}]}, PackedStringArray(["wall_ms"]))
	assert_eq(stripped, {"runs": [{"tick": 5}]})

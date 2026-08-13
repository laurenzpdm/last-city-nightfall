class_name TestRunner
extends RefCounted
## Discovers, runs and reports every test suite in the repo.
##
## Design constraints that shaped this file:
##   * Twenty parts are built in parallel. A suite whose dependency does not
##     exist yet must SKIP, not fail, and a suite that fails to compile must not
##     take the other nineteen down with it.
##   * The output is read by humans in a terminal and by grep in tools/check.sh,
##     so it prints exactly one of TESTS PASSED / TESTS FAILED, at the end.
##   * Ordering is sorted everywhere. A flaky test order is a flaky test suite.
##
## print() is used deliberately here: this is the harness, not game code, and
## its stdout is a product interface.

const TEST_CASE_PATH: String = "res://tests/framework/test_case.gd"
const SKIP_DIRS: Array[String] = ["framework", "scenarios", "artifacts"]
## The shared entry point is not a suite. Without this it discovers itself and
## check.sh launches a runner that launches a runner.
const SKIP_FILES: Array[String] = ["res://tests/run_tests.gd"]

const RULE: String = "────────────────────────────────────────────────────────────────────────"

var roots: PackedStringArray = PackedStringArray(["res://tests"])
var filter: String = ""          ## substring match on "<suite>::<test>"
var verbose: bool = false        ## print passing tests too
var lenient: bool = false        ## compile failures become skips, not failures
var list_mode: String = ""       ## "", "all", "suites", "standalone"

var suites_run: int = 0
var suites_skipped: int = 0
var suites_broken: int = 0
var suites_standalone: int = 0
var standalone_paths: PackedStringArray = PackedStringArray()
var tests_passed: int = 0
var tests_failed: int = 0
var tests_skipped: int = 0
var asserts_total: int = 0
var _failures: Array[Dictionary] = []
var _available_systems: PackedStringArray = PackedStringArray()


## THE NAMING CONTRACT, written down here because it used to be enforced only by
## a silent `f.begins_with("test_")` — which is how four suites and 2,480 lines
## of assertions became invisible to the gate while two of them were red.
##
## A suite entry point is any of:
##   tests/**/test_*.gd     a TestCase suite, or a Node suite with its own scene
##   tests/**/run_*.gd      a SceneTree runner (executed with --script)
##   tests/**/*.tscn        a scene runner (executed as a scene, so autoloads exist)
##
## A .tscn always WINS over the .gd it instantiates: a Node-based suite run with
## --script compiles before the autoloads exist, prints nothing and exits 0 — a
## silent false green. Preferring the scene makes that unreachable.
static func discover(root_dirs: PackedStringArray) -> PackedStringArray:
	var found: Array[String] = []
	var scenes: Array[String] = []
	for root: String in root_dirs:
		_walk(root, found, scenes)
	var shadowed: Dictionary[String, bool] = {}
	for scene: String in scenes:
		var backing: String = _scene_script(scene)
		if backing != "":
			shadowed[backing] = true
	var out: Array[String] = []
	for f: String in found:
		if not shadowed.has(f) and not SKIP_FILES.has(f):
			out.append(f)
	out.append_array(scenes)
	out.sort()
	return PackedStringArray(out)


## The first res://*.gd an ext_resource line in a .tscn points at, or "".
static func _scene_script(scene_path: String) -> String:
	var f: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if f == null:
		return ""
	var guard: int = 0
	while not f.eof_reached() and guard < 64:
		guard += 1
		var line: String = f.get_line()
		if not line.begins_with("[ext_resource"):
			continue
		var at: int = line.find("path=\"")
		if at < 0:
			continue
		var rest: String = line.substr(at + 6)
		var close: int = rest.find("\"")
		if close < 0:
			continue
		var path: String = rest.substr(0, close)
		if path.ends_with(".gd"):
			return path
	return ""


static func _walk(dir_path: String, found: Array[String], scenes: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	var sub_dirs: PackedStringArray = dir.get_directories()
	var files: PackedStringArray = dir.get_files()
	var sorted_dirs: Array[String] = []
	for d: String in sub_dirs:
		sorted_dirs.append(d)
	sorted_dirs.sort()
	for d: String in sorted_dirs:
		if d.begins_with(".") or SKIP_DIRS.has(d):
			continue
		_walk("%s/%s" % [dir_path, d], found, scenes)
	var sorted_files: Array[String] = []
	for f: String in files:
		sorted_files.append(f)
	sorted_files.sort()
	for f: String in sorted_files:
		if f.ends_with(".tscn"):
			scenes.append("%s/%s" % [dir_path, f])
		elif (f.begins_with("test_") or f.begins_with("run_")) and f.ends_with(".gd"):
			found.append("%s/%s" % [dir_path, f])


## Runs everything. Returns 0 when green, 1 when any test failed, 2 on a
## broken environment.
func run() -> int:
	var missing: PackedStringArray = TestEnv.missing()
	if not missing.is_empty():
		print("environment is missing autoloads: %s" % ", ".join(missing))
		print("TESTS FAILED")
		return 2

	var paths: PackedStringArray = discover(roots)
	if list_mode != "":
		for p: String in paths:
			var kind: String = classify(p)
			if list_mode == "all" or list_mode == kind:
				print(p)
		return 0

	_probe_systems()

	print(RULE)
	print(" Last City: Nightfall — test run")
	print(" %d suite file(s) under %s" % [paths.size(), ", ".join(roots)])
	if filter != "":
		print(" filter: %s" % filter)
	if _available_systems.is_empty():
		print(" sim systems present: (none yet)")
	else:
		print(" sim systems present: %s" % ", ".join(_available_systems))
	print(RULE)

	var t0: int = Time.get_ticks_usec()
	for path: String in paths:
		_run_suite(path)
	var elapsed_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

	_reset_world()
	_report(elapsed_ms)
	return 1 if (tests_failed > 0 or (suites_broken > 0 and not lenient)) else 0


## "suites" for a TestCase file, "standalone" for anything else — a part that
## brought its own entry point. Standalone suites cannot run inside this process
## (a SceneTree script IS the main loop), so tools/check.sh launches each one in
## its own Godot and gates on its exit code. Nobody is forced onto this
## framework; they are just forced to be runnable and to exit non-zero on red.
##
## The base class is read out of the source rather than off the loaded Script:
## Script.get_instance_base_type() reports "Node" for a SceneTree script in 4.7,
## and loading a foreign suite merely to classify it would compile a file this
## runner is never going to execute.
static func classify(path: String) -> String:
	if path.ends_with(".tscn"):
		return "standalone"
	var base: String = declared_base(path)
	if base == "TestCase":
		return "suites"
	if base == "SceneTree" or base == "MainLoop" or base == "Node":
		return "standalone"
	var scr: Script = load(path) as Script
	if scr == null:
		return "broken"
	return "suites" if extends_test_case(scr) else "standalone"


## The identifier on the script's own `extends` line, or "".
static func declared_base(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if not line.begins_with("extends "):
			continue
		return line.substr(8).strip_edges().split(" ")[0].split("#")[0].strip_edges()
	return ""


# --- suite execution ---------------------------------------------------------

func _run_suite(path: String) -> void:
	if classify(path) == "standalone":
		# A part that brought its own entry point. It cannot run inside this
		# process — a SceneTree script IS the main loop — so tools/check.sh
		# launches it separately and gates on its exit code.
		suites_standalone += 1
		standalone_paths.append(path)
		return
	var scr: Script = load(path) as Script
	if scr == null:
		suites_broken += 1
		print("")
		print(" %s  %s" % ["SKIP " if lenient else "BROKEN", _rel(path)])
		print("        script failed to compile — see the SCRIPT ERROR above")
		return
	if not extends_test_case(scr):
		suites_broken += 1
		print("")
		print(" %s  %s" % ["SKIP " if lenient else "BROKEN", _rel(path)])
		print("        does not extend TestCase (add `extends TestCase`)")
		return

	var suite: Object = scr.new()
	if suite == null:
		suites_broken += 1
		print("")
		print(" BROKEN  %s" % _rel(path))
		print("        could not be instantiated")
		return
	suite.call("_lcn_prepare", path)

	var name: String = String(suite.call("suite_name"))
	var blocked: String = _blocked_reason(suite)
	var methods: PackedStringArray = suite.call("_lcn_test_methods")
	var selected: PackedStringArray = PackedStringArray()
	for m: String in methods:
		if filter == "" or ("%s::%s" % [name, m]).contains(filter) or path.contains(filter):
			selected.append(m)
	if selected.is_empty():
		return

	print("")
	print(" ── %s   (%s)" % [name, _rel(path)])

	if blocked != "":
		suites_skipped += 1
		tests_skipped += selected.size()
		print("    SKIP  all %d test(s) — %s" % [selected.size(), blocked])
		return

	suites_run += 1
	suite.call("before_all")
	for m: String in selected:
		var result: Dictionary = suite.call("_lcn_run_test", m)
		_record(name, path, result)
	suite.call("after_all")
	_reset_world()


func _record(suite_name: String, path: String, result: Dictionary) -> void:
	var method: String = String(result.get("test", "?"))
	var asserts: int = int(result.get("asserts", 0))
	var ms: float = float(result.get("usec", 0)) / 1000.0
	var skip: String = String(result.get("skip", ""))
	var failures: Array = result.get("failures", [])
	asserts_total += asserts

	if not failures.is_empty():
		tests_failed += 1
		print("    FAIL  %-46s %d assert(s), %.1f ms" % [method, asserts, ms])
		for f: Dictionary in failures:
			var record: Dictionary = f.duplicate()
			record["suite"] = suite_name
			record["path"] = path
			record["test"] = method
			_failures.append(record)
			for line: String in _format_failure(record, "          "):
				print(line)
		return
	if skip != "":
		tests_skipped += 1
		print("    SKIP  %-46s %s" % [method, skip])
		return
	tests_passed += 1
	if verbose:
		print("    pass  %-46s %d assert(s), %.1f ms" % [method, asserts, ms])


func _format_failure(f: Dictionary, indent: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var file: String = String(f.get("file", "?"))
	var line: int = int(f.get("line", 0))
	var kind: String = String(f.get("kind", "assert"))
	var msg: String = String(f.get("msg", ""))
	out.append("%s%s:%d  in %s()" % [indent, file, line, String(f.get("func", "?"))])
	out.append("%s%s%s" % [indent, kind, "" if msg == "" else " — " + msg])
	out.append("%s  expected: %s" % [indent, String(f.get("expected", ""))])
	out.append("%s  actual:   %s" % [indent, String(f.get("actual", ""))])
	return out


## Why this suite cannot run, or "" when it can.
func _blocked_reason(suite: Object) -> String:
	var need_systems: PackedStringArray = suite.call("requires_systems")
	var absent: PackedStringArray = PackedStringArray()
	for n: String in need_systems:
		if not _available_systems.has(n):
			absent.append(n)
	if not absent.is_empty():
		return "sim system(s) not built yet: %s" % ", ".join(absent)
	var need_files: PackedStringArray = suite.call("requires_files")
	var gone: PackedStringArray = PackedStringArray()
	for p: String in need_files:
		if not (ResourceLoader.exists(p) or FileAccess.file_exists(p)):
			gone.append(p)
	if not gone.is_empty():
		return "missing file(s): %s" % ", ".join(gone)
	return ""


static func extends_test_case(scr: Script) -> bool:
	var cursor: Script = scr
	var guard: int = 0
	while cursor != null and guard < 32:
		if cursor.resource_path == TEST_CASE_PATH:
			return true
		cursor = cursor.get_base_script()
		guard += 1
	return false


## Creates a throwaway world so suites can be matched against the systems that
## actually exist in this build, then leaves nothing behind.
func _probe_systems() -> void:
	var sim: Node = TestEnv.sim()
	var clock: Node = TestEnv.clock()
	if sim == null or clock == null:
		return
	clock.call("set_manual", true)
	sim.call("create_world", 1)
	_available_systems = TestEnv.system_names()
	TestEnv.built_systems = _available_systems
	sim.call("teardown")
	clock.call("reset")


func _reset_world() -> void:
	var sim: Node = TestEnv.sim()
	var clock: Node = TestEnv.clock()
	if sim != null:
		sim.call("teardown")
	if clock != null:
		clock.call("reset")


# --- reporting ---------------------------------------------------------------

func _report(elapsed_ms: float) -> void:
	print("")
	print(RULE)
	if not _failures.is_empty():
		print(" FAILURES (%d)" % _failures.size())
		print("")
		for i: int in range(_failures.size()):
			var f: Dictionary = _failures[i]
			print("  %d) %s :: %s" % [i + 1, String(f.get("suite", "?")), String(f.get("test", "?"))])
			for line: String in _format_failure(f, "     "):
				print(line)
			print("")
		print(RULE)

	if suites_standalone > 0:
		print(" standalone suites — tools/check.sh runs each in its own process:")
		for p: String in standalone_paths:
			print("   %s   (extends %s)" % [_rel(p), declared_base(p)])
		print(RULE)
	print(" suites   %d run, %d skipped, %d broken, %d standalone" % [
		suites_run, suites_skipped, suites_broken, suites_standalone])
	print(" tests    %d passed, %d failed, %d skipped" % [tests_passed, tests_failed, tests_skipped])
	print(" asserts  %d" % asserts_total)
	print(" time     %.2f s" % (elapsed_ms / 1000.0))
	print(RULE)
	if tests_failed > 0 or (suites_broken > 0 and not lenient):
		print("TESTS FAILED")
	else:
		print("TESTS PASSED")


func _rel(path: String) -> String:
	return path.replace("res://", "")

extends SceneTree
## Test entry point.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script tests/run_tests.gd -- [options]
##
## Options (everything after the bare `--`):
##   --filter=<substring>   only suites/tests whose "<suite>::<test>" matches
##   --part=<dir>           only tests/<dir>/ (e.g. --part=p02)
##   --verbose              also list passing tests
##   --lenient              a suite that fails to compile skips instead of failing
##   --list                 print every discovered suite file and exit
##   --list-standalone      print only suites that are their own SceneTree entry
##   --list-suites          print only TestCase suites
##   --log                  do not silence Log below WARN
##
## Exit code: 0 green, 1 red, 2 broken environment.
##
## This file is compiled BEFORE the autoloads are registered, so it must not
## name Log/Sim/SimClock directly and must not preload anything that does.
## Everything real happens on the first processed frame, via load().

const RUNNER_PATH: String = "res://tests/framework/test_runner.gd"
const ENV_PATH: String = "res://tests/framework/test_env.gd"

var _done: bool = false


func _initialize() -> void:
	pass


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var code: int = _execute()
	quit(code)
	return true


func _execute() -> int:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var filter: String = ""
	var part: String = ""
	var verbose: bool = false
	var lenient: bool = false
	var list_mode: String = ""
	var quiet_log: bool = true
	for a: String in args:
		if a.begins_with("--filter="):
			filter = a.substr(9)
		elif a.begins_with("--part="):
			part = a.substr(7)
		elif a == "--verbose" or a == "-v":
			verbose = true
		elif a == "--lenient":
			lenient = true
		elif a == "--list":
			list_mode = "all"
		elif a == "--list-standalone":
			list_mode = "standalone"
		elif a == "--list-suites":
			list_mode = "suites"
		elif a == "--log":
			quiet_log = false

	var env_script: Script = load(ENV_PATH) as Script
	if env_script == null:
		print("cannot load %s" % ENV_PATH)
		print("TESTS FAILED")
		return 2
	if quiet_log:
		# 3 == Log.Level.WARN. Named by value because Log is fetched by path.
		env_script.call("set_log_level", 3)

	var runner_script: Script = load(RUNNER_PATH) as Script
	if runner_script == null:
		print("cannot load %s" % RUNNER_PATH)
		print("TESTS FAILED")
		return 2

	var runner: Object = runner_script.new()
	runner.set("filter", filter)
	runner.set("verbose", verbose)
	runner.set("lenient", lenient)
	runner.set("list_mode", list_mode)
	if part != "":
		var dir: String = part if part.begins_with("res://") else "res://tests/" + part
		runner.set("roots", PackedStringArray([dir]))

	return int(runner.call("run"))

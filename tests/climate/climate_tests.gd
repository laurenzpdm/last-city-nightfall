extends Node
## Headless entry point for the [P09] climate suite.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       res://tests/climate/climate_tests.tscn
##
## Exit code 0 = green, 1 = red. A shared runner can skip this scene entirely
## and call ClimateTestSuite.new().run() instead.

func _ready() -> void:
	Log.min_level = Log.Level.WARN     # keep the report readable; failures still print
	var suite := ClimateTestSuite.new()
	var result: Dictionary = suite.run()
	var failed: int = int(result.get("failed", 0))
	var passed: int = int(result.get("passed", 0))

	print("")
	print("== climate tests ==")
	for t: Dictionary in result.get("timings", []):
		print("  %-38s %5d ms  %s" % [
			String(t.get("name", "?")), int(t.get("ms", 0)),
			"FAIL" if int(t.get("failed", 0)) > 0 else "ok",
		])
	for line: String in result.get("failures", PackedStringArray()):
		print("  FAIL  %s" % line)
	print("  %d passed, %d failed" % [passed, failed])
	print("TESTS FAILED" if failed > 0 else "TESTS PASSED")
	get_tree().quit(1 if failed > 0 else 0)

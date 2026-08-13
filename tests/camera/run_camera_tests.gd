extends Node
## Entry point for the [P16] camera suite.
##
##   godot --headless --path . res://tests/camera/run_camera_tests.gd.tscn -- --out=artifacts/p16
##
## Runs in a scene rather than via --script on purpose: the autoloads only exist once the
## SceneTree has installed them, and the suite checks the camera against the real Settings
## and the real Bus. Exit code is the number of failures, capped at 125.

const TAG: String = "camera-tests"

var _out_dir: String = "res://artifacts/p16_camera"


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	call_deferred("_run")


func _run() -> void:
	var report: PackedStringArray = PackedStringArray()
	var total_checks: int = 0
	var total_failed: int = 0

	var pure := CameraTests.new()
	var pure_result: Dictionary = pure.run_all()
	total_checks += int(pure_result["checks"])
	total_failed += int(pure_result["failed"])
	report.append("suite=camera checks=%d failed=%d" % [int(pure_result["checks"]), int(pure_result["failed"])])
	for f: String in pure_result["failures"]:
		report.append("  FAIL %s" % f)

	var node_tests := CameraNodeTests.new()
	node_tests.name = "CameraNodeTests"
	add_child(node_tests)
	var node_result: Dictionary = await node_tests.run_all()
	total_checks += int(node_result["checks"])
	total_failed += int(node_result["failed"])
	report.append("suite=camera_node checks=%d failed=%d" % [int(node_result["checks"]), int(node_result["failed"])])
	for f2: String in node_result["failures"]:
		report.append("  FAIL %s" % f2)

	var verdict: String = "TESTS PASSED" if total_failed == 0 else "TESTS FAILED"
	report.append("%s — %d checks, %d failures" % [verdict, total_checks, total_failed])

	for line: String in report:
		if line.begins_with("  FAIL"):
			CameraServices.log_error(TAG, line.strip_edges())
		else:
			CameraServices.log_info(TAG, line)

	_write_report(report, total_checks, total_failed)
	get_tree().quit(mini(total_failed, 125))


func _write_report(report: PackedStringArray, total_checks: int, total_failed: int) -> void:
	var base: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/camera_tests.txt", FileAccess.WRITE)
	if f != null:
		for line: String in report:
			f.store_line(line)
	var j := FileAccess.open(base + "/camera_tests.json", FileAccess.WRITE)
	if j != null:
		j.store_string(JSON.stringify({
			"part": "P16",
			"checks": total_checks,
			"failed": total_failed,
			"lines": report,
		}, "  "))

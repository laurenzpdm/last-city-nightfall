extends SceneTree
## [P24] Produces the shippable builds.
##
##   godot --headless --path . --script game/ui/meta/export_build.gd -- --all
##   godot --headless --path . --script game/ui/meta/export_build.gd -- --linux
##   godot --headless --path . --script game/ui/meta/export_build.gd -- --windows
##   godot --headless --path . --script game/ui/meta/export_build.gd -- --check
##
## Godot only reads export presets from `export_presets.cfg` at the PROJECT
## ROOT, and the root is shared by every part working in this tree at once. So
## the master lives in `game/content/meta/export_presets.cfg`, which [P24] owns,
## and this script copies it up before exporting. `--check` copies and reports
## without building, which is what a CI job wants before it spends four minutes.
##
## It extends SceneTree and runs with `--script`, so it must not name an
## autoload: at that point they do not exist yet (ARCHITECTURE.md §6.1).
## Everything here is engine API and file I/O, which is available immediately.
##
## The export itself is a SECOND Godot process (`--export-release`), because the
## editor's exporter cannot run inside a `--script` main loop. That is also why
## this file checks the SIZE of what it produced: a missing export template
## makes Godot print an error and leave a 0-byte or absent file, and a build
## script that reports success on a 0-byte binary is worse than no build script.

const MASTER: String = "res://game/content/meta/export_presets.cfg"
const ROOT_COPY: String = "res://export_presets.cfg"
## Anything smaller than this is not a game; it is a failed export.
const MIN_BINARY_BYTES: int = 20 * 1024 * 1024

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var want_linux: bool = args.has("--linux") or args.has("--all")
	var want_windows: bool = args.has("--windows") or args.has("--all")
	if not (want_linux or want_windows or args.has("--check")):
		print("export_build: pass --all, --linux, --windows or --check")
		quit(2)
		return true

	if not _install_presets():
		quit(2)
		return true
	if args.has("--check"):
		_report_templates()
		print("export_build: presets installed at %s" % ROOT_COPY)
		quit(0)
		return true

	var failed: int = 0
	if want_linux:
		var linux_out: String = "dist/linux/last-city-nightfall.x86_64"
		if _export("Linux/X11 64", linux_out):
			# The binary exists; now ask it whether it is a GAME. See _smoke().
			failed += 0 if _smoke(linux_out) else 1
		else:
			failed += 1
	if want_windows:
		failed += 0 if _export("Windows Desktop 64", "dist/windows/last-city-nightfall.exe") else 1
	print("export_build: %s" % ("EXPORT OK" if failed == 0 else "EXPORT FAILED (%d)" % failed))
	quit(failed)
	return true


## Copies the owned master to the project root. Returns false if it cannot.
func _install_presets() -> bool:
	if not FileAccess.file_exists(MASTER):
		print("export_build: no preset master at %s" % MASTER)
		return false
	var text: String = FileAccess.get_file_as_string(MASTER)
	var out: FileAccess = FileAccess.open(ROOT_COPY, FileAccess.WRITE)
	if out == null:
		print("export_build: cannot write %s (err %d)" % [ROOT_COPY, FileAccess.get_open_error()])
		return false
	out.store_string(text)
	out.close()
	return true


func _export(preset: String, relative_out: String) -> bool:
	var root: String = ProjectSettings.globalize_path("res://")
	var out_path: String = root.path_join(relative_out)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	if FileAccess.file_exists(out_path):
		var _e: int = DirAccess.remove_absolute(out_path)
	var argv: PackedStringArray = PackedStringArray([
		"--headless", "--path", root, "--export-release", preset, out_path])
	var log: Array = []
	var code: int = OS.execute(OS.get_executable_path(), argv, log, true)
	var size: int = 0
	if FileAccess.file_exists(out_path):
		size = FileAccess.get_file_as_bytes(out_path).size()
	# The exit code alone is not enough: Godot has exited 0 after printing
	# "no export template found" and leaving nothing behind.
	var ok: bool = size >= MIN_BINARY_BYTES
	print("export_build: %-20s exit %d, %s, %.1f MB %s" % [
		preset, code, relative_out, float(size) / 1048576.0,
		"OK" if ok else "— TOO SMALL, THIS IS NOT A BUILD"])
	if not ok:
		for line: Variant in log:
			for text: String in String(line).split("\n"):
				if text.strip_edges() != "":
					print("    %s" % text)
	return ok


## Runs the exported binary and asks it what it loaded.
##
## A 73 MB file is not proof of a build. The first export this script produced
## was exactly that size, started, created a world, installed the whole view —
## and loaded ZERO content, because `Registry` scans for `*.tres` and an
## exported project has no `.tres` on disk: the exporter converts every resource
## to a binary `.res` and leaves `<name>.tres.remap` in its place. Every
## building, recipe, enemy, law, event and self-installing bootstrap was absent
## from the shipped game while the log said "world created, systems=11".
##
## So the build script refuses to certify a build it has not seen load its own
## content. Host platform only — this cannot run the Windows binary.
func _smoke(relative: String) -> bool:
	if OS.get_name() != "Linux":
		print("export_build: (no smoke run — the host cannot execute %s)" % relative)
		return true
	var path: String = ProjectSettings.globalize_path("res://").path_join(relative)
	var log: Array = []
	var _code: int = OS.execute(path, PackedStringArray(["--headless", "--quit-after", "200"]), log, true)
	var items: int = -1
	for chunk: Variant in log:
		for line: String in String(chunk).split("\n"):
			var at: int = line.find("registry] loaded ")
			if at >= 0:
				items = int(line.substr(at + 17).split(" ")[0])
	if items < 0:
		print("export_build: the exported build printed no registry line — cannot tell if it has content")
		return false
	var ok: bool = items > 0
	print("export_build: the exported build loaded %d content item(s) %s" % [
		items, "" if ok else "— IT IS AN EMPTY GAME, see game/core/registry.gd and the .tres.remap note above"])
	return ok


func _report_templates() -> void:
	var dir: String = OS.get_data_dir().path_join("godot/export_templates/%s" %
		_template_version())
	var have: PackedStringArray = PackedStringArray()
	var d: DirAccess = DirAccess.open(dir)
	if d != null:
		for f: String in d.get_files():
			if f.begins_with("linux_release") or f.begins_with("windows_release"):
				have.append(f)
	print("export_build: templates in %s: %s" % [
		dir, "none — the export will fail" if have.is_empty() else " ".join(have)])


func _template_version() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "%d.%d.%d.%s" % [int(v["major"]), int(v["minor"]), int(v["patch"]), String(v["status"])]

extends Node
## THE LOOK, photographed. [P13]
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" \
##     $GODOT --path . --resolution 1920x1080 tests/render/frame_lab.tscn
##
## This is the iteration loop for art direction. It stands the real renderer up
## over the preview settlement (no simulation, no HUD, no lens), then walks a
## matrix of HOURS x ZOOMS and writes one PNG per cell into
## `artifacts/P13/frames/`. Judging the art means looking at those, not at the
## code that made them.
##
## Why a separate scene and not the harness: the harness photographs whatever
## the simulation actually contains and is *forbidden* from inventing a city
## (LcnWorldModel.preview_allowed). That is the right rule for evidence and the
## wrong rule for a paint pass, where you need the same city in every frame so a
## change to the shader is the only difference between two runs.
##
## It is also a TEST. Frames are graded numerically — see `_grade_frame` — and
## the suite fails when the ground goes flat, the frame goes grey, or night
## stops being darker than noon. Those three checks are the exact defects a
## critic named in the first two passes, expressed as numbers a run can fail on.

const OUT: String = "res://artifacts/P13/frames"
const SETTLE_FRAMES: int = 6

## hour name -> normalised day fraction (see LcnPalette.grade_at).
const HOURS: Array[Dictionary] = [
	{"name": "midday", "t": 0.50},
	{"name": "afternoon", "t": 0.63},
	{"name": "dusk", "t": 0.74},
	{"name": "night", "t": 0.86},
	{"name": "deep_night", "t": 0.00},
	{"name": "dawn", "t": 0.27},
]

## The zooms the camera actually reaches (game/view/camera/camera_tuning.gd:
## zoom_min 0.22, default 1.0, zoom_max 3.0). Art that only works at one of
## these is art that works nowhere.
const ZOOMS: Array[Dictionary] = [
	{"name": "close", "z": 1.60},
	{"name": "normal", "z": 0.85},
	{"name": "far", "z": 0.40},
	{"name": "strategic", "z": 0.24},
]

var _renderer: WorldRenderer = null
var _cam: Camera2D = null
var _centre: Vector2 = Vector2.ZERO
var _shots: Array[Dictionary] = []
var _cursor: int = 0
var _wait: int = 0
var _frame: int = 0
var _done: bool = false
var _report: Array[Dictionary] = []
var _only_hour: String = ""
## `--no-vfx` frees [P14]'s effects layer before the first capture. The frame lab
## exists to judge [P13]'s art, and a particle bug in another folder should not
## be able to hide or fake a ground pass.
var _no_vfx: bool = false


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--hour="):
			_only_hour = a.substr(7)
		elif a == "--no-vfx":
			_no_vfx = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for h: Dictionary in HOURS:
		if _only_hour != "" and String(h["name"]) != _only_hour:
			continue
		for z: Dictionary in ZOOMS:
			_shots.append({"hour": h, "zoom": z})


func _process(_delta: float) -> void:
	if _done:
		return
	_frame += 1
	if _frame == 1:
		_build_world()
		return
	if _renderer == null:
		print("frame_lab: no renderer could be installed")
		print("TESTS FAILED")
		_finish(1)
		return
	if _cursor >= _shots.size():
		_summarise()
		return
	var shot: Dictionary = _shots[_cursor]
	_aim(shot)
	if _wait < SETTLE_FRAMES:
		_wait += 1
		return
	_capture(shot)
	_wait = 0
	_cursor += 1


func _finish(code: int) -> void:
	_done = true
	get_tree().quit(code)


func _build_world() -> void:
	Rng.reset(7)
	SimClock.reset()
	var packed: PackedScene = load(LcnViewBootstrap.SCENE) as PackedScene
	if packed == null:
		return
	_renderer = packed.instantiate() as WorldRenderer
	if _renderer == null:
		return
	get_tree().root.add_child(_renderer)
	var model: LcnWorldModel = _renderer.world_model()
	model.attach()
	model.ensure_preview_settlement(model.world_size() / 2)
	_renderer.terrain.bind_world()
	_renderer.entities.bind_field(_renderer.terrain.field)
	if _renderer.terrain.field != null:
		_renderer.post.bind_heat_field(_renderer.terrain.field.heat_tex,
			Vector2(_renderer.terrain.field.size) * 32.0)
	_centre = Vector2(model.preview.centre) * 32.0 if model.preview != null \
		else Vector2(model.world_size()) * 16.0
	if _no_vfx:
		for n: Node in get_tree().get_nodes_in_group(&"lcn_vfx"):
			n.queue_free()
		print("frame_lab: vfx layer removed (--no-vfx)")
	print("frame_lab: %d structures, %d agents, world %s" % [
		model.building_count(), model.agent_count(), str(model.world_size())])


## The hour is driven through SimClock because that is what the renderer reads;
## poking the grade directly would photograph a lighting state the game cannot
## reach.
func _aim(shot: Dictionary) -> void:
	var hour: Dictionary = shot["hour"]
	var zoom: Dictionary = shot["zoom"]
	SimClock.tick = int(fposmod(float(hour["t"]) - 0.22, 1.0) * 40.0 * 20.0)
	if _cam == null:
		_cam = _find_camera(get_tree().root)
	if _cam != null:
		_cam.position = _centre
		_cam.zoom = Vector2(float(zoom["z"]), float(zoom["z"]))
		_cam.force_update_scroll()


func _capture(shot: Dictionary) -> void:
	var hour: Dictionary = shot["hour"]
	var zoom: Dictionary = shot["zoom"]
	var img: Image = get_viewport().get_texture().get_image()
	var stem: String = "%s_%s" % [hour["name"], zoom["name"]]
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT, stem]))
	var g: Dictionary = _grade_frame(img)
	g["shot"] = stem
	g["hour"] = hour["name"]
	g["zoom"] = zoom["name"]
	_report.append(g)
	print("  %-22s lum %.3f  detail %.4f  chroma %.3f  darkest %.3f  warm %.4f  flat %.2f" % [
		stem, g["lum"], g["detail"], g["chroma"], g["p05"], g["warm"], g["flat"]])


# ------------------------------------------------------------------ grading --

## Numbers a critic's eye produces, computed instead of asserted.
##
##   lum      mean luminance — "washed out" is a high mean with a low spread
##   detail   mean |luma - 3x3 box blur|, i.e. how much local structure the
##            ground actually has. A cloud-noise field scores near zero
##   chroma   mean |max(rgb) - min(rgb)|; a grey frame scores near zero
##   p05      5th-percentile luminance — how dark the frame is allowed to get
##   warm     fraction of pixels that are decisively warm (r well over b)
##   flat     fraction of 16x16 blocks with no variation in them at all
static func _grade_frame(img: Image) -> Dictionary:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var step: int = 2
	var luma: PackedFloat32Array = PackedFloat32Array()
	var cols: int = 0
	var rows: int = 0
	var sum_l: float = 0.0
	var sum_c: float = 0.0
	var warm: int = 0
	var n: int = 0
	var y: int = 0
	while y < h:
		var x: int = 0
		cols = 0
		while x < w:
			var c: Color = img.get_pixel(x, y)
			var l: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			luma.append(l)
			sum_l += l
			sum_c += maxf(maxf(c.r, c.g), c.b) - minf(minf(c.r, c.g), c.b)
			if c.r - c.b > 0.10 and c.r > 0.18:
				warm += 1
			n += 1
			cols += 1
			x += step
		rows += 1
		y += step

	# Local structure: how far each sample sits from the mean of its neighbours.
	var detail: float = 0.0
	var dn: int = 0
	for yy: int in range(1, rows - 1):
		for xx: int in range(1, cols - 1):
			var i: int = yy * cols + xx
			var m: float = (luma[i - cols - 1] + luma[i - cols] + luma[i - cols + 1]
				+ luma[i - 1] + luma[i + 1]
				+ luma[i + cols - 1] + luma[i + cols] + luma[i + cols + 1]) / 8.0
			detail += absf(luma[i] - m)
			dn += 1

	# FLATNESS. The fraction of 16x16-sample blocks whose luminance range is under
	# one 50th of the scale — i.e. blocks with nothing in them at all. This is the
	# one number that separates "the ground shader did not compile and Godot drew
	# the fallback white quad" from "the art is merely pale": a fallback quad is
	# literally constant, while even a washed-out snowfield is not. It cost a full
	# iteration to learn that a shader compile failure does not throw, does not
	# stop the frame, and still writes 24 plausible-looking PNGs.
	var flat: int = 0
	var blocks: int = 0
	var by: int = 0
	while by + 16 <= rows:
		var bx: int = 0
		while bx + 16 <= cols:
			var lo: float = 2.0
			var hi: float = -1.0
			for yy2: int in range(by, by + 16):
				var row: int = yy2 * cols
				for xx2: int in range(bx, bx + 16):
					var v: float = luma[row + xx2]
					lo = minf(lo, v)
					hi = maxf(hi, v)
			if hi - lo < 0.02:
				flat += 1
			blocks += 1
			bx += 16
		by += 16

	var sorted: PackedFloat32Array = luma.duplicate()
	sorted.sort()
	return {
		"flat": float(flat) / float(maxi(1, blocks)),
		"lum": sum_l / float(maxi(1, n)),
		"chroma": sum_c / float(maxi(1, n)),
		"detail": detail / float(maxi(1, dn)),
		"p05": sorted[int(float(sorted.size()) * 0.05)],
		"p95": sorted[int(float(sorted.size()) * 0.95)],
		"warm": float(warm) / float(maxi(1, n)),
	}


func _find(shot_name: String) -> Dictionary:
	for r: Dictionary in _report:
		if String(r["shot"]) == shot_name:
			return r
	return {}


func _summarise() -> void:
	var fails: Array[String] = []
	print("────────────────────────────────────────────────────────────────")
	print(" frame lab — %d frames in %s" % [_report.size(), OUT])
	print("────────────────────────────────────────────────────────────────")

	# 0. THE GROUND SHADER ACTUALLY COMPILED. A canvas shader that fails to
	#    compile does not throw and does not stop the frame: Godot falls back to
	#    the default material and the ground quad draws its 1x1 white texture, so
	#    the run still exits 0 and still writes 24 PNGs. This cost a full
	#    iteration — one undeclared identifier, a white plain, and a suite that
	#    reported it as "washed out" rather than as "broken".
	for f0: Dictionary in _report:
		if float(f0["flat"]) > 0.45 and float(f0["lum"]) > 0.50:
			fails.append("%s is a flat white quad — the ground shader did not compile (check the log for SHADER ERROR)"
				% f0["shot"])
			break

	# 1. THE GROUND HAS STRUCTURE. A soft cloud-noise field scores ~0.004 here;
	#    ground with tile-scale drift, rock and tracks scores several times that.
	#    Checked at `normal`, the zoom a player spends the game at.
	for hour: String in ["midday", "afternoon"]:
		var f: Dictionary = _find("%s_normal" % hour)
		if f.is_empty():
			continue
		if float(f["detail"]) < 0.012:
			fails.append("%s_normal has no local structure (detail %.4f < 0.012) — the ground is a cloud"
				% [hour, float(f["detail"])])

	# 2. THE FRAME IS NOT WASHED OUT. Washed out = everything crowded into the
	#    top of the range with no shadow anywhere in the picture.
	for f2: Dictionary in _report:
		if String(f2["hour"]) in ["midday", "afternoon", "dawn"] and String(f2["zoom"]) != "strategic":
			if float(f2["p05"]) > 0.30:
				fails.append("%s never gets dark (5th-percentile luma %.3f > 0.30) — washed out"
					% [f2["shot"], float(f2["p05"])])
			if float(f2["lum"]) > 0.62:
				fails.append("%s mean luma %.3f > 0.62 — the frame is a white field"
					% [f2["shot"], float(f2["lum"])])

	# 3. NIGHT IS DARK AND THE CITY IS THE WARM THING IN IT.
	var noon: Dictionary = _find("midday_normal")
	var night: Dictionary = _find("deep_night_normal")
	if not noon.is_empty() and not night.is_empty():
		if float(night["lum"]) > float(noon["lum"]) * 0.55:
			fails.append("deep night (%.3f) is not meaningfully darker than midday (%.3f)"
				% [float(night["lum"]), float(noon["lum"])])
		if float(night["warm"]) < 0.004:
			fails.append("deep night has almost no warm pixels (%.4f) — nothing is lit"
				% float(night["warm"]))

	# 4. THE WORLD IS COLD AND BLUE, NOT GREY.
	for f3: Dictionary in _report:
		if String(f3["zoom"]) == "normal" and float(f3["chroma"]) < 0.045:
			fails.append("%s is grey (chroma %.3f < 0.045) — no colour direction" % [
				f3["shot"], float(f3["chroma"])])

	for f4: String in fails:
		print("  FAIL  %s" % f4)
	if fails.is_empty():
		print("  every frame passes the structure / contrast / night / colour checks")
		print("TESTS PASSED")
		_finish(0)
	else:
		print("TESTS FAILED")
		_finish(1)


func _find_camera(n: Node) -> Camera2D:
	for c: Node in n.get_children():
		if c is Camera2D:
			return c
		var f: Camera2D = _find_camera(c)
		if f != null:
			return f
	return null

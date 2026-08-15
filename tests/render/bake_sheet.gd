extends SceneTree
## Art proof sheet. Bakes every procedural sprite and terrain tile and writes
## contact sheets to artifacts/P13/art/, so the art can be judged without
## launching the game.
##
##   godot --headless --path . --script tests/render/bake_sheet.gd

const OUT: String = "res://artifacts/P13/art"


func _initialize() -> void:
	LcnArtCache.set_enabled(false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var t0: int = Time.get_ticks_msec()

	_buildings_sheet()
	_agents_sheet()
	_terrain_sheet()
	_atlas_sheet()

	print("bake_sheet: done in %d ms" % (Time.get_ticks_msec() - t0))
	print(LcnArtCache.report())
	quit(0)


func _buildings_sheet() -> void:
	var f := LcnSpriteFactory.new()
	var archs: Array[StringName] = LcnSpriteFactory.archetypes()
	var cell := Vector2i(120, 150)
	var cols: int = 6
	var rows: int = int(ceil(float(archs.size()) / float(cols)))
	var sheet: Image = Image.create(cell.x * cols, cell.y * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.043, 0.071, 0.125, 1.0))
	for i: int in archs.size():
		var arch: StringName = archs[i]
		var s: Dictionary = f.building(arch)
		var tex: ImageTexture = s["texture"]
		var img: Image = tex.get_image()
		var ox: int = (i % cols) * cell.x + (cell.x - img.get_width()) / 2
		var oy: int = (i / cols) * cell.y + (cell.y - img.get_height()) - 8
		sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(ox, maxi(oy, 0)))
		print("  %-12s %dx%d  tiles=%s lift=%.0f" % [
			arch, img.get_width(), img.get_height(), str(s["tiles"]), float(s["lift"]),
		])
	sheet.save_png(ProjectSettings.globalize_path("%s/buildings.png" % OUT))


func _agents_sheet() -> void:
	var f := LcnSpriteFactory.new()
	# Townspeople on the top row, the ten designed enemies on the row below,
	# every sprite BOTTOM-ALIGNED on a common baseline so the sheet answers the
	# question a critic actually asks: does a 30 hp hound read as a different
	# creature from a 9000 hp boss, and does it read as a smaller one.
	var kinds: Array[StringName] = LcnSpriteFactory.AGENT_KINDS
	var foes: Array[StringName] = LcnSpriteFactory.ENEMY_KINDS
	var cols: int = maxi(kinds.size(), foes.size())
	var cw: int = 64
	var rh: int = 64
	var sheet: Image = Image.create(cw * cols, rh * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.043, 0.071, 0.125, 1.0))
	for i: int in kinds.size():
		var img: Image = (f.agent(kinds[i])["texture"] as ImageTexture).get_image()
		sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()),
			Vector2i(i * cw + (cw - img.get_width()) / 2, rh - img.get_height() - 8))
	for j: int in foes.size():
		var fi: Image = (f.agent(foes[j])["texture"] as ImageTexture).get_image()
		sheet.blend_rect(fi, Rect2i(Vector2i.ZERO, fi.get_size()),
			Vector2i(j * cw + (cw - fi.get_width()) / 2,
				rh * 2 - fi.get_height() - 8))
		print("  foe %-20s %dx%d" % [foes[j], fi.get_width(), fi.get_height()])
	sheet.save_png(ProjectSettings.globalize_path("%s/agents.png" % OUT))


## The ground is no longer tiles, so there is no tile sheet to dump. What there
## IS to check is the tone table the shader reads and the draw atlas every entity
## pass now binds — both of which a reviewer can look at without a GPU.
func _terrain_sheet() -> void:
	var field := LcnTerrainField.new()
	field.setup(Vector2i(64, 64), 235.0)
	var pal: Image = (field.palette_tex as ImageTexture).get_image()
	var sw: int = 96
	var sheet: Image = Image.create(sw * LcnPalette.TERRAIN_COUNT, sw, false, Image.FORMAT_RGBA8)
	for k: int in LcnPalette.TERRAIN_COUNT:
		var t: Dictionary = LcnPalette.terrain_tones(k)
		for y: int in sw:
			var band: Color = t["low"] if y < sw / 3 else (t["base"] if y < sw * 2 / 3 else t["high"])
			for x: int in sw:
				sheet.set_pixel(k * sw + x, y, band)
	sheet.save_png(ProjectSettings.globalize_path("%s/terrain_tones.png" % OUT))
	pal.save_png(ProjectSettings.globalize_path("%s/terrain_palette.png" % OUT))
	var noise: Image = (field.noise_tex as ImageTexture).get_image()
	noise.save_png(ProjectSettings.globalize_path("%s/field_noise.png" % OUT))
	print("  terrain: %d kinds, palette %dx%d, field noise %dx%d" % [
		LcnPalette.TERRAIN_COUNT, pal.get_width(), pal.get_height(),
		noise.get_width(), noise.get_height()])


## Contact sheet of the ONE texture every entity pass binds. If two archetypes
## are indistinguishable here they are indistinguishable in the game.
func _atlas_sheet() -> void:
	var f := LcnSpriteFactory.new()
	var a: Dictionary = f.atlas([])
	var img: Image = (a["texture"] as ImageTexture).get_image()
	img.save_png(ProjectSettings.globalize_path("%s/draw_atlas.png" % OUT))
	print("  draw atlas %dx%d, %d sprites" % [img.get_width(), img.get_height(),
		(a["regions"] as Dictionary).size()])

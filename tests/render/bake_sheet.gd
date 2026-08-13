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
	var kinds: Array[StringName] = [&"citizen", &"worker", &"soldier", &"swarm", &"brute"]
	var sheet: Image = Image.create(60 * kinds.size(), 60, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.043, 0.071, 0.125, 1.0))
	for i: int in kinds.size():
		var img: Image = (f.agent(kinds[i])["texture"] as ImageTexture).get_image()
		sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()),
			Vector2i(i * 60 + (60 - img.get_width()) / 2, 60 - img.get_height() - 10))
	var barrel: Image = (f.turret_barrel()["texture"] as ImageTexture).get_image()
	sheet.blend_rect(barrel, Rect2i(Vector2i.ZERO, barrel.get_size()), Vector2i(4, 4))
	sheet.save_png(ProjectSettings.globalize_path("%s/agents.png" % OUT))


func _terrain_sheet() -> void:
	var atlas := LcnTerrainAtlas.new()
	atlas.build()
	var img: Image = atlas.atlas_image()
	if img != null:
		img.save_png(ProjectSettings.globalize_path("%s/terrain_atlas.png" % OUT))
		print("  terrain atlas %dx%d, %d tiles" % [img.get_width(), img.get_height(), atlas.tile_count()])

extends SceneTree
## Authoring tool for [P01]: writes game/content/biomes/*.tres.
##
## The .tres files are the shipping content; this script is how they were made,
## kept in the repo so a balance change is a diff and not a click-path in the
## editor. Run it with:
##   godot --headless --path . --script tests/grid/gen_biomes.gd

const OUT_DIR: String = "res://game/content/biomes"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_write(_frozen_basin(), "frozen_basin")
	_write(_shattered_flats(), "shattered_flats")
	_write(_deep_rift(), "deep_rift")
	quit(0)


func _write(p: BiomeProfile, file: String) -> void:
	var path: String = "%s/%s.tres" % [OUT_DIR, file]
	var err: int = ResourceSaver.save(p, path)
	print("[gen_biomes] %s -> %s" % [path, "ok" if err == OK else "ERR %d" % err])


func _dep(kind: int, clusters: int, dmin: int, dmax: int, smin: int, smax: int, amount: int, spacing: int) -> DepositSpec:
	var d := DepositSpec.new()
	d.kind = kind
	d.clusters = clusters
	d.min_distance = dmin
	d.max_distance = dmax
	d.size_min = smin
	d.size_max = smax
	d.base_amount = amount
	d.spacing = spacing
	return d


## The campaign map. A ringed basin: safe warm centre, two ridge arcs to hold,
## and everything worth having on the far side of them.
func _frozen_basin() -> BiomeProfile:
	var p := BiomeProfile.new()
	p.id = &"frozen_basin"
	p.display_name = "Frozen Basin"
	p.description = "A dead caldera on the northern plain. The vents at its heart are the last warm ground for two hundred miles, and the ore that could save the city is all on the wrong side of the ridges."
	p.width = 256
	p.height = 256
	# Measured against tests/grid/probe_noise.gd: 0.66 is roughly the 89th
	# percentile of the ridged field, so ridges land near 10% of the plain and
	# the ring bias turns that into two clear arcs instead of a maze.
	p.ridge_threshold = 0.66
	p.chasm_threshold = 0.80
	p.rock_elevation = 196
	p.deposits = [
		_dep(Grid.Res.SCRAP, 14, 18, 74, 10, 22, 150, 12),
		_dep(Grid.Res.COAL, 16, 26, 118, 16, 40, 340, 15),
		_dep(Grid.Res.IRON, 14, 34, 122, 14, 36, 300, 16),
		_dep(Grid.Res.COPPER, 9, 52, 124, 12, 28, 260, 18),
		_dep(Grid.Res.SULFUR, 6, 66, 126, 10, 22, 220, 20),
	]
	return p


## Wide, open and generous. Almost no natural cover, so the walls have to be
## yours — but the far fields are the richest in the world.
func _shattered_flats() -> BiomeProfile:
	var p := BiomeProfile.new()
	p.id = &"shattered_flats"
	p.display_name = "Shattered Flats"
	p.description = "Glacier plain, flat to the horizon. Nothing out here will stop anything for you."
	p.width = 320
	p.height = 320
	p.rim_height = 0.72
	p.terrain_roughness = 0.30
	p.ridge_threshold = 0.80
	p.ridge_rings = 1.5
	p.ridge_ring_strength = 0.07
	p.chasm_threshold = 0.90
	p.lake_threshold = -0.18
	p.drift_threshold = 0.24
	p.rock_elevation = 205
	p.snow_base = 62
	p.lane_count = 7
	p.chokepoint_max_width = 13
	p.ruin_clusters = 6
	p.convoys = 11
	p.core_clear_radius = 24
	p.outer_vents = 4
	p.richness_gain = 8.5
	p.richness_exponent = 1.85
	p.deposits = [
		_dep(Grid.Res.SCRAP, 12, 20, 80, 10, 20, 140, 14),
		_dep(Grid.Res.COAL, 18, 30, 150, 18, 46, 360, 18),
		_dep(Grid.Res.IRON, 16, 40, 152, 16, 42, 320, 18),
		_dep(Grid.Res.COPPER, 11, 62, 154, 12, 30, 280, 20),
		_dep(Grid.Res.SULFUR, 8, 78, 156, 10, 24, 240, 22),
	]
	return p


## Broken ground. Three ways in and every one of them is a knife-edge, but the
## basin is poor and the good ore is a long, exposed haul away.
func _deep_rift() -> BiomeProfile:
	var p := BiomeProfile.new()
	p.id = &"deep_rift"
	p.display_name = "Deep Rift"
	p.description = "The ground here gave out long before the cold did. Chasms, ridges, and three roads that never should have been built."
	p.width = 224
	p.height = 224
	p.rim_height = 1.25
	p.terrain_roughness = 0.52
	p.ridge_frequency = 0.020
	p.ridge_threshold = 0.56
	p.ridge_rings = 3.5
	p.ridge_ring_strength = 0.20
	p.chasm_frequency = 0.026
	p.chasm_threshold = 0.70
	p.chasm_min_distance = 0.18
	p.rock_elevation = 178
	p.lane_count = 3
	p.lane_wobble = 0.42
	p.chokepoint_max_width = 7
	p.core_clear_radius = 19
	p.ruin_clusters = 11
	p.ruin_max_distance = 46
	p.convoys = 6
	p.outer_vents = 2
	p.richness_gain = 5.0
	p.richness_exponent = 1.55
	p.deposits = [
		_dep(Grid.Res.SCRAP, 16, 15, 62, 10, 24, 165, 10),
		_dep(Grid.Res.COAL, 13, 24, 100, 14, 34, 320, 13),
		_dep(Grid.Res.IRON, 12, 30, 104, 12, 32, 285, 14),
		_dep(Grid.Res.COPPER, 8, 46, 106, 10, 24, 250, 16),
		_dep(Grid.Res.SULFUR, 5, 58, 108, 9, 20, 210, 18),
	]
	return p

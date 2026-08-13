class_name BiomeProfile
extends Resource
## Every knob the world generator turns, as data. Drop a .tres in
## game/content/biomes/ and the Registry finds it — no code change, no shared list.
##
## The defaults below describe the campaign map: a frozen basin with a geothermal
## core at its centre, ridge arcs that break the plain into defensible rings, and
## ore that gets richer the further you push from the fire.

@export var id: StringName = &"frozen_basin"
@export var display_name: String = "Frozen Basin"
@export_multiline var description: String = ""

@export_group("Size")
@export var width: int = 256
@export var height: int = 256
## Impassable world edge. Must be >= 1: the pathfinder relies on it.
@export var border_thickness: int = 2

@export_group("Elevation")
@export var rim_height: float = 1.0
@export var terrain_roughness: float = 0.40
@export var elevation_frequency: float = 0.0085
@export var elevation_octaves: int = 4
@export var basin_exponent: float = 1.35
@export var rock_elevation: int = 168

@export_group("Ridges and chasms")
@export var ridge_frequency: float = 0.016
@export var ridge_threshold: float = 0.66
## Concentric bias: ridges clump into arcs at these many rings out from the core.
@export var ridge_rings: float = 2.5
@export var ridge_ring_strength: float = 0.14
@export var ridge_min_distance: float = 0.13
@export var chasm_frequency: float = 0.021
@export var chasm_threshold: float = 0.80
@export var chasm_min_distance: float = 0.24

@export_group("Ground cover")
@export var lake_frequency: float = 0.013
@export var lake_threshold: float = -0.28
@export var drift_frequency: float = 0.045
@export var drift_threshold: float = 0.34
@export var snow_base: int = 44
@export var snow_drift: int = 72
@export var snow_cap: int = 235

@export_group("Geothermal core")
@export var core_radius: int = 7
@export var ash_radius: int = 15
@export var core_clear_radius: int = 21
@export var core_vents: int = 5
@export var vent_output: int = 900
@export var outer_vents: int = 3
@export var outer_vent_min_distance: int = 46
@export var outer_vent_max_distance: int = 104
@export var outer_vent_output: int = 2200

@export_group("Roads and approach lanes")
@export var lane_count: int = 5
@export var lane_wobble: float = 0.30
@export var lane_valley_bias: float = 0.0022
@export var chokepoint_max_width: int = 9
@export var chokepoint_scan: int = 14
## Isolated walkable pockets this big or bigger get a pass carved to the city.
@export var min_pocket: int = 60
@export var connect_search_radius: int = 90
@export var convoys: int = 8
@export var convoy_length_min: int = 4
@export var convoy_length_max: int = 12
@export var convoy_scrap_min: int = 90
@export var convoy_scrap_max: int = 260

@export_group("Ruins")
@export var ruin_clusters: int = 9
@export var ruin_min_distance: int = 12
@export var ruin_max_distance: int = 54
@export var ruin_blocks_min: int = 4
@export var ruin_blocks_max: int = 9
@export var ruin_block_size_min: int = 3
@export var ruin_block_size_max: int = 7
@export var ruin_scrap_chance: float = 0.42
@export var ruin_scrap_min: int = 55
@export var ruin_scrap_max: int = 210

@export_group("Deposits")
@export var deposits: Array[DepositSpec] = []
## Yield multiplier at the map rim is 1 + richness_gain.
@export var richness_gain: float = 6.0
@export var richness_exponent: float = 1.70


## Campaign defaults, used when no .tres has been authored yet.
static func fallback() -> BiomeProfile:
	var p := BiomeProfile.new()
	p.deposits = [
		_spec(Grid.Res.SCRAP, 14, 18, 70, 10, 22, 150, 12),
		_spec(Grid.Res.COAL, 16, 26, 118, 16, 40, 340, 15),
		_spec(Grid.Res.IRON, 14, 34, 122, 14, 36, 300, 16),
		_spec(Grid.Res.COPPER, 9, 52, 124, 12, 28, 260, 18),
		_spec(Grid.Res.SULFUR, 6, 66, 126, 10, 22, 220, 20),
	]
	return p


static func _spec(kind: int, clusters: int, dmin: int, dmax: int, smin: int, smax: int, amount: int, spacing: int) -> DepositSpec:
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

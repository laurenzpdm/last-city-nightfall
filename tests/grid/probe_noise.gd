extends SceneTree
## Throwaway calibration probe: prints the distribution of the ridged noise the
## generator thresholds against, so the biome numbers are measured, not guessed.


func _initialize() -> void:
	for cfg: Array in [["ridge", 0.016, 3], ["chasm", 0.021, 2]]:
		var n := FastNoiseLite.new()
		n.seed = 12345
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = float(cfg[1])
		n.fractal_octaves = int(cfg[2])
		n.fractal_type = FastNoiseLite.FRACTAL_RIDGED
		var vals: PackedFloat32Array = PackedFloat32Array()
		for y: int in range(256):
			for x: int in range(256):
				vals.append(n.get_noise_2d(float(x), float(y)))
		vals.sort()
		var out: PackedStringArray = PackedStringArray()
		for p: float in [0.50, 0.70, 0.80, 0.85, 0.90, 0.94, 0.97, 0.99]:
			out.append("p%d=%.3f" % [int(p * 100.0), vals[int(float(vals.size() - 1) * p)]])
		print("%s: min=%.3f max=%.3f %s" % [cfg[0], vals[0], vals[vals.size() - 1], " ".join(out)])
	quit(0)

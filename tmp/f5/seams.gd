extends Node
## F5 probe: where the ground actually is. Prints, for every 3x3 drill site in a
## window around the core, the richest deposit kind under the footprint — which
## is exactly what ProductionSystem._acquire_seam reads.

const KINDS: Array[String] = ["", "scrap", "coal", "iron_ore", "copper_ore", "sulfur", "vent"]


func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var grid: Object = sim.call("get_system", &"grid")
	var core: Vector2i = grid.call("core_cell")
	print("CORE ", core)
	# Best 3x3 site per kind, by total amount, over a 90x90 window.
	var best: Dictionary = {}
	for oy: int in range(-46, 47):
		for ox: int in range(-46, 47):
			var origin: Vector2i = core + Vector2i(ox, oy)
			var tally: Dictionary = {}
			for dy: int in 3:
				for dx: int in 3:
					var c: Vector2i = origin + Vector2i(dx, dy)
					var k: int = int(grid.call("resource_kind_at", c))
					if k <= 0 or k >= KINDS.size() or KINDS[k] == "":
						continue
					var a: int = int(grid.call("resource_amount_at", c))
					tally[k] = int(tally.get(k, 0)) + a
			for k2: int in tally:
				var cur: Array = best.get(k2, [0, Vector2i.ZERO])
				if int(tally[k2]) > int(cur[0]):
					best[k2] = [int(tally[k2]), origin]
	for k3: int in best:
		var e: Array = best[k3]
		var o: Vector2i = e[1]
		print("BEST %-11s amount=%d origin=(%d,%d) delta=(%d,%d) dist=%d" % [
			KINDS[k3], int(e[0]), o.x, o.y, o.x - core.x, o.y - core.y,
			maxi(absi(o.x - core.x), absi(o.y - core.y))])
	# Every viable 3x3 site (>= 300 under the footprint), nearest first, for the
	# kinds a factory actually needs.
	for want: int in [6]:
		var sites: Array = []
		for oy2: int in range(-44, 45):
			for ox2: int in range(-44, 45):
				var origin2: Vector2i = core + Vector2i(ox2, oy2)
				var total: int = 0
				for dy2: int in 3:
					for dx2: int in 3:
						var c2: Vector2i = origin2 + Vector2i(dx2, dy2)
						if int(grid.call("resource_kind_at", c2)) == want:
							total += int(grid.call("resource_amount_at", c2))
				if total >= 120:
					sites.append([maxi(absi(ox2), absi(oy2)), ox2, oy2, total])
		sites.sort_custom(func(a, b): return a[0] < b[0] if a[0] != b[0] else a[3] > b[3])
		var shown: int = 0
		var seen: Array[Vector2i] = []
		for s: Array in sites:
			var o3: Vector2i = Vector2i(int(s[1]), int(s[2]))
			var near_other: bool = false
			for t: Vector2i in seen:
				if absi(t.x - o3.x) < 4 and absi(t.y - o3.y) < 4:
					near_other = true
					break
			if near_other:
				continue
			seen.append(o3)
			print("SITE %-11s dist=%2d delta=(%d,%d) cell=(%d,%d) amount=%d" % [
				KINDS[want], int(s[0]), o3.x, o3.y, core.x + o3.x, core.y + o3.y, int(s[3])])
			shown += 1
			if shown >= 14:
				break
	get_tree().quit()

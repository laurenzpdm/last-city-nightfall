extends SceneTree
## Scratch probe: how a smelter on a fresh hearth grid warms up over time.

func _initialize() -> void:
	var sim: Node = root.get_node_or_null("/root/Sim")
	var clock: Node = root.get_node_or_null("/root/SimClock")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var prod: Object = sim.call("get_system", &"production")
	prod.call("set_staffing_autarky", true)
	var heat: Object = sim.call("get_system", &"heat")
	var o := Vector2i(60, 60)
	sim.call("submit_command", {"system": &"build", "op": "add_stock",
		"items": {"iron_ore": 9000, "iron_plate": 9000, "coal": 9000}})
	sim.call("submit_command", {"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [o.x, o.y], "free": true, "instant": true})
	clock.call("advance", 1)
	sim.call("submit_command", {"system": &"build", "op": "place_line", "kind": "heat_pipe",
		"from": [o.x + 5, o.y + 2], "to": [o.x + 16, o.y + 2], "free": true, "instant": true})
	clock.call("advance", 1)
	sim.call("submit_command", {"system": &"build", "op": "place", "kind": "smelter",
		"cell": [o.x + 17, o.y + 1], "free": true, "instant": true})
	sim.call("submit_command", {"system": &"build", "op": "place", "kind": "workshop",
		"cell": [o.x + 17, o.y - 2], "free": true, "instant": true})
	clock.call("advance", 2)
	var ms: Dictionary = prod.get("machines")
	var keys: Array = ms.keys()
	keys.sort()
	for t: int in [20, 60, 150, 300, 600, 1200, 2400]:
		clock.call("advance", t - int(clock.get("tick")))
		for k: int in keys:
			var m: Object = ms[k]
			print("t=%5d %-10s rate %.3f cold %.3f hf %.3f pw %.3f felt %.2f amb %.2f warm %.2f reason '%s' out %d" % [
				t, String(m.get("kind")), m.get("rate"), m.get("cold"), m.get("heat_factor"),
				m.get("power"), m.get("felt_c"), heat.call("ambient"),
				heat.call("warmth_at", m.get("center_cell")), String(m.get("reason")),
				m.call("output_total")])
	print("produced ", prod.call("serialize")["produced"])
	quit(0)

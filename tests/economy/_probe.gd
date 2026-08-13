extends SceneTree
## Throwaway probe. Not a suite (no test_/run_ prefix), invisible to the gate.
## Compiled before the autoloads exist, so everything is reached through load().

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var B: Script = load("res://game/sim/economy/balance.gd")
	var registry: Node = root.get_node("/root/Registry")
	print("economy ids=", registry.call("ids", "economy"))
	var t: Resource = B.call("table")
	print("table id=", t.get("id"), " ", t.get("display_name"))
	var c: Resource = B.call("curve")
	print("curve id=", c.get("id"), " days=", c.call("days"))
	print("starting stock=", B.call("starting_stock"))
	for d: int in range(1, 11):
		print("  day %d budget=%.0f lanes=%d" % [d, B.call("threat_budget", d), B.call("threat_lanes", d)])
	print("research t1: ", B.call("research_cost", 1, 0), " ", B.call("research_cost", 1, 3),
		" t2: ", B.call("research_cost", 2, 0))
	print("--- economics")
	for id: StringName in registry.call("ids", "buildings"):
		var def: Resource = registry.call("get_item", "buildings", id)
		var e: Dictionary = B.call("economics_of", def)
		print(" %-22s t%d pts=%7.1f /cell=%6.2f out=%6.1f in=%5.1f ppho=%6.2f pphi=%7.2f bs=%6.1f thr=%5.1f" % [
			String(id), int(e["tier"]), float(e["points"]), float(e["points_per_cell"]),
			float(e["heat_out"]), float(e["heat_in"]), float(e["points_per_heat_out"]),
			float(e["points_per_heat_in"]), float(e["build_seconds"]), float(e["throughput"])])
	print("--- audit")
	var findings: Array = B.call("audit")
	for f: Variant in findings:
		print("  ", String((f as Dictionary)["text"]))
	print("audit findings: ", findings.size())
	print("--- research audit")
	for f: Variant in B.call("audit_research"):
		print("  ", String((f as Dictionary)["text"]))
	print("--- threat audit")
	for f: Variant in B.call("audit_threat"):
		print("  ", String((f as Dictionary)["text"]))
	print("--- coverage")
	var cov: Dictionary = B.call("audit_coverage")
	var keys: Array = cov.keys(); keys.sort()
	for k: Variant in keys:
		print("  %-22s %s" % [String(k), ",".join(cov[k])])
	quit(0)
	return true

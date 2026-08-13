extends SceneTree
## Throwaway probe. Not a suite (no test_/run_ prefix), invisible to the gate.

func _initialize() -> void:
	print("registry loaded=", Registry.loaded, " economy ids=", Registry.ids("economy"))
	var t: BalanceTable = Balance.table()
	print("table id=", t.id, " display=", t.display_name)
	var c: DifficultyCurve = Balance.curve()
	print("curve id=", c.id, " days=", c.days())
	print("starting stock=", Balance.starting_stock())
	print("threat d1..d10:")
	for d: int in range(1, 11):
		print("  day %d budget=%.0f lanes=%d" % [d, Balance.threat_budget(d), Balance.threat_lanes(d)])
	print("research t1: ", Balance.research_cost(1, 0), " ", Balance.research_cost(1, 3),
		" t2: ", Balance.research_cost(2, 0))
	print("--- economics")
	for id: StringName in Registry.ids("buildings"):
		var def: BuildingDef = Registry.get_item("buildings", id) as BuildingDef
		var e: Dictionary = Balance.economics_of(def)
		print(" %-22s t%d pts=%7.1f /cell=%6.2f out=%6.1f in=%5.1f ppho=%6.2f pphi=%7.2f bs=%6.1f thr=%5.1f" % [
			String(id), int(e["tier"]), float(e["points"]), float(e["points_per_cell"]),
			float(e["heat_out"]), float(e["heat_in"]), float(e["points_per_heat_out"]),
			float(e["points_per_heat_in"]), float(e["build_seconds"]), float(e["throughput"])])
	print("--- audit")
	var findings: Array[Dictionary] = Balance.audit()
	for f: Dictionary in findings:
		print("  ", String(f["text"]))
	print("audit findings: ", findings.size())
	quit(0)

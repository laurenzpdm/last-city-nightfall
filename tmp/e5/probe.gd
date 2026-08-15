extends Node
## E5 probe: seed the opening settlement exactly as boot does, tick, and print
## the picture the opening screen would show.

func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var build: Object = sim.call("get_system", &"build")
	var grid: Object = sim.call("get_system", &"grid")
	var core: Vector2i = grid.call("core_cell")
	var refusals: PackedStringArray = PackedStringArray()
	for cmd: Dictionary in load("res://game/boot.gd").call("opening_commands", core):
		if String(cmd.get("system", "build")) != "build":
			sim.call("submit_command", cmd)
			continue
		var r: Dictionary = build.call("execute", cmd)
		if not bool(r.get("ok", false)):
			refusals.append("%s %s %s: %s" % [str(cmd.get("op","?")), str(cmd.get("kind","?")), str(cmd.get("cell", cmd.get("from",""))), str(r.get("reason",""))])
	print("REFUSALS: ", refusals)
	var marks: Array[int] = [1, 20, 100, 600, 2000, 6000]
	var at: int = 0
	for m: int in marks:
		clock.call("advance", m - at)
		at = m
		_dump(sim, m)
	get_tree().quit()


func _dump(sim: Node, t: int) -> void:
	var heat: Object = sim.call("get_system", &"heat")
	var out: Dictionary = {"t": t}
	var nets: Array = []
	for nid: int in heat.call("network_ids"):
		var st: Dictionary = heat.call("network_stats", nid)
		nets.append({"id": nid, "supply": st.get("supply"), "demand": st.get("demand"),
			"deficit": st.get("deficit"), "starved": st.get("starved"),
			"brownouts": st.get("brownouts"), "consumers": st.get("consumers"),
			"nodes": st.get("nodes")})
	out["nets"] = nets
	out["heat"] = heat.call("totals")
	var bs: Object = sim.call("get_system", &"build")
	var odd: Array = []
	for b: BuildingInstance in bs.call("all_buildings"):
		if b.kind == &"heat_pipe":
			continue
		var row: Dictionary = {"kind": str(b.kind), "cell": str(b.cell),
			"net": heat.call("network_of", b.id), "pf": heat.call("power_factor", b.id),
			"frozen": heat.call("is_frozen", b.id), "fuel": heat.call("fuel_stock_of", b.id),
			"bn": heat.call("bottleneck_of", b.id), "state": b.state, "workers": b.workers}
		odd.append(row)
	out["b"] = odd
	var prod: Object = sim.call("get_system", &"production")
	if prod != null:
		out["stalled"] = prod.call("stalled_machines")
	var logi: Object = sim.call("get_system", &"logistics")
	if logi != null:
		var m: Dictionary = logi.call("metrics")
		out["logi"] = {"burners_short": m.get("burners_short"), "line_dry": m.get("line_dry")}
	var combat: Object = sim.call("get_system", &"combat")
	if combat != null:
		out["turrets"] = combat.call("turret_count")
	var cit: Object = sim.call("get_system", &"citizens")
	if cit != null:
		var cm: Dictionary = cit.call("metrics")
		out["cit"] = {"pop": cm.get("population"), "freezing": cm.get("freezing"),
			"idle": cm.get("idle"), "avg_warmth": cm.get("avg_warmth")}
	print("=== ", JSON.stringify(out))

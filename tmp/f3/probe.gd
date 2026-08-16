extends Node
## F3 probe: seed boot's opening settlement, tick, and print the fuel/freeze
## picture the player would live through unattended.

func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var build: Object = sim.call("get_system", &"build")
	var grid: Object = sim.call("get_system", &"grid")
	var core: Vector2i = grid.call("core_cell")
	var refusals: PackedStringArray = PackedStringArray()
	clock.call("advance", 1)
	for cmd: Dictionary in load("res://game/boot.gd").call("opening_commands", core):
		var r: Dictionary = build.call("execute", cmd)
		if not bool(r.get("ok", false)):
			refusals.append("%s %s %s: %s" % [str(cmd.get("op","?")), str(cmd.get("kind","?")),
				str(cmd.get("cell", cmd.get("from",""))), str(r.get("reason",""))])
	print("REFUSALS: ", refusals)
	clock.call("advance", 1)
	print("DEFECTS: ", load("res://game/boot.gd").call("opening_defects"))
	var at: int = 0
	for m: int in [1, 100, 600, 1200, 2400, 3600, 4320, 5400, 6600, 7800, 9600, 12000]:
		clock.call("advance", m - at)
		at = m
		_dump(sim, m)
	get_tree().quit()


func _dump(sim: Node, t: int) -> void:
	var heat: Object = sim.call("get_system", &"heat")
	var build: Object = sim.call("get_system", &"build")
	var row: Dictionary = {"t": t}
	row["heat"] = heat.call("totals")
	var stock: Object = build.get("stock")
	var st: Dictionary = {}
	for it: StringName in [&"coal", &"timber", &"scrap", &"stone", &"iron_ore", &"iron_plate", &"grain", &"ration"]:
		st[String(it)] = int(stock.call("count", it))
	row["stock"] = st
	var frozen: PackedStringArray = PackedStringArray()
	var fuels: Dictionary = {}
	for b: BuildingInstance in build.call("all_buildings"):
		if b.kind == &"heat_pipe":
			continue
		if bool(heat.call("is_frozen", b.id)):
			frozen.append("%s%s" % [str(b.kind), str(b.cell)])
		if b.def != null and b.def.heat_produced > 0.0:
			fuels[str(b.kind)] = snappedf(float(heat.call("fuel_stock_of", b.id)), 0.1)
	row["frozen"] = Array(frozen)
	row["burner_fuel"] = fuels
	var cit: Object = sim.call("get_system", &"citizens")
	if cit != null:
		var cm: Dictionary = cit.call("metrics")
		row["cit"] = {"pop": cm.get("population"), "warmth": cm.get("avg_warmth"),
			"staffed": cm.get("staffed"), "dead": cm.get("deaths")}
	var prod: Object = sim.call("get_system", &"production")
	if prod != null:
		var pm: Dictionary = prod.call("metrics")
		row["prod"] = {"crafts": pm.get("crafts_total"), "produced": pm.get("produced")}
	print("### ", JSON.stringify(row))

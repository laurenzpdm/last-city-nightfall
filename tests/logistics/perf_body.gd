extends RefCounted
## [P03] Bench body. Loaded by path from perf_probe.gd once the autoloads exist.

func run() -> void:
	Log.min_level = Log.Level.WARN
	diag_tunnel()
	_throughput()
	_scale()


func _fresh() -> LogisticsSystem:
	SimClock.set_manual(true)
	Sim.create_world(7)
	return Sim.get_system(&"logistics") as LogisticsSystem


func _throughput() -> void:
	print("")
	print("-- throughput (measured over 10 in-world seconds, saturated source) --")
	print(" belt          tooltip   measured")
	for kind: String in ["belt_mk1", "belt_mk2", "belt_mk3"]:
		var logi: LogisticsSystem = _fresh()
		Sim.submit_command({"system": &"build", "op": "grant_unlock", "unlock": "belt_gearing"})
		Sim.submit_command({"system": &"build", "op": "grant_unlock", "unlock": "driven_rollers"})
		SimClock.advance(1)
		var o := Vector2i(40, 40)
		for i: int in 12:
			logi.place(StringName(kind), o + Vector2i(i, 0), 0, true)
		var chest: Dictionary = logi.place(&"crate", o + Vector2i(12, 0), 0, true)
		var store: LogiStore = logi.world.stores[int(chest["id"])]
		for _i: int in 200:
			_feed(logi, o)
			SimClock.advance(1)
		store.clear()
		for _i: int in 200:
			_feed(logi, o)
			SimClock.advance(1)
		var def: LogiDef = logi.def_of(StringName(kind))
		print(" %-13s %6.1f   %6.1f items/s" % [kind, def.belt_rate(), float(store.total()) / 10.0])


func _feed(logi: LogisticsSystem, cell: Vector2i) -> void:
	for lane: int in 2:
		var guard: int = 0
		while logi.world.push_onto_belt(cell, lane, &"coal") and guard < 8:
			guard += 1


## A factory that is big enough to be a real answer: 40 lines of 24 belts, a
## splitter and an arm on each, all of them saturated and moving.
func _scale() -> void:
	var logi: LogisticsSystem = _fresh()
	var lines: int = 40
	var length: int = 24
	var entries: Array[Vector2i] = []
	for l: int in lines:
		var o := Vector2i(20, 20 + l * 3)
		for i: int in length:
			logi.place(&"belt_mk1", o + Vector2i(i, 0), 0, true)
		logi.place(&"crate", o + Vector2i(length, 0), 0, true)
		logi.place(&"inserter_mk1", o + Vector2i(length / 2, 1), 3, true)
		logi.place(&"crate", o + Vector2i(length / 2, 2), 0, true)
		entries.append(o)

	for _i: int in 200:
		for e: Vector2i in entries:
			_feed(logi, e)
		SimClock.advance(1)

	var samples: int = 400
	var t0: int = Time.get_ticks_usec()
	for _i: int in samples:
		for e: Vector2i in entries:
			_feed(logi, e)
		SimClock.advance(1)
	var us: int = Time.get_ticks_usec() - t0

	var m: Dictionary = logi.metrics()
	print("")
	print("-- scale --")
	print(" entities        %d (%d belt tiles, %d lines)" % [
		logi.world.entity_ids.size(), lines * length, logi.world.segment_ids.size()])
	print(" items on belts  %d" % int(m["items_on_belts"]))
	print(" throughput      %.1f items/s across the map" % float(m["throughput"]))
	print(" whole tick      %.3f ms  (every system in the build)" % (float(us) / float(samples) / 1000.0))

	# The same measurement with only logistics stepping, so the number is ours.
	var only: int = Time.get_ticks_usec()
	for _i: int in samples:
		logi.step(SimClock.tick)
	var only_us: int = Time.get_ticks_usec() - only
	print(" logistics.step  %.3f ms" % (float(only_us) / float(samples) / 1000.0))


## One-off diagnostic: what happens to an underground pair.
func diag_tunnel() -> void:
	var logi: LogisticsSystem = _fresh()
	var o := Vector2i(40, 40)
	for i: int in 4:
		logi.place(&"belt_mk1", o + Vector2i(i, 0), 0, true)
	var a: Dictionary = logi.place(&"underground_mk1", o + Vector2i(4, 0), 0, true)
	var b: Dictionary = logi.place(&"underground_mk1", o + Vector2i(8, 0), 0, true)
	print(" place a: %s" % str(a))
	print(" place b: %s" % str(b))
	SimClock.advance(1)
	var ea: LogiEntity = logi.entity_at(o + Vector2i(4, 0))
	var eb: LogiEntity = logi.entity_at(o + Vector2i(8, 0))
	print(" a: role=%d pair=%d entrance=%s seg=%d" % [ea.role(), ea.pair_id, str(ea.is_entrance), ea.seg_id])
	print(" b: role=%d pair=%d entrance=%s seg=%d" % [eb.role(), eb.pair_id, str(eb.is_entrance), eb.seg_id])
	print(" segments: %d" % logi.world.segment_ids.size())
	for sid: int in logi.world.segment_ids:
		var s: LogiSegment = logi.world.segments[sid]
		print("   seg %d %s entry %s exit %s len %.1f tunnel %s sink %d" % [
			sid, s.kind, str(s.entry_cell), str(s.exit_cell), s.length, str(s.is_tunnel), s.sink])

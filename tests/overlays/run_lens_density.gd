extends Node
## [P19] HOW MANY WORDS ARE ON THE SCREEN, COUNTED, AT THE ZOOM THE GAME IS
## PLAYED AT.
##
##   godot --headless --path . res://tests/overlays/run_lens_density.tscn
##
## A critic counted ONE frame of `first_night` at zoom 0.70 by hand and found:
## 24 temperature chips and 17 "no crew" chips printed through each other, a
## vertical ladder of 22 identical "building" chips down the middle of the
## screen, `SURVIVAL LINE -10°C` stamped three times on one closed contour, and
## the world badge `= GRID 3 0/0 heat/s NO SOURCE` reading straight through the
## clock panel with `| GRID 1 47/47 heat/s` on the "2:21" numeral. Legibility
## went from 5 to 3. Their word for the frame was "a crash dump".
##
## They were right, and the reason it reached them is that no number anywhere in
## this build described what a frame contained. Six lenses each had their own
## private cap — `MAX_LABELS`, `LABELS_PER_LINE`, `shown < 14` — and every one of
## them was individually reasonable. So this suite exists to make the count a
## number the build asserts about itself, on every gate run, forever.
##
## WHAT IT DOES. It draws the real lenses — the real `_draw()`, the real fonts,
## the real `LcnLabelField` — over a synthetic city built to BE the frame that
## was counted: a 22-deep ladder of construction sites, a block of 24 buildings
## with real temperatures and no crew, three of them frozen, two heat grids, and
## [P17]'s clock panel sitting in the world exactly where a 1920x1080 frame puts
## it. Then, at zoom 0.50, 0.60 and 0.70, for every one of the six lenses plus
## the always-on status layer, it counts:
##
##   chips       words actually painted into the world
##   marks       badges and glyphs holding pixels
##   overlaps    pairs of those that intersect — MUST BE ZERO
##   on chrome   words standing on the interface — MUST BE ZERO
##   repeat      the most times any one string appears
##
## WHY THE NUMBERS ARE BELIEVABLE. Every measurement is taken twice: once with
## the arbiter on and once with `field.enforce = false`, which records every
## request and refuses none. The second pass is the OLD BEHAVIOUR, and the suite
## fails if it does not reproduce the defect — if the bypass frame is clean, then
## the city this suite built was never crowded, the assertions never had anything
## to bite on, and a green here would mean nothing at all. That check is the
## whole difference between this suite and one that passes because its
## precondition was never met.

const TAG: String = "overlay-density"
const TILE: float = 32.0
const SCREEN := Vector2(1920.0, 1080.0)
## [P17]'s clock panel in `artifacts/CRIT/shots/build.png`, in screen pixels.
const CLOCK_PANEL := Rect2(735.0, 8.0, 500.0, 205.0)
const ZOOMS: Array[float] = [0.50, 0.60, 0.70]
## The most times one string may appear in a frame. Two is a concession to a
## lens that legitimately names two of a thing; three was the survival line.
const MAX_REPEAT: int = 2

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://artifacts/p19_density"

var _snap: LcnOverlaySnapshot = null
var _pal: LcnOverlayPalette = null
var _field: LcnLabelField = null
var _icons: LcnStatusIcons = null
var _lenses: Dictionary[int, LcnOverlayLayer] = {}
var _rows: Array[Dictionary] = []


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	var watchdog := Timer.new()
	watchdog.wait_time = 90.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the lens density suite timed out after 90 s")
	get_tree().quit(125)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)


func _run() -> void:
	_build_city()
	_build_layers()
	await _suite_the_city_is_actually_crowded()
	await _suite_density_at_every_played_zoom()
	await _suite_the_named_defects_are_gone()

	_report()
	var verdict: String = "TESTS PASSED" if _failures.is_empty() else "TESTS FAILED"
	for f: String in _failures:
		Log.error(TAG, f)
	print("%s — %d checks, %d failures" % [verdict, _checks, _failures.size()])
	_write_report(verdict)
	get_tree().quit(mini(_failures.size(), 125))


# =========================================================================
# the city — the frame the critic counted, rebuilt so it can be counted again
# =========================================================================

func _build_city() -> void:
	_snap = LcnOverlaySnapshot.new()
	_snap.ambient_c = -26.0
	_snap.last_tick = 9000

	# The ladder: 22 construction sites straight down the middle, the exact
	# shape that came out as "building building buildinginginging". The top of it
	# sits UNDER THE CLOCK on purpose, so the keep-out rule has something to
	# refuse and `culled_chrome` is a number this suite can prove is non-zero.
	for i: int in 22:
		var b: int = _building(&"heat_pipe", 128, 94 + i, 1, 1,
			LcnOverlaySnapshot.B_GHOST, 1.0, 2, 0)
		_snap.bld_progress[b] = 0.1 + 0.03 * float(i)
		_heat_node(b, LcnOverlayDefs.F_CONDUIT, 1.0, 4.0 + float(i), 1)

	# The district: 24 workshops on a 6x4 grid, every one of them with a real
	# internal temperature, seventeen of them short of crew, three frozen solid.
	var n: int = 0
	for gy: int in 4:
		for gx: int in 6:
			var x: int = 118 + gx * 4
			var y: int = 120 + gy * 4
			var need: int = 4
			var have: int = 4 if n % 24 >= 17 else 0      # 17 short of crew
			var b2: int = _building(&"workshop", x, y, 2, 2, 0, 1.0, need, have)
			var flags: int = LcnOverlayDefs.F_CONSUMER
			var frozen: bool = n == 3 or n == 11 or n == 19
			if frozen:
				flags |= LcnOverlayDefs.F_FROZEN
			var temp: float = -13.0 if frozen else 5.0 + float(n) * 1.6
			_heat_node(b2, flags, 0.4 if n % 3 == 0 else 1.0, temp,
				1 if gx < 3 else 5)
			n += 1

	# Two grids, so the network lens has two badges and two balance sheets — the
	# pair that landed on the clock in the reference frame.
	_network(1, 0, 164.0, 202.0, 3)
	_network(5, 1, 0.0, 12.0, 0)

	# A bottleneck and an orphan, so the bottleneck lens has verdicts to place.
	_snap.bottlenecks = [
		{"node": _snap.node_id[24], "reason": "capacity", "load": 47.0,
			"capacity": 47.0, "consumers": 9},
		{"node": _snap.node_id[26], "reason": "supply", "consumers": 4},
	]
	_snap.node_flags[30] |= LcnOverlayDefs.F_NO_NETWORK
	_snap.node_flags[31] |= LcnOverlayDefs.F_NO_NETWORK
	_snap.node_flags[32] |= LcnOverlayDefs.F_NO_NETWORK
	_snap.node_flags[33] |= LcnOverlayDefs.F_NO_NETWORK

	# The warmth field, with a genuine closed contour around the hearth — the
	# shape that produced three `SURVIVAL LINE` labels on one loop.
	_build_warmth()

	# Two generators with empty bunkers, so the logistics lens has an "OUT OF
	# FUEL" verdict and the status layer has a fuel alarm — and four gun mounts
	# with real reach, so the coverage lens has range figures to place.
	for k: int in 2:
		var g: int = _building(&"coal_generator", 112, 122 + k * 6, 2, 2, 0, 1.0, 2, 2)
		_heat_node(g, LcnOverlayDefs.F_PRODUCER | LcnOverlayDefs.F_STARVED_FUEL,
			1.0, 18.0, 1)
		_snap.node_fuel[_snap.node_count - 1] = 0.0
	for t: int in 4:
		var gun: int = _building(&"gun_mount", 144, 118 + t * 5, 2, 2,
			LcnOverlaySnapshot.B_TURRET, 1.0, 1, 1)
		_snap.bld_reach[gun] = 9.0 + float(t)
	_snap.alive = true


func _building(kind: StringName, x: int, y: int, w: int, h: int, flags: int,
		hp: float, need: int, workers: int) -> int:
	var i: int = _snap.bld_count
	_snap.bld_count = i + 1
	_snap.bld_id.append(1000 + i)
	_snap.bld_x.append(x)
	_snap.bld_y.append(y)
	_snap.bld_w.append(w)
	_snap.bld_h.append(h)
	_snap.bld_state.append(0)
	_snap.bld_workers.append(workers)
	_snap.bld_need.append(need)
	_snap.bld_flags.append(flags)
	_snap.bld_hp.append(hp)
	_snap.bld_progress.append(0.4)
	_snap.bld_reach.append(0.0)
	_snap.bld_kind.append(kind)
	_snap.bld_row[1000 + i] = i
	return i


func _heat_node(for_row: int, flags: int, served: float, temp: float, net: int) -> int:
	var i: int = _snap.node_count
	_snap.node_count = i + 1
	_snap.node_id.append(_snap.bld_id[for_row])
	_snap.node_x.append(_snap.bld_x[for_row])
	_snap.node_y.append(_snap.bld_y[for_row])
	_snap.node_w.append(_snap.bld_w[for_row])
	_snap.node_h.append(_snap.bld_h[for_row])
	_snap.node_slot.append(0 if net == 1 else 1)
	_snap.node_net.append(net)
	_snap.node_state.append(0)
	_snap.node_flags.append(flags)
	_snap.node_dirs.append(0)
	_snap.node_link.append(LcnOverlayDefs.D_NORTH | LcnOverlayDefs.D_SOUTH)
	_snap.node_choke.append(0)
	_snap.node_bx.append(-1)
	_snap.node_by.append(-1)
	_snap.node_served.append(served)
	_snap.node_load.append(0.6)
	_snap.node_temp.append(temp)
	_snap.node_freeze.append(-10.0)
	_snap.node_demand.append(5.0)
	_snap.node_output.append(0.0)
	_snap.node_fuel.append(0.05 if for_row % 7 == 0 else 0.8)
	_snap.node_eta.append(45.0 if for_row % 5 == 0 else -1.0)
	_snap.node_cool.append(0.4)
	_snap.node_kind.append(_snap.bld_kind[for_row])
	_snap.node_row[_snap.bld_id[for_row]] = i
	_snap.bld_flags[for_row] |= LcnOverlaySnapshot.B_HEAT
	return i


func _network(nid: int, slot: int, delivered: float, demand: float, producers: int) -> void:
	_snap.net_slot[nid] = slot
	_snap.net_row[nid] = _snap.nets.size()
	_snap.nets.append({
		"id": nid, "slot": slot, "supply": delivered, "demand": demand,
		"delivered": delivered, "deficit": maxf(0.0, demand - delivered),
		"producers": producers, "nodes": 40,
	})


## A warm island around the hearth: high in the middle, ambient at the edges, so
## both the SURVIVAL and COMFORT isolines come out as closed loops.
func _build_warmth() -> void:
	var w: int = 48
	var h: int = 48
	_snap.warm_w = w
	_snap.warm_h = h
	_snap.warm_step = 1
	_snap.warm_origin = Vector2i(106, 108)
	_snap.warm.resize(w * h)
	var centre := Vector2(float(w) * 0.5, float(h) * 0.5)
	_snap.warm_min = 999.0
	_snap.warm_max = -999.0
	for y: int in h:
		for x: int in w:
			var d: float = Vector2(float(x), float(y)).distance_to(centre) / (float(w) * 0.5)
			var v: float = lerpf(34.0, _snap.ambient_c, clampf(d, 0.0, 1.0))
			_snap.warm[y * w + x] = v
			_snap.warm_min = minf(_snap.warm_min, v)
			_snap.warm_max = maxf(_snap.warm_max, v)


# =========================================================================
# the layers, in a real tree, drawing for real
# =========================================================================

func _build_layers() -> void:
	_pal = LcnOverlayPalette.new("off", false, true)   # reduce_motion: no pulse
	_field = LcnLabelField.new()
	_icons = LcnStatusIcons.new()
	add_child(_icons)
	_add(LcnOverlayDefs.Mode.HEAT_NETWORK, LcnHeatNetworkLens.new())
	_add(LcnOverlayDefs.Mode.BOTTLENECK, LcnBottleneckLens.new())
	_add(LcnOverlayDefs.Mode.THERMAL, LcnThermalLens.new())
	_add(LcnOverlayDefs.Mode.FREEZE, LcnFreezeLens.new())
	_add(LcnOverlayDefs.Mode.LOGISTICS, LcnLogisticsLens.new())
	_add(LcnOverlayDefs.Mode.COVERAGE, LcnCoverageLens.new())


func _add(mode: int, lens: LcnOverlayLayer) -> void:
	lens.visible = false
	add_child(lens)
	_lenses[mode] = lens


func _view_for(zoom: float) -> Rect2:
	var size: Vector2 = SCREEN / zoom
	# Centred on the ladder, the way a player watching their build queue would be.
	return Rect2(Vector2(128.0, 118.0) * TILE - size * 0.5, size)


## [P17]'s clock panel, in world coordinates, by exactly the mapping
## `LcnOverlayRoot._chrome_world()` uses.
func _chrome_for(zoom: float) -> Array[Rect2]:
	var view: Rect2 = _view_for(zoom)
	var k := Vector2(view.size.x / SCREEN.x, view.size.y / SCREEN.y)
	return [Rect2(view.position + CLOCK_PANEL.position * k, CLOCK_PANEL.size * k)] as Array[Rect2]


## ONE FRAME. Opens the budget, syncs both layers, makes them actually draw, and
## hands back what the field recorded. `alt` is held because that is the state
## the critic's frames were in — and it is the state that produced the ladder.
func _frame(mode: int, zoom: float, enforce: bool) -> Dictionary:
	var view: Rect2 = _view_for(zoom)
	var wpp: float = 1.0 / zoom
	_field.enforce = enforce
	_field.begin(view, wpp, LcnLabelField.budget_for(zoom), _chrome_for(zoom))
	for m: int in _lenses:
		_lenses[m].visible = m == mode
	_icons.sync(_snap, _pal, view, wpp, 4.0, true, 0, _field)
	_icons.queue_redraw()
	var lens: LcnOverlayLayer = _lenses.get(mode)
	if lens != null:
		lens.sync(_snap, _pal, view, wpp, 4.0, true, 0, _field)
		lens.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	if enforce and _field.overlap_count() > 0:
		_name_the_collisions(mode, zoom)
	var out: Dictionary = _field.stats()
	out["mode"] = String(LcnOverlayDefs.mode_id(mode))
	out["zoom"] = zoom
	out["enforced"] = enforce
	out["texts"] = ", ".join(_field.chip_texts)
	return out


# ==================================================================  suite 1 ==

## THE PRECONDITION, ASSERTED. Everything below only means something if the city
## this suite built is genuinely the crowded one. With the arbiter bypassed the
## frame must reproduce the defect that was reported: dozens of chips, printed
## through each other, some of them on the clock. If this suite is ever green
## here with small numbers, the city stopped being crowded and every assertion
## after it is measuring an empty room.
func _suite_the_city_is_actually_crowded() -> void:
	var worst_chips: int = 0
	var worst_overlaps: int = 0
	var worst_chrome: int = 0
	for zoom: float in ZOOMS:
		for mode: int in [LcnOverlayDefs.Mode.FREEZE, LcnOverlayDefs.Mode.HEAT_NETWORK,
				LcnOverlayDefs.Mode.THERMAL]:
			var r: Dictionary = await _frame(mode, zoom, false)
			_rows.append(r)
			worst_chips = maxi(worst_chips, int(r["chips"]))
			worst_overlaps = maxi(worst_overlaps, int(r["overlaps"]))
			worst_chrome = maxi(worst_chrome, int(r["chrome_hits"]))
	Log.info(TAG, "unarbitrated worst frame: %d chips, %d overlaps, %d on the clock" % [
		worst_chips, worst_overlaps, worst_chrome])
	_check(worst_chips >= 30,
		"the test city is not crowded — unarbitrated worst frame had only %d chips, so the density assertions have nothing to bite on" % worst_chips)
	_check(worst_overlaps > 0,
		"the test city produced no overlapping words without the arbiter, so the zero-overlap assertion proves nothing")
	_check(worst_chrome > 0,
		"no word ever wanted the clock's pixels, so the keep-out assertion proves nothing")


# ==================================================================  suite 2 ==

## The deliverable. Every lens, every zoom the game is played at, counted.
func _suite_density_at_every_played_zoom() -> void:
	for zoom: float in ZOOMS:
		var budget: int = LcnLabelField.budget_for(zoom)
		for mode: int in range(1, LcnOverlayDefs.MODE_COUNT):
			var r: Dictionary = await _frame(mode, zoom, true)
			_rows.append(r)
			var who: String = "%s @ %.2f" % [r["mode"], zoom]
			_check(int(r["overlaps"]) == 0,
				"%s — %d pairs of words/marks overlap. They must never." % [who, int(r["overlaps"])])
			_check(int(r["chrome_hits"]) == 0,
				"%s — %d word(s) standing on the clock panel. ARCHITECTURE.md §3." % [who, int(r["chrome_hits"])])
			_check(int(r["chips"]) <= budget,
				"%s — %d chips against a budget of %d" % [who, int(r["chips"]), budget])
			_check(int(r["worst_repeat"]) <= MAX_REPEAT,
				"%s — one string printed %d times: %s" % [who, int(r["worst_repeat"]), r["texts"]])

	# A lens that says NOTHING passes every assertion above, which is the exact
	# way a suite goes green while asserting nothing. Every lens with something
	# to say in this city has to say it.
	for mode2: int in [LcnOverlayDefs.Mode.HEAT_NETWORK, LcnOverlayDefs.Mode.THERMAL,
			LcnOverlayDefs.Mode.FREEZE, LcnOverlayDefs.Mode.BOTTLENECK,
			LcnOverlayDefs.Mode.COVERAGE]:
		var r2: Dictionary = await _frame(mode2, 0.70, true)
		_check(int(r2["chips"]) >= 1,
			"%s drew NOTHING at zoom 0.70 over a city with 54 buildings, two grids, three frozen and a bottleneck — a silent lens passes a density test by saying nothing" % r2["mode"])
		_check(int(r2["marks"]) >= 1,
			"%s placed no marks at all" % r2["mode"])


# ==================================================================  suite 3 ==

## The four defects, each named by the critic, each asserted dead.
func _suite_the_named_defects_are_gone() -> void:
	# 1. "a vertical ladder of 22 identical building chips"
	var ladder: Dictionary = await _frame(LcnOverlayDefs.Mode.NONE, 0.70, true)
	_rows.append(ladder)
	_check(_field.count_of("building") <= 1,
		"the bare word 'building' appears %d times — the ladder is back" % _field.count_of("building"))
	var building_chips: int = 0
	for t: String in _field.chip_texts:
		if t.begins_with("building"):
			building_chips += 1
	_check(building_chips <= 1,
		"%d chips about construction sites in one frame; 22 sites are one fact: %s" % [
			building_chips, ", ".join(_field.chip_texts)])
	_check(int(ladder["marks"]) >= 1, "and the sites still carry marks a player can see")

	# 2. "24 temperature chips and 17 no crew chips, overlapping each other"
	var freeze: Dictionary = await _frame(LcnOverlayDefs.Mode.FREEZE, 0.70, true)
	_rows.append(freeze)
	var temps: int = 0
	for t2: String in _field.chip_texts:
		if t2.ends_with("°C") and not t2.begins_with("FROZEN"):
			temps += 1
	_check(temps <= 3, "%d bare temperature chips at zoom 0.70 (the counted frame had 24)" % temps)
	_check(int(freeze["overlaps"]) == 0, "and none of them is printed through anything")

	# 3. "SURVIVAL LINE -10C printed three times on one closed contour"
	var thermal: Dictionary = await _frame(LcnOverlayDefs.Mode.THERMAL, 0.70, true)
	_rows.append(thermal)
	var survival: int = 0
	for t3: String in _field.chip_texts:
		if t3.begins_with("SURVIVAL"):
			survival += 1
	_check(survival == 1,
		"the survival isotherm is named %d times on one contour; it is one line" % survival)

	# 4. "the lens badge = GRID 3 0/0 heat/s NO SOURCE reads straight through
	#     the clock panel, and | GRID 1 47/47 heat/s collides with the 2:21"
	var grids: Dictionary = await _frame(LcnOverlayDefs.Mode.HEAT_NETWORK, 0.70, true)
	_rows.append(grids)
	_check(int(grids["chrome_hits"]) == 0, "a grid badge is on the clock panel")
	_check(int(grids["culled_chrome"]) >= 1,
		"no grid badge even TRIED for the clock's pixels, so this frame is not the one that broke")
	var named: int = 0
	for t4: String in _field.chip_texts:
		if t4.contains("GRID"):
			named += 1
	_check(named >= 1, "and the grids are still named somewhere on the world")


# =========================================================================

## A failing overlap count is a number; this says WHICH two things collided, so
## the next reader does not have to reproduce the frame to find out.
func _name_the_collisions(mode: int, zoom: float) -> void:
	for i: int in _field.chips.size():
		var mine: int = _field.chip_slot[i]
		for j: int in _field.boxes.size():
			if j == mine or not _field.boxes[j].intersects(_field.boxes[mine]):
				continue
			var other: String = "a mark"
			for k: int in _field.chips.size():
				if _field.chip_slot[k] == j:
					other = "'%s'" % _field.chip_texts[k]
			print("    COLLISION  '%s' vs %s  (%s @ %.2f)" % [
				_field.chip_texts[i], other, LcnOverlayDefs.mode_id(mode), zoom])


func _report() -> void:
	print("")
	print("  lens              zoom  arb   chips/bud  marks  overlap  on-clock  repeat   culled off/chrome/repeat/overlap/budget")
	for r: Dictionary in _rows:
		print("  %-16s  %.2f  %-4s  %5d/%-4d %5d  %7d  %8d  %6d   %d/%d/%d/%d/%d" % [
			r["mode"], float(r["zoom"]), "on" if bool(r["enforced"]) else "OFF",
			int(r["chips"]), int(r["budget"]), int(r["marks"]), int(r["overlaps"]),
			int(r["chrome_hits"]), int(r["worst_repeat"]),
			int(r["culled_offscreen"]), int(r["culled_chrome"]), int(r["culled_repeat"]),
			int(r["culled_overlap"]), int(r["culled_budget"])])
	print("")


func _write_report(verdict: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	var f: FileAccess = FileAccess.open(_out_dir + "/density.json", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"verdict": verdict, "checks": _checks,
		"failures": _failures, "frames": _rows,
	}, "  "))
	f.close()

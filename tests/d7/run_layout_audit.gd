## REQUIRES: --force-ui
extends Node
## THE LAYOUT AUDIT. Boots the real game, resizes the real window to eight
## configurations, and asserts that no two pieces of chrome overlap in any of
## them. [D7 composition]
##
##   godot --path . res://tests/d7/run_layout_audit.tscn -- --force-ui
##
## WHY THIS EXISTS AND WHAT WOULD MAKE IT GO RED
##
## Overlap used to be something a human noticed in a screenshot, at one
## resolution, if they were looking. Three parts each owned a corner and each
## carried its own constant for where the neighbours were: [P18]'s hotkey rail at
## `BOTTOM_LEFT + (18, -26)`, [P19]'s legend at `BOTTOM_CLEARANCE = 108`, [P17]'s
## stores shelf growing a chip at a time until it was 1160 px wide. On the build
## this suite was written against, at 1920x1080, the hotkey rail was drawn
## THROUGH the stores shelf in every single frame `tools/run_visual.sh` produced,
## and nothing anywhere could fail because of it.
##
## WHAT MAKES IT GO RED — mutation-tested, not asserted. Each of these was
## applied on its own to a scratch copy of the tree and the suite re-run:
##
##   hotkey rail back on `PRESET_BOTTOM_LEFT + (18, -26)`  → 36 of 36 cases red,
##       `hint x stores`, 2820 px². This is the defect that was on screen in
##       every frame `tools/run_visual.sh` produced before this work.
##   lens-rail height reservation removed from the solver → 12 cases red,
##       `rail x selection`, 3434 px².
##   `fit_scale`'s stage guarantee removed                → 8 cases red, both as
##       stage-too-small and as `alerts x heat`, 23,579 px².
##   [P22]'s original card placement (window-centred, 0.22h) restored
##                                                        → 2 cases red,
##       `card x clock`, up to 20,496 px².
##
## TWO THINGS IT DOES **NOT** CATCH, measured the same way and written down so
## nobody mistakes them for covered:
##
##   * Putting the selection panel back in the bottom-right corner is GREEN. The
##     move into the right rail is a composition decision — one reading column
##     instead of a fifth lonely corner — not an overlap fix. It never overlapped
##     the shelf, because the logical canvas is never narrower than 1920 (below).
##   * Removing the stores chip cap is GREEN for the same reason. The cap is a
##     composition rule (the shelf recedes to five chips at night) and a guard
##     against a future shelf that grows; it is not currently load-bearing.
##
## It runs as a SCENE, not with `--script`: a Node-based suite launched with
## `--script` compiles before the autoloads exist, prints nothing, and exits 0.
## See ARCHITECTURE.md §6.1.
##
## It refuses to run without a view. Without `--force-ui` or a display the parts
## that install themselves come up in a different order and half of them are not
## in the tree at all, which is the configuration no player ever gets — the exact
## disease documented in HANDOFF §4B. Checks it could not ask are counted
## UNCHECKED and force `TESTS PASSED, PARTIAL`.

const TAG: String = "d7-layout"
const BOOT_SCENE: String = "res://game/boot.tscn"
const SETTLE_FRAMES: int = 8

## Every screen this build claims to support, plus the accessibility scaling
## [D4] is adding. `ui` scales the whole HUD; `font` scales only type, which is
## what makes panels taller without making them wider — the case that breaks a
## column layout and is never tested.
##
## A MEASURED FACT THAT CHANGES WHAT "RESOLUTION" MEANS HERE, and which this
## suite found the first time it ran: `project.godot` sets
## `window/stretch/mode = "canvas_items"` with `aspect = "expand"` on a
## 1920x1080 base. So the LOGICAL viewport every Control lays out against is
## 1920x1080 at 1280x720, at 1920x1080 and at 2560x1440 alike — those three are
## the SAME layout, rendered at three sizes. What actually moves the logical
## rectangle is the ASPECT RATIO: 21:9 gives 2580x1080, 16:10 gives 1920x1200,
## 4:3 gives 1920x1440.
##
## Auditing "1280 / 1920 / 2560" would therefore have been three readings of one
## configuration and would have felt like coverage. The pixel sizes are kept
## because a critic will run those windows and they must be seen to pass — but
## the cases that can actually break the composition are the aspects and the
## scales, and they are the reason this list is shaped the way it is.
const CASES: Array[Dictionary] = [
	{"name": "1920x1080", "size": Vector2i(1920, 1080), "ui": 1.0, "font": 1.0},
	{"name": "2560x1440", "size": Vector2i(2560, 1440), "ui": 1.0, "font": 1.0},
	{"name": "1280x720", "size": Vector2i(1280, 720), "ui": 1.0, "font": 1.0},
	{"name": "3440x1440 ultrawide 21:9", "size": Vector2i(3440, 1440), "ui": 1.0, "font": 1.0},
	{"name": "5120x1440 superwide 32:9", "size": Vector2i(5120, 1440), "ui": 1.0, "font": 1.0},
	{"name": "1920x1200 16:10", "size": Vector2i(1920, 1200), "ui": 1.0, "font": 1.0},
	{"name": "1600x1200 4:3", "size": Vector2i(1600, 1200), "ui": 1.0, "font": 1.0},
	{"name": "1920x1080 font 1.4", "size": Vector2i(1920, 1080), "ui": 1.0, "font": 1.4},
	{"name": "1600x1200 4:3 font 1.7", "size": Vector2i(1600, 1200), "ui": 1.0, "font": 1.7},
	{"name": "2560x1440 ui 1.35", "size": Vector2i(2560, 1440), "ui": 1.35, "font": 1.0},
	{"name": "3440x1440 ui 1.6 font 1.4", "size": Vector2i(3440, 1440), "ui": 1.6, "font": 1.4},
	{"name": "1920x1080 ui 0.8 font 1.7", "size": Vector2i(1920, 1080), "ui": 0.8, "font": 1.7},
]

## The three compositions the game has. Every case is audited in all three,
## because "no two panels overlap" is a claim about a SCREEN, and this screen is
## three different screens: the lull has no alert stack and no palette, the build
## has [P18]'s palette down the left flank, and the night has a lens legend, a
## lens rail, a full attention stack and something selected.
##
## A suite that only ever measured the resting state would have certified the
## build mode in which [P17]'s left rail sits underneath [P18]'s palette.
const STATES: Array[String] = ["lull", "build", "night"]

## Pairs that are allowed to touch, with why. Kept deliberately short: every
## entry here is a thing this suite has stopped being able to catch.
const ALLOWED: Array[String] = [
	# [P22]'s ticker is prose with a shadow and no plate, deliberately floating on
	# the world. It is placed on the stage floor and may pass behind the card's
	# lower edge when a card is unusually tall.
	"card|ticker",
	# A DECISION MAY COVER A BROWSER. [P18]'s palette is 982 px wide at 1920x1080
	# and [P22]'s card is 661: on a 1920 canvas there is no arrangement in which
	# both have the flank, and the tie-break is not close. The browser is a list
	# the player opened and closes with Escape; the card is a question with a
	# deadline that decides itself if it is ignored. So the card is centred on
	# [P17]'s own walls, ignoring the palette, and [P17] scrims the world behind
	# it so the two read as foreground and background rather than as clutter.
	# What is NOT allowed, and what this suite still fails on, is a card over any
	# status panel — the clock, the heat grid, attention, the people, the wave,
	# the shelf or the lens legend.
	"card|palette", "card|recipes", "card|tech", "card|blueprints", "card|laws",
	"card|sheet", "palette|ticker", "recipes|ticker", "tech|ticker",
	"blueprints|ticker", "laws|ticker",
]

## The share of the screen the world must keep, per state. Build mode is allowed
## to be a browser — the player is reading a list, and [P18]'s palette is nine
## hundred pixels wide on purpose. The lull and the night are not: those are the
## two states whose whole job is to make the player look at the city.
const STAGE_FLOOR: Dictionary = {"lull": 0.30, "build": 0.18, "night": 0.24}

var _checks: int = 0
var _unchecked: PackedStringArray = PackedStringArray()
var _failures: PackedStringArray = PackedStringArray()
var _report: Array[Dictionary] = []
var _out_dir: String = "artifacts/d7"
var _boot: Node = null


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out_dir = a.substr(6)
	Log.capture = true
	Log.min_level = Log.Level.INFO
	var watchdog := Timer.new()
	watchdog.wait_time = 220.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()

	if not LcnLayers.view_wanted():
		print("TESTS PASSED, PARTIAL — 0 checks, 8 UNCHECKED: no view. "
			+ "Run with --force-ui or a display; without one, half the parts "
			+ "this suite measures are not in the scene tree at all.")
		get_tree().quit(126)
		return
	if not ResourceLoader.exists(BOOT_SCENE):
		print("TESTS FAILED — no %s" % BOOT_SCENE)
		get_tree().quit(2)
		return
	_boot = (load(BOOT_SCENE) as PackedScene).instantiate()
	add_child(_boot)
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the layout audit timed out after 220 s")
	get_tree().quit(125)


func _run() -> void:
	# A world with buildings in it, so the panels have something to be tall about
	# and [P22] has a reason to put a card up. Manual ticks: this suite must not
	# depend on how fast the machine running it happens to be.
	SimClock.set_manual(true)
	for _i: int in 3:
		await get_tree().process_frame
	if Sim.alive:
		SimClock.advance(240)
	for _j: int in 4:
		await get_tree().process_frame

	for case: Dictionary in CASES:
		for st: String in STATES:
			await _audit(case, st)

	var verdict: String = "TESTS PASSED" if _failures.is_empty() else "TESTS FAILED"
	if _failures.is_empty() and not _unchecked.is_empty():
		verdict = "TESTS PASSED, PARTIAL"
	for line: String in _failures:
		print("  FAIL  " + line)
	for line2: String in _unchecked:
		print("  UNCHECKED  " + line2)
	print("%s — %d checks, %d failures, %d unchecked" % [
		verdict, _checks, _failures.size(), _unchecked.size()])
	_write()
	if not _failures.is_empty():
		get_tree().quit(mini(_failures.size(), 120))
		return
	get_tree().quit(126 if not _unchecked.is_empty() else 0)


## Drives the build into one of its three compositions using the same public
## entry points a player's hands would: [P18]'s hotkey handler opens the palette,
## [P19]'s `set_mode` raises a lens, [P17]'s `select` fills the selection panel.
## Nothing here reaches past a part to set a private flag, because a state a test
## can only reach by cheating is a state the game does not have.
func _drive_state(st: String) -> void:
	var menu: Node = get_tree().get_first_node_in_group(&"lcn_build_menu")
	var lens: Node = get_tree().get_first_node_in_group(&"lcn_overlay_root")
	var hud: Node = _hud()
	if menu != null and menu.has_method(&"set_open"):
		menu.call(&"set_open", &"palette", st == "build")
	if lens != null and lens.has_method(&"set_mode"):
		lens.call(&"set_mode", LcnOverlayDefs.Mode.FREEZE if st == "night"
			else LcnOverlayDefs.Mode.NONE)
	if hud != null and hud.has_method(&"select"):
		hud.call(&"select", _a_building() if st == "night" else -1)


## Any real building id, so the selection panel has something to be. -1 when the
## world has none, which the audit then reports as an unchecked column.
func _a_building() -> int:
	var build: Object = Sim.get_system(&"build") if Sim.alive else null
	if build == null or not build.has_method(&"all_buildings"):
		return -1
	var all: Array = build.call(&"all_buildings")
	if all.is_empty():
		return -1
	return int((all[all.size() - 1] as Object).get(&"id"))


func _audit(case: Dictionary, st: String) -> void:
	var label: String = "%s [%s]" % [String(case["name"]), st]
	var want: Vector2i = case["size"]
	Settings.set_value("accessibility", "font_scale", float(case["font"]))
	Settings.set_value("graphics", "ui_scale", float(case["ui"]))
	get_window().size = want
	_drive_state(st)
	# The root viewport carries `stretch/mode = canvas_items`, so the LOGICAL
	# viewport is what every Control actually lays out against. Asserting against
	# the window size would be asserting against a number no panel ever sees.
	#
	# Settled in WALL TIME, not in frames. [P17] polls the simulation at 10 Hz and
	# falls back to 4 Hz while the clock is not moving; [P18] refreshes at 4 Hz.
	# Headless frames run in microseconds, so eight of them are eight microseconds
	# and none of those pollers ever fires — the suite would be measuring the
	# layout of the PREVIOUS case and calling it this one.
	for _i: int in SETTLE_FRAMES:
		await get_tree().process_frame
	for _t: int in 2:
		await get_tree().create_timer(0.3).timeout
		await get_tree().process_frame
	var view: Vector2 = get_viewport().get_visible_rect().size

	var rects: Dictionary = {}
	var sources: int = 0
	for node: Node in _chrome_sources():
		sources += 1
		var owned: Dictionary = node.call(&"chrome_rects")
		for k: Variant in owned.keys():
			var key: String = String(k)
			# Two parts may both name a rect "legend"/"card"; the owner's node
			# name disambiguates so a collision in this dictionary can never hide
			# a collision on the screen.
			if rects.has(key):
				key = "%s.%s" % [String(node.name), key]
			rects[key] = owned[k] as Rect2
	if sources == 0:
		_unchecked.append("%s — nothing in the tree published chrome_rects()" % label)
		return
	if rects.size() < 3:
		_unchecked.append("%s — only %d rect(s) on screen; too little to audit"
			% [label, rects.size()])
		return

	var bad: Array[Dictionary] = LcnHudLayout.overlaps(rects, PackedStringArray(), 2.0)
	var real: Array[Dictionary] = []
	for row: Dictionary in bad:
		var pair: String = "%s|%s" % [String(row["a"]), String(row["b"])]
		if ALLOWED.has(pair):
			continue
		real.append(row)
	_checks += 1
	if not real.is_empty():
		var worst: Dictionary = real[0]
		_failures.append("%s — %d overlapping pair(s), worst %s x %s = %d px² at %s"
			% [label, real.size(), String(worst["a"]), String(worst["b"]),
			int(worst["area"]), str(worst["rect"])])

	var out: Array[Dictionary] = LcnHudLayout.out_of_bounds(rects, view, 2.0)
	_checks += 1
	if not out.is_empty():
		_failures.append("%s — %d rect(s) off screen, worst %s by %d px"
			% [label, out.size(), String(out[0]["name"]), int(out[0]["by"])])

	# The stage is what the whole composition exists to protect: if the rails eat
	# the middle of the screen there is nowhere left to look at the city.
	var hud: Node = _hud()
	if hud != null and hud.has_method(&"solved_rect"):
		var stage: Rect2 = hud.call(&"solved_rect", &"stage")
		_checks += 1
		var frac: float = (stage.size.x * stage.size.y) / maxf(1.0, view.x * view.y)
		# Only at the DEFAULT scale. Above it the player has traded stage for
		# legibility on purpose and the composition honours the request in full;
		# see the note in `LcnHud._relayout`. Overlap is still checked at every
		# scale, because overlap is never something the player asked for.
		var floor_frac: float = float(STAGE_FLOOR.get(st, 0.30))
		if not is_equal_approx(float(case["ui"]), 1.0):
			floor_frac = 0.0
		if frac < floor_frac:
			_failures.append("%s — the stage is only %.0f%% of the screen (floor %.0f%%); "
				% [label, frac * 100.0, floor_frac * 100.0] + "the chrome has eaten the game")
	else:
		_unchecked.append("%s — no HUD published a stage rectangle" % label)

	var named: Array = rects.keys()
	named.sort()
	_report.append({
		"case": label, "want": [want.x, want.y], "view": [view.x, view.y],
		"ui": float(case["ui"]), "font": float(case["font"]),
		"state": int(hud.get("state")) if hud != null else -1,
		"rects": _rect_rows(rects, named),
		"overlaps": _overlap_rows(real),
		"off_screen": out.size(),
	})


func _rect_rows(rects: Dictionary, named: Array) -> Array:
	var rows: Array = []
	for n: Variant in named:
		var r: Rect2 = rects[n]
		rows.append({"name": String(n), "x": int(r.position.x), "y": int(r.position.y),
			"w": int(r.size.x), "h": int(r.size.y)})
	return rows


func _overlap_rows(bad: Array[Dictionary]) -> Array:
	var rows: Array = []
	for row: Dictionary in bad:
		rows.append({"a": String(row["a"]), "b": String(row["b"]),
			"area": int(row["area"])})
	return rows


## Everything in the tree that publishes where it draws. Discovered, not listed:
## a part that lands a new panel after this was written is audited without this
## file being touched.
func _chrome_sources() -> Array[Node]:
	var out: Array[Node] = []
	_walk(get_tree().root, out)
	return out


func _walk(node: Node, out: Array[Node]) -> void:
	if node.has_method(&"chrome_rects"):
		out.append(node)
	for child: Node in node.get_children():
		_walk(child, out)


func _hud() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(&"lcn_hud_chrome")


func _write() -> void:
	var dir: String = ProjectSettings.globalize_path("res://" + _out_dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/layout_audit.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"checks": _checks,
			"failures": _failures,
			"unchecked": _unchecked,
			"cases": _report,
		}, "  "))

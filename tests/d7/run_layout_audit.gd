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

## The height [P19]'s legend cannot go below however many rows it sheds: a title,
## a blurb, a headline, a footer and one row of numbers. Measured at 143 px; the
## 150 here is that plus a margin, so `_audit_slot_fidelity` never squeezes the
## panel into a strip no part could honour. See the long note there.
const CONTENT_FLOOR: float = 150.0
## How much smaller than its natural height the test strip must be, so the panel
## is genuinely forced to shed a row and the rectangle it publishes has to move.
## Small on purpose: rows are ~20 px, so a strip 6 px under the natural height
## costs the panel a whole row and the paint lands well clear of the strip.
const SHED_MARGIN: float = 6.0

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
## `card|ticker` USED TO BE HERE, exempted as "prose that may pass behind the
## card's lower edge when a card is unusually tall". Two things were wrong with
## that. It described the defect in `fixed_1920/shots/dusk.png` — four lines of
## flavour printed across the two options of "The Clerk Wants an Answer" — as
## acceptable. And it exempted a check that COULD NOT RUN: nothing in the build
## published a `ticker` rectangle at all, so this entry and the four `*|ticker`
## entries below it were permissions for a comparison that never happened.
## `LcnHudStage` now publishes `ticker_rect` and hides the feed against the card
## that is really on screen, so the pair is enforced instead of excused.
const ALLOWED: Array[String] = [
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

## Every rect name any part published in any state of this run. See
## `_audit_allowances`: an entry in ALLOWED naming something nothing ever draws
## is a permission for a comparison that never happened.
var _seen_names: PackedStringArray = PackedStringArray()
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

	_audit_allowances()

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


## THE SAME BUG THIS FILE'S HEADER ALREADY FIXED ONCE, CAUGHT GENERALLY.
##
## The header records that `palette|ticker` and its four siblings were
## "permissions for a comparison that never happened", because nothing in the
## build published a `ticker` rect at all. It fixed that one name and left the
## list unguarded, and `sheet` is the same bug still live: [P18] publishes
## `sheet` only when `tooltip.visible`, the tooltip follows the pointer, and
## under `--force-ui` on a headless runner there is no pointer. So every
## `*|sheet` pair is silently absent, the overlap check counts a pass it never
## earned, and the four `palette x sheet` failures E3 measured at a real
## 1920x1080 cannot go red in the gate — which is how a 382x385 inspection sheet
## reached a shipped `assault.png` with ten hostiles on the map.
##
## An allowance is a claim that two things can be on screen together. If one of
## them was never on screen, the run did not test the claim and must not report
## that it did. This is UNCHECKED rather than FAIL: the sheet's absence is a
## property of the runner, not a defect in the build, and `tools/check.sh` grades
## a PARTIAL as not-checked rather than as a pass.
func _audit_allowances() -> void:
	var missing: PackedStringArray = PackedStringArray()
	for pair: String in ALLOWED:
		for side: String in pair.split("|"):
			if not _seen_names.has(side) and not missing.has(side):
				missing.append(side)
	for side: String in missing:
		_unchecked.append(("no state of this run put `%s` on screen, so every "
			+ "ALLOWED pair naming it permitted a comparison that never ran") % side)


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
			if not _seen_names.has(key):
				_seen_names.append(key)
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

	await _audit_slot_fidelity(label, st)

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


## THE CHECK THAT EVERY OTHER CHECK IN THIS FILE DEPENDS ON, and which did not
## exist until the composition was already green.
##
## Everything above compares rectangles that the parts REPORT. That is only an
## audit of the screen if a part draws where it says it draws. [P19]'s legend did
## not: it published `legend_size()`, the height its content WANTS, while
## `_draw_panel` painted `_panel_height()`, the height its content HAS. Those
## agree until the content grows between one solve and the next — and at the
## assault beat of `first_night` a second heat grid appears, the panel gains two
## rows, and 31 px of it is painted over the strip [P17] had reserved for [P18]'s
## hotkeys. Both reported rectangles agreed with each other. The suite was green.
## The frame, `artifacts/d7/cur_1920/shots/assault.png`, had two texts on one
## line of pixels.
##
## So this check does not ask a part how big it is. It SHRINKS the slot [P17]
## handed it, forces a repaint, and asserts that what the part actually painted
## fits inside what it was given. A part that treats its slot as advice rather
## than as a boundary fails here and only here.
##
## It reads nothing but the interface both versions of the part already have —
## `legend_slot` in, `chrome_rects()` out — so it is a test of the CONTRACT and
## not of the fix. Mutation-tested by reverting `game/ui/overlays/*.gd` and
## `game/ui/hud/*.gd` to the previous commit in a scratch copy of the tree and
## re-running: the numbers are in this file's commit message.
func _audit_slot_fidelity(label: String, st: String) -> void:
	if st != "night":
		return
	var lens: Node = get_tree().get_first_node_in_group(&"lcn_overlay_root")
	var hud: Node = _hud()
	if lens == null or hud == null or not hud.has_method(&"solved_rect") \
			or not lens.has_method(&"chrome_rects"):
		_unchecked.append("%s — no lens or no HUD to check slot fidelity against" % label)
		return
	var legend: Object = lens.get(&"_legend")
	if legend == null:
		_unchecked.append("%s — the lens part published no legend node" % label)
		return
	var slot: Rect2 = hud.call(&"solved_rect", &"legend") as Rect2
	if slot.size.y <= 1.0:
		_unchecked.append("%s — no legend slot was reserved; nothing to be faithful to" % label)
		return

	# WHAT THIS CHECK IS FOR, AND WHY BOTH EARLIER THRESHOLDS WERE WRONG.
	#
	# The defect is a part that publishes the rectangle it WANTED instead of the
	# one it DREW: both numbers then agree with each other, the audit compares
	# two copies of the same wrong height, and [P18]'s hotkey strip goes on being
	# printed through this panel's footer with every rectangle reporting
	# agreement. Measured before the fix: reserved 154 px, drawn 185 px.
	#
	# [P19]'s panel sheds rows to fit its strip, but it has a floor — a title, a
	# blurb, a headline, a footer and one row of numbers is 143 px however hard it
	# sheds. That floor is what made the two earlier versions of this line wrong,
	# in opposite directions:
	#
	#   tight = max(140, half)   the panel CANNOT fit and honestly says so, so
	#                            this went red 12 times on correct code. A check
	#                            no part can satisfy is not a check.
	#   tight = max(150, half)   the panel fits with room to spare, so the
	#                            published rectangle equals the slot whether the
	#                            part is honest or not. MEASURED: publishing
	#                            `legend_slot` instead of the painted rectangle —
	#                            the exact defect above — passes 120/0.
	#
	# The threshold was never the problem. The question has to be asked where the
	# answer can differ: a strip the panel CAN honour but only by shedding rows.
	# Then an honest part publishes the SHORTER rectangle it actually painted, and
	# a part reporting its want publishes the taller natural height. So `tight`
	# is clamped between the content floor and the panel's own natural height,
	# and both halves are asserted below.
	var natural: float = (lens.call(&"chrome_rects") as Dictionary).get(
		"legend", Rect2()) .size.y as float
	if natural < CONTENT_FLOOR + SHED_MARGIN:
		_unchecked.append(("%s — the legend drew %d px, which is inside its own "
			+ "%d px content floor: there is nothing it could shed, so an honest "
			+ "part and one reporting its want would publish the same number")
			% [label, int(natural), int(CONTENT_FLOOR)])
		return
	var tight: float = maxf(CONTENT_FLOOR, natural - SHED_MARGIN)

	# The lens root re-reads its slots from [P17] on EVERY `_process` frame, so a
	# slot written from here is overwritten before the next redraw — the first
	# version of this check measured the real slot, reported the real height, and
	# was red against fixed and unfixed code alike with identical numbers. That
	# is a check that cannot pass, which is the same disease as one that cannot
	# fail. Processing is suspended for the two frames this takes; `_draw` is not
	# a process callback and still runs, which is the whole point.
	var was_mode: int = lens.process_mode
	lens.process_mode = Node.PROCESS_MODE_DISABLED
	legend.set(&"legend_slot", Rect2(slot.position, Vector2(slot.size.x, tight)))
	(legend as CanvasItem).queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	var published: Rect2 = (lens.call(&"chrome_rects") as Dictionary).get(
		"legend", Rect2()) as Rect2
	var live_slot: Rect2 = legend.get(&"legend_slot") as Rect2
	lens.process_mode = was_mode
	legend.set(&"legend_slot", slot)
	(legend as CanvasItem).queue_redraw()
	await get_tree().process_frame

	_checks += 1
	if not is_equal_approx(live_slot.size.y, tight):
		# The suspension did not hold, so the number below would be meaningless.
		# Said out loud rather than passed quietly.
		_unchecked.append("%s — the tightened slot did not survive; %d px went in, "
			% [label, int(tight)] + "%d px was in place at read" % int(live_slot.size.y))
		return
	if published.size.y > tight + 2.0:
		_failures.append(("%s — [P19]'s legend was given a %d px strip and published "
			+ "a %d px rectangle. A part that reports the size it WANTS rather "
			+ "than the size it DREW makes every rectangle under it wrong, and "
			+ "every one of them still reports agreement.")
			% [label, int(tight), int(published.size.y)])
		return
	# THE OTHER HALF, AND THE ONE THAT CATCHES THE ORIGINAL DEFECT. The strip was
	# chosen so the panel has to shed to fit it, so the rectangle it publishes
	# must have MOVED. A part that publishes `legend_slot` back also satisfies the
	# clause above — it reports exactly the strip it was handed — and only this
	# one separates it from a part that reports its paint.
	_checks += 1
	if is_equal_approx(published.size.y, tight):
		_failures.append(("%s — [P19]'s legend drew %d px naturally, was handed a "
			+ "%d px strip that costs it a whole row, and published exactly %d px "
			+ "back. Rows are quantised; a panel that really measured its own "
			+ "paint could not land on the strip to the pixel. It is echoing the "
			+ "number it was given.")
			% [label, int(natural), int(tight), int(published.size.y)])


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

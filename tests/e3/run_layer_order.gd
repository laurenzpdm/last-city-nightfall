extends SceneTree
## THE RANK OF THE UI STACK. [E3]
##
##   godot --headless --path . --script tests/e3/run_layer_order.gd
##
## `LcnLayers.enforce()` and `tests/boot/run_reachability.tscn` between them
## already prove that every CanvasLayer sits on the number the table gives it.
## Neither of them could ever have caught the defect this suite exists for,
## because the defect was IN THE TABLE: [P22]'s card was allocated 78 and it was
## on 78, [P21]'s guide was allocated 79 and it was on 79, every check in the
## build agreed, and the card was printed across the entire cost column of
## [P18]'s build palette in `artifacts/ui_tour/shots/01_palette.png` — and across
## the recipe browser, the tech tree, the blueprint library, the Book of Laws,
## [P20]'s statistics screen, and `artifacts/d2_belt_gallery/01_four_states.png`,
## the gallery that exists to grade belt art. Six for six in the tour's own
## frames, and every automated check green.
##
## The rule the build was missing, and the one thing this file asserts:
##
##   **A SURFACE THAT DOES NOT STOP THE WORLD MAY NOT COVER A SURFACE THE PLAYER
##   OPENED ON PURPOSE.**
##
## The story card does not stop the world — its deadline runs whether it is read
## or not — so it does not get to answer the B key. Only `LcnLayers.MODAL` stops
## the world, and it is [P24]'s alone.
##
## WHAT MAKES THIS SUITE RED. Not a guess: each of these was applied to a scratch
## copy of `game/core/ui_layers.gd` and the suite re-run.
##
##   NARRATIVE 66 → 78, TUTORIAL 67 → 79 (the code as it shipped before this)
##       → 4 checks red in the table half, 2 more in the live half.
##   NARRATIVE 66 → 65 (level with the HUD)
##       → red: [P17] draws the scrim on the HUD layer and a card at 65 is
##         either under its own dimmer or ordered by tree accident.
##   NARRATIVE 66 → 80 (level with MODAL)
##       → red twice: above the work surfaces, and level with the one layer that
##         is allowed to stop the game.
##
## It runs with `--script` and touches no autoload: `LcnLayers` is a global
## script class, not an autoload, so it is available before `Sim` and `Log` are.
## The live half builds its own CanvasLayers under the root rather than booting
## the game — booting is `tests/boot/run_reachability.tscn`'s job, and it calls
## the same `LcnLayers.violations()` this file does, against the real tree.
##
## The work happens in `_process`, not `_init`. Under `--script` the root window
## has no tree yet when `_init` runs, so `audit()`'s `get_path()` printed one
## engine ERROR per canvas layer per call — errors `Log.errors` does not count
## and `tools/scan_errors.py` correctly fails a run for.

var _checks: int = 0
var _fails: PackedStringArray = PackedStringArray()
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_the_table_is_ordered()
	_the_table_agrees_with_itself()
	_violations_reads_the_live_tree()

	for line: String in _fails:
		print("  FAIL  " + line)
	if _fails.is_empty():
		print("TESTS PASSED — %d checks, 0 failures" % _checks)
		quit(0)
		return true
	print("TESTS FAILED — %d of %d checks failed" % [_fails.size(), _checks])
	quit(mini(_fails.size(), 120))
	return true


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(what)


# ================================================================= the table ==

## Every non-modal surface against every work surface, by name, from the table.
func _the_table_is_ordered() -> void:
	for key: StringName in LcnLayers.NON_MODAL:
		var mine: int = LcnLayers.layer_of(key)
		_ok(mine >= 0, "'%s' has a row in LcnLayers.SLOTS" % String(key))
		for other: StringName in LcnLayers.WORK_SURFACES:
			var theirs: int = LcnLayers.layer_of(other)
			_ok(mine >= 0 and theirs >= 0 and mine < theirs,
				("%s (%d) does not stop the world and must draw UNDER the work "
				+ "surface %s (%d)") % [String(key), mine, String(other), theirs])
		# Above the HUD, because [P17]'s scrim lands between the world and the
		# card and it is drawn on the HUD layer.
		_ok(mine > LcnLayers.HUD,
			"%s (%d) draws over the HUD (%d), so the scrim can land under it"
			% [String(key), mine, LcnLayers.HUD])
		# Below the only layer that is allowed to stop the game.
		_ok(mine < LcnLayers.MODAL,
			"%s (%d) draws under MODAL (%d)" % [String(key), mine, LcnLayers.MODAL])

	# The named work surfaces themselves, so a future edit that "fixes" the rank
	# by demoting the palette instead of the card is caught too.
	for other2: StringName in LcnLayers.WORK_SURFACES:
		var l: int = LcnLayers.layer_of(other2)
		_ok(l > LcnLayers.HUD and l < LcnLayers.MODAL,
			"the work surface %s (%d) is between the HUD (%d) and MODAL (%d)"
			% [String(other2), l, LcnLayers.HUD, LcnLayers.MODAL])

	_ok(LcnLayers.table_violations().is_empty(),
		"LcnLayers.table_violations() is empty: %s"
		% " · ".join(LcnLayers.table_violations()))


## The constants and SLOTS are two statements of the same allocation, and the
## rank rule is checked against SLOTS. A constant that drifted away from its own
## row would make every check above true of a table nothing uses.
func _the_table_agrees_with_itself() -> void:
	var pairs: Dictionary[StringName, int] = {
		&"hud": LcnLayers.HUD,
		&"overlay_ui": LcnLayers.OVERLAY_UI,
		&"build_menu": LcnLayers.BUILD_MENU,
		&"stats": LcnLayers.STATS,
		&"narrative": LcnLayers.NARRATIVE,
		&"tutorial": LcnLayers.TUTORIAL,
		&"meta": LcnLayers.MODAL,
	}
	var keys: Array[StringName] = pairs.keys()
	keys.sort()
	for key: StringName in keys:
		_ok(LcnLayers.layer_of(key) == pairs[key],
			"SLOTS['%s'] is %d, matching the constant (%d)"
			% [String(key), LcnLayers.layer_of(key), pairs[key]])

	# No two rows on one number: two parts that agree with the same row are
	# ordered by whichever reached the viewport's canvas first, which is a
	# tie-break no part can see, state or test.
	var seen: Dictionary[int, StringName] = {}
	for slot: Dictionary in LcnLayers.SLOTS:
		var n: int = int(slot["layer"])
		_ok(not seen.has(n), "layer %d is allocated once (%s), not twice (%s)"
			% [n, String(slot["key"]), String(seen.get(n, &"-"))])
		seen[n] = StringName(slot["key"])


# ============================================================== the live tree ==

## `violations()` is what the gate actually calls, so it is what has to catch a
## part that ignores the table and sets its own number in `_ready`. Built by hand
## here: two CanvasLayers with the names the table matches on, at layers the
## table does NOT allocate, so the check cannot be passing because it agrees with
## the constants.
func _violations_reads_the_live_tree() -> void:
	var card := CanvasLayer.new()
	card.name = "LcnNarrativeCard"
	var menu := CanvasLayer.new()
	menu.name = "LcnBuildMenu"
	root.add_child(card)
	root.add_child(menu)

	# The order the build shipped with: card over the palette. Both numbers are
	# wrong against the table, so `enforce()` would have corrected them — but
	# `violations()` is asked BEFORE any correction and has to say so.
	card.layer = 78
	menu.layer = 74
	_ok(_names(LcnLayers.violations(self)).has(&"narrative"),
		"violations() names 'narrative' when the card (78) is over the palette (74)")

	# The order this wave installs. The only rows left are the two disagreements
	# with the table, which is a different complaint and belongs to enforce().
	card.layer = LcnLayers.NARRATIVE
	menu.layer = LcnLayers.BUILD_MENU
	var rows: Array[Dictionary] = LcnLayers.violations(self)
	_ok(not _names(rows).has(&"narrative"),
		"violations() is quiet about 'narrative' once the card is under the palette: %s"
		% _why(rows))

	# A part that puts itself on the number the table gives ANOTHER part is the
	# case `enforce()` cannot see when both agree. Level is not below.
	card.layer = LcnLayers.BUILD_MENU
	_ok(_names(LcnLayers.violations(self)).has(&"narrative"),
		"violations() names 'narrative' when the card is LEVEL with the palette")

	root.remove_child(card)
	root.remove_child(menu)
	card.free()
	menu.free()


func _names(rows: Array[Dictionary]) -> Array[StringName]:
	var out: Array[StringName] = []
	for row: Dictionary in rows:
		out.append(StringName(row.get("key", &"?")))
	return out


func _why(rows: Array[Dictionary]) -> String:
	var out: PackedStringArray = PackedStringArray()
	for row: Dictionary in rows:
		out.append("%s: %s" % [String(row.get("key", "?")),
			String(row.get("why", "?"))])
	return " · ".join(out) if not out.is_empty() else "(no rows)"

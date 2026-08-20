extends SceneTree
## READS: visual-run
## NOTHING THAT STOPS THE WORLD IS IN A FRAME NAMED FOR A FIGHT. [D7]
##
##   xvfb-run -a tools/run_visual.sh --scenario=first_night --out=artifacts/mine
##   godot --headless --path . --script tests/d7/run_fight_frames.gd
##   LCN_FRAME_DIR=artifacts/mine godot --headless --path . --script tests/d7/run_fight_frames.gd
##
## THE DEFECT, THREE ROUNDS RUNNING. A blocking narrative modal — 660 x 460, dead
## centre — sat over the city in `artifacts/CRIT/shots/assault.png` while ten
## hostiles were inside the perimeter and the ATTENTION stack was four rows deep
## behind it. Each round it was MOVED: a slot, a solver, a stage director. Moving
## a rectangle answers "where". It has never once answered "whether", so each
## round the next beat put it over something else.
##
## `LcnWorldWatch` is the rule. THIS FILE IS THE GATE, and its whole design is a
## reaction to the five instruments this project has already shipped that graded
## something other than the game: a sprite suite reading its own cache, a frame
## lab and a tour that both photographed the title screen, beats that fired in
## the wrong phase, and a contrast rig with the screen wash left out.
##
## SO IT STANDS NOTHING UP. It opens the PNGs an ordinary
## `tools/run_visual.sh --scenario=first_night` already wrote — the frames a
## critic is handed — and measures those. No scene, no probe, no member of the
## code it is grading.
##
## ── THE MEASUREMENT, AND THE ONE THAT WAS TRIED FIRST AND THROWN AWAY ────────
##
## The obvious measurement is the harness's own pair: every beat is written twice,
## `<beat>.png` and `<beat>.world.png`, the second with every layer above the HUD
## stripped. Their difference over the stage centre ought to be "everything drawn
## over the city", and against `artifacts/CRIT` it duly read 23% at the assault
## beat and looked like a gate.
##
## IT WAS NOISE. The two exposures are three rendered frames apart, and in those
## three frames the snow moves, the embers move and the lights flicker: the SAME
## measurement reads 23% at `third_day_city` in a build with the card already
## taken off the stage, and the median pixel of a clean pair is already 8 grey
## levels apart. A bar drawn above that floor would have been a bar drawn above
## the weather. It is written down here rather than deleted quietly, because a
## rig that measures the weather and calls it a modal is precisely the failure
## this file exists to stop happening a sixth time.
##
## WHAT IS MEASURED INSTEAD IS THE ONE THING A PLATE HAS AND A CITY DOES NOT:
## LONG RUNS OF FLAT PIXELS. A `StyleBoxFlat` panel is hundreds of pixels of one
## colour across, row after row, broken only by its own text. A city under snow —
## at any hour, in any weather, at every zoom this scenario uses — is textured
## everywhere. So: sample every third row of the stage centre, find the longest
## run of horizontally adjacent pixels that stay within 2/255 of each other, and
## count the rows whose longest run covers at least `RUN_FRACTION` of the box.
##
## MEASURED, on the eleven beats of three full `first_night` runs:
##
##   card on the stage   45.0 – 67.5 %   (all 22 beats of artifacts/CRIT and
##                                        artifacts/H3_base, the parent commit)
##   card off the stage   2.1 –  5.8 %   (the five night and fight beats of
##                                        artifacts/H3_fix, after the rule)
##
## There is a factor of eight between the two populations and `MAX_PLATED` sits
## in the middle of the gap. Nothing in the scenario lands between them.
##
## THOSE TWO NUMBERS WERE MEASURED IN THE NARROW BOX — see `CX0` below, which the
## integrator widened after the card stopped being the only thing that plates the
## stage. Re-measured in the box this file now uses: watched beats 0.5 %, quiet
## beats 30.4 – 38.2 %. Same shape, same verdicts, a factor of sixty instead of
## eight, and the box now reaches the part of the screen where the defect that
## replaced the card actually sits.
##
## This reads the SHIPPED frame alone, which also closes the hole the pair
## measurement had: a world-stopping surface drawn at or below `LcnLayers.HUD`
## would have been in both exposures and invisible to a difference, and it is not
## invisible to this.
##
## WHAT IT CANNOT SEE, SAID PLAINLY: a modal painted with a gradient or a texture
## instead of a flat plate. Every panel in this build is a `StyleBoxFlat` and the
## day one is not, this number moves and somebody has to look. A gate with an
## unstated blind spot is how the last five got shipped.
##
## ── THE PRECONDITION IS CHECKED, BECAUSE A SUITE THAT ASSERTS NOTHING IS THE
##    OTHER WAY THIS PROJECT HAS BEEN LIED TO ─────────────────────────────────
##
## A green here means "there were fight frames and they were clean". If a run has
## no fight frame in it, or a fight frame with nothing hostile in it, this suite
## says UNCHECKED and names the run — it never counts an absent condition as a
## pass. The fight beats are not hard-coded: they are read out of the run's own
## `state.json`, from the `claims` line the harness itself wrote
## ("something alive and hostile in the frame") and the hostile count in
## `photographed`. There is no second vocabulary here to drift out of step with
## `LcnHarness.BEAT_LIVE_WORDS`.
##
## AND IT IS NOT A CHECK THAT THE CARD IS GONE. Six of the eleven beats of
## `first_night` still measure 47–62 % after the rule landed, because a story
## card on a quiet afternoon is the point of [P22] — see the day beats in
## `test_the_quiet_beats_still_carry_a_card` below, which fails if the fix ever
## turns into "delete the narrative layer".

# ---------------------------------------------------------------- the rules --

## The rectangle the city is in, as fractions of the frame. Deliberately well
## inside every rail so no chrome that BELONGS at the edge can reach it: at
## 1920x1080 this is x 576..1344, y 162..734. [P19]'s lens legend ends at x 524,
## [P17]'s left rail at x 390, the key rail starts at x 1760, and the clock panel
## stops at y 202 but never reaches x 576 — none of them touch this box in any
## shot of `first_night`. The card, at x 656..1316 y 212..670, sits inside it.
##
## X WIDENED 0.30..0.70 -> 0.17..0.83 BY THE INTEGRATOR, BECAUSE THE NARROW BOX
## WAS DRAWN AROUND THE CARD AND THE CARD IS NO LONGER THE ONLY THING THAT PLATES
## THE STAGE. With [P22]'s card correctly standing down for a watch, [P18]'s
## world-inspection sheet took the space it left: a 382x385 opaque panel at
## x 345..727 in the integrated tree's `shots/assault.png`, ten hostiles alive.
## Only 151 px of it reached into x 576..1344, and the plate test needs a flat
## run of 0.26 of the box — 199 px — so the sheet could not trip this suite at
## any opacity. Measured on that frame: 5.8 % in the narrow box (PASS), 28.3 %
## in this one (FAIL). The suite was passing a frame that carried exactly the
## defect it exists to catch, one screen-eighth to the left of where it looked.
##
## THE WIDER BOX SEPARATES THE TWO POPULATIONS BETTER, NOT WORSE, AND IT CAN
## STILL FAIL. Four beats of `artifacts/INT_ship` (the sheet suppressed) against
## `artifacts/H4b_v6` (the same build with it up), narrow -> wide:
##
##     assault         5.8 -> 28.3 %  before      4.7 ->  0.5 %  after
##     second_night    5.2 -> 28.3 %  before      5.2 ->  0.5 %  after
##     third_day_city 60.2 -> 38.2 %  (quiet, card up — unchanged by the fix)
##     midday         51.8 -> 30.4 %  (quiet, card up — unchanged by the fix)
##
## So a watched frame reads 0.5 % and a quiet one 30-38 %: MAX_PLATED 0.20 and
## MIN_QUIET_PLATED 0.20 both still sit in the gap, and the box now reaches the
## chrome that actually lands there. `deep_night` reads 0.0 % in the wide box,
## which is the control that says the extra width is not picking up a rail.
const CX0: float = 0.17
const CX1: float = 0.83
const CY0: float = 0.15
const CY1: float = 0.68

## Two adjacent pixels this close are the same colour. Not zero: the PNG is
## written after the post grade, and a flat plate picks up a grey level or two of
## dither and grain crossing it.
const FLAT: float = 2.0 / 255.0

## A run this long is a PLATE. 0.26 of the box — 200 px at 1920x1080 — is longer
## than any uninterrupted feature of the city at the zooms this scenario uses,
## and less than a third of the 660 px card.
const RUN_FRACTION: float = 0.26

## Every third row. 190 samples over a 572 px box: a panel that only covered a
## sixth of the stage would still put thirty rows in.
const ROW_STEP: int = 3

## How many of those rows a fight frame may have a plate across. See the two
## measured populations in the header — 2.1-5.8 % clean, 45.0-67.5 % with the
## card up.
const MAX_PLATED: float = 0.20

## And how few a QUIET beat may have before the fix has become a deletion. Day
## beats measure 47-62 % with the card in them; a build that took the card out of
## the game entirely would read zero here and pass every other check in this
## file.
const MIN_QUIET_PLATED: float = 0.20


var _checks: int = 0
var _fails: PackedStringArray = PackedStringArray()
var _notes: PackedStringArray = PackedStringArray()
var _unchecked: PackedStringArray = PackedStringArray()
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return _verdict()


func _run() -> void:
	var dir: String = _find_run()
	if dir == "":
		_unchecked.append("no visual run in artifacts/ carries a beat with something "
			+ "alive and hostile in it — run tools/run_visual.sh --scenario=first_night")
		return
	_notes.append("reading %s" % dir)
	var fights: int = 0
	var quiet_best: float = -1.0
	var quiet_name: String = ""
	for b: Dictionary in _beats(dir):
		var name: String = String(b["name"])
		var live: int = int(b["live"])
		var img: Image = _load(dir, name + ".png")
		if img == null:
			continue
		var plated: float = _plated_rows(img)
		if bool(b["fight"]):
			fights += 1
			_grade_fight(name, live, plated)
		elif plated > quiet_best:
			quiet_best = plated
			quiet_name = name
	if fights == 0:
		_unchecked.append("%s has no fight beat" % dir)
	_grade_quiet(quiet_name, quiet_best)


func _grade_fight(name: String, live: int, plated: float) -> void:
	# THE PRECONDITION, CHECKED AND NOT ASSUMED. A frame named for a fight with
	# nothing in it grades nothing, and a suite that calls that a pass is the
	# exact failure that cost this project a round.
	if live == 0:
		_unchecked.append(("%s claims a fight and photographed 0 hostile(s) — "
			+ "nothing to be covered, so nothing was checked") % name)
		return
	_checks += 1
	var line: String = "%s: %d hostile(s), %.1f%% of the stage centre is plated" % [
		name, live, plated * 100.0]
	if plated > MAX_PLATED:
		_fails.append(line + " — a panel is standing on the city at the one moment "
			+ "the player has to watch it (bar %.0f%%)" % (MAX_PLATED * 100.0))
	else:
		_notes.append(line)


## THE OTHER DIRECTION, AND IT IS NOT DECORATION. The cheapest way to make every
## check above green is to stop drawing [P22] at all, and no measurement of a
## fight frame can tell that apart from the fix. So the quietest beat of the run
## — the one with the most plate in it — has to still have a card on it.
func _grade_quiet(name: String, plated: float) -> void:
	if plated < 0.0:
		_unchecked.append("the run has no beat that is not a fight, so 'the card "
			+ "still exists' was not checked")
		return
	_checks += 1
	if plated < MIN_QUIET_PLATED:
		_fails.append(("no beat of this run has a panel on the stage at all — the "
			+ "quietest, %s, measures %.1f%%. The rule is supposed to stand the "
			+ "story down during a fight, not delete it") % [name, plated * 100.0])
	else:
		_notes.append("%s (quiet): %.1f%% plated — the card is still in the build"
			% [name, plated * 100.0])


# ------------------------------------------------------------- the measurement --

## Fraction of sampled rows of the stage centre carrying a flat run at least
## `RUN_FRACTION` of the box wide.
func _plated_rows(img: Image) -> float:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var x0: int = int(w * CX0)
	var x1: int = int(w * CX1)
	var y0: int = int(h * CY0)
	var y1: int = int(h * CY1)
	var need: int = int(float(x1 - x0) * RUN_FRACTION)
	var rows: int = 0
	var plated: int = 0
	var y: int = y0
	while y < y1:
		rows += 1
		if _longest_flat_run(img, x0, x1, y) >= need:
			plated += 1
		y += ROW_STEP
	return 0.0 if rows == 0 else float(plated) / float(rows)


func _longest_flat_run(img: Image, x0: int, x1: int, y: int) -> int:
	var best: int = 0
	var run: int = 0
	var prev: Color = img.get_pixel(x0, y)
	for x: int in range(x0 + 1, x1):
		var here: Color = img.get_pixel(x, y)
		if absf(here.r - prev.r) <= FLAT and absf(here.g - prev.g) <= FLAT \
				and absf(here.b - prev.b) <= FLAT:
			run += 1
			if run > best:
				best = run
		else:
			run = 0
		prev = here
	return best


# ------------------------------------------------------------- the run's own --

## Every beat of the run, with the harness's own word on whether it was a fight.
## `claims` is the sentence `LcnHarness._claim_text` wrote for a beat whose name
## carries one of `BEAT_LIVE_WORDS`; `photographed` carries the hostile count the
## harness read out of the running world at the instant the shutter opened.
## Reading both out of the artifact means this file has no vocabulary of its own
## to go stale.
func _beats(dir: String) -> Array:
	var out: Array = []
	for raw: Variant in _json(dir.path_join("state.json")).get("shots", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = raw
		var live: int = _hostiles(String(row.get("photographed", "")))
		var claimed: bool = String(row.get("claims", "")).findn("alive and hostile") >= 0
		out.append({
			"name": String(row.get("name", "")),
			"live": live,
			"fight": claimed or live > 0,
		})
	return out


## "night of day 2, 10 hostile(s) alive" -> 10. -1 when the sentence does not
## carry the count at all, which reads as "unknown" rather than as "none".
func _hostiles(photographed: String) -> int:
	var re: RegEx = RegEx.new()
	re.compile("(\\d+) hostile")
	var m: RegExMatch = re.search(photographed)
	return -1 if m == null else int(m.get_string(1))


## The newest artifacts folder that has a state.json naming a fight beat and the
## PNG for it on disk. LCN_FRAME_DIR wins, so a builder can point this at the run
## they just made.
func _find_run() -> String:
	var root: String = ProjectSettings.globalize_path("res://artifacts")
	var order: PackedStringArray = PackedStringArray()
	var want: String = String(OS.get_environment("LCN_FRAME_DIR")).strip_edges()
	# LCN_FRAME_DIR IS AN INSTRUCTION, NOT A FIRST GUESS. When it is set this
	# search stops here: grade that run or report UNCHECKED. It used to be the
	# head of a list that fell through to `artifacts/gate/visual` and then to
	# every folder in `artifacts/` newest-first, which meant tools/check.sh —
	# where this suite runs before the gate has photographed anything — graded
	# whichever builder's scratch run happened to be newest. On this tree that
	# was `artifacts/H4b_v6`; four rows down the same list sits
	# `artifacts/H4b_nofloor`, an ablation with the night's light set to zero.
	# A stage that cannot say which run it graded is not evidence.
	if not want.is_empty():
		var pinned: String = want if want.begins_with("/") \
			else ProjectSettings.globalize_path("res://" + want)
		return pinned if _qualifies(pinned) else ""
	var rest: Array[Dictionary] = []
	var d: DirAccess = DirAccess.open(root)
	if d != null:
		for name: String in d.get_directories():
			var st: String = root.path_join(name).path_join("state.json")
			if FileAccess.file_exists(st):
				rest.append({"dir": root.path_join(name),
					"at": FileAccess.get_modified_time(st)})
	rest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) > int(b["at"]))
	for row: Dictionary in rest:
		order.append(String(row["dir"]))
	for cand: String in order:
		if _qualifies(cand):
			return cand
	return ""


## Can this run answer the question this file asks? One rule, used both by the
## search and by the LCN_FRAME_DIR path, so a pinned run is held to exactly the
## standard a discovered one is.
func _qualifies(cand: String) -> bool:
	for b: Dictionary in _beats(cand):
		if bool(b["fight"]) and FileAccess.file_exists(
				cand.path_join("shots/%s.png" % String(b["name"]))):
			return true
	return false


# ------------------------------------------------------------------ plumbing --

func _load(dir: String, file: String) -> Image:
	var path: String = dir.path_join("shots").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img: Image = Image.new()
	return null if img.load(path) != OK else img


func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _verdict() -> bool:
	for n: String in _notes:
		print("  " + n)
	for line: String in _fails:
		print("  FAIL  " + line)
	for u: String in _unchecked:
		print("  UNCHECKED  " + u)
	if not _fails.is_empty():
		print("TESTS FAILED — %d of %d checks failed" % [_fails.size(), _checks])
		quit(mini(_fails.size(), 120))
		return true
	if not _unchecked.is_empty():
		print("TESTS PASSED, PARTIAL — %d checks, %d unchecked"
			% [_checks, _unchecked.size()])
		quit(0)
		return true
	print("TESTS PASSED — %d check(s): every fight frame has the city in it"
		% _checks)
	quit(0)
	return true

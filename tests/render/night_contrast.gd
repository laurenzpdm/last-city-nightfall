extends Node
## CAN YOU SEE THE WAVE. [P13]
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" \
##     $GODOT --path . --resolution 1920x1080 tests/render/night_contrast.tscn
##
## THE INSTRUMENT THIS PROJECT DID NOT HAVE. Three rounds of critics scored the
## night at 3, and the sentence that named the defect was this one: the interface
## says "10 in the city", `render` reports 27 agents drawn that tick, and a
## gamma-0.35 lift of the whole 1920x1080 frame finds ZERO enemies. Nothing in
## this repository could contradict that, because nothing in it measured the one
## quantity involved — how far a creature sits from the ground it is standing on,
## in the graded frame a player actually receives.
##
## So this suite renders A WAVE — not a tidy row of specimens, a converging
## arc of eighteen hostiles crossing open plain toward a lit settlement at deep
## night, at zoom 0.60 where the overlay legends say the camera sits — and asks
## two questions of the photograph:
##
##   DELTA-L   for each creature, the strongest departure of its own pixels from
##             the ground immediately around it. The brief is 0.25–0.30; the
##             build before this pass measured a MEDIAN of 0.0922 with zero of
##             eleven clearing 0.25, on a frame that also carries film grain at
##             ±0.03. Reported per creature, gated on the median and on how many
##             individually clear the bar.
##
##   BLOBS     how many DISTINCT connected regions of that contrast the frame
##             actually contains at a staged creature's feet. A wave of eighteen
##             that resolves into four blobs is four things happening, whatever
##             the agent counter says.
##
## ── INTEGRATOR, SIX-BUILDER H WAVE: THIS SUITE IS RED AND IT DID NOT ARRIVE ──
## ── RED. THREE PARTS MOVED ONE NUMBER AND NONE OF THEM COULD SEE THE OTHERS. ─
##
## [H4] reported this suite red and called it pre-existing, on the strength of
## stashing their own three files and reading 0.5974 / 0.7990 on "the parent".
## That parent already contained [H1] and [H3]. Run on 0e212fc, the commit this
## wave started from, alone on the box under xvfb at 1920x1080:
##
##     tree        deep_night median deltaL   dusk    blobs at deep night
##     0e212fc     0.3200  (ceiling 0.55)     0.4088   9 of 18   TESTS PASSED
##     HEAD        0.6160                     0.7289  13 of 18   TESTS FAILED
##
## So the ceiling was met before this wave and is broken by it. BOTH halves of
## that are real: the wave also took the night from 9 figures resolving to 13,
## which is exactly what [H1] set out to do. What it bought that with is
## over-drive, and this suite's own failure line says so in words — "the lift is
## over-driving on ground that already carries some light of its own, and the
## wave arrives as pale cut-outs".
##
## THE MECHANISM, MEASURED ON SHIPPED FRAMES RATHER THAN ON THIS STAGING. The
## p90 luminance of the nine hostile rectangles the renderer logs for `assault`,
## read out of the ordinary first_night `shots/assault.world.png`:
##
##     artifacts/H1_v5    hostiles 0.220..0.347 (med 0.312)   local plain 0.06..0.12
##     artifacts/H1_final hostiles 0.226..0.348 (med 0.316)   local plain 0.07..0.12
##     artifacts/H3_ship  hostiles 0.443..0.696 (med 0.654)   local plain 0.11..0.23
##     artifacts/H4b_v6   hostiles 0.433..0.693 (med 0.643)   local plain 0.10..0.24
##     artifacts/INT_ship hostiles 0.431..0.696 (med 0.646)   local plain 0.10..0.24
##
## The step is at [H3], not [H4]. [H1] tuned the hostile treatment against a
## night with [P22]'s scrim in it and verified a delivered lift of 0.13..0.25.
## [H3] then removed that scrim for exactly the frames with hostiles in them —
## correctly, for composition — which is a 1.47x to 1.77x brightening of
## precisely the frames [H1] tuned on. [H1]'s treatment paints at ABSOLUTE canvas
## luminance and blends additively, so it did not scale down with the night: the
## figures went to 0.43..0.70 and the lift doubled to 0.27..0.51. [H4]'s ground
## then moved the median 0.654 -> 0.643, i.e. not at all.
##
## AND THE GATE COULD NOT HAVE CAUGHT IT. `tests/render/run_foe_frame.gd` grades
## the same quantity with a FLOOR of 0.17 and no ceiling, so it reads 9 of 9
## GREEN on figures that are twice as hot as the ones it was calibrated on. This
## suite is the only thing in the build holding the other end, and it needs a
## framebuffer: every `tools/check.sh` run records it UNCHECKED — "no display
## server, so there is no framebuffer to photograph". A floor in a stage that
## runs and a ceiling in a stage that cannot is not a band.
##
## Not retuned by the integrator. Pulling the lift back down is [P13]/[H1]'s
## craft and the obvious risk is un-finding the monsters the wave just found —
## the 9-of-18 column is what that costs. What is an integrator's is saying
## which commit moved it, and that it is a regression rather than the weather.
##
## ── WHY A BLOB AND NOT A DIFFERENCE ──────────────────────────────────────────
##
## `tests/render/frame_lab.gd`'s night beat already photographs the eleven
## designed enemies twice — with and without agents — and grades the DIFFERENCE.
## That check is sound as far as it goes and it is why the enemies are known to
## be drawn at all. It cannot answer the critic, because a creature that changes
## nine hundred pixels by 0.09 each changes a great many pixels and is still
## invisible: a difference plate measures whether something was DRAWN, and
## legibility is about whether it can be TOLD APART. Its threshold, 0.035 peak,
## is a drawn/not-drawn threshold and passed the whole time the night was blank.
##
## This suite measures against the ground in the SAME frame, in absolute graded
## luminance, with no control plate involved in the verdict. The control plate is
## still taken, and it is used for one thing only: to prove the blob is the
## creature. A blob is credited only if most of its pixels are pixels the
## creature CHANGED — otherwise a bright rock inside the box could sign for a
## hound that is not there, which is precisely the class of false green this
## project has already paid for twice.
##
## ── HOW IT FAILS ─────────────────────────────────────────────────────────────
##
## RUN, not asserted. This suite was checked out into a worktree of the commit
## BEFORE the change it grades (`git worktree add … HEAD~1`), with only these
## test files copied across, and the same wave photographed from the same camera
## at the same hour and the same seed:
##
##   build              median deltaL   worst    blobs found   midday
##   before this pass          0.1203  0.0608          0/18     green
##   after                     0.4253  0.3942         17/18     green
##
## Two FAIL lines against the old build, both of them the sentence a critic
## wrote — and the midday beat green on BOTH, which is the correct shape: the day
## was never the broken half, and a suite that went red on both would be
## measuring the staging rather than the change. That 0.12 also independently
## reproduces the measurement taken off the previous pass's own
## `artifacts/P13/frames/night_foes.png` (median 0.0922 over eleven) — two
## instruments, different staging, same answer.
##
## `tests/render/test_agent_masks.gd` does not even compile against that build,
## which is the correct outcome: the masks it guards do not exist there.

const OUT: String = "res://artifacts/P13/frames"
const SETTLE_FRAMES: int = 6

## The zoom a session is played at, off [P19]'s legends. Everything is graded
## here; a night that only works at 1.6 is a night nobody sees.
const JUDGE_ZOOM: float = 0.60

## THREE HOURS, AND THE OTHER TWO EXIST BECAUSE THE FIRST ONE CANNOT SEE PAST
## ITSELF. The treatment is keyed off the ground, so it has a CROSSOVER: on a
## black plain the figure is lit, on snow at noon it is a silhouette, and
## somewhere between it has to hand the read from one to the other. A gate that
## only photographs the hour a fix was aimed at will certify the other
## twenty-three, and the crossover is where the arithmetic goes wrong:
##
##   deep_night  can the wave be SEEN. The brief, and the failing measurement.
##               ITS PLATE IS ALSO THE ONE THAT SHOWS. `wave_dusk.png` caught the
##               first fade curve over-driving: 45–79% of every figure reading as
##               lit and a delta of 0.60 where the design asks for 0.38, because
##               the grade keeps far more of a canvas-space delta at dusk than at
##               midnight and the fade had barely engaged. Eighteen figures as
##               pale cut-outs at the assault hour, with deep_night green.
##   midday      is the treatment OFF. Every figure back to a dark silhouette.
##
## Graded on the same staged wave, from the same camera, so the only difference
## between the three plates is the hour.
const HOURS: Array[Dictionary] = [
	{"name": "deep_night", "t": 0.00, "gate": "lit"},
	{"name": "dusk", "t": 0.74, "gate": "mid"},
	{"name": "midday", "t": 0.50, "gate": "dark"},
]

## Eighteen, out of eleven designed kinds, so the frame is a WAVE and not a
## catalogue. Spread over a converging arc: some out on black plain, some close
## enough to the settlement that the city's own light is falling on them, which
## is the case the ground-keyed treatment has to get right in both directions.
const WAVE: int = 18
## Far enough apart that one creature's box never contains its neighbour, which
## would let a bright one sign for a dark one.
const BOX_W: int = 78
const BOX_H: int = 94

# ── THE BARS ─────────────────────────────────────────────────────────────────
#
# All three are stated in GRADED luminance, i.e. in the photograph, after lift,
# gain, fog, vignette, bloom and grain.

## What a critic asked for: 25–30%. Held at the bottom of that band per creature.
const MIN_DELTA: float = 0.25
## ...and on the median, above it, because a median at the floor means half the
## wave is under it.
const MIN_MEDIAN_DELTA: float = 0.28
## A contour on a 24-px figure at 0.60 is roughly 90–140 px; a body lift adds the
## interior. Under 60 the "blob" is aliasing on a leg.
const MIN_BLOB_PX: int = 60
## Fraction of a credited blob that must be pixels the creature itself changed.
const MIN_OWNERSHIP: float = 0.55
## How many of the eighteen have to clear all of the above.
const MIN_FOUND: int = 15

# ── AND THE OTHER DIRECTION ──────────────────────────────────────────────────

## By day every figure must be DARKER than the ground beside it by at least this
## much. A silhouette is the right technique when there is something to be a
## silhouette against, and this is the half of the treatment that hands the read
## back to the plain.
const DAY_MIN_DARK: float = 0.10
## How much brighter than its ground a pixel has to be to count as LIT.
const DAY_MAX_LIFT: float = 0.13
## ...and how much of a figure may be lit before it is a lamp. THE ANTI-LAMP
## GATE. Not zero, because every one of these was drawn with a hot part the fill
## mask deliberately spares; the white cut-outs this catches were lit over
## essentially their whole area.
const DAY_MAX_LIT_FRAC: float = 0.30
## How many of the wave have to be silhouettes for the day beat to pass.
const DAY_MIN_DARK_COUNT: int = 15

## At the crossover hour a figure may read either way, but it must read. This is
## a lower bar than the night one on purpose: at dusk the plain still carries
## some structure of its own and the treatment is deliberately half off.
const MID_MIN_DELTA: float = 0.15
const MID_MIN_COUNT: int = 15

# ── AND A CEILING, WHICH IS THE HALF THIS SUITE KEPT LEARNING IT NEEDED ──────
#
# Every bar above is a floor, and a treatment that over-drives clears all of
# them. `wave_dusk.png` is the case: median deltaL 0.60 where the design asks
# for 0.38, because the grade keeps far more of a canvas-space delta at dusk
# than at midnight and the fade had barely engaged at that ground. Eighteen
# figures as pale cut-outs, every floor green.
#
# The first attempt to gate that was an "is this figure lit" fraction, and it
# was wrong: at dusk the treatment is DELIBERATELY half on, so the figures are
# legitimately lit and the fraction fires on the intended picture. Looking at
# the plate settled it. What is actually wrong at 0.60 is the SIZE of the
# separation, so that is what is measured.
const MAX_MEDIAN_DELTA: float = 0.55
const MID_MAX_MEDIAN: float = 0.48

var _renderer: WorldRenderer = null
var _cam: Camera2D = null
var _centre: Vector2 = Vector2.ZERO
var _frame: int = 0
var _step: int = 0
var _hour: int = 0
var _done: bool = false
var _bare: Image = null
var _seen_chrome: Dictionary[String, bool] = {}
var _chrome_left: PackedStringArray = PackedStringArray()
var _spots: Array[Dictionary] = []
var _fails: Array[String] = []
## How many figures each hour actually graded, appended as the LAST statement of
## `_judge`. See `_verdict`.
var _graded: Array[int] = []


func _ready() -> void:
	# The lab grades the BAKER, not the disk: a forgotten ART_VERSION bump would
	# otherwise certify the art of an earlier run. tests/render/frame_lab.gd and
	# tests/render/test_sprites.gd both learned this the expensive way.
	LcnArtCache.set_enabled(false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))


func _process(_delta: float) -> void:
	if _done:
		return
	if DisplayServer.get_name() == "headless":
		print("  UNCHECKED the night — no display server, so there is no "
			+ "framebuffer to photograph")
		print("  run it with: xvfb-run -a -s \"-screen 0 1920x1080x24\" "
			+ "$GODOT --path . --resolution 1920x1080 tests/render/night_contrast.tscn")
		print("TESTS PASSED, PARTIAL")
		_finish(126)
		return
	_frame += 1
	if _frame == 1:
		_build_world()
		return
	if _renderer == null:
		print("night_contrast: no renderer could be installed")
		print("TESTS FAILED")
		_finish(1)
		return
	_stage()


# ------------------------------------------------------------------ staging --

func _stage() -> void:
	var hour: Dictionary = HOURS[_hour]
	var model: LcnWorldModel = _renderer.world_model()
	if _step == 0:
		_place_wave(model)
		SimClock.tick = int(fposmod(float(hour["t"]) - 0.22, 1.0) * 40.0 * 20.0)
		if _cam == null:
			_cam = _find_camera(get_tree().root)
		if _cam != null:
			_cam.position = _centre + Vector2(0.0, -300.0)
			_cam.zoom = Vector2(JUDGE_ZOOM, JUDGE_ZOOM)
			_cam.force_update_scroll()
	_step += 1
	if _step <= SETTLE_FRAMES:
		# The control plate: the same hour, the same camera, nobody in it. It
		# never enters the verdict — only the ownership test.
		if _step == SETTLE_FRAMES:
			_renderer.entities.draw_agents = false
		return
	if _bare == null:
		_strip_chrome()
		var btex: ViewportTexture = get_viewport().get_texture()
		_bare = btex.get_image() if btex != null else null
		if _bare != null:
			_bare.save_png(ProjectSettings.globalize_path(
				"%s/wave_%s_bare.png" % [OUT, hour["name"]]))
		_renderer.entities.draw_agents = true
		return
	_strip_chrome()
	var tex: ViewportTexture = get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null or _bare == null:
		print("  UNCHECKED the wave — the viewport handed back no image")
		print("TESTS PASSED, PARTIAL")
		_finish(126)
		return
	img.save_png(ProjectSettings.globalize_path("%s/wave_%s.png" % [OUT, hour["name"]]))
	_judge(hour, img, _bare)
	# Next hour, from a clean plate.
	_hour += 1
	_step = 0
	_bare = null
	if _hour >= HOURS.size():
		_verdict()


## A converging arc walking in at the settlement across open ground.
##
## MIXED, not a catalogue of hostiles: every second figure is one of the city's
## own people. Both go through the identical code path in
## `LcnEntityRenderer._draw_agent_edge` and differ only by hue, so a wave with no
## citizens in it would have let the white-cut-out defect through — it was the
## CITIZENS that came back white.
##
## Placed through `model.set_agent` twice each so `prev` and `cur` differ and the
## facing flip is exercised, exactly as the frame lab's night beat does: a wave
## in which every figure faces the same way is not the wave the game delivers.
func _place_wave(model: LcnWorldModel) -> void:
	var foes: Array[StringName] = LcnSpriteFactory.ENEMY_KINDS
	var kin: Array[StringName] = LcnSpriteFactory.PERSON_KINDS
	_spots.clear()
	for i: int in WAVE:
		var f: float = float(i) / float(maxi(WAVE - 1, 1))
		# An arc: wide at the flanks, closer at the centre, so the row of boxes
		# never lines up with a road, a wall or the pylon run.
		var ang: float = lerpf(-1.05, 1.05, f)
		var reach: float = 560.0 + absf(ang) * 130.0
		var p: Vector2 = _centre + Vector2(sin(ang) * reach * 1.35, -reach)
		var hostile: bool = i % 3 != 2
		var kind: StringName = foes[i % foes.size()] if hostile \
			else kin[(i / 3) % kin.size()]
		var d: float = 6.0 if i % 2 == 0 else -6.0
		model.set_agent(9000 + i, kind, p - Vector2(d, 0.0))
		model.set_agent(9000 + i, kind, p)
		_spots.append({"kind": String(kind), "pos": p, "hostile": hostile})


# ------------------------------------------------------------------ judging --

func _judge(hour: Dictionary, lit: Image, bare: Image) -> void:
	var xf: Transform2D = get_viewport().get_canvas_transform()
	var w: int = mini(lit.get_width(), bare.get_width())
	var h: int = mini(lit.get_height(), bare.get_height())
	var deltas: Array[float] = []
	var found: int = 0
	var blobs: int = 0
	var dark_enough: int = 0
	var lamps: Array[String] = []
	var offscreen: int = 0
	var rows: Array[Dictionary] = []
	var gate: String = hour["gate"]
	var reads: int = 0
	for spot: Dictionary in _spots:
		var s: Vector2 = xf * (spot["pos"] as Vector2)
		var x0: int = int(s.x) - BOX_W / 2
		var y0: int = int(s.y) - BOX_H + 18
		if x0 < 1 or y0 < 1 or x0 + BOX_W >= w or y0 + BOX_H >= h:
			offscreen += 1
			continue
		var r: Dictionary = _grade_one(lit, bare, x0, y0)
		r["kind"] = spot["kind"]
		# DIAGNOSTIC, NOT VERDICT — and guarded, so this suite still delivers a
		# clean red rather than a stack trace when it is checked out against a
		# build that predates `ground_luma`. That is not hypothetical: it is
		# exactly how this suite is proved capable of failing.
		r["est"] = _renderer.entities.ground_luma(spot["pos"] as Vector2) \
			if _renderer.entities.has_method("ground_luma") else -1.0
		rows.append(r)
		deltas.append(float(r["delta"]))
		if int(r["blob"]) >= MIN_BLOB_PX:
			blobs += 1
		if float(r["delta"]) >= MIN_DELTA and int(r["blob"]) >= MIN_BLOB_PX \
				and float(r["own"]) >= MIN_OWNERSHIP:
			found += 1
		if float(r["down"]) >= DAY_MIN_DARK:
			dark_enough += 1
		if float(r["delta"]) >= MID_MIN_DELTA:
			reads += 1
		if float(r["up"]) > DAY_MAX_LIT_FRAC:
			lamps.append("%s %.0f%% lit" % [r["kind"], float(r["up"]) * 100.0])
	print("────────────────────────────────────────────────────────────────")
	print(" night contrast — a wave of %d at %s, zoom %.2f"
		% [WAVE, hour["name"], JUDGE_ZOOM])
	print("────────────────────────────────────────────────────────────────")
	print("  %-20s %7s %7s %7s %7s %7s %7s %6s" % [
		"kind", "ground", "est", "up", "down", "deltaL", "blob", "own"])
	for r2: Dictionary in rows:
		print("  %-20s %7.4f %7.4f %7.4f %7.4f %7.4f %7d %6.2f" % [
			r2["kind"], float(r2["ground"]), float(r2["est"]), float(r2["up"]),
			float(r2["down"]), float(r2["delta"]), int(r2["blob"]), float(r2["own"])])
	deltas.sort()
	var median: float = deltas[deltas.size() / 2] if not deltas.is_empty() else 0.0
	var worst: float = deltas[0] if not deltas.is_empty() else 0.0
	print("  median deltaL %.4f, worst %.4f" % [median, worst])
	print("  %d of %d figures resolve as a distinct blob of >= %d px they own; "
		% [found, rows.size(), MIN_BLOB_PX]
		+ "%d reach the blob size at all; %d are silhouettes" % [blobs, dark_enough])
	if offscreen > 0:
		print("  note: %d staged figure(s) fell outside the frame and were not graded"
			% offscreen)

	if not _chrome_left.is_empty():
		_fails.append("%s: chrome above [P13]'s post layer was still in the "
			% hour["name"] + "photograph: %s" % ", ".join(_chrome_left))
	if rows.size() < MIN_FOUND:
		_fails.append(("%s: only %d of the wave landed inside the frame — the "
			+ "camera is not looking at what this suite staged, so nothing here "
			+ "was measured") % [hour["name"], rows.size()])
	elif gate == "lit":
		if median < MIN_MEDIAN_DELTA:
			_fails.append(("%s: the wave is not separated from the ground it walks "
				+ "on: median deltaL %.4f against a bar of %.2f. Half the night is "
				+ "under it.") % [hour["name"], median, MIN_MEDIAN_DELTA])
		if found < MIN_FOUND:
			_fails.append(("%s: %d of %d figures resolve as a distinct "
				+ "high-contrast blob, and the bar is %d. The agent counter is not "
				+ "the picture.") % [hour["name"], found, rows.size(), MIN_FOUND])
		if median > MAX_MEDIAN_DELTA:
			_fails.append(("%s: median deltaL %.4f is ABOVE the ceiling of %.2f. "
				+ "The night is meant to be lit, not blown out.")
				% [hour["name"], median, MAX_MEDIAN_DELTA])
	elif gate == "mid":
		# THE CROSSOVER. Either direction is allowed here — the ground is neither
		# black nor snow — but every figure must still read, and none of them may
		# be driven past what this hour needs.
		if reads < MID_MIN_COUNT:
			_fails.append(("%s: only %d of %d figures are separated from their "
				+ "ground by %.2f in ANY direction. This is the assault hour and "
				+ "the middle of the crossover: it is where a treatment that fades "
				+ "badly leaves figures sitting at exactly ground value.")
				% [hour["name"], reads, rows.size(), MID_MIN_DELTA])
		if median > MID_MAX_MEDIAN:
			_fails.append(("%s: median deltaL %.4f is ABOVE the ceiling of %.2f — "
				+ "the lift is over-driving on ground that already carries some "
				+ "light of its own, and the wave arrives as pale cut-outs.")
				% [hour["name"], median, MID_MAX_MEDIAN])
	else:
		# THE OTHER END. On ground bright enough to carry a silhouette the
		# treatment must be OFF, and every figure back to being darker than what
		# is behind it.
		if dark_enough < DAY_MIN_DARK_COUNT:
			_fails.append(("%s: only %d of %d figures are darker than the ground "
				+ "beside them by %.2f. On a bright plain a figure that is not a "
				+ "silhouette is nothing.")
				% [hour["name"], dark_enough, rows.size(), DAY_MIN_DARK])
		if not lamps.is_empty():
			_fails.append(("%s: %d figure(s) are lit over more than %.0f%% of "
				+ "themselves — %s. At this hour the lift is supposed to be OFF "
				+ "entirely; a lit figure on lit snow is a white cut-out.")
				% [hour["name"], lamps.size(), DAY_MAX_LIT_FRAC * 100.0,
					", ".join(lamps)])
	# LAST STATEMENT IN THE FUNCTION, ON PURPOSE. See `_verdict`.
	_graded.append(rows.size())


## ── THE VERDICT REFUSES TO BE GIVEN OVER WORK THAT DID NOT HAPPEN ────────────
##
## This guard is here because THIS SUITE PRINTED A FALSE GREEN, once, and it is
## worth the paragraph. Checked out against the build it was written to fail,
## `_judge` raised on its first row — `ground_luma` does not exist there — and a
## raised GDScript call abandons the WHOLE function. `rows` stayed empty, nothing
## was appended to `_fails`, both hours "completed", and the run printed TESTS
## PASSED over a build whose night is measurably blank.
##
## The `rows.size() < MIN_FOUND` check inside `_judge` did not save it, because
## that check is also inside `_judge`. Any assertion that lives downstream of the
## thing that can abort is not an assertion.
##
## So the count is recorded as the last statement of `_judge`, and the verdict is
## computed from OUTSIDE it: an hour that did not reach the end of its own
## grading has no entry, and a run missing an entry cannot pass no matter how
## empty `_fails` is. Silence is not success.
func _verdict() -> void:
	if _graded.size() != HOURS.size():
		_fails.append(("only %d of %d hours finished grading — a beat that "
			+ "abandoned itself part-way has asserted NOTHING, and an empty "
			+ "failure list is not a pass") % [_graded.size(), HOURS.size()])
	for i: int in _graded.size():
		if _graded[i] < MIN_FOUND:
			_fails.append("%s graded only %d figures of a staged %d"
				% [HOURS[i]["name"], _graded[i], WAVE])
	if _fails.is_empty():
		print(("  %d hours, %d figures each — the night is on screen, the "
			+ "crossover holds, and the day is still a silhouette")
			% [_graded.size(), _graded[0]])
		print("TESTS PASSED")
		_finish(0)
		return
	for f: String in _fails:
		print("  FAIL: %s" % f)
	print("TESTS FAILED")
	_finish(1)


## One creature's box, graded three ways.
##
##   ground  the median luminance of the box's BORDER RING, in the same lit
##           frame. That is the plain the creature is standing on, measured
##           beside it rather than assumed from a constant.
##   up/down the strongest departure from that ground in each DIRECTION, counted
##           only over pixels the figure itself changed. Signed on purpose: the
##           unsigned number cannot tell "a bright creature on dark ground" from
##           "a white cut-out on snow", and those are the pass and the fail.
##   delta   the larger of the two.
##   blob    the largest 8-connected run of pixels at least MIN_DELTA from the
##           ground — the thing an eye would resolve as ONE object.
##   own     the fraction of that blob the creature itself put there, against
##           the control plate. A bright rock cannot sign for a hound.
func _grade_one(lit: Image, bare: Image, x0: int, y0: int) -> Dictionary:
	var ring: Array[float] = []
	for x: int in range(x0, x0 + BOX_W):
		ring.append(_luma(lit.get_pixel(x, y0)))
		ring.append(_luma(lit.get_pixel(x, y0 + BOX_H - 1)))
	for y: int in range(y0 + 1, y0 + BOX_H - 1):
		ring.append(_luma(lit.get_pixel(x0, y)))
		ring.append(_luma(lit.get_pixel(x0 + BOX_W - 1, y)))
	ring.sort()
	var ground: float = ring[ring.size() / 2]

	var mask: PackedByteArray = PackedByteArray()
	mask.resize(BOX_W * BOX_H)
	var mine: PackedByteArray = PackedByteArray()
	mine.resize(BOX_W * BOX_H)
	var peak: float = 0.0
	var up: float = 0.0
	var down: float = 0.0
	var own_px: int = 0
	for yy: int in BOX_H:
		for xx: int in BOX_W:
			var l: float = _luma(lit.get_pixel(x0 + xx, y0 + yy))
			var d: float = absf(l - ground)
			peak = maxf(peak, d)
			mask[yy * BOX_W + xx] = 1 if d >= MIN_DELTA else 0
			var b: float = _luma(bare.get_pixel(x0 + xx, y0 + yy))
			var owned: bool = absf(l - b) > 0.012
			mine[yy * BOX_W + xx] = 1 if owned else 0
			# Measured only over pixels the FIGURE changed, so a lit window in
			# the background of the box cannot be read as the figure glowing.
			if not owned:
				continue
			own_px += 1
			# `up` is a FRACTION and `down` is a PEAK, and the asymmetry is the
			# point. Every one of these creatures was drawn with a hot part — an
			# eye, a core, a crucible — and the fill mask deliberately spares it,
			# so the brightest pixel of a perfectly good midday silhouette is
			# above its ground. A lamp is not a figure with a hot pixel in it; a
			# lamp is a figure MOST OF WHICH is brighter than the ground. Being
			# dark, on the other hand, only takes one convincing region.
			if l - ground > DAY_MAX_LIFT:
				up += 1.0
			down = maxf(down, ground - l)

	var best: int = 0
	var best_own: int = 0
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(BOX_W * BOX_H)
	for i: int in BOX_W * BOX_H:
		if mask[i] == 0 or seen[i] == 1:
			continue
		var stack: PackedInt32Array = PackedInt32Array([i])
		seen[i] = 1
		var n: int = 0
		var owned: int = 0
		while not stack.is_empty():
			var c: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			n += 1
			if mine[c] == 1:
				owned += 1
			var cx: int = c % BOX_W
			var cy: int = c / BOX_W
			for dy: int in [-1, 0, 1]:
				for dx: int in [-1, 0, 1]:
					var nx: int = cx + dx
					var ny: int = cy + dy
					if nx < 0 or ny < 0 or nx >= BOX_W or ny >= BOX_H:
						continue
					var ni: int = ny * BOX_W + nx
					if mask[ni] == 1 and seen[ni] == 0:
						seen[ni] = 1
						stack.append(ni)
		if n > best:
			best = n
			best_own = owned
	return {
		"ground": ground, "peak": ground + peak, "delta": peak,
		"up": up / float(maxi(own_px, 1)), "down": down, "px": own_px,
		"blob": best, "own": float(best_own) / float(maxi(best, 1)),
	}


static func _luma(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722


# ------------------------------------------------------------------- world ---
#
# The same standing-up the frame lab does, and for the same reason: the harness
# is forbidden from inventing a city, which is right for evidence and wrong for
# a contrast measurement that needs the identical settlement in every run.

func _build_world() -> void:
	Rng.reset(7)
	SimClock.reset()
	var packed: PackedScene = load(LcnViewBootstrap.SCENE) as PackedScene
	if packed == null:
		return
	_renderer = packed.instantiate() as WorldRenderer
	if _renderer == null:
		return
	get_tree().root.add_child(_renderer)
	var model: LcnWorldModel = _renderer.world_model()
	model.attach()
	model.ensure_preview_settlement(model.world_size() / 2)
	_renderer.terrain.bind_world()
	_renderer.entities.bind_field(_renderer.terrain.field)
	if _renderer.terrain.field != null:
		_renderer.post.bind_heat_field(_renderer.terrain.field.heat_tex,
			Vector2(_renderer.terrain.field.size) * 32.0)
	_centre = Vector2(model.preview.centre) * 32.0 if model.preview != null \
		else Vector2(model.world_size()) * 16.0
	_cam = _find_camera(get_tree().root)
	_strip_chrome()
	print("night_contrast: %d structures, world %s" % [
		model.building_count(), str(model.world_size())])


func _find_camera(n: Node) -> Camera2D:
	var c := n as Camera2D
	if c != null:
		return c
	for ch: Node in n.get_children():
		var f: Camera2D = _find_camera(ch)
		if f != null:
			return f
	return null


## Nothing above [P13]'s post layer may be in the photograph. Asserted, not
## assumed — twenty-four frames of this project's art were once a main menu.
func _strip_chrome() -> void:
	var above: Array[CanvasLayer] = []
	_collect_layers(get_tree().root, above)
	for cl: CanvasLayer in above:
		if cl.layer <= LcnLayers.POST:
			continue
		var tag: String = "%s@%d" % [cl.name, cl.layer]
		if not _seen_chrome.has(tag):
			_seen_chrome[tag] = true
			print("night_contrast: hiding '%s' on layer %d — not [P13]'s to photograph"
				% [cl.name, cl.layer])
		cl.visible = false
	var again: Array[CanvasLayer] = []
	_collect_layers(get_tree().root, again)
	_chrome_left = PackedStringArray()
	for cl2: CanvasLayer in again:
		if cl2.layer > LcnLayers.POST and cl2.visible:
			_chrome_left.append("%s (layer %d)" % [cl2.name, cl2.layer])


func _collect_layers(n: Node, out: Array[CanvasLayer]) -> void:
	var cl := n as CanvasLayer
	if cl != null:
		out.append(cl)
	for c: Node in n.get_children():
		_collect_layers(c, out)


func _finish(code: int) -> void:
	_done = true
	get_tree().quit(code)

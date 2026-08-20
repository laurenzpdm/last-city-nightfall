extends Node
## THE LOOK, photographed. [P13]
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" \
##     $GODOT --path . --resolution 1920x1080 tests/render/frame_lab.tscn
##
## This is the iteration loop for art direction. It stands the real renderer up
## over the preview settlement (no simulation, no HUD, no lens), then walks a
## matrix of HOURS x ZOOMS and writes one PNG per cell into
## `artifacts/P13/frames/`. Judging the art means looking at those, not at the
## code that made them.
##
## Why a separate scene and not the harness: the harness photographs whatever
## the simulation actually contains and is *forbidden* from inventing a city
## (LcnWorldModel.preview_allowed). That is the right rule for evidence and the
## wrong rule for a paint pass, where you need the same city in every frame so a
## change to the shader is the only difference between two runs.
##
## It is also a TEST. Frames are graded numerically — see `_grade_frame` — and
## the suite fails when the ground goes flat, the frame goes grey, or night
## stops being darker than noon. Those three checks are the exact defects a
## critic named in the first two passes, expressed as numbers a run can fail on.
##
## ── THE GRADER WAS BLIND, AND THAT IS WHY THE CHROME AND DIFF CHECKS EXIST ──
##
## Every one of the 24 frames this suite wrote before this pass was THE TITLE
## SCREEN. `LcnMetaRoot._should_open_title()` opens the main menu on any run
## that is not `--harness`, not `--ui-tour` and not `--force-ui`; the frame lab
## is none of those, so [P24] pushed an OPAQUE modal onto layer 80 over the
## world and the lab photographed it 24 times. Every number reported about this
## build's art — mean luminance, chroma, warm fraction — graded a main menu, and
## the failure messages ("the ground is a cloud", "grey, no colour direction")
## were accurate descriptions of a list of buttons on a dark plate.
##
## Suppressing the menu is the one-line half of the fix and it is the half that
## rots: the next part to install a full-screen layer re-blinds the lab in
## silence. So two checks now stand in front of the grade, and BOTH would have
## gone red on the old build:
##
##   CHROME  nothing may remain above [P13]'s own post layer when the shutter
##           opens. Not suppressed-by-flag: asserted, by name, after the strip.
##   DIFF    frames from different cells must actually differ. 24 photographs
##           of one menu are 24 identical fingerprints, and the zoom column in
##           particular must move the picture — if changing the camera by 6.6x
##           does not change the pixels, the camera is not what is on screen.
##
## `--keep-chrome` skips the strip so the checks can be shown going red against
## the exact defect they were written for.

const OUT: String = "res://artifacts/P13/frames"
const SETTLE_FRAMES: int = 6

## hour name -> normalised day fraction (see LcnPalette.grade_at).
const HOURS: Array[Dictionary] = [
	{"name": "midday", "t": 0.50},
	{"name": "afternoon", "t": 0.63},
	{"name": "dusk", "t": 0.74},
	{"name": "night", "t": 0.86},
	{"name": "deep_night", "t": 0.00},
	{"name": "dawn", "t": 0.27},
]

## The zooms the camera actually reaches (game/view/camera/camera_tuning.gd:
## zoom_min 0.22, default 1.0, zoom_max 3.0). Art that only works at one of
## these is art that works nowhere.
## `play` is 0.60 because that is where the overlay legends say the camera
## actually sits during a session (0.50–0.70). The structure and colour checks
## are graded THERE, not at `normal`: art that only survives at the zoom nobody
## uses is art that fails in the only frame anybody sees.
const ZOOMS: Array[Dictionary] = [
	{"name": "close", "z": 1.60},
	{"name": "normal", "z": 0.85},
	{"name": "play", "z": 0.60},
	{"name": "far", "z": 0.40},
	{"name": "strategic", "z": 0.24},
]

## The zoom the structure/colour checks grade at.
const JUDGE_ZOOM: String = "play"

var _renderer: WorldRenderer = null
var _cam: Camera2D = null
var _centre: Vector2 = Vector2.ZERO
var _shots: Array[Dictionary] = []
var _cursor: int = 0
var _wait: int = 0
var _frame: int = 0
var _done: bool = false
var _report: Array[Dictionary] = []
var _only_hour: String = ""
## `--no-vfx` frees [P14]'s effects layer before the first capture. The frame lab
## exists to judge [P13]'s art, and a particle bug in another folder should not
## be able to hide or fake a ground pass.
var _no_vfx: bool = false
## Skips the chrome strip, so the CHROME and DIFF checks can be watched failing
## against the defect that produced them.
var _keep_chrome: bool = false
var _chrome_left: PackedStringArray = PackedStringArray()
var _seen_chrome: Dictionary[String, bool] = {}
## shot stem -> 16x16 luma fingerprint, for the DIFF check.
var _prints: Dictionary[String, PackedFloat32Array] = {}
var _foes_done: bool = false
var _foe_wait: int = 0
var _foe_report: Array[Dictionary] = []
## The control plate: the staged night with `draw_agents` off.
var _bare: Image = null
var _crowd_done: bool = false
var _crowd_step: int = 0
var _crowd_bare: Image = null
var _crowd_lit_at: int = 0
var _crowd: Dictionary = {}
var _storm_done: bool = false
var _storm_step: int = 0
var _calm_plate: Image = null
var _snow_plate: Image = null
var _storm_report: Dictionary = {}
var _snow_report: Dictionary = {}
var _stub_climate: SimSystem = null
var _wear_done: bool = false
var _wear_begun: bool = false
var _wear_step: int = 0
var _wear_walked: int = 0
var _wear_tick: int = 0
var _wear_fresh: Image = null
var _wear_report: Dictionary = {}


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--hour="):
			_only_hour = a.substr(7)
		elif a == "--no-vfx":
			_no_vfx = true
		elif a == "--keep-chrome":
			_keep_chrome = true
	# THE LAB GRADES THE BAKER, NOT THE DISK. `LcnArtCache` keys baked sprites by
	# name under an ART_VERSION that a human has to remember to bump, and a
	# forgotten bump makes this whole suite certify the art of an earlier run.
	# That is not a hypothetical: the keener was redrawn and re-measured at an
	# identical 117 screen pixels because v17/agent_keener.png already existed.
	# tests/render/test_sprites.gd learned the same thing about silhouettes and
	# turns the cache off in `before_all`; a suite that photographs the art has
	# even less business reading yesterday's.
	LcnArtCache.set_enabled(false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for h: Dictionary in HOURS:
		if _only_hour != "" and String(h["name"]) != _only_hour:
			continue
		for z: Dictionary in ZOOMS:
			_shots.append({"hour": h, "zoom": z})


func _process(_delta: float) -> void:
	if _done:
		return
	# This suite grades PIXELS. Headless there is no framebuffer to read, so
	# get_viewport().get_texture().get_image() hands back null and every capture
	# raised — 48 blocking engine errors per gate run, against an invariant this
	# project holds at zero. A check that cannot be asked is UNCHECKED, never a
	# pass and never a crash; tests/boot/run_reachability.gd settled that
	# vocabulary and tests/tutorial/run_tutorial.gd follows it.
	if DisplayServer.get_name() == "headless":
		print("  UNCHECKED the look — %d frame(s) not graded: no display server, "
			% _shots.size()
			+ "so there is no framebuffer to photograph")
		print("  run it with: xvfb-run -a -s \"-screen 0 1920x1080x24\" "
			+ "$GODOT --path . --resolution 1920x1080 tests/render/frame_lab.tscn")
		print("TESTS PASSED, PARTIAL")
		_finish(126)
		return
	_frame += 1
	if _frame == 1:
		_build_world()
		return
	if _renderer == null:
		print("frame_lab: no renderer could be installed")
		print("TESTS FAILED")
		_finish(1)
		return
	if _cursor >= _shots.size():
		if not _foes_done:
			_stage_the_night()
			return
		if not _crowd_done:
			_stage_the_crowd()
			return
		if not _wear_done:
			_stage_the_wear()
			return
		if not _storm_done:
			_stage_the_storm()
			return
		_summarise()
		return
	var shot: Dictionary = _shots[_cursor]
	_aim(shot)
	if _wait < SETTLE_FRAMES:
		_wait += 1
		return
	_capture(shot)
	_wait = 0
	_cursor += 1


# ------------------------------------------------------- the night, staged --

## THE ONE QUESTION A TOWER DEFENSE FRAME HAS TO ANSWER: at the hour and the
## zoom the game is played at, CAN YOU SEE THE THING THAT IS COMING.
##
## The hour matrix above photographs a settlement with nobody in it — the
## preview world has no crowd and the frame lab has no simulation, which is
## honest but says nothing about combat. So the last beat stands the ten
## designed enemies in a row on open ground at deep night, at zoom 0.60, and
## grades each one INDIVIDUALLY: the strongest pixel inside its footprint,
## against the median of the ground immediately around it.
##
## This is the check that ten enemies sharing one 18 px sprite would have
## passed and ten enemies nobody can see would fail. It is deliberately not a
## whole-frame statistic: a boss lighting up the corner of the screen must not
## be allowed to certify that a drift hound is visible.
## HOW THIS IS MEASURED, AND WHY IT IS MEASURED THIS WAY. The frame is
## photographed TWICE from the identical camera at the identical hour: once with
## `entities.draw_agents` off and once with it on. The creature's read is the
## DIFFERENCE — the pixels it and only it changed.
##
## The first version of this check did not do that. It measured "how far the
## brightest pixel near the enemy sits from the median of a ring around it",
## which sounded like a legibility metric and was not: on ground with drift
## structure in it, 55% of any box departs from its own median, so the number
## came out at 0.60 whether the enemies were drawn at full size, at a fifth of
## it, or (as the control run proved) with the size floor switched off entirely.
## It moved by 0.02 across a 2.4x change in the thing it was supposedly grading.
## A check that cannot go red is not a check, and this project has already paid
## for that lesson twice — once for a suite whose precondition never fired and
## once for a grader that photographed a menu.
##
## The differential cannot make that mistake: with nothing drawn the difference
## is exactly zero.
const FOE_SPACING: float = 74.0
## Peak luminance change the creature makes to the ground it stands on.
const FOE_MIN_CONTRAST: float = 0.035
## Screen pixels it changes at all. This is the number the figure floor in
## LcnEntityRenderer.agent_scale exists to hold up: at zoom 0.60 an unscaled
## 22x13 drift hound covers about 50 of them, which is a hairline.
const FOE_MIN_PIXELS: int = 130

func _stage_the_night() -> void:
	if _renderer == null:
		_foes_done = true
		return
	var model: LcnWorldModel = _renderer.world_model()
	if _foe_wait == 0:
		# Out on the plain, well clear of the settlement, so what lights an
		# enemy is the enemy — not a hearth thirty tiles away doing its job.
		var row: Vector2 = _centre + Vector2(-FOE_SPACING * 5.0, -520.0)
		var kinds: Array[StringName] = LcnSpriteFactory.ENEMY_KINDS
		for i: int in kinds.size():
			var p: Vector2 = row + Vector2(float(i) * FOE_SPACING, 0.0)
			# Twice, so `prev` and `cur` differ and the facing flip is exercised:
			# half the row walks left, half walks right.
			var d: float = 6.0 if i % 2 == 0 else -6.0
			model.set_agent(9000 + i, kinds[i], p - Vector2(d, 0.0))
			model.set_agent(9000 + i, kinds[i], p)
		# ...and one of them has just died, so the death mark is in the picture
		# too rather than being a code path nothing ever photographs.
		_renderer.entities.mark_death(row + Vector2(FOE_SPACING * 2.0, 48.0),
			&"hoarfrost_breaker")
		SimClock.tick = int(fposmod(0.0 - 0.22, 1.0) * 40.0 * 20.0)
		if _cam != null:
			_cam.position = row + Vector2(FOE_SPACING * 4.5, 0.0)
			_cam.zoom = Vector2(0.60, 0.60)
			_cam.force_update_scroll()
	_foe_wait += 1
	if _foe_wait <= SETTLE_FRAMES:
		# The control plate: the same night, the same camera, nobody in it.
		if _foe_wait == SETTLE_FRAMES:
			_renderer.entities.draw_agents = false
		return
	if _bare == null:
		_strip_chrome()
		var btex: ViewportTexture = get_viewport().get_texture()
		_bare = btex.get_image() if btex != null else null
		if _bare != null:
			_bare.save_png(ProjectSettings.globalize_path("%s/night_foes_bare.png" % OUT))
		_renderer.entities.draw_agents = true
		return
	_foes_done = true
	_strip_chrome()
	var tex: ViewportTexture = get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		print("  UNCHECKED night_foes — the viewport handed back no image")
		return
	img.save_png(ProjectSettings.globalize_path("%s/night_foes.png" % OUT))
	var xf: Transform2D = get_viewport().get_canvas_transform()
	var kinds2: Array[StringName] = LcnSpriteFactory.ENEMY_KINDS
	var row2: Vector2 = _centre + Vector2(-FOE_SPACING * 5.0, -520.0)
	for i2: int in kinds2.size():
		var scr: Vector2 = xf * (row2 + Vector2(float(i2) * FOE_SPACING, 0.0))
		var r: Dictionary = _contrast_at(img, _bare, scr)
		r["kind"] = String(kinds2[i2])
		_foe_report.append(r)
		print("  foe %-20s changes %4d px, peak %.4f, %.1f%% of its box" % [
			r["kind"], int(r["pixels"]), float(r["contrast"]), float(r["fill"]) * 100.0])


## What this creature and only this creature does to the picture. `lit` is the
## frame with the agents drawn, `bare` the identical frame without them; the
## return is the size and the strength of the difference inside its box.
static func _contrast_at(lit: Image, bare: Image, scr: Vector2) -> Dictionary:
	var cx: int = int(scr.x)
	var cy: int = int(scr.y)
	var w: int = mini(lit.get_width(), bare.get_width())
	var h: int = mini(lit.get_height(), bare.get_height())
	var pixels: int = 0
	var total: int = 0
	var peak: float = 0.0
	for dy: int in range(-46, 14):
		for dx: int in range(-34, 35):
			var x: int = cx + dx
			var y: int = cy + dy
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			total += 1
			var a: Color = lit.get_pixel(x, y)
			var b: Color = bare.get_pixel(x, y)
			var d: float = absf(
				(a.r - b.r) * 0.2126 + (a.g - b.g) * 0.7152 + (a.b - b.b) * 0.0722)
			peak = maxf(peak, d)
			if d > 0.012:
				pixels += 1
	return {
		"pixels": pixels, "contrast": peak,
		"fill": float(pixels) / float(maxi(total, 1)),
	}


# ------------------------------------------------------ the city, inhabited --
#
# THE COMPLAINT THIS BEAT EXISTS FOR, in a critic's words about a real frame of
# this build: "`render` logs 18–34 agents and I could find one human figure",
# and "the city does not occupy the screen". Both are statements about PIXELS at
# the zoom a session is played at, and neither was measured by anything.
#
# So: the settlement, the camera at 0.60 where the overlay legends say a player
# sits, the crowd walked for CROWD_TICKS so it has been somewhere — then the
# frame photographed twice from the identical camera at the identical tick, once
# with `entities.draw_agents` off and once with it on. What the people and only
# the people put on the screen is the difference, and it is graded two ways:
#
#   REACH    how many pixels of the frame they changed at all. A city whose
#            population is invisible changes almost none.
#   PLACES   how many 24x24 screen blocks contain enough changed pixels to be
#            somebody. This is the "I could find one human figure" number, and
#            it is the one a whole-frame statistic cannot fake: forty people in
#            one corner and one person is the same REACH and a very different
#            PLACES.
#
# The floors are set below what the current build measures, with headroom, and
# above what the build BEFORE this pass measured — which was 18 unenlarged
# figures with no tracks behind them. Proven by reverting game/view/render in a
# scratch tree and watching this beat go red, which is the only way to know a
# green means anything.
const CROWD_TICKS: int = 64
const CROWD_BLOCK: int = 24
## Changed pixels in a block before that block counts as "somebody is there".
const CROWD_BLOCK_MIN: int = 7
## MEASURED, both sides. This build: 46 agents, 400 boot marks, 14701 changed
## pixels in 308 places. The build before this pass, photographed by this same
## beat in a scratch worktree at HEAD~1: 46 agents, 0 boot marks, 10486 pixels
## in 246 places. The floors sit between the two, so the check is red against
## the code it was written for and has room for a frame that lands slightly
## differently on another GPU.
const CROWD_MIN_REACH: int = 12500
const CROWD_MIN_PLACES: int = 275
## What it takes for ONE person to count as findable: screen pixels they change,
## and the peak luminance step they make on the ground they stand on.
const PERSON_MIN_PX: int = 90
const PERSON_MIN_CONTRAST: float = 0.035
## ...and how much of the crowd has to clear that bar. NOT the worst case: a
## citizen who has walked behind the hearth is legitimately invisible and always
## will be, and a floor on the single worst figure in the frame is a floor on
## occlusion. This says the population is findable, which is the claim the judge
## disputed, and it cannot be paid by one bright figure or by the boot marks.
const PERSON_MIN_FINDABLE: float = 0.75
## How many of the crowd have to be inside the frame at all for that fraction to
## mean anything. Below this the beat is measuring three people.
const PERSON_MIN_COUNTED: int = 12


func _stage_the_crowd() -> void:
	if _renderer == null:
		_crowd_done = true
		return
	var model: LcnWorldModel = _renderer.world_model()
	if _crowd_step == 0:
		if _cam != null:
			_cam.position = _centre
			_cam.zoom = Vector2(0.60, 0.60)
			_cam.force_update_scroll()
		# Start mid-afternoon so the figures are read against lit snow, which is
		# the hardest case for a dark coat and the commonest frame in a session.
		SimClock.tick = int(fposmod(0.58 - 0.22, 1.0) * 40.0 * 20.0)
		# The night beat left eleven creatures standing on the plain 520 px north
		# of here, and they are agents. This beat is about the CITY's people, so
		# they go before anything is counted — otherwise the population number
		# includes the enemy and the floor below means nothing.
		for i: int in LcnSpriteFactory.ENEMY_KINDS.size():
			model.remove_agent(9000 + i)
		_renderer.entities.clear_tracks()
		_renderer.entities.clear_deaths()
	_crowd_step += 1
	if _crowd_step <= CROWD_TICKS:
		# One simulation tick per frame: the renderer lays boot marks on tick
		# CHANGES, so walking the crowd inside one frame would leave no trail at
		# all and grading it would be grading a bug.
		SimClock.tick += 1
		model.advance(SimClock.tick)
		return
	# From here the clock is FROZEN, so the two plates differ by the crowd and
	# by nothing else — not by a figure that took another step between them.
	if _crowd_step == CROWD_TICKS + 1:
		_renderer.entities.draw_agents = false
		return
	if _crowd_bare == null:
		if _crowd_step <= CROWD_TICKS + 1 + SETTLE_FRAMES:
			return
		_strip_chrome()
		var btex: ViewportTexture = get_viewport().get_texture()
		_crowd_bare = btex.get_image() if btex != null else null
		if _crowd_bare != null:
			_crowd_bare.save_png(ProjectSettings.globalize_path("%s/crowd_bare.png" % OUT))
		_renderer.entities.draw_agents = true
		_crowd_lit_at = _crowd_step + SETTLE_FRAMES
		return
	if _crowd_step < _crowd_lit_at:
		return
	_crowd_done = true
	_strip_chrome()
	var tex: ViewportTexture = get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null or _crowd_bare == null:
		print("  UNCHECKED the crowd — the viewport handed back no image")
		return
	img.save_png(ProjectSettings.globalize_path("%s/crowd.png" % OUT))
	_crowd = _crowd_grade(img, _crowd_bare)
	_crowd["agents"] = model.agent_count()
	_crowd["tracks"] = int(_renderer.entities.stats()["tracks"])
	_grade_each_person(img, _crowd_bare, model)
	print("  crowd  %d agents, %d boot marks — they change %d px in %d places on the screen"
		% [int(_crowd["agents"]), int(_crowd["tracks"]),
			int(_crowd["reach"]), int(_crowd["places"])])
	print("  crowd  %d of them inside the frame; %d are individually findable (%.0f%%), "
		% [int(_crowd["counted"]), int(_crowd["findable"]),
			float(_crowd["findable_frac"]) * 100.0]
		+ "the 10th-percentile figure covers %d px, the median %d px"
		% [int(_crowd["p10_px"]), int(_crowd["median_px"])])


## CAN YOU FIND A PERSON — asked once per person, not once per frame.
##
## REACH and PLACES above are aggregates, and an aggregate is exactly what a
## judge's "I could find one human figure" does not dispute: thirty people and
## four hundred boot marks put plenty of pixels on the screen between them. The
## question is whether ANY GIVEN ONE of them is findable, which is the question
## the night beat already asks of every enemy — so it is asked here of every
## citizen, by the same differential, and reported by its WORST case.
##
## The box is centred on the figure's own screen position through the live canvas
## transform, so this measures the person and not the neighbourhood: a trail of
## boot marks two tiles away cannot sign for a citizen nobody can see.
func _grade_each_person(lit: Image, bare: Image, model: LcnWorldModel) -> void:
	var xf: Transform2D = get_viewport().get_canvas_transform()
	var half: int = int(LcnEntityRenderer.MIN_AGENT_PX * 0.75)
	var w: int = mini(lit.get_width(), bare.get_width())
	var h: int = mini(lit.get_height(), bare.get_height())
	var pxs: Array[int] = []
	var findable: int = 0
	for ag: Dictionary in model.agents(1.0):
		if LcnSpriteFactory.is_enemy_kind(ag["kind"]):
			continue
		var s: Vector2 = xf * (ag["pos"] as Vector2)
		var x0: int = int(s.x) - half
		var y0: int = int(s.y) - half * 2
		if x0 < 0 or y0 < 0 or x0 + half * 2 >= w or y0 + half * 2 + half >= h:
			continue
		var hits: int = 0
		var peak: float = 0.0
		for y: int in range(y0, y0 + half * 3):
			for x: int in range(x0, x0 + half * 2):
				var a: Color = lit.get_pixel(x, y)
				var b: Color = bare.get_pixel(x, y)
				var d: float = absf(
					(a.r - b.r) * 0.2126 + (a.g - b.g) * 0.7152 + (a.b - b.b) * 0.0722)
				if d > 0.012:
					hits += 1
				peak = maxf(peak, d)
		pxs.append(hits)
		if hits >= PERSON_MIN_PX and peak >= PERSON_MIN_CONTRAST:
			findable += 1
	pxs.sort()
	_crowd["counted"] = pxs.size()
	_crowd["findable"] = findable
	_crowd["findable_frac"] = float(findable) / float(maxi(1, pxs.size()))
	_crowd["p10_px"] = pxs[pxs.size() / 10] if not pxs.is_empty() else 0
	_crowd["median_px"] = pxs[pxs.size() / 2] if not pxs.is_empty() else 0


## REACH and PLACES: what the people put on the screen, and how spread out it is.
static func _crowd_grade(lit: Image, bare: Image) -> Dictionary:
	var w: int = mini(lit.get_width(), bare.get_width())
	var h: int = mini(lit.get_height(), bare.get_height())
	var reach: int = 0
	var places: int = 0
	var by: int = 0
	while by + CROWD_BLOCK <= h:
		var bx: int = 0
		while bx + CROWD_BLOCK <= w:
			var hits: int = 0
			for y: int in range(by, by + CROWD_BLOCK):
				for x: int in range(bx, bx + CROWD_BLOCK):
					var a: Color = lit.get_pixel(x, y)
					var b: Color = bare.get_pixel(x, y)
					var d: float = absf(
						(a.r - b.r) * 0.2126 + (a.g - b.g) * 0.7152 + (a.b - b.b) * 0.0722)
					if d > 0.012:
						hits += 1
			reach += hits
			if hits >= CROWD_BLOCK_MIN:
				places += 1
			bx += CROWD_BLOCK
		by += CROWD_BLOCK
	return {"reach": reach, "places": places}


# ------------------------------------------------------- the weather, still --
#
# "There is no visible weather in a still." [P14] draws the flakes and does it
# well, but a photograph of falling snow at 0.60 is a scatter of specks, so the
# weather has to reach the GROUND to survive being looked at — see the spindrift
# block in terrain.gdshader.
#
# Graded as a differential, for the same reason the night beat is: the same
# camera, the same hour, the same frozen tick, [P14]'s layers HIDDEN so what is
# measured is [P13]'s ground and not somebody else's particles, and the only
# difference between the two plates is what [P09] says the wind is doing. With
# the old shader that difference is exactly zero, because `storm` reached
# nothing.
#
# The storm is delivered the way the game delivers it — a climate system with
# `storm_intensity()` — and not by poking the material, so this grades the path
# a player's blizzard actually takes.
const STORM_MIN_REACH: float = 0.10
const STORM_MIN_DELTA: float = 0.006

## ── AND THE WEATHER THAT ACTUALLY HAPPENS ─────────────────────────────────────
##
## The blizzard plate has passed since the ground learned about `storm`, and the
## build still came back from a critic as "there is no visible weather in a
## still". Both are true, because the ground was driven off `storm_intensity()`,
## which is [P09]'s GREAT FROST envelope — a scheduled campaign event.
##
## `artifacts/F4b_probe/metrics.csv` (first_night, seed 7, 9000 ticks) says what
## a session is actually made of: `climate.storm_intensity` is 0.000 on every
## row, and `climate.weather` reads `snowfall` for roughly 7000 of them, wind
## 0.22–0.31, visibility down to 0.83. So the hours a player and a critic look
## at were rendered dead calm, and the blizzard test passed the whole time.
##
## This plate is that run's own numbers. It is the honest question: does an
## ORDINARY SNOWING AFTERNOON look different from a still one.
## MEASURED BOTH SIDES. This build, with the stub reporting exactly what
## artifacts/F4b_probe reports (snowfall, intensity 0.55, wind 0.28, storm
## envelope 0.000): 9.4% of the frame, mean |delta| 0.0058, ground told 0.30.
## The build before this pass, same beat, same plates: 0.0% and 0.0000 — not
## approximately zero, EXACTLY zero, because `storm` reached nothing on an
## ordinary day. The floors sit between the two with room for another GPU.
const SNOW_MIN_REACH: float = 0.045
const SNOW_MIN_DELTA: float = 0.0025


class StubClimate extends SimSystem:
	## The methods LcnWorldModel asks the weather for, and nothing else: a stub
	## that also answered the hour would move every other number in this report.
	## `storm_intensity` is present and returns 0 on the snowfall plate ON
	## PURPOSE — that is what the real ClimateSystem does on an ordinary day, and
	## it is what makes this beat red against a renderer that reads only it.
	var intensity: float = 0.0
	var kind: StringName = &"clear"
	var inten: float = 0.0
	var gust: float = 0.0

	func system_name() -> StringName:
		return &"climate"

	func storm_intensity() -> float:
		return intensity

	func weather() -> StringName:
		return kind

	func weather_intensity() -> float:
		return inten

	func wind() -> float:
		return gust


func _stage_the_storm() -> void:
	if _renderer == null:
		_storm_done = true
		return
	if _storm_step == 0:
		_stub_climate = StubClimate.new()
		Sim.by_name[&"climate"] = _stub_climate
		_renderer.world_model().attach()
		# The clock is frozen for the whole beat: three plates that differ by the
		# weather and by nothing else, not by the hour drifting between them.
		# (With no climate answering the hour, `day_fraction` runs off
		# SimClock.seconds, so an unfrozen clock would relight the frame.)
		SimClock.tick = int(fposmod(0.58 - 0.22, 1.0) * 40.0 * 20.0)
		# [P14]'s snow lives on layers 52–59, under [P13]'s post layer, so the
		# chrome strip leaves it alone — correctly, it is part of the look. It is
		# hidden HERE because this particular measurement is of the ground, and a
		# particle field that animates between two plates would sign the check
		# for a shader that did nothing.
		_hide_vfx()
	_storm_step += 1
	if _storm_step <= SETTLE_FRAMES:
		return
	var stub: StubClimate = _stub_climate as StubClimate
	if _calm_plate == null:
		_strip_chrome()
		var ctex: ViewportTexture = get_viewport().get_texture()
		_calm_plate = ctex.get_image() if ctex != null else null
		if _calm_plate != null:
			_calm_plate.save_png(ProjectSettings.globalize_path("%s/weather_calm.png" % OUT))
		# PLATE 2: the weather a session is made of. Verbatim from
		# artifacts/F4b_probe/metrics.csv — snowfall, wind 0.28, and a Great
		# Frost envelope of exactly zero, because that is what the real climate
		# reports on an ordinary afternoon.
		stub.kind = &"snowfall"
		stub.inten = 0.55
		stub.gust = 0.28
		stub.intensity = 0.0
		_storm_step = 1
		return
	if _snow_plate == null:
		_strip_chrome()
		var stex: ViewportTexture = get_viewport().get_texture()
		_snow_plate = stex.get_image() if stex != null else null
		if _snow_plate != null:
			_snow_plate.save_png(ProjectSettings.globalize_path("%s/weather_snowfall.png" % OUT))
			_snow_report = _storm_grade(_snow_plate, _calm_plate)
			var mdl: LcnWorldModel = _renderer.world_model()
			# Guarded so the beat runs against a build with no composed weather:
			# there it reports 0.0% and 0.00, which is the red it exists for.
			var told: float = mdl.ground_weather() if mdl.has_method("ground_weather") \
				else mdl.storm()
			print("  snow   an ordinary snowing afternoon changes %.1f%% of the frame, "
				% [float(_snow_report["reach"]) * 100.0]
				+ "mean |delta| %.4f — the ground is told %.2f"
				% [float(_snow_report["delta"]), told])
		# PLATE 3: the Great Frost, which is what was being measured before.
		stub.kind = &"great_frost"
		stub.inten = 1.0
		stub.gust = 0.9
		stub.intensity = 1.0
		_storm_step = 1
		return
	_storm_done = true
	_strip_chrome()
	var tex: ViewportTexture = get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null or _calm_plate == null:
		print("  UNCHECKED the weather — the viewport handed back no image")
		return
	img.save_png(ProjectSettings.globalize_path("%s/weather_storm.png" % OUT))
	_storm_report = _storm_grade(img, _calm_plate)
	print("  storm  changes %.1f%% of the frame, mean |delta| %.4f — the ground in a blizzard"
		% [float(_storm_report["reach"]) * 100.0, float(_storm_report["delta"])])


# ------------------------------------------------------ the ground remembers --
#
# "Hour 3 looks like hour 1 because the city never fills the frame." — the blind
# judge, on a build where the only thing in the picture that could accumulate
# was the boot marks, which are a 420-entry ring buffer that forgets in 26
# seconds. Everything else in the frame is a function of the buildings and the
# hour, so two photographs taken three hours apart at the same hour of the same
# unchanged settlement were the SAME PICTURE, and correctly so.
#
# The wear field is the answer, and this is the measurement of it: the identical
# camera, the identical frozen hour, the identical settlement, [P14] hidden and
# THE PEOPLE THEMSELVES HIDDEN IN BOTH PLATES — so the only difference between
# the two frames is what the ground remembers about where they went.
#
# Against a build with no wear field the difference is exactly zero: the old
# "tracks" were contour lines of a static noise field revealed by the building
# presence texture, and no amount of walking moved them by one pixel.
const WEAR_TICKS: int = 260
## Fraction of the frame the city's own history is allowed to occupy, and the
## mean step it makes. Deliberately below the storm's floors: this is the ground
## going quietly darker along the routes people use, not weather.
## MEASURED BOTH SIDES, and the floors are what the beat is worth rather than
## what the code happens to produce. This build: 260 ticks of 46 people, 1707
## footfalls, 8.42% of the frame at mean |delta| 0.0088. A build with no wear
## field: 0.00% and 0.0000, because the old "tracks" were contour lines of a
## static noise field and no amount of walking moved them.
##
## The first two attempts at the response curve scored 0.37% and 1.13% and BOTH
## looked identical to the fresh plate with the two crops held side by side —
## which is why these floors are set where a human can see the difference and
## not merely where the number is non-zero.
const WEAR_MIN_REACH: float = 0.040
const WEAR_MIN_DELTA: float = 0.0035


func _stage_the_wear() -> void:
	if _renderer == null or _renderer.terrain == null or _renderer.terrain.field == null:
		_wear_done = true
		return
	var field: LcnTerrainField = _renderer.terrain.field
	var model: LcnWorldModel = _renderer.world_model()
	# SET UP ONCE. `_wear_step` is reset to zero between the two phases, so the
	# setup cannot hang off it — the first draft did, re-entered this block after
	# plate A, and switched the crowd back OFF for the entire walk. The frame lab
	# reported 0 agents and 0 boot marks for 177 straight frames and would have
	# gone on to grade the wear field at exactly zero, which is the shape of a
	# suite that measures nothing and says so in a number that looks like a
	# finding.
	if not _wear_begun:
		_wear_begun = true
		if _cam != null:
			_cam.position = _centre
			_cam.zoom = Vector2(0.60, 0.60)
			_cam.force_update_scroll()
		_wear_tick = int(fposmod(0.58 - 0.22, 1.0) * 40.0 * 20.0)
		SimClock.tick = _wear_tick
		# A plain nobody has crossed yet. The crowd beat has already walked this
		# settlement for 64 ticks, so the field has to be emptied or plate A is
		# an hour-1 photograph of an hour-1-and-a-bit city.
		#
		# Guarded, so this beat can be run in a scratch worktree against a build
		# that has no wear field at all. That is the point of it: there it takes
		# the same two photographs and reports 0.00%, which is the red this check
		# was written for. A beat that crashed on the old code would prove
		# nothing about it.
		if field.has_method("clear_wear"):
			field.clear_wear()
		for i: int in LcnSpriteFactory.ENEMY_KINDS.size():
			model.remove_agent(9000 + i)
		_renderer.entities.draw_agents = false
	_wear_step += 1
	if _wear_fresh == null:
		if _wear_step <= SETTLE_FRAMES:
			return
		_strip_chrome()
		var ftex: ViewportTexture = get_viewport().get_texture()
		_wear_fresh = ftex.get_image() if ftex != null else null
		if _wear_fresh != null:
			_wear_fresh.save_png(ProjectSettings.globalize_path("%s/wear_fresh.png" % OUT))
		_renderer.entities.draw_agents = true
		_wear_step = 0
		return
	if _wear_walked < WEAR_TICKS:
		# One sim tick per frame, exactly as the crowd beat does: wear is written
		# on tick CHANGES, so walking the crowd inside one frame would wear
		# nothing and grading it would be grading a bug.
		_wear_walked += 1
		SimClock.tick += 1
		model.advance(SimClock.tick)
		# A walk in which nobody walks is the failure this beat is most likely to
		# have and least likely to notice, so it is checked while it happens
		# rather than inferred from the picture afterwards.
		if _wear_walked == WEAR_TICKS:
			_wear_report["walked_agents"] = int(_renderer.entities.stats()["visible_agents"])
			_wear_report["walked_tracks"] = int(_renderer.entities.stats()["tracks"])
		_wear_step = 0
		return
	if _wear_step == 1:
		# THE HOUR GOES BACK. With no climate system the day is driven off
		# SimClock.seconds, so 420 ticks is a fifth of the day cycle and the two
		# plates would differ by the light before they differed by the ground.
		# The wear field is not on the clock and does not care.
		SimClock.tick = _wear_tick
		_renderer.entities.draw_agents = false
		return
	if _wear_step <= 1 + SETTLE_FRAMES:
		return
	_wear_done = true
	_strip_chrome()
	var tex: ViewportTexture = get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null or _wear_fresh == null:
		print("  UNCHECKED the ground's memory — the viewport handed back no image")
		return
	img.save_png(ProjectSettings.globalize_path("%s/wear_lived.png" % OUT))
	var walked_agents: int = int(_wear_report.get("walked_agents", 0))
	var walked_tracks: int = int(_wear_report.get("walked_tracks", 0))
	_wear_report = _storm_grade(img, _wear_fresh)
	_wear_report["walked_agents"] = walked_agents
	_wear_report["walked_tracks"] = walked_tracks
	_wear_report["mean"] = field.wear_mean() if field.has_method("wear_mean") else 0.0
	_wear_report["stamps"] = int(field.stats().get("wear_stamps", 0))
	_renderer.entities.draw_agents = true
	print("  wear   %d ticks of %d visible people (%d boot marks, %d footfalls recorded): "
		% [WEAR_TICKS, walked_agents, walked_tracks, int(_wear_report["stamps"])]
		+ "the same frame differs by %.2f%% of the screen, mean |delta| %.4f "
		% [float(_wear_report["reach"]) * 100.0, float(_wear_report["delta"])]
		+ "(field mean %.5f) — the ground remembers" % float(_wear_report["mean"]))


func _hide_vfx() -> void:
	for n: Node in get_tree().get_nodes_in_group(&"lcn_vfx"):
		var cl := n as CanvasLayer
		if cl != null:
			cl.visible = false
			continue
		var ci := n as CanvasItem
		if ci != null:
			ci.visible = false


## Fraction of the frame the weather touched, and by how much on average.
static func _storm_grade(storm: Image, calm: Image) -> Dictionary:
	var w: int = mini(storm.get_width(), calm.get_width())
	var h: int = mini(storm.get_height(), calm.get_height())
	var changed: int = 0
	var total: int = 0
	var sum: float = 0.0
	var y: int = 0
	while y < h:
		var x: int = 0
		while x < w:
			var a: Color = storm.get_pixel(x, y)
			var b: Color = calm.get_pixel(x, y)
			var d: float = absf(
				(a.r - b.r) * 0.2126 + (a.g - b.g) * 0.7152 + (a.b - b.b) * 0.0722)
			sum += d
			if d > 0.010:
				changed += 1
			total += 1
			x += 2
		y += 2
	return {
		"reach": float(changed) / float(maxi(total, 1)),
		"delta": sum / float(maxi(total, 1)),
	}


func _finish(code: int) -> void:
	_done = true
	get_tree().quit(code)


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
	# The camera is found HERE and not lazily inside `_aim`. Run this lab with
	# `--hour=` naming an hour that does not exist and the shot list is empty, so
	# `_aim` never runs, `_cam` stays null, no beat ever points the camera at the
	# settlement — and the night beat dutifully reports that all eleven creatures
	# change zero pixels. It fails loudly rather than passing, but the number it
	# prints is about an unaimed camera and not about the art.
	_cam = _find_camera(get_tree().root)
	if _no_vfx:
		for n: Node in get_tree().get_nodes_in_group(&"lcn_vfx"):
			n.queue_free()
		print("frame_lab: vfx layer removed (--no-vfx)")
	_strip_chrome()
	print("frame_lab: %d structures, %d agents, world %s" % [
		model.building_count(), model.agent_count(), str(model.world_size())])


## Removes everything drawn above [P13]'s post layer, then reports what is
## still there. Layer 0 (the world) and layer 60 (POST) are the look; every
## number above them belongs to another part and is not what this lab grades.
##
## [P24]'s title screen is `opaque` and sits on MODAL (80), which is how 24
## photographs of a main menu were reported as the art of this game.
func _strip_chrome() -> void:
	var above: Array[CanvasLayer] = []
	_collect_layers(get_tree().root, above)
	for cl: CanvasLayer in above:
		if cl.layer <= LcnLayers.POST:
			continue
		var tag: String = "%s@%d" % [cl.name, cl.layer]
		var first: bool = not _seen_chrome.has(tag)
		_seen_chrome[tag] = true
		if _keep_chrome:
			if first:
				print("frame_lab: KEEPING chrome '%s' on layer %d (--keep-chrome)" % [cl.name, cl.layer])
			continue
		# HIDDEN, not freed. Freeing [P15]'s screen layer left [P14] and [P15]
		# holding references to it and printed two script errors per frame for
		# the rest of the run — a lab that corrupts the build it is
		# photographing is not measuring the build. `visible = false` on a
		# CanvasLayer stops it reaching the framebuffer, which is the entire
		# requirement here.
		print("frame_lab: hiding '%s' on layer %d — not [P13]'s to photograph"
			% [cl.name, cl.layer])
		cl.visible = false
	# Re-scan. A strip that trusted its own first pass would miss anything a
	# deferred installer adds afterwards, and that is exactly the failure mode
	# this check exists to make loud.
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


## The hour is driven through SimClock because that is what the renderer reads;
## poking the grade directly would photograph a lighting state the game cannot
## reach.
func _aim(shot: Dictionary) -> void:
	var hour: Dictionary = shot["hour"]
	var zoom: Dictionary = shot["zoom"]
	SimClock.tick = int(fposmod(float(hour["t"]) - 0.22, 1.0) * 40.0 * 20.0)
	if _cam == null:
		_cam = _find_camera(get_tree().root)
	if _cam != null:
		_cam.position = _centre
		_cam.zoom = Vector2(float(zoom["z"]), float(zoom["z"]))
		_cam.force_update_scroll()


func _capture(shot: Dictionary) -> void:
	var hour: Dictionary = shot["hour"]
	var zoom: Dictionary = shot["zoom"]
	var stem: String = "%s_%s" % [hour["name"], zoom["name"]]
	# Re-checked at the shutter, not only at setup: a layer installed one frame
	# after the world was built is still in the photograph.
	_strip_chrome()
	var tex: ViewportTexture = get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		# Belt and braces: the headless gate is caught in _process, but a display
		# that hands back nothing must still not raise inside the render loop.
		print("  UNCHECKED %s — the viewport handed back no image" % stem)
		return
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT, stem]))
	_prints[stem] = _fingerprint(img)
	var g: Dictionary = _grade_frame(img)
	g["shot"] = stem
	g["hour"] = hour["name"]
	g["zoom"] = zoom["name"]
	_report.append(g)
	print("  %-22s lum %.3f  detail %.4f  chroma %.3f  darkest %.3f  warm %.4f  flat %.2f" % [
		stem, g["lum"], g["detail"], g["chroma"], g["p05"], g["warm"], g["flat"]])


# ------------------------------------------------------------------ grading --

## Numbers a critic's eye produces, computed instead of asserted.
##
##   lum      mean luminance — "washed out" is a high mean with a low spread
##   detail   mean |luma - 3x3 box blur|, i.e. how much local structure the
##            ground actually has. A cloud-noise field scores near zero
##   chroma   mean |max(rgb) - min(rgb)|; a grey frame scores near zero
##   p05      5th-percentile luminance — how dark the frame is allowed to get
##   warm     fraction of pixels that are decisively warm (r well over b)
##   flat     fraction of 16x16 blocks with no variation in them at all
static func _grade_frame(img: Image) -> Dictionary:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var step: int = 2
	var luma: PackedFloat32Array = PackedFloat32Array()
	var cols: int = 0
	var rows: int = 0
	var sum_l: float = 0.0
	var sum_c: float = 0.0
	var warm: int = 0
	var n: int = 0
	var y: int = 0
	while y < h:
		var x: int = 0
		cols = 0
		while x < w:
			var c: Color = img.get_pixel(x, y)
			var l: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			luma.append(l)
			sum_l += l
			sum_c += maxf(maxf(c.r, c.g), c.b) - minf(minf(c.r, c.g), c.b)
			if c.r - c.b > 0.10 and c.r > 0.18:
				warm += 1
			n += 1
			cols += 1
			x += step
		rows += 1
		y += step

	# Local structure: how far each sample sits from the mean of its neighbours.
	var detail: float = 0.0
	var dn: int = 0
	for yy: int in range(1, rows - 1):
		for xx: int in range(1, cols - 1):
			var i: int = yy * cols + xx
			var m: float = (luma[i - cols - 1] + luma[i - cols] + luma[i - cols + 1]
				+ luma[i - 1] + luma[i + 1]
				+ luma[i + cols - 1] + luma[i + cols] + luma[i + cols + 1]) / 8.0
			detail += absf(luma[i] - m)
			dn += 1

	# FLATNESS. The fraction of 16x16-sample blocks whose luminance range is under
	# one 50th of the scale — i.e. blocks with nothing in them at all. This is the
	# one number that separates "the ground shader did not compile and Godot drew
	# the fallback white quad" from "the art is merely pale": a fallback quad is
	# literally constant, while even a washed-out snowfield is not. It cost a full
	# iteration to learn that a shader compile failure does not throw, does not
	# stop the frame, and still writes 24 plausible-looking PNGs.
	var flat: int = 0
	var blocks: int = 0
	var by: int = 0
	while by + 16 <= rows:
		var bx: int = 0
		while bx + 16 <= cols:
			var lo: float = 2.0
			var hi: float = -1.0
			for yy2: int in range(by, by + 16):
				var row: int = yy2 * cols
				for xx2: int in range(bx, bx + 16):
					var v: float = luma[row + xx2]
					lo = minf(lo, v)
					hi = maxf(hi, v)
			if hi - lo < 0.02:
				flat += 1
			blocks += 1
			bx += 16
		by += 16

	var sorted: PackedFloat32Array = luma.duplicate()
	sorted.sort()
	return {
		"flat": float(flat) / float(maxi(1, blocks)),
		"lum": sum_l / float(maxi(1, n)),
		"chroma": sum_c / float(maxi(1, n)),
		"detail": detail / float(maxi(1, dn)),
		"p05": sorted[int(float(sorted.size()) * 0.05)],
		"p95": sorted[int(float(sorted.size()) * 0.95)],
		"warm": float(warm) / float(maxi(1, n)),
	}


## A 16x16 mean-luma thumbnail of the frame. Coarse on purpose: it must be
## insensitive to a stray particle and sensitive to "this is a different
## picture". Two frames of the same title screen score ~0.000 apart.
static func _fingerprint(img: Image) -> PackedFloat32Array:
	const N: int = 16
	var w: int = img.get_width()
	var h: int = img.get_height()
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(N * N)
	for by: int in range(N):
		for bx: int in range(N):
			var x0: int = bx * w / N
			var x1: int = maxi(x0 + 1, (bx + 1) * w / N)
			var y0: int = by * h / N
			var y1: int = maxi(y0 + 1, (by + 1) * h / N)
			var acc: float = 0.0
			var cnt: int = 0
			var y: int = y0
			while y < y1:
				var x: int = x0
				while x < x1:
					var c: Color = img.get_pixel(x, y)
					acc += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
					cnt += 1
					x += 4
				y += 4
			out[by * N + bx] = acc / float(maxi(1, cnt))
	return out


## Mean absolute difference between two thumbnails, in luma units.
static func _print_delta(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size() or a.is_empty():
		return 1.0
	var s: float = 0.0
	for i: int in range(a.size()):
		s += absf(a[i] - b[i])
	return s / float(a.size())


func _find(shot_name: String) -> Dictionary:
	for r: Dictionary in _report:
		if String(r["shot"]) == shot_name:
			return r
	return {}


func _summarise() -> void:
	var fails: Array[String] = []
	print("────────────────────────────────────────────────────────────────")
	print(" frame lab — %d frames in %s" % [_report.size(), OUT])
	print("────────────────────────────────────────────────────────────────")

	# -2. WHAT WAS PHOTOGRAPHED IS THE WORLD. [P24]'s opaque title screen sat on
	#     layer 80 over all 24 frames of the previous pass and every art number
	#     this project has ever quoted was measured off it. A grade of an
	#     unknown picture is worse than no grade, so this check runs first and
	#     refuses the whole report rather than annotating it.
	if not _chrome_left.is_empty():
		fails.append("the frames are not the world — %s still drew above [P13]'s post layer; every number below grades that, not the art"
			% ", ".join(_chrome_left))

	# -1. THE FRAMES ARE DIFFERENT FRAMES. Six hours and five camera distances
	#     cannot produce one picture. The zoom column is the sharp end: `close`
	#     and `strategic` are 6.6x apart, so if their thumbnails match, the
	#     camera is not what is on screen.
	var pairs: int = 0
	var identical: int = 0
	var keys: Array[String] = _prints.keys()
	keys.sort()
	for i: int in range(keys.size()):
		for j: int in range(i + 1, keys.size()):
			pairs += 1
			if _print_delta(_prints[keys[i]], _prints[keys[j]]) < 0.002:
				identical += 1
	if pairs > 0:
		print("  %d frame pairs, %d of them indistinguishable" % [pairs, identical])
	if pairs > 0 and identical * 2 > pairs:
		fails.append("%d of %d frame pairs are the same picture — the lab is photographing something that does not move with the hour or the camera"
			% [identical, pairs])
	for hour_d: Dictionary in HOURS:
		var hn: String = String(hour_d["name"])
		var a: String = "%s_close" % hn
		var b: String = "%s_strategic" % hn
		if not (_prints.has(a) and _prints.has(b)):
			continue
		var d: float = _print_delta(_prints[a], _prints[b])
		if d < 0.010:
			fails.append("%s looks the same at zoom 1.60 and 0.24 (thumbnail delta %.4f) — the camera is not framing the world"
				% [hn, d])

	# 0b. THE NIGHT HAS SOMETHING IN IT THAT YOU CAN SEE. Ten designed enemies
	#     drew one 18 px sprite before this pass; ten enemies nobody can pick
	#     out of the dark would be the same failure with better art.
	for fr: Dictionary in _foe_report:
		if float(fr["contrast"]) < FOE_MIN_CONTRAST:
			fails.append("%s does not change the picture at deep night, zoom 0.60 (peak %.4f < %.3f) — it is invisible"
				% [String(fr["kind"]), float(fr["contrast"]), FOE_MIN_CONTRAST])
		elif int(fr["pixels"]) < FOE_MIN_PIXELS:
			fails.append("%s is a hairline at deep night, zoom 0.60 — it covers %d screen pixels (want %d)"
				% [String(fr["kind"]), int(fr["pixels"]), FOE_MIN_PIXELS])
	if _foe_report.size() < LcnSpriteFactory.ENEMY_KINDS.size():
		fails.append("only %d of %d enemies were staged and graded — the night beat did not run"
			% [_foe_report.size(), LcnSpriteFactory.ENEMY_KINDS.size()])

	# 0c. THE CITY IS INHABITED, AT THE ZOOM IT IS PLAYED AT. A blind judge found
	#     one human figure in a real frame of the last build. These two numbers
	#     are that sentence, computed: how much of the screen the people put
	#     there, and in how many separate places.
	if _crowd.is_empty():
		fails.append("the crowd was never staged — the inhabited-city beat did not run")
	else:
		if int(_crowd["reach"]) < CROWD_MIN_REACH:
			fails.append("the people change only %d screen pixels at zoom 0.60 (want %d) — %d agents and the frame is empty"
				% [int(_crowd["reach"]), CROWD_MIN_REACH, int(_crowd["agents"])])
		if int(_crowd["places"]) < CROWD_MIN_PLACES:
			fails.append("there is somebody in only %d places on the screen (want %d) — a player looking at this frame finds a figure, not a population"
				% [int(_crowd["places"]), CROWD_MIN_PLACES])
		# ...and the same question asked of each person separately, because the
		# two numbers above are aggregates and the judge's sentence was not.
		if int(_crowd.get("counted", 0)) < PERSON_MIN_COUNTED:
			fails.append("only %d of the crowd were inside the frame to grade (want %d) — the per-figure floors were not really asked"
				% [int(_crowd.get("counted", 0)), PERSON_MIN_COUNTED])
		elif float(_crowd["findable_frac"]) < PERSON_MIN_FINDABLE:
			fails.append("only %d of the %d people in this frame are individually findable (%.0f%%, want %.0f%%) — each has to change %d screen pixels at %.3f contrast to count, and the 10th-percentile figure changes %d"
				% [int(_crowd["findable"]), int(_crowd["counted"]),
					float(_crowd["findable_frac"]) * 100.0, PERSON_MIN_FINDABLE * 100.0,
					PERSON_MIN_PX, PERSON_MIN_CONTRAST, int(_crowd["p10_px"])])

	# 0d. THE WEATHER IS IN THE PICTURE. Not in the air where a still cannot see
	#     it: on the ground, where a photograph can.
	if _storm_report.is_empty():
		fails.append("the storm was never staged — the weather beat did not run")
	else:
		if float(_storm_report["reach"]) < STORM_MIN_REACH:
			fails.append("a full blizzard changes only %.1f%% of the ground (want %.0f%%) — there is no visible weather in a still"
				% [float(_storm_report["reach"]) * 100.0, STORM_MIN_REACH * 100.0])
		if float(_storm_report["delta"]) < STORM_MIN_DELTA:
			fails.append("a full blizzard moves the frame by %.4f of a stop (want %.3f) — the weather is not doing anything the eye can see"
				% [float(_storm_report["delta"]), STORM_MIN_DELTA])

	# 0e. ...AND THE WEATHER THAT IS ACTUALLY BLOWING. A blizzard is a scheduled
	#     event; snowfall is most of a session, and it was rendered as a calm
	#     afternoon for every hour a critic has ever looked at.
	if _snow_report.is_empty():
		fails.append("the ordinary weather was never staged — the snowfall plate did not run")
	else:
		if float(_snow_report["reach"]) < SNOW_MIN_REACH:
			fails.append("an ordinary snowing afternoon changes only %.1f%% of the ground (want %.0f%%) — the ground is only wired to the Great Frost, which a first night never sees"
				% [float(_snow_report["reach"]) * 100.0, SNOW_MIN_REACH * 100.0])
		if float(_snow_report["delta"]) < SNOW_MIN_DELTA:
			fails.append("an ordinary snowing afternoon moves the frame by %.4f of a stop (want %.4f) — there is no visible weather in the hours the game is played in"
				% [float(_snow_report["delta"]), SNOW_MIN_DELTA])

	# 0f. THE CITY GROWS INTO THE SCREEN. Two photographs of the same settlement
	#     at the same hour from the same camera, one taken before its people had
	#     walked anywhere and one after. If they are the same picture, hour 3
	#     looks like hour 1 — which is the sentence this beat exists to answer.
	if _wear_report.is_empty():
		fails.append("the ground's memory was never staged — the wear beat did not run")
	elif int(_wear_report.get("walked_agents", 0)) < 8:
		# THE PRECONDITION, ASSERTED. A beat that walks nobody reports a perfect
		# zero and reads exactly like a renderer that forgets, which is how a
		# suite ends up passing on a check it never performed.
		fails.append("the wear beat walked %d visible people — it measured nothing, so its %.2f%% means nothing"
			% [int(_wear_report.get("walked_agents", 0)),
				float(_wear_report.get("reach", 0.0)) * 100.0])
	else:
		if float(_wear_report["reach"]) < WEAR_MIN_REACH:
			fails.append("%d footfalls change %.2f%% of the frame (want %.1f%%) — the ground does not remember anybody, so hour 3 is hour 1"
				% [int(_wear_report["stamps"]), float(_wear_report["reach"]) * 100.0,
					WEAR_MIN_REACH * 100.0])
		if float(_wear_report["delta"]) < WEAR_MIN_DELTA:
			fails.append("a day of walking moves the frame by %.4f of a stop (want %.4f) — nothing in this picture accumulates"
				% [float(_wear_report["delta"]), WEAR_MIN_DELTA])

	# 0. THE GROUND SHADER ACTUALLY COMPILED. A canvas shader that fails to
	#    compile does not throw and does not stop the frame: Godot falls back to
	#    the default material and the ground quad draws its 1x1 white texture, so
	#    the run still exits 0 and still writes 24 PNGs. This cost a full
	#    iteration — one undeclared identifier, a white plain, and a suite that
	#    reported it as "washed out" rather than as "broken".
	for f0: Dictionary in _report:
		if float(f0["flat"]) > 0.45 and float(f0["lum"]) > 0.50:
			fails.append("%s is a flat white quad — the ground shader did not compile (check the log for SHADER ERROR)"
				% f0["shot"])
			break

	# 1. THE GROUND HAS STRUCTURE. A soft cloud-noise field scores ~0.004 here;
	#    ground with tile-scale drift, rock and tracks scores several times that.
	#    Checked at `normal`, the zoom a player spends the game at.
	for hour: String in ["midday", "afternoon"]:
		var f: Dictionary = _find("%s_%s" % [hour, JUDGE_ZOOM])
		if f.is_empty():
			continue
		if float(f["detail"]) < 0.012:
			fails.append("%s_%s has no local structure (detail %.4f < 0.012) — the ground is a cloud"
				% [hour, JUDGE_ZOOM, float(f["detail"])])

	# 2. THE FRAME IS NOT WASHED OUT. Washed out = everything crowded into the
	#    top of the range with no shadow anywhere in the picture.
	for f2: Dictionary in _report:
		if String(f2["hour"]) in ["midday", "afternoon", "dawn"] and String(f2["zoom"]) != "strategic":
			if float(f2["p05"]) > 0.30:
				fails.append("%s never gets dark (5th-percentile luma %.3f > 0.30) — washed out"
					% [f2["shot"], float(f2["p05"])])
			if float(f2["lum"]) > 0.62:
				fails.append("%s mean luma %.3f > 0.62 — the frame is a white field"
					% [f2["shot"], float(f2["lum"])])

	# 3. NIGHT IS DARK AND THE CITY IS THE WARM THING IN IT.
	var noon: Dictionary = _find("midday_%s" % JUDGE_ZOOM)
	var night: Dictionary = _find("deep_night_%s" % JUDGE_ZOOM)
	if not noon.is_empty() and not night.is_empty():
		if float(night["lum"]) > float(noon["lum"]) * 0.55:
			fails.append("deep night (%.3f) is not meaningfully darker than midday (%.3f)"
				% [float(night["lum"]), float(noon["lum"])])
		if float(night["warm"]) < 0.004:
			fails.append("deep night has almost no warm pixels (%.4f) — nothing is lit"
				% float(night["warm"]))

	# 4. THE WORLD IS COLD AND BLUE, NOT GREY.
	for f3: Dictionary in _report:
		if String(f3["zoom"]) == JUDGE_ZOOM and float(f3["chroma"]) < 0.045:
			fails.append("%s is grey (chroma %.3f < 0.045) — no colour direction" % [
				f3["shot"], float(f3["chroma"])])

	for f4: String in fails:
		print("  FAIL  %s" % f4)
	if fails.is_empty():
		print("  every frame passes the structure / contrast / night / colour checks")
		print("TESTS PASSED")
		_finish(0)
	else:
		print("TESTS FAILED")
		_finish(1)


func _find_camera(n: Node) -> Camera2D:
	for c: Node in n.get_children():
		if c is Camera2D:
			return c
		var f: Camera2D = _find_camera(c)
		if f != null:
			return f
	return null

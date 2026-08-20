class_name LcnShutter
extends RefCounted
## THE TWO GUARDS EVERY SCREENSHOT IN THIS REPOSITORY GOES THROUGH.
##
## This project has now shipped THREE tools that photographed something other
## than the thing they were named for, and each one was found by a human holding
## two PNGs side by side rather than by any check in the build:
##
##   1. a sprite suite that read its own cache and certified last week's art;
##   2. `tests/render/frame_lab.gd`, whose 24 "art direction" frames were 24
##      photographs of [P24]'s title screen — every luminance, chroma and warmth
##      number this project has ever quoted about its own look was measured off
##      a list of buttons on a dark plate;
##   3. `--ui-tour`, which photographed the same title screen eleven more times
##      and reported 11 of 17 screens unreachable, because the menu was also
##      eating every key it pressed.
##
## The frame lab was fixed properly and this class is that fix, lifted out so
## the next tool inherits it instead of rediscovering it:
##
##   CHROME  nothing may be drawn above the subject when the shutter opens.
##           Not "suppressed by a flag": ASSERTED, by node name and layer
##           number, at the instant of capture. A flag rots the moment another
##           part installs a full-screen layer; an assertion cannot.
##   DIFF    photographs of different things must actually differ. Eleven
##           pictures of one menu are eleven identical fingerprints, and no
##           amount of correct-looking metadata makes them eleven screens.
##
## Both guards are about the SAME failure — the tool cannot see itself — and
## both have to be present, because either one alone is passable by the defect:
## a run with the menu suppressed by a flag still photographs a blank world if
## the camera never aimed (DIFF catches that, CHROME does not), and a run that
## photographs eleven genuinely different menu screens passes DIFF.
##
## USAGE — the caller owns the awaits, because every rig settles differently:
##
##     var shutter := LcnShutter.new(LcnLayers.STATS, "the interface")
##     ...
##     await RenderingServer.frame_post_draw
##     var img: Image = shutter.shoot(get_tree(), "01_palette")
##     if img != null: img.save_png(path)
##     ...
##     for line: String in shutter.failures():
##         Log.error("my-tool", line)
##
## `tests/gate/test_screenshot_guards.gd` fails any file in this repository that
## reads the framebuffer without going through here (or without carrying both
## guards inline, which is what the frame lab does and is asserted line by line).

## Two 16x16 luma thumbnails closer than this are the same picture. Two frames
## of one static menu score ~0.000 apart; two hours of the same city score in
## the hundredths.
const IDENTICAL: float = 0.002

## The top of the picture. Layers above this are not part of what is being
## photographed, and the shutter hides them for the capture.
var ceiling: int = LcnLayers.POST

## The layer at or above which a visible CanvasLayer is a FAILURE rather than
## merely something to hide. Defaults to `ceiling + 1`: for most rigs, anything
## above the subject at all is chrome that should not have been there.
##
## The harness sets this to MODAL for its ordinary shots, because "what a player
## sees" legitimately includes the HUD, the story card and the lens legend — but
## never a modal that has stopped the world.
var forbidden: int = LcnLayers.POST + 1

## Named in every failure message, so a red says what it was trying to look at.
var subject: String = "the world"

## When true, EVERY pair of shots must differ. Use it for a rig where each shot
## is a different screen — that is exactly the tour's contract, and the exact
## shape of the defect this class exists for. When false, the frame lab's looser
## rule applies: a majority of identical pairs fails.
var all_distinct: bool = true

## shot -> 16x16 mean-luma thumbnail.
var _prints: Dictionary[String, PackedFloat32Array] = {}
## Order the shots were taken in, so failure messages read chronologically.
var _order: PackedStringArray = PackedStringArray()
## shot -> the chrome that was above `forbidden` when its shutter opened.
var _chrome: Dictionary[String, PackedStringArray] = {}
## Shots whose viewport handed back nothing. Neither pass nor fail: UNCHECKED.
var _unchecked: PackedStringArray = PackedStringArray()
## Layers this shutter hid, so `restore()` can put the build back the way it was.
var _hidden: Array[CanvasLayer] = []


func _init(top_layer: int = LcnLayers.POST, what: String = "the world",
		forbid_at: int = -1) -> void:
	ceiling = top_layer
	forbidden = (top_layer + 1) if forbid_at < 0 else forbid_at
	subject = what


# ----------------------------------------------------------------- capture --

## `strip` then `capture`, in one call, for a rig that photographs the frame AS
## IT STANDS and only wants the assertion.
##
## ── WHEN NOT TO USE THIS, AND IT COST A ROUND TO LEARN ────────────────────────
##
## `strip` sets `visible = false`; `capture` reads pixels the GPU has ALREADY
## drawn. In one call the hiding therefore has no effect on the image at all —
## it takes a redraw for a hidden layer to leave the framebuffer. A rig that
## actually wants the chrome OUT of the picture must call `strip`, then await
## its frames, then `capture`. `LcnHarness` does exactly that for the `.world`
## variant of every shot, and when it did not, all eleven of those "the city
## with the chrome taken off" frames still had the whole HUD in them and were
## within 1-4 grey levels of the shot they were supposed to differ from.
##
## The DIFF guard is what found it, on the first run after it was written, and
## the first instinct was to widen the guard. That is how this project already
## lost a check once.
func shoot(tree: SceneTree, shot: String) -> Image:
	strip(tree, shot)
	return capture(tree, shot)


## Reads the framebuffer, fingerprints it, and re-checks for chrome that arrived
## since `strip` ran. Returns null — and records the shot as UNCHECKED — when
## there is nothing to read, which is what a headless display server gives you.
## A check that cannot be asked is never a pass and never a crash.
##
## The caller must already have awaited whatever its rig needs to settle;
## `RenderingServer.frame_post_draw` is the last thing every caller wants.
func capture(tree: SceneTree, shot: String) -> Image:
	_recheck(tree, shot)
	var vp: Viewport = tree.root as Viewport
	var tex: ViewportTexture = vp.get_texture() if vp != null else null
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		if not _unchecked.has(shot):
			_unchecked.append(shot)
		return null
	note(shot, img)
	return img


## The CHROME guard. Call it BEFORE the frames that will be drawn if the point
## is to keep the chrome out of the picture; see `shoot` above.
##
## Hides every visible CanvasLayer above `ceiling`, then records everything that
## was above `forbidden` — INCLUDING what it just hid. Hiding is a courtesy to
## whoever opens the PNG; it is not an excuse. A main menu that had to be hidden
## was in front of the lens.
func strip(tree: SceneTree, shot: String) -> void:
	var found: PackedStringArray = PackedStringArray()
	for cl: CanvasLayer in _layers(tree):
		if cl.layer <= ceiling or not draws(cl):
			continue
		if cl.layer >= forbidden:
			found.append("%s (layer %d)" % [cl.name, cl.layer])
		# Hidden, never freed. Freeing another part's screen layer leaves the
		# parts that hold a reference to it printing two script errors a frame
		# for the rest of the run, and a rig that corrupts the build it is
		# photographing is not measuring the build.
		cl.visible = false
		_hidden.append(cl)
	if not found.is_empty():
		_chrome[shot] = _merge(_chrome.get(shot, PackedStringArray()), found)
	_recheck(tree, shot)


## RE-SCAN, at the shutter itself. A strip that trusted its own earlier pass
## would miss anything a deferred installer added in between — and a deferred
## installer is exactly how [P24]'s menu got in front of the frame lab.
func _recheck(tree: SceneTree, shot: String) -> void:
	var late: PackedStringArray = PackedStringArray()
	for cl: CanvasLayer in _layers(tree):
		if cl.layer >= forbidden and draws(cl):
			late.append("%s (layer %d, still drawing at the shutter)" % [cl.name, cl.layer])
	if not late.is_empty():
		_chrome[shot] = _merge(_chrome.get(shot, PackedStringArray()), late)


static func _merge(a: PackedStringArray, b: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = a.duplicate()
	for s: String in b:
		if not out.has(s):
			out.append(s)
	return out


## Puts back everything `strip` hid. A rig that keeps playing after a shot — the
## tour does, between screens — must call this or it photographs a build it
## quietly dismantled.
func restore() -> void:
	for cl: CanvasLayer in _hidden:
		if is_instance_valid(cl):
			cl.visible = true
	_hidden.clear()


## The DIFF guard's input. Separate from `shoot` for a caller that produced its
## Image some other way (a differential plate, a sub-viewport).
func note(shot: String, img: Image) -> void:
	if img == null:
		return
	if not _prints.has(shot):
		_order.append(shot)
	_prints[shot] = fingerprint(img)


# ----------------------------------------------------------------- verdict --

## Every sentence that should turn this run red. Empty means both guards held.
##
## Ordered worst first: a frame that is not the subject makes every number
## measured off it meaningless, so CHROME is reported before DIFF and before
## anything the caller grades itself.
func failures() -> PackedStringArray:
	var out := PackedStringArray()
	for shot: String in _order:
		if _chrome.has(shot):
			out.append(("%s is not %s — %s drew over it when the shutter opened; "
				+ "every judgement made from that photograph is about the wrong picture")
				% [shot, subject, ", ".join(_chrome[shot])])
	# A shot that raised chrome but never produced an image still has to be named.
	for shot2: String in _chrome.keys():
		if not _order.has(shot2) and not _unchecked.has(shot2):
			out.append("%s is not %s — %s drew over it when the shutter opened"
				% [shot2, subject, ", ".join(_chrome[shot2])])
	out.append_array(diff_failures())
	return out


## The DIFF guard's verdict, on its own.
func diff_failures() -> PackedStringArray:
	var out := PackedStringArray()
	var keys: Array[String] = []
	for k: String in _order:
		keys.append(k)
	keys.sort()
	var pairs: int = 0
	var same: int = 0
	var named: PackedStringArray = PackedStringArray()
	for i: int in range(keys.size()):
		for j: int in range(i + 1, keys.size()):
			pairs += 1
			if delta(_prints[keys[i]], _prints[keys[j]]) < IDENTICAL:
				same += 1
				if named.size() < 12:
					named.append("%s == %s" % [keys[i], keys[j]])
	if same == 0:
		return out
	if all_distinct:
		out.append(("%d of %d %s photographs are the same picture (%s) — the "
			+ "shutter is not looking at what its names say it is")
			% [same, pairs, subject, ", ".join(named)])
	elif same * 2 > pairs:
		out.append(("%d of %d %s photographs are indistinguishable (%s) — the rig "
			+ "is photographing something that does not move with what it varies")
			% [same, pairs, subject, ", ".join(named)])
	return out


## Shots the display server could not answer. Reported as UNCHECKED by the
## caller: never a pass, never a crash.
func unchecked() -> PackedStringArray:
	return _unchecked


func shots() -> PackedStringArray:
	return _order


## One line a caller can put in a log or an artifact.
func summary() -> String:
	return "%d shot(s), %d unchecked, %d with chrome over them" % [
		_order.size(), _unchecked.size(), _chrome.size()]


# --------------------------------------------------------------- internals --

## A 16x16 mean-luma thumbnail. Coarse on purpose: insensitive to a stray
## particle, sensitive to "this is a different picture".
static func fingerprint(img: Image) -> PackedFloat32Array:
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
static func delta(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size() or a.is_empty():
		return 1.0
	var s: float = 0.0
	for i: int in range(a.size()):
		s += absf(a[i] - b[i])
	return s / float(a.size())


## ── THE EXEMPTION THAT IS NOT HERE, AND WHY ──────────────────────────────────
##
## The first run after DIFF was written reported `deep_night_zoomout` and
## `deep_night_zoomout.world` as the same picture, and the first fix written was
## an exemption: two views of one moment are not two subjects, so stop comparing
## them. It was a page of good reasoning and it was wrong. The guard was right —
## the harness was stripping the chrome and reading the framebuffer in the same
## breath, so nothing was ever removed and all eleven "the city with the chrome
## taken off" frames still had the entire HUD in them.
##
## Measured after the real fix, on `smoke` and `first_night`: every `.world`
## frame now sits 0.005 to 0.08 from the shot it is a variant of, against a
## threshold of 0.002. The exemption is not needed and would have hidden the
## defect it was written to explain away. If a future frame trips this, that
## frame is worth looking at.


## DOES THIS LAYER PUT ANYTHING ON THE SCREEN — which is not the same question
## as `cl.visible`, and the difference cost this file a round.
##
## [P24]'s meta root is a permanently-visible CanvasLayer holding a stack of
## screens that are each shown and hidden individually. `close_all()` empties the
## stack and leaves the layer itself visible and completely empty, so a guard
## reading `cl.visible` reports a main menu standing over all eleven photographs
## of a tour that had just shut it. That is a FALSE RED, and a false red is how a
## guard gets a threshold moved and stops guarding anything.
##
## A CanvasLayer has no `_draw` of its own; everything it contributes to the
## frame arrives through a visible CanvasItem underneath it. So that is the
## question asked: is there one.
static func draws(cl: CanvasLayer) -> bool:
	if cl == null or not cl.visible:
		return false
	return _has_visible_item(cl)


static func _has_visible_item(n: Node) -> bool:
	for c: Node in n.get_children():
		var ci := c as CanvasItem
		if ci != null:
			if not ci.visible:
				continue
			return true
		# A plain Node in the middle of the tree still passes its children
		# through to the canvas, so the walk cannot stop at the first non-item.
		if _has_visible_item(c):
			return true
	return false


static func _layers(tree: SceneTree) -> Array[CanvasLayer]:
	var out: Array[CanvasLayer] = []
	if tree == null or tree.root == null:
		return out
	_collect(tree.root, out)
	return out


static func _collect(n: Node, out: Array[CanvasLayer]) -> void:
	var cl := n as CanvasLayer
	if cl != null:
		out.append(cl)
	for c: Node in n.get_children():
		_collect(c, out)

class_name LcnLayers
extends RefCounted
## THE UI ALLOCATION TABLE. Canvas layers on the left, hotkeys on the right,
## one file, read and ENFORCED by the boot seam. INTEGRATOR-OWNED.
##
## Why this exists as code and not as a paragraph in a design document: three
## parts each wrote down "my layer is above the HUD" in their own header comment,
## all three were internally consistent, and the result put world-space FROZEN
## badges straight across the clock panel in three of seven screenshots. A
## comment cannot be checked. This table can, and `enforce()` runs on every
## launch, so a part that disagrees is corrected and named in the log instead of
## silently winning.
##
## ── CANVAS LAYERS ────────────────────────────────────────────────────────────
##
##   0   WORLD          [P13] terrain, entities, lights (a plain Node2D canvas)
##                      — and four other parts paint inside it. See the Z LADDER
##                        below: layer 0 is shared, so the ordering there is by
##                        `z_index` and it is allocated here like everything else.
##   60  POST           [P13] grade, bloom, vignette, grain, cold split
##   61  FEEL_SCREEN    [P15] hit flashes, freeze frames, screen impulses
##   62  OVERLAY_WORLD  [P19] readability lenses + world badges  ← WORLD SPACE
##   65  HUD            [P17] clock, vitals, stocks, alerts, selection
##   72  OVERLAY_UI     [P19] the lens legend and key rail       ← SCREEN SPACE
##   74  BUILD_MENU     [P18] palette, recipes, tech, blueprints, laws
##   76  STATS          [P20] production graphs, flow history, the night report
##   78  NARRATIVE      [P22] the dilemma card — it is answered, so it is on top
##   79  TUTORIAL       [P21] the guide strip — chrome, never a modal
##   80  MODAL          [P24] title, pause, settings, saves — it stops the world
##   90  DEBUG          reserved: profiler HUDs, harness annotations
##
## 79 EXISTS BECAUSE TWO PARTS BOTH TOOK 80. The row above used to read
## "reserved: [P21] tutorial gates, [P24] settings, pause", and both parts read
## it and obeyed it: `LcnTutorial` and `LcnMetaRoot` came up on layer 80
## together, and NEITHER had a row in SLOTS — so `enforce()` had nothing to
## correct, `audit()` called both unclaimed, and boot logged them as layers it
## did not know about on every launch. Two CanvasLayers with the same `layer`
## are ordered by the order they reached the viewport's canvas, which here is
## decided by one installing from `PENDING` and the other from a `.tres` the
## Registry scans — a tie-break neither part can see, state, or test. A slot two
## parts share is not an allocation, it is a coincidence that has not bitten yet.
## The tutorial is chrome the player reads WHILE playing; MODAL is the layer that
## stops the world, and it is [P24]'s alone. Verified with `tools/layer_probe.gd`
## against a real display: ten canvas layers, ten rows, no two on one number.
##
## THE RULE, in one sentence: **anything drawn in world coordinates goes UNDER
## the interface, anything drawn in screen coordinates goes OVER the world.**
##
## A lens still beats the post stack, because a diagnostic that gets graded
## along with the night is unreadable at exactly the hour a player needs it. But
## a lens is a thing painted on the ground, and the ground does not get to cover
## the clock. The legend is not a lens: it is chrome, it lives in screen space,
## and it belongs on top with the rest of the chrome.
##
## ── THE Z LADDER INSIDE LAYER 0 ──────────────────────────────────────────────
##
## Five parts draw in world coordinates on the one canvas, and `enforce()` cannot
## help there: `z_index` is a property of a CanvasItem, not of a CanvasLayer, so
## nothing audits it. This is the allocation, read off the running build:
##
##   -100  terrain quad                    [P13] terrain_renderer
##    -40  building shadows                [P13] entity_renderer ShadowPass
##    -20  building glow                   [P13] entity_renderer GlowPass
##    -18  idle life (smoke, birds)        [P15] idle_life
##      0  entities, lights, vfx root      [P13] / [P17]
##      1  belt surfaces                   [D2] item_flow_root Z_BELTS
##      3  items in flight                 [D2] item_flow_root Z_ITEMS
##      4  inserters, splitters, tunnels   [D2] item_flow_root Z_MACHINES
##      5  world juice                     [P15] world_fx
##      6  hover feedback                  [P15] hover_fx
##      8  decay                           [P14] vfx_decay
##     20+ particles, combat, weather      [P14] vfx_*
##
## [D2] asked for the rows at 1/3/4 rather than taking a canvas layer of its own,
## which was the right call: an item on a belt is a thing lying on the ground and
## a canvas layer above the HUD is not where the ground goes. The gap between the
## simulation paint (1–4) and the juice (5) is deliberate — juice reads as
## something happening TO the factory, so it goes over it.
##
## ── HOTKEYS ──────────────────────────────────────────────────────────────────
##
## Three parts independently claimed the number row: [P16] bound 1/2/3 to sim
## speed through the InputMap, [P19] claims any bare number the InputMap has not
## taken, and [P18]'s quickbar takes 1..0 unconditionally from `_input`, which
## runs before `_unhandled_input`. The quickbar starts empty, so the collision
## only appears after the player's FIRST building — which is why nobody caught
## it. `LcnInputRouter` (game/play/) settles it by taking the reserved keys
## before any panel sees them:
##
##   SPACE  pause                 router → camera
##   1 2 3  sim speed             router → camera        RESERVED
##   4 5 6  lenses 4, 5, 6        router → overlay root  RESERVED
##   F1..F6 lenses 1..6           [P16] InputMap + [P19]
##   7 8 9 0  quickbar slots      [P18]  (0 also resets zoom when unpinned)
##   B      build palette         [P18]
##   I      recipes and items     [P18]
##   T      research              [P18]
##   N      blueprint library     [P18]
##   L      the Book of Laws      [P18]
##   G / P  statistics screens    [P20]
##   Esc    close the top panel   [P18], then cancel     [P16]
##   Q E    cycle the ghost       play shell
##   R      rotate the ghost      [P16] action → play shell
##   X      demolish under cursor play shell
##   H      centre on the hearth  [P16]
##   W A S D / arrows  pan        [P16]
##   + -    zoom                  [P16]
##
## Nothing here is a suggestion: `tests/boot/run_reachability.tscn` presses every
## one of these against the real scene tree and fails if a screen does not open.

# --- canvas layers -----------------------------------------------------------

const WORLD: int = 0
const POST: int = 60
const FEEL_SCREEN: int = 61
const OVERLAY_WORLD: int = 62
const HUD: int = 65
const OVERLAY_UI: int = 72
const BUILD_MENU: int = 74
const STATS: int = 76
const NARRATIVE: int = 78
const TUTORIAL: int = 79
const MODAL: int = 80
const DEBUG: int = 90

## Where boot looks for a subsystem that has not landed yet. A part is reachable
## the moment it puts a Node class at this path; until then boot says out loud,
## on every launch, that it is not.
const PENDING: Array[Dictionary] = [
	{"key": &"stats", "owner": "P20 stats", "hotkey": "G",
		"script": "res://game/ui/stats/stats_root.gd", "layer": STATS,
		"why": "production graphs, flow history and the night report"},
	# [P21] HAS LANDED — this row is what installs it, so it stays. Only the
	# hotkey text was wrong: it advertised "F1 help", and F1 is [P19]'s
	# readability lens, which `tests/boot/run_reachability.tscn` asserts. The
	# guide took no key at all; it is mouse-only on real Buttons, like [P22]'s
	# card. A row in this table that names a key another part owns is exactly
	# the disagreement this file exists to prevent, even when it is only text.
	{"key": &"tutorial", "owner": "P21 tutorial", "hotkey": "no key — mouse only",
		"script": "res://game/ui/tutorial/tutorial_root.gd", "layer": TUTORIAL,
		"why": "the first twenty minutes"},
]

## key → the layer it must sit on, and the node names that identify it.
## Matched by NAME, never by class: game/core/ must not depend on a part being
## present, and every part below sets its node name in `_ready`.
const SLOTS: Array[Dictionary] = [
	{"key": &"post", "layer": POST, "owner": "P13 render",
		"names": ["Post", "PostProcess", "LcnPostProcess"]},
	{"key": &"feel_screen", "layer": FEEL_SCREEN, "owner": "P15 feel",
		"names": ["FeelScreen", "LcnScreenFx"]},
	{"key": &"overlay_world", "layer": OVERLAY_WORLD, "owner": "P19 overlays",
		"names": ["OverlayWorld"]},
	{"key": &"hud", "layer": HUD, "owner": "P17 hud",
		"names": ["LcnHud", "Hud"]},
	{"key": &"overlay_ui", "layer": OVERLAY_UI, "owner": "P19 overlays",
		"names": ["OverlayUi"]},
	{"key": &"build_menu", "layer": BUILD_MENU, "owner": "P18 build menu",
		"names": ["LcnBuildMenu", "BuildMenu"]},
	{"key": &"stats", "layer": STATS, "owner": "P20 stats",
		"names": ["LcnStatsRoot", "StatsRoot", "LcnStats"]},
	{"key": &"narrative", "layer": NARRATIVE, "owner": "P22 narrative",
		"names": ["LcnNarrativeCard", "NarrativeCard"]},
	{"key": &"tutorial", "layer": TUTORIAL, "owner": "P21 tutorial",
		"names": ["LcnTutorial", "LcnTutorialRoot"]},
	{"key": &"meta", "layer": MODAL, "owner": "P24 meta",
		"names": ["LcnMetaRoot", "MetaRoot"]},
]

# --- hotkeys -----------------------------------------------------------------

## Keys the router takes before any panel can. Everything else falls through.
const RESERVED_TIME: Array[int] = [KEY_1, KEY_2, KEY_3]
const RESERVED_LENS: Array[int] = [KEY_4, KEY_5, KEY_6]

## Sim speed each of 1/2/3 selects. Matches [P16]'s SPEED_STEPS.
const SPEED_STEPS: Array[float] = [1.0, 2.0, 3.0]


## True for a key `LcnInputRouter` dispatches itself. A part must never bind one
## of these in its own `_input`, whatever the InputMap happens to say at the
## moment it asks.
##
## Asking the InputMap is not a substitute for asking this. [P19] decided which
## bare numbers it could take by probing `InputMap`, which is only populated when
## [P16]'s camera installs the action map — and with a display attached the
## self-installing parts come up BEFORE boot builds the camera. So [P19] probed
## an empty map, concluded 1/2/3 were free, bound them as lens keys and consumed
## them with `set_input_as_handled()`. Sim speed was dead on 2 and 3 for every
## player, and green in the one headless order where [P19] happened to install
## last. A reservation that depends on who booted first is not a reservation.
static func key_is_reserved(code: int) -> bool:
	return RESERVED_TIME.has(code) or RESERVED_LENS.has(code)

## The screens a human must be able to open, and the key that opens each.
## The reachability suite iterates this literally.
const SCREENS: Array[Dictionary] = [
	{"id": &"palette", "key": KEY_B, "label": "build palette"},
	{"id": &"recipes", "key": KEY_I, "label": "recipe & item browser"},
	{"id": &"tech", "key": KEY_T, "label": "research tree"},
	{"id": &"blueprints", "key": KEY_N, "label": "blueprint library"},
	{"id": &"laws", "key": KEY_L, "label": "the Book of Laws"},
]

## Screens that live outside [P18]'s panel set. Same contract: a key, a thing
## that reports whether it is open, and a suite that presses the key.
const EXTRA_SCREENS: Array[Dictionary] = [
	{"key": KEY_G, "group": &"lcn_stats", "flag": &"is_open",
		"label": "production graphs & the night report", "owner": "P20"},
]

# --- test/tooling escape hatch ----------------------------------------------

## Set true BEFORE the boot scene enters the tree to install the whole view even
## without a display server. The reachability suite needs a real scene tree with
## real panels in it, and `tools/check.sh` can only run a suite headless. Every
## install seam consults this, so there is exactly one switch.
static var force_install: bool = false


## True when the view must be built: a display exists, or someone asked for it.
static func view_wanted() -> bool:
	if force_install:
		return true
	if OS.get_cmdline_user_args().has("--force-ui"):
		force_install = true
		return true
	if OS.get_cmdline_user_args().has("--no-view"):
		return false
	return DisplayServer.get_name() != "headless"


# --- enforcement -------------------------------------------------------------

## Every CanvasLayer in the tree, matched against the table.
## Rows: {key, owner, node, path, expected, actual, ok, known}
static func audit(tree: SceneTree) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if tree == null or tree.root == null:
		return out
	var found: Array[CanvasLayer] = []
	_collect(tree.root, found)
	for cl: CanvasLayer in found:
		var slot: Dictionary = _slot_for(cl.name)
		var known: bool = not slot.is_empty()
		var expected: int = int(slot.get("layer", cl.layer))
		out.append({
			"key": slot.get("key", StringName(cl.name)),
			"owner": String(slot.get("owner", "unclaimed")),
			"node": cl,
			"path": String(cl.get_path()),
			"expected": expected,
			"actual": cl.layer,
			"ok": (not known) or cl.layer == expected,
			"known": known,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["expected"]) != int(b["expected"]):
			return int(a["expected"]) < int(b["expected"])
		return String(a["path"]) < String(b["path"]))
	return out


## Corrects every layer that disagrees with the table. Returns one line per
## correction, so the caller can put the part's name in the log rather than
## fixing it in silence — a silent correction is how the disagreement survives.
static func enforce(tree: SceneTree) -> PackedStringArray:
	var notes := PackedStringArray()
	for row: Dictionary in audit(tree):
		if bool(row["ok"]) or not bool(row["known"]):
			continue
		var node: CanvasLayer = row["node"]
		notes.append("%s put %s on layer %d; the table says %d — corrected" % [
			String(row["owner"]), String(row["key"]), int(row["actual"]),
			int(row["expected"])])
		node.layer = int(row["expected"])
	return notes


## The one invariant a screenshot can betray: nothing drawn in world space may
## sit above the HUD. Returns the offending rows, empty when the stack is sane.
static func violations(tree: SceneTree) -> Array[Dictionary]:
	var bad: Array[Dictionary] = []
	for row: Dictionary in audit(tree):
		var node: CanvasLayer = row["node"]
		if node.follow_viewport_enabled and node.layer >= HUD:
			bad.append(row)
		elif bool(row["known"]) and not bool(row["ok"]):
			bad.append(row)
	return bad


static func _collect(node: Node, out: Array[CanvasLayer]) -> void:
	var cl := node as CanvasLayer
	if cl != null:
		out.append(cl)
	for child: Node in node.get_children():
		_collect(child, out)


static func _slot_for(node_name: StringName) -> Dictionary:
	var n: String = String(node_name)
	for slot: Dictionary in SLOTS:
		for candidate: String in (slot["names"] as Array):
			if candidate == n:
				return slot
	return {}

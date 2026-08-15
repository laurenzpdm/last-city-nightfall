extends Node
## Entry point. Assembles a playable session, or yields to the harness.
##
## This is the ONE place where the simulation, the renderer, the camera and the
## player's hands are wired together, and — since the phase where a whole build
## menu spent an entire day as an orphan — the one place that is allowed to say
## whether any of it worked.
##
##   Sim.create_world()  the simulation, seeded
##   WorldRenderer       [P13] terrain, entities, lights, post          layer 60
##   GameCamera          [P16] pan, zoom, drag, selection, the action map
##   LcnHud              [P17] clock, grid, vitals, stocks, alerts      layer 65
##   LcnOverlayRoot      [P19] readability lenses      world 62 / legend 72
##   LcnBuildMenu        [P18] palette, recipes, tech, blueprints, laws layer 74
##   PlayController      build mode, ghost, placement — the integrator's shell
##   LcnInputRouter      the arbiter for keys three parts claimed at once
##
## THE INSTALL CONTRACT. Every subsystem is created here, added to a parent that
## is ALREADY IN THE TREE, and then checked with `is_inside_tree()` before it is
## allowed to count. A subsystem that is not in the tree is reported as an ERROR
## naming it, and the ready line lists only what was actually verified.
##
## That paragraph is not decoration. The previous version installed the build
## menu with `tree.root.add_child()` from inside `_ready`, where Godot refuses
## the call because the root is still setting up its children; it printed one
## engine error into a log nobody parsed and then announced "view installed:
## renderer + camera + HUD + build menu + play shell" while the build menu was
## an orphan holding the palette, the tech tree, the recipe browser, the
## blueprint library and the Book of Laws. Every one of those was unreachable
## for a whole phase and 768 tests, a determinism replay and a perf gate all
## stayed green, because none of them ever asked whether a human could open a
## menu. `tests/boot/run_reachability.tscn` now asks, on every run.
##
## Headless runs (tools/check.sh, the deterministic harness) get the simulation
## and nothing else: no window, no art bake, no rendering cost, and no way for
## the view to perturb a replay.
##
##   --no-view    force the simulation-only path even with a display attached
##   --force-ui   build the whole view even without one (the reachability suite)
##   --seed=N     override the world seed
##   --ui-tour    open every screen in turn and photograph it, then quit

const OPENING_SEED: int = 7

## path → what boot calls it. Loaded by PATH, not by class name, so a part that
## is deleted mid-phase costs one logged line instead of a build that will not
## compile.
const RENDERER_SCENE: String = "res://game/view/render/world_renderer.tscn"
const HUD_SCRIPT: String = "res://game/ui/hud/hud_root.gd"
const OVERLAY_SCRIPT: String = "res://game/ui/overlays/overlay_root.gd"
const BUILD_MENU_SCRIPT: String = "res://game/ui/build_menu/build_menu_root.gd"

var renderer: Node = null
var camera: Node = null
var play: PlayController = null
var hud: Node = null
var build_menu: Node = null
var overlays: Node = null
var router: LcnInputRouter = null

## subsystem → {ok: bool, path: String, why: String}. The reachability suite and
## the harness both read this instead of trusting a log line.
var install_report: Dictionary[StringName, Dictionary] = {}


func _ready() -> void:
	Log.info("boot", "Last City: Nightfall — Godot %s" % Engine.get_version_info().string)
	if Harness.active:
		# The harness owns world creation and the tick loop. It still wants the
		# view in --visual mode, so install it and let Harness drive.
		if Harness.visual:
			_install_view()
		Log.info("boot", "harness mode; boot yields control to Harness")
		return

	# View FIRST, world second: the play shell and the camera bind to the world on
	# Bus.world_ready, and a world created before they exist fires it into an
	# empty room — which is how the camera ended up parked at (0, 0) looking at
	# empty snow while the city stood a hundred tiles away.
	_install_view()
	Sim.create_world(_seed_from_cli())
	_seed_opening_settlement()
	SimClock.start()
	if OS.get_cmdline_user_args().has("--ui-tour"):
		_start_ui_tour()


func _seed_from_cli() -> int:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			return int(a.substr(7))
	return OPENING_SEED


func headless() -> bool:
	return not LcnLayers.view_wanted()


# ============================================================== installation ==

## Idempotent. Safe to call twice; safe to call when a part already installed
## itself; a no-op with no display server and no --force-ui.
func _install_view() -> void:
	install_report.clear()
	if headless():
		Log.info("boot", "no display server (or --no-view): simulation only")
		return

	renderer = _install_renderer()
	camera = _install_camera()
	hud = _install_scripted(&"hud", HUD_SCRIPT, "P17")
	# Order matters twice over. Children are added front-to-back for DRAWING,
	# and `_input` is delivered in REVERSE tree order, so the last child added
	# is the first to see a key. The router goes last on purpose: it is the only
	# thing allowed to settle a key two parts both claimed.
	overlays = _install_scripted(&"overlays", OVERLAY_SCRIPT, "P19")
	build_menu = _install_scripted(&"build_menu", BUILD_MENU_SCRIPT, "P18")
	_install_play()
	_install_pending()
	# LAST, so that in reverse tree order it is FIRST to see a key.
	_install_router()

	_apply_layer_table()
	_report_install()


## Parts that have a slot in LcnLayers but have not landed a root yet. Installed
## the moment the script appears; named out loud on every launch until then, so
## "the stats screens exist but nothing opens them" is a line in the log rather
## than a discovery a critic makes three phases later.
func _install_pending() -> void:
	for entry: Dictionary in LcnLayers.PENDING:
		var key: StringName = entry["key"]
		var path: String = String(entry["script"])
		if not ResourceLoader.exists(path):
			Log.info("boot", "NOT REACHABLE YET: %s [%s] — %s. Land %s and boot installs it on %s." % [
				String(key), String(entry["owner"]), String(entry["why"]), path,
				String(entry["hotkey"])])
			continue
		var node: Node = _install_scripted(key, path, String(entry["owner"]))
		if node != null and node is CanvasLayer:
			(node as CanvasLayer).layer = int(entry["layer"])


## [P13]'s renderer, from its scene. Everything else in the view hangs off it
## or draws over it, so a failure here is fatal to the session and says so.
func _install_renderer() -> Node:
	var existing: Node = get_tree().get_first_node_in_group(&"lcn_world_renderer")
	if existing != null:
		return _verify(&"renderer", existing, "P13")
	if not ResourceLoader.exists(RENDERER_SCENE):
		return _failed(&"renderer", "P13", "no scene at %s" % RENDERER_SCENE)
	var packed: PackedScene = load(RENDERER_SCENE) as PackedScene
	if packed == null:
		return _failed(&"renderer", "P13", "%s did not load as a PackedScene" % RENDERER_SCENE)
	var node: Node = packed.instantiate()
	# Parented to Boot, which is ALREADY in the tree. `tree.root.add_child()`
	# from inside `_ready` is refused by Godot with "parent node is busy setting
	# up children" and returns an orphan.
	add_child(node)
	return _verify(&"renderer", node, "P13")


func _install_camera() -> Node:
	var existing: Node = GameCamera.current()
	if existing != null and existing.is_inside_tree():
		return _verify(&"camera", existing, "P16")
	var cam := GameCamera.new()
	cam.name = "GameCamera"
	# The camera must land on the Camera2D BEFORE the renderer reads the canvas
	# transform, or every frame culls and streams for where the camera was last
	# frame. On the first frame of a screenshot run that means an empty screen.
	cam.process_priority = -50
	add_child(cam)
	return _verify(&"camera", cam, "P16")


## A UI part, from its script path. Stands down when the part already put one in
## the tree; reports a missing part as a failure rather than a missing line.
func _install_scripted(key: StringName, path: String, owner: String) -> Node:
	var existing: Node = _find_installed(key)
	if existing != null:
		return _verify(key, existing, owner)
	if not ResourceLoader.exists(path):
		return _failed(key, owner, "no script at %s" % path)
	var script: Script = load(path) as Script
	if script == null:
		return _failed(key, owner, "%s did not compile" % path)
	var node: Node = script.new() as Node
	if node == null:
		return _failed(key, owner, "%s is not a Node" % path)
	add_child(node)
	return _verify(key, node, owner)


## Was this subsystem already put in the tree by its own bootstrap .tres?
func _find_installed(key: StringName) -> Node:
	var groups: Dictionary[StringName, StringName] = {
		&"hud": &"lcn_hud",
		&"overlays": &"lcn_overlay_root",
		&"build_menu": &"lcn_build_menu",
	}
	var g: StringName = groups.get(key, &"")
	if g != &"":
		var by_group: Node = get_tree().get_first_node_in_group(g)
		if by_group != null:
			return by_group
	# [P17] does not join a group; it names itself. Both conventions are checked,
	# under Boot and under the root, so neither can produce a second copy.
	var names: Dictionary[StringName, String] = {
		&"hud": "LcnHud",
		&"overlays": "OverlayRoot",
		&"build_menu": "LcnBuildMenu",
	}
	var node_name: String = String(names.get(key, ""))
	if node_name == "":
		return null
	var mine: Node = get_node_or_null(NodePath(node_name))
	if mine != null:
		return mine
	return get_tree().root.get_node_or_null(NodePath(node_name))


func _install_play() -> void:
	play = PlayController.new()
	var parent: Node = renderer if renderer != null else self
	parent.add_child(play)
	if _verify(&"play", play, "integrator") == null:
		play = null
		return
	play.attach(camera, hud)


func _install_router() -> void:
	router = LcnInputRouter.new()
	add_child(router)
	if _verify(&"input_router", router, "integrator") == null:
		router = null
		return
	router.bind(camera, overlays)


## The single question every install has to answer. A node that is not in the
## tree is not installed, whatever the constructor returned.
func _verify(key: StringName, node: Node, owner: String) -> Node:
	if node == null:
		return _failed(key, owner, "nothing was created")
	if not node.is_inside_tree():
		# Never "probably fine, it will arrive": an orphan that MIGHT land later
		# is exactly the state that produced a ready line naming a menu nobody
		# could open. Boot owns the parents it adds to and every one of them is
		# already in the tree, so there is no legitimate way to be here.
		node.queue_free()
		return _failed(key, owner, "created but not in the scene tree")
	install_report[key] = {"ok": true, "path": String(node.get_path()), "why": "", "owner": owner}
	return node


func _failed(key: StringName, owner: String, why: String) -> Node:
	install_report[key] = {"ok": false, "path": "", "why": why, "owner": owner}
	return null


## Enforces docs/ARCHITECTURE.md §3 / LcnLayers, rather than trusting five
## header comments that each said "above the HUD".
func _apply_layer_table() -> void:
	for note: String in LcnLayers.enforce(get_tree()):
		Log.warn("boot", "layer table: %s" % note)
	var bad: Array[Dictionary] = LcnLayers.violations(get_tree())
	for row: Dictionary in bad:
		Log.error("boot", "canvas layer %s (%s) still violates the table at %d" % [
			String(row["key"]), String(row["owner"]), int(row["actual"])])
	# A table that quietly falls behind the build is the same disease one step
	# later, so every canvas layer nobody has claimed gets named on every launch.
	var unclaimed: PackedStringArray = PackedStringArray()
	for row2: Dictionary in LcnLayers.audit(get_tree()):
		if not bool(row2["known"]):
			unclaimed.append("%s@%d" % [String(row2["key"]), int(row2["actual"])])
	if not unclaimed.is_empty():
		Log.info("boot", "canvas layers not in LcnLayers.SLOTS yet: %s" % " ".join(unclaimed))


## One line per subsystem, and a ready line that can only name things that are
## genuinely in the tree.
func _report_install() -> void:
	var ok: PackedStringArray = PackedStringArray()
	var broken: int = 0
	var keys: Array = install_report.keys()
	keys.sort()
	for k: StringName in keys:
		var row: Dictionary = install_report[k]
		if bool(row["ok"]):
			ok.append(String(k))
		else:
			broken += 1
			Log.error("boot", "%s [%s] did NOT install: %s — it is unreachable to the player" % [
				String(k), String(row["owner"]), String(row["why"])])
	if broken > 0:
		Log.error("boot", "%d of %d subsystems are missing from the scene tree" % [
			broken, install_report.size()])
	Log.info("boot", "view installed and verified in-tree: %s" % ", ".join(ok))


## True only when every subsystem boot tried to install is in the tree.
func view_ok() -> bool:
	if install_report.is_empty():
		return false
	for k: StringName in install_report:
		if not bool((install_report[k] as Dictionary)["ok"]):
			return false
	return true


# ================================================================== opening ==

## A city already stands when the player arrives — a hearth, the pipes that carry
## it and the first ring of housing. Placed FREE and INSTANT through the same
## command path a scenario uses, so nothing here is a special case the rest of
## the build does not see.
func _seed_opening_settlement() -> void:
	var build: SimSystem = Sim.get_system(&"build")
	var grid: SimSystem = Sim.get_system(&"grid")
	if build == null or grid == null:
		return
	var c: Vector2i = grid.call("core_cell")
	for cmd: Dictionary in opening_commands(c):
		Sim.submit_command(cmd)
	# Commands are applied at the start of the next tick; run it now so the
	# renderer's first frame already shows the settlement.
	SimClock.advance(1)
	Log.info("boot", "opening settlement seeded around %s" % str(c))

	# THE GATE. A settlement is not seeded until it is whole — see
	# opening_defects(). This is the last moment anyone can notice, and a
	# Log.error here fails the harness run rather than shipping a save that
	# freezes itself.
	for defect: String in opening_defects():
		Log.error("boot", "opening settlement is broken on arrival: %s" % defect)


## The opening layout, as commands. Shared with tests so the scene a player sees
## on launch is the scene a test can assert against.
##
## HOW A CONSUMER GETS PLACED HERE. Anything that draws heat goes down through
## `fed`, which lays the pipe run AND derives the building's origin from the last
## tile of that run. A consumer's coordinate is therefore not something anyone
## types; it is what the pipe decides.
##
## That rule exists because the old version of this function was fifteen typed
## coordinates with no relationship between them. Thirteen happened to land on
## the trunk. Two did not: a watchtower nine tiles north of the nearest pipe and
## a turret mount nine tiles south of it, each alone on its own heat network with
## supply 0.0, permanently `unreachable`, both `frozen: true` by t=600 of every
## single run. That is where the opening HUD's "3 grids", "Turret Mount run is
## 7.4 heat short" and "2 frozen" came from — a settlement that failed on its own
## before the player touched it.
##
## `warmth_radiator` was saved from the same fate only by its `must_connect` tag.
## The defensive buildings consume heat and declare no such tag, so nothing in
## placement, in the layout or in a test related them to a pipe. `fed` relates
## them structurally; `opening_defects()` checks the result on every launch.
static func opening_commands(c: Vector2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var place := func(kind: String, cell: Vector2i, rot: int) -> void:
		out.append({"system": &"build", "op": "place", "kind": kind,
			"cell": [cell.x, cell.y], "rot": rot, "free": true, "instant": true})
	var line := func(kind: String, a: Vector2i, b: Vector2i) -> void:
		out.append({"system": &"build", "op": "place_line", "kind": kind,
			"from": [a.x, a.y], "to": [b.x, b.y], "free": true, "instant": true})

	## A heat consumer and the pipe that reaches it, as one indivisible act.
	## `from` is the first spur tile (orthogonally touching the trunk), `dir` the
	## direction it runs, `length` how many tiles of pipe it lays. The building's
	## origin is derived from the last pipe tile and its own footprint, so the two
	## cannot drift apart no matter who edits this next.
	var fed := func(kind: String, size: Vector2i, from: Vector2i, dir: Vector2i, length: int) -> void:
		var last: Vector2i = from + dir * maxi(0, length - 1)
		line.call("heat_pipe", from, last)
		var origin: Vector2i = last + dir
		# Footprints grow +x/+y from their origin, so a spur running north or west
		# has to step back by the building's own size or it lands ON its own pipe.
		if dir.x < 0:
			origin.x -= size.x - 1
		if dir.y < 0:
			origin.y -= size.y - 1
		place.call(kind, origin, 0)

	place.call("the_hearth", c + Vector2i(-2, -2), 0)
	line.call("heat_pipe", c + Vector2i(3, 0), c + Vector2i(12, 0))
	line.call("heat_pipe", c + Vector2i(-3, 0), c + Vector2i(-12, 0))
	line.call("heat_pipe", c + Vector2i(0, 3), c + Vector2i(0, 12))
	line.call("heat_pipe", c + Vector2i(3, 2), c + Vector2i(12, 2))
	line.call("heat_pipe", c + Vector2i(-3, 2), c + Vector2i(-12, 2))
	place.call("warmth_radiator", c + Vector2i(13, -1), 0)
	place.call("warmth_radiator", c + Vector2i(-14, -1), 0)
	place.call("housing_block", c + Vector2i(5, 3), 0)
	place.call("housing_block", c + Vector2i(-9, 3), 0)
	place.call("coal_generator", c + Vector2i(-3, 11), 0)
	place.call("workshop", c + Vector2i(1, 11), 0)
	place.call("storage_yard", c + Vector2i(10, 4), 0)
	# The watch on the northern approach, on a spur off the east trunk's last
	# tile. The lower trunk feeds the turret the same way to the south, one column
	# further out so the spur clears the storage yard.
	fed.call("watchtower", Vector2i(2, 2), c + Vector2i(12, -1), Vector2i(0, -1), 8)
	fed.call("turret_mount", Vector2i(2, 2), c + Vector2i(13, 2), Vector2i(0, 1), 8)
	return out


## Every heat consumer the opening settlement placed that the grid does not
## reach, as a line naming the building, its cell and why. Empty means whole.
##
## Read straight off the built world, not off the command list, so it is the
## SETTLEMENT that is graded and not the author's intent: a placement the build
## system refused, a spur that landed one tile short, a consumer stranded on its
## own island — all three come out here as the same kind of sentence.
##
## Called by boot on every launch (a Log.error fails the harness run) and by
## tests/f3/test_opening_settlement.gd against the same layout a player gets.
## The criterion is "is there a source of heat on this building's network",
## not "is heat flowing", because at the tick the settlement is seeded the
## hearth has not burned anything yet and every honest network reads supply 0.0.
static func opening_defects() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var build: SimSystem = Sim.get_system(&"build")
	var heat: SimSystem = Sim.get_system(&"heat")
	if build == null or heat == null:
		return out

	var buildings: Array = build.call("all_buildings")
	# Which networks have something that makes heat on them.
	var producers: Dictionary[int, bool] = {}
	for b: BuildingInstance in buildings:
		if b.def == null or b.def.heat_produced <= 0.0:
			continue
		var pn: int = int(heat.call("network_of", b.id))
		if pn >= 0:
			producers[pn] = true

	var consumers: int = 0
	for b2: BuildingInstance in buildings:
		if b2.def == null or b2.def.heat_consumed <= 0.0:
			continue
		consumers += 1
		var nid: int = int(heat.call("network_of", b2.id))
		if nid < 0:
			out.append("%s at %d,%d draws %.1f heat and is on no network at all — nothing was laid next to it" % [
				b2.def.display_name, b2.cell.x, b2.cell.y, b2.def.heat_consumed])
		elif not producers.has(nid):
			out.append("%s at %d,%d draws %.1f heat on network %d, which has no source of heat on it — the spur that should feed it does not reach the trunk" % [
				b2.def.display_name, b2.cell.x, b2.cell.y, b2.def.heat_consumed, nid])
	if consumers == 0:
		out.append("the opening settlement placed no heat consumers at all — the layout did not land")
	return out


# ================================================================= ui tour ==

## `--ui-tour` presses every screen's hotkey against the real window and saves a
## PNG of each, so "a human can open it" is answered by a photograph instead of
## by a comment. Quits when the last shot is written.
func _start_ui_tour() -> void:
	var tour := LcnUiTour.new()
	tour.build_menu = build_menu
	tour.overlays = overlays
	tour.router = router
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			tour.out_dir = a.substr(6)
	add_child(tour)

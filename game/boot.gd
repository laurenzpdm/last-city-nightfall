extends Node
## Entry point. Assembles a playable session, or yields to the harness.
##
## This is the ONE place where the simulation, the renderer, the camera and the
## player's hands are wired together. Every part is written to install itself
## defensively and stand down if someone else got there first, so the wiring here
## is deliberate and explicit rather than a race of self-installers:
##
##   Sim.create_world()  the simulation, seeded
##   WorldRenderer       [P13] terrain, entities, lights, post
##   GameCamera          [P16] pan, zoom, drag, selection, the whole action map
##   PlayController      build mode, ghost, placement — the integrator's shell
##   PlayHud             the clock, the grid and the controls
##
## Headless runs (tools/check.sh, the deterministic harness) get the simulation
## and nothing else: no window, no art bake, no rendering cost, and no way for
## the view to perturb a replay.
##
##   --no-view   force the simulation-only path even with a display attached
##   --seed=N    override the world seed

const OPENING_SEED: int = 7

var renderer: WorldRenderer = null
var camera: GameCamera = null
var play: PlayController = null
var hud: PlayHud = null


func _ready() -> void:
	Log.info("boot", "Last City: Nightfall — Godot %s" % Engine.get_version_info().string)
	if Harness.active:
		# The harness owns world creation and the tick loop. It still wants the
		# view in --visual mode, so install it and let Harness drive.
		if Harness.visual:
			_install_view()
		Log.info("boot", "harness mode; boot yields control to Harness")
		return

	Sim.create_world(_seed_from_cli())
	_install_view()
	_seed_opening_settlement()
	SimClock.start()


func _seed_from_cli() -> int:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			return int(a.substr(7))
	return OPENING_SEED


func headless() -> bool:
	return DisplayServer.get_name() == "headless" \
		or OS.get_cmdline_user_args().has("--no-view")


## Idempotent. Safe to call twice; safe to call when a part already installed
## itself; a no-op with no display server.
func _install_view() -> void:
	if headless():
		Log.info("boot", "no display server (or --no-view): simulation only")
		return
	renderer = LcnViewBootstrap.install()
	if renderer == null:
		renderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	if renderer == null:
		Log.error("boot", "the world renderer failed to install — nothing will be visible")
		return

	if GameCamera.current() == null:
		camera = GameCamera.new()
		camera.name = "GameCamera"
		add_child(camera)
	else:
		camera = GameCamera.current()

	hud = PlayHud.new()
	add_child(hud)

	play = PlayController.new()
	renderer.add_child(play)
	play.attach(camera, hud)

	Log.info("boot", "view installed: renderer + camera + play controller")


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


## The opening layout, as commands. Shared with tests so the scene a player sees
## on launch is the scene a test can assert against.
static func opening_commands(c: Vector2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var place := func(kind: String, cell: Vector2i, rot: int) -> void:
		out.append({"system": &"build", "op": "place", "kind": kind,
			"cell": [cell.x, cell.y], "rot": rot, "free": true, "instant": true})
	var line := func(kind: String, a: Vector2i, b: Vector2i) -> void:
		out.append({"system": &"build", "op": "place_line", "kind": kind,
			"from": [a.x, a.y], "to": [b.x, b.y], "free": true, "instant": true})

	place.call("the_hearth", c + Vector2i(-2, -2), 0)
	line.call("heat_pipe", c + Vector2i(3, 0), c + Vector2i(11, 0))
	line.call("heat_pipe", c + Vector2i(-3, 0), c + Vector2i(-11, 0))
	line.call("heat_pipe", c + Vector2i(0, 3), c + Vector2i(0, 9))
	place.call("warmth_radiator", c + Vector2i(12, -1), 0)
	place.call("warmth_radiator", c + Vector2i(-13, -1), 0)
	place.call("housing_block", c + Vector2i(6, 2), 0)
	place.call("housing_block", c + Vector2i(-10, 2), 0)
	place.call("housing_block", c + Vector2i(-2, 4), 0)
	place.call("coal_generator", c + Vector2i(-3, 10), 0)
	place.call("workshop", c + Vector2i(2, 10), 0)
	place.call("storage_yard", c + Vector2i(8, 4), 0)
	place.call("watchtower", c + Vector2i(14, -8), 0)
	place.call("watchtower", c + Vector2i(-15, -8), 0)
	place.call("turret_mount", c + Vector2i(14, 10), 0)
	return out

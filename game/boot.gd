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

	# View FIRST, world second: the play shell and the camera bind to the world on
	# Bus.world_ready, and a world created before they exist fires it into an
	# empty room — which is how the camera ended up parked at (0, 0) looking at
	# empty snow while the city stood a hundred tiles away.
	_install_view()
	Sim.create_world(_seed_from_cli())
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
	renderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	if renderer == null:
		# Instantiated HERE and parented to Boot, not to the scene root:
		# tree.root is still "busy setting up children" while the main scene's
		# _ready runs, and add_child() on it silently fails. [P13]'s self-installer
		# stands down once the node is in its group, so this is idempotent.
		if not ResourceLoader.exists(LcnViewBootstrap.SCENE):
			Log.error("boot", "world_renderer.tscn missing at %s" % LcnViewBootstrap.SCENE)
			return
		renderer = (load(LcnViewBootstrap.SCENE) as PackedScene).instantiate() as WorldRenderer
		add_child(renderer)
	if renderer == null or not renderer.is_inside_tree():
		Log.error("boot", "the world renderer failed to install — nothing will be visible")
		return

	if GameCamera.current() == null:
		camera = GameCamera.new()
		camera.name = "GameCamera"
		# The camera must land on the Camera2D BEFORE the renderer reads the canvas
		# transform, or every frame culls and streams for where the camera was last
		# frame. On the first frame of a screenshot run that means an empty screen.
		camera.process_priority = -50
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
	place.call("watchtower", c + Vector2i(14, -9), 0)
	place.call("turret_mount", c + Vector2i(14, 9), 0)
	return out

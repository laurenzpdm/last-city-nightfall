extends Node
## Entry point. Decides between harness mode and a normal player session.
## Kept deliberately thin — [P24] meta owns the real main-menu flow.

func _ready() -> void:
	Log.info("boot", "Last City: Nightfall — Godot %s" % Engine.get_version_info().string)
	if Harness.active:
		Log.info("boot", "harness mode; boot yields control to Harness")
		return
	# Normal session. Until the main menu exists, drop straight into a world.
	Sim.create_world(int(Time.get_unix_time_from_system()) & 0x7FFFFFFF)
	SimClock.start()

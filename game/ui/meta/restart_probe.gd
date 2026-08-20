extends Node
## [P24] A second process, started cold, that prints what the settings file says.
##
## This is how "a rebinding survives a restart" is PROVEN rather than asserted.
## The obvious test — write a setting, read it back in the same process — proves
## a dictionary can hold a value and nothing else. The only honest version boots
## the engine again, lets `Settings._ready()` load `user://settings.cfg` the way
## a player's launch does, asks [Keybinds] what it thinks, and prints it.
##
##   godot --headless --path . res://game/ui/meta/restart_probe.tscn -- --probe=rotate
##
## It lives in game/ui/meta/ and not in tests/ ON PURPOSE: every `.tscn` under
## tests/ is discovered by the gate as a suite that must print a verdict, and
## this is not a suite. It is an instrument that another suite reads.

func _ready() -> void:
	var actions: PackedStringArray = PackedStringArray(["rotate"])
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--probe="):
			actions = a.substr(8).split(",")
	Keybinds.install()
	Keybinds.restore(Settings)
	for action: String in actions:
		print("PROBE %s=%s" % [action, Keybinds.binding_label(StringName(action))])
	print("PROBE font_scale=%s" % str(Settings.get_value("accessibility", "font_scale", 1.0)))
	print("PROBE window_mode=%s" % str(Settings.get_value("graphics", "window_mode", "windowed")))
	print("PROBE saves=%d" % LcnSaveManager.slots().size())
	get_tree().quit(0)

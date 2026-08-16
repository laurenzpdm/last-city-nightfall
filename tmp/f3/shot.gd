extends Node
## Photograph the first screen a player actually sees: game/boot.tscn's own
## opening settlement, not the harness scenario.
var _frames: int = 0
var _boot: Node = null

func _ready() -> void:
	_boot = load("res://game/boot.tscn").instantiate()
	add_child(_boot)

func _process(_d: float) -> void:
	_frames += 1
	if _frames == 90:
		var img: Image = get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("res://artifacts/f3_boot_shot")
		img.save_png("res://artifacts/f3_boot_shot/new_game.png")
		print("SHOT saved, sim tick ", SimClock.tick)
		get_tree().quit()
	elif _frames > 400:
		print("SHOT gave up at frame ", _frames)
		get_tree().quit()

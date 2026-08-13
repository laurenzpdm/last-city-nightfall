extends SceneTree
## [P23] Offline baker. Renders the whole synthesised catalogue to real .wav
## files so a human can listen to the palette without launching the game.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script game/audio/bake_audio.gd -- [--out=artifacts/audio] [--key=hearth_bed]
##
## This is a LISTENING tool, not a build step. The game synthesises at runtime —
## there is nothing to check in and nothing to keep in sync, which is the point
## of generating the soundtrack in the first place. What this gives you is the
## ability to open a folder in an audio editor and hear whether the fire sounds
## like a fire, and a printed table of what every sound costs to build.
##
## Nothing here may name an autoload: a `--script` entry point is compiled
## before the autoloads are registered.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var code: int = _bake()
	quit(code)
	return true


func _bake() -> int:
	var out_dir: String = "res://artifacts/audio"
	var only: String = ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--key="):
			only = a.substr(6)

	var base: String = ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(base)

	var recipes: Dictionary = LcnSynthRecipes.all()
	var keys: Array = recipes.keys()
	keys.sort()

	print("─────────────────────────────────────────────────────────────────────")
	print(" Last City: Nightfall — audio bake → %s" % base)
	print("─────────────────────────────────────────────────────────────────────")
	print(" %-18s %7s %7s %6s %8s %7s" % ["sound", "sec", "rate", "loop", "KiB", "ms"])

	var total_ms: float = 0.0
	var total_bytes: int = 0
	var bad: int = 0
	for k: Variant in keys:
		var key: StringName = k
		if only != "" and String(key) != only:
			continue
		var spec: Dictionary = recipes[key]
		var job := LcnSynthJob.new(key, spec)
		while not job.advance(1 << 22):
			pass
		if job.stream == null:
			print(" %-18s FAILED" % String(key))
			bad += 1
			continue
		if job.non_finite > 0:
			print(" %-18s %d non-finite samples were silenced" % [String(key), job.non_finite])
			bad += 1
		var ms: float = float(job.build_usec) / 1000.0
		total_ms += ms
		total_bytes += job.byte_size()
		print(" %-18s %7.2f %7d %6s %8.1f %7.1f" % [
			String(key), job.stream.get_length(), job.stream.mix_rate,
			"yes" if bool(spec.get("loop", false)) else "-",
			float(job.byte_size()) / 1024.0, ms])
		var path: String = "%s/%s.wav" % [base, String(key)]
		var err: int = _write_wav(path, job.stream)
		if err != OK:
			print(" %-18s could not be written (%d)" % [String(key), err])
			bad += 1

	print("─────────────────────────────────────────────────────────────────────")
	print(" %d sounds, %.1f KiB, %.0f ms of synthesis" % [
		keys.size(), float(total_bytes) / 1024.0, total_ms])
	if bad > 0:
		print(" BAKE FAILED — %d problem(s)" % bad)
		return 1
	print(" BAKE OK")
	return 0


## AudioStreamWAV.save_to_wav exists but is editor-only in some builds, so the
## 44-byte canonical header is written by hand. Mono, 16-bit, PCM.
func _write_wav(path: String, stream: AudioStreamWAV) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var pcm: PackedByteArray = stream.data
	var rate: int = stream.mix_rate
	var channels: int = 2 if stream.stereo else 1
	var bits: int = 16
	var byte_rate: int = rate * channels * bits / 8
	var align: int = channels * bits / 8

	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + pcm.size())
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)                 # PCM
	f.store_16(channels)
	f.store_32(rate)
	f.store_32(byte_rate)
	f.store_16(align)
	f.store_16(bits)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(pcm.size())
	f.store_buffer(pcm)
	f.close()
	return OK

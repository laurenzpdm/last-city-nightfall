extends TestCase
## [P23] The bank's budget and the mixer's bus graph.
##
## The mixer is asserted rather than eyeballed because the bus graph is the one
## part of this whole soundtrack a player can break from the options screen: if
## `Sfx` does not send into `Master`, the sfx slider silently controls nothing.
## Godot also only lets a bus send to a LOWER index, so the creation order IS the
## graph and getting it wrong produces a warning nobody reads and a routing
## nobody notices.
##
## These suites run headless against the Dummy audio driver, which implements the
## full AudioServer bus API — so the graph tested here is the graph that ships.

var _mixer: LcnAudioMixer = null


func suite_name() -> String:
	return "audio_bank_mixer"


func teardown() -> void:
	if _mixer != null:
		_mixer.uninstall()
		_mixer = null


func _fresh_mixer() -> LcnAudioMixer:
	_mixer = LcnAudioMixer.new()
	_mixer.install()
	return _mixer


# ================================================================== the bank ==

func test_the_bank_bakes_the_essentials_up_front_and_queues_the_rest() -> void:
	var bank := LcnSoundBank.new()
	bank.warm_up()
	for key: StringName in LcnSynthRecipes.essential():
		assert_true(bank.has(key), "essential '%s' is ready before the first frame" % key)
	assert_gt(float(bank.pending_count()), 0.0, "and the rest are queued")
	assert_false(bank.finished(), "the bake is not done yet")


func test_pumping_respects_its_budget() -> void:
	var bank := LcnSoundBank.new()
	bank.queue_all()
	for i: int in 6:
		var t0: int = Time.get_ticks_usec()
		bank.pump(2000)
		var spent: int = Time.get_ticks_usec() - t0
		# One slice can overshoot — the check is that it does not overshoot by
		# an order of magnitude, which would be a frame hitch.
		assert_lt(float(spent), 40000.0, "a 2 ms budget did not become 40 ms")


func test_pumping_eventually_finishes_the_whole_catalogue() -> void:
	var bank := LcnSoundBank.new()
	bank.queue_all()
	var guard: int = 0
	while not bank.finished() and guard < 20000:
		bank.pump(4000)
		guard += 1
	assert_true(bank.finished(), "the bake completed")
	assert_eq(bank.ready_count(), LcnSynthRecipes.all().size(), "every recipe is baked")
	var r: Dictionary = bank.report()
	assert_eq(int(r["non_finite_samples"]), 0, "and nothing had to be scrubbed")
	assert_gt(float(r["kib"]), 100.0, "the bank holds real audio")


func test_asking_for_an_unbaked_stream_is_a_counted_silence_not_an_error() -> void:
	var bank := LcnSoundBank.new()
	bank.queue_all()
	assert_null(bank.get_stream(&"toll"), "not baked yet, so no stream")
	assert_eq(int(bank.report()["misses"]), 1, "the miss was counted")
	# ...and asking promotes it, so the cue arrives next frame rather than in
	# alphabetical order half a second later.
	var guard: int = 0
	while not bank.has(&"toll") and guard < 200:
		bank.pump(20000)
		guard += 1
	assert_true(bank.has(&"toll"), "asking for it moved it to the front of the queue")
	assert_lt(float(guard), 6.0, "and it arrived within a few frames")


func test_an_unknown_key_is_refused_quietly() -> void:
	var bank := LcnSoundBank.new()
	assert_null(bank.build_now(&"no_such_sound"), "unknown key builds nothing")
	bank.queue(&"no_such_sound")
	assert_eq(bank.pending_count(), 0, "and never joins the queue")


# ================================================================= the desk ==

func test_the_bus_graph_is_built_exactly_as_declared() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	assert_true(mixer.installed, "installed")
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		var name: String = String(row["name"])
		var idx: int = AudioServer.get_bus_index(name)
		assert_ge(float(idx), 1.0, "%s exists and is not Master" % name)
		assert_eq(String(AudioServer.get_bus_send(idx)), String(row["send"]),
			"%s sends into %s" % [name, row["send"]])


func test_every_bus_sends_to_a_lower_index_because_godot_requires_it() -> void:
	_fresh_mixer()
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		var idx: int = AudioServer.get_bus_index(String(row["name"]))
		var parent: int = AudioServer.get_bus_index(String(row["send"]))
		assert_lt(float(parent), float(idx),
			"%s (%d) must come after its parent %s (%d)" % [row["name"], idx, row["send"], parent])


func test_the_four_player_sliders_reach_the_four_buses_they_claim_to() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	for slider: String in LcnAudioDefs.SLIDER_BUS:
		var bus: StringName = LcnAudioDefs.SLIDER_BUS[slider]
		assert_ge(float(mixer.bus_index(bus)), 0.0, "%s has a bus" % slider)
	# Master, Music, Ambience, Sfx — everything else hangs off one of them, so
	# every voice in the game is under exactly one slider.
	assert_eq(LcnAudioDefs.SLIDER_BUS.size(), 4, "four sliders")
	for row: Dictionary in LcnAudioDefs.BUS_TREE:
		var reachable: bool = false
		var cursor: StringName = row["name"]
		var hops: int = 0
		while hops < 8:
			hops += 1
			if LcnAudioDefs.SLIDER_BUS.values().has(cursor):
				reachable = true
				break
			var next: StringName = &""
			for r: Dictionary in LcnAudioDefs.BUS_TREE:
				if StringName(r["name"]) == cursor:
					next = r["send"]
			if next == &"":
				break
			cursor = next
		assert_true(reachable, "%s is under a slider the player owns" % row["name"])


func test_the_master_bus_carries_a_limiter() -> void:
	_fresh_mixer()
	var master: int = AudioServer.get_bus_index("Master")
	var found: bool = false
	for i: int in AudioServer.get_bus_effect_count(master):
		if AudioServer.get_bus_effect(master, i) is AudioEffectHardLimiter:
			found = true
	assert_true(found, "a hundred-body assault must not clip the mix into mush")


func test_the_scenic_buses_are_sidechained_to_the_alert_bus() -> void:
	_fresh_mixer()
	for name: StringName in LcnAudioDefs.DUCKED_BUSES:
		var idx: int = AudioServer.get_bus_index(String(name))
		var sidechained: bool = false
		for i: int in AudioServer.get_bus_effect_count(idx):
			var fx: AudioEffect = AudioServer.get_bus_effect(idx, i)
			var comp := fx as AudioEffectCompressor
			if comp != null and String(comp.sidechain) == String(LcnAudioDefs.BUS_ALERT):
				sidechained = true
		assert_true(sidechained, "%s ducks under an alert" % name)
	assert_false(LcnAudioDefs.DUCKED_BUSES.has(LcnAudioDefs.BUS_ALERT),
		"the alert bus must never duck itself")


func test_installing_twice_does_not_double_the_graph() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	var before: int = AudioServer.bus_count
	var master_effects: int = AudioServer.get_bus_effect_count(0)
	mixer.install()
	assert_eq(AudioServer.bus_count, before, "no duplicate buses")
	assert_eq(AudioServer.get_bus_effect_count(0), master_effects, "no duplicate effects")


func test_an_alert_ducks_the_scenery_and_the_scenery_comes_back() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	var quiet: float = mixer.db_of(LcnAudioDefs.BUS_MUSIC)
	mixer.duck(2)
	for i: int in 12:
		mixer.update(0.016)
	var ducked: float = mixer.db_of(LcnAudioDefs.BUS_MUSIC)
	assert_lt(ducked, quiet - 1.0, "the score got out of the way")
	assert_gt(mixer.duck_amount(), 0.2, "and the desk knows it is ducking")
	for i: int in 200:
		mixer.update(0.016)
	assert_near(mixer.db_of(LcnAudioDefs.BUS_MUSIC), quiet, 0.6, "and it came back")
	assert_lt(mixer.duck_amount(), 0.05, "duck released")


func test_a_louder_alert_ducks_harder() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	mixer.duck(0)
	for i: int in 12:
		mixer.update(0.016)
	var soft: float = mixer.db_of(LcnAudioDefs.BUS_MUSIC)
	for i: int in 200:
		mixer.update(0.016)
	mixer.duck(2)
	for i: int in 12:
		mixer.update(0.016)
	var hard: float = mixer.db_of(LcnAudioDefs.BUS_MUSIC)
	assert_lt(hard, soft, "severity 2 ducks further than severity 0")


func test_the_settings_dictionary_drives_the_gains() -> void:
	var settings: Node = TestEnv.autoload("Settings")
	if settings == null:
		skip("no Settings autoload in this process")
		return
	var mixer: LcnAudioMixer = _fresh_mixer()
	var original: Dictionary = (settings.get("audio") as Dictionary).duplicate()

	settings.set("audio", {"master": 1.0, "music": 1.0, "sfx": 1.0, "ambience": 1.0})
	mixer.apply_settings(true)
	var loud: float = mixer.db_of(LcnAudioDefs.BUS_MUSIC)

	settings.set("audio", {"master": 1.0, "music": 0.25, "sfx": 1.0, "ambience": 1.0})
	mixer.apply_settings(true)
	var soft: float = mixer.db_of(LcnAudioDefs.BUS_MUSIC)
	assert_lt(soft, loud - 3.0, "turning the music down turns the music down")

	settings.set("audio", {"master": 0.0, "music": 1.0, "sfx": 1.0, "ambience": 1.0})
	mixer.apply_settings(true)
	assert_eq(mixer.db_of(LcnAudioDefs.BUS_MASTER), LcnDsp.MIN_DB, "zero master is silence")
	assert_true(is_finite(mixer.db_of(LcnAudioDefs.BUS_MASTER)), "and it is finite, not -INF")

	settings.set("audio", original)
	mixer.apply_settings(true)


func test_the_filters_follow_the_world_and_never_leave_their_range() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	for storm: float in [0.0, 0.5, 1.0, NAN, 9.0, -3.0]:
		mixer.storm01 = storm
		mixer.hearth01 = storm
		mixer.factory01 = storm
		mixer.update(0.016)
		var r: Dictionary = mixer.report()
		for row: Dictionary in r["buses"]:
			assert_true(is_finite(float(row.get("volume_db", 0.0))),
				"%s volume stayed finite at storm=%f" % [row["bus"], storm])


func test_the_report_names_every_bus_and_its_effects() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	var r: Dictionary = mixer.report()
	assert_eq(int(r["bus_count"]), LcnAudioDefs.BUS_TREE.size() + 1, "master plus the tree")
	var seen: Array[String] = []
	for row: Dictionary in r["buses"]:
		assert_true(bool(row["present"]), "%s is present" % row["bus"])
		seen.append(String(row["bus"]))
	assert_has(seen, "Master")
	assert_has(seen, "Hearth")
	assert_has(seen, "Alert")


func test_uninstall_leaves_the_engine_as_it_found_it() -> void:
	var mixer: LcnAudioMixer = _fresh_mixer()
	assert_gt(float(AudioServer.bus_count), 1.0, "buses exist")
	mixer.uninstall()
	_mixer = null
	assert_eq(AudioServer.bus_count, 1, "only Master is left")

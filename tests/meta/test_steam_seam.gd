extends TestCase
## [P24] The Steam seam is safe with no Steam attached — which is the state of
## every CI run, every headless gate run, and every launch until somebody
## attaches a real app id.
##
## This is the whole point of shipping a seam rather than a dependency: the
## build must behave identically with and without it. If `godotsteam` were in
## the repo today, every one of the ~40 headless invocations in tools/check.sh
## would load a native extension and print a load error when `steam_api` is not
## present — and the gate counts engine errors.

func test_the_seam_is_silent_with_no_steam_client() -> void:
	assert_false(LcnSteamSeam.available(), "no Steam singleton in a plain build")
	assert_no_errors(func() -> void:
		var _a: bool = LcnSteamSeam.init_if_present()
		var _b: bool = LcnSteamSeam.init_if_present(),
		"initialising twice with no client logs nothing")


func test_an_achievement_can_be_raised_with_nothing_listening() -> void:
	assert_no_errors(func() -> void:
		LcnSteamSeam.unlock(&"first_night"),
		"raising a declared achievement is safe")
	assert_has(LcnSteamSeam.unlocked_this_session(), &"first_night", "it was recorded")
	var count: int = LcnSteamSeam.unlocked_this_session().size()
	LcnSteamSeam.unlock(&"first_night")
	assert_eq(LcnSteamSeam.unlocked_this_session().size(), count,
		"raising it twice does not raise it twice")


func test_every_declared_achievement_names_a_fact_this_build_can_measure() -> void:
	# An achievement list written against facts nobody publishes is a store page
	# that cannot be honoured. Each entry names a `system.metric` and this checks
	# the system exists and publishes something.
	var seen: Dictionary[String, bool] = {}
	for row: Dictionary in LcnSteamSeam.ACHIEVEMENTS:
		var id: String = String(row["id"])
		assert_false(seen.has(id), "achievement id '%s' is unique" % id)
		seen[id] = true
		assert_true(String(row.get("name", "")).length() > 0, "%s has a display name" % id)
		assert_true(String(row.get("how", "")).length() > 10, "%s says how it is earned" % id)
		var fact: String = String(row.get("fact", ""))
		assert_true(fact.length() > 0, "%s names the fact it waits on" % id)
		for word: String in fact.split(" "):
			if not word.contains("."):
				continue
			var system_name: String = word.split(".")[0].strip_edges()
			if system_name == "" or not system_name[0].is_valid_identifier():
				continue
			assert_true(_system_exists(system_name),
				"'%s' waits on the %s system, which is in this build" % [id, system_name])


func test_the_cloud_directory_is_the_directory_saves_are_actually_written_to() -> void:
	LcnSaveFile.ensure_dir()
	var declared: String = LcnSteamSeam.save_directory_for_cloud()
	var real: String = ProjectSettings.globalize_path(LcnSaveFile.path_for("x")).get_base_dir()
	assert_eq(declared.rstrip("/"), real.rstrip("/"),
		"Steam auto-cloud would sync the folder the game writes into")


func test_the_platform_line_says_something_a_critic_can_read() -> void:
	var line: String = LcnSteamSeam.platform_line()
	assert_true(line.length() > 0, "the title screen has something to print")
	assert_true(line.contains(OS.get_name()), "it names the platform: '%s'" % line)


func _system_exists(system_name: String) -> bool:
	if Sim.get_system(StringName(system_name)) != null:
		return true
	# The suite may run with no world; fall back to the pillar's own folder.
	# NOT "<name>/<name>_system.gd": [P05]'s file is citizen_system.gd while its
	# system name is "citizens", and guessing the filename made this check pass
	# for the wrong reason on four of five entries.
	return DirAccess.dir_exists_absolute("res://game/sim/%s" % system_name)

extends SceneTree
# Mars's own mechanic, end to end: a scripted player farms the first dome, builds more as the colony may, keeps going past the goal
# ("established") and lets the plants of every dome thicken the air until Mars is terraformed, the best way to win. It checks what the
# player would see on the way: the stages of the air in order, the two garden sites that open at open-air farming, the colony bar's air
# gauge, the ending and its score. The rules themselves (the air's pace, the stages, the sites) are tested in tests/test_colony.cpp.
#
#   Godot --headless --path godot -s res://tests/terraform_test.gd
#
# The player is a bot with a simple plan: two beds of lettuce to eat, two of potato for the leaf and the calories, a dome built as soon as
# the colony may (and keeps 70 days of food after), every dome watered and fed. It points the leaderboard and the preferences at scratch files.

const Settlement = preload("res://scripts/settlement.gd")
const Driver = preload("res://scripts/training_driver.gd")
const Leaderboard = preload("res://scripts/leaderboard.gd")
const Prefs = preload("res://scripts/prefs.gd")

const CROPS := ["lettuce", "lettuce", "potato", "potato"]
const BUILD_AT_DAYS_OF_FOOD := 70.0
const LIMIT_DAYS := 700

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

# water, feed, harvest, clear and sow every bed of a dome, the way a patient player would
func tend(bay: FarmBay) -> void:
	bay.set_setting("auto_irrigate", true)
	for b in bay.get_bed_count():
		if float(bay.get_bed_info(b)["nutrient"]) < 0.5 and float(bay.get_status()["nutrient_stock"]) > 0.0:
			bay.feed(b, 3.0)
		for s in int(bay.get_bed_info(b)["slots"]):
			var p: Dictionary = bay.get_plant(b, s)
			if not p["empty"] and (p["ready"] or p["stage"] == FarmBay.STAGE_OVERRIPE):
				bay.harvest(b, s)
			if bay.get_plant(b, s)["empty"] or bay.get_plant(b, s)["stage"] == FarmBay.STAGE_DEAD:
				bay.remove(b, s)
				bay.plant(b, s, CROPS[b % CROPS.size()])

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	root.size = Vector2i(1600, 900)
	Leaderboard.path = "user://test_leaderboard.json"
	Prefs.path = "user://test_prefs.cfg"
	Leaderboard.clear()
	Prefs.erase()
	if Engine.has_meta("colony_start"):
		Engine.remove_meta("colony_start")
	Settlement.reset()
	await process_frame

	var packed := load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene
	var farm: Node3D = packed.instantiate()
	farm.ask_difficulty = false
	root.add_child(farm)
	current_scene = farm
	await process_frame
	await process_frame
	farm.set_speed(0.0)
	farm.voice.set_audio(false)
	farm.colony_ui.choose(0, false)
	farm.set_speed(0.0)
	var first: FarmBay = farm.bay
	var start: Dictionary = first.get_colony()
	var air0: Dictionary = first.get_terraform()
	check(bool(air0["enabled"]) and float(air0["progress"]) == 0.0 and int(air0["stage"]) == 0, "Mars tracks the air from the start, thin")
	check(int(start["max_units"]) == 6, "six domes at first")
	for b in 4:
		Driver.sow_bed(farm, b, CROPS[b])
	tend(first)

	var stages: Array = []
	first.terraform_stage.connect(func(stage): stages.append([int(first.get_colony()["day"]), stage]))
	farm.open_settlement()
	for i in 4:
		await process_frame
	var view: Node3D = current_scene
	var st: Node = Settlement.peek()
	view.voice.set_audio(false)
	view.set_speed(0.0)
	var ui = view.colony_ui
	check(st != null and st.world != null, "the settlement carries the weather")

	var days := 0
	var kept := false
	var sites_opened_at := -1
	var gauge_seen := false
	var best_units := 1
	while days < LIMIT_DAYS:
		var c: Dictionary = first.get_colony()
		if not bool(c["running"]):
			break
		if bool(c["expansion_ready"]) and float(c["reserve_days"]) >= BUILD_AT_DAYS_OF_FOOD:
			for i in view.Look.SITES.size():
				if view.state_of(i) == "ready":
					view.select_site(i)
					view.build_here()
					break
		if bool(c["established"]) and not kept:
			kept = true
			check(ui.phase == "ending" and ui._ending.visible, "reaching the goal establishes the colony and asks what to do next")
			check(float(c["day"]) >= float(c["goal_days"]) - 1.0 and c["running"], "and the run is not over")
			ui.keep_going()
			check(ui.phase == "playing", "Keep going carries on")
		if int(c["max_units"]) == 8 and sites_opened_at < 0:
			sites_opened_at = days
		best_units = maxi(best_units, int(c["units"]))
		for u in st.units:
			tend(u["bay"])
		st.advance_all(24.0)
		days += 1
		if not gauge_seen and float(first.get_terraform()["progress"]) > 0.02:
			ui._refresh_bar()
			gauge_seen = ui._air_label.visible and ui._air_label.text.begins_with("Air ")
	var end: Dictionary = first.get_colony()

	# ---- what happened ----
	check(days < LIMIT_DAYS, "Mars was terraformed within %d days (it took %d)" % [LIMIT_DAYS, days])
	check(not bool(end["running"]) and int(end["outcome"]) == FarmBay.OUTCOME_TERRAFORMED, "the colony ended as a terraformed Mars (%s)" % str(end["outcome_name"]))
	var order: Array = stages.map(func(s): return s[1])
	check(order == [1, 2, 3, 4], "the air was announced stage by stage, each once, in order: %s" % str(order))
	check(sites_opened_at >= 0 and best_units == 8, "open-air farming opened two more sites, and all eight were built (%d units)" % best_units)
	var air: Dictionary = first.get_terraform()
	check(int(air["best_stage"]) == 4 and float(air["progress"]) >= 0.99, "the air reached 100%% (it has since lost a little in the rest of the day: %.1f%%)" % (100.0 * float(air["progress"])))
	check(gauge_seen, "the colony bar shows the air once it has begun to change")
	check(int(end["arrivals_total"]) > 0 and int(end["population"]) > int(end["crew"]), "the colony grew on the way: %d people" % int(end["population"]))
	var parts: Dictionary = end["score_parts"]
	check(float(parts["bonus"]) >= 6000.0 and int(end["score"]) > 10000, "the win scored well: bonus %d, total %d" % [int(parts["bonus"]), int(end["score"])])
	check(ui.phase == "ending" and ui._ending != null and ui._ending.visible, "the ending is up")
	var words := ""
	for n in ui._ending_box.get_children():
		if n is Label:
			words += (n as Label).text + "\n"
	check(words.find("MARS IS TERRAFORMED") >= 0, "and says that Mars is terraformed")
	check(words.find("domes") >= 0 and words.find("masks") >= 0, "with the story of the domes' plants and the masks")

	Settlement.reset()
	Leaderboard.clear()
	Prefs.erase()
	print("terraform test: %d checks, %d failures (%d days)" % [checks, failures, days])
	quit(1 if failures > 0 else 0)

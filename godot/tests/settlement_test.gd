extends SceneTree
# The settlement: the units of the colony (a greenhouse or a dome each), the overview scene where the player sees them and the sites for
# new ones, building when the colony has food to spare, walking into a unit, and the one clock and one colony they share. The colony's
# rules (when people arrive, when it may expand, what it costs) are tested in tests/test_colony.cpp; this checks what the player sees and
# does. The same file is used by both farming games.
#
#   Godot --headless --path godot -s res://tests/settlement_test.gd

const Settlement = preload("res://scripts/settlement.gd")
const Driver = preload("res://scripts/training_driver.gd")
const Leaderboard = preload("res://scripts/leaderboard.gd")
const Prefs = preload("res://scripts/prefs.gd")

const CROPS := ["lettuce", "radish", "lettuce", "radish"]

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

# the farm scene the project starts in, as the current scene (so that a scene change frees it, as in the game)
func make_farm() -> Node3D:
	var packed := load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene
	var scene: Node3D = packed.instantiate()
	scene.ask_difficulty = false
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	scene.set_speed(0.0)
	scene.voice.set_audio(false)
	if scene.get("_next_storm_sol") != null:
		scene._next_storm_sol = 1000000
	return scene

func settle(frames := 4) -> void:
	for i in frames:
		await process_frame

# harvest what is ripe and sow again, in every bed of a bay
func tend(bay: FarmBay) -> void:
	for b in bay.get_bed_count():
		for s in int(bay.get_bed_info(b)["slots"]):
			var p: Dictionary = bay.get_plant(b, s)
			if not p["empty"] and p["ready"]:
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

	# ---- before the player opens the overview there is no settlement, and the farm is a farm as it always was ----
	check(Settlement.peek() == null, "no settlement before the overview is opened")
	var farm := await make_farm()
	check(farm.unit_index == 0 and farm.colony_bay == farm.bay and farm.unit_noun != "", "the first farm scene is unit 1 and holds the colony")
	check(farm.has_method("open_settlement"), "the farm can open the overview")
	farm.colony_ui.choose(0, false)
	farm.set_speed(0.0)
	var first_bay: FarmBay = farm.bay
	var colony0: Dictionary = first_bay.get_colony()
	check(colony0["started"] and colony0["units"] == 1 and colony0["housing"] > colony0["population"], "the colony starts with one unit and room to spare")
	check(not colony0["expansion_ready"] and not colony0["crowded"], "and no food to spare yet: nothing to build")

	# ---- farm until the colony has food to spare ----
	for b in 4:
		Driver.sow_bed(farm, b, CROPS[b])
	farm.bay.set_setting("auto_irrigate", true)
	var days := 0
	while days < 100 and not bool(first_bay.get_colony()["expansion_ready"]):
		tend(first_bay)
		Driver.advance(farm, 24.0, false)
		days += 1
	farm._refresh_all()
	var ready: Dictionary = first_bay.get_colony()
	check(ready["running"] and ready["expansion_ready"], "a farmed colony has food to spare after a while (day %d)" % days)
	check(days > 15, "but not at once: it takes a harvest first")
	farm.colony_ui._refresh_bar()
	check(farm.colony_ui._btn_settle.visible and farm.colony_ui._btn_settle.text.begins_with("Settlement: BUILD"), "the colony bar points at the settlement")
	var stock_before := float(ready["stock_kcal"])

	# ---- open the overview ----
	farm.open_settlement()
	await settle()
	var view: Node3D = current_scene
	check(view != null and view != farm and view.has_method("state_of"), "the overview is the current scene")
	var st: Node = Settlement.peek()
	check(st != null and st.units.size() == 1 and st.primary() == first_bay, "the first unit is the farm's own bay, kept by the settlement")
	check(first_bay.get_parent() == st and is_instance_valid(first_bay), "and it lives on after its scene is gone")
	var sites: int = view.Look.SITES.size()
	check(sites >= 4 and view.state_of(0) == "built", "the overview has its sites, the first with the first unit")
	var free_ready := 0
	for i in range(1, sites):
		free_ready += 1 if view.state_of(i) == "ready" else 0
	check(free_ready == mini(sites - 1, int(first_bay.get_colony()["max_units"]) - 1), "every free site the colony may use is open to build on")
	check(view.why_not() == "", "nothing stops the player building")
	check(view._info.text.find("Food to spare") >= 0, "the panel says so: %s" % view._info.text.replace("\n", " | "))

	# ---- the card of a site ----
	view.select_site(0)
	check(view._enter_btn.visible and not view._build_btn.visible and view._card_title.text.begins_with(view.unit_noun.capitalize()), "a unit's card offers to go in")
	view.select_site(1)
	check(view._build_btn.visible and not view._enter_btn.visible, "a free site's card offers to build")
	await physics_frame
	view.select_site(-1)
	view.pick(view.site_screen(1))
	check(view.site == 1, "clicking on a site selects it")
	view.pick(Vector2(2, 2))
	check(view.site == -1, "and clicking on empty space selects nothing")

	# ---- build ----
	view.select_site(1)
	var idx: int = view.build_here()
	check(idx == 1 and st.units.size() == 2 and view.state_of(1) == "built", "building puts a unit on the site")
	var after: Dictionary = first_bay.get_colony()
	check(after["units"] == 2 and after["housing"] == 2 * ready["housing"], "the colony counts it, and its housing doubles")
	check(float(after["stock_kcal"]) < stock_before - 5.0 * float(ready["need_kcal_day"]), "the building crew ate days of food")
	check(view._toast.text.find("built") >= 0, "the player is told")
	var second: FarmBay = st.unit_bay(1)
	check(second != first_bay and second.get_bed_count() == first_bay.get_bed_count(), "the new unit is a bay like the first")
	check(not second.get_colony()["started"], "and holds no colony of its own: it feeds the first's")
	check(second.get_parent() == st and second.time_scale == first_bay.time_scale, "it runs on the settlement's clock")
	check(view.build_here() == -1 or view.site != 1, "a built site cannot be built on again")
	check(int(view.st.build(1)) == -1, "the settlement refuses it as well")

	# what the new unit grows feeds the colony
	for b in 4:
		second.plant(b, 0, "radish")
	second.set_setting("auto_irrigate", true)
	var harvested_before := float(first_bay.get_colony()["harvested_kcal"])
	var guard := 0
	var got := false
	while guard < 60 and not got:
		st.advance_all(24.0)
		guard += 1
		for b in 4:
			if second.get_plant(b, 0)["ready"]:
				second.harvest(b, 0)
				got = true
	check(got and float(first_bay.get_colony()["harvested_kcal"]) > harvested_before, "what the new unit harvests feeds the colony")
	check(float(first_bay.get_colony()["day"]) > float(ready["day"]) + 10.0 and not second.get_colony().has("day"), "the colony's clock is the first unit's alone")

	# one clock for every unit
	view.set_speed(16.0)
	check(first_bay.time_scale == 16.0 and second.time_scale == 16.0 and st.speed == 16.0, "the speed buttons set every unit's clock")
	view.set_speed(0.0)

	# ---- walk into the second unit ----
	view.select_site(1)
	view._enter_btn.pressed.emit()
	await settle()
	var farm2: Node3D = current_scene
	check(farm2 != view and farm2.has_method("open_settlement") and farm2.unit_index == 1, "the Enter button takes the player into the unit")
	check(farm2.bay == second and farm2.colony_bay == first_bay, "which shows that unit's bay, and the colony of the first")
	farm2.voice.set_audio(false)
	farm2.set_speed(0.0)
	farm2._refresh_all()
	check(farm2.colony_ui._mode_label.text.find("2 %ss" % farm2.unit_noun) >= 0, "the colony bar counts the units: %s" % farm2.colony_ui._mode_label.text)
	check(farm2.colony_ui._btn_settle.visible, "and still points at the settlement")
	check(st.has_unit(0) and st.has_unit(1) and is_instance_valid(first_bay), "the first unit goes on while the second is on show")
	var plants_here := 0
	for b in second.get_bed_count():
		plants_here += 0 if second.get_plant(b, 0)["empty"] else 1
	check(plants_here > 0 or got, "the second unit still has what was sown there")

	# ---- back to the overview: the same settlement ----
	farm2.open_settlement()
	await settle()
	var view2: Node3D = current_scene
	check(view2.has_method("state_of") and Settlement.peek() == st and st.units.size() == 2 and st.current == 1, "the overview again, with the same settlement")
	check(view2.state_of(0) == "built" and view2.state_of(1) == "built", "both units on their sites")

	# ---- fill the sites, then no more ----
	var built := 2
	guard = 0
	while built < view2.Look.SITES.size() and guard < 400:
		guard += 1
		var c: Dictionary = view2.colony()
		if bool(c["expansion_ready"]):
			var free := -1
			for i in view2.Look.SITES.size():
				if view2.state_of(i) == "ready":
					free = i
					break
			if free < 0:
				break
			view2.select_site(free)
			if view2.build_here() >= 0:
				built += 1
			continue
		if not bool(c["running"]):
			break
		for u in st.units:
			tend(u["bay"])
		st.advance_all(24.0)
	check(built == view2.Look.SITES.size() or not bool(view2.colony()["running"]) or not bool(view2.colony()["expansion_ready"]), "the player can go on building while there is food to spare (units: %d)" % built)
	if built == view2.Look.SITES.size():
		check(not bool(view2.colony()["expansion_ready"]), "and with every site taken there is nothing more to build")
		check(view2.why_not() != "", "the view says why: %s" % view2.why_not())

	# ---- a new game forgets the units ----
	Settlement.reset()
	await settle()
	check(Settlement.peek() == null, "a new game starts with no settlement")

	Leaderboard.clear()
	Prefs.erase()
	print("settlement test: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)

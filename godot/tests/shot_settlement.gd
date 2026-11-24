extends SceneTree
# A picture of the settlement overview (real renderer, off-screen): the sites where a new greenhouse may be built, and the greenhouses that
# are. It plays a real colony on Easy, with the farm kept fed, until the crew has outgrown the housing and the colony may expand, and
# then opens the overview the way the player does (the Settlement button on the colony bar).
#
#   Godot --path godot --resolution 1600x900 --position -3000,-3000 -s res://tests/shot_settlement.gd -- <name> <moment> [key=value ...]
#
# moment: fresh (a colony just started: one unit, every other site locked), ready (the housing is full and there is food to spare: a
# site is open to build on), select (ready, a free site selected), built (the colony has built a second unit and grown into it) or
# full (four units: built directly, because no Easy colony lasts long enough to fill every site honestly).
# keys: yaw=, pitch=, dist= (the camera)   site=N (the site to select)   air=P (Mars: the air's progress, 0 to 1, drawn as if the plants had done it)
# Saves godot/shots/<name>.png (git-ignored); a name ending in .jpg is saved as a small JPEG. The leaderboard and the preferences are
# scratch files with made-up names, so nothing of the player's is read or written.

const Settlement = preload("res://scripts/settlement.gd")
const Driver = preload("res://scripts/training_driver.gd")
const Leaderboard = preload("res://scripts/leaderboard.gd")
const Prefs = preload("res://scripts/prefs.gd")

const CROPS := ["lettuce", "radish", "lettuce", "radish"]

func _initialize() -> void:
	_run()

# Harvest whatever is ripe and sow again, in every bed of a bay (the farm kept running, one visit a day).
func _tend(bay: FarmBay) -> void:
	for b in bay.get_bed_count():
		for s in int(bay.get_bed_info(b)["slots"]):
			var p: Dictionary = bay.get_plant(b, s)
			if not p["empty"] and p["ready"]:
				bay.harvest(b, s)
			if bay.get_plant(b, s)["empty"] or bay.get_plant(b, s)["stage"] == FarmBay.STAGE_DEAD:
				bay.remove(b, s)
				bay.plant(b, s, CROPS[b % CROPS.size()])

# A unit on a site with no questions asked of the colony (for the picture of a settlement that is full).
func _force_build(st: Node, site: int) -> void:
	var bay: FarmBay = st.factory.call()
	bay.name = "Unit%d" % (st.units.size() + 1)
	st.add_child(bay)
	bay.link_colony(st.primary())
	bay.time_scale = st.speed
	st.units.append({"bay": bay, "site": site})
	st.unit_built.emit(st.units.size() - 1)

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var shot_name: String = args[0] if args.size() > 0 else "settlement"
	var moment: String = args[1] if args.size() > 1 else "ready"
	var opts := {}
	for i in range(2, args.size()):
		var kv := str(args[i]).split("=")
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	Leaderboard.path = "user://shot_leaderboard.json"
	Prefs.path = "user://shot_prefs.cfg"
	Leaderboard.clear()
	Prefs.erase()
	Settlement.reset()
	var scene: Node3D = (load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene).instantiate()
	scene.ask_difficulty = false
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	scene.set_speed(0.0)
	scene.voice.set_audio(false)                   # a screenshot must not speak through the speakers
	if scene.get("_next_storm_sol") != null:
		scene._next_storm_sol = 1000000
	scene.colony_ui.choose(0, false)
	scene.set_speed(0.0)
	for b in 4:
		Driver.sow_bed(scene, b, CROPS[b])
	scene.bay.set_setting("auto_irrigate", true)
	var days := 0
	var colony_bay: FarmBay = scene.colony_bay
	if moment != "fresh":                          # play the farm until the colony may expand
		while days < 400:
			var c: Dictionary = colony_bay.get_colony()
			if not bool(c["running"]):
				print("the colony ended on day ", days)
				break
			if bool(c["expansion_ready"]):
				break
			_tend(scene.bay)
			Driver.advance(scene, 24.0, false)
			days += 1
	scene._refresh_all()
	var c1: Dictionary = colony_bay.get_colony()
	print("day ", days, "  population ", c1["population"], "/", c1["housing"], "  ready=", c1["expansion_ready"], "  food ", int(c1["reserve_days"]), " days")
	scene.open_settlement()
	for i in 4:
		await process_frame
	var view: Node3D = current_scene
	view.voice.set_audio(false)
	view.set_speed(0.0)
	var look = view.Look
	var want := 4 if moment == "full" else (2 if moment == "built" else 1)
	if moment == "full":
		for i in range(1, 4):
			_force_build(view.st, i)
	else:
		while view.st.units.size() < want:         # build, then let the colony grow into the new unit
			var c: Dictionary = view.colony()
			if bool(c["expansion_ready"]):
				for i in look.SITES.size():
					if view.state_of(i) == "ready":
						view.select_site(i)
						view.build_here()
						break
				continue
			if not bool(c["running"]) or days > 600:
				print("stopped on day ", days)
				break
			for u in view.st.units:
				_tend(u["bay"])
			view.st.advance_all(24.0)
			days += 1
	if opts.has("air"):
		view.debug_set_air(float(opts["air"]))
	if opts.has("yaw"):
		view._yaw = float(opts["yaw"])
	if opts.has("pitch"):
		view._pitch = float(opts["pitch"])
	if opts.has("dist"):
		view._dist = float(opts["dist"])
	view._apply_camera()
	var pick_site := int(opts.get("site", -1))
	if moment == "select" and pick_site < 0:
		for i in look.SITES.size():
			if view.state_of(i) == "ready":
				pick_site = i
				break
	view.select_site(pick_site)
	view._refresh_all()
	view._toast_time = 0.0
	view._toast.modulate.a = 0.0
	for i in (80 if moment == "full" or moment == "built" else 10):      # (a new unit pops up over most of a second)
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var jpg := shot_name.ends_with(".jpg")
	var path := ProjectSettings.globalize_path("res://shots/%s" % (shot_name if jpg else shot_name + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("saved ", path, " err=", img.save_jpg(path, 0.88) if jpg else img.save_png(path), "  units=", view.st.units.size(), "  day ", days)
	Settlement.reset()
	Leaderboard.clear()
	Prefs.erase()
	quit(0)

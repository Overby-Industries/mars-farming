extends SceneTree
# A picture of the colony screens (real renderer, off-screen): the difficulty and voice picker, the bar along the top in play, an
# ending, the leaderboard. Used to eyeball them and to make the README pictures.
#
#   Godot --path godot --resolution 1600x900 --position -3000,-3000 -s res://tests/shot_colony.gd -- <name> <moment>
#
# moment: picker, bar (a colony in play, forty days in), ending (a failed Difficult colony), success (an Easy colony kept fed), board.
# Saves godot/shots/<name>.png (git-ignored); a name ending in .jpg is saved as a small JPEG. The leaderboard and the preferences are
# scratch files with made-up names, so nothing of the player's is read or written.

const Leaderboard = preload("res://scripts/leaderboard.gd")
const Prefs = preload("res://scripts/prefs.gd")
const Driver = preload("res://scripts/training_driver.gd")

const SAMPLE_NAMES := ["Nova", "Orion", "Vega", "Lyra", "Atlas", "Juno", "Kepler", "Halley", "Sagan", "Pulsar"]

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var shot_name: String = args[0] if args.size() > 0 else "colony"
	var moment: String = args[1] if args.size() > 1 else "picker"
	Leaderboard.path = "user://shot_leaderboard.json"
	Prefs.path = "user://shot_prefs.cfg"
	Leaderboard.clear()
	Prefs.erase()
	for d in 3:                                   # a table with some runs on it
		for i in SAMPLE_NAMES.size():
			Leaderboard.submit({"name": SAMPLE_NAMES[i], "score": (9000 - i * 700 + d * 3500) if d > 0 else (5200 - i * 380),
					"difficulty": d, "outcome": "success" if i < 6 else ("extinct" if d == 2 else "evacuated"), "day": [120.0, 200.0, 300.0][d] - (0.0 if i < 6 else 40.0 + i * 3.0)})
	var scene: Node3D = (load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene).instantiate()
	scene.ask_difficulty = moment == "picker"
	root.add_child(scene)
	await process_frame
	await process_frame
	scene.set_speed(0.0)
	scene.voice.set_audio(false)                  # a screenshot must not speak through the speakers
	if scene.get("_next_storm_sol") != null:
		scene._next_storm_sol = 1000000
	var ui = scene.colony_ui
	match moment:
		"bar":
			ui.choose(1, false)
			scene.set_speed(0.0)
			var crops := ["lettuce", "radish", "tomato", "potato"]
			for b in 4:
				Driver.sow_bed(scene, b, crops[b])
			scene.bay.set_setting("auto_irrigate", true)
			Driver.advance(scene, 24.0 * 40.0)
			scene.select_slot(0, 2)
		"ending":
			ui.choose(2, false)
			scene.set_speed(0.0)
			var crops := ["lettuce", "lettuce", "potato", "potato"]
			for b in 4:
				Driver.sow_bed(scene, b, crops[b])
			scene.bay.set_setting("auto_irrigate", false)
			while ui.phase != "ending":
				Driver.advance(scene, 24.0, false)
			scene._refresh_all()
		"success":
			ui.choose(0, false)
			scene.set_speed(0.0)
			for b in 4:
				Driver.sow_bed(scene, b, "lettuce")
			scene.bay.set_setting("auto_irrigate", true)
			var day := 0
			while ui.phase != "ending" and day < 400:
				for b in 4:                         # harvest what is ripe and sow again, once a day
					for s in 8:
						var p: Dictionary = scene.bay.get_plant(b, s)
						if not p["empty"] and p["ready"]:
							scene.bay.harvest(b, s)
						if scene.bay.get_plant(b, s)["empty"] or scene.bay.get_plant(b, s)["stage"] == FarmBay.STAGE_DEAD:
							scene.bay.remove(b, s)
							scene.bay.plant(b, s, "lettuce")
				Driver.advance(scene, 24.0, false)
				day += 1
			scene._refresh_all()
		"board":
			ui.choose(1, false)
			scene.set_speed(0.0)
			ui.show_board(1, 4)
	if scene.astronaut != null:
		scene.astronaut.set_process(false)
		scene.astronaut.pose(11.0)
	scene._toast_time = 0.0
	scene._toast.modulate.a = 0.0
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var jpg := shot_name.ends_with(".jpg")
	var path := ProjectSettings.globalize_path("res://shots/%s" % (shot_name if jpg else shot_name + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("saved ", path, " err=", img.save_jpg(path, 0.88) if jpg else img.save_png(path))
	Leaderboard.clear()
	Prefs.erase()
	quit(0)

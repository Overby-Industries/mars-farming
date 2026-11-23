extends SceneTree
# A scripted play session for the screenshot: sow the four beds with different crops, run some days with automatic
# irrigation, pick a slot, and capture the frame (real renderer, off-screen). Used to eyeball the whole scene.
#
#   Godot --path godot --resolution 1600x900 --position -3000,-3000 -s res://tests/shot_growth.gd -- <name> [days] [noon|storm|night] [default|back|wide] [idle_seconds]
#
# Saves godot/shots/<name>.png (that folder is git-ignored).
#   noon  - 12:00 under a clear sky
#   storm - 12:00 at the peak of a dust storm
#   night - 21:00, the LEDs on
# and the camera: the default view (over the astronaut's shoulder at the beds), `at:x,y,z:distance:yaw:pitch` (look at any
# point), `back` (turned round to face the airlock), `airlock` (close up on the airlock and the supply crates), or `wide`
# (pulled back to take in the whole dome). idle_seconds is where the astronaut's idle animation is frozen (default 3).

const Prefs = preload("res://scripts/prefs.gd")

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var shot_name: String = args[0] if args.size() > 0 else "dome"
	var days := int(args[1]) if args.size() > 1 else 45
	var mode: String = args[2] if args.size() > 2 else "noon"
	var view: String = args[3] if args.size() > 3 else "default"
	Prefs.path = "user://shot_prefs.cfg"      # the picture starts a colony: its choices go to a scratch file, never the player's own
	var scene: Node3D = (load("res://scenes/dome.tscn") as PackedScene).instantiate()
	scene.ask_difficulty = false              # no difficulty picker over the picture
	root.add_child(scene)
	scene.set_speed(0.0)                      # paused before the first frame, so the clock starts exactly at 06:00
	scene._next_storm_sol = 1000000
	await process_frame
	scene.colony_ui.choose(1, false)          # an Intermediate colony, so the bar along the top shows
	scene.set_speed(0.0)
	var crops := ["potato", "lettuce", "radish", "tomato"]
	for b in 4:
		scene.crop_key = crops[b]
		scene.select_slot(b, 0)
		scene.action_sow_bed()
	scene.bay.set_setting("auto_irrigate", true)
	scene.bay.set_setting("nutrient_stock", 40.0)
	for b in 4:
		scene.bay.feed(b, 3.0)
	scene.advance_world(24.0 * days)          # the sowing was at 06:00, so it is 06:00 again
	match mode:
		"storm":
			scene.start_storm(4.0, 48.0)
			scene.advance_world(30.0)         # a day of rising dust, then up to noon at the peak
		"night":
			scene.advance_world(15.0)
		_:
			scene.advance_world(6.0)
	scene._refresh_all()
	scene.voice.set_audio(false)                 # captions only: a screenshot must not speak through the speakers
	scene.select_slot(0, 2)
	if view.begins_with("at:"):          # at:x,y,z:distance:yaw:pitch  - look at any point
		var parts := view.substr(3).split(":")
		var p := parts[0].split(",")
		scene._pivot.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		scene._dist = float(parts[1])
		scene._yaw = float(parts[2])
		scene._pitch = float(parts[3])
		scene._apply_camera()
		view = "custom"
	match view:
		"back":
			scene._yaw = PI + 0.5
			scene._pitch = -0.28
			scene._dist = 6.5
			scene._apply_camera()
		"airlock":
			scene._pivot.position = Vector3(0.6, 0.9, 5.6)
			scene._yaw = PI + 0.25
			scene._pitch = -0.2
			scene._dist = 4.4
			scene._apply_camera()
		"wide":
			scene._yaw = 0.7
			scene._pitch = -0.32
			scene._dist = 15.0
			scene._apply_camera()
	scene._toast_time = 0.0                      # no toast in the picture
	scene._toast.modulate.a = 0.0
	if scene.astronaut != null:
		scene.astronaut.look_at_point(scene.voice.slot_point(0, 2), 10.0, true)
	if scene.astronaut != null:                  # freeze the astronaut's idle animation at a chosen moment (default 3 s)
		scene.astronaut.set_process(false)
		scene.astronaut.pose(float(args[4]) if args.size() > 4 else 3.0)
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var jpg := shot_name.ends_with(".jpg")      # a name ending in .jpg is saved as a small JPEG (README images)
	var path := ProjectSettings.globalize_path("res://shots/%s" % (shot_name if jpg else shot_name + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("saved ", path, " err=", img.save_jpg(path, 0.88) if jpg else img.save_png(path))
	Prefs.erase()
	quit(0)

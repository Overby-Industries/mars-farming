extends SceneTree
# A picture of the training scene at one moment (real renderer, off-screen): the training is played with "Watch it all" up to the
# moment and then stopped there, so the coach panel, the ring and the game are as a player sees them. Used to eyeball the scene.
#
#   Godot --path godot --resolution 1600x900 --position -3000,-3000 -s res://tests/shot_training.gd -- <name> <moment>
#
# moment: welcome, sow (the + ring), sow2 (the whole-bed ring), grow, dry (the Water ring), harvest (the Harvest ring), select,
#         ask, finish, or watch (the pointer on its way to the first +).
# Saves godot/shots/<name>.png (git-ignored); a name ending in .jpg is saved as a small JPEG instead, as for the README image.

const Driver = preload("res://scripts/training_driver.gd")

func pump(t: Node, seconds: float, dt := 0.05) -> void:
	for i in int(seconds / dt):
		step_once(t, dt)

func step_once(t: Node, dt: float) -> void:
	t.tick(dt)
	t.voice.tick(dt)
	var speed: float = t.farm.bay.time_scale
	if speed > 0.0:
		Driver.advance(t.farm, speed * dt)

func pump_until(t: Node, done: Callable, limit: float, dt := 0.05) -> void:
	var spent := 0.0
	while not done.call() and spent < limit:
		step_once(t, dt)
		spent += dt

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var shot_name: String = args[0] if args.size() > 0 else "training"
	var moment: String = args[1] if args.size() > 1 else "welcome"
	var t: Node = (load("res://scenes/training.tscn") as PackedScene).instantiate()
	t.change_scene = false
	root.add_child(t)
	await process_frame
	await process_frame
	t.set_process(false)                      # the script is the clock
	t.voice.set_process(false)
	t.voice.audio = false                     # a screenshot must not speak through the speakers
	var want := {"sow": ["sow", 0], "sow2": ["sow", 1], "grow": ["grow", 0], "dry": ["dry", 1], "harvest": ["harvest", 1],
			"select": ["select", 0], "ask": ["ask", 0], "finish": ["finish", 0]}
	if moment == "watch":
		t.toggle_watch()
		pump_until(t, func(): return t.current_id() == "sow" and t._ptr_on, 120.0)
		pump(t, 0.75)
	elif want.has(moment):
		t.toggle_watch()
		pump_until(t, func(): return t.current_id() == want[moment][0] and t.phase() == want[moment][1], 600.0)
		if moment != "finish":
			t.toggle_watch()                  # stop the demo where it stands
		pump(t, 0.3)
	var man: Node3D = t.farm.astronaut
	if man != null:
		var look: Vector3 = t._look_target()
		if look != Vector3.INF:
			man.look_at_point(look, 10.0, true)
		man.set_process(false)
		man.pose(3.0)
	t.farm._toast_time = 0.0
	t.farm._toast.modulate.a = 0.0
	for i in 6:
		await process_frame
	t.tick(0.0)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var jpg := shot_name.ends_with(".jpg")
	var path := ProjectSettings.globalize_path("res://shots/%s" % (shot_name if jpg else shot_name + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("saved ", path, " err=", img.save_jpg(path, 0.88) if jpg else img.save_png(path))
	quit(0)

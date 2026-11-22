extends SceneTree
# Capture one frame of a scene with the real renderer, off-screen:
#
#   Godot --path godot --resolution 1280x720 --position -3000,-3000 -s res://tests/shot.gd -- res://scenes/showcase.tscn showcase [frames]
#
# Saves godot/shots/<name>.png (that folder is git-ignored). `frames` is how many frames to let the scene run first;
# raise it to let a simulation advance.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -s res://tests/shot.gd -- <scene> <name> [frames]")
		quit(2)
		return
	_run(args[0], args[1], int(args[2]) if args.size() > 2 else 8)

func _run(scene_path: String, shot_name: String, frames: int) -> void:
	await process_frame
	var scene: PackedScene = load(scene_path)
	if scene == null:
		print("could not load ", scene_path)
		quit(1)
		return
	root.add_child(scene.instantiate())
	for i in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://shots/%s.png" % shot_name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("saved ", path, " err=", img.save_png(path), " size=", img.get_size())
	quit(0)

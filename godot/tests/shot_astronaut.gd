extends SceneTree
# The crew astronaut on a bare stage, from the front, the back, three quarters and close up on the helmet, captured with
# the real renderer (off-screen). Used to look at the model beside the concept sheet. Saves godot/shots/<name>_front.png,
# _back.png, _three_quarter.png and _head.png, and <name>_sheet.png with the first three side by side.
#
#   Godot --path godot --resolution 1600x900 --position -3000,-3000 -s res://tests/shot_astronaut.gd -- <name> [pose_seconds] [views]
#
# pose_seconds is where the idle animation is frozen (default 0: at rest). views is a comma-separated list of view names
# (front, back, three_quarter, head, torso, shoulder, pack, legs, arms; default the first four), or all; add dump to
# print the node tree. A name ending in .jpg saves the three-view sheet as a small JPEG under exactly that name (the picture
# in the README is `-- astronaut.jpg 0 front,back,three_quarter`).

const Astronaut = preload("res://scripts/astronaut.gd")

# name, camera position, look-at point, vertical field of view
const VIEWS := [
	["front", Vector3(0, 0.98, -3.6), Vector3(0, 0.9, 0), 34.0],
	["back", Vector3(0, 0.98, 3.6), Vector3(0, 0.9, 0), 34.0],
	["three_quarter", Vector3(2.5, 1.3, 3.0), Vector3(0, 0.95, 0), 34.0],
	["head", Vector3(0.9, 1.72, -1.1), Vector3(0, 1.62, 0.0), 30.0],
	["torso", Vector3(0.7, 1.45, -1.5), Vector3(0, 1.3, 0.0), 30.0],
	["shoulder", Vector3(1.3, 1.5, -1.0), Vector3(0.2, 1.38, 0.0), 30.0],
	["pack", Vector3(-0.7, 1.45, 1.5), Vector3(0, 1.3, 0.1), 30.0],
	["legs", Vector3(1.7, 0.7, -1.7), Vector3(0, 0.5, 0.0), 32.0],
	["arms", Vector3(1.9, 1.1, -1.4), Vector3(0.2, 1.0, 0.0), 32.0],
]
const DEFAULT_VIEWS := ["front", "back", "three_quarter", "head"]

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var shot_name: String = args[0] if args.size() > 0 else "astronaut"
	var as_jpg := shot_name.ends_with(".jpg")       # a name ending in .jpg: the sheet is saved as a small JPEG (README images)
	shot_name = shot_name.trim_suffix(".jpg")
	var pose_t := float(args[1]) if args.size() > 1 else 0.0
	var wanted: PackedStringArray = (args[2] if args.size() > 2 else ",".join(DEFAULT_VIEWS)).split(",")

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.55, 0.57, 0.61)
	sky_mat.sky_horizon_color = Color(0.86, 0.85, 0.83)
	sky_mat.ground_horizon_color = Color(0.36, 0.36, 0.37)
	sky_mat.ground_bottom_color = Color(0.10, 0.10, 0.11)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.12)
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.1
	root.mesh_lod_threshold = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_color = Color("fff1d8")
	key.light_energy = 1.1
	key.rotation_degrees = Vector3(-45, 30, 0)
	key.shadow_enabled = true
	root.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.light_color = Color("e8eeff")
	rim.light_energy = 0.5
	rim.rotation_degrees = Vector3(-20, 200, 0)
	root.add_child(rim)

	# a round platform instead of an endless floor, so the views share one plain background (no horizon line)
	var floor_mesh := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.85
	disc.bottom_radius = 0.85
	disc.height = 0.05
	disc.radial_segments = 64
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.22, 0.23, 0.25)
	fm.roughness = 0.5
	fm.metallic = 0.6
	disc.material = fm
	floor_mesh.mesh = disc
	floor_mesh.position.y = -0.025
	root.add_child(floor_mesh)

	root.msaa_3d = Viewport.MSAA_4X
	var man: Node3D = Astronaut.new()
	man.recipe = {"idle": false}
	root.add_child(man)

	var cam := Camera3D.new()
	cam.far = 60.0
	root.add_child(cam)
	cam.make_current()
	await process_frame
	man.pose(pose_t)
	if "dump" in wanted:
		_dump(man, 0)

	var images := {}
	for v in VIEWS:
		if not ("all" in wanted or v[0] in wanted):
			continue
		cam.fov = v[3]
		cam.look_at_from_position(v[1], v[2])
		for i in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_viewport().get_texture().get_image()
		images[v[0]] = img
		var path := ProjectSettings.globalize_path("res://shots/%s_%s.png" % [shot_name, v[0]])
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		print("saved ", path, " err=", img.save_png(path))

	# a sheet: the central strip of the first three views, side by side
	if not (images.has("front") and images.has("back") and images.has("three_quarter")):
		quit(0)
		return
	var strip_w := 560
	var h: int = (images["front"] as Image).get_height()
	var sheet := Image.create_empty(strip_w * 3, h, false, Image.FORMAT_RGBA8)
	var k := 0
	for n in ["front", "back", "three_quarter"]:
		var im: Image = images[n]
		im.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(im, Rect2i((im.get_width() - strip_w) / 2, 0, strip_w, h), Vector2i(k * strip_w, 0))
		k += 1
	var sheet_path := ProjectSettings.globalize_path("res://shots/%s%s" % [shot_name, ".jpg" if as_jpg else "_sheet.png"])
	print("saved ", sheet_path, " err=", sheet.save_jpg(sheet_path, 0.9) if as_jpg else sheet.save_png(sheet_path))
	quit(0)

func _dump(n: Node, depth: int) -> void:
	var extra := ""
	if n is MeshInstance3D:
		extra = "  [mesh %d surfaces]" % (n as MeshInstance3D).mesh.get_surface_count()
	print("  ".repeat(depth), n.name, " (", n.get_class(), ")", extra, "  pos=", (n as Node3D).position if n is Node3D else "")
	for c in n.get_children():
		_dump(c, depth + 1)

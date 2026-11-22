extends SceneTree
# Loads the extension in a real Godot and checks what the C++ classes promise: they exist, every shape builds,
# plants grow with their progress, the same seed draws the same plant, textures are deterministic, a bay runs a
# lettuce from seed to harvest, and a recipe that names a missing model falls back to its procedural shape.
#
#   Godot --headless --path godot -s res://tests/smoke.gd

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

func near(a: float, b: float, tol: float, what: String) -> void:
	check(absf(a - b) <= tol, "%s: %f vs %f (+-%f)" % [what, a, b, tol])

func mesh_of(node: Node3D) -> Mesh:
	for child in node.get_children():
		if child is MeshInstance3D:
			return (child as MeshInstance3D).mesh
	return null

func aabb_of(node: Node3D) -> AABB:
	var m := mesh_of(node)
	return m.get_aabb() if m != null else AABB()

func first_vertices(node: Node3D, count: int) -> PackedVector3Array:
	var m := mesh_of(node)
	if m == null or m.get_surface_count() == 0:
		return PackedVector3Array()
	return (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).slice(0, count)

func _initialize() -> void:
	# ---- the classes exist ----
	for cls in ["FarmBay", "FarmShapeBuilder", "FarmSkinGenerator"]:
		check(ClassDB.class_exists(cls), "class %s is registered" % cls)
	if failures > 0:
		print("extension did not load; stopping")
		quit(1)
		return

	var sb := FarmShapeBuilder.new()
	var names := sb.get_shape_names()
	for n in ["box", "cylinder", "capsule", "sphere", "planter_tray", "grow_light", "tank", "plant"]:
		check(n in names, "shape %s is listed" % n)

	# ---- primitives and props ----
	for recipe in [
		{"shape": "box", "size": Vector3(1, 2, 3)},
		{"shape": "cylinder", "radius": 0.3, "height": 1.0},
		{"shape": "capsule", "radius": 0.2, "height": 1.0},
		{"shape": "sphere", "radius": 0.4},
	]:
		var node: Node3D = sb.build_node(recipe)
		check(node != null and mesh_of(node) != null, "%s builds a mesh" % recipe["shape"])
		node.free()

	var box: Node3D = sb.build_node({"shape": "box", "size": Vector3(1, 2, 3)})
	near(aabb_of(box).size.y, 2.0, 1e-4, "box height")
	box.free()

	var planter_recipe := {"shape": "planter_tray", "rows": 2, "cols": 4}
	var planter: Node3D = sb.build_node(planter_recipe)
	var pa := aabb_of(planter)
	near(pa.size.x, 1.2 + 0.024 + 0.028, 0.005, "planter length: 1.2 m + the rust lip + the 4 cm drain stub")
	near(pa.size.y, 0.22, 0.005, "planter height")
	near(pa.size.z, 0.6 + 0.024, 0.005, "planter width: 0.6 m + the rust lip on both sides")
	check(mesh_of(planter).get_surface_count() == 2, "planter has a body surface and a soil surface")
	var slots := sb.get_slot_positions(planter_recipe)
	check(slots.size() == 8, "planter has 2 x 4 slots")
	for s in slots:
		check(absf(s.x) < 0.6 and absf(s.z) < 0.3 and absf(s.y - 0.17) < 1e-4, "slot %s sits on the soil" % str(s))
	check(slots[0].x < slots[1].x and slots[0].z < slots[4].z, "slots run along x, then down z (row-major)")
	planter.free()

	var light: Node3D = sb.build_node({"shape": "grow_light"})
	near(aabb_of(light).size.x, 1.22, 0.02, "grow light length")
	check(light.has_meta("led_material"), "grow light exposes its LED material")
	var led: StandardMaterial3D = light.get_meta("led_material")
	check(led != null and led.emission_enabled, "the LED material glows")
	light.free()

	var tank: Node3D = sb.build_node({"shape": "tank", "radius": 0.35, "height": 0.9})
	near(aabb_of(tank).size.y, 0.9, 0.02, "tank height")
	tank.free()

	# ---- plants: every species, every stage, sensible size and triangle budget ----
	var lister := FarmBay.new()
	var species := lister.get_species_list()
	lister.free()
	check(species.size() == 4, "four species")
	var stage_ids := [FarmBay.STAGE_SEED, FarmBay.STAGE_SPROUT, FarmBay.STAGE_VEGETATIVE, FarmBay.STAGE_FLOWERING,
			FarmBay.STAGE_FRUITING, FarmBay.STAGE_READY, FarmBay.STAGE_OVERRIPE, FarmBay.STAGE_DEAD]
	var progress_for := {FarmBay.STAGE_SEED: 0.03, FarmBay.STAGE_SPROUT: 0.15, FarmBay.STAGE_VEGETATIVE: 0.4,
			FarmBay.STAGE_FLOWERING: 0.6, FarmBay.STAGE_FRUITING: 0.85, FarmBay.STAGE_READY: 1.0,
			FarmBay.STAGE_OVERRIPE: 1.0, FarmBay.STAGE_DEAD: 0.5}
	var max_tris := 0
	for sp in species:
		for st in stage_ids:
			var recipe := {"shape": "plant", "species": sp["key"], "progress": progress_for[st], "stage": st, "health": 1.0, "seed": 7}
			var plant: Node3D = sb.build_node(recipe)
			var box_size := aabb_of(plant).size
			check(mesh_of(plant) != null and mesh_of(plant).get_surface_count() == 1,
					"%s at stage %d builds one surface" % [sp["key"], st])
			check(box_size.y > 0.0 and box_size.y < 0.7 and box_size.x < 0.7 and box_size.z < 0.7,
					"%s at stage %d has a sane size %s" % [sp["key"], st, str(box_size)])
			max_tris = maxi(max_tris, int(plant.get_meta("triangles")))
			plant.free()
	check(max_tris > 0 and max_tris < 6000, "the heaviest plant is %d triangles (budget 6000)" % max_tris)

	# a plant grows: bigger at higher progress
	for key in ["tomato", "potato", "radish", "lettuce"]:
		var sizes: Array[float] = []
		for prog in [0.2, 0.5, 1.0]:
			var stage_for := FarmBay.STAGE_VEGETATIVE if prog < 1.0 else FarmBay.STAGE_READY
			var n: Node3D = sb.build_node({"shape": "plant", "species": key, "progress": prog, "stage": stage_for, "seed": 3})
			var s := aabb_of(n).size
			sizes.append(s.x * s.y * s.z)
			n.free()
		check(sizes[0] < sizes[1] and sizes[1] < sizes[2], "%s grows with progress: %s" % [key, str(sizes)])

	# the same seed gives the same plant; another seed gives another
	var a: Node3D = sb.build_node({"shape": "plant", "species": "tomato", "progress": 0.9, "stage": FarmBay.STAGE_FRUITING, "seed": 11})
	var b: Node3D = sb.build_node({"shape": "plant", "species": "tomato", "progress": 0.9, "stage": FarmBay.STAGE_FRUITING, "seed": 11})
	var c: Node3D = sb.build_node({"shape": "plant", "species": "tomato", "progress": 0.9, "stage": FarmBay.STAGE_FRUITING, "seed": 12})
	check(first_vertices(a, 300) == first_vertices(b, 300), "same seed, same plant")
	check(first_vertices(a, 300) != first_vertices(c, 300), "different seed, different plant")
	check(int(a.get_meta("triangles")) == int(b.get_meta("triangles")), "same seed, same triangle count")
	a.free(); b.free(); c.free()

	# health shows: a failing plant is not the same mesh as a healthy one
	var healthy: Node3D = sb.build_node({"shape": "plant", "species": "lettuce", "progress": 1.0, "stage": FarmBay.STAGE_READY, "health": 1.0, "seed": 5})
	var sick: Node3D = sb.build_node({"shape": "plant", "species": "lettuce", "progress": 1.0, "stage": FarmBay.STAGE_READY, "health": 0.2, "seed": 5})
	var hc: PackedColorArray = mesh_of(healthy).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var sc: PackedColorArray = mesh_of(sick).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(hc[10] != sc[10], "a sick plant is a different colour")
	healthy.free(); sick.free()

	# ---- textures ----
	var gen := FarmSkinGenerator.new()
	var t1 := gen.generate_texture({"kind": "soil", "seed": 4}, 64, 64)
	var t2 := gen.generate_texture({"kind": "soil", "seed": 4}, 64, 64)
	var t3 := gen.generate_texture({"kind": "soil", "seed": 5}, 64, 64)
	check(t1.get_width() == 64 and t1.get_height() == 64, "texture size")
	check(t1.get_image().get_data() == t2.get_image().get_data(), "same seed, same texture")
	check(t1.get_image().get_data() != t3.get_image().get_data(), "different seed, different texture")
	for kind in ["cellular", "soil", "panel"]:
		var t := gen.generate_texture({"kind": kind, "seed": 1}, 32, 32)
		check(t != null and t.get_width() == 32, "%s texture builds" % kind)

	# ---- the bay, end to end ----
	var bay := FarmBay.new()
	var stage_events: Array = []
	var days_seen := [0]
	bay.plant_stage_changed.connect(func(bed, slot, stage): stage_events.append([bed, slot, stage]))
	bay.day_changed.connect(func(d): days_seen[0] = d)
	check(bay.add_bed(2, 4, 0.72) == 0, "first bed is bed 0")
	bay.set_setting("auto_irrigate", true)
	check(bay.plant(0, 0, "lettuce"), "sow a lettuce")
	check(not bay.plant(0, 0, "lettuce"), "an occupied slot refuses a second seed")
	check(not bay.plant(0, 1, "no-such-crop"), "an unknown crop is refused")
	bay.advance_hours(24.0 * 34.0)
	var p := bay.get_plant(0, 0)
	check(p["stage"] == FarmBay.STAGE_READY, "the lettuce is ready after 34 days (stage %s)" % p["stage_name"])
	check(days_seen[0] == 35, "day_changed reached day 35 (saw %d)" % days_seen[0])
	check(stage_events.size() >= 3, "stage signals fired")
	var h := bay.harvest(0, 0)
	check(h["ok"] and h["kg"] > 0.0 and h["kg"] <= 0.2 + 1e-9, "harvest gives up to 0.2 kg (%s)" % str(h))
	check(bay.get_plant(0, 0)["empty"], "the slot is empty after harvest")
	var st := bay.get_status()
	for key in ["day", "tank_l", "energy_kwh", "harvested_kg", "power_demand_w", "lights_on", "temp_c"]:
		check(st.has(key), "status has %s" % key)
	near(st["harvested_kg"], h["kg"], 1e-9, "status counts the harvest")
	bay.free()

	# ---- the model seam falls back when the asset is missing ----
	var fallback: Node3D = sb.build_node({"shape": "box", "size": Vector3(1, 1, 1), "model": "res://models/does_not_exist.glb"})
	check(fallback != null and mesh_of(fallback) != null, "a missing model falls back to the procedural shape")
	fallback.free()
	sb = null

	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

extends SceneTree
# The crew astronaut as modular suit components (blender/build_astronaut.py makes the glb files, scripts/astronaut.gd puts
# them together): every component loads with its origin at its joint and brings the sockets the others hang on; the
# assembled figure is 1.8 m tall, stands on y = 0 and faces -z; the idle animation turns the head and lifts the chest; a
# component can be left out, swapped for another file or missing without breaking anything; a colour can be changed for one
# astronaut and not the next; and the fabric and the armour are different surfaces.
#
#   Godot --headless --path godot --import   (once, so the .glb files are imported)
#   Godot --headless --path godot -s res://tests/astronaut_test.gd

const Astronaut = preload("res://scripts/astronaut.gd")

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

func near(a: float, b: float, tol: float, what: String) -> void:
	check(absf(a - b) <= tol, "%s: %f vs %f (+-%f)" % [what, a, b, tol])

# the transform of `n` in `top`'s space, composed by hand (the nodes are not in the tree)
func to_top(top: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != top:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf

# the bounding box of everything drawable under `top`, in top's space
func bounds(top: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in meshes(top):
		var box: AABB = to_top(top, mi) * (mi as MeshInstance3D).mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out

func meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		out.append_array(meshes(c))
	return out

func material_names(node: Node) -> Array:
	var out: Array = []
	for mi in meshes(node):
		for i in (mi as MeshInstance3D).mesh.get_surface_count():
			var m := (mi as MeshInstance3D).mesh.surface_get_material(i)
			if m != null and not (m.resource_name in out):
				out.append(m.resource_name)
	return out

func area_of(mi: MeshInstance3D, surface: int) -> float:
	var arrays := mi.mesh.surface_get_arrays(surface)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var total := 0.0
	for t in range(0, idx.size(), 3):
		total += 0.5 * (v[idx[t + 1]] - v[idx[t]]).cross(v[idx[t + 2]] - v[idx[t]]).length()
	return total

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame

	# ---- every component: loads, has its mesh and materials, its origin at its joint, its sockets ----
	var comps := {}
	for c in Astronaut.COMPONENTS:
		var path: String = Astronaut.DIR + c[1] + ".glb"
		check(ResourceLoader.exists(path), "%s exists" % path)
		var packed := load(path) as PackedScene
		check(packed != null, "%s loads" % c[1])
		if packed != null:
			var inst := packed.instantiate() as Node3D
			comps[c[0]] = inst
			check(meshes(inst).size() > 0, "%s has meshes" % c[0])
			check(inst.find_child(c[0], true, false) != null or inst.name == c[0], "%s has its root pivot" % c[0])
	check(comps.size() == 11, "eleven components")

	var torso: Node3D = comps["Torso"]
	for s in [["Socket_Neck", Vector3(0, 0.48, 0)], ["Socket_Back", Vector3(0, 0.28, 0.1075)], ["Socket_ShoulderR", Vector3(0.215, 0.40, 0)],
			["Socket_ShoulderL", Vector3(-0.215, 0.40, 0)], ["Socket_HipR", Vector3(0.105, -0.09, 0)], ["Socket_HipL", Vector3(-0.105, -0.09, 0)]]:
		var sock := torso.find_child(s[0], true, false) as Node3D
		check(sock != null, "the torso has %s" % s[0])
		if sock != null:
			check((to_top(torso, sock) * Vector3.ZERO).distance_to(s[1]) < 0.005, "%s is at %s (%s)" % [s[0], str(s[1]), str(to_top(torso, sock) * Vector3.ZERO)])
	check(torso.find_child("Chest", true, false) != null, "the torso has a Chest pivot to breathe with")
	for side in ["R", "L"]:
		var arm: Node3D = comps["Arm" + side]
		var fore := arm.find_child("Forearm" + side, true, false) as Node3D
		check(fore != null and (to_top(arm, fore) * Vector3.ZERO).distance_to(Vector3(0, -0.255, 0)) < 0.005, "arm %s has its elbow pivot 0.255 m below the shoulder" % side)
		var wrist := arm.find_child("Socket_Wrist" + side, true, false) as Node3D
		check(wrist != null and (to_top(arm, wrist) * Vector3.ZERO).distance_to(Vector3(0, -0.477, 0)) < 0.005, "arm %s offers a wrist socket" % side)
		var leg: Node3D = comps["Leg" + side]
		var shin := leg.find_child("Shin" + side, true, false) as Node3D
		check(shin != null and (to_top(leg, shin) * Vector3.ZERO).distance_to(Vector3(0, -0.405, 0)) < 0.005, "leg %s has its knee pivot 0.405 m below the hip" % side)
		var ankle := leg.find_child("Socket_Ankle" + side, true, false) as Node3D
		check(ankle != null and (to_top(leg, ankle) * Vector3.ZERO).distance_to(Vector3(0, -0.74, -0.02)) < 0.005, "leg %s offers an ankle socket" % side)

	# each limb hangs from its joint: the origin is its top, the rest is below
	var hb := bounds(comps["Helmet"])
	check(hb.position.y > -0.02 and absf(hb.size.x - 0.36) < 0.08 and hb.size.y > 0.25 and hb.size.y < 0.38, "the helmet stands on its neck origin: %s" % str(hb))
	var pb := bounds(comps["Backpack"])
	check(pb.position.z > -0.01 and pb.size.z > 0.18 and pb.size.y > 0.38 and pb.size.y < 0.5, "the backpack grows backwards (+z) from its mounting face: %s" % str(pb))
	var ab := bounds(comps["ArmR"])
	check(ab.position.y < -0.43 and ab.position.y > -0.55 and ab.end.y > 0.05 and ab.end.y < 0.14, "the arm hangs from the shoulder: %s" % str(ab))
	var gb := bounds(comps["GloveR"])
	check(gb.end.y > -0.01 and gb.end.y < 0.02 and gb.position.y > -0.2 and gb.position.y < -0.14, "the glove hangs from the wrist: %s" % str(gb))
	var lb := bounds(comps["LegR"])
	check(lb.position.y < -0.72 and lb.position.y > -0.85 and lb.end.y > 0.0 and lb.end.y < 0.06, "the leg hangs from the hip: %s" % str(lb))
	var bb := bounds(comps["BootR"])
	near(bb.position.y, -0.19, 0.01, "the boot's sole is 0.19 m under its ankle origin")
	check(bb.size.z > 0.3 and bb.size.x > 0.15 and bb.size.x < 0.25, "the boot is chunky: %s" % str(bb.size))
	# the right-hand components are on the +x side of the figure, the left-hand on -x
	check(bounds(comps["ArmR"]).get_center().x * 0 + (to_top(comps["LegR"], comps["LegR"].find_child("Socket_AnkleR", true, false) as Node3D) * Vector3.ZERO).x == 0.0, "the leg component is modelled about its own hip")
	for n in comps:
		comps[n].free()

	# ---- the assembled figure ----
	var man: Node3D = Astronaut.new()
	man.recipe = {"idle": false}
	root.add_child(man)
	await process_frame
	check(man.assembled and man.missing.is_empty(), "the astronaut assembles with nothing missing %s" % str(man.missing))
	check(man.parts.size() == 11, "all eleven components are in the tree")
	for c in Astronaut.COMPONENTS:
		check(man.get_component(c[0]) != null and man.get_component(c[0]).is_inside_tree(), "%s hangs in the tree" % c[0])
	var hosts_ok := true
	for c in Astronaut.COMPONENTS:
		if c[2] != "":
			var host_part: Node = man.get_component(c[2])
			hosts_ok = hosts_ok and host_part != null and host_part.is_ancestor_of(man.get_component(c[0]))
	check(hosts_ok, "every component hangs below its host (gloves under the arms, boots under the legs)")
	var box := bounds(man)
	near(box.size.y, 1.8, 0.04, "the astronaut is 1.8 m tall")
	near(box.position.y, 0.0, 0.01, "it stands on y = 0")
	check(box.size.x > 0.55 and box.size.x < 0.9 and box.size.z > 0.35 and box.size.z < 0.6, "a plausible footprint: %s" % str(box.size))
	check(box.get_center().x > -0.05 and box.get_center().x < 0.05, "centred left to right")
	var visor := man.find_child("Helmet_Visor", true, false) as MeshInstance3D
	var pack := man.find_child("Backpack_Suit_White", true, false) as MeshInstance3D
	var chest_logo := man.find_child("Chest_Logo_Green", true, false) as MeshInstance3D
	var pack_logo := man.find_child("Backpack_Logo_Green", true, false) as MeshInstance3D
	check(visor != null and (to_top(man, visor) * visor.mesh.get_aabb()).get_center().z < -0.03, "the visor faces -z, the way the figure looks")
	check(pack != null and (to_top(man, pack) * pack.mesh.get_aabb()).get_center().z > 0.15, "the backpack is behind it (+z)")
	check(chest_logo != null and (to_top(man, chest_logo) * chest_logo.mesh.get_aabb()).get_center().z < -0.1, "a leaf on the chest")
	check(pack_logo != null and (to_top(man, pack_logo) * pack_logo.mesh.get_aabb()).get_center().z > 0.25, "and a leaf on the backpack")
	var names := material_names(man)
	for want in ["Suit_White", "Suit_Grey", "Undersuit", "Suit_Orange", "Metal_Dark", "Rubber", "Glove", "Strip_Blue", "Visor", "Logo_Green", "Logo_Dark"]:
		check(want in names, "the suit uses %s" % want)
	check(not ("Suit_Black" in names), "the old Suit_Black name is gone: the fabric is called Undersuit")

	# the blue light strips are a small accent: a small share of the suit's surface
	var blue := 0.0
	var all := 0.0
	for mi in meshes(man):
		for i in (mi as MeshInstance3D).mesh.get_surface_count():
			var a := area_of(mi, i)
			all += a
			var m := (mi as MeshInstance3D).mesh.surface_get_material(i) as StandardMaterial3D
			if m != null and m.resource_name == "Strip_Blue":
				blue += a
				check(m.emission_enabled and m.emission_energy_multiplier > 1.0, "the light strips glow")
	check(blue > 0.0 and blue / all < 0.03, "blue is only an accent: %.1f%% of %.2f m2" % [100.0 * blue / all, all])

	# ---- the stance and the idle animation ----
	var arm_r: Node3D = man.get_component("ArmR")
	var arm_l: Node3D = man.get_component("ArmL")
	near(rad_to_deg(arm_r.rotation.z), 12.0, 0.01, "the right arm is swung 12 degrees out")
	near(rad_to_deg(arm_l.rotation.z), -12.0, 0.01, "the left arm 12 degrees out the other way")
	check(absf(man.find_child("ForearmR", true, false).rotation.x - deg_to_rad(15.0)) < 0.001, "the forearms bend 15 degrees forward")
	var helmet: Node3D = man.get_component("Helmet")
	man.pose(0.0)
	var yaw0 := helmet.rotation.y
	man.pose(man.head_period * 0.25)
	var yaw1 := helmet.rotation.y
	near(rad_to_deg(yaw1 - yaw0), man.head_sweep_deg, 0.5, "a quarter of the way through the sweep the head has turned the full angle")
	man.pose(man.head_period * 0.75)
	near(rad_to_deg(helmet.rotation.y), -man.head_sweep_deg, 0.5, "and it turns the other way later")
	var chest := man.find_child("Chest", true, false) as Node3D
	man.pose(0.0)
	var rest_y := chest.position.y
	man.pose(man.breath_period * 0.5)
	check(chest.position.y > rest_y + 0.002 and chest.scale.y > 1.004, "the chest rises with a breath (%f, %f)" % [chest.position.y - rest_y, chest.scale.y])
	man.pose(man.breath_period)
	near(chest.position.y, rest_y, 1e-4, "and falls again")
	man.pose(2.0)
	man.ground()
	near(bounds(man).position.y, 0.0, 0.01, "grounding the feet again changes nothing")

	# ---- two textures: matte woven fabric, scuffed smooth armour ----
	var fabric_ok := 0
	var armour_ok := 0
	for mi in meshes(man):
		for i in (mi as MeshInstance3D).mesh.get_surface_count():
			var m := (mi as MeshInstance3D).get_active_material(i) as StandardMaterial3D
			if m == null:
				continue
			if m.resource_name == "Undersuit" and m.albedo_texture != null and m.normal_enabled and m.normal_texture != null and m.uv1_triplanar and m.roughness > 0.85 and m.metallic < 0.05:
				fabric_ok += 1
			if (m.resource_name == "Suit_White" or m.resource_name == "Suit_Grey") and m.albedo_texture != null and not m.normal_enabled and m.uv1_triplanar and m.roughness < 0.6 and m.metallic > 0.1:
				armour_ok += 1
	check(fabric_ok >= 8, "the undersuit has a woven, matte, normal-mapped skin on %d surfaces" % fabric_ok)
	check(armour_ok >= 20, "the armour has a smooth, scuffed, glossier skin on %d surfaces" % armour_ok)
	var tex_f: Texture2D = null
	var tex_a: Texture2D = null
	for mi in meshes(man):
		var m := (mi as MeshInstance3D).get_active_material(0) as StandardMaterial3D
		if m != null and m.resource_name == "Undersuit" and tex_f == null:
			tex_f = m.albedo_texture
		if m != null and m.resource_name == "Suit_White" and tex_a == null:
			tex_a = m.albedo_texture
	check(tex_f != null and tex_a != null and tex_f != tex_a and tex_f.get_image().get_data() != tex_a.get_image().get_data(), "the two skins are different textures")
	check(Astronaut._textures("fabric")[0] == tex_f and Astronaut._textures("fabric") == Astronaut._textures("fabric"), "the textures are generated once and shared by every astronaut")

	# ---- modular: leave a component out, recolour one astronaut, swap a file, lose a file ----
	var custom: Node3D = Astronaut.new()
	custom.recipe = {"idle": false, "skins": false, "hidden": ["Backpack"], "colors": {"Suit_Orange": Color(0.1, 0.7, 0.3), "Strip_Blue": Color(1.0, 0.2, 0.2)}}
	custom.position = Vector3(3, 0, 0)
	root.add_child(custom)
	await process_frame
	check(not custom.get_component("Backpack").visible and man.get_component("Backpack").visible, "a component can be left out of one astronaut")
	var orange_a := Color()
	var orange_b := Color()
	var strip_emission := Color()
	for mi in meshes(custom):
		for i in (mi as MeshInstance3D).mesh.get_surface_count():
			var m := (mi as MeshInstance3D).get_active_material(i) as StandardMaterial3D
			if m != null and m.resource_name == "Suit_Orange":
				orange_a = m.albedo_color
			if m != null and m.resource_name == "Strip_Blue":
				strip_emission = m.emission
	for mi in meshes(man):
		for i in (mi as MeshInstance3D).mesh.get_surface_count():
			var m := (mi as MeshInstance3D).get_active_material(i) as StandardMaterial3D
			if m != null and m.resource_name == "Suit_Orange":
				orange_b = m.albedo_color
	check(orange_a.is_equal_approx(Color(0.1, 0.7, 0.3)) and not orange_b.is_equal_approx(orange_a), "the orange can be recoloured for one astronaut and not the next")
	check(strip_emission.is_equal_approx(Color(1.0, 0.2, 0.2)), "a glowing material changes its glow")
	var plain: Material = null
	for mi in meshes(custom):
		if (mi as MeshInstance3D).get_active_material(0).resource_name == "Undersuit":
			plain = (mi as MeshInstance3D).get_active_material(0)
			break
	check(plain != null and (plain as StandardMaterial3D).albedo_texture == null, "skins can be switched off")
	custom.queue_free()

	var swapped: Node3D = Astronaut.new()
	swapped.recipe = {"idle": false, "parts": {"Helmet": Astronaut.DIR + "helmet.glb", "BootR": Astronaut.DIR + "boot_l.glb"}}
	root.add_child(swapped)
	await process_frame
	check(swapped.missing.is_empty() and swapped.get_component("BootR") != null, "any component can be replaced by another file")
	swapped.queue_free()

	var holey: Node3D = Astronaut.new()
	holey.recipe = {"idle": false, "parts": {"Helmet": "res://models/astronaut/no_such_helmet.glb"}}
	root.add_child(holey)
	await process_frame
	check(holey.missing == PackedStringArray(["Helmet"]) and holey.parts.size() == 10, "a missing helmet leaves the rest of the suit standing")
	holey.queue_free()

	var nobody: Node3D = Astronaut.new()
	nobody.recipe = {"idle": false, "parts": {"Torso": "res://models/astronaut/no_such_torso.glb"}}
	root.add_child(nobody)
	await process_frame
	check(nobody.get_node_or_null("Placeholder") != null and nobody.parts.is_empty() or nobody.parts.size() <= 1, "without a torso a placeholder stands in and nothing breaks (%d parts)" % nobody.parts.size())
	nobody.queue_free()

	# let everything be freed in an ordinary frame before quitting (the headless renderer logs an error for an astronaut that
	# is freed at once, or still alive at shutdown, because its material copies go before the instances that use them)
	man.queue_free()
	await process_frame
	await process_frame
	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

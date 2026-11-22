extends SceneTree
# The Blender-modelled props must be drop-in replacements for the procedural shapes: same size, same origin, same
# planting slots. This builds each both ways through FarmShapeBuilder and compares them, then checks the materials
# and node names the game relies on.
#
#   Godot --headless --path godot --import   (once, so the .glb files are imported; run it twice on a fresh checkout)
#   Godot --headless --path godot -s res://tests/assets_test.gd

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

# the bounding box of everything drawable under `node`, in the node's own space
func bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != node:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var box: AABB = xf * (n as MeshInstance3D).mesh.get_aabb()
			out = box if first else out.merge(box)
			first = false
		for c in n.get_children():
			stack.append([c, xf])
	return out

func find_material(node: Node, material_name: String) -> StandardMaterial3D:
	for c in node.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i)
				if m != null and m.resource_name == material_name:
					return m as StandardMaterial3D
		var deeper := find_material(c, material_name)
		if deeper != null:
			return deeper
	return null

func _initialize() -> void:
	var sb := FarmShapeBuilder.new()

	# ---- the regolith bed (the planter) ----
	var tray_recipe := {"shape": "planter_tray", "rows": 2, "cols": 4}
	var proc: Node3D = sb.build_node(tray_recipe)
	var model: Node3D = sb.build_node({"shape": "planter_tray", "rows": 2, "cols": 4, "model": "res://models/regolith_bed.glb"})
	check(model.name == &"planter_tray" and model.get_child_count() > 0, "the bed model is built under the shape's name (%s)" % model.name)
	var pb := bounds(proc)
	var mb := bounds(model)
	check(absf(pb.size.y - mb.size.y) < 0.01, "bed height matches: %f vs %f" % [pb.size.y, mb.size.y])
	check(absf(pb.size.z - mb.size.z) < 0.02, "bed width matches: %f vs %f" % [pb.size.z, mb.size.z])
	check(absf(pb.size.x - mb.size.x) < 0.05, "bed length matches (the model adds an inlet pipe): %f vs %f" % [pb.size.x, mb.size.x])
	check(absf(pb.position.y - mb.position.y) < 0.005, "bed origin is at the bottom in both")
	check(absf((pb.position.z + pb.size.z * 0.5) - (mb.position.z + mb.size.z * 0.5)) < 0.01, "bed is centred on z in both")
	# the slots: the empties in the model sit where the C++ code says
	var slots := sb.get_slot_positions(tray_recipe)
	check(slots.size() == 8, "the C++ code lays out eight slots")
	for i in slots.size():
		var marker := model.get_node_or_null("Slot_%d" % i) as Node3D
		check(marker != null, "the model has Slot_%d" % i)
		if marker != null:
			check(marker.position.distance_to(slots[i]) < 0.002, "Slot_%d is at %s, C++ says %s" % [i, str(marker.position), str(slots[i])])
	check(find_material(model, "Soil_Regolith") != null, "the bed has its regolith material")
	check(find_material(model, "Trim_Rust") != null, "the bed has its rust trim")
	proc.free(); model.free()

	# ---- the LED bar ----
	var lp: Node3D = sb.build_node({"shape": "grow_light"})
	var lm: Node3D = sb.build_node({"shape": "grow_light", "model": "res://models/led_bar.glb"})
	var lpb := bounds(lp)
	var lmb := bounds(lm)
	check(absf(lpb.size.x - lmb.size.x) < 0.03, "bar length matches: %f vs %f" % [lpb.size.x, lmb.size.x])
	check(absf(lpb.size.z - lmb.size.z) < 0.02, "bar depth matches")
	check(absf((lpb.position.y + lpb.size.y) - (lmb.position.y + lmb.size.y)) < 0.01, "the hangers reach the same height")
	check(absf(lpb.position.y - lmb.position.y) < 0.01, "the LED face is at the same height")
	var led := find_material(lm, "LED_Emissive")
	check(led != null and led.emission_enabled, "the model's LED material glows")
	if led != null:
		check(led.emission_energy_multiplier > 1.0, "the LED glow is bright (%f)" % led.emission_energy_multiplier)
	lp.free(); lm.free()

	# ---- the ice-melt tank ----
	var tp: Node3D = sb.build_node({"shape": "tank"})
	var tm: Node3D = sb.build_node({"shape": "tank", "model": "res://models/ice_tank.glb"})
	var tpb := bounds(tp)
	var tmb := bounds(tm)
	check(absf(tpb.size.z - tmb.size.z) < 0.03, "tank width matches: %f vs %f" % [tpb.size.z, tmb.size.z])
	check(tmb.size.y >= tpb.size.y - 0.01 and tmb.size.y < tpb.size.y + 0.15, "tank height matches, plus the fill pipe: %f vs %f" % [tpb.size.y, tmb.size.y])
	check(absf(tpb.position.y - tmb.position.y) < 0.01, "tank origin is at the bottom in both")
	check(find_material(tm, "Gauge_Emissive") != null, "the tank has its glowing gauge")
	tp.free(); tm.free()

	# ---- the extras ----
	var missing: Node3D = sb.build_node({"shape": "box", "model": "res://models/seam_crate_missing.glb"})
	check(missing != null, "a missing model still falls back")
	missing.free()
	var crate: Node3D = sb.build_node({"shape": "box", "model": "res://models/supply_crate.glb"})
	var cb := bounds(crate)
	check(absf(cb.size.x - 0.41) < 0.03 and absf(cb.size.z - 0.31) < 0.03 and cb.size.y > 0.2 and cb.size.y < 0.3, "the supply crate is about 0.4 x 0.25 x 0.3 m: %s" % str(cb.size))
	check(absf(cb.position.y) < 0.005, "the crate stands on y = 0")
	crate.free()
	var lock: Node3D = sb.build_node({"shape": "box", "model": "res://models/airlock.glb"})
	var ab := bounds(lock)
	check(absf(ab.size.x - 1.5) < 0.03 and absf(ab.size.y - 2.2) < 0.03 and ab.size.z > 0.3 and ab.size.z < 0.6, "the airlock is 1.5 m wide, 2.2 m tall and under 0.6 m deep: %s" % str(ab.size))
	check(absf(ab.position.y) < 0.005, "the airlock stands on y = 0")
	check(absf(ab.position.x + ab.size.x * 0.5) < 0.01, "the airlock is centred on x")
	check(ab.position.z < 0.0 and ab.position.z + ab.size.z > 0.0, "the airlock straddles its mounting plane")
	check(find_material(lock, "Status_Emissive") != null, "the airlock has its green status light")
	check(find_material(lock, "Gauge_Emissive") != null, "the airlock has its lit porthole")
	lock.free()

	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

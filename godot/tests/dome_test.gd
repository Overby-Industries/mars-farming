extends SceneTree
# Drives the dome scene the way a player would, without a window: pick a slot, sow a potato, ride out a dust storm,
# grow the crop to harvest, and check that the weather, the HUD and the C++ simulation agree.
#
#   Godot --headless --path godot -s res://tests/dome_test.gd
#
# The numbers asserted here are the placeholder design values in dome.gd and docs/DESIGN.md (650 umol/m2/s sun, screens
# open, 360 W of solar power); when those are tuned, update this file with them.

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

func plant_nodes(scene: Node) -> int:
	var n := 0
	for c in scene.get_children():
		if c is Node3D and c.get_child_count() == 1 and c.get_child(0) is MeshInstance3D and (c.get_child(0) as MeshInstance3D).name == "Plant":
			n += 1
	return n

# every drawable box under `node`, in world space
func world_boxes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null and (node as MeshInstance3D).is_visible_in_tree():
		out.append((node as MeshInstance3D).global_transform * (node as MeshInstance3D).mesh.get_aabb())
	for c in node.get_children():
		out.append_array(world_boxes(c))
	return out

func flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z).normalized()

# Only the first dome gets the suit's textured skins: the headless renderer logs an error when one astronaut with skins is freed
# while another is alive, and this test frees several domes.
func make_dome(skins := false) -> Node3D:
	var packed: PackedScene = load("res://scenes/dome.tscn")
	var scene: Node3D = packed.instantiate()
	scene.astronaut_recipe = {"skins": skins}
	root.add_child(scene)
	scene.set_speed(0.0)               # the test advances time itself (paused before the first frame can move the clock)
	scene._next_storm_sol = 1000000    # no random storms unless a test asks for one
	await process_frame
	return scene

func advance_to_clock(scene: Node3D, hour: float) -> void:
	var now: float = scene.bay.get_status()["clock_h"]
	scene.advance_world(fposmod(hour - now, 24.0))

# Sow a potato in bed 0, slot 0, keep it watered, and return its age in days when it is ready (-1 if it never is).
func days_to_ready(scene: Node3D, limit_days: int) -> float:
	scene.crop_key = "potato"
	scene.select_slot(0, 0)
	scene.action_plant()
	scene.bay.set_setting("auto_irrigate", true)
	scene.bay.set_setting("nutrient_stock", 40.0)
	scene.bay.feed(0, 3.0)
	for h in limit_days * 24:
		scene.advance_world(1.0)
		var p: Dictionary = scene.bay.get_plant(0, 0)
		if p["stage"] == FarmBay.STAGE_READY:
			return p["age_days"]
	return -1.0

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	root.size = Vector2i(1600, 900)      # headless windows are tiny: lay the HUD and the camera out as they are in the game
	var scene: Node3D = await make_dome(true)
	var bay: FarmBay = scene.bay

	# ---- the dome at the start ----
	check(bay.get_bed_count() == 4, "four beds")
	check(bay.get_bed_info(0)["slots"] == 8, "eight slots per bed")
	check(plant_nodes(scene) == 0, "no plants at the start")
	check(scene.crop_key == "potato", "the crop picker starts on the staple, potato")
	check(bay.get_setting("sun_peak_ppfd") == 650.0, "the sun is 650 umol/m2/s at noon through the glazing")
	check(bay.get_setting("power_budget_w") == 360.0, "the solar array gives 360 W on a clear day")
	check(bay.get_setting("shade") == 0.0, "the shade screens start open")
	check(not scene.storm_active and absf(scene.tau - 0.5) < 1e-9, "a clear sky at the start")
	check(not scene.action_plant(), "no selection, no planting")

	# ---- the crew astronaut ----
	var man: Node3D = scene.astronaut
	check(man != null and man.is_inside_tree() and man.get_parent() == scene and man.name == "Astronaut", "the astronaut is in the scene tree")
	check(man.assembled and man.missing.is_empty() and man.parts.size() == 11, "assembled from all eleven suit components")
	check(man.global_position.is_equal_approx(scene.ASTRONAUT_POS), "it stands where the scene puts it: %s" % str(man.global_position))
	check(man.is_processing(), "its idle animation runs")
	check(man.find_children("*", "CollisionObject3D", true, false).is_empty(), "it has no collision bodies, so clicks go through to the beds")

	var man_boxes := world_boxes(man)
	var whole := AABB()
	for i in man_boxes.size():
		whole = man_boxes[i] if i == 0 else whole.merge(man_boxes[i])
	check(absf(whole.size.y - 1.8) < 0.05, "it is 1.8 m tall: %.3f m" % whole.size.y)
	check(absf(whole.position.y) < 0.01, "its boots are on the floor")
	check(whole.end.y < 2.5, "and it fits under the grow lights' hangers' ceiling")

	# it looks at the crops: toward the dome wall beyond the nearest bed, within 50 degrees
	var fwd: Vector3 = flat(-man.global_transform.basis.z)
	var best := -1.0
	for centre in scene.BED_CENTERS:
		best = maxf(best, fwd.dot(flat(centre - man.global_position)))
	check(best > cos(deg_to_rad(50.0)), "it faces the beds: its heading is %.0f degrees off the nearest" % rad_to_deg(acos(clampf(best, -1.0, 1.0))))
	check(fwd.z < -0.9, "and the dome wall beyond them (heading z = %.2f)" % fwd.z)
	check(man.global_position.length() < scene.DOME_R - 1.5, "it is well inside the dome (%.1f m from the middle of a %.0f m dome)" % [man.global_position.length(), scene.DOME_R])

	# clear of the beds, benches, crates, tank and lights: no box of the suit touches a box of the furniture
	var furniture: Array = []
	for c in scene.get_tree().get_nodes_in_group("furniture"):
		if scene.is_ancestor_of(c) and c != man:
			furniture.append_array(world_boxes(c))
	check(furniture.size() > 60, "there are furniture boxes to keep clear of (%d)" % furniture.size())
	var touching := 0
	for b in furniture:
		for m in man_boxes:
			if (b as AABB).intersects(m):
				touching += 1
	check(touching == 0, "it intersects no bed, bench, crate, tank, light or hanger (%d overlaps)" % touching)
	var crowded := 0
	for b in furniture:
		if (b as AABB).intersects(whole.grow(0.25)):
			crowded += 1
	check(crowded == 0, "and there is a quarter of a metre of walkway around it (%d boxes closer)" % crowded)

	# it does not hide a slot in the view the game starts in, and the slots and the astronaut clear the HUD panels
	await process_frame
	await process_frame
	var cam: Camera3D = scene._cam
	var cam_pos := cam.global_position
	var panels: Array = []
	for pc in scene.find_children("*", "PanelContainer", true, false):
		if pc.get_parent() is MarginContainer and pc.get_parent().name != "CrewCaption" and (pc as Control).is_visible_in_tree():      # the HUD's three panels, not a popup's frame
			panels.append((pc as Control).get_global_rect().grow(6.0))
	check(panels.size() == 4, "four HUD panels (left, right, bottom, and the colony bar along the top): %s" % str(panels))
	var view := Rect2(Vector2.ZERO, Vector2(1600, 900))
	var hidden := 0
	var under_hud := 0
	var off_screen := 0
	for bi in scene.BED_CENTERS.size():
		for si in scene._slot_offsets.size():
			var at: Vector3 = scene.BED_CENTERS[bi] + scene._slot_offsets[si] + Vector3(0, 0.12, 0)
			for m in man_boxes:
				if (m as AABB).intersects_segment(cam_pos, at) != null:
					hidden += 1
					break
			var px := cam.unproject_position(at)
			if not view.grow(-8.0).has_point(px):
				off_screen += 1
			for r in panels:
				if (r as Rect2).has_point(px):
					under_hud += 1
					break
	check(hidden == 0, "it hides none of the 32 slots from the camera (%d hidden)" % hidden)
	check(off_screen == 0, "every slot is on screen in the start view (%d off)" % off_screen)
	check(under_hud == 0, "and no slot is under a HUD panel (%d under)" % under_hud)
	for point in [Vector3(0, 1.65, 0), Vector3(0, 1.25, 0), Vector3(0, 0.5, 0)]:
		var px := cam.unproject_position(man.global_position + point)
		var clear := view.grow(-4.0).has_point(px)
		for r in panels:
			if (r as Rect2).has_point(px):
				clear = false
		check(clear, "the astronaut's %s is in view and clear of the HUD (%s)" % [str(point), str(px)])

	# clicking works with the astronaut standing there: pick a slot of each bed through the screen
	await physics_frame
	await physics_frame
	for bi in scene.BED_CENTERS.size():
		var slot := 5
		var at: Vector3 = scene.BED_CENTERS[bi] + scene._slot_offsets[slot] + Vector3(0, 0.22, 0)
		scene._pick(cam.unproject_position(at))
		check(scene.selected == Vector2i(bi, slot), "a click on bed %d slot %d picks it (picked %s)" % [bi + 1, slot + 1, str(scene.selected)])
	scene.select_slot(-1, -1)

	# ---- the LED bars hang high enough to see and pick every slot ----
	var light_boxes: Array = []
	var lowest := INF
	var bars := 0
	for c in scene.get_children():
		if c is Node3D and str(c.name).begins_with("GrowLight"):
			bars += 1
			for b in world_boxes(c):
				light_boxes.append(b)
				lowest = minf(lowest, (b as AABB).position.y)
	check(bars == 4, "four LED bars")
	var soil_top: float = scene.BED_CENTERS[0].y + 0.17
	check(lowest - soil_top > 1.0, "the lowest bar hangs %.2f m above the soil: over a metre clear of even a full-grown tomato" % (lowest - soil_top))
	# from the view the game starts in no bar stands between the camera and a slot; from steep or sideways orbit views a bar that
	# would is faded to a ghost, so every slot can be seen and picked from any angle
	check(scene.fade_blocking_lights(1.0) == 0, "no bar stands between the start view's camera and a slot")
	var start_view := [scene._yaw, scene._pitch, scene._dist]
	var poses := 0
	var poses_with_a_bar_in_the_way := 0
	var solid_blockers := 0
	for dyaw in [-0.8, -0.4, 0.0, 0.4, 0.8]:
		for pitch in [-0.3, -0.5, -0.8, -1.1]:
			scene._yaw = start_view[0] + dyaw
			scene._pitch = pitch
			scene._apply_camera()
			poses += 1
			if scene.fade_blocking_lights(10.0) > 0:
				poses_with_a_bar_in_the_way += 1
			for bar in scene._bars:
				if bar["blocking"] and bar["fade"] < 0.6:
					solid_blockers += 1
	scene._yaw = start_view[0]
	scene._pitch = start_view[1]
	scene._dist = start_view[2]
	scene._apply_camera()
	scene.fade_blocking_lights(10.0)
	check(poses_with_a_bar_in_the_way > 0, "(some of the %d orbit poses do have a bar in the way: %d)" % [poses, poses_with_a_bar_in_the_way])
	check(solid_blockers == 0, "and in every one of them the bar in the way is faded (%d solid)" % solid_blockers)
	var back: bool = true
	for bar in scene._bars:
		back = back and float(bar["fade"]) == 0.0
	check(back, "back in the start view every bar is solid again")

	# ---- a clear noon ----
	advance_to_clock(scene, 12.0)
	var clear: Dictionary = bay.get_status()
	check(absf(clear["sun_ppfd"] - 650.0) < 0.5, "clear noon, screens open: %.1f umol/m2/s" % clear["sun_ppfd"])
	bay.set_setting("shade", 0.5)
	check(absf(bay.get_status()["sun_ppfd"] - 325.0) < 0.5, "screens half shut halve the noon sun")
	bay.set_setting("shade", 0.0)
	scene._update_sky()
	var clear_light: float = scene._sun.light_energy
	check(clear_light > 1.2, "the sun lamp is bright at a clear noon (%.2f)" % clear_light)
	check(scene._sky.sky_top_color.is_equal_approx(scene.COL_SKY_TOP), "the sky is butterscotch when clear")

	# ---- a dust storm ----
	scene.start_storm(4.0, 48.0)
	check(scene.storm_active, "the storm is on")
	scene.advance_world(24.0)          # the dust rises over a day, back at noon
	check(absf(scene.tau - 4.0) < 1e-6, "the dust reached its peak optical depth of 4.0 (%f)" % scene.tau)
	var trans := exp(-0.5 * 3.5)
	var storm: Dictionary = bay.get_status()
	check(absf(storm["sun_ppfd"] - 650.0 * trans) < 0.5, "storm noon: %.1f umol/m2/s, the dust passes %.0f%%" % [storm["sun_ppfd"], trans * 100.0])
	check(storm["sun_ppfd"] < clear["sun_ppfd"] * 0.25, "a storm cuts the noon sun to under a quarter")
	check(absf(storm["power_budget_w"] - 360.0 * trans) < 0.5, "the solar power falls with the dust: %.1f W" % storm["power_budget_w"])
	scene._update_sky()
	check(scene._sun.light_energy < clear_light * 0.5, "the sun lamp dims in the storm (%.2f vs %.2f)" % [scene._sun.light_energy, clear_light])
	check(scene._sky.sky_top_color.is_equal_approx(scene.COL_STORM_TOP), "the sky turns the colour of dust")
	scene._refresh_all()
	check((scene._storm_label as Label).text.begins_with("DUST STORM"), "the HUD warns of the storm")

	# the LEDs run on the same power: at 18:00 the four beds ask for more than the dust-dimmed array gives
	advance_to_clock(scene, 19.0)
	var night: Dictionary = bay.get_status()
	check(night["lights_on"] and night["power_demand_w"] > night["power_budget_w"], "in the storm the LEDs want more power than the array gives (%.0f W of %.0f W)" % [night["power_demand_w"], night["power_budget_w"]])
	check(bay.get_bed_info(0)["ppfd"] < 100.0, "so a bed gets only a little LED light (%.0f umol/m2/s)" % bay.get_bed_info(0)["ppfd"])

	# the storm blows over
	scene.advance_world(48.0 + 60.0)
	check(not scene.storm_active, "the storm has passed")
	check(absf(scene.tau - 0.5) < 1e-9, "the sky is clear again")
	check(bay.get_status()["power_budget_w"] == 360.0, "the solar array is back to 360 W")
	scene._refresh_all()
	check((scene._storm_label as Label).text == "Sky clear", "the HUD says the sky is clear")

	# ---- storms come on their own ----
	var rain: Node3D = await make_dome()
	rain._next_storm_sol = 2
	rain.advance_world(20.0)           # 6:00 to 02:00: past midnight, sol 2 has begun
	check(rain.storm_active, "a storm arrives on the sol it was scheduled for")
	check(rain._next_storm_sol >= 10, "the next one is scheduled at least eight sols later (sol %d)" % rain._next_storm_sol)
	rain.queue_free()

	# ---- sow, water, feed ----
	scene.select_slot(0, 0)
	check(scene.selected == Vector2i(0, 0), "slot selected")
	check(scene.action_plant(), "sow a potato")
	check(bay.get_plant(0, 0)["species"] == "potato", "the bay holds a potato")
	check(plant_nodes(scene) == 1, "a seed mound appears")
	check(not scene.action_plant(), "an occupied slot cannot be sown again")
	scene.crop_key = "radish"
	scene.select_slot(1, 0)
	check(scene.action_sow_bed() == 8, "sow eight radishes")
	check(plant_nodes(scene) == 9, "nine plants stand in the dome")
	var before: float = bay.get_status()["tank_l"]
	check(scene.action_water() > 0.0 or bay.get_bed_info(1)["water_l"] >= bay.get_bed_info(1)["water_capacity_l"] - 0.01, "watering moves ice-melt water or the bed is full")
	check(bay.get_status()["tank_l"] <= before, "the tank did not gain water")

	# ---- grow a potato: a storm costs time, not the crop ----
	var calm: Node3D = await make_dome()
	var calm_days := days_to_ready(calm, 240)
	var windy: Node3D = await make_dome()
	windy.start_storm(4.0, 96.0)       # a week of dust right after sowing
	var windy_days := days_to_ready(windy, 240)
	print("potato: ready after %.1f days under a clear sky, %.1f days with a 7-day storm at the start" % [calm_days, windy_days])
	check(calm_days > 0.0, "a potato ripens under a clear sky within 240 days (%.1f)" % calm_days)
	check(windy_days > calm_days, "a storm slows the crop (%.1f vs %.1f days)" % [windy_days, calm_days])
	check(windy_days > 0.0 and windy_days < calm_days + 30.0, "but it still ripens, a few weeks late at worst (%.1f days)" % windy_days)

	# ---- harvest ----
	calm.select_slot(0, 0)
	check(calm.action_harvest()["ok"], "harvest the potato")
	check(calm.bay.get_plant(0, 0)["empty"], "the slot is empty again")
	check(calm.bay.get_status()["harvested_kg"] > 0.0, "the harvest is counted")
	await process_frame   # queue_free() takes effect at the end of the frame
	check(plant_nodes(calm) == 0, "the harvested plant's model is gone")
	calm._refresh_all()
	check((calm._harvest_label as Label).text.contains("Harvested"), "the harvest line shows")
	check((calm._status_label as Label).text.begins_with("Sol "), "the status panel shows the sol")

	# ---- clearing ----
	scene.select_slot(1, 3)
	check(scene.action_remove(), "clear a radish")
	check(not scene.action_remove(), "an empty slot cannot be cleared")

	# let every dome be freed in an ordinary frame before quitting (the headless renderer logs an error for the suit's
	# material copies when a scene with an astronaut is still alive at shutdown)
	for dome in [scene, calm, windy]:
		dome.queue_free()
	await process_frame
	await process_frame
	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

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

func make_dome() -> Node3D:
	var packed: PackedScene = load("res://scenes/dome.tscn")
	var scene: Node3D = packed.instantiate()
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
	var scene: Node3D = await make_dome()
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

	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

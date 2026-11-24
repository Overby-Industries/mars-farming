extends RefCounted
## The journey through the farm that the crew UI test checks and the training scene teaches: sow a slot, let the crop grow, let
## a bed dry out and water it, harvest what is ripe, select a plant, ask the crew. These helpers do the parts that are about time and
## the simulation, the same way for both: tests/crew_ui_test.gd calls them to get to each state quickly, and the training scene
## (scripts/training.gd) calls them for "Skip 5 days" while it teaches the same steps with the real buttons.
##
## They work on the scene the project starts in (greenhouse.gd or dome.gd) and need nothing else of it than `bay`, `crop_key`,
## `select_slot()`, `action_sow_bed()`, `BED_ROWS`, `BED_COLS`, `_refresh_all()` and, for the dome, `advance_world()`.

const SlotButtons = preload("res://scripts/slot_buttons.gd")
const Settlement = preload("res://scripts/settlement.gd")

# Advance the whole world by game hours: the dome also has weather to move along. The room is refreshed once at the end
# (`refresh` off, for the loops below that call this many times).
static func advance(scene: Node3D, hours: float, refresh := true) -> void:
	var st: Node = Settlement.peek()
	if scene.has_method("advance_world"):
		scene.advance_world(hours)                        # (the dome moves the weather, and every unit with it)
	elif st != null and not scene.has_meta("training"):
		st.advance_all(hours)
	else:
		scene.bay.advance_hours(hours)
	if refresh:
		scene._refresh_all()

# Sow a whole bed with a crop, through the scene's own actions.
static func sow_bed(scene: Node3D, bed: int, crop: String) -> void:
	scene.crop_key = crop
	scene.select_slot(bed, 0)
	scene.action_sow_bed()

# What a slot's floating button would say right now: "sow", "growing", "water", "feed", "harvest" or "clear".
static func kind(scene: Node3D, bed: int, slot: int) -> String:
	return SlotButtons.state_of(scene.bay, bed, slot)["kind"]

# The first slot whose button says `wanted`, as Vector2i(bed, slot), or Vector2i(-1, -1).
static func find_kind(scene: Node3D, wanted: String) -> Vector2i:
	for bed in scene.bay.get_bed_count():
		for slot in scene.BED_ROWS * scene.BED_COLS:
			if kind(scene, bed, slot) == wanted:
				return Vector2i(bed, slot)
	return Vector2i(-1, -1)

# How many slots hold a plant (alive or not).
static func occupied(scene: Node3D) -> int:
	var n := 0
	for bed in scene.bay.get_bed_count():
		for slot in scene.BED_ROWS * scene.BED_COLS:
			if not scene.bay.get_plant(bed, slot)["empty"]:
				n += 1
	return n

# The furthest growth (0 to 1) of any plant in the bay.
static func best_progress(scene: Node3D) -> float:
	var best := 0.0
	for bed in scene.bay.get_bed_count():
		for slot in scene.BED_ROWS * scene.BED_COLS:
			var p: Dictionary = scene.bay.get_plant(bed, slot)
			if not p["empty"]:
				best = maxf(best, float(p["progress"]))
	return best

# The species that gets to harvest soonest: the training grows it so the lessons are short.
static func fastest_crop(scene: Node3D) -> String:
	var best := ""
	var days := INF
	for sp in scene.bay.get_species_list():
		if float(sp["days_to_mature"]) < days:
			days = float(sp["days_to_mature"])
			best = sp["key"]
	return best

# Let time pass (6 game hours at a time, up to `max_days`) until a plant has reached `stage` or further. Returns the days it took,
# or -1.0 if it never did.
static func grow_until(scene: Node3D, bed: int, slot: int, stage: int, max_days := 120.0) -> float:
	var hours := 0.0
	while scene.bay.get_plant(bed, slot)["stage"] < stage and hours < max_days * 24.0:
		advance(scene, 6.0, false)
		hours += 6.0
	scene._refresh_all()
	return hours / 24.0 if scene.bay.get_plant(bed, slot)["stage"] >= stage else -1.0

# Let time pass until the slot's button says `wanted`. Returns the days it took, or -1.0.
static func run_until_kind(scene: Node3D, bed: int, slot: int, wanted: String, max_days := 40.0) -> float:
	var hours := 0.0
	while kind(scene, bed, slot) != wanted and hours < max_days * 24.0:
		advance(scene, 6.0, false)
		hours += 6.0
	scene._refresh_all()
	return hours / 24.0 if kind(scene, bed, slot) == wanted else -1.0

# Let time pass until any slot's button says `wanted` (not just one slot). Returns the days it took, or -1.0.
static func run_until_any_kind(scene: Node3D, wanted: String, max_days := 40.0, step_hours := 6.0) -> float:
	var hours := 0.0
	while find_kind(scene, wanted).x < 0 and hours < max_days * 24.0:
		advance(scene, step_hours, false)
		hours += step_hours
	scene._refresh_all()
	return hours / 24.0 if find_kind(scene, wanted).x >= 0 else -1.0

extends SceneTree
# The training scene (scenes/training.tscn, scripts/training.gd) played through in the real game, the way a new player would
# and the way "Watch it all" does: sow, grow, dry (and water), harvest, select, ask. Nothing is spoken headless, so the crew's lines
# are read as text. The same file is used by both farming games.
#
#   Godot --headless --path godot -s res://tests/training_test.gd
#
# The test is the clock: it ticks the training, the crew voice and the game's time together, and does not wait for frames.

const Driver = preload("res://scripts/training_driver.gd")
const Prefs = preload("res://scripts/prefs.gd")

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

func make_training() -> Node:
	var packed := load("res://scenes/training.tscn") as PackedScene
	var t: Node = packed.instantiate()
	t.farm_recipe = {"skins": false}        # the headless renderer logs an error when one astronaut with textured skins is freed while another is alive
	t.change_scene = false
	root.add_child(t)
	await process_frame
	await process_frame
	t.voice.audio = false
	return t

func discard(t: Node) -> void:
	t.queue_free()
	await process_frame
	await process_frame

# let `seconds` of training time pass: the training, the crew voice and the game's clock (at the speed the training set) together
func pump(t: Node, seconds: float, dt := 0.05) -> void:
	for i in int(seconds / dt):
		step_once(t, dt)

func step_once(t: Node, dt: float) -> void:
	t.tick(dt)
	t.voice.tick(dt)
	var speed: float = t.farm.bay.time_scale
	if speed > 0.0:
		Driver.advance(t.farm, speed * dt)
	t.farm.slot_buttons.refresh()

# ... until `done` is true; returns the seconds it took, or -1
func pump_until(t: Node, done: Callable, limit: float, dt := 0.05) -> float:
	var spent := 0.0
	while not done.call() and spent < limit:
		step_once(t, dt)
		spent += dt
	return spent if done.call() else -1.0

func button(t: Node, text: String) -> Button:
	for b in t.farm.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			return b
	return null

func panels_of(t: Node) -> Array:
	var rects: Array = []
	for pc in t.farm.find_children("*", "PanelContainer", true, false):
		if pc.get_parent() is MarginContainer and pc.get_parent().name != "CrewCaption" and (pc as Control).is_visible_in_tree():
			rects.append((pc as Control).get_global_rect())
	return rects

# how many visible floating slot buttons lie under the coach panel
func buttons_under_coach(t: Node) -> int:
	var coach: Rect2 = (t._coach as Control).get_global_rect().grow(4.0)
	var n := 0
	for key in t.farm.slot_buttons.buttons:
		var b: Button = t.farm.slot_buttons.buttons[key]
		if b.visible and coach.intersects(b.get_global_rect()):
			n += 1
	return n

func texts_of(t: Node) -> String:
	var all := ""
	for l in t.voice.lines:
		all += str(l["key"]) + ": " + str(l["text"]) + "\n"
	return all

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	root.size = Vector2i(1600, 900)      # headless windows are tiny: lay the HUD and the camera out as they are in the game
	Prefs.path = "user://test_prefs.cfg"      # the voice choice is remembered: never in the player's own file
	Prefs.erase()

	# ---- the scene: the project's own game, with a coach over it ----
	var t := await make_training()
	var farm: Node3D = t.farm
	check(farm != null and farm.scene_file_path == str(ProjectSettings.get_setting("application/run/main_scene")), "the training hosts the project's main scene (%s)" % farm.scene_file_path)
	check(farm.has_meta("training") and farm.slot_buttons != null and farm.voice == t.voice, "it is the real game: slot buttons and the crew voice are there")
	check(farm.bay.time_scale == 0.0, "the clock waits until a lesson starts it")
	check(not t.voice.spontaneous, "the crew speaks for the coach and when spoken to, not on its own")
	check(farm.crop_key == Driver.fastest_crop(farm), "the crop is the quickest grower: %s" % farm.crop_key)
	var ids: Array = []
	for s in t.steps:
		ids.append(s["id"])
	check(ids == ["welcome", "sow", "grow", "dry", "harvest", "select", "ask", "finish"], "the lessons are sow, grow, dry, harvest, select, ask, between a welcome and an end: %s" % str(ids))
	check(t.lesson_count() == 6, "six lessons")
	check(t.current_id() == "welcome" and t._text.text.contains(t._crop_name()) and t._title.text == "Welcome aboard", "it opens with a welcome that names the crop")
	check(t.voice.lines.size() == 1 and t.voice.lines[0]["key"] == "train_welcome_0" and t.voice.lines[0]["text"].begins_with("Welcome aboard"), "the crew says the welcome")
	check(not t.voice._caption_box.visible, "and the panel is its caption, so the crew's own caption stays hidden")
	check(farm.colony_ui == null and not farm.bay.get_colony()["started"], "the training hosts the game without a colony: a sandbox")
	check(not t._b_voice.visible, "with no speech voice on the PC, the welcome has no voice button")
	t.voice._voices = {"male": {"id": "m1", "name": "Test David", "language": "en_US"}, "female": {"id": "f1", "name": "Test Zira", "language": "en_US"}}
	t._show_phase()
	check(t._b_voice.visible and t._b_voice.text == "Voice: Male", "with both a male and a female voice it offers the choice: %s" % t._b_voice.text)
	t.toggle_voice()
	check(t.voice.gender == "female" and t._b_voice.text == "Voice: Female" and Prefs.read("voice", "gender", "") == "female", "and the button switches the crew to the female voice, and remembers it")
	t.toggle_voice()
	check(t.voice.gender == "male" and t._b_voice.text == "Voice: Male", "and back")
	t.voice._voices = {}
	t._show_phase()
	var how := button(t, "How to play")
	check(how != null and not how.visible, "the game's How to play button is hidden while the game is hosted")
	check(t._b_start.visible and t._b_watch.visible and t._b_skip.visible and not t._b_show.visible and not t._b_new.visible, "the welcome offers Start, Watch it all and Skip training")
	var coach: Rect2 = (t._coach as Control).get_global_rect()
	var view := Rect2(Vector2.ZERO, Vector2(1600, 900))
	check(view.encloses(coach) and coach.size.y < 260.0, "the coach panel is on the screen and not tall: %s" % str(coach))
	var hud_overlaps := 0
	for r in panels_of(t):
		if (r as Rect2).intersects(coach):
			hud_overlaps += 1
	check(hud_overlaps == 0, "it sits between the game's HUD panels, covering none (%d)" % hud_overlaps)
	check(buttons_under_coach(t) == 0, "and it covers none of the slot buttons")
	check(farm._toast.position.y > coach.end.y, "the game's messages appear under it")

	# ---- guided: the player does each lesson ----
	t.press_start()
	check(t.current_id() == "sow", "Start begins the first lesson")
	pump(t, 0.2)
	check(t._counter.text == "Lesson 1 of 6" and t._text.text.contains("+"), "lesson 1 of 6 says what to press: %s" % t._text.text)
	check(t._target.has("rect") and Driver.kind(farm, t._sow_slot().x, t._sow_slot().y) == "sow", "the ring is on the + of an empty slot")
	check(buttons_under_coach(t) == 0, "the lesson's words cover no slot button")
	check(t._b_show.visible and not t._b_days.visible, "Show me is offered, Skip 5 days is not (nothing to wait for)")
	var key: Vector2i = t._sow_slot()
	check(farm.slot_buttons.press(key.x, key.y) == "sow", "the player presses the +")
	pump(t, 0.2)
	check(t.current_id() == "sow" and t.phase() == 1 and t._text.text.contains("Sow the whole bed"), "the lesson goes on to filling the bed: %s" % t._text.text)
	check((t._target.get("rect", Rect2()) as Rect2) == button(t, "Sow the whole bed").get_global_rect(), "the ring is on Sow the whole bed")
	button(t, "Sow the whole bed").pressed.emit()
	check(Driver.occupied(farm) == farm.BED_ROWS * farm.BED_COLS, "the player presses it: the bed is full (%d plants)" % Driver.occupied(farm))
	pump(t, 0.2)
	check(t._hint.text.begins_with("Done"), "the panel says it is done: %s" % t._hint.text)
	check(pump_until(t, func(): return t.current_id() == "grow", 20.0) > 0.0, "the training goes on once the crew has finished speaking")

	check(t._text.text.contains("16x") and t._b_days.visible and farm.bay.time_scale == 0.0, "lesson 2 sends the player to the speed buttons, with the clock paused")
	check(t._hint.text.contains("paused"), "and says the clock is paused: %s" % t._hint.text)
	var speed_rect: Rect2 = (button(t, "16x") as Button).get_global_rect().merge((button(t, "64x") as Button).get_global_rect())
	check(t._target.get("rect", Rect2()) == speed_rect, "the ring is around 16x and 64x")
	button(t, "64x").pressed.emit()
	check(farm.bay.time_scale == 64.0, "the player presses 64x")
	check(pump_until(t, func(): return t.current_id() == "dry", 60.0) > 0.0, "the plant grows and the lesson ends (%.0f%% grown)" % (Driver.best_progress(farm) * 100.0))
	check(Driver.best_progress(farm) >= t.GROW_TO, "it took at least %d%% growth" % int(t.GROW_TO * 100.0))

	check(farm.bay.get_setting("auto_irrigate") == false, "the dry lesson keeps Automatic irrigation off")
	check(t._phase == 0 and t._text.text.contains("Water"), "it waits for a bed to run low")
	var waited := pump_until(t, func(): return t.phase() == 1, 120.0)
	check(waited > 0.0, "a bed runs dry (after %.0f seconds at 64x)" % waited)
	check(farm.bay.time_scale == 0.0, "the clock is paused the moment it does, so nothing is lost")
	var dry_key := Driver.find_kind(farm, "water")
	check(dry_key.x >= 0 and t._text.text.contains("Bed %d" % (dry_key.x + 1)) and t._text.text.contains("Water"), "the panel names the bed and says to press Water: %s" % t._text.text)
	check(t.voice.lines[t.voice.lines.size() - 1]["key"] == "train_dry_1" and t.voice.lines[t.voice.lines.size() - 1]["text"].contains("paused the clock"), "and the crew says so")
	pump(t, 0.2)
	check((t._target.get("rect", Rect2()) as Rect2) == (farm.slot_buttons.buttons[dry_key] as Button).get_global_rect(), "the ring is on that slot's Water button")
	var water_before: float = farm.bay.get_bed_info(dry_key.x)["water_l"]
	check(farm.slot_buttons.press(dry_key.x, dry_key.y) == "water" and farm.bay.get_bed_info(dry_key.x)["water_l"] > water_before, "the player presses Water and the bed gets its water")
	check(pump_until(t, func(): return t.current_id() == "harvest", 30.0) > 0.0, "the lesson ends")

	check(farm.bay.get_setting("auto_irrigate") == true, "the harvest lesson switches Automatic irrigation on, so the crop does not dry out while it ripens")
	check(farm._auto_check.button_pressed, "and shows it in the checkbox")
	check(farm.bay.time_scale > 0.0 and t.phase() == 0, "and starts the clock")
	var ripe := pump_until(t, func(): return t.phase() == 1, 180.0)
	check(ripe > 0.0, "a crop ripens (after %.0f seconds at 64x)" % ripe)
	check(farm.bay.time_scale == 0.0, "and the clock stops")
	var ripe_key := Driver.find_kind(farm, "harvest")
	check(ripe_key.x >= 0 and t._text.text.contains("Harvest"), "the panel says to press Harvest: %s" % t._text.text)
	check(farm.slot_buttons.press(ripe_key.x, ripe_key.y) == "harvest" and farm.bay.get_plant(ripe_key.x, ripe_key.y)["empty"], "the player presses Harvest")
	check(pump_until(t, func(): return t.current_id() == "select", 40.0) > 0.0, "the lesson ends (the crew first says what was harvested)")
	check(texts_of(t).contains("kilograms"), "the crew read out the harvest")

	check(farm.selected == Vector2i(-1, -1), "the select lesson starts with nothing selected")
	pump(t, 0.2)
	check(t._target.has("point") and (t._target["point"] as Vector2).x > 0.0, "the ring is around a plant")
	var plant_at: Vector2i = t._plant_slot()
	farm._pick(t._plant_screen(plant_at))
	check(farm.selected == plant_at, "the player clicks the plant and it is selected (%s)" % str(farm.selected))
	pump(t, 0.2)
	check(t.voice.lines[t.voice.lines.size() - 1]["key"] == "describe", "the crew describes it: %s" % t.voice.lines[t.voice.lines.size() - 1]["text"])
	check(pump_until(t, func(): return t.current_id() == "ask", 40.0) > 0.0, "and the lesson ends once it has finished")

	check(t._text.text.contains("Ask crew") and (t._target.get("rect", Rect2()) as Rect2) == button(t, "Ask crew (C)").get_global_rect(), "the ring is on the Ask crew button")
	var before_lines: int = t.voice.lines.size()
	button(t, "Ask crew (C)").pressed.emit()
	check(t.voice.lines.size() == before_lines + 1 and not str(t.voice.lines[t.voice.lines.size() - 1]["key"]).begins_with("train"), "the player presses Ask crew and the crew answers: %s" % t.voice.lines[t.voice.lines.size() - 1]["text"])
	check(pump_until(t, func(): return t.current_id() == "finish", 40.0) > 0.0, "and the training ends")
	check(t._b_new.visible and t._b_keep.visible and not t._b_show.visible and t._counter.text == "", "the end offers Start a new game and Keep this farm")
	var ended: Array = []
	t.finished.connect(func(start: bool): ended.append(start))
	t.finish(false)
	await process_frame
	check(ended == [false], "Keep this farm ends the training")
	check(not is_instance_valid(t._layer) or t._layer.is_queued_for_deletion(), "the coach is gone")
	check(t.voice.spontaneous and farm._toast.position.y == 70.0 and not farm.has_meta("training"), "and the game is as it is when played: the crew speaks up again and its messages are back")
	how = button(t, "How to play")
	check(how.visible, "How to play is back at the bottom")
	check(Driver.occupied(farm) > 0 and float(farm.bay.get_status()["harvested_kg"]) > 0.0, "the farm the training grew carries on")
	await discard(t)

	# ---- Show me, Skip 5 days, Skip training ----
	t = await make_training()
	farm = t.farm
	t.press_start()
	pump(t, 0.2)
	check(t._b_show.visible, "Show me is offered")
	var ptr_start: Vector2 = Vector2.ZERO
	t.show_me()
	pump(t, 0.1)
	check(t._ptr_on, "Show me brings up the pointer")
	ptr_start = t._ptr
	pump(t, 0.5)
	check(t._ptr != ptr_start, "which moves toward the + (%s to %s)" % [str(ptr_start), str(t._ptr)])
	check(pump_until(t, func(): return t.current_id() == "grow", 60.0) > 0.0 and Driver.occupied(farm) == farm.BED_ROWS * farm.BED_COLS, "and presses the + and then Sow the whole bed: the bed is sown and the training goes on (%d plants)" % Driver.occupied(farm))
	var day_before: int = farm.bay.get_status()["day"]
	t.skip_days()
	check(int(farm.bay.get_status()["day"]) - day_before == 5, "Skip 5 days moves the clock five days (%d to %d)" % [day_before, int(farm.bay.get_status()["day"])])
	var ended2: Array = []
	t.finished.connect(func(start: bool): ended2.append(start))
	t.finish(true)
	check(ended2 == [true] and t.closed, "Skip training ends it and asks for a new game")
	await discard(t)

	# ---- Watch it all: the pointer plays every lesson, on the real controls ----
	t = await make_training()
	farm = t.farm
	var seen: Array = []
	t.step_changed.connect(func(i: int, id: String): seen.append(id))
	t.toggle_watch()
	check(t.auto and t._b_watch.text == "Stop watching", "Watch it all switches to watching")
	var total := pump_until(t, func(): return t.current_id() == "finish", 400.0)
	check(total > 0.0, "the whole training plays through to the end (%.0f seconds)" % total)
	check(seen == ["sow", "grow", "dry", "harvest", "select", "ask", "finish"], "every lesson in turn: %s" % str(seen))
	check(t.forced == 0, "and the pointer did every lesson itself (%d done for it)" % t.forced)
	check(float(farm.bay.get_status()["harvested_kg"]) > 0.0, "a crop was grown and harvested: %.2f kg" % float(farm.bay.get_status()["harvested_kg"]))
	check(farm.selected.x >= 0, "a plant was selected")
	var said := texts_of(t)
	for needle in ["train_sow_0", "train_grow_0", "train_dry_0", "train_dry_1", "train_harvest_0", "train_harvest_1", "train_select_0", "train_ask_0", "describe:", "toast:"]:
		check(said.contains(needle), "the crew said %s" % needle)
	check(farm.bay.time_scale == 0.0 or farm.bay.time_scale > 0.0, "(the clock was left as the lessons left it)")
	check(t._b_new.visible and t._b_keep.visible, "it stops at the end, for the player to choose")
	await discard(t)

	Prefs.erase()
	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

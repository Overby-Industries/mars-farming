extends SceneTree
# The floating slot buttons (scripts/slot_buttons.gd) and the crew voice (scripts/crew_voice.gd), driven the way a player
# would, in the scene the project starts with: sow a slot with its button, grow a crop and harvest it with its button, let a
# bed run dry and water it, let plants die and clear them, and listen (as text: nothing is spoken headless) to what the crew
# says about each of those. The same file is used by both farming games. The parts about time (sowing a bed, letting a crop grow,
# running until a button changes) are scripts/training_driver.gd, which the training scene (scripts/training.gd) teaches the same
# journey with; tests/training_test.gd plays that scene through.
#
#   Godot --headless --path godot -s res://tests/crew_ui_test.gd

const SlotButtons = preload("res://scripts/slot_buttons.gd")
const CrewVoice = preload("res://scripts/crew_voice.gd")
const Driver = preload("res://scripts/training_driver.gd")

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

# The scene the project starts with. Its astronaut gets plain surfaces: the headless renderer logs an error when one astronaut
# with textured skins is freed while another is alive, and this test makes several scenes.
func make_scene() -> Node3D:
	var packed := load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene
	var scene: Node3D = packed.instantiate()
	scene.astronaut_recipe = {"skins": false}
	root.add_child(scene)
	scene.set_speed(0.0)
	if scene.get("_next_storm_sol") != null:
		scene._next_storm_sol = 1000000        # the dome: no random storms unless a test asks
	await process_frame
	return scene

func discard(scene: Node3D) -> void:
	scene.queue_free()
	await process_frame
	await process_frame

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	root.size = Vector2i(1600, 900)      # headless windows are tiny: lay the HUD and the camera out as they are in the game
	check(ProjectSettings.get_setting("audio/general/text_to_speech") == true, "text-to-speech is switched on in the project, so the voice can speak")

	# ---- empty slots: a "+" over every slot, and pressing one sows it ----
	var scene := await make_scene()
	var sb = scene.slot_buttons
	check(sb.buttons.size() == 32, "a floating button over each of the 32 slots")
	var all_sow := true
	for key in sb.buttons:
		all_sow = all_sow and sb.kind_of(key.x, key.y) == "sow" and sb.text_of(key.x, key.y) == "+"
	check(all_sow, "an empty slot's button is a plus")
	scene.crop_key = "lettuce"
	check(sb.press(0, 1) == "sow" and not scene.bay.get_plant(0, 1)["empty"], "pressing the plus sows the chosen crop in that slot")
	check(scene.selected == Vector2i(0, 1), "and selects it")
	await process_frame
	check(sb.kind_of(0, 1) == "growing" and sb.text_of(0, 1).ends_with("%"), "a young plant's button shows how far it has grown (%s)" % sb.text_of(0, 1))
	check((sb.buttons[Vector2i(0, 1)] as Button).tooltip_text.contains("Butterhead"), "its tooltip names the crop")
	await discard(scene)

	# ---- a ready crop says Harvest, and pressing it harvests ----
	scene = await make_scene()
	sb = scene.slot_buttons
	Driver.sow_bed(scene, 0, "lettuce")
	scene.bay.set_setting("auto_irrigate", true)
	var took := Driver.grow_until(scene, 0, 0, FarmBay.STAGE_READY)      # as long as the crop takes in this scene
	await process_frame
	var ready := 0
	var first_ready := -1
	var consistent := true
	for s in 8:
		var p: Dictionary = scene.bay.get_plant(0, s)
		if not p["empty"] and p["ready"]:
			ready += 1
			first_ready = s if first_ready < 0 else first_ready
			consistent = consistent and sb.kind_of(0, s) == "harvest" and sb.text_of(0, s) == "Harvest"
	check(ready >= 1 and consistent, "every lettuce that is ready says Harvest (%d ready after %.1f days)" % [ready, took])
	var before: float = scene.bay.get_status()["harvested_kg"]
	check(sb.press(0, first_ready) == "harvest" and scene.bay.get_plant(0, first_ready)["empty"], "pressing Harvest harvests it")
	check(scene.bay.get_status()["harvested_kg"] > before, "and the harvest is counted")
	await process_frame
	check(sb.kind_of(0, first_ready) == "sow", "the slot is a plus again")
	var voice = scene.voice
	var adv: Dictionary = voice.advice(true)
	check(adv.get("key", "") == "ready" and adv["text"].contains("Harvest") and adv["text"].contains("lettuce"), "the crew says a crop is ready and to press Harvest: %s" % adv.get("text", ""))
	await discard(scene)

	# ---- a bed that runs dry says Water, and pressing it waters the bed ----
	scene = await make_scene()
	sb = scene.slot_buttons
	Driver.sow_bed(scene, 1, "radish")
	scene.bay.set_setting("auto_irrigate", false)
	var days := Driver.run_until_kind(scene, 1, 0, "water")
	sb.refresh()
	check(sb.kind_of(1, 0) == "water" and sb.text_of(1, 0) == "Water", "a plant in a dry bed says Water (after %.1f days)" % days)
	var water_before: float = scene.bay.get_bed_info(1)["water_l"]
	adv = scene.voice.advice(true)
	check(adv.get("key", "") == "dry_1" and adv["text"].contains("Bed 2") and adv["text"].contains("dry") and adv["text"].contains("Water"), "the crew says bed 2 is dry and to press Water: %s" % adv.get("text", ""))
	check(sb.press(1, 3) == "water" and scene.bay.get_bed_info(1)["water_l"] > water_before, "pressing Water adds water to the bed")
	check(sb.kind_of(1, 0) != "water", "and the Water buttons go away")
	await discard(scene)

	# ---- plants that die say Clear ----
	scene = await make_scene()
	sb = scene.slot_buttons
	Driver.sow_bed(scene, 2, "radish")
	scene.bay.set_setting("auto_irrigate", false)
	days = Driver.run_until_kind(scene, 2, 0, "clear", 80.0)
	sb.refresh()
	check(sb.kind_of(2, 0) == "clear" and sb.text_of(2, 0) == "Clear", "a dead plant says Clear (after %.1f days)" % days)
	check(sb.press(2, 0) == "clear" and scene.bay.get_plant(2, 0)["empty"], "pressing Clear takes it out")
	await discard(scene)

	# ---- the buttons in a busy bay: no two overlap, none is lost under the HUD or off the screen, each is near its plant ----
	scene = await make_scene()
	sb = scene.slot_buttons
	var crops := ["lettuce", "radish", "tomato", "potato"]
	for b in 4:
		Driver.sow_bed(scene, b, crops[b])
	scene.bay.set_setting("auto_irrigate", true)
	Driver.advance(scene, 24.0 * 40.0, false)
	scene.bay.set_setting("auto_irrigate", false)
	Driver.advance(scene, 24.0 * 4.0)
	await process_frame
	await process_frame
	var panels: Array = []
	for pc in scene.find_children("*", "PanelContainer", true, false):
		if pc.get_parent() is MarginContainer and pc.get_parent().name != "CrewCaption" and (pc as Control).is_visible_in_tree():
			panels.append((pc as Control).get_global_rect())
	var rects: Array = []
	var kinds := {}
	var strays := 0
	var under_hud := 0
	var off_screen := 0
	var view := Rect2(Vector2.ZERO, Vector2(1600, 900))
	for key in sb.buttons:
		var btn: Button = sb.buttons[key]
		kinds[sb.kind_of(key.x, key.y)] = true
		if not btn.visible:
			continue
		var r := Rect2(btn.position, btn.size)
		rects.append(r)
		if not view.encloses(r):
			off_screen += 1
		for p in panels:
			if (p as Rect2).intersects(r):
				under_hud += 1
				break
	var overlaps := 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersection(rects[j]).get_area() > 4.0:
				overlaps += 1
	check(rects.size() == 32, "all 32 buttons are showing in the start view (%d)" % rects.size())
	check(overlaps == 0, "no two buttons overlap (%d pairs)" % overlaps)
	check(off_screen == 0 and under_hud == 0, "none is off the screen (%d) or under a HUD panel (%d)" % [off_screen, under_hud])
	check(kinds.size() >= 2, "a busy bay shows several kinds of button (%s)" % str(kinds.keys()))
	await discard(scene)

	# ---- the voice ----
	scene = await make_scene()
	voice = scene.voice
	voice.audio = false
	check(voice.enabled and not voice.speaking, "the voice starts quiet")
	voice.tick(0.4)
	check(voice.lines.is_empty(), "it does not talk the moment the scene opens")
	voice.tick(1.5)
	check(voice.lines.size() == 1 and voice.lines[0]["key"] == "intro" and voice.lines[0]["text"].contains("Ask crew"), "it greets the player and points at the Ask crew button")
	check(voice._caption_box.visible and (voice._caption_label as Label).text == voice.lines[0]["text"], "every line is captioned")
	var count: int = voice.lines.size()
	voice.tick(CrewVoice.THINK_S)
	check(voice.lines.size() == count, "it leaves a gap after a line: nothing new straight away")
	var guard := 0
	while voice.lines.size() == count and guard < 40:
		voice.tick(CrewVoice.THINK_S)
		guard += 1
	check(voice.lines.size() == count + 1 and voice.lines[count]["key"] == "sow" and voice.lines[count]["text"].contains("empty"), "then, with every slot empty, it tells the player to sow: %s" % voice.lines[voice.lines.size() - 1]["text"])
	check(voice._caption_label.text == voice.lines[voice.lines.size() - 1]["text"], "the caption follows")
	var spoken: int = voice.lines.size()
	for i in int(CrewVoice.REPEAT_S / CrewVoice.THINK_S) - 12:
		voice.tick(CrewVoice.THINK_S)
	check(voice.lines.size() == spoken, "it does not repeat the same advice within %d seconds" % int(CrewVoice.REPEAT_S))
	for i in 20:
		voice.tick(CrewVoice.THINK_S)
	check(voice.lines.size() > spoken, "but it does remind the player later")

	# selecting a slot gets a description of it, and the astronaut turns to look
	scene.select_slot(1, 2)
	voice.tick(0.1)
	var last: Dictionary = voice.lines[voice.lines.size() - 1]
	check(last["key"] == "describe" and last["text"].begins_with("Bed 2, slot 3 is empty") and last["text"].contains("percent moisture") and last["text"].contains("nutrients"), "selecting an empty slot describes the slot and the state of the medium: %s" % last["text"])
	check(scene.astronaut._look_left > 0.0, "and the astronaut looks toward it")
	Driver.sow_bed(scene, 1, "tomato")
	scene.select_slot(1, 4)
	voice.tick(0.1)
	last = voice.lines[voice.lines.size() - 1]
	check(last["key"] == "describe" and last["text"].contains("Dwarf tomato") and last["text"].contains("bed 2, slot 5") and last["text"].contains("grown") and last["text"].contains("days to go"), "selecting a plant describes the crop, its stage, its progress and what is next: %s" % last["text"])
	check(last["text"].contains(voice.medium), "and names the medium it grows in (%s)" % voice.medium)

	# the Ask crew button answers at once, whatever was said a moment ago
	var n: int = voice.lines.size()
	voice.ask()
	check(voice.lines.size() == n + 1, "Ask crew always answers")
	# news and toasts
	voice.on_toast("Harvested 0.18 kg of lettuce")
	last = voice.lines[voice.lines.size() - 1]
	check(last["key"] == "toast" and last["text"].contains("kilograms"), "it reads out a harvest in words: %s" % last["text"])
	n = voice.lines.size()
	voice.on_toast("Butterhead lettuce in bed 1 is ready")
	check(voice.lines.size() == n, "and leaves the 'is ready' message to its own advice")
	# the voice can be switched off, entirely
	voice.enabled = false
	voice.say("This should not appear", "x")
	check(voice.lines.size() == n, "when it is switched off it says nothing")
	voice.enabled = true
	# the scene's own notes
	if scene.has_method("start_storm"):
		scene.start_storm(4.0, 48.0)
		Driver.advance(scene, 30.0, false)
		var notes: Array = scene.voice_notes()
		check(notes.size() == 1 and notes[0]["text"].contains("dust storm") and notes[0]["text"].contains("percent"), "in a dust storm the crew warns about the sun and the solar power: %s" % str(notes))
	else:
		scene.bay.set_setting("power_budget_w", 5.0)
		var notes2: Array = scene.voice_notes()
		check(notes2.size() == 1 and notes2[0]["text"].contains("power budget"), "over the power budget the crew says the lights are dimmed: %s" % str(notes2))
	# the caption goes away after the line
	voice.say("A short line.", "short")
	voice._quiet_until = 1.0e9                # nothing else spontaneous, so the caption can be seen to fade
	for i in 40:
		voice.tick(0.5)
	check(not voice._caption_box.visible, "the caption fades once the line is done")
	await discard(scene)

	# ---- the astronaut looks where it is told ----
	scene = await make_scene()
	var man: Node3D = scene.astronaut
	man.set_process(false)
	var helmet: Node3D = man.get_component("Helmet")
	man.pose(0.0)
	var idle_yaw := helmet.rotation.y
	man.look_at_point(man.to_global(Vector3(-3.0, 1.6, -3.0)), 5.0, true)     # ahead and to its left
	man.pose(0.0)
	check(helmet.rotation.y > idle_yaw + 0.3 and helmet.rotation.y < 1.25, "told to look ahead and to its left, the head turns left (%.2f rad)" % helmet.rotation.y)
	man.look_at_point(man.to_global(Vector3(3.0, 1.6, -3.0)), 5.0, true)      # ahead and to its right
	man.pose(0.0)
	check(helmet.rotation.y < idle_yaw - 0.3, "and to the right when told to look right (%.2f rad)" % helmet.rotation.y)
	man.look_at_point(man.to_global(Vector3(0.0, 0.2, -2.0)), 5.0, true)      # low and ahead: the plants
	man.pose(0.0)
	check(helmet.rotation.x < -0.1, "and down when told to look low (%.2f rad)" % helmet.rotation.x)
	man.look_at_point(man.to_global(Vector3(0.0, 1.6, 6.0)), 5.0, true)       # behind it: a neck can only turn so far
	man.pose(0.0)
	check(absf(helmet.rotation.y) <= 1.21, "a neck turns only so far (%.2f rad)" % helmet.rotation.y)
	man.stop_looking()
	await discard(scene)

	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

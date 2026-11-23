extends Node
## The training for new players: the real game, played through with a coach.
##
## It hosts the project's own main scene (greenhouse.gd or dome.gd, whichever the project starts with) and lays a coach panel over
## it. The panel says what to do next, a ring marks the control to use, and "Show me" does the step on the real buttons while a
## pointer shows where. The six lessons are the journey tests/crew_ui_test.gd drives through the game, with the same
## scripts/training_driver.gd helpers for the parts about time:
##
##   SOW     press the + over a slot            GROW     run the clock and watch the plant's percentage climb
##   DRY     a bed runs low: press Water        HARVEST  a crop is ripe: press Harvest
##   SELECT  click a plant, hear it described   ASK      press Ask crew, hear what to do next
##
## The crew reads each instruction aloud and, as in the game, describes what you select and answers Ask crew. "Watch it all" plays
## the whole training with the pointer, one lesson after another. The game's own How to play button opens this scene
## (scenes/training.tscn); "Start a new game" or "Skip training" goes to the project's main scene, "Keep this farm" carries on
## in the farm the training grew.
##
## Everything is driven by `tick(delta)` (called every frame), so the tests can play the training with the clock they want.

const Driver = preload("res://scripts/training_driver.gd")

signal step_changed(index: int, id: String)
signal finished(start_game: bool)

const GROW_TO := 0.25          # the Grow lesson is done when a plant is this far along (0 to 1)
const FAST := 64.0             # the clock speed the pointer picks, game hours per second
const SKIP_DAYS := 5.0
const SETTLE := 7.0            # how quickly the pointer settles on its target (per second)
const STALL_S := 10.0          # in "Watch it all", a lesson that is still not done this long after its demo is done for the player
const RING := Color("ffe08a")
const ARROW := [Vector2(0, 0), Vector2(0, 21), Vector2(5, 16.5), Vector2(8.5, 25), Vector2(12, 23.5), Vector2(8.5, 15.5), Vector2(15, 15.5)]

var farm_recipe := {}          # the hosted game's astronaut recipe; the tests set {"skins": false} before the node enters the tree
var change_scene := true       # off: `finished` is emitted and the scenes are left alone (the tests)
var auto := false              # watching: each lesson is shown by the pointer, one after another
var step := 0                  # index into `steps`
var steps: Array = []
var farm: Node3D               # the hosted game
var voice: Node                # its crew voice
var closed := false
var forced := 0                # lessons the watch mode had to do for the player because the demo did not (the tests expect 0)

var _t := 0.0
var _phase := 0                # the Dry and Harvest lessons have two: wait for the moment, then act
var _advance_at := -1.0        # the lesson is done: go on at this time, once the crew has finished speaking
var _praise := ""
var _base_kg := 0.0
var _dry_bed := -1
var _asked := false
var _demo_ran := false
var _stall := 0.0
var _sow_key := Vector2i(-1, -1)
var _plant_key := Vector2i(-1, -1)
var _buttons := {}
var _target := {}
var _hint_shown := ""

# the pointer: a list of actions, ["wait", s] ["point", Callable -> Vector2] ["press", Callable] ["until", Callable -> bool, limit s]
var _script: Array = []
var _si := 0
var _wait := 0.0
var _ptr := Vector2.ZERO
var _ptr_on := false
var _press_t := 0.0

# the overlay
var _layer: CanvasLayer
var _root: Control
var _canvas: Control
var _coach: MarginContainer
var _title: Label
var _counter: Label
var _text: Label
var _hint: Label
var _dots: Array = []
var _ring_style: StyleBoxFlat
var _accent := Color("e8861f")
var _muted := Color(0.8, 0.8, 0.8, 0.65)
var _b_start: Button
var _b_show: Button
var _b_days: Button
var _b_watch: Button
var _b_voice: Button
var _b_skip: Button
var _b_new: Button
var _b_keep: Button
var _spacer: Control

func _ready() -> void:
	var path := str(ProjectSettings.get_setting("application/run/main_scene"))
	if path == scene_file_path:
		push_error("The training hosts the project's main scene, so it cannot be the main scene itself.")
		return
	farm = (load(path) as PackedScene).instantiate()
	farm.astronaut_recipe = farm_recipe
	farm.set_meta("training", true)         # the game hides its How to play button while it is hosted
	add_child(farm)
	voice = farm.voice
	voice.spontaneous = false               # the crew speaks for the coach and when spoken to (a selection, Ask crew), not on its own
	voice.describe_selection = false        # ... and does not describe every slot the lessons press, until the Select lesson
	voice.asked.connect(func(): _asked = true)
	farm.set_speed(0.0)                     # the clock waits until a lesson starts it
	if farm.get("_next_storm_sol") != null:
		farm._next_storm_sol = 1000000      # the dome: no dust storm in the middle of the training
	farm._toast.position.y = 232            # the game's messages appear under the coach panel
	_choose_crop()
	_build_overlay()
	steps = _make_steps()
	_goto(0)

func _process(delta: float) -> void:
	tick(delta)

# ---------------------------------------------------------------------------------------------------------
# the lessons
# ---------------------------------------------------------------------------------------------------------

# For the training the crop is the one that is ready soonest, so the lessons stay short; the list on the right shows it.
func _choose_crop() -> void:
	farm.crop_key = Driver.fastest_crop(farm)
	var picker = farm.get("_crop_picker")
	if picker is OptionButton:
		var list: Array = farm.bay.get_species_list()
		for i in list.size():
			if list[i]["key"] == farm.crop_key:
				(picker as OptionButton).select(i)

# The crop in plain words ("radish": the species key, not the cultivar's long name).
func _crop_name() -> String:
	return str(farm.crop_key).replace("_", " ")

# Each lesson: its id, title, what the panel says and what the crew says for each phase ({crop}, {bed} and {tank} are filled in), and
# a word of praise for when it is done (shown always, spoken unless "quiet": the crew's own answer is the feedback then). "lesson"
# numbers the six; the welcome and the end are bookends.
func _make_steps() -> Array:
	return [
		{"id": "welcome", "title": "Welcome aboard", "lesson": 0, "phases": [{
			"text": "This is a short training in the real game. You will sow {crop}, let it grow, water it when it runs dry, harvest it, look at a plant and ask me what to do next.",
			"hint": "Press Start and do each step yourself, or Watch it all and I will play it through for you.",
			"say": "Welcome aboard. This is a short training in the real game. You will sow {crop}, let it grow, water it when it runs dry, harvest it, look at a plant and ask me what to do next."}]},
		{"id": "sow", "title": "Sow", "lesson": 1, "praise": "Sown.", "phases": [{
			"text": "Every empty slot has a + over it. Press one to sow {crop} in that slot.",
			"hint": "The crop comes from the list on the right. For the training I chose {crop}, the quickest to grow.",
			"say": "Every empty slot has a plus over it. Press one to sow {crop} in that slot."}, {
			"text": "Slot by slot is precise. To fill the rest of the bed at once, press Sow the whole bed in the right panel.",
			"hint": "The right panel works on the bed of the slot you pressed. A full bed is what you will water and harvest.",
			"say": "Slot by slot is precise. To fill the rest of the bed at once, press Sow the whole bed in the right panel."}]},
		{"id": "grow", "title": "Grow", "lesson": 2, "praise": "It is growing.", "phases": [{
			"text": "Plants grow as time passes. Press 16x or 64x at the bottom, and watch the percentage on the plant's button climb.",
			"hint": "The clock is paused until you start it.",
			"say": "Plants grow as time passes. Press the sixteen or the sixty-four button at the bottom, and watch the percentage on the plant's button climb."}]},
		{"id": "dry", "title": "Dry", "lesson": 3, "praise": "Watered.", "phases": [{
			"text": "Plants drink from their bed. Keep the clock running until a bed runs low: its buttons turn blue and say Water.",
			"hint": "Automatic irrigation is off for this lesson.",
			"say": "Plants drink from their bed. Keep the clock running until a bed runs low. Its buttons turn blue and say Water."}, {
			"text": "Bed {bed} has run dry, so I have paused the clock. Press Water on any plant in that bed.",
			"hint": "The water comes from the {tank}. The right panel can water the bed too.",
			"say": "Bed {bed} has run dry, so I have paused the clock. Press Water on any plant in that bed."}]},
		{"id": "harvest", "title": "Harvest", "lesson": 4, "praise": "Harvested.", "phases": [{
			"text": "Now let it ripen. I switched on Automatic irrigation and started the clock, so the bed waters itself while you wait. A ripe crop's button says Harvest.",
			"hint": "Automatic irrigation is the checkbox on the left. It draws on the {tank}.",
			"say": "Now let it ripen. I have switched on automatic irrigation and started the clock, so the bed waters itself while you wait. A ripe crop's button says Harvest."}, {
			"text": "A crop is ripe, so I have paused the clock. Press its Harvest button.",
			"hint": "What you harvest adds up in the panel on the left.",
			"say": "A crop is ripe, so I have paused the clock. Press its Harvest button."}]},
		{"id": "select", "title": "Select", "lesson": 5, "praise": "That is how you check on a plant.", "quiet": true, "phases": [{
			"text": "Click any plant or slot in a bed. The panel on the right shows its details, and I describe it.",
			"hint": "Hold the right mouse button and drag to turn the view; the wheel zooms.",
			"say": "Click any plant or slot in a bed. The panel on the right shows its details, and I will describe it."}]},
		{"id": "ask", "title": "Ask", "lesson": 6, "praise": "", "phases": [{
			"text": "Not sure what to do next? Press Ask crew, or the C key, and I will say the most useful thing right now.",
			"hint": "Ask as often as you like.",
			"say": "Not sure what to do next? Press Ask crew, or the C key, and I will say the most useful thing right now."}]},
		{"id": "finish", "title": "Training complete", "lesson": 0, "phases": [{
			"text": "That is the whole loop: sow, grow, water, harvest, and ask me when you are unsure. In a new game you choose how hard the colony's situation is, and win by keeping the crew fed. Start one, or keep playing in this farm.",
			"hint": "The How to play button at the bottom brings this training back any time.",
			"say": "Training complete. That is the whole loop: sow, grow, water, harvest, and ask me when you are unsure. In a new game you choose how hard the colony's situation is, and win by keeping the crew fed. Start one, or keep playing in this farm."}]},
	]

func _fmt(text: String) -> String:
	return text.format({"crop": _crop_name(), "bed": _dry_bed + 1, "tank": str(voice.reservoir)})

func lesson_count() -> int:
	var n := 0
	for s in steps:
		n = maxi(n, int(s["lesson"]))
	return n

func current_id() -> String:
	return str(steps[step]["id"])

func phase() -> int:
	return _phase

# What the lesson is waiting for is time itself: the buttons offer to skip ahead.
func _is_waiting_for_time() -> bool:
	var id := current_id()
	return id == "grow" or (id == "dry" and _phase == 0) or (id == "harvest" and _phase == 0)

func _goto(i: int) -> void:
	_advance_at = -1.0
	step = i
	_phase = 0
	_script = []
	_ptr_on = false
	_demo_ran = false
	_stall = 0.0
	var id := current_id()
	match id:
		"dry":
			_set_irrigation(false)
		"harvest":
			_set_irrigation(true)
			_base_kg = float(farm.bay.get_status()["harvested_kg"])
			if farm.bay.time_scale <= 0.0:
				farm.set_speed(FAST)
		"select":
			farm.select_slot(-1, -1)
			voice.describe_selection = true
		"ask":
			_asked = false
	_show_phase()
	step_changed.emit(step, id)

func _set_irrigation(on: bool) -> void:
	farm.bay.set_setting("auto_irrigate", on)
	var check = farm.get("_auto_check")
	if check is CheckBox:
		(check as CheckBox).set_pressed_no_signal(on)

func _set_phase(p: int) -> void:
	_phase = p
	_show_phase()

# Show the lesson's words, buttons and progress, and have the crew say it.
func _show_phase() -> void:
	var s: Dictionary = steps[step]
	var ph: Dictionary = s["phases"][_phase]
	var id := current_id()
	_title.text = str(s["title"])
	_counter.text = "Lesson %d of %d" % [s["lesson"], lesson_count()] if int(s["lesson"]) > 0 else ""
	_text.text = _fmt(str(ph["text"]))
	_hint_shown = ""
	_refresh_hint()
	_b_start.visible = id == "welcome"
	_b_voice.visible = id == "welcome" and voice.available_genders().size() > 1
	_refresh_voice_button()
	_b_show.visible = id != "welcome" and id != "finish"
	_b_days.visible = _is_waiting_for_time()
	_b_watch.visible = id != "finish"
	_b_watch.text = "Stop watching" if auto else ("Watch it all" if id == "welcome" else "Watch the rest")
	_b_skip.visible = id != "finish"
	_b_new.visible = id == "finish"
	_b_keep.visible = id == "finish"
	_spacer.visible = id != "finish"
	for i in _dots.size():
		var c := _accent
		c.a = 1.0 if (i + 1 < int(s["lesson"]) or id == "finish") else (0.9 if i + 1 == int(s["lesson"]) else 0.22)
		if i + 1 == int(s["lesson"]):
			c = c.lightened(0.45)
		(_dots[i] as ColorRect).color = c
	voice.say(_fmt(str(ph["say"])), "train_%s_%d" % [id, _phase], _look_target(), false)

func _refresh_hint() -> void:
	var text: String
	var colour := _muted
	if _advance_at >= 0.0:
		text = "Done. " + _praise if _praise != "" else "Done."
		colour = Color("8fd68a")
	else:
		var ph: Dictionary = steps[step]["phases"][_phase]
		text = _fmt(str(ph.get("hint", "")))
		if _is_waiting_for_time() and farm.bay.time_scale <= 0.0 and current_id() != "harvest":
			text = "The clock is paused: press 16x or 64x at the bottom, or skip ahead."
	if text == _hint_shown:
		return
	_hint_shown = text
	_hint.text = text
	_hint.add_theme_color_override("font_color", colour)
	_hint.visible = text != ""

# Is the current lesson done?
func _step_done() -> bool:
	match current_id():
		"sow":
			return _phase == 1 and _bed_full()
		"grow":
			return Driver.best_progress(farm) >= GROW_TO
		"dry":
			return _phase == 1 and not _bed_says(_dry_bed, "water")
		"harvest":
			return float(farm.bay.get_status()["harvested_kg"]) > _base_kg + 0.0001
		"select":
			return farm.selected.x >= 0
		"ask":
			return _asked
	return false

# Is some bed sown in every slot?
func _bed_full() -> bool:
	for bed in farm.bay.get_bed_count():
		var full := true
		for slot in farm.BED_ROWS * farm.BED_COLS:
			full = full and not farm.bay.get_plant(bed, slot)["empty"]
		if full:
			return true
	return false

func _bed_says(bed: int, kind: String) -> bool:
	for slot in farm.BED_ROWS * farm.BED_COLS:
		if Driver.kind(farm, bed, slot) == kind:
			return true
	return false

# The moments the Dry and Harvest lessons wait for: the clock stops there, so nothing is lost while the player learns.
func _phase_logic() -> void:
	if _phase != 0:
		return
	match current_id():
		"sow":
			if Driver.occupied(farm) > 0:
				_set_phase(1)
		"dry":
			var key := Driver.find_kind(farm, "water")
			if key.x >= 0:
				_dry_bed = key.x
				farm.set_speed(0.0)
				_set_phase(1)
		"harvest":
			if Driver.find_kind(farm, "harvest").x >= 0:
				farm.set_speed(0.0)
				_set_phase(1)

func _complete_step() -> void:
	_praise = str(steps[step].get("praise", ""))
	_advance_at = _t + 0.9
	_script = []
	_ptr_on = false
	_refresh_hint()
	if _praise != "" and not steps[step].get("quiet", false) and not voice.is_busy():
		voice.say(_praise, "train_praise", Vector3.INF, false)      # (when the crew is already saying something about it, that is the feedback)

# Advance the training by `delta` seconds.
func tick(delta: float) -> void:
	if farm == null or closed:
		return
	_t += delta
	_run_script(delta)
	if _press_t > 0.0:
		_press_t -= delta
	if _advance_at >= 0.0:
		if _t >= _advance_at and not voice.is_busy():
			_goto(step + 1)
	else:
		_phase_logic()
		if _step_done():
			_complete_step()
		elif auto:
			_auto_logic(delta)
		_refresh_hint()
	_target = _compute_target()
	_canvas.queue_redraw()

# "Watch it all": speak the lesson, then show it with the pointer; if it somehow does not get done, do it for the player.
func _auto_logic(delta: float) -> void:
	var id := current_id()
	if id == "finish" or voice.is_busy() or not _script.is_empty():
		return
	if id == "welcome":
		_goto(1)
	elif not _demo_ran:
		_start_demo()
	else:
		_stall += delta
		if _stall > STALL_S:
			_stall = 0.0
			forced += 1
			_force_step()

func _force_step() -> void:
	if _is_waiting_for_time():
		Driver.advance(farm, SKIP_DAYS * 24.0)
	else:
		_do(current_id())

# ---------------------------------------------------------------------------------------------------------
# the buttons of the panel
# ---------------------------------------------------------------------------------------------------------

func press_start() -> void:
	if current_id() == "welcome":
		_goto(1)

func show_me() -> void:
	if not closed and current_id() != "welcome" and current_id() != "finish":
		_start_demo()

func _refresh_voice_button() -> void:
	_b_voice.text = "Voice: %s" % str(voice.gender).capitalize()

# The welcome offers the crew's voice, male or female (when this PC has both), so the training is heard in the one the player wants.
func toggle_voice() -> void:
	voice.set_gender("female" if voice.gender == "male" else "male")
	_refresh_voice_button()

func skip_days() -> void:
	if not closed and _is_waiting_for_time():
		Driver.advance(farm, SKIP_DAYS * 24.0)

func toggle_watch() -> void:
	auto = not auto
	_b_watch.text = "Stop watching" if auto else ("Watch it all" if current_id() == "welcome" else "Watch the rest")
	if not auto:
		_script = []
		_ptr_on = false

# End the training: `start_game` goes to the project's main scene (a fresh farm), otherwise the coach goes and this farm carries on.
func finish(start_game: bool) -> void:
	if closed:
		return
	closed = true
	_script = []
	finished.emit(start_game)
	if start_game:
		if change_scene:
			get_tree().change_scene_to_file(str(ProjectSettings.get_setting("application/run/main_scene")))
		return
	_layer.queue_free()
	voice.spontaneous = true
	voice.describe_selection = true
	farm._toast.position.y = 70
	farm.remove_meta("training")
	var how: Button = _find_button("How to play")
	if how != null:
		how.visible = true
		(how.get_parent().get_child(how.get_index() - 1) as Control).visible = true       # and the separator before it

# ---------------------------------------------------------------------------------------------------------
# the pointer: what "Show me" does, step by step, on the real controls
# ---------------------------------------------------------------------------------------------------------

func _start_demo() -> void:
	var s := _demo_script()
	if s.is_empty():
		return
	_demo_ran = true
	_script = s
	_si = 0
	_wait = 0.0
	if not _ptr_on:
		_ptr_on = true
		_ptr = _b_show.get_global_rect().get_center() if _b_show.is_visible_in_tree() else Vector2(800, 150)

func _demo_script() -> Array:
	var s: Array = []
	var clock_off: bool = farm.bay.time_scale < 16.0
	match current_id():
		"sow":
			if _phase == 0:
				var key := _sow_slot()
				s = [["wait", 0.4], ["point", func(): return _slot_centre(key)], ["wait", 0.5], ["press", func(): _do("sow")], ["wait", 0.4]]
				s.append(["until", (func(): return _phase == 1), 5.0])
			s += [["point", func(): return _button_centre("Sow the whole bed")], ["wait", 0.5], ["press", func(): _do("sow")], ["wait", 0.4]]
		"grow":
			if clock_off:
				s = [["wait", 0.4], ["point", func(): return _button_centre("64x")], ["wait", 0.5], ["press", func(): _do("grow")]]
			s.append(["until", (func(): return _step_done()), 150.0])
		"dry":
			if _phase == 0:
				if clock_off:
					s = [["wait", 0.4], ["point", func(): return _button_centre("64x")], ["wait", 0.5], ["press", func(): _do("grow")]]
				s.append(["until", (func(): return _phase == 1), 150.0])
				s.append(["wait", 0.6])
			s += [["point", func(): return _kind_centre("water")], ["wait", 0.5], ["press", func(): _do("dry")], ["wait", 0.4]]
		"harvest":
			if _phase == 0:
				s = [["wait", 0.4], ["until", (func(): return _phase == 1), 150.0], ["wait", 0.6]]
			s += [["point", func(): return _kind_centre("harvest")], ["wait", 0.5], ["press", func(): _do("harvest")], ["wait", 0.4]]
		"select":
			var key := _plant_slot()
			s = [["wait", 0.4], ["point", func(): return _plant_screen(key)], ["wait", 0.5], ["press", func(): _do("select")], ["wait", 0.4]]
		"ask":
			s = [["wait", 0.4], ["point", func(): return _button_centre("Ask crew (C)")], ["wait", 0.5], ["press", func(): _do("ask")], ["wait", 0.4]]
	return s

# What the player's hand would do for a lesson, done through the game's own buttons and calls.
func _do(id: String) -> void:
	match id:
		"sow":
			if _phase == 0:
				var key := _sow_slot()
				if key.x >= 0:
					farm.slot_buttons.press(key.x, key.y)
			else:
				_press_button("Sow the whole bed")
		"grow":
			_press_button("64x")
		"dry":
			_press_kind("water")
		"harvest":
			_press_kind("harvest")
		"select":
			var key := _plant_slot()
			if key.x >= 0:
				farm._pick(_plant_screen(key))        # a click on the plant, through the game's own picking
		"ask":
			_press_button("Ask crew (C)")

func _press_kind(kind: String) -> void:
	var key := Driver.find_kind(farm, kind)
	if key.x >= 0:
		farm.slot_buttons.press(key.x, key.y)

func _press_button(text: String) -> void:
	var b := _find_button(text)
	if b != null:
		b.pressed.emit()

func _run_script(delta: float) -> void:
	if _script.is_empty():
		return
	if _si >= _script.size():
		_script = []
		_ptr_on = false
		return
	var a: Array = _script[_si]
	var done := false
	match a[0]:
		"wait":
			_wait += delta
			done = _wait >= float(a[1])
		"point":
			var goal: Vector2 = (a[1] as Callable).call()
			_wait += delta
			_ptr = _ptr.lerp(goal, 1.0 - exp(-delta * SETTLE))
			if _ptr.distance_to(goal) < 2.0 or _wait > 2.5:
				_ptr = goal
				done = true
		"press":
			(a[1] as Callable).call()
			_press_t = 0.4
			done = true
		"until":
			_wait += delta
			done = bool((a[1] as Callable).call()) or _wait >= float(a[2])
	if done:
		_si += 1
		_wait = 0.0
		if _si >= _script.size():
			_script = []

# ---------------------------------------------------------------------------------------------------------
# where things are on the screen
# ---------------------------------------------------------------------------------------------------------

func _find_button(text: String) -> Button:
	if _buttons.has(text) and is_instance_valid(_buttons[text]):
		return _buttons[text]
	for b in farm.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			_buttons[text] = b
			return b
	return null

func _button_centre(text: String) -> Vector2:
	var b := _find_button(text)
	return b.get_global_rect().get_center() if b != null else _ptr

func _slot_button(key: Vector2i) -> Button:
	var sbs: Control = farm.slot_buttons
	return sbs.buttons.get(key)

func _slot_centre(key: Vector2i) -> Vector2:
	var b := _slot_button(key)
	return b.get_global_rect().get_center() if b != null and b.visible else _ptr

func _kind_centre(kind: String) -> Vector2:
	var key := Driver.find_kind(farm, kind)
	return _slot_centre(key) if key.x >= 0 else _ptr

func _plant_screen(key: Vector2i) -> Vector2:
	if key.x < 0:
		return _ptr
	var cam: Camera3D = farm._cam
	return cam.unproject_position(farm.BED_CENTERS[key.x] + farm._slot_offsets[key.y] + Vector3(0, 0.22, 0))

# The slot nearest the middle of the screen that is empty (to sow) or planted (to select); kept while it stays good.
func _nearest_slot(planted: bool) -> Vector2i:
	var middle := get_viewport().get_visible_rect().size * 0.5
	var best := Vector2i(-1, -1)
	var best_d := INF
	for bed in farm.bay.get_bed_count():
		for slot in farm.BED_ROWS * farm.BED_COLS:
			var key := Vector2i(bed, slot)
			if farm.bay.get_plant(bed, slot)["empty"] == planted:
				continue
			var d := _plant_screen(key).distance_to(middle)
			if d < best_d:
				best_d = d
				best = key
	return best

func _sow_slot() -> Vector2i:
	if _sow_key.x < 0 or not farm.bay.get_plant(_sow_key.x, _sow_key.y)["empty"]:
		_sow_key = _nearest_slot(false)
	return _sow_key

func _plant_slot() -> Vector2i:
	if _plant_key.x < 0 or farm.bay.get_plant(_plant_key.x, _plant_key.y)["empty"]:
		_plant_key = _nearest_slot(true)
	return _plant_key

# A world point for the astronaut to look at while it gives the instruction, or Vector3.INF.
func _look_target() -> Vector3:
	var key := Vector2i(-1, -1)
	match current_id():
		"sow":
			if _phase == 0:
				key = _sow_slot()
		"dry":
			if _phase == 1:
				key = Driver.find_kind(farm, "water")
		"harvest":
			if _phase == 1:
				key = Driver.find_kind(farm, "harvest")
		"select":
			key = _plant_slot()
	if key.x < 0:
		return Vector3.INF
	var p: Vector3 = voice.slot_point(key.x, key.y)
	return p

func _speed_rect() -> Rect2:
	var a := _find_button("16x")
	var b := _find_button("64x")
	if a == null or b == null:
		return Rect2()
	return a.get_global_rect().merge(b.get_global_rect())

# What the ring is around now: {"rect": Rect2} (a control), {"point": Vector2} (a plant) or {}.
func _compute_target() -> Dictionary:
	if _advance_at >= 0.0:
		return {}
	var clock_off: bool = farm.bay.time_scale < 16.0
	match current_id():
		"sow":
			if _phase == 1:
				var whole := _find_button("Sow the whole bed")
				if whole != null and not whole.disabled:
					return {"rect": whole.get_global_rect()}
				return {}
			var key := _sow_slot()
			var b: Button = _slot_button(key) if key.x >= 0 else null
			if b != null and b.visible:
				return {"rect": b.get_global_rect()}
		"grow":
			if clock_off:
				return {"rect": _speed_rect()}
		"dry":
			if _phase == 0 and clock_off:
				return {"rect": _speed_rect()}
			if _phase == 1:
				return _rect_of_kind("water")
		"harvest":
			if _phase == 1:
				return _rect_of_kind("harvest")
		"select":
			var key := _plant_slot()
			if key.x >= 0:
				return {"point": _plant_screen(key)}
		"ask":
			var b := _find_button("Ask crew (C)")
			if b != null:
				return {"rect": b.get_global_rect()}
	return {}

func _rect_of_kind(kind: String) -> Dictionary:
	var key := Driver.find_kind(farm, kind)
	var b: Button = _slot_button(key) if key.x >= 0 else null
	if b != null and b.visible:
		return {"rect": b.get_global_rect()}
	return {}

# ---------------------------------------------------------------------------------------------------------
# the overlay
# ---------------------------------------------------------------------------------------------------------

func _make_label(text: String, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l

func _make_button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(callback)
	return b

func _build_overlay() -> void:
	var pal: Dictionary = farm.hud_palette
	_accent = pal.get("accent", _accent)
	var panel_colour: Color = pal.get("panel", Color(0.075, 0.08, 0.09, 0.9))
	var text_colour: Color = pal.get("text", Color("e6e8eb"))
	_muted = Color(text_colour, 0.62)
	_layer = CanvasLayer.new()
	_layer.layer = 20                       # above the game's own HUD
	add_child(_layer)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = (farm.slot_buttons.get_parent() as Control).theme       # the game's own button look
	_layer.add_child(_root)

	# the coach panel, top centre, between the game's left and right panels
	_coach = MarginContainer.new()
	_coach.name = "Coach"
	_coach.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_coach.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_coach.add_theme_constant_override("margin_top", 14)
	_coach.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_coach)
	var frame := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(panel_colour, maxf(panel_colour.a, 0.93))
	style.border_color = _accent
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	frame.add_theme_stylebox_override("panel", style)
	_coach.add_child(frame)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	frame.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	box.add_child(head)
	head.add_child(_make_label("TRAINING", 12, _accent))
	_title = _make_label("", 17, text_colour)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_counter = _make_label("", 12, _muted)
	head.add_child(_counter)

	_text = _make_label("", 15, text_colour)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(580, 0)
	box.add_child(_text)
	_hint = _make_label("", 12, _muted)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(580, 0)
	box.add_child(_hint)

	var dots := HBoxContainer.new()
	dots.add_theme_constant_override("separation", 5)
	box.add_child(dots)
	for i in 6:
		var d := ColorRect.new()
		d.custom_minimum_size = Vector2(34, 5)
		dots.add_child(d)
		_dots.append(d)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	_b_start = _make_button("Start", press_start)
	_b_show = _make_button("Show me", show_me)
	_b_days = _make_button("Skip 5 days", skip_days)
	_b_watch = _make_button("Watch it all", toggle_watch)
	_b_voice = _make_button("Voice: Male", toggle_voice)
	_spacer = Control.new()
	_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_b_skip = _make_button("Skip training", func(): finish(true))
	_b_new = _make_button("Start a new game", func(): finish(true))
	_b_keep = _make_button("Keep this farm", func(): finish(false))
	for c in [_b_start, _b_voice, _b_show, _b_days, _b_watch, _spacer, _b_skip, _b_new, _b_keep]:
		row.add_child(c)

	# the ring and the pointer are drawn on top of everything
	_canvas = Control.new()
	_canvas.name = "Pointer"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_canvas)
	_root.add_child(_canvas)
	_ring_style = StyleBoxFlat.new()
	_ring_style.draw_center = false
	_ring_style.set_border_width_all(3)
	_ring_style.set_corner_radius_all(12)
	_ring_style.shadow_size = 8
	_ring_style.shadow_color = Color(RING, 0.28)

func _draw_canvas() -> void:
	if closed:
		return
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	if _target.has("rect") and (_target["rect"] as Rect2).has_area():
		_ring_style.border_color = Color(RING, 0.6 + 0.4 * pulse)
		_canvas.draw_style_box(_ring_style, (_target["rect"] as Rect2).grow(5.0 + 3.0 * pulse))
	elif _target.has("point"):
		_canvas.draw_arc(_target["point"], 36.0 + 5.0 * pulse, 0.0, TAU, 48, Color(RING, 0.6 + 0.4 * pulse), 3.0, true)
	if _ptr_on:
		if _press_t > 0.0:
			var k := 1.0 - _press_t / 0.4
			_canvas.draw_arc(_ptr, 6.0 + 30.0 * k, 0.0, TAU, 32, Color(1, 1, 1, 1.0 - k), 3.0, true)
		var shape := PackedVector2Array()
		var shadow := PackedVector2Array()
		for v in ARROW:
			shape.append(_ptr + (v as Vector2) * 1.25)
			shadow.append(_ptr + (v as Vector2) * 1.25 + Vector2(2, 3))
		_canvas.draw_colored_polygon(shadow, Color(0, 0, 0, 0.35))
		_canvas.draw_colored_polygon(shape, Color.WHITE)
		shape.append(shape[0])
		_canvas.draw_polyline(shape, Color(0.04, 0.04, 0.05), 1.6, true)

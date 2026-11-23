extends Control
## The colony on screen: a bar along the top (the mode, the crew, the day, how many days of food are in store, the score), the
## choice of difficulty and of the crew's voice when a game starts, the ending when the colony succeeds or fails (what happened to the
## crew, the score and what it is made of, a name for the leaderboard), and the leaderboard itself. The rules and the score are in
## the C++ core (core/colony.hpp, read through FarmBay.get_colony()); this script only shows them and asks the player.
##
## It works with any scene shaped like greenhouse.gd and dome.gd (a `bay`, `voice`, `set_speed()`, optionally `colony_tuning` and
## `colony_place`). Add it to the HUD last, so its overlays are above everything:
##
##   var colony_ui = ColonyUI.new()           # const ColonyUI = preload("res://scripts/colony_ui.gd")
##   hud_root.add_child(colony_ui)
##   colony_ui.setup(self, hud_palette, ask_difficulty)
##
## With `ask` the difficulty picker opens at once and the clock waits for it; without, the bay is a sandbox (no colony) until
## `choose()` or the New colony button starts one. "Play again" reloads the scene and starts the same difficulty without asking.

const Leaderboard = preload("res://scripts/leaderboard.gd")
const Prefs = preload("res://scripts/prefs.gd")

signal colony_started(difficulty: int)
signal colony_ended(outcome: int)

const NAMES := ["Easy", "Intermediate", "Difficult"]
const SITUATIONS := [
	"Earth is safe. If the food runs out, the whole crew is evacuated home and the colony fails.",
	"Earth is damaged. If the food runs out, an evacuation can carry only half the crew home. The rest are lost.",
	"Earth cannot be lived on. If the food runs out there is nowhere to go: the colony is extinct.",
]
const WARN_DAYS := 20.0          # the crew warns when the food in store falls below this many days
const START_SPEED := 4.0         # game hours per second once a colony starts
const REFRESH_S := 0.25

var scene: Node
var palette := {}
var difficulty := -1             # the colony's difficulty, or -1 for a sandbox
var phase := "sandbox"           # "sandbox", "picker", "playing", "ending" or "board"
var restart: Callable            # what Play again and Change difficulty do: reload the scene (the tests replace it)
var open_training: Callable      # what How to play does
var result := {}                 # the colony when it ended: get_colony() as it was
var rank := 0                    # where the saved score landed on the table (0: not saved, or not on the table)
var saved := false

var _t := 0.0
var _accent := Color("e8861f")
var _panel_col := Color(0.075, 0.08, 0.09, 0.92)
var _text_col := Color("e6e8eb")
var _muted := Color(0.8, 0.8, 0.8, 0.65)
var _bar: MarginContainer
var _mode_label: Label
var _food_box: HBoxContainer
var _food_bar: ProgressBar
var _food_fill: StyleBoxFlat
var _food_value: Label
var _score_label: Label
var _btn_new: Button
var _btn_voice: Button
var _btn_board: Button
var _picker: Control
var _picker_voice_row: HBoxContainer
var _ending: Control
var _ending_box: VBoxContainer
var _name_edit: LineEdit
var _board: Control
var _board_box: VBoxContainer
var _board_tab := 0
var _board_from := "picker"      # where Close goes back to
var _speed_before := START_SPEED

func setup(p_scene: Node, p_palette: Dictionary, ask: bool) -> void:
	scene = p_scene
	palette = p_palette
	name = "ColonyUI"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)      # (anchors alone would leave it zero-sized: it is added to a tree that is already laid out)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_accent = palette.get("accent", _accent)
	_panel_col = Color(palette.get("panel", _panel_col), 0.94)
	_text_col = palette.get("text", _text_col)
	_muted = Color(_text_col, 0.62)
	restart = func(): scene.get_tree().reload_current_scene()
	open_training = func(): scene.get_tree().change_scene_to_file(str(scene.get("TRAINING_SCENE")))
	_build_bar()
	scene.bay.colony_outcome.connect(_on_outcome)
	_refresh_bar()
	if Engine.has_meta("colony_start"):                            # "Play again" reloaded the scene on purpose
		var next := int(Engine.get_meta("colony_start"))
		Engine.remove_meta("colony_start")
		choose(next, false)
	elif ask:
		show_picker()

func _process(delta: float) -> void:
	_t += delta
	if _t >= REFRESH_S:
		_t = 0.0
		_refresh_bar()

# ---------------------------------------------------------------------------------------------------------
# small builders
# ---------------------------------------------------------------------------------------------------------

func _label(text: String, size := 14, colour := Color.WHITE, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour if colour != Color.WHITE else _text_col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(callback)
	return b

func _frame_style(margin := 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _panel_col
	sb.border_color = _accent
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(margin)
	return sb

# A full-screen overlay that dims the game, takes every click, and holds one centred panel. Returns the panel's VBox.
func _overlay(overlay_name: String, width: float) -> Array:
	var root := Control.new()
	root.name = overlay_name
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", _frame_style(18))
	centre.add_child(frame)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(width, 0)
	box.add_theme_constant_override("separation", 10)
	frame.add_child(box)
	add_child(root)
	return [root, box]

func _clear(box: Control) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()

func _n(v: float) -> String:          # 12345 -> "12,345"
	var s := str(int(roundf(absf(v))))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if v < 0.0 else "") + out

func _voice() -> Node:
	return scene.voice

func _say(text: String, key: String) -> void:
	if scene.voice != null:
		scene.voice.say(text, key)

# ---------------------------------------------------------------------------------------------------------
# the bar along the top
# ---------------------------------------------------------------------------------------------------------

func _build_bar() -> void:
	_bar = MarginContainer.new()
	_bar.name = "ColonyBar"
	_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bar.add_theme_constant_override("margin_top", 14)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _frame_style(8))
	_bar.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	_mode_label = _label("", 14, _accent)
	row.add_child(_mode_label)
	_food_box = HBoxContainer.new()
	_food_box.add_theme_constant_override("separation", 6)
	_food_box.add_child(_label("Food", 13, _muted))
	_food_bar = ProgressBar.new()
	_food_bar.custom_minimum_size = Vector2(110, 14)
	_food_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_food_bar.show_percentage = false
	_food_bar.max_value = 60.0
	_food_fill = StyleBoxFlat.new()
	_food_fill.bg_color = Color("7bd35a")
	_food_fill.set_corner_radius_all(3)
	_food_bar.add_theme_stylebox_override("fill", _food_fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.11, 0.12, 0.14, 0.9)
	back.set_corner_radius_all(3)
	_food_bar.add_theme_stylebox_override("background", back)
	_food_box.add_child(_food_bar)
	_food_value = _label("", 13)
	_food_box.add_child(_food_value)
	row.add_child(_food_box)
	_score_label = _label("", 14)
	row.add_child(_score_label)
	_btn_new = _button("New colony", show_picker)
	row.add_child(_btn_new)
	_btn_voice = _button("", toggle_voice)
	row.add_child(_btn_voice)
	_btn_board = _button("Leaderboard", func(): show_board())
	row.add_child(_btn_board)

func _refresh_bar() -> void:
	if scene == null or _bar == null:
		return
	var c: Dictionary = scene.bay.get_colony()
	var started: bool = c["started"]
	var running: bool = c["running"]
	_bar.visible = phase != "picker"                      # the picker has the screen to itself
	_food_box.visible = running
	_score_label.visible = started
	_btn_new.visible = not running
	if not started:
		_mode_label.text = "SANDBOX  ·  no colony to feed"
	elif running:
		_mode_label.text = "%s  ·  Crew %d  ·  Day %d / %d" % [str(c["difficulty_name"]).to_upper(), c["crew"], int(c["day"]) + 1, int(c["goal_days"])]
		var reserve: float = c["reserve_days"]
		_food_bar.value = reserve
		_food_value.text = "%d days" % int(ceilf(reserve)) if not c["starving"] else "EMPTY: %d of %d days" % [int(c["hunger_days"]) + 1, int(c["grace_days"])]
		_food_fill.bg_color = Color("c4472f") if c["starving"] or reserve < 7.0 else (Color("e8a33d") if reserve < WARN_DAYS else Color("7bd35a"))
	else:
		_mode_label.text = "%s  ·  %s" % [str(c["difficulty_name"]).to_upper(), _outcome_short(int(c["outcome"]))]
	if started:
		_score_label.text = "Score %s" % _n(float(c["score"]))
	_refresh_voice_button()

func _outcome_short(outcome: int) -> String:
	match outcome:
		FarmBay.OUTCOME_SUCCESS: return "colony established"
		FarmBay.OUTCOME_EVACUATED: return "evacuated"
		FarmBay.OUTCOME_EVACUATED_WITH_LOSSES: return "partial evacuation"
		FarmBay.OUTCOME_EXTINCT: return "extinct"
	return ""

# ---------------------------------------------------------------------------------------------------------
# the crew's voice: male or female, when this PC has both
# ---------------------------------------------------------------------------------------------------------

func _refresh_voice_button() -> void:
	var v := _voice()
	var offered: Array = v.available_genders() if v != null else []
	_btn_voice.visible = offered.size() > 1
	if _btn_voice.visible:
		_btn_voice.text = "Voice: %s" % str(v.gender).capitalize()
		_btn_voice.tooltip_text = "Switch the crew's voice (%s)" % v.voice_name("female" if v.gender == "male" else "male")

# Swap to the other voice, if there is one.
func toggle_voice() -> void:
	var v := _voice()
	if v == null:
		return
	choose_voice("female" if v.gender == "male" else "male")

# Pick the crew's voice: "male" or "female". False when this PC has no such voice.
func choose_voice(gender: String) -> bool:
	var v := _voice()
	if v == null or not v.set_gender(gender):
		return false
	_refresh_voice_button()
	_refresh_picker_voice()
	return true

# ---------------------------------------------------------------------------------------------------------
# choosing a difficulty
# ---------------------------------------------------------------------------------------------------------

func show_picker() -> void:
	if _picker == null:
		_build_picker()
	if phase == "playing" or phase == "sandbox":
		_speed_before = maxf(float(scene.bay.time_scale), START_SPEED if phase == "sandbox" else 1.0)
	scene.set_speed(0.0)
	phase = "picker"
	_refresh_picker_voice()
	_picker.visible = true
	_refresh_bar()

func _build_picker() -> void:
	var made := _overlay("ColonyPicker", 960.0)
	_picker = made[0]
	var box: VBoxContainer = made[1]
	box.add_child(_label("CHOOSE YOUR COLONY'S SITUATION", 22, _accent))
	box.add_child(_label("Keep the crew fed from this bay. The mode sets how much food the colony needs, how long you have to last, and what happens if the food runs out. Your score goes on the leaderboard.", 14, _text_col, true))
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 12)
	box.add_child(cards)
	var last := int(Prefs.read("colony", "difficulty", 0))
	for d in 3:
		var r: Dictionary = FarmBay.get_difficulty_rules(d)
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", _frame_style(12))
		cards.add_child(card)
		var cb := VBoxContainer.new()
		cb.add_theme_constant_override("separation", 6)
		card.add_child(cb)
		cb.add_child(_label(str(r["name"]).to_upper(), 20, _accent))
		cb.add_child(_label(SITUATIONS[d], 14, _text_col, true))
		var facts := "Crew of %d\nKeep them fed for %d days\nThe colony fails after %d hungry days\nScore x%s" % [r["crew"], int(r["goal_days"]), int(r["grace_days"]), str(r["score_multiplier"])]
		var f := _label(facts, 13, _muted)
		f.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cb.add_child(f)
		var play := _button("Play %s" % r["name"], func(): choose(d))
		play.name = "Play%s" % r["name"]
		if d == last:
			play.text += "  (last played)"
		cb.add_child(play)
	_picker_voice_row = HBoxContainer.new()
	_picker_voice_row.add_theme_constant_override("separation", 8)
	box.add_child(_picker_voice_row)
	var extras := HBoxContainer.new()
	extras.add_theme_constant_override("separation", 8)
	box.add_child(extras)
	extras.add_child(_button("Leaderboard", func(): show_board(-1, 0, "picker")))
	extras.add_child(_button("How to play", func(): open_training.call()))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	extras.add_child(spacer)
	extras.add_child(_button("Sandbox: no colony", choose_sandbox))

func _refresh_picker_voice() -> void:
	if _picker_voice_row == null:
		return
	_clear(_picker_voice_row)
	var v := _voice()
	var offered: Array = v.available_genders() if v != null else []
	_picker_voice_row.add_child(_label("Crew voice", 14, _accent))
	if offered.is_empty():
		_picker_voice_row.add_child(_label("No speech voice was found on this PC: the crew will use captions only.", 13, _muted))
		return
	var group := ButtonGroup.new()
	for g in ["male", "female"]:
		var b := Button.new()
		b.name = "Voice%s" % str(g).capitalize()
		b.text = "%s voice" % str(g).capitalize()
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = not offered.has(g)
		b.button_pressed = v.gender == g
		b.tooltip_text = v.voice_name(g) if offered.has(g) else "No %s voice is installed on this PC" % g
		b.pressed.connect(func(): choose_voice(g))
		_picker_voice_row.add_child(b)
	if offered.size() == 1:
		_picker_voice_row.add_child(_label("(this PC has only a %s voice)" % offered[0], 13, _muted))

# Start a colony on a difficulty (0 Easy, 1 Intermediate, 2 Difficult): the picker closes and the clock runs.
func choose(d: int, announce := true) -> void:
	d = clampi(d, 0, 2)
	difficulty = d
	var tuning: Dictionary = {}
	if scene.get("colony_tuning") != null:
		tuning = scene.colony_tuning
	var demand: Array = tuning.get("demand", [1.0, 1.0, 1.0])
	var reserve: Array = tuning.get("reserve", [1.0, 1.0, 1.0])
	scene.bay.start_colony(d, float(demand[d]), float(reserve[d]))
	Prefs.write("colony", "difficulty", d)
	if _picker != null:
		_picker.visible = false
	if _ending != null:
		_ending.visible = false
	if _board != null:
		_board.visible = false
	phase = "playing"
	result = {}
	saved = false
	rank = 0
	scene.set_speed(START_SPEED)
	_refresh_bar()
	if announce:
		var r: Dictionary = FarmBay.get_difficulty_rules(d)
		_say("Colony established. We are %d, and the farm has to feed us for %d days. %s" % [r["crew"], int(r["goal_days"]), SITUATIONS[d]], "colony_start")
	colony_started.emit(d)

# No colony: just farm, as the game did before it had one.
func choose_sandbox() -> void:
	scene.bay.stop_colony()
	difficulty = -1
	if _picker != null:
		_picker.visible = false
	phase = "sandbox"
	scene.set_speed(START_SPEED)
	_refresh_bar()

# ---------------------------------------------------------------------------------------------------------
# the ending
# ---------------------------------------------------------------------------------------------------------

func _on_outcome(outcome: int) -> void:
	result = scene.bay.get_colony().duplicate(true)
	scene.set_speed(0.0)
	phase = "ending"
	saved = false
	rank = 0
	_show_ending()
	_say(_voice_line(), "colony_end")
	colony_ended.emit(outcome)

func _place() -> String:
	return str(scene.get("colony_place")) if scene.get("colony_place") != null else "station"

func _fill(text: String) -> String:
	return text.format({"place": _place(), "crew": result.get("crew", 0), "survivors": result.get("survivors", 0),
			"lost": int(result.get("crew", 0)) - int(result.get("survivors", 0)), "goal": int(result.get("goal_days", 0)), "day": int(result.get("day", 0.0))})

func _title_text() -> String:
	match int(result.get("outcome", 0)):
		FarmBay.OUTCOME_SUCCESS: return "COLONY ESTABLISHED"
		FarmBay.OUTCOME_EVACUATED: return "EVACUATED: THE COLONY HAS FAILED"
		FarmBay.OUTCOME_EVACUATED_WITH_LOSSES: return "PARTIAL EVACUATION: THE COLONY HAS FAILED"
	return "EXTINCTION"

func _story_text() -> String:
	match int(result.get("outcome", 0)):
		FarmBay.OUTCOME_SUCCESS:
			return _fill("The farm kept all {crew} colonists fed for {goal} days. The {place} no longer depends on supplies from home: the colony is established.")
		FarmBay.OUTCOME_EVACUATED:
			return _fill("The food ran out on day {day}. Earth is safe, so mission control ordered the {place} evacuated and all {crew} colonists were brought home. They are alive, but the colony has failed.")
		FarmBay.OUTCOME_EVACUATED_WITH_LOSSES:
			return _fill("The food ran out on day {day}. Earth is damaged and could take back only {survivors} of the {crew} colonists. The other {lost} were left behind. The colony has failed.")
	return _fill("The food ran out on day {day}. Earth can no longer be lived on, so there was nowhere to go. None of the {crew} colonists survived. The colony is extinct.")

func _voice_line() -> String:
	match int(result.get("outcome", 0)):
		FarmBay.OUTCOME_SUCCESS: return _fill("The colony is established. The farm kept all {crew} of us fed for {goal} days.")
		FarmBay.OUTCOME_EVACUATED: return _fill("The food has run out. We are being evacuated home. The colony has failed.")
		FarmBay.OUTCOME_EVACUATED_WITH_LOSSES: return _fill("The food has run out. Earth can take only {survivors} of us home. The colony has failed.")
	return "The food has run out, and there is nowhere to go. The colony is extinct."

func _show_ending() -> void:
	if _ending == null:
		var made := _overlay("ColonyEnding", 760.0)
		_ending = made[0]
		_ending_box = made[1]
	_clear(_ending_box)
	var success: bool = int(result.get("outcome", 0)) == FarmBay.OUTCOME_SUCCESS
	_ending_box.add_child(_label(_title_text(), 22, Color("8fd68a") if success else Color("e07a5f")))
	_ending_box.add_child(_label(_story_text(), 15, _text_col, true))
	var facts := "%s  ·  Survivors %d of %d  ·  Day %d" % [str(result.get("difficulty_name", "")), int(result.get("survivors", 0)), int(result.get("crew", 0)), int(result.get("day", 0.0))]
	_ending_box.add_child(_label(facts, 13, _muted))
	var parts: Dictionary = result.get("score_parts", {})
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 2)
	_ending_box.add_child(grid)
	var rows := [
		["Days lasted (%d)" % int(result.get("day", 0.0)), parts.get("days", 0.0), 1],
		["Food grown (%d kcal)" % int(result.get("harvested_kcal", 0.0)), parts.get("food", 0.0), 1],
		["Crops grown (%d of 4)" % int(result.get("crops_grown", 0)), parts.get("variety", 0.0), 1],
		["Food left in store (%d days)" % int(result.get("reserve_days", 0.0)), parts.get("reserve", 0.0), 1],
		["Plants lost (%d)" % int(result.get("plants_lost", 0)), parts.get("lost", 0.0), -1],
		["Hungry days (%.1f)" % float(result.get("hungry_days_total", 0.0)), parts.get("hunger", 0.0), -1],
		["Colony established", parts.get("bonus", 0.0), 1],
		["%s difficulty" % str(result.get("difficulty_name", "")), parts.get("multiplier", 1.0), 0],
	]
	for row in rows:
		var kind: int = row[2]
		if kind != 0 and absf(float(row[1])) < 0.5 and not (str(row[0]).begins_with("Days") or str(row[0]).begins_with("Food grown")):
			continue
		grid.add_child(_label(str(row[0]), 14, _muted))
		var v := _label(("x%s" % str(row[1])) if kind == 0 else ("%s%s" % ["-" if kind < 0 else "+", _n(float(row[1]))]), 14)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(v)
	var total := _label("SCORE  %s" % _n(float(result.get("score", 0))), 24, _accent)
	total.name = "Total"
	_ending_box.add_child(total)
	# a name for the leaderboard
	var qualifies := Leaderboard.qualifies(int(result.get("difficulty", 0)), int(result.get("score", 0)))
	var entry := HBoxContainer.new()
	entry.name = "Entry"
	entry.add_theme_constant_override("separation", 8)
	_ending_box.add_child(entry)
	if qualifies:
		entry.add_child(_label("Your name", 14, _muted))
		_name_edit = LineEdit.new()
		_name_edit.max_length = Leaderboard.NAME_MAX
		_name_edit.text = str(Prefs.read("player", "name", Leaderboard.DEFAULT_NAME))
		_name_edit.custom_minimum_size = Vector2(220, 0)
		_name_edit.text_submitted.connect(func(t): submit_score(t))
		entry.add_child(_name_edit)
		entry.add_child(_button("Save score", func(): submit_score(_name_edit.text)))
	else:
		entry.add_child(_label("This score is not high enough for the leaderboard." if int(result.get("score", 0)) > 0 else "No score to save.", 13, _muted))
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	_ending_box.add_child(buttons)
	buttons.add_child(_button("Play %s again" % str(result.get("difficulty_name", "")), play_again))
	buttons.add_child(_button("Change difficulty", change_difficulty))
	buttons.add_child(_button("Leaderboard", func(): show_board(int(result.get("difficulty", 0)), rank, "ending")))
	buttons.add_child(_button("Keep playing", keep_playing))
	_ending.visible = true

# Put the finished run on the leaderboard under `player_name`. Returns its rank (0: not on the table).
func submit_score(player_name: String) -> int:
	if saved or result.is_empty():
		return rank
	var clean := Leaderboard.clean_name(player_name)
	rank = Leaderboard.submit({"name": clean, "score": int(result["score"]), "difficulty": int(result["difficulty"]),
			"outcome": str(result["outcome_name"]), "day": float(result["day"])})
	saved = true
	Prefs.write("player", "name", clean)
	var entry := _ending_box.get_node_or_null("Entry")
	if entry != null:
		_clear(entry)
		entry.add_child(_label(("Saved as %s: number %d on the %s table." % [clean, rank, str(result["difficulty_name"])]) if rank > 0 else "Could not save the score.", 14, Color("8fd68a") if rank > 0 else Color("e07a5f")))
	show_board(int(result["difficulty"]), rank, "ending")
	return rank

func play_again() -> void:
	Engine.set_meta("colony_start", int(result.get("difficulty", maxi(difficulty, 0))))
	restart.call()

func change_difficulty() -> void:
	if Engine.has_meta("colony_start"):
		Engine.remove_meta("colony_start")
	restart.call()

# Carry on farming in the same bay after the ending: the colony stays ended and the clock runs again.
func keep_playing() -> void:
	if _ending != null:
		_ending.visible = false
	phase = "sandbox"
	scene.set_speed(START_SPEED)

# ---------------------------------------------------------------------------------------------------------
# the leaderboard
# ---------------------------------------------------------------------------------------------------------

# Show the table of a difficulty (-1: the one last played, or Easy). `highlight` is a rank to mark as the player's own, `from` where
# Close returns to ("picker", "ending" or "game").
func show_board(d := -1, highlight := 0, from := "game") -> void:
	if _board == null:
		var made := _overlay("Leaderboard", 640.0)
		_board = made[0]
		_board_box = made[1]
	_board_from = from if from != "game" or phase == "picker" or phase == "ending" else "game"
	if from == "game" and phase == "picker":
		_board_from = "picker"
	elif from == "game" and phase == "ending":
		_board_from = "ending"
	_board_tab = clampi(d if d >= 0 else (difficulty if difficulty >= 0 else int(Prefs.read("colony", "difficulty", 0))), 0, 2)
	_draw_board(highlight)
	if _picker != null and from == "picker":
		_picker.visible = false
	if _ending != null and from == "ending":
		_ending.visible = false
	if _board_from == "game" and phase == "playing":
		_speed_before = maxf(float(scene.bay.time_scale), 1.0)
		scene.set_speed(0.0)
	_board.visible = true

func _draw_board(highlight: int) -> void:
	_clear(_board_box)
	_board_box.add_child(_label("LEADERBOARD", 22, _accent))
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_board_box.add_child(tabs)
	var group := ButtonGroup.new()
	for d in 3:
		var b := Button.new()
		b.name = "Tab%s" % NAMES[d]
		b.text = NAMES[d]
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = d == _board_tab
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func():
			_board_tab = d
			_draw_board(0))
		tabs.add_child(b)
	var table := Leaderboard.entries(_board_tab)
	if table.is_empty():
		_board_box.add_child(_label("No runs yet. Be the first to put a score here.", 14, _muted))
	else:
		var grid := GridContainer.new()
		grid.columns = 5
		grid.add_theme_constant_override("h_separation", 22)
		grid.add_theme_constant_override("v_separation", 3)
		_board_box.add_child(grid)
		for h in ["#", "Name", "Score", "Result", "Day"]:
			grid.add_child(_label(h, 13, _muted))
		for i in table.size():
			var e: Dictionary = table[i]
			var own := highlight > 0 and i + 1 == highlight
			var colour := _accent if own else _text_col
			var result_text: String = str({"success": "Colony established", "evacuated": "Evacuated", "evacuated_with_losses": "Partial evacuation", "extinct": "Extinct"}.get(str(e.get("outcome", "")), str(e.get("outcome", ""))))
			grid.add_child(_label(str(i + 1), 14, colour))
			grid.add_child(_label(str(e.get("name", "")), 14, colour))
			var score := _label(_n(float(e.get("score", 0))), 14, colour)
			score.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			grid.add_child(score)
			grid.add_child(_label(result_text, 14, colour))
			grid.add_child(_label(str(int(float(e.get("day", 0.0)))), 14, colour))
	_board_box.add_child(_label("Saved on this PC only: nothing is sent anywhere.", 12, _muted))
	_board_box.add_child(_button("Close", close_board))

func close_board() -> void:
	if _board != null:
		_board.visible = false
	match _board_from:
		"picker":
			if _picker != null:
				_picker.visible = true
		"ending":
			if _ending != null:
				_ending.visible = true
		_:
			if phase == "playing":
				scene.set_speed(_speed_before)

# ---------------------------------------------------------------------------------------------------------
# what the crew says about the colony (the scene hands these to the crew voice)
# ---------------------------------------------------------------------------------------------------------

# Cannot wait: the crew has no food and the colony is counting down.
func urgent_notes() -> Array:
	var c: Dictionary = scene.bay.get_colony()
	if c["running"] and c["starving"]:
		var left := maxi(1, int(ceilf(float(c["grace_days"]) - float(c["hunger_days"]))))
		return [{"key": "colony_hunger", "text": "The crew is out of food. In %d days the colony fails. Harvest whatever is ready, and sow quick crops like lettuce." % left}]
	return []

# Worth saying when nothing is more pressing: the food in store is running low.
func voice_notes() -> Array:
	var c: Dictionary = scene.bay.get_colony()
	if c["running"] and not c["starving"] and float(c["reserve_days"]) < WARN_DAYS:
		return [{"key": "colony_low", "text": "The food in store is down to %d days. Harvest what is ready, and keep every bed sown." % int(ceilf(float(c["reserve_days"])))}]
	return []

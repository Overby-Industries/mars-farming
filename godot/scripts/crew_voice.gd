extends Node
## The crew member's voice: it says what needs doing next, and describes the plants and the state of the growing medium.
##
## What it says, and when:
##  - NEXT STEPS, unasked, when it has been quiet for a while: a plant is ready (press Harvest), a plant has died (Clear), a
##    bed is dry (Water) or short of nutrients (Feed), the water tank or the nutrient stock is low, empty slots are waiting
##    for seeds, and, when all is well, a round of the plants: how far along they are and how the medium is doing. A scene may
##    add its own notes with a `voice_notes()` method (the dome warns of dust storms, the station of the power budget).
##  - NEWS, as it happens: a crop sprouts, flowers or sets fruit, a plant dies, a harvest or a watering is done.
##  - DESCRIPTIONS of whatever the player selects: the crop, its stage, its health, the moisture and nutrients of the bed.
##  - ANSWERS: `ask()` (the "Ask crew" button) gives the most useful thing right now, whatever it said a moment ago.
## The same advice is not repeated for REPEAT_S seconds and nothing spontaneous comes within GAP_S of the last line, so it
## does not chatter. Every line is captioned on screen and the astronaut turns its head to look at what the line is about.
##
## Speech is the operating system's text-to-speech through DisplayServer (voices the PC already has; nothing is shipped), so it
## needs `audio/general/text_to_speech` on in project.godot. Without voices (or headless) the captions still appear. `audio`
## switches the speech, `enabled` switches the whole thing (what the tests and the screenshot scripts use).
##
##   var voice = CrewVoice.new()                   # const CrewVoice = preload("res://scripts/crew_voice.gd")
##   add_child(voice)
##   voice.setup(self, astronaut, hud_root, {"accent": Color("e8861f")})       # the scene: a bay, BED_CENTERS, selected ...

const SlotButtons = preload("res://scripts/slot_buttons.gd")

signal said(text: String, key: String)
signal asked                      # the player pressed Ask crew

const GAP_S := 7.0         # quiet seconds after a line before the next spontaneous one
const THINK_S := 1.5       # how often it looks around for something worth saying
const REPEAT_S := 80.0     # the same advice is not given again within this many seconds
const STATUS_S := 40.0     # ... nor the round of the plants
const READ_CPS := 15.0     # characters per second a line is given to be spoken, for its caption and its pauses

var enabled := true        # off: it says and shows nothing
var spontaneous := true    # off: it speaks only when spoken to (a selection, Ask crew) or told to (say()); the training scene uses this
var describe_selection := true      # off: selecting a slot is not described (the training scene holds it back until its Select lesson)
var audio := true          # spoken aloud (text-to-speech); off leaves the captions
var volume := 80           # 0 to 100
var pitch := 0.95
var rate := 1.0
var medium := "growing medium"      # what the beds are filled with ("regolith" in the dome)
var reservoir := "water tank"       # what holds the water ("ice-melt reserve" in the dome)
var intro := "Good to see you. Pick a slot and I will tell you about it, or press Ask crew for what to do next. New here? Press How to play."

var lines: Array = []      # everything said, in order: {"t": seconds, "key": String, "text": String}
var speaking := false

var scene: Node
var astronaut: Node3D

var _clock := 0.0
var _think := 1.0
var _quiet_until := 0.0
var _end_at := 0.0
var _said := {}            # key -> the clock when it was last said
var _last_selected := Vector2i(-1, -1)
var _tour := 0
var _intro_done := false
var _news: Array = []      # things that happened and are worth a line: {"key", "text", "target", "t"}
var _species_by_key := {}
var _tts := false
var _voice_id := ""
var _caption_box: Control
var _caption_label: Label
var _caption_left := 0.0

func setup(p_scene: Node, p_astronaut: Node3D, hud_root: Control, palette := {}) -> void:
	scene = p_scene
	astronaut = p_astronaut
	name = "CrewVoice"
	for sp in scene.bay.get_species_list():
		_species_by_key[sp["key"]] = sp
	scene.bay.plant_stage_changed.connect(_on_stage)
	scene.bay.plant_died.connect(_on_died)
	_tts = DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH) and DisplayServer.tts_get_voices().size() > 0
	if _tts:
		var english := DisplayServer.tts_get_voices_for_language("en")
		_voice_id = english[0] if english.size() > 0 else DisplayServer.tts_get_voices()[0]["id"]
	_build_caption(hud_root, palette)

func _process(delta: float) -> void:
	tick(delta)

func set_audio(on: bool) -> void:
	audio = on
	if not on and _tts:
		DisplayServer.tts_stop()

# ---------------------------------------------------------------------------------------------------------
# when to speak
# ---------------------------------------------------------------------------------------------------------

# Is a line still being said (or its pause not over)? Unlike `speaking`, which is brought up to date once a tick, this is always right.
func is_busy() -> bool:
	return _clock < _end_at or (_tts and audio and DisplayServer.tts_is_speaking())

# Advance the voice by `delta` seconds (the tests call this directly with the clock they want).
func tick(delta: float) -> void:
	_clock += delta
	speaking = _clock < _end_at or (_tts and audio and DisplayServer.tts_is_speaking())
	if _caption_left > 0.0:
		_caption_left -= delta
		_caption_box.modulate.a = clampf(_caption_left / 0.6, 0.0, 1.0)
		if _caption_left <= 0.0:
			_caption_box.visible = false
	if not enabled or scene == null:
		return
	# the player picked a slot: describe it
	if scene.selected != _last_selected:
		_last_selected = scene.selected
		if scene.selected.x >= 0 and describe_selection:
			say(describe_slot(scene.selected.x, scene.selected.y), "describe", slot_point(scene.selected.x, scene.selected.y))
	if not spontaneous:
		return
	_think -= delta
	if _think > 0.0:
		return
	_think = THINK_S
	if not _intro_done and _clock > 1.0:
		_intro_done = true
		say(intro, "intro")
		return
	if speaking or _clock < _quiet_until:
		return
	var adv := advice()
	if not adv.is_empty():
		say(adv["text"], adv["key"], adv.get("target", Vector3.INF))

# Say a line: caption it, speak it, and have the astronaut look at `target` (a world point) while it does. `show_caption` off is for
# a line the scene shows in its own words on screen (the training panel).
func say(text: String, key := "", target := Vector3.INF, show_caption := true) -> void:
	if not enabled or text.is_empty():
		return
	_said[key] = _clock
	lines.append({"t": _clock, "key": key, "text": text})
	_end_at = _clock + text.length() / READ_CPS + 0.8
	_quiet_until = _end_at + GAP_S
	if show_caption:
		_caption_label.text = text
		_caption_box.visible = true
		_caption_box.modulate.a = 1.0
		_caption_left = _end_at - _clock + 1.8
	else:
		_caption_box.visible = false
		_caption_left = 0.0
	if audio and _tts:
		DisplayServer.tts_speak(text, _voice_id, volume, pitch, rate, 0, true)
	if astronaut != null and target != Vector3.INF and astronaut.has_method("look_at_point"):
		astronaut.look_at_point(target, _end_at - _clock + 1.5)
	said.emit(text, key)

# The "Ask crew" button: the most useful thing to say right now, ignoring what it said a moment ago.
func ask() -> void:
	asked.emit()
	var adv := advice(true)
	if adv.is_empty():
		adv = status_line()
	if adv.is_empty():
		adv = {"key": "ask", "text": "Nothing is growing yet and nothing needs me. Pick a crop in the panel, then sow a slot or a whole bed."}
	say(adv["text"], adv["key"], adv.get("target", Vector3.INF))

# ---------------------------------------------------------------------------------------------------------
# what to say
# ---------------------------------------------------------------------------------------------------------

func slot_point(bed: int, slot: int) -> Vector3:
	return scene.BED_CENTERS[bed] + scene._slot_offsets[slot] + Vector3(0, 0.3, 0)

func _name_of(p: Dictionary) -> String:
	return str(p["name"]).to_lower()

func _due(key: String, every: float, ignore: bool) -> bool:
	return ignore or _clock - float(_said.get(key, -1.0e9)) >= every

static func moisture_word(share: float) -> String:
	if share < 0.2:
		return "bone dry"
	if share < SlotButtons.NEED:
		return "dry"
	if share < 0.7:
		return "damp"
	if share < 0.9:
		return "moist"
	return "saturated"

static func nutrient_word(share: float) -> String:
	if share < 0.2:
		return "exhausted"
	if share < SlotButtons.NEED:
		return "running thin"
	if share < 0.8:
		return "good"
	return "rich"

static func health_word(h: float) -> String:
	if h > 0.85:
		return "healthy"
	if h > 0.6:
		return "a little stressed"
	if h > 0.3:
		return "stressed"
	return "failing"

static func stage_phrase(stage: int) -> String:
	match stage:
		FarmBay.STAGE_SEED: return "a seed in the medium, not up yet"
		FarmBay.STAGE_SPROUT: return "sprouting"
		FarmBay.STAGE_VEGETATIVE: return "putting on leaves"
		FarmBay.STAGE_FLOWERING: return "flowering"
		FarmBay.STAGE_FRUITING: return "setting fruit"
		FarmBay.STAGE_READY: return "ready to harvest"
		FarmBay.STAGE_OVERRIPE: return "overripe, so harvest it soon"
	return "dead"

func _bed_state(bed: int) -> Dictionary:
	var info: Dictionary = scene.bay.get_bed_info(bed)
	var water: float = info["water_l"] / maxf(info["water_capacity_l"], 0.001)
	return {"water": water, "nutrient": info["nutrient"], "water_l": info["water_l"],
			"text": "The %s is %s, %d percent moisture, and the nutrients are %s." % [medium, moisture_word(water), roundi(water * 100.0), nutrient_word(info["nutrient"])]}

func _days_left(p: Dictionary) -> int:
	var sp: Dictionary = _species_by_key.get(p["species"], {})
	return maxi(1, roundi((1.0 - float(p["progress"])) * float(sp.get("days_to_mature", 30.0))))

# What the player selected, in words.
func describe_slot(bed: int, slot: int) -> String:
	var p: Dictionary = scene.bay.get_plant(bed, slot)
	var bed_state := _bed_state(bed)
	if p["empty"]:
		var crop: String = str(_species_by_key.get(scene.crop_key, {}).get("name", scene.crop_key)).to_lower()
		return "Bed %d, slot %d is empty. %s Press the plus to sow %s here, or sow the whole bed from the panel." % [bed + 1, slot + 1, bed_state["text"], crop]
	var next_step := "About %d days to go." % _days_left(p)
	match SlotButtons.state_of(scene.bay, bed, slot)["kind"]:
		"harvest": next_step = "Press Harvest."
		"clear": next_step = "Press Clear to remove it."
		"water": next_step = "It needs water: press Water."
		"feed": next_step = "It needs feeding: press Feed."
	if p["stage"] == FarmBay.STAGE_DEAD:
		return "The %s in bed %d, slot %d has died. %s" % [_name_of(p), bed + 1, slot + 1, next_step]
	return "%s in bed %d, slot %d: %s, %d percent grown, and %s. %s %s" % [str(p["name"]), bed + 1, slot + 1, stage_phrase(p["stage"]),
			roundi(float(p["progress"]) * 100.0), health_word(p["health"]), bed_state["text"], next_step]

# A round of the plants when all is well: one bed at a time.
func status_line() -> Dictionary:
	var beds: int = scene.bay.get_bed_count()
	for k in beds:
		var b := (_tour + k) % beds
		for s in scene.BED_ROWS * scene.BED_COLS:
			var p: Dictionary = scene.bay.get_plant(b, s)
			if p["empty"] or p["stage"] == FarmBay.STAGE_DEAD:
				continue
			_tour = b + 1
			return {"key": "status_%d" % b, "target": slot_point(b, s),
					"text": "In bed %d the %s is %s, %d percent grown, about %d days to harvest. %s" % [b + 1, _name_of(p), stage_phrase(p["stage"]),
							roundi(float(p["progress"]) * 100.0), _days_left(p), _bed_state(b)["text"]]}
	return {}

# The next thing worth saying, or {} when there is nothing. With `ignore` the repeat timers are ignored (for ask()).
func advice(ignore := false) -> Dictionary:
	var bay: FarmBay = scene.bay
	var slots: int = scene.BED_ROWS * scene.BED_COLS
	var ready: Array = []
	var dead: Array = []
	var dry := {}
	var hungry := {}
	var empty_by_bed := {}
	var empty := 0
	var occupied := 0
	for b in bay.get_bed_count():
		var st := _bed_state(b)
		var has_plants := false
		for s in slots:
			var p := bay.get_plant(b, s)
			if p["empty"]:
				empty += 1
				empty_by_bed[b] = int(empty_by_bed.get(b, 0)) + 1
				continue
			has_plants = true
			occupied += 1
			if p["stage"] == FarmBay.STAGE_DEAD:
				dead.append([b, s, p])
			elif p["ready"]:
				ready.append([b, s, p])
		if has_plants and st["water"] < SlotButtons.NEED:
			dry[b] = st
		if has_plants and st["nutrient"] < SlotButtons.NEED:
			hungry[b] = st
	# 1. a harvest is waiting
	if not ready.is_empty() and _due("ready", REPEAT_S * 0.6, ignore):
		var first: Array = ready[0]
		var p: Dictionary = first[2]
		var text := "The %s in bed %d, slot %d is ready. Press its Harvest button." % [_name_of(p), first[0] + 1, first[1] + 1]
		if ready.size() > 1:
			text = "%d plants are ready to harvest, starting with the %s in bed %d. Press Harvest on each." % [ready.size(), _name_of(p), first[0] + 1]
		return {"key": "ready", "text": text, "target": slot_point(first[0], first[1])}
	# 2. a plant died
	if not dead.is_empty() and _due("dead", REPEAT_S, ignore):
		var d: Array = dead[0]
		return {"key": "dead", "target": slot_point(d[0], d[1]),
				"text": "We lost the %s in bed %d, slot %d. Press Clear to take it out." % [_name_of(d[2]), d[0] + 1, d[1] + 1]}
	# 3. a bed is dry
	for b in dry:
		if _due("dry_%d" % b, REPEAT_S, ignore):
			return {"key": "dry_%d" % b, "target": slot_point(b, 0),
					"text": "Bed %d is running dry. %s Press Water on any plant in the bed." % [b + 1, dry[b]["text"]]}
	# 4. a bed is short of nutrients
	for b in hungry:
		if _due("hungry_%d" % b, REPEAT_S, ignore):
			return {"key": "hungry_%d" % b, "target": slot_point(b, 0),
					"text": "The nutrients in bed %d are %s, about %d percent. Press Feed." % [b + 1, nutrient_word(hungry[b]["nutrient"]), roundi(hungry[b]["nutrient"] * 100.0)]}
	# 5. the stores
	var status := bay.get_status()
	var tank: float = status["tank_l"] / maxf(status["tank_capacity_l"], 0.001)
	if tank < 0.25 and _due("tank", REPEAT_S, ignore):
		return {"key": "tank", "text": "The %s is down to %d percent. Water is the limit now, so go easy on the watering." % [reservoir, roundi(tank * 100.0)]}
	if status["nutrient_stock"] < 4.0 and _due("stock", REPEAT_S, ignore):
		return {"key": "stock", "text": "The nutrient stock is nearly gone: %.1f units left." % status["nutrient_stock"]}
	# 6. the scene's own notes (a dust storm, the power budget)
	if scene.has_method("voice_notes"):
		for note in scene.voice_notes():
			if _due(note["key"], REPEAT_S, ignore):
				return note
	# 7. news: a crop sprouted, flowered or set fruit
	while not _news.is_empty():
		var item: Dictionary = _news.pop_front()
		if _clock - float(item["t"]) < 90.0 and _due(item["key"], REPEAT_S, ignore):
			return item
	# 8. slots waiting for seeds
	if empty > 0 and _due("sow", REPEAT_S, ignore):
		if occupied == 0:
			var crop: String = str(_species_by_key.get(scene.crop_key, {}).get("name", scene.crop_key)).to_lower()
			return {"key": "sow", "text": "All %d slots are empty. Choose a crop in the panel, currently %s, then press the plus on a slot or sow a whole bed." % [empty, crop]}
		var bed: int = empty_by_bed.keys()[0]
		return {"key": "sow", "text": "Bed %d still has %d empty slots. Press the plus over a slot to sow it." % [bed + 1, empty_by_bed[bed]], "target": slot_point(bed, 0)}
	# 9. all is well: a round of the plants
	if occupied > 0 and _due("status", STATUS_S, ignore):
		var line := status_line()
		if not line.is_empty():
			_said["status"] = _clock
			return line
	return {}

# ---------------------------------------------------------------------------------------------------------
# what happened
# ---------------------------------------------------------------------------------------------------------

func _on_stage(bed: int, slot: int, stage: int) -> void:
	var verbs := {FarmBay.STAGE_SPROUT: "has sprouted", FarmBay.STAGE_FLOWERING: "is flowering", FarmBay.STAGE_FRUITING: "is setting fruit"}
	if not verbs.has(stage) or scene.bay.get_plant(bed, slot)["empty"]:
		return
	var key := "news_%d_%d" % [bed, stage]          # one line per bed and stage, not one per plant
	for item in _news:
		if item["key"] == key:
			return
	_news.append({"key": key, "t": _clock, "target": slot_point(bed, slot),
			"text": "The %s in bed %d %s." % [_name_of(scene.bay.get_plant(bed, slot)), bed + 1, verbs[stage]]})

func _on_died(bed: int, slot: int) -> void:
	say("We lost the %s in bed %d, slot %d. Press Clear to take it out." % [_name_of(scene.bay.get_plant(bed, slot)), bed + 1, slot + 1], "dead", slot_point(bed, slot))

# A message the scene put on screen (a harvest, a watering, a storm): the crew says it too, minus the ones it already covers.
func on_toast(text: String) -> void:
	if text.contains("is ready") or text.contains("died"):
		return
	say(text.replace(" kg", " kilograms").replace(" L)", " litres)").replace("%", " percent"), "toast")

# ---------------------------------------------------------------------------------------------------------
# the caption
# ---------------------------------------------------------------------------------------------------------

func _build_caption(parent: Control, pal: Dictionary) -> void:
	var wrap := MarginContainer.new()
	wrap.name = "CrewCaption"
	wrap.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	wrap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	wrap.add_theme_constant_override("margin_bottom", 82)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.visible = false
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = pal.get("panel", Color(0.07, 0.08, 0.09, 0.9))
	sb.border_color = pal.get("accent", Color("e8861f"))
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(9)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var tag := Label.new()
	tag.text = "CREW"
	tag.add_theme_font_size_override("font_size", 12)
	tag.add_theme_color_override("font_color", pal.get("accent", Color("e8861f")))
	_caption_label = Label.new()
	_caption_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption_label.custom_minimum_size = Vector2(560, 0)
	_caption_label.add_theme_font_size_override("font_size", 15)
	_caption_label.add_theme_color_override("font_color", pal.get("text", Color("e6e8eb")))
	row.add_child(tag)
	row.add_child(_caption_label)
	panel.add_child(row)
	wrap.add_child(panel)
	parent.add_child(wrap)
	_caption_box = wrap

extends Node3D
## The settlement seen from above: every greenhouse or dome (a "unit") the colony has, and the sites where it may build more. When
## the colony has food to spare it may expand: click a free site and build a new unit there, then click a unit to walk into it and
## farm. When the farm has out-grown the crew by a clear margin, more colonists arrive, up to what the units house. The game's own look (the station in space, the
## domes on the Martian plain) is scripts/settlement_look.gd, which differs between the two games; this script is the same in both.
##
## The units themselves are in scripts/settlement.gd; the colony's rules (when people arrive, when it may expand, what it costs) are in
## core/colony.hpp. The colony bar along the top is the same one the farm shows (scripts/colony_ui.gd).

const Settlement = preload("res://scripts/settlement.gd")
const ColonyUI = preload("res://scripts/colony_ui.gd")
const CrewVoice = preload("res://scripts/crew_voice.gd")
const Look = preload("res://scripts/settlement_look.gd")

const TRAINING_SCENE := "res://scenes/training.tscn"
const SPEEDS := [["Pause", 0.0], ["1x", 1.0], ["4x", 4.0], ["16x", 16.0], ["64x", 64.0]]
const REFRESH_S := 0.25

# what colony_ui.gd and the crew voice read of a scene
var bay: FarmBay                           # the first unit's bay: it holds the colony
var colony_bay: FarmBay
var voice: Node
var colony_ui: Control
var hud_palette := {}
var colony_place := Look.PLACE
var colony_tuning: Dictionary = Look.TUNING
var unit_noun := Look.NOUN
var ask_difficulty := false
var selected := Vector2i(-1, -1)           # (the crew voice looks for it)
var crop_key := "lettuce"

var st: Node                               # the settlement
var site := -1                             # the selected site
var world := {}                            # what the look built: its environment, its pieces
var _sites: Array = []                     # per site: {"root", "pad", "unit", "label", "body"}
var _cam: Camera3D
var _pivot: Node3D
var _yaw := 0.0
var _pitch := -0.8
var _dist := 60.0
var _orbiting := false
var _t := 0.0
var _clock := 0.0
var _toast: Label
var _toast_time := 0.0
var _info: Label
var _air_box: VBoxContainer
var _air_bar: ProgressBar
var _air_label: Label
var _card_title: Label
var _card_text: Label
var _build_btn: Button
var _enter_btn: Button
var _palette_text := Color("e6e8eb")
var _palette_accent := Color("e8861f")
var _palette_panel := Color(0.075, 0.08, 0.09, 0.88)
var _last_ready := false
var _air_override := -1.0                 # a picture of the land at some air progress, whatever the plants have done (debug_set_air)

func _ready() -> void:
	st = Settlement.peek()
	if st == null:                                   # opened on its own (a test, a picture): a settlement of one new unit
		st = Settlement.get_or_create(get_tree())
		var first: FarmBay = Look.make_bay()
		first.name = "Bay"
		st.add_child(first)
		st.adopt(first, Callable(Look, "make_bay"), Look.SITES.size())
	st.sites = Look.SITES.size()
	bay = st.primary()
	colony_bay = bay
	var look := Look.camera_start()
	_yaw = look["yaw"]
	_pitch = look["pitch"]
	_dist = look["dist"]
	world = Look.build_world(self)
	_build_sites()
	_build_camera(look["pivot"])
	_build_hud()
	st.unit_built.connect(_on_unit_built)
	_refresh_all()

# ---------------------------------------------------------------------------------------------------------
# the world: a pad or a unit on every site
# ---------------------------------------------------------------------------------------------------------

func _build_sites() -> void:
	for i in Look.SITES.size():
		var root := Node3D.new()
		root.name = "Site%d" % i
		root.position = Look.SITES[i]
		add_child(root)
		var pad := Look.make_pad(i)
		root.add_child(pad)
		var unit := Look.make_unit(i)
		unit.visible = false
		root.add_child(unit)
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.font_size = 56
		label.outline_size = 14
		label.pixel_size = 0.028
		label.modulate = Color(1, 1, 1, 0.95)
		label.position = Look.label_offset(i)
		root.add_child(label)
		var body := StaticBody3D.new()
		body.set_meta("site", i)
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = Look.pick_radius()
		shape.shape = sphere
		body.add_child(shape)
		root.add_child(body)
		_sites.append({"root": root, "pad": pad, "unit": unit, "label": label, "body": body})

func _build_camera(pivot_at: Vector3) -> void:
	_pivot = Node3D.new()
	_pivot.position = pivot_at
	add_child(_pivot)
	_cam = Camera3D.new()
	_cam.fov = 38.0
	_cam.far = 1500.0
	_pivot.add_child(_cam)
	_cam.make_current()
	_apply_camera()

func _apply_camera() -> void:
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	_cam.position = Vector3(0, 0, _dist)

# ---------------------------------------------------------------------------------------------------------
# input
# ---------------------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = clampf(_dist * 0.92, 18.0, 160.0)
			_apply_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = clampf(_dist * 1.08, 18.0, 160.0)
			_apply_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			pick(mb.position)
	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.005
		_pitch = clampf(_pitch - mm.relative.y * 0.005, -1.45, -0.35)
		_apply_camera()

# Select the site under a screen point (or none).
func pick(screen_pos: Vector2) -> void:
	var from := _cam.project_ray_origin(screen_pos)
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + _cam.project_ray_normal(screen_pos) * 1200.0))
	if hit.has("collider") and (hit["collider"] as Object).has_meta("site"):
		select_site(int((hit["collider"] as Object).get_meta("site")))
	else:
		select_site(-1)

func select_site(i: int) -> void:
	site = i
	_refresh_card()

# The screen position of a site (for the tests and the pointer).
func site_screen(i: int) -> Vector2:
	return _cam.unproject_position((_sites[i]["root"] as Node3D).global_position + Look.label_offset(i) * 0.4)

# ---------------------------------------------------------------------------------------------------------
# what is built, what may be
# ---------------------------------------------------------------------------------------------------------

func colony() -> Dictionary:
	return colony_bay.get_colony()

# What a site is now: "built", "ready" (a unit may be built here), "waiting" (not yet), or "locked" (the colony has no use for it yet).
func state_of(i: int) -> String:
	if st.unit_on(i) >= 0:
		return "built"
	var c := colony()
	if i >= int(c.get("max_units", 1)) or not bool(c.get("started", false)):
		return "locked"
	return "ready" if st.can_build(i) else "waiting"

# Why no unit may be built now, in words (an empty string when one may).
func why_not() -> String:
	var c := colony()
	if not bool(c.get("started", false)):
		return "Start a colony first: the settlement only grows when there is a crew to feed."
	if not bool(c.get("running", false)):
		return "The colony has ended."
	if st.units.size() >= int(c.get("max_units", 1)):
		return Look.locked_text(self)
	var rules := FarmBay.get_expansion_rules()
	if bool(c["starving"]):
		return "The crew is hungry: no one will build until they have eaten."
	if float(c["reserve_days"]) < float(rules["expand_min_reserve_days"]):
		return "Building eats %d days of food, and the store holds only %d: keep farming until it holds %d." % [int(rules["expansion_cost_days"]), int(c["reserve_days"]), int(rules["expand_min_reserve_days"])]
	if float(c["harvested_kcal"]) < float(rules["expand_min_harvest_days"]) * float(c["need_kcal_day"]):
		return "The farm has not grown enough yet to spare a building crew: harvest the equivalent of %d days of the crew's food first." % int(rules["expand_min_harvest_days"])
	return ""

# Build a unit on the selected site. Returns its index, or -1.
func build_here() -> int:
	if site < 0:
		return -1
	var idx: int = st.build(site)
	if idx >= 0:
		_toast_text("A new %s is built: %s" % [Look.site_noun(site), Look.unit_label(site, idx + 1)])
	_refresh_all()
	return idx

# Walk into a unit: the farm scene shows it.
func enter_unit(i: int) -> void:
	if not st.has_unit(i):
		return
	st.current = i
	get_tree().change_scene_to_file(str(ProjectSettings.get_setting("application/run/main_scene")))

func open_farm() -> void:
	enter_unit(st.current if st.has_unit(st.current) else 0)

func set_speed(hours_per_second: float) -> void:
	st.set_speed(hours_per_second)

func _on_unit_built(index: int) -> void:
	_refresh_sites()
	var node: Node3D = _sites[int(st.units[index]["site"])]["unit"]
	node.scale = Vector3.ONE * 0.05
	create_tween().tween_property(node, "scale", Vector3.ONE, 0.9).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _refresh_sites() -> void:
	for i in _sites.size():
		var s: Dictionary = _sites[i]
		var state := state_of(i)
		(s["unit"] as Node3D).visible = state == "built"
		(s["pad"] as Node3D).visible = state != "built"
		Look.set_pad_state(s["pad"], state, i == site)
		var label: Label3D = s["label"]
		match state:
			"built":
				label.text = Look.unit_label(i, st.unit_on(i) + 1)
				label.modulate = Color(1, 1, 1, 0.95)
			"ready":
				label.text = "+  BUILD HERE"
				label.modulate = Color("ffd27a")
			"waiting":
				label.text = "free site"
				label.modulate = Color(1, 1, 1, 0.55)
			_:
				label.text = "locked"
				label.modulate = Color(1, 1, 1, 0.3)

func _refresh_all() -> void:
	_refresh_sites()
	_refresh_hud()
	_refresh_card()

# ---------------------------------------------------------------------------------------------------------
# the HUD
# ---------------------------------------------------------------------------------------------------------

func _build_hud() -> void:
	hud_palette = Look.PALETTE
	_palette_accent = hud_palette["accent"]
	_palette_panel = hud_palette["panel"]
	_palette_text = hud_palette["text"]
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var theme := Theme.new()
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = {"normal": Color(0.11, 0.12, 0.14, 0.95), "hover": Color(0.20, 0.21, 0.24, 1.0), "pressed": Color(0.42, 0.27, 0.10, 1.0), "disabled": Color(0.10, 0.10, 0.11, 0.7)}[state]
		sb.bg_color = sb.bg_color.lerp(_palette_accent.darkened(0.6), 0.25 if state != "disabled" else 0.0)
		sb.border_color = _palette_accent if state != "disabled" else Color(0.38, 0.38, 0.38)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(4)
		sb.set_content_margin_all(6)
		theme.set_stylebox(state, "Button", sb)
	theme.set_color("font_color", "Button", _palette_text)
	theme.set_color("font_disabled_color", "Button", Color(0.52, 0.52, 0.52))
	root.theme = theme

	# left: the settlement
	var left := MarginContainer.new()
	left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	left.add_theme_constant_override("margin_left", 14)
	left.add_theme_constant_override("margin_top", 14)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(left)
	var lbox := _panel(left)
	lbox.custom_minimum_size = Vector2(300, 0)
	_label(lbox, Look.TITLE, 16, _palette_accent)
	_info = _label(lbox, "", 14)
	_air_box = VBoxContainer.new()
	_air_box.add_theme_constant_override("separation", 4)
	lbox.add_child(_air_box)
	_label(_air_box, "THE AIR OF MARS", 12, Color("9fd7ff"))
	_air_bar = ProgressBar.new()
	_air_bar.custom_minimum_size = Vector2(0, 14)
	_air_bar.show_percentage = false
	_air_bar.max_value = 1.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("6fc3ff")
	fill.set_corner_radius_all(3)
	_air_bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.11, 0.12, 0.14, 0.9)
	back.set_corner_radius_all(3)
	_air_bar.add_theme_stylebox_override("background", back)
	_air_box.add_child(_air_bar)
	_air_label = _label(_air_box, "", 12, Color("c9e6ff"))
	_air_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_air_label.custom_minimum_size = Vector2(280, 0)

	# right: the selected site
	var right := MarginContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right.add_theme_constant_override("margin_right", 14)
	right.add_theme_constant_override("margin_top", 14)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(right)
	var rbox := _panel(right)
	rbox.custom_minimum_size = Vector2(300, 0)
	_card_title = _label(rbox, "Nothing selected", 16, _palette_accent)
	_card_text = _label(rbox, "Click a unit to look at it, or a free site to build on it.", 13)
	_card_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_text.custom_minimum_size = Vector2(280, 0)
	_build_btn = _button(rbox, "Build here", func(): build_here())
	_enter_btn = _button(rbox, "Enter", func(): enter_unit(st.unit_on(site)))

	# bottom: the clock and the way back
	var bottom := MarginContainer.new()
	bottom.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.add_theme_constant_override("margin_bottom", 14)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	var bbox := _panel(bottom)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bbox.add_child(row)
	for sp in SPEEDS:
		var speed: float = sp[1]
		_button(row, sp[0], func(): set_speed(speed))
	row.add_child(VSeparator.new())
	_button(row, "Back to the farm", open_farm)

	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y = 120
	_toast.add_theme_font_size_override("font_size", 18)
	_toast.add_theme_color_override("font_color", _palette_accent)
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_toast.modulate.a = 0.0
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toast)

	# the crew's voice (no astronaut here) and the colony bar
	voice = CrewVoice.new()
	voice.follow_plants = false
	add_child(voice)
	voice.setup(self, null, root, hud_palette)
	voice.spontaneous = false
	voice.describe_selection = false
	voice.medium = Look.MEDIUM
	colony_ui = ColonyUI.new()
	root.add_child(colony_ui)
	colony_ui.setup(self, hud_palette, false)
	colony_ui.restart = func(): get_tree().change_scene_to_file(str(ProjectSettings.get_setting("application/run/main_scene")))

func _panel(parent: Control) -> VBoxContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _palette_panel
	sb.border_color = _palette_accent
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	pc.add_theme_stylebox_override("panel", sb)
	parent.add_child(pc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	pc.add_child(box)
	return box

func _label(parent: Control, text: String, size := 14, colour := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour if colour != Color.WHITE else _palette_text)
	parent.add_child(l)
	return l

func _button(parent: Control, text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(callback)
	parent.add_child(b)
	return b

func _toast_text(text: String) -> void:
	_toast.text = text
	_toast_time = 4.0
	_toast.modulate.a = 1.0
	if voice != null:
		voice.say(text, "settlement")

func _process(delta: float) -> void:
	if not is_instance_valid(st) or not is_instance_valid(colony_bay):      # (a new game has just cleared the settlement)
		return
	_t += delta
	_clock += delta
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast.modulate.a = clampf(_toast_time, 0.0, 1.0)
	for i in _sites.size():
		Look.pulse(_sites[i]["pad"], _clock, state_of(i))
	Look.animate(world, _clock, _terraform())
	if _t >= REFRESH_S:
		_t = 0.0
		_refresh_hud()
		var ready: bool = bool(colony().get("expansion_ready", false))
		if ready != _last_ready:
			_last_ready = ready
			_refresh_sites()
			_refresh_card()

# The air as the plants have made it (get_terraform()), or as a picture wants it (debug_set_air).
func _terraform() -> Dictionary:
	var t: Dictionary = colony_bay.get_terraform()
	if _air_override >= 0.0 and bool(t["enabled"]):
		var stage := 0
		var stages: Array = t["stages"]
		for k in stages.size():
			if _air_override >= float(stages[k]):
				stage = k + 1
		t = t.duplicate()
		t["progress"] = _air_override
		t["stage"] = stage
	return t

# For pictures: show the land as it would look with the air at this progress (0 to 1); a negative value goes back to the real air.
func debug_set_air(progress: float) -> void:
	_air_override = progress
	_refresh_hud()

func _refresh_hud() -> void:
	var c := colony()
	var air: Dictionary = _terraform()
	var text := ""
	if bool(c.get("started", false)):
		text = "Population  %d / %d housed\n%ss  %d of %d sites\nFood in store  %d days\n" % [int(c["population"]), int(c["housing"]), unit_noun.capitalize(), int(c["units"]), int(c["max_units"]), int(c["reserve_days"])]
		if bool(c["running"]):
			if bool(c["expansion_ready"]):
				text += "Food to spare: you may BUILD a new %s\n" % unit_noun
			if bool(c["plenty"]) and int(c["population"]) < int(c["housing"]):
				text += "The farm out-grows the crew: more colonists soon (%d%%)\n" % roundi(float(c["growth_progress"]) * 100.0)
			elif bool(c["crowded"]) and bool(c["plenty"]):
				text += "The housing is full: build to welcome more people\n"
			else:
				text += "Farm output %d%% of the crew's need (%d%% brings more colonists)\n" % [roundi(float(c["surplus_ratio"]) * 100.0), roundi(float(FarmBay.get_expansion_rules()["surplus_factor"]) * 100.0)]
		text += "Day %d" % (int(c["day"]) + 1)
	else:
		text = "No colony yet: farm first, then start one\nfrom the farm's bar."
	_info.text = text
	_air_box.visible = bool(air["enabled"])
	if bool(air["enabled"]):
		_air_bar.value = float(air["progress"])
		var stage_names := ["Thin air", "The air is thickening", "Open-air farming", "Breathable with a mask", "Terraformed"]
		_air_label.text = "%d%%  ·  %s\nThe plants of every dome would settle it at about %d%%." % [roundi(float(air["progress"]) * 100.0), stage_names[int(air["stage"])], roundi(float(air["equilibrium"]) * 100.0)]

func _refresh_card() -> void:
	if site < 0:
		_card_title.text = "Nothing selected"
		_card_text.text = "Click a %s to look at it, or a free site to build on it." % unit_noun
		_build_btn.visible = false
		_enter_btn.visible = false
		return
	var state := state_of(site)
	_build_btn.visible = false
	_enter_btn.visible = false
	match state:
		"built":
			var u: int = st.unit_on(site)
			var bay_u: FarmBay = st.unit_bay(u)
			var plants := 0
			var ready_plants := 0
			for b in bay_u.get_bed_count():
				for s in int(bay_u.get_bed_info(b)["slots"]):
					var p: Dictionary = bay_u.get_plant(b, s)
					if not p["empty"]:
						plants += 1
						ready_plants += 1 if p["ready"] else 0
			_card_title.text = Look.unit_label(site, u + 1)
			_card_text.text = "%d plants growing, %d ready to harvest.\nWater %.0f L, nutrients %.0f units." % [plants, ready_plants, float(bay_u.get_status()["tank_l"]), float(bay_u.get_status()["nutrient_stock"])]
			_enter_btn.visible = true
			_enter_btn.text = "Enter " + Look.unit_label(site, u + 1)
		"ready":
			var rules := FarmBay.get_expansion_rules()
			_card_title.text = "A free site"
			_card_text.text = "There is food to spare. Build a new %s here: the building crew eats %d days of food, it houses %d more people, and its plants grow more." % [Look.site_noun(site), int(rules["expansion_cost_days"]), int(ceil(float(colony()["crew"]) * float(rules["housing_factor"])))]
			_build_btn.visible = true
			_build_btn.text = "Build a new %s here" % Look.site_noun(site)
		"waiting":
			_card_title.text = "A free site"
			_card_text.text = why_not()
		_:
			_card_title.text = "Not open yet"
			_card_text.text = why_not() if not bool(colony().get("running", false)) else Look.closed_text(site)

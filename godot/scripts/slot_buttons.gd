extends Control
## Floating buttons over the crop slots: one per slot, hovering just above its plant. Each says what that plant needs
## next, and does it when pressed (pressing also selects the slot, so the HUD shows its details):
##
##   Harvest   the plant is ready (or overripe)            Clear    the plant has died
##   Water     the plant's bed has run low on water        Feed     its bed has run low on nutrients
##   +         the slot is empty: sow the chosen crop      42%      all is well: how far the plant has grown
##
## It works with any scene shaped like greenhouse.gd and dome.gd (a `bay`, BED_CENTERS, BED_ROWS, BED_COLS, `_slot_offsets`,
## `_plants`, `_cam`, `selected`, `select_slot()` and the `action_*()` calls). Add it to the HUD BEFORE the panels, so the
## panels draw over it and take the clicks that fall on them:
##
##   var slot_buttons = SlotButtons.new()      # const SlotButtons = preload("res://scripts/slot_buttons.gd")
##   hud_root.add_child(slot_buttons)
##   slot_buttons.setup(self, {"feed": Color("e8861f")})     # the palette is optional: see `palette`

signal slot_pressed(bed: int, slot: int, kind: String)

# A bed counts as dry, or hungry, below this share of its reserve. (Growth is already held back below 0.35, core/plant.hpp;
# this warns a little before that.) A design value.
const NEED := 0.45
const LIFT := 0.12           # how far above the top of the plant the button floats, metres
const MIN_HEIGHT := 0.1      # ... measured from the soil, so a seed's button does not sit on the soil
const REF_DIST := 5.0        # camera distance at which the buttons have their nominal size; nearer is bigger, farther smaller

var scene: Node
var buttons := {}            # Vector2i(bed, slot) -> Button

# colours by kind; "quiet" is the dim pill for "+" and the growth percentage
var palette := {
	"harvest": Color("58b44f"), "harvest_text": Color("0b1a0a"),
	"water": Color("3b8fd4"), "water_text": Color("ffffff"),
	"feed": Color("e8861f"), "feed_text": Color("1b0e02"),
	"clear": Color("c4472f"), "clear_text": Color("ffffff"),
	"quiet": Color(0.07, 0.08, 0.09, 0.62), "quiet_text": Color(0.88, 0.88, 0.86),
	"border": Color(1, 1, 1, 0.38), "selected": Color("ffd27a"),
}

var _t := 0.0
var _styles := {}
var _items: Array = []       # this frame's layout: {"btn", "rect", "ideal" (where the plant is), "urgent"}

# What the plant in a slot needs next. {"kind": "sow" | "harvest" | "clear" | "water" | "feed" | "growing", "text", "tip"}.
static func state_of(bay: FarmBay, bed: int, slot: int) -> Dictionary:
	var p := bay.get_plant(bed, slot)
	if p["empty"]:
		return {"kind": "sow", "text": "+", "tip": "Sow this slot"}
	var info := bay.get_bed_info(bed)
	var water: float = info["water_l"] / maxf(info["water_capacity_l"], 0.001)
	var nutrient: float = info["nutrient"]
	if p["stage"] == FarmBay.STAGE_DEAD:
		return {"kind": "clear", "text": "Clear", "tip": "The %s has died: clear the slot" % str(p["name"]).to_lower()}
	if p["ready"]:
		return {"kind": "harvest", "text": "Harvest", "tip": "Harvest the %s" % str(p["name"]).to_lower()}
	if water < NEED:
		return {"kind": "water", "text": "Water", "tip": "Bed %d is running dry (%d%%): water it" % [bed + 1, int(water * 100.0)]}
	if nutrient < NEED:
		return {"kind": "feed", "text": "Feed", "tip": "Bed %d is short of nutrients (%d%%): feed it" % [bed + 1, int(nutrient * 100.0)]}
	return {"kind": "growing", "text": "%d%%" % int(p["progress"] * 100.0),
			"tip": "%s: %s, %d%% grown" % [p["name"], str(p["stage_name"]).to_lower(), int(p["progress"] * 100.0)]}

func setup(p_scene: Node, p_palette := {}) -> void:
	scene = p_scene
	for k in p_palette:
		palette[k] = p_palette[k]
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	name = "SlotButtons"
	var slots: int = scene.BED_ROWS * scene.BED_COLS
	for bed in scene.bay.get_bed_count():
		for slot in slots:
			var btn := Button.new()
			btn.name = "Slot_%d_%d" % [bed, slot]
			btn.focus_mode = Control.FOCUS_NONE
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.set_meta("key", "")
			btn.pressed.connect(_on_pressed.bind(bed, slot))
			add_child(btn)
			buttons[Vector2i(bed, slot)] = btn
	refresh()

func _process(delta: float) -> void:
	_t += delta
	refresh()

# Bring every button up to date: its words, its colours, its size for its distance, and its place above its plant (nudged
# aside when it would sit on a neighbour, with a thin line back to the plant).
func refresh() -> void:
	if scene == null or scene.get("_cam") == null:
		return
	var cam: Camera3D = scene._cam
	var view := get_viewport_rect().grow(20.0)
	_items.clear()
	for key in buttons:
		var btn: Button = buttons[key]
		var bed: int = key.x
		var slot: int = key.y
		var st := state_of(scene.bay, bed, slot)
		var selected: bool = scene.selected == key
		var world: Vector3 = scene.BED_CENTERS[bed] + scene._slot_offsets[slot] + Vector3(0, maxf(_plant_height(bed, slot), MIN_HEIGHT) + LIFT, 0)
		if cam.is_position_behind(world):
			btn.visible = false
			continue
		var quiet: bool = st["kind"] == "sow" or st["kind"] == "growing"
		var font := clampi(roundi((11.0 if quiet else 12.0) * clampf(REF_DIST / cam.global_position.distance_to(world), 0.8, 1.15)), 9, 14)
		var sig := "%s|%s|%s|%d" % [st["kind"], st["text"], selected, font]
		if btn.get_meta("key") != sig:
			btn.set_meta("key", sig)
			btn.text = st["text"]
			btn.tooltip_text = st["tip"]
			_dress(btn, st["kind"], selected, font)
			btn.reset_size()
		var px := cam.unproject_position(world)
		btn.visible = view.has_point(px)
		btn.modulate.a = 1.0 if quiet else 0.86 + 0.14 * sin(_t * 5.0 + float(bed))
		if btn.visible:
			_items.append({"btn": btn, "rect": Rect2(px - Vector2(btn.size.x * 0.5, btn.size.y), btn.size), "ideal": px, "urgent": not quiet})
	_declutter()
	for it in _items:
		(it["btn"] as Button).position = (it["rect"] as Rect2).position
	queue_redraw()

# Push overlapping buttons apart, along the shorter way out, half each, until none touch (or a few rounds have passed).
func _declutter() -> void:
	for round_i in 6:
		var moved := false
		for i in _items.size():
			for j in range(i + 1, _items.size()):
				var a: Rect2 = _items[i]["rect"]
				var b: Rect2 = _items[j]["rect"]
				var hit := a.grow(1.0).intersection(b)
				if hit.size.x <= 0.0 or hit.size.y <= 0.0:
					continue
				if hit.size.x < hit.size.y:
					var d := hit.size.x * 0.5 + 1.0
					var s := 1.0 if a.get_center().x < b.get_center().x else -1.0
					a.position.x -= s * d
					b.position.x += s * d
				else:
					var d := hit.size.y * 0.5 + 1.0
					var s := 1.0 if a.get_center().y < b.get_center().y else -1.0
					a.position.y -= s * d
					b.position.y += s * d
				_items[i]["rect"] = a
				_items[j]["rect"] = b
				moved = true
		if not moved:
			break

# a thin line from a button that wants attention down to its plant, so a button nudged aside still says whose it is
func _draw() -> void:
	for it in _items:
		var r: Rect2 = it["rect"]
		var tail := Vector2(r.get_center().x, r.end.y)
		if it["urgent"] and tail.distance_to(it["ideal"]) > 3.0:
			draw_line(tail, it["ideal"], Color(1, 1, 1, 0.55), 1.5)
			draw_circle(it["ideal"], 2.5, Color(1, 1, 1, 0.8))

func _plant_height(bed: int, slot: int) -> float:
	var node: Node3D = scene._plants.get(Vector2i(bed, slot))
	if node != null and node.get_child_count() > 0 and node.get_child(0) is MeshInstance3D:
		var mi := node.get_child(0) as MeshInstance3D
		if mi.mesh != null:
			return mi.mesh.get_aabb().size.y
	return 0.0

func _dress(btn: Button, kind: String, selected: bool, font: int) -> void:
	var quiet := kind == "sow" or kind == "growing"
	var colour_key := "quiet" if quiet else kind
	var text_colour: Color = palette[colour_key + "_text"]
	btn.add_theme_font_size_override("font_size", font)
	for state in ["normal", "hover", "pressed"]:
		btn.add_theme_stylebox_override(state, _style(colour_key, selected, state != "normal", quiet))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		btn.add_theme_color_override(c, text_colour)

func _style(colour_key: String, selected: bool, lit: bool, quiet: bool) -> StyleBoxFlat:
	var cache_key := "%s|%s|%s|%s" % [colour_key, selected, lit, quiet]
	if _styles.has(cache_key):
		return _styles[cache_key]
	var sb := StyleBoxFlat.new()
	var bg: Color = palette[colour_key]
	sb.bg_color = bg.lightened(0.2) if lit else bg
	sb.border_color = palette["selected"] if selected else palette["border"]
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(10 if quiet else 12)
	sb.content_margin_left = 6.0 if quiet else 9.0
	sb.content_margin_right = 6.0 if quiet else 9.0
	sb.content_margin_top = 1.0 if quiet else 2.0
	sb.content_margin_bottom = 1.0 if quiet else 2.0
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 3
	_styles[cache_key] = sb
	return sb

func _on_pressed(bed: int, slot: int) -> void:
	press(bed, slot)

# Select the slot and do what its button says (what a click does, and what the tests call).
func press(bed: int, slot: int) -> String:
	scene.select_slot(bed, slot)
	var kind: String = state_of(scene.bay, bed, slot)["kind"]
	match kind:
		"sow": scene.action_plant()
		"harvest": scene.action_harvest()
		"clear": scene.action_remove()
		"water": scene.action_water()
		"feed": scene.action_feed()
	slot_pressed.emit(bed, slot, kind)
	return kind

func kind_of(bed: int, slot: int) -> String:
	return state_of(scene.bay, bed, slot)["kind"]

func text_of(bed: int, slot: int) -> String:
	return (buttons[Vector2i(bed, slot)] as Button).text

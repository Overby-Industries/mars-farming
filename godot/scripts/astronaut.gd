extends Node3D
## The crew astronaut, put together from the modular suit components in res://models/astronaut/ (built by
## blender/build_astronaut.py): torso, helmet, backpack, an arm, a glove, a leg and a boot for each side.
##
## Each component is its own glb with its origin at its joint and its limbs hanging straight down. A component hangs on a
## SOCKET, an empty named Socket_* that its host places, so swapping a component for one with other proportions needs no
## change here. The stance is data (REST_DEG), not baked into the models, and the idle animation moves the same pivots:
## the helmet turns slowly, the chest breathes, the arms sway a little.
##
## Use:  var man := Astronaut.new()      # const Astronaut = preload("res://scripts/astronaut.gd")
##       man.recipe = {"colors": {"Suit_Orange": Color("2f9e6b")}, "hidden": ["Backpack"]}   # all optional
##       add_child(man)                  # assembles itself on entering the tree; man.pose(t) freezes the idle at t seconds
##
## recipe keys: "parts" {component: glb path} swaps a component, "colors" {material name: Color} recolours it,
## "hidden" [component names] leaves some out, "idle" false switches the idle animation off, "skins" false leaves the
## surfaces plain.
##
## Two surfaces, two textures. The ARMOUR (Suit_White, Suit_Grey) is smooth painted composite with a few chips and scuffs;
## the UNDERSUIT is a technical fabric: matte, a diagonal twill with a heavier ripstop thread every few centimetres,
## lit through a normal map. Both are made here from code (nothing on disk), tiled by triplanar mapping so the models
## need no UVs, and shared by every astronaut in the game.

const DIR := "res://models/astronaut/"

# material name -> the skin it gets: its kind and how many texture tiles fit in a metre
const SKINS := {
	"Undersuit": {"kind": "fabric", "scale": 9.0},
	"Suit_White": {"kind": "scuffed", "scale": 2.2},
	"Suit_Grey": {"kind": "scuffed", "scale": 2.2},
}
static var _skin_textures := {}          # kind -> [albedo texture, normal texture or null], built on first use
const WAIST := Vector3(0, 1.02, 0)       # where the torso's origin hangs before the feet are grounded (the stock suit's waist)

# component, glb file, host component, socket on the host (a component with no host hangs on this node)
const COMPONENTS := [
	["Torso", "torso", "", ""],
	["Helmet", "helmet", "Torso", "Socket_Neck"],
	["Backpack", "backpack", "Torso", "Socket_Back"],
	["ArmR", "arm_r", "Torso", "Socket_ShoulderR"],
	["ArmL", "arm_l", "Torso", "Socket_ShoulderL"],
	["GloveR", "glove_r", "ArmR", "Socket_WristR"],
	["GloveL", "glove_l", "ArmL", "Socket_WristL"],
	["LegR", "leg_r", "Torso", "Socket_HipR"],
	["LegL", "leg_l", "Torso", "Socket_HipL"],
	["BootR", "boot_r", "LegR", "Socket_AnkleR"],
	["BootL", "boot_l", "LegL", "Socket_AnkleL"],
]

# the stance, in degrees of rotation at each pivot: arms out a little, elbows bent a little
const REST_DEG := {
	"ArmR": Vector3(0, 0, 12), "ArmL": Vector3(0, 0, -12),
	"ForearmR": Vector3(15, 0, 0), "ForearmL": Vector3(15, 0, 0),
}

@export var head_sweep_deg := 24.0       # how far the head turns each way
@export var head_period := 15.0          # seconds for the head to turn one way and back
@export var look_down_deg := 8.0         # the head hangs a little, looking at the crops
@export var breath_period := 4.5         # seconds per breath

var recipe := {}
var parts := {}                          # component name -> the node holding it
var assembled := false
var missing: PackedStringArray = []      # components whose file could not be loaded

var _pivots := {}                        # Chest, Forearm..., Shin... : the moving pivots inside the components
var _rest := {}                          # node name -> its rest rotation
var _chest_rest := Vector3.ZERO
var _time := 0.0
var _idle := true
var _look_point := Vector3.ZERO     # a world point the head is turned to while a line is spoken (see look_at_point)
var _look_left := 0.0
var _look_w := 0.0                  # 0 = the idle sweep, 1 = looking at the point

func _ready() -> void:
	if not assembled:
		assemble()

func assemble() -> void:
	assembled = true
	var files: Dictionary = recipe.get("parts", {})
	for c in COMPONENTS:
		var path: String = files.get(c[0], DIR + c[1] + ".glb")
		var node := _load(path)
		if node == null:
			missing.append(c[0])
			continue
		node.name = c[0]
		var host: Node = self
		if c[2] != "":
			var host_part: Node3D = parts.get(c[2])
			var socket: Node = host_part.find_child(c[3], true, false) if host_part != null else null
			if socket == null:
				missing.append(c[0])
				node.free()
				continue
			host = socket
		host.add_child(node)
		parts[c[0]] = node
	if not parts.has("Torso"):
		_placeholder()
	else:
		(parts["Torso"] as Node3D).position = WAIST
	for pivot_name in ["Chest", "ForearmR", "ForearmL", "ShinR", "ShinL"]:
		var p := find_child(pivot_name, true, false) as Node3D
		if p != null:
			_pivots[pivot_name] = p
	for n in REST_DEG:
		var node := _pivot(n)
		if node != null:
			node.rotation_degrees = REST_DEG[n]
			_rest[n] = node.rotation
	var chest := _pivot("Chest")
	_chest_rest = chest.position if chest != null else Vector3.ZERO
	for n in recipe.get("hidden", []):
		set_component_visible(n, false)
	if recipe.get("skins", true):
		apply_skins()
	if recipe.has("colors"):
		apply_colors(recipe["colors"])
	_idle = recipe.get("idle", true)
	set_process(_idle)
	pose(0.0)
	ground()

# A glb instantiates as a plain wrapper around the component's root pivot: keep the pivot, drop the wrapper.
func _load(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("Astronaut: missing component %s" % path)
		return null
	var scene := load(path) as PackedScene
	var wrapper := scene.instantiate() as Node3D if scene != null else null
	if wrapper != null and wrapper.get_child_count() == 1 and wrapper.get_child(0) is Node3D:
		var inner := wrapper.get_child(0) as Node3D
		wrapper.remove_child(inner)
		wrapper.free()
		return inner
	return wrapper

# Put the soles of the boots on y = 0 whatever the proportions of the legs and boots in use (the stock suit needs no shift).
func ground() -> void:
	var torso := get_component("Torso")
	if torso == null:
		return
	var low := INF
	for n in ["BootR", "BootL"]:
		var boot := get_component(n)
		if boot == null:
			continue
		for mi in _mesh_instances(boot):
			low = minf(low, (_to_self(mi) * (mi as MeshInstance3D).mesh.get_aabb()).position.y)
	if low < INF and absf(low) > 1e-5:
		torso.position.y -= low

# the transform of a node in this node's space, composed by hand so it works before the tree is built
func _to_self(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != self:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf

# a capsule where the suit would be, so a missing torso file never breaks the scene
func _placeholder() -> void:
	var cap := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.25
	mesh.height = 1.8
	cap.mesh = mesh
	cap.position.y = 0.9
	cap.name = "Placeholder"
	add_child(cap)

# a pivot inside a component by name: one of the moving pivots, or the root of a component
func _pivot(n: String) -> Node3D:
	if _pivots.has(n):
		return _pivots[n]
	if parts.has(n):
		return parts[n]
	return find_child(n, true, false) as Node3D

func get_component(n: String) -> Node3D:
	return parts.get(n)

func set_component_visible(n: String, on: bool) -> void:
	var node := get_component(n)
	if node != null:
		node.visible = on

# Recolour materials by name ("Suit_Orange", "Suit_White" ...): each affected surface gets its own copy of the material,
# so one astronaut can wear another colour than the next. A glowing material changes its glow, not its base.
func apply_colors(colors: Dictionary) -> void:
	for mi in _mesh_instances(self):
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i) as StandardMaterial3D
			if m == null or not colors.has(m.resource_name):
				continue
			var copy := m.duplicate() as StandardMaterial3D
			if copy.emission_enabled:
				copy.emission = colors[m.resource_name]
			else:
				copy.albedo_color = colors[m.resource_name]
			mi.set_surface_override_material(i, copy)

# Give the fabric and the armour their textures (SKINS). Each surface gets its own copy of its material, the textures
# are shared.
func apply_skins() -> void:
	for mi in _mesh_instances(self):
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i) as StandardMaterial3D
			if m == null or not SKINS.has(m.resource_name):
				continue
			var skin: Dictionary = SKINS[m.resource_name]
			var tex := _textures(skin["kind"])
			var copy := m.duplicate() as StandardMaterial3D
			copy.albedo_texture = tex[0]
			copy.uv1_triplanar = true                         # the models carry no UVs: project the texture from three sides
			copy.uv1_scale = Vector3.ONE * float(skin["scale"])
			copy.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			if tex[1] != null:
				copy.normal_enabled = true
				copy.normal_texture = tex[1]
				copy.normal_scale = 1.0
			if skin["kind"] == "fabric":
				copy.roughness = 0.92
				copy.metallic_specular = 0.3
			mi.set_surface_override_material(i, copy)

static func _textures(kind: String) -> Array:
	if not _skin_textures.has(kind):
		_skin_textures[kind] = _make_fabric() if kind == "fabric" else _make_scuffed()
	return _skin_textures[kind]

# A technical fabric: a diagonal twill (a ridge every 8 pixels), a faint basket texture, and a heavier ripstop thread every
# 32 pixels each way. The albedo is a grey multiplier on the material's dark colour; the normal map carries the weave.
static func _make_fabric() -> Array:
	var n := 128
	var h := PackedFloat32Array()
	h.resize(n * n)
	for y in n:
		for x in n:
			var twill := 0.5 + 0.5 * sin(TAU * float((x + y) % 8) / 8.0)
			var basket := 0.5 + 0.5 * sin(TAU * float(x % 4) / 4.0) * sin(TAU * float(y % 4) / 4.0)
			var v := 0.62 * twill + 0.22 * basket
			if x % 32 < 3 or y % 32 < 3:
				v = 0.45 + 0.55 * v
			h[y * n + x] = v
	var albedo := PackedByteArray()
	var normal := PackedByteArray()
	albedo.resize(n * n * 3)
	normal.resize(n * n * 3)
	for y in n:
		for x in n:
			var i := y * n + x
			var g := clampf(0.55 + 0.6 * h[i], 0.0, 1.0)
			var dx := h[y * n + (x + 1) % n] - h[y * n + (x + n - 1) % n]
			var dy := h[((y + 1) % n) * n + x] - h[((y + n - 1) % n) * n + x]
			var nv := Vector3(-dx * 2.2, -dy * 2.2, 1.0).normalized()
			for k in 3:
				albedo[i * 3 + k] = int(g * 255.0)
				normal[i * 3 + k] = int((nv[k] * 0.5 + 0.5) * 255.0)
	return [_texture(n, albedo), _texture(n, normal)]

# Painted armour: white, with a scatter of small chips and a few faint scuffs (no normal map: the plates stay smooth).
static func _make_scuffed() -> Array:
	var n := 256
	var v := PackedFloat32Array()
	v.resize(n * n)
	v.fill(1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 110:
		_blob(v, n, rng.randi_range(0, n - 1), rng.randi_range(0, n - 1), rng.randf_range(0.9, 2.0), rng.randf_range(0.5, 0.8))
	for i in 14:
		_blob(v, n, rng.randi_range(0, n - 1), rng.randi_range(0, n - 1), rng.randf_range(5.0, 11.0), rng.randf_range(0.9, 0.96))
	var albedo := PackedByteArray()
	albedo.resize(n * n * 3)
	for i in n * n:
		for k in 3:
			albedo[i * 3 + k] = int(clampf(v[i], 0.0, 1.0) * 255.0)
	return [_texture(n, albedo), null]

static func _blob(v: PackedFloat32Array, n: int, cx: int, cy: int, r: float, dark: float) -> void:
	var ri := int(ceil(r))
	for dy in range(-ri, ri + 1):
		for dx in range(-ri, ri + 1):
			if float(dx * dx + dy * dy) <= r * r:
				var i := ((cy + dy + n) % n) * n + (cx + dx + n) % n
				v[i] = minf(v[i], dark)

static func _texture(n: int, rgb: PackedByteArray) -> ImageTexture:
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGB8, rgb)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		out.append_array(_mesh_instances(c))
	return out

# ---------------------------------------------------------------------------------------------------------
# the idle animation
# ---------------------------------------------------------------------------------------------------------

# Turn the head to look at a world point for a few seconds (the crew voice does this for whatever it is talking about), then
# let it go back to the idle sweep. `instant` skips the turn (what the tests use).
func look_at_point(world_point: Vector3, seconds := 5.0, instant := false) -> void:
	_look_point = world_point
	_look_left = seconds
	if instant:
		_look_w = 1.0

func stop_looking() -> void:
	_look_left = 0.0

func _process(delta: float) -> void:
	_time += delta
	if _look_left > 0.0:
		_look_left -= delta
		_look_w = minf(1.0, _look_w + delta * 2.5)
	else:
		_look_w = maxf(0.0, _look_w - delta * 1.2)
	pose(_time)

# the helmet's (pitch, yaw) that would look at a world point, limited to what a neck can do
func _aim_at(helmet: Node3D, world_point: Vector3) -> Vector2:
	var d := to_local(world_point) - _to_self(helmet).origin
	return Vector2(clampf(atan2(d.y, Vector2(d.x, d.z).length()), -0.6, 0.45), clampf(atan2(-d.x, -d.z), -1.2, 1.2))

# Freeze the idle at t seconds (what the tests and the screenshot scripts use).
func pose(t: float) -> void:
	_time = t
	var breath := 0.5 - 0.5 * cos(TAU * t / breath_period)          # 0 at the end of an out-breath, 1 at the top of an in-breath
	var chest := _pivot("Chest")
	if chest != null:
		chest.position = _chest_rest + Vector3(0, 0.003 * breath, 0)
		chest.scale = Vector3.ONE * (1.0 + 0.006 * breath)
	var helmet := get_component("Helmet")
	if helmet != null:
		var yaw := deg_to_rad(head_sweep_deg) * sin(TAU * t / head_period)
		var pitch := -deg_to_rad(look_down_deg) * (0.65 + 0.35 * sin(TAU * t / (head_period * 0.7) + 1.0))
		if _look_w > 0.0 and is_inside_tree():
			var aim := _aim_at(helmet, _look_point)
			pitch = lerp_angle(pitch, aim.x, _look_w)
			yaw = lerp_angle(yaw, aim.y, _look_w)
		helmet.rotation = Vector3(pitch, yaw, 0.0)
	for side in ["R", "L"]:
		var arm := _pivot("Arm" + side)
		if arm != null and _rest.has("Arm" + side):
			var sway := deg_to_rad(1.4) * sin(TAU * t / breath_period + (0.0 if side == "R" else PI))
			arm.rotation = _rest["Arm" + side] + Vector3(sway, 0, 0)

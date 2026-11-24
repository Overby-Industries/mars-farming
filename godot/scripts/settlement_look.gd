extends RefCounted
## How the settlement looks in this game (Mars Farming): a mission hub on the rust-red plain, six sites around it for glass domes, and two
## more farther out for open-air gardens, which open once the air is thick enough to farm in the open. The sky, the soil and the land
## follow how far the colony's plants have thickened the air (core/terraform.hpp): butterscotch sky and bare rust at the start, a blue
## sky and green fields at the half-way mark, trees and a lake when Mars has been terraformed. scripts/settlement_view.gd (the same in
## both games) asks for everything here.
##
## 1 unit is 1 m. A dome is 14 m across, like the dome scene's; a hub is 10 m across.

const PLACE := "dome"
const NOUN := "dome"
const TITLE := "MARS SETTLEMENT"
const MEDIUM := "regolith"
const TUNING := {"demand": [0.5, 0.6, 0.6], "reserve": [1.0, 1.6, 1.6]}
const PALETTE := {"accent": Color("d2682f"), "panel": Color(0.10, 0.06, 0.05, 0.86), "text": Color("efe6da")}
const DOME_R := 7.0
# six domes round the hub, and two gardens beyond (they open when the air does)
const SITES := [Vector3(25.4, 0, 9.2), Vector3(4.7, 0, 26.6), Vector3(-20.7, 0, 17.4), Vector3(-25.4, 0, -9.2), Vector3(-4.7, 0, -26.6), Vector3(20.7, 0, -17.4),
		Vector3(33.4, 0, 39.8), Vector3(-33.4, 0, -39.8)]
const INNER := 6                                                # the sites that are domes

const RUST := Color("d2682f")
const SKY_TOP := Color(0.60, 0.43, 0.31)
const SKY_HORIZON := Color(0.88, 0.64, 0.43)
const AIR_TOP := Color(0.36, 0.55, 0.82)
const AIR_HORIZON := Color(0.78, 0.84, 0.88)

static func make_bay() -> FarmBay:
	return preload("res://scripts/dome.gd").make_bay()

static func camera_start() -> Dictionary:
	return {"pivot": Vector3(2, 0, 4), "yaw": 0.35, "pitch": -0.78, "dist": 125.0}

static func pick_radius() -> float:
	return 8.5

static func label_offset(i: int) -> Vector3:
	return Vector3(0, 11.0 if i < INNER else 5.0, 0)

# What a built unit is called on the overview: a dome, or a garden in the open.
static func unit_label(site: int, number: int) -> String:
	return ("Dome %d" if site < INNER else "Garden %d") % number

static func site_noun(site: int) -> String:
	return "dome" if site < INNER else "garden"

static func locked_text(_view: Node) -> String:
	return "Every site is taken. More open when the air is thick enough to farm in the open."

static func closed_text(site: int) -> String:
	return "A garden beyond the airlocks: it opens when the plants have thickened the air to open-air farming (the air must reach 50%)." if site >= INNER else "Not open yet."

# ---------------------------------------------------------------------------------------------------------
# small builders
# ---------------------------------------------------------------------------------------------------------

static func _mat(colour: Color, metallic := 0.0, rough := 0.6, glow := Color.BLACK, glow_energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.metallic = metallic
	m.roughness = rough
	if glow_energy > 0.0:
		m.emission_enabled = true
		m.emission = glow
		m.emission_energy_multiplier = glow_energy
	if colour.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

static func _mi(parent: Node3D, mesh: Mesh, material: Material, pos := Vector3.ZERO, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi

static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

static func _cyl(radius: float, height: float, segments := 40, top_radius := -1.0) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius if top_radius < 0.0 else top_radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = segments
	return c

static func _sphere(radius: float, squash := 1.0, hemisphere := false) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0 * squash if not hemisphere else radius
	s.is_hemisphere = hemisphere
	s.radial_segments = 48
	s.rings = 20
	return s

static func _torus(inner: float, outer: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = 48
	t.ring_segments = 10
	return t

static func _dir_to_hub(i: int) -> float:
	var d: Vector3 = -(SITES[i] as Vector3)
	return atan2(d.x, d.z)

# ---------------------------------------------------------------------------------------------------------
# the world: the plain, the sky, the hub and its corridors
# ---------------------------------------------------------------------------------------------------------

static func build_world(root: Node3D) -> Dictionary:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.ground_horizon_color = Color(0.5, 0.3, 0.2)
	sky_mat.ground_bottom_color = Color(0.3, 0.17, 0.11)
	sky_mat.sky_energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.80, 0.68, 0.58)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.fog_enabled = true
	env.fog_light_color = SKY_HORIZON
	env.fog_density = 0.0016
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color("ffe2c0")
	sun.light_energy = 1.5
	sun.rotation_degrees = Vector3(-48, 118, 0)
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.7
	sun.directional_shadow_max_distance = 280.0
	root.add_child(sun)

	# the plain: the dome scene's soil, a ring of rocks, hills on the horizon
	var gen := FarmSkinGenerator.new()
	var tex := gen.generate_texture({"kind": "soil", "seed": 21, "frequency": 0.03, "dark_color": Color("3a170c"), "base_color": Color("8c4220"), "highlight_color": Color("c97a45")}, 512, 512)
	var plane := PlaneMesh.new()
	plane.size = Vector2(700, 700)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_texture = tex
	ground_mat.uv1_scale = Vector3(90, 90, 1)
	ground_mat.roughness = 1.0
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = ground_mat
	ground.position = Vector3(0, -0.04, 0)
	root.add_child(ground)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var rock_mat := _mat(Color(0.28, 0.17, 0.12), 0.0, 1.0)
	for i in 90:
		var ang := rng.randf_range(0.0, TAU)
		var dist := rng.randf_range(16.0, 150.0)
		var pos := Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var near_site := false
		for s in SITES:
			if (s as Vector3).distance_to(pos) < 11.0:
				near_site = true
		if near_site or pos.length() < 8.0:
			continue
		var r := rng.randf_range(0.3, 1.4) * (1.0 + dist / 90.0)
		var rock := _mi(root, _sphere(r), rock_mat, Vector3(pos.x, r * 0.1, pos.z))
		rock.scale = Vector3(1.0, rng.randf_range(0.4, 0.8), rng.randf_range(0.7, 1.2))
		rock.rotation.y = rng.randf_range(0.0, TAU)
	for i in 7:
		var hill := _mi(root, _sphere(40.0), _mat(Color(0.5, 0.28, 0.17), 0.0, 1.0), Vector3(-170 + i * 58.0, -10.0, -230.0 - (i % 2) * 30.0))
		hill.scale = Vector3(1.9, 0.45, 1.0)

	# the hub: a squat habitat with a ring of lit windows, an antenna and a field of solar panels
	var metal := _mat(Color("cdc4bb"), 0.6, 0.4)
	var dark := _mat(Color("3a3430"), 0.5, 0.5)
	var window := _mat(Color("fff0d0"), 0.0, 0.3, Color("ffe2b0"), 1.6)
	var hub := Node3D.new()
	hub.name = "Hub"
	root.add_child(hub)
	_mi(hub, _cyl(5.2, 3.2, 56), metal, Vector3(0, 1.6, 0))
	_mi(hub, _cyl(5.4, 0.4, 56), dark, Vector3(0, 0.2, 0))
	_mi(hub, _sphere(4.0, 1.0, true), _mat(Color(0.75, 0.88, 0.95, 0.35), 0.0, 0.1), Vector3(0, 3.2, 0))
	_mi(hub, _cyl(0.1, 7.0, 8), metal, Vector3(2.0, 6.5, -1.0))
	_mi(hub, _sphere(0.35), _mat(RUST, 0.0, 0.4, RUST, 1.5), Vector3(2.0, 10.1, -1.0))
	for k in 12:
		var a := TAU * k / 12.0
		_mi(hub, _box(Vector3(0.9, 0.7, 0.25)), window, Vector3(sin(a) * 5.22, 1.9, cos(a) * 5.22), Vector3(0, a, 0))
	var panel_mat := _mat(Color("18284c"), 0.5, 0.3, Color("2b4a9a"), 0.3)
	for row in 3:
		for col in 5:
			var panel := _mi(hub, _box(Vector3(3.4, 0.1, 2.0)), panel_mat, Vector3(-9.0 + col * 4.0, 1.1, -13.0 - row * 3.2))
			panel.rotation.x = -0.35
	# the corridors to the domes (the foundations are laid; what stands on them is built)
	var tube_mat := _mat(Color("c9bfb4"), 0.5, 0.45)
	for i in INNER:
		var d: Vector3 = SITES[i]
		var dir := d.normalized()
		var length := d.length() - DOME_R - 4.5
		var tube := _mi(root, _cyl(1.05, length, 24), tube_mat, dir * (4.5 + length * 0.5) + Vector3(0, 1.05, 0))
		tube.basis = Basis(Vector3.UP, atan2(dir.x, dir.z)) * Basis(Vector3.RIGHT, PI * 0.5)       # lying along the way to the dome

	# what the plants make of Mars: the green of the fields, trees, a lake, clouds. Hidden until the air allows
	var fields := Node3D.new()
	fields.name = "Fields"
	fields.visible = false
	root.add_child(fields)
	var field_mat := _mat(Color("5a9c3c"), 0.0, 1.0)
	for k in 14:
		var ang := rng.randf_range(0.0, TAU)
		var dist := rng.randf_range(34.0, 78.0)
		var disc := _mi(fields, _cyl(rng.randf_range(4.0, 9.0), 0.12, 24), field_mat, Vector3(cos(ang) * dist, 0.02, sin(ang) * dist))
		disc.scale = Vector3(1.0, 1.0, rng.randf_range(0.6, 1.0))
	for s in [SITES[6], SITES[7]]:                                      # the open-air gardens' plots
		_mi(fields, _cyl(9.5, 0.14, 32), _mat(Color("6bb04a"), 0.0, 1.0), (s as Vector3) + Vector3(0, 0.03, 0))
	var trees := Node3D.new()
	trees.name = "Trees"
	trees.visible = false
	root.add_child(trees)
	var trunk_mat := _mat(Color("5b3a22"), 0.0, 1.0)
	var leaf_mat := _mat(Color("3f8a35"), 0.0, 0.9)
	for k in 70:
		var ang := rng.randf_range(0.0, TAU)
		var dist := rng.randf_range(40.0, 110.0)
		var tp := Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var near := false
		for s in SITES:
			if (s as Vector3).distance_to(tp) < 12.0:
				near = true
		if near:
			continue
		var h := rng.randf_range(3.5, 7.0)
		var tree := Node3D.new()
		tree.position = tp
		trees.add_child(tree)
		_mi(tree, _cyl(0.25, h * 0.4, 8), trunk_mat, Vector3(0, h * 0.2, 0))
		_mi(tree, _cyl(h * 0.38, h * 0.8, 10, 0.05), leaf_mat, Vector3(0, h * 0.4 + h * 0.4, 0))
	var lake_mat := _mat(Color(0.2, 0.45, 0.75, 0.85), 0.1, 0.1, Color(0.1, 0.3, 0.6), 0.3)
	var lake := _mi(root, _cyl(24.0, 0.1, 48), lake_mat, Vector3(-62.0, 0.05, 28.0))
	lake.name = "Lake"
	lake.scale = Vector3(1.0, 1.0, 0.62)
	lake.visible = false
	var clouds := Node3D.new()
	clouds.name = "Clouds"
	clouds.visible = false
	root.add_child(clouds)
	var cloud_mat := _mat(Color(1, 1, 1, 0.0), 0.0, 1.0)
	cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for k in 22:                                                     # banks of cloud round the horizon, never between the camera and the domes
		var ang := TAU * k / 22.0 + rng.randf_range(-0.1, 0.1)
		var dist := rng.randf_range(230.0, 420.0)
		var cloud := _mi(clouds, _sphere(rng.randf_range(24.0, 46.0)), cloud_mat, Vector3(cos(ang) * dist, rng.randf_range(40.0, 85.0), sin(ang) * dist))
		cloud.scale = Vector3(1.0, 0.3, rng.randf_range(0.5, 0.8))
		cast_off(cloud)
	return {"environment": env, "sun": sun, "sky": sky_mat, "ground": ground_mat, "fields": fields, "trees": trees, "lake": lake,
			"clouds": clouds, "cloud_mat": cloud_mat, "env": env}

static func cast_off(mi: MeshInstance3D) -> void:
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# ---------------------------------------------------------------------------------------------------------
# a free site: the foundation, waiting; a unit: a dome, or a garden in the open
# ---------------------------------------------------------------------------------------------------------

static func make_pad(i: int) -> Node3D:
	var pad := Node3D.new()
	pad.name = "Pad"
	var collar := _mi(pad, _torus(DOME_R - 0.3, DOME_R + 0.4), _mat(RUST, 0.2, 0.5, RUST, 1.0), Vector3(0, 0.12, 0))
	collar.name = "Collar"
	for k in 4:                                                      # four beacon posts round the foundation
		var a := TAU * k / 4.0 + PI * 0.25
		var at := Vector3(sin(a) * (DOME_R + 1.0), 0, cos(a) * (DOME_R + 1.0))
		_mi(pad, _cyl(0.12, 2.4, 8), _mat(Color("4a3f38"), 0.4, 0.6), at + Vector3(0, 1.2, 0))
		var beacon := _mi(pad, _sphere(0.42), _mat(RUST, 0.0, 0.3, RUST, 2.0), at + Vector3(0, 2.6, 0))
		beacon.name = "Beacon%d" % k
	var ghost := _mi(pad, _sphere(DOME_R, 1.0, true), _mat(Color(1.0, 0.7, 0.45, 0.07), 0.0, 1.0, RUST, 0.12), Vector3(0, 0.05, 0))
	ghost.name = "Ghost"
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if i >= INNER:                                                   # the gardens: a marked plot, not a dome
		ghost.mesh = _cyl(DOME_R + 1.0, 0.3, 32)
		ghost.position = Vector3(0, 0.15, 0)
	return pad

static func make_unit(i: int) -> Node3D:
	var unit := Node3D.new()
	unit.name = "Unit"
	var rib := _mat(Color("efe6da"), 0.4, 0.5)
	if i < INNER:
		var glass := _mat(Color(0.82, 0.9, 0.95, 0.16), 0.1, 0.05)
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		var shell := _mi(unit, _sphere(DOME_R, 1.0, true), glass)
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for k in 4:                                                  # the meridian ribs
			var r := _mi(unit, _torus(DOME_R - 0.06, DOME_R + 0.06), rib, Vector3.ZERO, Vector3(PI * 0.5, PI * k / 4.0, 0))
			r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for lat in [0.4, 0.8, 1.15]:
			var band := _mi(unit, _torus(DOME_R * cos(lat) - 0.06, DOME_R * cos(lat) + 0.06), rib, Vector3(0, DOME_R * sin(lat), 0))
			band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mi(unit, _torus(DOME_R - 0.1, DOME_R + 0.35), _mat(Color("c5602e"), 0.3, 0.6), Vector3(0, 0.1, 0))
		_mi(unit, _cyl(DOME_R - 0.15, 0.1, 40), _mat(Color("8d837b"), 0.0, 0.6), Vector3(0, 0.02, 0))
		var green := _mat(Color("5fbf4a"), 0.0, 0.7, Color("6fe05a"), 0.6)
		for bx in [-1.0, 1.0]:                                       # the benches and their beds, seen through the glass
			_mi(unit, _box(Vector3(2.2, 0.5, 5.4)), green, Vector3(bx * 1.9, 0.9, 0))
		var lock := _mi(unit, _box(Vector3(2.4, 2.6, 2.4)), _mat(Color("cdc4bb"), 0.6, 0.4), Vector3(0, 1.3, 0))
		lock.position = Vector3(sin(_dir_to_hub(i)) * (DOME_R + 0.4), 1.3, cos(_dir_to_hub(i)) * (DOME_R + 0.4))
		lock.rotation.y = _dir_to_hub(i)
		var glow := OmniLight3D.new()
		glow.light_color = Color(1.0, 0.92, 0.8)
		glow.light_energy = 1.2
		glow.omni_range = 14.0
		glow.position = Vector3(0, 3.5, 0)
		unit.add_child(glow)
	else:                                                            # an open-air garden: a low wall round rows of crops
		_mi(unit, _cyl(DOME_R + 0.6, 0.3, 40), _mat(Color("4a3a30"), 0.0, 0.9), Vector3(0, 0.15, 0))
		_mi(unit, _cyl(DOME_R + 0.2, 0.32, 40), _mat(Color("6b4b36"), 0.0, 1.0), Vector3(0, 0.18, 0))
		var green2 := _mat(Color("6fc24f"), 0.0, 0.8, Color("6fe05a"), 0.35)
		for row in 6:
			_mi(unit, _box(Vector3(11.0 - absf(row - 2.5) * 1.6, 0.5, 0.9)), green2, Vector3(0, 0.55, -4.4 + row * 1.76))
		var wall_mat := _mat(Color("c9bfb4"), 0.3, 0.6)
		for k in 8:
			var a := TAU * k / 8.0
			_mi(unit, _cyl(0.2, 1.3, 8), wall_mat, Vector3(sin(a) * (DOME_R + 0.5), 0.8, cos(a) * (DOME_R + 0.5)))
		_mi(unit, _cyl(0.18, 4.0, 8), wall_mat, Vector3(0, 2.0, DOME_R * 0.7))                 # an irrigation mast
		_mi(unit, _sphere(0.5), _mat(Color("5fb6e8"), 0.0, 0.3, Color("5fb6e8"), 1.0), Vector3(0, 4.1, DOME_R * 0.7))
	return unit

# ---------------------------------------------------------------------------------------------------------
# a site's look follows its state; the pads breathe when a unit may be built
# ---------------------------------------------------------------------------------------------------------

static func set_pad_state(pad: Node3D, state: String, selected: bool) -> void:
	var collar := pad.get_node_or_null("Collar") as MeshInstance3D
	if collar == null:
		return
	var colour: Color = {"ready": Color("ffd27a"), "waiting": RUST, "locked": Color(0.45, 0.42, 0.4)}.get(state, RUST)
	var m := collar.material_override as StandardMaterial3D
	m.albedo_color = colour
	m.emission = colour
	(pad.get_node("Ghost") as MeshInstance3D).visible = state == "ready" or selected
	for k in 4:
		var b := pad.get_node("Beacon%d" % k) as MeshInstance3D
		(b.material_override as StandardMaterial3D).emission = colour
		(b.material_override as StandardMaterial3D).albedo_color = colour

static func pulse(pad: Node3D, clock: float, state: String) -> void:
	var collar := pad.get_node_or_null("Collar") as MeshInstance3D
	if collar == null or not pad.visible:
		return
	var base: float = {"ready": 2.2, "waiting": 0.6, "locked": 0.12}.get(state, 0.6)
	var swing := 0.8 * sin(clock * 4.0) if state == "ready" else 0.0
	(collar.material_override as StandardMaterial3D).emission_energy_multiplier = base + swing
	for k in 4:
		var b := pad.get_node("Beacon%d" % k) as MeshInstance3D
		var on := state == "ready" and int(floor(clock * 3.0 + k)) % 4 == 0
		(b.material_override as StandardMaterial3D).emission_energy_multiplier = (3.5 if on else (0.9 if state != "locked" else 0.1))

# ---------------------------------------------------------------------------------------------------------
# the air the plants make: the sky, the soil, the land
# ---------------------------------------------------------------------------------------------------------

# `terraform` is get_terraform(): enabled, progress (0 to 1) and stage (0 thin air ... 4 terraformed).
static func animate(world: Dictionary, clock: float, terraform: Dictionary) -> void:
	if world.is_empty():
		return
	var air := float(terraform.get("progress", 0.0)) if bool(terraform.get("enabled", false)) else 0.0
	var stage := int(terraform.get("stage", 0)) if bool(terraform.get("enabled", false)) else 0
	var sky: ProceduralSkyMaterial = world["sky"]
	sky.sky_top_color = SKY_TOP.lerp(AIR_TOP, air * 0.9)
	sky.sky_horizon_color = SKY_HORIZON.lerp(AIR_HORIZON, air * 0.75)
	var env: Environment = world["env"]
	env.fog_light_color = sky.sky_horizon_color
	env.fog_density = lerpf(0.0016, 0.0009, air)
	(world["ground"] as StandardMaterial3D).albedo_color = Color.WHITE.lerp(Color(0.66, 0.92, 0.55), smoothstep(0.3, 1.0, air))
	(world["fields"] as Node3D).visible = stage >= 2
	(world["trees"] as Node3D).visible = stage >= 3
	(world["lake"] as Node3D).visible = stage >= 4
	var clouds := world["clouds"] as Node3D
	clouds.visible = air > 0.5
	(world["cloud_mat"] as StandardMaterial3D).albedo_color = Color(1, 1, 1, clampf((air - 0.5) * 1.4, 0.0, 0.8))
	clouds.rotation.y = clock * 0.004
	if stage >= 3:
		(world["trees"] as Node3D).scale = Vector3.ONE * lerpf(0.5, 1.0, clampf((air - 0.8) * 5.0, 0.0, 1.0))

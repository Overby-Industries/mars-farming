extends Node3D
## A development showcase: every crop at every stage, plus the props, on one table. Open it in the editor to
## look at the procedural art, or capture it with tests/shot.gd. Nothing here is gameplay.

const SPECIES := ["lettuce", "radish", "tomato", "potato"]
const SPACING := 0.30

var _builder := FarmShapeBuilder.new()

func _stages() -> Array:
	return [
		[FarmBay.STAGE_SEED, 0.03], [FarmBay.STAGE_SPROUT, 0.15], [FarmBay.STAGE_VEGETATIVE, 0.45],
		[FarmBay.STAGE_FLOWERING, 0.62], [FarmBay.STAGE_FRUITING, 0.85], [FarmBay.STAGE_READY, 1.0],
		[FarmBay.STAGE_OVERRIPE, 1.0], [FarmBay.STAGE_DEAD, 0.5],
	]

func _ready() -> void:
	_build_environment()
	_build_table()
	_build_lineup()
	_build_props()
	_build_camera()

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("2a1710")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c9a283")
	env.ambient_light_energy = 0.55
	env.glow_enabled = true
	env.glow_intensity = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color("ffe2c0")
	sun.light_energy = 1.1
	sun.rotation_degrees = Vector3(-52, -28, 0)
	sun.shadow_enabled = true
	add_child(sun)

func _build_table() -> void:
	add_child(_builder.build_node({"shape": "box", "name": "Table", "size": Vector3(3.0, 0.04, 2.6),
			"albedo_color": Color("4a3d36"), "roughness": 0.6}))
	($Table as Node3D).position = Vector3(1.05, -0.02, -0.2)

func _build_lineup() -> void:
	var stages := _stages()
	for r in SPECIES.size():
		for c in stages.size():
			var node: Node3D = _builder.build_node({
				"shape": "plant", "species": SPECIES[r], "stage": stages[c][0], "progress": stages[c][1],
				"health": 0.25 if stages[c][0] == FarmBay.STAGE_DEAD else 1.0, "seed": 100 + r * 10 + c,
			})
			node.position = Vector3(c * SPACING, 0.0, r * SPACING)
			add_child(node)

func _build_props() -> void:
	var recipe := {"shape": "planter_tray", "rows": 2, "cols": 4,
			"soil_skin": {"kind": "soil", "seed": 3, "dark_color": Color("2e140a"), "base_color": Color("6e3b22"), "highlight_color": Color("a8683c")}}
	var tray: Node3D = _builder.build_node(recipe)
	tray.position = Vector3(0.7, 0.0, -0.95)
	add_child(tray)
	var slots := _builder.get_slot_positions(recipe)
	var kinds := ["lettuce", "radish", "tomato", "potato"]
	for i in slots.size():
		var plant: Node3D = _builder.build_node({"shape": "plant", "species": kinds[i % 4], "stage": FarmBay.STAGE_READY, "progress": 1.0, "seed": 40 + i})
		plant.position = tray.position + slots[i]
		add_child(plant)

	var light: Node3D = _builder.build_node({"shape": "grow_light"})
	light.position = tray.position + Vector3(0, 0.78, 0)
	add_child(light)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.6, 0.86)
	glow.light_energy = 1.6
	glow.omni_range = 1.6
	glow.position = light.position + Vector3(0, -0.12, 0)
	add_child(glow)

	var tank: Node3D = _builder.build_node({"shape": "tank"})
	tank.position = Vector3(2.15, 0.0, -0.9)
	add_child(tank)

func _build_camera() -> void:
	var cam := Camera3D.new()
	cam.fov = 48.0
	add_child(cam)
	cam.position = Vector3(1.05, 1.15, 2.35)
	cam.look_at(Vector3(1.05, 0.12, -0.15))
	cam.make_current()

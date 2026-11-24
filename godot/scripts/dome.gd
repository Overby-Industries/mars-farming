extends Node3D
## The first playable slice of Mars Farming: a glass dome greenhouse on the Martian surface. Four regolith beds on two
## benches, a little LED light for the nights and the storms, and the sun for the rest: it follows the hour of the day,
## and dust storms dim it and cut the solar power that feeds the LEDs. Shade screens (open to start with) take the
## edge off the noon sun for the crops that mind it.
## Click a slot, sow a crop, keep it watered and fed, harvest when it is ready.
##
## Right-drag orbits, the mouse wheel zooms, left-click picks a slot. Everything you see is built here from recipes
## (docs/GRAPHICS_GUIDE.md); the growing itself is the C++ simulation behind FarmBay.

const COL_PANEL := Color(0.10, 0.06, 0.05, 0.86)
const COL_RUST := Color("d2682f")
const COL_CLOUD := Color("efe6da")
const COL_SKY_TOP := Color(0.60, 0.43, 0.31)
const COL_SKY_HORIZON := Color(0.88, 0.64, 0.43)
const COL_STORM_TOP := Color(0.40, 0.29, 0.22)
const COL_STORM_HORIZON := Color(0.52, 0.38, 0.28)

const DOME_R := 7.0
const BED_ROWS := 2
const BED_COLS := 4
const BED_CENTERS := [Vector3(-0.78, 0.80, -0.95), Vector3(0.78, 0.80, -0.95), Vector3(-0.78, 0.80, 0.65), Vector3(0.78, 0.80, 0.65)]
const SPEEDS := [["Pause", 0.0], ["1x", 1.0], ["4x", 4.0], ["16x", 16.0], ["64x", 64.0]]

# What the sun and the solar panels give under clear skies. DESIGN VALUES, not measurements.
const SUN_PEAK_PPFD := 650.0     # umol/m2/s at the canopy at noon, through the dome glazing
const SOLAR_BUDGET_W := 360.0    # watts the panels can give the LEDs on a clear day
const ICE_MELT_L_DAY := 0.6      # litres of ice-melt a dome adds to its reserve each day (the dehumidifier loses a tenth of what the plants breathe out)
const STORM_SEED := 42

# The Blender-modelled props (blender/build_assets.py); each replaces its procedural twin through the "model" seam.
const MODEL_BED := "res://models/regolith_bed.glb"
const MODEL_LIGHT := "res://models/led_bar.glb"
const MODEL_TANK := "res://models/ice_tank.glb"
const MODEL_CRATE := "res://models/supply_crate.glb"
const MODEL_AIRLOCK := "res://models/airlock.glb"

const REFRESH_SECONDS := 0.25

# How high the LED bars hang above a bench top (the soil is 0.17 m higher still) and where their wires end. Low bars used to
# cut across the far beds in the start view and poke into a full-grown tomato; at 1.55 m they clear the tallest crop (0.7 m)
# by more than half a metre, and from the start view and the orbit views around it no bar hides a slot (dome_test.gd).
const LIGHT_HEIGHT := 1.55
const ROOM_TOP := 3.8

# The crew astronaut (scripts/astronaut.gd puts it together from the modular components in models/astronaut/). It stands
# on the walkway in front of the near bench, beside its left-hand end, looking over the beds at the dome and the plain beyond.
const Astronaut = preload("res://scripts/astronaut.gd")
const ASTRONAUT_POS := Vector3(-1.7, 0.0, 1.65)
const ASTRONAUT_YAW_DEG := -12.0          # 0 faces down the dome, away from the airlock; negative turns toward the beds on its right

const SlotButtons = preload("res://scripts/slot_buttons.gd")
const CrewVoice = preload("res://scripts/crew_voice.gd")
const ColonyUI = preload("res://scripts/colony_ui.gd")
const Settlement = preload("res://scripts/settlement.gd")
const Weather = preload("res://scripts/weather.gd")
const SETTLEMENT_SCENE := "res://scenes/settlement.tscn"      # the overview of the domes and the sites for new ones (scripts/settlement_view.gd)
const MAX_SITES := 8                                           # sites for domes on the overview: six, and two more beyond the airlocks once the air allows open-air farming
const MAX_UNITS := 6                                           # domes the colony may build at first (core/colony.hpp: kMaxUnits is the station's four)
const OPEN_AIR_UNITS := 2                                      # ... and this many more once the air has thickened enough to farm in the open
const COL_AIR_TOP := Color(0.36, 0.55, 0.82)                   # the sky the plants make: blue overhead ...
const COL_AIR_HORIZON := Color(0.78, 0.84, 0.88)               # ... pale at the horizon
const TRAINING_SCENE := "res://scenes/training.tscn"      # the how-to-play training for new players (scripts/training.gd)

var bay := FarmBay.new()
var builder := FarmShapeBuilder.new()
var slot_buttons: Control                  # the floating buttons over the slots (scripts/slot_buttons.gd)
var voice: Node                            # the crew member's voice (scripts/crew_voice.gd)
var hud_palette := {}                       # the HUD's accent, panel and text colours; the training scene dresses its coach panel to match
var colony_ui: Control                     # the colony bar, the difficulty picker, the ending and the leaderboard (scripts/colony_ui.gd); none while the training hosts the game
var ask_difficulty := DisplayServer.get_name() != "headless"      # open the difficulty picker with the scene; headless runs (the tests) start as a sandbox
var colony_place := "dome"                    # how the ending texts name the place
var unit_index := 0                        # which dome of the settlement this scene shows (the first, unless the overview sent the player to another)
var colony_bay: FarmBay                    # the bay that holds the colony: the first dome's, whichever dome this scene shows
var unit_noun := "dome"                    # what a unit is called here
var colony_tuning := {"demand": [0.5, 0.6, 0.6], "reserve": [1.0, 1.6, 1.6]}                    # scales for what this bay can grow, by difficulty: {"demand": [...], "reserve": [...]}, 1.0 when absent
# The dome grows less than the station (its potato takes about 150 days under the sun, and storms dim it): its colony asks for
# 0.5 to 0.6 of the food of the station's, with a longer reserve on the two harder modes (see tests/test_colony.cpp).
var astronaut: Node3D
var astronaut_recipe := {}                  # optional look of the crew member (scripts/astronaut.gd lists the keys); set before the scene enters the tree

var selected := Vector2i(-1, -1)          # (bed, slot), or (-1, -1)
var crop_key := "potato"

var _weather: Weather                      # the dust and the sun's power, shared by every dome of the settlement (scripts/weather.gd)
var tau: float:                            # the dust optical depth the bay is using now (0.5 = a clear day)
	get:
		return _weather.tau
	set(v):
		_weather.tau = v
var storm_active: bool:
	get:
		return _weather.storm_active
	set(v):
		_weather.storm_active = v

var _tray_recipe := {}
var _slot_offsets: PackedVector3Array
var _plants := {}
var _plant_keys := {}
var _bars: Array = []                      # [{node, box (world), meshes, fade, blocking}] per LED bar, see fade_blocking_lights()
var _lights: Array = []
var _ring: MeshInstance3D
var _refresh := 0.0
var _species: Array = []

var _next_storm_sol: int:                  # (the weather keeps the schedule; the tests move it)
	get:
		return _weather.next_storm_sol
	set(v):
		_weather.next_storm_sol = v
var _storm: Dictionary:
	get:
		return _weather.storm
	set(v):
		_weather.storm = v
var _ground_mat: StandardMaterial3D       # the plain: it greens as the air thickens
var _air := 0.0                            # how far the colony's plants have thickened the air (0 to 1), refreshed a few times a second

var _sun: DirectionalLight3D
var _env: Environment
var _sky: ProceduralSkyMaterial
var _lamp: OmniLight3D

var _cam: Camera3D
var _pivot: Node3D
# The start view: over the astronaut's shoulder at the benches, the dome and the Martian plain beyond. The pivot sits left
# of the middle so the walkway is in the picture; every slot stays clear of the HUD panels (dome_test.gd checks).
const START_PIVOT := Vector3(-0.4, 1.0, 0.5)
var _yaw := 0.27
var _pitch := -0.42
var _dist := 5.7
var _orbiting := false

# HUD
var _status_label: Label
var _storm_label: Label
var _tank_bar: ProgressBar
var _harvest_label: Label
var _sel_title: Label
var _sel_info: Label
var _sel_progress: ProgressBar
var _sel_health: ProgressBar
var _crop_picker: OptionButton
var _plant_btn: Button
var _sow_btn: Button
var _water_btn: Button
var _feed_btn: Button
var _harvest_btn: Button
var _remove_btn: Button
var _auto_check: CheckBox
var _led_slider: HSlider
var _shade_slider: HSlider
var _toast: Label
var _toast_time := 0.0

# A bay as this game's domes are: four beds of eight slots under the Martian sun, with a little LED light for the nights (the settlement
# builds every dome after the first with this).
static func make_bay() -> FarmBay:
	var b := FarmBay.new()
	for i in BED_CENTERS.size():
		b.add_bed(BED_ROWS, BED_COLS, 0.72)
	b.time_scale = 4.0
	b.set_setting("sun_peak_ppfd", SUN_PEAK_PPFD)
	b.set_setting("temp_c", 19.0)
	b.set_setting("temp_swing_c", 6.0)
	b.set_setting("light_on_hour", 18.0)
	b.set_setting("light_off_hour", 0.0)          # LEDs from 18:00 to midnight: a supplement, not the main light
	b.set_setting("power_budget_w", SOLAR_BUDGET_W)
	b.set_setting("shade", 0.0)                   # screens open: closing them costs light, it never adds any
	b.set_setting("tank_capacity_l", 120.0)
	b.set_setting("tank_l", 80.0)
	b.set_setting("tank_resupply_l_day", ICE_MELT_L_DAY)      # the dome melts ice from the regolith, so the reserve lasts as long as the settlement does
	for i in BED_CENTERS.size():
		b.set_bed_light_level(i, 0.5)
	return b

func _ready() -> void:
	var st: Node = null if has_meta("training") else Settlement.peek()
	bay.free()                                    # (the default one: this scene gets its own below, or a dome of the settlement)
	if st != null and st.has_unit(st.current):    # a settlement is under way: this scene shows one of its domes
		unit_index = st.current
		bay = st.unit_bay(unit_index)
		colony_bay = st.primary()
		_weather = st.world as Weather
	else:
		bay = make_bay()
		bay.name = "Bay"
		add_child(bay)
		colony_bay = bay
		colony_bay.setup_settlement(MAX_UNITS, true, OPEN_AIR_UNITS)      # Mars is terraformed by its plants: the colony tracks the air (core/terraform.hpp)
		_weather = Weather.new()
	_weather.say = Callable(self, "_say")
	_weather.attach(colony_bay)                   # storms are scheduled by the sols of the colony's own bay
	_weather.apply(bay)
	_species = bay.get_species_list()
	bay.plant_stage_changed.connect(_on_stage_changed)
	bay.plant_died.connect(func(b, s): _say("A plant in bed %d died" % (b + 1)))

	get_viewport().msaa_3d = Viewport.MSAA_4X       # the suit's plates and hoses have fine edges
	_build_environment()
	_build_surface()
	_build_dome()
	_build_beds()
	_build_astronaut()
	_build_camera()
	_build_hud()
	_apply_camera()
	_refresh_all()
	_update_sky()

# ---------------------------------------------------------------------------------------------------------
# the world
# ---------------------------------------------------------------------------------------------------------

func _build_environment() -> void:
	_sky = ProceduralSkyMaterial.new()
	_sky.sky_top_color = COL_SKY_TOP
	_sky.sky_horizon_color = COL_SKY_HORIZON
	_sky.ground_horizon_color = Color(0.5, 0.3, 0.2)
	_sky.ground_bottom_color = Color(0.3, 0.17, 0.11)
	var sky := Sky.new()
	sky.sky_material = _sky
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.80, 0.68, 0.58)
	_env.ambient_light_energy = 0.7
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.glow_enabled = true
	_env.glow_intensity = 0.4
	_env.fog_enabled = true
	_env.fog_light_color = COL_SKY_HORIZON
	_env.fog_density = 0.002
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.light_color = Color("ffe2c0")
	_sun.shadow_enabled = true
	add_child(_sun)

	# a soft lamp inside the dome so the nights are dim, not black
	_lamp = OmniLight3D.new()
	_lamp.light_color = Color("fff0dc")
	_lamp.omni_range = 9.0
	_lamp.position = Vector3(0, 4.5, 0)
	add_child(_lamp)

func _build_surface() -> void:
	var gen := FarmSkinGenerator.new()
	var tex := gen.generate_texture({"kind": "soil", "seed": 21, "frequency": 0.03, "dark_color": Color("3a170c"), "base_color": Color("8c4220"), "highlight_color": Color("c97a45")}, 512, 512)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(240, 240)
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = tex
	gm.uv1_scale = Vector3(40, 40, 1)
	gm.roughness = 1.0
	_ground_mat = gm
	plane.material = gm
	ground.mesh = plane
	ground.position = Vector3(0, -0.02, 0)
	add_child(ground)

	# scattered basalt rocks, and low hills on the horizon
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in 70:
		var ang := rng.randf_range(0.0, TAU)
		var dist := rng.randf_range(DOME_R + 1.5, 60.0)
		var r := rng.randf_range(0.15, 0.9) * (1.0 + dist / 60.0)
		var rock: Node3D = builder.build_node({"shape": "sphere", "name": "Rock", "radius": r, "albedo_color": Color(0.22, 0.15, 0.12).lerp(Color(0.4, 0.24, 0.16), rng.randf()), "roughness": 1.0})
		rock.position = Vector3(cos(ang) * dist, r * 0.15, sin(ang) * dist)
		rock.scale = Vector3(1.0, rng.randf_range(0.4, 0.8), rng.randf_range(0.7, 1.2))
		rock.rotation.y = rng.randf_range(0.0, TAU)
		add_child(rock)
	for i in 6:
		var hill: Node3D = builder.build_node({"shape": "sphere", "name": "Hill", "radius": 30.0, "albedo_color": Color(0.5, 0.28, 0.17), "roughness": 1.0})
		hill.position = Vector3(-120 + i * 48.0, -8.0, -110.0 - (i % 2) * 20.0)
		hill.scale = Vector3(1.8, 0.45, 1.0)
		add_child(hill)

func _build_dome() -> void:
	# glass, a floor, and a frame of ribs
	var glass := MeshInstance3D.new()
	var hemi := SphereMesh.new()
	hemi.radius = DOME_R
	hemi.height = DOME_R
	hemi.is_hemisphere = true
	hemi.radial_segments = 48
	hemi.rings = 16
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.82, 0.88, 0.92, 0.10)
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.roughness = 0.05
	gm.metallic = 0.1
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	hemi.material = gm
	glass.mesh = hemi
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(glass)

	var rib_mat := StandardMaterial3D.new()
	rib_mat.albedo_color = COL_CLOUD
	rib_mat.roughness = 0.5
	rib_mat.metallic = 0.4
	for k in 4:   # vertical rings: their upper halves are the meridian ribs, the lower halves are underground
		var rib := MeshInstance3D.new()
		var t := TorusMesh.new()
		t.inner_radius = DOME_R - 0.05
		t.outer_radius = DOME_R + 0.05
		t.rings = 48
		t.ring_segments = 8
		t.material = rib_mat
		rib.mesh = t
		rib.rotation = Vector3(PI * 0.5, PI * float(k) / 4.0, 0)
		rib.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # a web of rib shadows hides the beds
		add_child(rib)
	for lat in [0.35, 0.7, 1.05]:   # horizontal rings
		var band := MeshInstance3D.new()
		var t2 := TorusMesh.new()
		t2.inner_radius = DOME_R * cos(lat) - 0.05
		t2.outer_radius = DOME_R * cos(lat) + 0.05
		t2.rings = 48
		t2.ring_segments = 8
		t2.material = rib_mat
		band.mesh = t2
		band.position = Vector3(0, DOME_R * sin(lat), 0)
		band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(band)
	# the foundation: a rust ring around the rim (a solid disc here would bury everything standing on the floor)
	var base := MeshInstance3D.new()
	base.name = "BaseRing"
	var base_torus := TorusMesh.new()
	base_torus.inner_radius = DOME_R - 0.1
	base_torus.outer_radius = DOME_R + 0.3
	base_torus.rings = 64
	base_torus.ring_segments = 12
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = Color("c5602e")
	base_mat.roughness = 0.6
	base_mat.metallic = 0.3
	base_torus.material = base_mat
	base.mesh = base_torus
	base.position = Vector3(0, 0.02, 0)
	add_child(base)
	var floor_disc := builder.build_node({"shape": "cylinder", "name": "Floor", "radius": DOME_R - 0.1, "height": 0.1, "albedo_color": Color("8d837b"), "roughness": 0.6}) as Node3D
	floor_disc.position = Vector3(0, -0.04, 0)
	add_child(floor_disc)

	# the airlock in the dome wall, facing the middle
	var lock: Node3D = builder.build_node({"shape": "box", "name": "Airlock", "model": MODEL_AIRLOCK, "size": Vector3(1.4, 2.2, 0.4)})
	lock.position = Vector3(0, 0.0, DOME_R - 0.55)
	lock.rotation_degrees.y = 180.0
	add_child(lock)
	lock.add_to_group("furniture")

	# two benches the beds stand on
	for z in [-0.95, 0.65]:
		_box("BenchTop", Vector3(0, 0.76, z), Vector3(3.5, 0.04, 0.74), Color("5a463d"), 0.45, 0.5)
		for x in [-1.65, 1.65]:
			for dz in [-0.3, 0.3]:
				_box("BenchLeg", Vector3(x, 0.37, z + dz), Vector3(0.05, 0.74, 0.05), Color("9a9088"), 0.35, 0.8)
		_box("BenchTrim", Vector3(0, 0.74, z + 0.372), Vector3(3.5, 0.03, 0.01), COL_RUST, 0.4, 0.5)

func _build_beds() -> void:
	var soil_skin := {"kind": "soil", "seed": 5, "dark_color": Color("2e140a"), "base_color": Color("6e3b22"), "highlight_color": Color("a8683c")}
	_tray_recipe = {"shape": "planter_tray", "rows": BED_ROWS, "cols": BED_COLS, "soil_skin": soil_skin, "model": MODEL_BED,
			"albedo_color": Color("efe6da"), "accent_color": COL_RUST, "base_color": Color("2e2825"), "soil_color": Color("6e3b22")}
	_slot_offsets = builder.get_slot_positions(_tray_recipe)

	for bi in BED_CENTERS.size():
		var origin: Vector3 = BED_CENTERS[bi]
		var tray: Node3D = builder.build_node(_tray_recipe)
		tray.name = "Bed%d" % bi
		tray.position = origin
		add_child(tray)
		tray.add_to_group("furniture")

		# an LED bar hung LIGHT_HEIGHT above the bench, well clear of the tallest crop and out of the way of the camera
		var light: Node3D = builder.build_node({"shape": "grow_light", "model": MODEL_LIGHT, "albedo_color": Color("efe6da"), "accent_color": COL_RUST})
		light.name = "GrowLight%d" % bi
		light.position = origin + Vector3(0, LIGHT_HEIGHT, 0)
		add_child(light)
		light.add_to_group("furniture")
		var bar_meshes := _bar_meshes(light)
		var bar_box := AABB()
		for i in bar_meshes.size():
			var mi := bar_meshes[i] as MeshInstance3D
			var b := mi.global_transform * mi.mesh.get_aabb()
			bar_box = b if i == 0 else bar_box.merge(b)
		_bars.append({"node": light, "box": bar_box, "meshes": bar_meshes, "fade": 0.0, "blocking": false})
		var omni := OmniLight3D.new()
		omni.light_color = Color(1.0, 0.78, 0.9)
		omni.omni_range = 2.8                       # far enough to reach the soil from that height
		omni.light_energy = 1.0
		omni.position = light.position + Vector3(0, -0.15, 0)
		add_child(omni)
		_lights.append({"led": _find_led(light), "omni": omni})
		var wire_from := light.position.y + 0.12    # wires from the bar's own hangers up into the dome's frame
		for sx in [-0.4, 0.4]:
			_box("Hanger", Vector3(origin.x + sx, (wire_from + ROOM_TOP) * 0.5, origin.z), Vector3(0.012, ROOM_TOP - wire_from, 0.012), Color("9a9088"), 0.4, 0.8)

		for si in _slot_offsets.size():
			var body := StaticBody3D.new()
			body.set_meta("slot", Vector2i(bi, si))
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.12, 0.46, 0.12)
			shape.shape = box
			body.add_child(shape)
			body.position = origin + _slot_offsets[si] + Vector3(0, 0.22, 0)
			add_child(body)

	# the ice-melt tank beside the benches, and supply crates by the airlock
	var tank: Node3D = builder.build_node({"shape": "tank", "model": MODEL_TANK, "albedo_color": Color("efe6da"), "accent_color": COL_RUST})
	tank.position = Vector3(-3.7, 0.0, -2.4)
	add_child(tank)
	tank.add_to_group("furniture")
	for spec in [[Vector3(1.9, 0.0, 5.3), 8.0], [Vector3(1.9, 0.25, 5.3), -5.0], [Vector3(2.45, 0.0, 5.4), -12.0], [Vector3(-1.9, 0.0, 5.3), 15.0]]:
		var crate: Node3D = builder.build_node({"shape": "box", "name": "SupplyCrate", "model": MODEL_CRATE, "size": Vector3(0.4, 0.25, 0.3)})
		crate.position = spec[0]
		crate.rotation_degrees.y = spec[1]
		add_child(crate)
		crate.add_to_group("furniture")

	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.058
	torus.outer_radius = 0.07
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COL_RUST
	mat.emission_enabled = true
	mat.emission = Color("ffb070")
	mat.emission_energy_multiplier = 2.5
	torus.material = mat
	_ring.mesh = torus
	_ring.visible = false
	add_child(_ring)

func _build_astronaut() -> void:
	astronaut = Astronaut.new()
	astronaut.name = "Astronaut"
	astronaut.recipe = astronaut_recipe
	astronaut.position = ASTRONAUT_POS
	astronaut.rotation_degrees.y = ASTRONAUT_YAW_DEG
	add_child(astronaut)

func _build_camera() -> void:
	_pivot = Node3D.new()
	_pivot.position = START_PIVOT
	add_child(_pivot)
	_cam = Camera3D.new()
	_cam.fov = 45.0
	_cam.far = 400.0
	_pivot.add_child(_cam)
	_cam.make_current()

# ---------------------------------------------------------------------------------------------------------
# weather: the sun, the sky and the dust
# ---------------------------------------------------------------------------------------------------------

func start_storm(peak: float, hold_hours: float) -> void:
	_weather.start_storm(peak, hold_hours)

# With a settlement the weather moves with the settlement's clock (scripts/settlement.gd), whichever scene is on show.
func _settlement_moves_the_weather() -> bool:
	var st: Node = null if has_meta("training") else Settlement.peek()
	return st != null and st.world == _weather

# step the whole world by game hours, one hour at a time (what the tests and the screenshot scripts use): the weather and every dome
func advance_world(game_hours: float) -> void:
	var st: Node = null if has_meta("training") else Settlement.peek()
	if st != null and st.world == _weather:
		st.advance_all(game_hours)
		return
	var left := game_hours
	while left > 1e-9:
		var dt := minf(1.0, left)
		_weather.advance(dt, [bay])
		bay.advance_hours(dt)
		left -= dt

func _update_sky() -> void:
	var s := bay.get_status()
	var hour: float = s["clock_h"]
	var elev := 0.0
	if hour > 6.0 and hour < 18.0:
		elev = sin(PI * (hour - 6.0) / 12.0)
	var trans := exp(-0.5 * maxf(0.0, tau - 0.5))
	var storm_mix := clampf((tau - 0.5) / 3.0, 0.0, 1.0)
	var day_light := clampf(elev * 3.0, 0.0, 1.0)
	_sky.sky_top_color = COL_SKY_TOP.lerp(COL_STORM_TOP, storm_mix).lerp(COL_AIR_TOP, _air * 0.85)
	_sky.sky_horizon_color = COL_SKY_HORIZON.lerp(COL_STORM_HORIZON, storm_mix).lerp(COL_AIR_HORIZON, _air * 0.7)
	_sky.sky_energy_multiplier = 0.06 + 0.94 * day_light
	_env.fog_light_color = _sky.sky_horizon_color
	_env.fog_density = 0.0015 + 0.012 * storm_mix
	_env.tonemap_exposure = lerpf(1.0, 0.68, storm_mix)      # the whole picture darkens in a storm
	_env.ambient_light_energy = 0.18 + 0.55 * day_light * (0.4 + 0.6 * trans)
	_sun.light_energy = 1.5 * elev * (0.3 + 0.7 * trans)
	_sun.visible = elev > 0.01
	_sun.rotation_degrees = Vector3(-(6.0 + 70.0 * elev), lerpf(100.0, -100.0, clampf((hour - 6.0) / 12.0, 0.0, 1.0)), 0.0)
	_lamp.light_energy = 0.25 + 0.35 * (1.0 - day_light)

func _process(delta: float) -> void:
	if bay.time_scale > 0.0 and not _settlement_moves_the_weather():
		_weather.advance(minf(delta * bay.time_scale, 6.0), [bay])
	_refresh += delta
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast.modulate.a = clampf(_toast_time, 0.0, 1.0)
	_update_sky()
	if _refresh >= REFRESH_SECONDS:
		_refresh = 0.0
		for b in BED_CENTERS.size():
			for s in BED_ROWS * BED_COLS:
				_refresh_slot(b, s)
		_refresh_hud()
	var on: bool = bay.get_status()["lights_on"]
	for i in _lights.size():
		var led: StandardMaterial3D = _lights[i]["led"]
		var level: float = bay.get_bed_info(i)["light_level"]
		if led != null:
			led.emission_energy_multiplier = (2.5 * (0.35 + 0.65 * level)) if on else 0.0
		(_lights[i]["omni"] as OmniLight3D).light_energy = (1.7 * level) if on else 0.0
	fade_blocking_lights(delta)

# ---------------------------------------------------------------------------------------------------------
# the HUD (the panel helpers below are shared with the station game)
# ---------------------------------------------------------------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var theme := Theme.new()
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = {"normal": Color(0.17, 0.09, 0.07, 0.95), "hover": Color(0.30, 0.15, 0.10, 1.0), "pressed": Color(0.50, 0.25, 0.12, 1.0), "disabled": Color(0.12, 0.09, 0.08, 0.7)}[state]
		sb.border_color = COL_RUST if state != "disabled" else Color(0.4, 0.38, 0.36)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(4)
		sb.set_content_margin_all(6)
		theme.set_stylebox(state, "Button", sb)
	theme.set_color("font_color", "Button", COL_CLOUD)
	theme.set_color("font_disabled_color", "Button", Color(0.55, 0.52, 0.5))
	theme.set_color("font_color", "CheckBox", COL_CLOUD)
	root.theme = theme

	# floating buttons over the crop slots (Harvest, Water, Feed ...), added first so the panels below draw over them
	slot_buttons = SlotButtons.new()
	root.add_child(slot_buttons)
	slot_buttons.setup(self, {"feed": COL_RUST, "quiet": Color(0.12, 0.07, 0.05, 0.66), "quiet_text": COL_CLOUD, "selected": Color("ffb070")})

	var left := MarginContainer.new()
	left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	left.add_theme_constant_override("margin_left", 14)
	left.add_theme_constant_override("margin_top", 14)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(left)
	var lbox := _panel(left)
	lbox.custom_minimum_size = Vector2(310, 0)
	_label(lbox, "DOME GREENHOUSE %d" % (unit_index + 1), 16, COL_RUST)
	_status_label = _label(lbox, "")
	_storm_label = _label(lbox, "", 13, Color(1.0, 0.75, 0.45))
	_label(lbox, "Ice-melt reserve", 12, Color(0.85, 0.78, 0.7))
	_tank_bar = _bar(lbox, Color("5fb6e8"))
	_auto_check = CheckBox.new()
	_auto_check.text = "Automatic irrigation"
	_auto_check.toggled.connect(func(on): bay.set_setting("auto_irrigate", on))
	lbox.add_child(_auto_check)
	_label(lbox, "Shade screens (0 = open, 1 = shut)", 12, Color(0.85, 0.78, 0.7))
	_shade_slider = HSlider.new()
	_shade_slider.min_value = 0.0
	_shade_slider.max_value = 1.0
	_shade_slider.step = 0.05
	_shade_slider.value = 0.0
	_shade_slider.value_changed.connect(func(v): bay.set_setting("shade", v))
	lbox.add_child(_shade_slider)
	_label(lbox, "LED brightness (all beds)", 12, Color(0.85, 0.78, 0.7))
	_led_slider = HSlider.new()
	_led_slider.min_value = 0.0
	_led_slider.max_value = 1.0
	_led_slider.step = 0.05
	_led_slider.value = 0.5
	_led_slider.value_changed.connect(func(v): for i in BED_CENTERS.size(): bay.set_bed_light_level(i, v))
	lbox.add_child(_led_slider)
	_button(lbox, "Call a dust storm (test)", func(): if not storm_active: start_storm(3.5, 48.0))
	_harvest_label = _label(lbox, "", 13, Color(0.85, 0.95, 0.75))

	var right := MarginContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right.add_theme_constant_override("margin_right", 14)
	right.add_theme_constant_override("margin_top", 14)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(right)
	var rbox := _panel(right)
	rbox.custom_minimum_size = Vector2(290, 0)
	_sel_title = _label(rbox, "Nothing selected", 16, COL_RUST)
	_sel_info = _label(rbox, "Click a slot in a bed.", 13)
	_label(rbox, "Growth", 12, Color(0.85, 0.78, 0.7))
	_sel_progress = _bar(rbox, Color("8bd35a"))
	_label(rbox, "Health", 12, Color(0.85, 0.78, 0.7))
	_sel_health = _bar(rbox, Color("e8a33d"))
	_crop_picker = OptionButton.new()
	for sp in _species:
		_crop_picker.add_item("%s (%d days)" % [sp["name"], int(sp["days_to_mature"])])
	_crop_picker.select(3)   # potato: the Martian staple
	_crop_picker.item_selected.connect(func(i): crop_key = _species[i]["key"])
	rbox.add_child(_crop_picker)
	_plant_btn = _button(rbox, "Sow this slot", action_plant)
	_sow_btn = _button(rbox, "Sow the whole bed", func(): action_sow_bed())
	_water_btn = _button(rbox, "Water the bed (+2 L)", func(): action_water())
	_feed_btn = _button(rbox, "Feed the bed (+1 unit)", func(): action_feed())
	_harvest_btn = _button(rbox, "Harvest", func(): action_harvest())
	_remove_btn = _button(rbox, "Clear the slot", func(): action_remove())

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
	_button(row, "Ask crew (C)", func(): voice.ask())
	var voice_check := CheckBox.new()
	voice_check.text = "Crew voice"
	voice_check.button_pressed = true
	voice_check.toggled.connect(func(on): voice.set_audio(on))
	row.add_child(voice_check)
	var how_sep := VSeparator.new()
	row.add_child(how_sep)
	var how_btn := _button(row, "How to play", func(): get_tree().change_scene_to_file(TRAINING_SCENE))
	how_sep.visible = not has_meta("training")        # the training scene hosts this farm and shows its own coach instead
	how_btn.visible = not has_meta("training")

	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y = 70
	_toast.add_theme_font_size_override("font_size", 18)
	_toast.add_theme_color_override("font_color", Color("ffb070"))
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_toast.modulate.a = 0.0
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toast)

	# the crew member's voice: speech, captions along the bottom, and the astronaut turning to look at what it describes
	voice = CrewVoice.new()
	add_child(voice)
	hud_palette = {"accent": COL_RUST, "panel": COL_PANEL, "text": COL_CLOUD}
	voice.setup(self, astronaut, root, hud_palette)
	voice.medium = "regolith"
	voice.reservoir = "ice-melt reserve"
	voice.intro = "Dome greenhouse online. Pick a slot and I will tell you about it, or press Ask crew for what to do next. New here? Press How to play."

	# the colony: its bar, the choice of difficulty and voice, the ending and the leaderboard (the training hosts the game without one)
	if not has_meta("training"):
		colony_ui = ColonyUI.new()
		root.add_child(colony_ui)
		colony_ui.setup(self, hud_palette, ask_difficulty)

# What the crew voice may add to its usual advice (scripts/crew_voice.gd calls this): the colony's food, the dust and the solar power.
func voice_notes() -> Array:
	var notes: Array = colony_ui.voice_notes() if colony_ui != null else []
	notes.append_array(_weather_notes())
	return notes

# What cannot wait (scripts/crew_voice.gd calls this): the colony is out of food.
func urgent_notes() -> Array:
	return colony_ui.urgent_notes() if colony_ui != null else []

# While the difficulty picker, an ending or the leaderboard covers the game, the crew does not chat (scripts/crew_voice.gd asks).
func voice_held() -> bool:
	return colony_ui != null and ["picker", "ending", "board"].has(colony_ui.phase)

func _weather_notes() -> Array:
	var s := bay.get_status()
	var sun := roundi(100.0 * exp(-0.5 * maxf(0.0, tau - 0.5)))
	if storm_active and tau > 1.5:
		return [{"key": "storm", "text": "A dust storm is up. Sunlight is down to %d percent and the solar array gives %d percent of its power. Expect dim LEDs tonight, and do not count on the sun." % [sun, roundi(100.0 * s["power_budget_w"] / SOLAR_BUDGET_W)]}]
	if s["lights_on"] and s["power_demand_w"] > s["power_budget_w"] * 1.001:
		return [{"key": "power", "text": "The LEDs want more power than the array can give, so every bed is dimmed. Turn the LED brightness down to share it out."}]
	return []

func _refresh_hud() -> void:
	if _status_label == null:
		return
	var air: Dictionary = colony_bay.get_terraform()
	_air = float(air["progress"]) if bool(air["enabled"]) else 0.0
	if _ground_mat != null:
		_ground_mat.albedo_color = Color.WHITE.lerp(Color(0.66, 0.92, 0.55), smoothstep(0.3, 1.0, _air))     # the soil greens
	var s := bay.get_status()
	var hh := int(s["clock_h"])
	var mm := int((s["clock_h"] - hh) * 60.0)
	_status_label.text = "Sol %d   %02d:%02d\nSunlight %.0f umol/m2/s  (dust tau %.1f)\nInside %.1f C   LEDs %s\nPower %.0f of %.0f W (%.1f kWh used)\nNutrient stock %.1f units\nWater %.0f / %.0f L (lost %.1f L)" % [
		s["day"], hh, mm, s["sun_ppfd"], tau, s["temp_c"], "ON" if s["lights_on"] else "off", s["power_demand_w"], s["power_budget_w"],
		s["energy_kwh"], s["nutrient_stock"], s["tank_l"], s["tank_capacity_l"], s["water_lost_l"]]
	_storm_label.text = ("DUST STORM: sunlight at %.0f%%, solar power at %.0f%%" % [100.0 * exp(-0.5 * maxf(0.0, tau - 0.5)), 100.0 * s["power_budget_w"] / SOLAR_BUDGET_W]) if storm_active else "Sky clear"
	_tank_bar.value = s["tank_l"] / maxf(s["tank_capacity_l"], 0.001)
	var parts: PackedStringArray = []
	for k in s["harvested_by_species"]:
		if s["harvested_by_species"][k] > 0.0:
			parts.append("%s %.2f kg" % [k, s["harvested_by_species"][k]])
	_harvest_label.text = "Harvested %.2f kg%s" % [s["harvested_kg"], ("\n" + ", ".join(parts)) if parts.size() > 0 else ""]

	var has := selected.x >= 0
	for b in [_plant_btn, _sow_btn, _water_btn, _feed_btn, _harvest_btn, _remove_btn, _crop_picker]:
		b.disabled = not has
	if not has:
		_sel_title.text = "Nothing selected"
		_sel_info.text = "Click a slot in a bed."
		_sel_progress.value = 0.0
		_sel_health.value = 0.0
		return
	var info := bay.get_bed_info(selected.x)
	var p := bay.get_plant(selected.x, selected.y)
	_sel_title.text = "Bed %d, slot %d" % [selected.x + 1, selected.y + 1]
	var bed_text := "Bed: water %.1f / %.0f L, nutrients %.0f%%, light %.0f umol/m2/s" % [info["water_l"], info["water_capacity_l"], info["nutrient"] * 100.0, info["ppfd"]]
	if p["empty"]:
		_sel_info.text = "Empty.\n" + bed_text
		_sel_progress.value = 0.0
		_sel_health.value = 0.0
		_plant_btn.disabled = false
		_harvest_btn.disabled = true
		_remove_btn.disabled = true
	else:
		_sel_info.text = "%s: %s\nAge %.1f days, quality %.0f%%\n%s" % [p["name"], p["stage_name"], p["age_days"], p["quality"] * 100.0, bed_text]
		_sel_progress.value = p["progress"]
		_sel_health.value = p["health"]
		_plant_btn.disabled = true
		_harvest_btn.disabled = not p["ready"]

# ---------------------------------------------------------------------------------------------------------
# helpers shared with the station game
# ---------------------------------------------------------------------------------------------------------

func _box(name: String, pos: Vector3, size: Vector3, color: Color, rough := 0.7, metal := 0.0) -> Node3D:
	var n: Node3D = builder.build_node({"shape": "box", "name": name, "size": size, "albedo_color": color, "roughness": rough, "metallic": metal})
	n.position = pos
	add_child(n)
	if name in ["BenchTop", "BenchLeg", "BenchTrim", "Hanger"]:
		n.add_to_group("furniture")
	return n

func _find_led(light: Node) -> StandardMaterial3D:
	if light.has_meta("led_material"):
		return light.get_meta("led_material")
	return _find_material(light, "LED_Emissive")

func _find_material(node: Node, material_name: String) -> StandardMaterial3D:
	for c in node.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i)
				if m != null and m.resource_name == material_name:
					return m as StandardMaterial3D
		var deeper := _find_material(c, material_name)
		if deeper != null:
			return deeper
	return null

func _apply_camera() -> void:
	_pivot.rotation = Vector3(_pitch, _yaw, 0)
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
			_dist = clampf(_dist - 0.4, 2.0, 12.0)
			_apply_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = clampf(_dist + 0.4, 2.0, 12.0)
			_apply_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_pick(mb.position)
	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.005
		_pitch = clampf(_pitch - mm.relative.y * 0.005, -1.35, -0.1)
		_apply_camera()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C:
		voice.ask()                 # "C" asks the crew what to do next, like the Ask crew button

func _pick(screen_pos: Vector2) -> void:
	var from := _cam.project_ray_origin(screen_pos)
	var to := from + _cam.project_ray_normal(screen_pos) * 30.0
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	if hit.has("collider") and (hit["collider"] as Object).has_meta("slot"):
		var s: Vector2i = (hit["collider"] as Object).get_meta("slot")
		select_slot(s.x, s.y)
	else:
		select_slot(-1, -1)

# ---------------------------------------------------------------------------------------------------------
# actions, also what the tests drive
# ---------------------------------------------------------------------------------------------------------

func select_slot(bed: int, slot: int) -> void:
	selected = Vector2i(bed, slot)
	if bed >= 0:
		_ring.position = BED_CENTERS[bed] + _slot_offsets[slot] + Vector3(0, 0.004, 0)
	_ring.visible = bed >= 0
	_refresh_hud()

func action_plant() -> bool:
	if selected.x < 0:
		return false
	var ok := bay.plant(selected.x, selected.y, crop_key)
	_refresh_all()
	return ok

func action_sow_bed() -> int:
	if selected.x < 0:
		return 0
	var n := 0
	for s in BED_ROWS * BED_COLS:
		if bay.plant(selected.x, s, crop_key):
			n += 1
	_refresh_all()
	return n

func action_water() -> float:
	if selected.x < 0:
		return 0.0
	var moved := bay.irrigate(selected.x, 2.0)
	if moved <= 0.0:
		_say("Nothing to add: the bed is full or the tank is empty")
	_refresh_hud()
	return moved

func action_feed() -> float:
	if selected.x < 0:
		return 0.0
	var used := bay.feed(selected.x, 1.0)
	if used <= 0.0:
		_say("Nothing to add: the bed is full or the stock is out")
	_refresh_hud()
	return used

func action_harvest() -> Dictionary:
	if selected.x < 0:
		return {"ok": false}
	var h := bay.harvest(selected.x, selected.y)
	if h["ok"]:
		_say("Harvested %.2f kg of %s" % [h["kg"], h["species"]])
	_refresh_all()
	return h

func action_remove() -> bool:
	if selected.x < 0:
		return false
	var ok := bay.remove(selected.x, selected.y)
	_refresh_all()
	return ok

func set_speed(hours_per_second: float) -> void:
	var st := Settlement.peek()
	if st != null and not has_meta("training"):
		st.set_speed(hours_per_second)                     # every dome keeps the same clock
	else:
		bay.time_scale = hours_per_second

# The overview of the settlement: its domes, and the sites for new ones. The first visit hands this scene's bay and weather over.
func open_settlement() -> void:
	var st = Settlement.get_or_create(get_tree())
	if st.units.is_empty():
		st.adopt(bay, Callable(get_script(), "make_bay"), MAX_SITES)
		st.world = _weather
	st.current = unit_index
	get_tree().change_scene_to_file(SETTLEMENT_SCENE)

# ---------------------------------------------------------------------------------------------------------
# visuals that follow the simulation
# ---------------------------------------------------------------------------------------------------------

func _on_stage_changed(bed: int, slot: int, stage: int) -> void:
	_refresh_slot(bed, slot)
	if stage == FarmBay.STAGE_READY:
		_say("%s in bed %d is ready" % [bay.get_plant(bed, slot)["name"], bed + 1])

# An LED bar that stands between the camera and any slot fades to a ghost, so from any orbit angle every crop location can be
# seen and picked (the bars hang high, but a steep or sideways view can still look through one). Returns how many bars are in
# the way; `delta` is the time to fade by (the tests use a big one).
func fade_blocking_lights(delta: float) -> int:
	if _cam == null:
		return 0
	var eye := _cam.global_position
	var blocking := 0
	for bar in _bars:
		var blocks := false
		for bi in BED_CENTERS.size():
			for si in _slot_offsets.size():
				if (bar["box"] as AABB).intersects_segment(eye, BED_CENTERS[bi] + _slot_offsets[si] + Vector3(0, 0.12, 0)) != null:
					blocks = true
					break
			if blocks:
				break
		bar["blocking"] = blocks
		blocking += 1 if blocks else 0
		bar["fade"] = move_toward(bar["fade"], 0.88 if blocks else 0.0, delta * 3.0)
		for mi in bar["meshes"]:
			(mi as GeometryInstance3D).transparency = bar["fade"]
	return blocking

func _bar_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_bar_meshes(c))
	return out

func _refresh_all() -> void:
	for b in BED_CENTERS.size():
		for s in BED_ROWS * BED_COLS:
			_refresh_slot(b, s)
	_refresh_hud()

func _refresh_slot(bed: int, slot: int) -> void:
	var key := Vector2i(bed, slot)
	var p := bay.get_plant(bed, slot)
	var visual_key := "empty"
	if not p["empty"]:
		visual_key = "%s|%d|%d|%d" % [p["species"], p["stage"], int(p["progress"] * 50.0), int(p["health"] * 10.0)]
	if _plant_keys.get(key, "") == visual_key:
		return
	_plant_keys[key] = visual_key
	if _plants.has(key):
		(_plants[key] as Node3D).queue_free()
		_plants.erase(key)
	if p["empty"]:
		return
	var node: Node3D = builder.build_node({
		"shape": "plant", "species": p["species"], "progress": p["progress"], "stage": p["stage"],
		"health": p["health"], "seed": p["visual_seed"],
	})
	node.position = BED_CENTERS[bed] + _slot_offsets[slot]
	add_child(node)
	_plants[key] = node

func _say(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast_time = 3.5
	_toast.modulate.a = 1.0
	if voice != null:
		voice.on_toast(text)

func _panel(parent: Control) -> VBoxContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.border_color = COL_RUST
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	pc.add_theme_stylebox_override("panel", sb)
	parent.add_child(pc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	pc.add_child(box)
	return box

func _label(parent: Control, text: String, size := 14, color := COL_CLOUD) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l

func _button(parent: Control, text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(callback)
	parent.add_child(b)
	return b

func _bar(parent: Control, color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 14)
	bar.show_percentage = false
	bar.max_value = 1.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.1, 0.14, 0.25, 0.9)
	back.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", back)
	parent.add_child(bar)
	return bar

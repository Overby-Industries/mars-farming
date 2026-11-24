extends Node
## The settlement: every greenhouse or dome (a "unit") of the colony. Each unit is a FarmBay with its own beds, water and power; the first
## holds the colony and the others are linked to it, so what any of them harvests feeds the one crew (core/bay.hpp). The units are
## kept here, outside any scene, so they keep growing while the player looks at the settlement or walks into another unit: the farm
## scene shows one of them (`current`), the overview scene (scenes/settlement.tscn) shows them all and builds new ones.
##
## It is created the first time the player opens the overview (the farm scene hands over its own bay as the first unit) and lives under
## the window root until `reset()` (a new game, the training). A game that never opens the overview never has one, and its farm scene
## makes its own bay as before.
##
##   var st = Settlement.get_or_create(get_tree())          # const Settlement = preload("res://scripts/settlement.gd")
##   st.adopt(bay, Callable(get_script(), "make_bay"))      # the farm scene's bay becomes unit 1; make_bay() builds the others
##   st.build(site)                                          # when the colony may expand: a new bay, linked to the colony

signal unit_built(index: int)

const PATH := "res://scripts/settlement.gd"

static var instance: Node = null

var units: Array = []          # [{"bay": FarmBay, "site": int}]; the first holds the colony
var current := 0               # the unit the farm scene shows
var speed := 4.0               # game hours per second, for every unit
var factory: Callable          # () -> FarmBay set up like the first unit (a static function of the game's farm script)
var sites := 4                 # how many sites the overview shows (the colony's own limit says how many may be used)
var world = null              # what the units share that moves with time (Mars: the weather): has advance(game_hours, bays) and apply(bay)

static func peek() -> Node:
	return instance if is_instance_valid(instance) else null

static func get_or_create(tree: SceneTree) -> Node:
	if peek() != null:
		return instance
	var node: Node = (load(PATH) as GDScript).new()
	node.name = "Settlement"
	instance = node
	tree.root.add_child.call_deferred(node)
	return node

# A new game (or the training): forget every unit.
static func reset() -> void:
	var n := peek()
	instance = null
	if n != null:
		n.queue_free()

func has_unit(i: int) -> bool:
	return i >= 0 and i < units.size()

func unit_bay(i: int) -> FarmBay:
	return units[i]["bay"]

func primary() -> FarmBay:
	return units[0]["bay"] if not units.is_empty() else null

# The farm scene's bay becomes the first unit, and lives on here when the scene goes.
func adopt(bay: FarmBay, make: Callable, p_sites := 4) -> void:
	if not units.is_empty():
		return
	factory = make
	sites = p_sites
	speed = bay.time_scale
	if bay.get_parent() != self:
		bay.reparent(self)
	units.append({"bay": bay, "site": 0})

# The unit built on a site (an index into `units`), or -1.
func unit_on(site: int) -> int:
	for i in units.size():
		if int(units[i]["site"]) == site:
			return i
	return -1

func colony() -> Dictionary:
	return primary().get_colony() if primary() != null else {}

# May a unit be built on this site now? There is food to spare (a store, and a harvest behind it), the site is free, and the colony allows one more.
func can_build(site: int) -> bool:
	if units.is_empty() or site < 0 or site >= sites or unit_on(site) >= 0 or not factory.is_valid():
		return false
	var c := colony()
	return bool(c.get("expansion_ready", false)) and units.size() < int(c.get("max_units", 1))

# Build a unit on a site: the colony pays in food, a new bay is linked to it. Returns the new unit's index, or -1.
func build(site: int) -> int:
	if not can_build(site) or not primary().colony_add_unit():
		return -1
	var bay: FarmBay = factory.call()
	bay.name = "Unit%d" % (units.size() + 1)
	add_child(bay)
	bay.link_colony(primary())
	bay.time_scale = speed
	if world != null:
		world.apply(bay)                                  # (the new unit starts under the sky as it is now)
	units.append({"bay": bay, "site": site})
	unit_built.emit(units.size() - 1)
	return units.size() - 1

func bays() -> Array:
	return units.map(func(u): return u["bay"])

# The shared world (the weather) moves with the clock the units run on, whichever scene the player is in.
func _process(delta: float) -> void:
	if world != null and speed > 0.0:
		world.advance(minf(delta * speed, 6.0), bays())

# Every unit keeps the same clock.
func set_speed(hours_per_second: float) -> void:
	speed = hours_per_second
	for u in units:
		(u["bay"] as FarmBay).time_scale = hours_per_second

# Advance every unit together, an hour at a time (what the tests and the training driver use).
func advance_all(hours: float) -> void:
	var left := hours
	while left > 1e-9:
		var dt := minf(1.0, left)
		if world != null:
			world.advance(dt, bays())
		for u in units:
			(u["bay"] as FarmBay).advance_hours(dt)
		left -= dt

func total_plants() -> int:
	var n := 0
	for u in units:
		var bay: FarmBay = u["bay"]
		for b in bay.get_bed_count():
			for s in int(bay.get_bed_info(b)["slots"]):
				if not bay.get_plant(b, s)["empty"]:
					n += 1
	return n

func _exit_tree() -> void:
	if instance == self:
		instance = null

extends RefCounted
## The weather the domes share: the dust in the sky, and the solar power the panels give the LEDs because of it. A dust storm comes every
## eight to sixteen sols, builds for a day, holds for one to four, and fades over two and a half. One Weather serves the whole
## settlement: the dome scene moves it while there is only one dome, and the settlement (scripts/settlement.gd) moves it once there are
## more, so a storm goes on while the player is looking at the overview or at another dome.
##
## The numbers here are the dome's own (they were scripts/dome.gd's before there were several domes); the tests of the dome read them
## through the scene (tau, storm_active, start_storm(), advance_world()).

const SEED := 42
const SOLAR_BUDGET_W := 360.0       # watts the panels can give the LEDs on a clear day
const CLEAR_TAU := 0.5              # the dust optical depth of a clear day

var tau := CLEAR_TAU                # the dust optical depth now
var storm_active := false
var storm := {"t": 0.0, "peak": 3.0, "rise": 24.0, "hold": 48.0, "fall": 60.0}
var next_storm_sol := 6
var rng := RandomNumberGenerator.new()
var say := Callable()               # (text: String) called when a storm comes or has passed; the dome shows it as a message
var _attached: Object = null

func _init() -> void:
	rng.seed = SEED
	next_storm_sol = rng.randi_range(4, 8)

# Follow the sols of the bay that holds the colony: storms are scheduled by the day.
func attach(primary: FarmBay) -> void:
	if _attached == primary:
		return
	if is_instance_valid(_attached):
		(_attached as FarmBay).day_changed.disconnect(on_sol)
	_attached = primary
	primary.day_changed.connect(on_sol)

func start_storm(peak: float, hold_hours: float) -> void:
	storm = {"t": 0.0, "peak": peak, "rise": 24.0, "hold": hold_hours, "fall": 60.0}
	storm_active = true
	_say("A dust storm is coming: peak optical depth %.1f" % peak)

func on_sol(day: int) -> void:
	if day >= next_storm_sol and not storm_active:
		start_storm(rng.randf_range(2.5, 5.0), rng.randf_range(24.0, 96.0))
		next_storm_sol = day + rng.randi_range(8, 16)

# The solar power the dust leaves the panels.
func power_budget_w() -> float:
	return SOLAR_BUDGET_W * exp(-0.5 * maxf(0.0, tau - CLEAR_TAU))

# Put the dust and the power on a bay (a new dome starts with the sky as it is).
func apply(bay: FarmBay) -> void:
	bay.set_setting("dust_tau", tau)
	bay.set_setting("power_budget_w", power_budget_w())

# Move the storm on by some game hours; sets the dust, and with it the solar power, on every bay given.
func advance(game_hours: float, bays: Array) -> void:
	if not storm_active:
		return
	storm["t"] += game_hours
	var t: float = storm["t"]
	var rise: float = storm["rise"]
	var hold: float = storm["hold"]
	var fall: float = storm["fall"]
	var peak: float = storm["peak"]
	if t < rise:
		tau = lerpf(CLEAR_TAU, peak, t / rise)
	elif t < rise + hold:
		tau = peak
	elif t < rise + hold + fall:
		tau = lerpf(peak, CLEAR_TAU, (t - rise - hold) / fall)
	else:
		tau = CLEAR_TAU
		storm_active = false
		_say("The dust storm has passed")
	for b in bays:
		apply(b)

func _say(text: String) -> void:
	if say.is_valid():
		say.call(text)

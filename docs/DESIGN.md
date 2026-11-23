# Design

## The idea

A glass dome on Mars has to feed a crew from regolith beds. The sun is free, but it is weaker than on Earth and
the planet throws dust storms that dim it for days. The same dust cuts the output of the solar panels, and the
panels are what power the LEDs that would otherwise cover the shortfall: when the light is needed most, there is
the least power to make it. The player decides what to plant, how much to water and feed, how bright to run the
LEDs, when to close the shade screens, and rides out the storms.

It is the sibling of Aevoria Space Station Farming, which has no weather and a fixed power budget. They share the
simulation; this repository adds a sun that follows the hour, a sky, the dust, the solar coupling and a Martian
set of props.

## What exists

**The simulation** (`core/`, plain C++17, tested without Godot; the same code as the station game):

- **Crops** (`species.hpp`): butterhead lettuce, Cherry Belle radish, dwarf tomato, dwarf potato. Each has
  days to mature, preferred light (PPFD, umol/m2/s), a light ceiling, a temperature trapezoid, water use,
  nutrient use, yield and, for the bushes, when flowering and fruiting begin.
- **A plant** (`plant.hpp`) gets four growth factors between 0 and 1 each hour: light, temperature, water,
  nutrients. They multiply, and progress only advances in lit hours. Under ideal conditions on a 16-hour
  photoperiod a plant reaches Ready in exactly `days_to_mature` days; a test pins that down for every crop.
  Shortage of water or nutrients, or the wrong temperature, costs health (a plant with no water dies in about
  three days); good conditions let it recover. Stages: Seed, Sprout, Growing, Flowering, Fruiting, Ready,
  Overripe, Dead. A Ready crop keeps full value for a few days, loses value as it goes Overripe, and spoils
  after three times that window.
- **A bay** (`bay.hpp`) holds beds, a light schedule, LEDs with a power budget (over-demand dims every bed),
  a sun with a dust optical depth and a shade, a day/night temperature swing, a water tank (recycled at 90%),
  a nutrient stock, optional automatic irrigation, and an event list the game turns into signals. It advances in
  steps of at most an hour, deterministically for a given seed.
- Sunlight at the canopy is `sun_peak_ppfd x sin(arc) x exp(-0.5 x max(0, tau - 0.5)) x (1 - shade)`, where `arc`
  runs from sunrise at 06:00 to sunset at 18:00 and `tau` is the dust optical depth (0.5 on a clear day).
- Yield is `yield_kg x health x (0.5 + 0.5 x quality) x freshness`, where quality is the plant's average growth
  factor over its life.

**The dome** (`godot/scenes/dome.tscn`, `godot/scripts/dome.gd`): four regolith beds of eight slots on two
benches, an LED bar over each (hung 1.55 m above the bench, clear of every crop, and faded to a ghost when it would hide a
slot), an ice-melt tank, an airlock and supply crates, and a crew astronaut on the walkway looking over the beds, all inside
a glass dome on a rust plain. Over every slot floats a **button** that says what its plant needs next (`+` to sow, the growth
percentage, Water, Feed, Harvest or Clear) and does it when pressed (`scripts/slot_buttons.gd`; what a button says is one
function of the plant and its bed, `SlotButtons.state_of`, which the tests and the voice read too). HUD: sol and clock, sunlight
and dust, temperature, power, water, nutrient stock, harvest totals, shade, LED brightness, automatic irrigation, a storm button
for testing, time controls from pause to 64x, Ask crew and How to play.

**The crew voice** (`scripts/crew_voice.gd`) turns the same states into words: what to do next (in this order: a harvest waiting, a
dead plant, a dry bed, a hungry bed, the water and nutrient stores, a dust storm or the power budget, news, empty slots, a round of
the plants), a description of whatever is selected, and an answer to Ask crew. It is spoken by the operating system's text-to-speech
and captioned, and the astronaut looks at what it is talking about. The player can pick a male or a female voice (the gender is read from a voice's name, and only the
genders the PC has a voice for are offered). **The training** (`scenes/training.tscn`, `scripts/training.gd`)
hosts the real game with a coach panel (the dust storms are held off) and plays it through in six lessons (sow, grow, dry, harvest,
select, ask), using the same helpers (`scripts/training_driver.gd`) as the test that drives the real scene through those steps
(`tests/crew_ui_test.gd`).

**The weather** (`dome.gd`): a storm rises over 24 hours to a peak optical depth between 2.5 and 5, holds for
1 to 4 days, and clears over 60 hours. The first storm comes between sol 4 and 8 and each next one 8 to 16 sols
after the last, drawn from a seeded generator so a run repeats. While the dust is up, the sun at the canopy falls by
the factor above (at tau 4 it passes 17%), the sky turns the colour of dust and the fog thickens, and the solar
power budget falls by the same factor: 360 W becomes 63 W, which dims the LEDs on every bed.

## Placeholder numbers, and what they give

All of these are design values for a first playable slice, not measurements:

| Value | Where | Set to |
|---|---|---|
| Sun at the canopy at noon, clear, screens open | `SUN_PEAK_PPFD` in `dome.gd` | 650 umol/m2/s |
| Solar power for the LEDs on a clear day | `SOLAR_BUDGET_W` | 360 W |
| LED power per bed, light output | `core/bay.hpp` | 160 W, 2.6 umol/J |
| LED hours | `dome.gd` | 18:00 to midnight, at half brightness |
| Inside temperature | `dome.gd` | 19 C, swinging 6 C either way, warmest at 15:00 |
| Storm: peak, hold, first sol | `dome.gd` | tau 2.5 to 5, 1 to 4 days, sol 4 to 8 |

What the current values do: a dwarf potato, whose design time is 100 days under ideal light, is Ready after about
150 days under a clear sky, because the sun is above the potato's preferred light for only about nine hours around
noon, and the LEDs, at half brightness, give the bed less than the potato wants (about 250 umol/m2/s against 400).
A week-long storm at the start of the crop adds about five days (`dome_test.gd` prints both). Closing the shade
screens costs light: in a trial of two settings the potato took 11 days longer with them at 0.25 than open, and the
lettuce was Ready after 35.3 days either way, so they start open and the slider is there to be explored.

A sol here is 24 hours, as everywhere in the shared core; a real sol is 24 h 39 min.

## The colony: food, hunger, three endings, a score

The bay feeds a colony (`core/colony.hpp`, started with `start_colony(difficulty)`; without one the bay is a sandbox). Food is counted in kcal: each crop has
its energy per kilo in `species.hpp` (lettuce 150, radish 160, tomato 180, potato 770), a harvest adds `kg x kcal_per_kg` to the colony's store, and the
crew eats its day's need a little every hour. With the store empty the crew goes hungry, and a hungry spell ends the moment it eats in full again; hungry
for the whole grace period and the colony fails; kept fed for the goal period and it succeeds.

| | Easy | Intermediate | Difficult |
|---|---|---|---|
| Crew | 4 | 8 | 12 |
| Food asked of the bay | 24 kcal a day | 50 | 66 |
| Food in store at the start | 100 days | 60 | 95 |
| Hungry days before it fails | 14 | 10 | 7 |
| Days to keep them fed | 120 | 200 | 300 |
| If it fails | all evacuated home: failed | half taken home, half lost: failed | nowhere to go: extinct |
| Score multiplier | x1 | x1.5 | x2 |

**Every number here is a design value.** One bay of 32 plants grows only 30 to 80 kcal a day (a person eats 2,500), so the colony asks the bay for a
fresh-food share scaled to what it can grow, and the rest of the diet is imagined to come from elsewhere. `tests/test_colony.cpp` plays simple strategies
against each mode and pins down who wins. On the station: doing nothing fails every mode (on days 114, 70 and 102); on Easy any farming wins; on
Intermediate all lettuce fails and two beds of lettuce with two of potato win; on Difficult potatoes are essential (the first harvest is on day 105) and
so is lettuce to carry the colony until then (one bed of lettuce and three of potato win). However large a reserve a game asks for, it is cut so that the
food runs out `kMinFailureMarginDays` before the goal: a colony that grows nothing always fails. The dome grows less than the station (its potato takes about 150 days under the sun, and storms dim it), so it scales the colony with `demand_scale` and `reserve_scale`: 0.5, 0.6 and 0.6 of the demand and 1.0, 1.6 and 1.6 of the reserve for the three modes (`colony_tuning` in `dome.gd`, calibrated against the same strategies with storms).

**The score** (`Colony::score()`, shown live and ranked on the leaderboard): 3 points for each day the colony has lasted, 0.5 for each kcal grown, 150 for each
different crop harvested, 10 for each day of food in store (up to 60), 1,000 for making it, less 40 for each plant lost and 25 for each hungry day, times the
mode's multiplier, never below zero. The strategies above score about 3,500 for a win on Easy, 7,000 on Intermediate and 17,000 to 19,000 on Difficult.

**The leaderboard** (`scripts/leaderboard.gd`): the ten best runs for each mode, in `user://leaderboard.json` on this PC only; nothing is sent anywhere. An
online board would need a server to send scores to, and `submit()` and `entries()` are all the game calls.

## What does not exist yet

Dust settling on the panels and the glass, equipment
faults and events, an online leaderboard, pressure and radiation, crops picked for Mars, regolith that has to be washed, a save file,
sound effects and music (the crew speaks, but nothing else makes a noise), and any tuning beyond a first guess. The two farming games share no library yet; `core/` is a copy.

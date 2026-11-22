# Graphics guide

The dome follows the same rule as Aevoria Simulator (see its `docs/GRAPHICS_GUIDE.md`): the visuals are generated
from data. A look is a dictionary; only a genuinely new shape needs C++. Scale is **1 Godot unit = 1 metre**.
The palette is Martian: dusty white `#EDE6DC`, rust orange `#C5602E`, basalt `#2E2825`, regolith `#6E3B22`,
and a butterscotch sky.

## Data or code?

| You want to... | Where | Rebuild? |
|---|---|---|
| Resize or recolour a bed, light or tank; change a plant's scale | The recipe dictionary in GDScript | No |
| Retune a crop (growth time, light, yield) | `core/species.hpp` | Yes |
| Change the soil, ground or panel texture | A skin recipe in GDScript | No |
| Move or add a prop, change the sky or the weather | `godot/scripts/dome.gd` | No |
| Add a new shape, or change how a crop looks | `src/farm_shape_builder.cpp`, `src/plant_meshes.cpp` | Yes |
| Replace a procedural shape with a modelled one | Add `"model": "res://models/x.glb"` to its recipe | No |
| Change a modelled prop | `blender/build_assets.py`, then re-export | No (re-import in Godot) |

## `FarmShapeBuilder`

```gdscript
var builder := FarmShapeBuilder.new()
var node: Node3D = builder.build_node({"shape": "planter_tray", "rows": 2, "cols": 4})
```

Keys common to every shape: `shape`, `name`, `model`, `model_scale`, `albedo_color`, `roughness`, `metallic`,
`emission_color`, `emission_energy`.

| Shape | Keys and notes |
|---|---|
| `box`, `cylinder`, `capsule`, `sphere` | Godot's own primitives: `size`, or `radius` and `height` |
| `planter_tray` | The regolith bed. `size` (default 1.2 x 0.22 x 0.6 m), `wall`, `rows`, `cols`, `soil_color`, `soil_skin`, `accent_color`, `base_color`. Origin at the middle of the bottom. `get_slot_positions(recipe)` returns the planting spots, row-major, on the soil |
| `grow_light` | The LED bar. `length` (1.2 m). Origin at the mount, hangs down. Its LED material is in the node's `led_material` metadata: set `emission_energy_multiplier` to dim or switch it |
| `tank` | The ice-melt tank. `radius`, `height`, `dome`. Origin at the middle of the bottom |
| `plant` | `species` (`lettuce`, `radish`, `tomato`, `potato`), `progress` 0..1, `stage` (the `FarmBay.STAGE_*` constants), `health` 0..1, `seed`, `scale`. Origin on the soil. The same inputs always give the same plant |

With no colours given, the shapes use the Mars palette above. A plant is rebuilt when its stage changes or its
progress moves by about 2%; the dome script shows the pattern (`_refresh_slot`). The heaviest plant is a few
thousand triangles.

## The model seam and the Blender assets

If a recipe names a `model` that exists, the imported scene is returned instead of the procedural shape, and
nothing else changes. If the file is missing, the procedural shape is used, so the game never breaks for want
of an asset. A modelled replacement must match the procedural one's dimensions and origin.

`blender/build_assets.py` builds the props in `godot/models/` from code, so they can be regenerated and tuned like
everything else:

```
blender -b --factory-startup --python blender/build_assets.py -- godot/models [asset ...]
```

(Built with Blender 5.3. Name assets after the `--` to rebuild only those; then run `godot --headless --path godot
--import`.)

| Asset | Replaces | Size and origin |
|---|---|---|
| `regolith_bed.glb` | `planter_tray` | 1.2 x 0.22 x 0.6 m, origin at the middle of the bottom, soil surface at y = 0.17 m; eight `Slot_0`..`Slot_7` empties exactly where `get_slot_positions()` puts them |
| `led_bar.glb` | `grow_light` | 1.2 m, origin at the mount point; the `LED_Emissive` material is the glowing panel |
| `ice_tank.glb` | `tank` | 0.7 m across, 0.9 m tall, origin at the middle of the bottom; the `Gauge_Emissive` material is the level window |
| `supply_crate.glb` | (extra) | 0.4 x 0.25 x 0.3 m, origin at the middle of the bottom |
| `airlock.glb` | (extra) | 1.5 x 2.2 x 0.5 m, origin at the middle of the bottom, the door faces +z; `Gauge_Emissive` is the porthole, `Status_Emissive` the status light |

The geometry in the script is written in Godot space (x right, y up, z toward the viewer) and `G()` converts it
to Blender's axes, so that the glTF exporter's Y-up conversion lands every point back on the same Godot
coordinates. Materials are plain Principled BSDF colours with no textures, named so that game code can find
them (`LED_Emissive`, `Gauge_Emissive`, `Status_Emissive`). The `.glb.import` files are tracked, so the import
settings are the same on every checkout. `godot/tests/assets_test.gd` builds each asset both ways and checks
that the sizes, origins and slots agree.

## `FarmSkinGenerator`

```gdscript
var tex := FarmSkinGenerator.new().generate_texture({"kind": "soil", "seed": 3}, 256, 256)
```

Recipe keys: `kind` (`cellular`, `soil`, `panel`), `seed`, `frequency`, `dark_color`, `base_color`,
`highlight_color`; `panel` also takes `cells` and `seam_color`. The same seed always gives the same texture. The
dome uses `soil` twice: dark regolith in the beds, and a 512 x 512 rust ground texture tiled 40 times over the plain.

## The world around the beds

`godot/scripts/dome.gd` builds everything that is not a bed or a plant, from recipes and Godot primitives:

- the **dome**: a glass hemisphere (alpha-blended, no shadow), four vertical and three horizontal ribs
  (`TorusMesh`, no shadow, because a web of rib shadows hides the beds), a floor disc, and a thin rust foundation
  ring around the rim;
- the **plain**: a 240 m plane with the rust ground texture, seventy rocks (flattened spheres) and a line of low hills;
- the **sky**: a `ProceduralSkyMaterial` whose colours, the sun's energy and angle, the fog and the ambient light
  all follow the hour and the dust (`_update_sky()`), so noon, night and a storm each look different.

## Adding a crop

1. Add a row to `kSpecies` in `core/species.hpp` (the tests check the table is well formed).
2. Add a colour case in `palette_for()` and, if it needs a new growth form, a function in
   `src/plant_meshes.cpp` (all in that file).
3. Rebuild. The crop appears in the dome's crop list automatically.

## One gotcha

Godot treats **clockwise** triangles as front faces, and it flips the normal of a back face even when culling
is off, so a wrongly wound triangle is lit inside out. `MeshBuilder::tri()` (`src/mesh_builder.h`) orients every
triangle from the normals it is given, so shape code never has to think about vertex order.

A second one, from this scene: a solid floor or base under a prop buries it. The foundation under the dome is a
ring for that reason; a disc as thick as a crate would hide the crates.

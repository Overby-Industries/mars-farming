#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

namespace godot {

/**
 * FarmShapeBuilder: turns a recipe Dictionary into a Node3D, the farm's counterpart of Aevoria's
 * PartDefinition::build_mesh_node(). A shape is data; only a genuinely new shape needs C++.
 *
 * Recipe keys, all shapes:
 *   "shape"            String, see get_shape_names()
 *   "name"             String, the node's name (default: the shape)
 *   "model"            String, res:// path of a glTF/PackedScene. If it exists it REPLACES the procedural
 *                      shape (the imported-model seam, as in PartDefinition::imported_model); if not, the
 *                      procedural shape is used, so a missing asset never breaks the scene
 *   "model_scale"      Vector3, optional scale for the imported model
 *   "albedo_color"     Color, "roughness" float, "metallic" float
 *   "emission_color"   Color, "emission_energy" float: omit for a non-glowing shape
 *
 * Shapes and their own keys:
 *   "box"           "size" Vector3
 *   "cylinder"      "radius", "height"
 *   "capsule"       "radius", "height"
 *   "sphere"        "radius", "radial_segments", "rings"
 *   "planter_tray"  "size" Vector3 (default 1.2 x 0.22 x 0.6 m), "wall", "rows", "cols", "soil_color",
 *                   "soil_skin" (a FarmSkinGenerator recipe), "accent_color", "base_color".
 *                   Origin at the middle of the bottom; get_slot_positions() gives the planting spots.
 *   "grow_light"    "length" (default 1.2 m); origin at the mount; the LED strip is a separate surface and its
 *                   material is stored in the node's metadata "led_material" so scripts can dim or switch it
 *   "tank"          "radius", "height", "dome"; origin at the middle of the bottom
 *   "plant"         "species" (key), "progress" 0..1, "stage" (Stage as int), "health" 0..1, "seed" int,
 *                   "scale"; origin on the soil
 */
class FarmShapeBuilder : public RefCounted {
    GDCLASS(FarmShapeBuilder, RefCounted)

protected:
    static void _bind_methods();

public:
    FarmShapeBuilder();
    ~FarmShapeBuilder();

    Node3D *build_node(const Dictionary &recipe);
    PackedVector3Array get_slot_positions(const Dictionary &recipe);
    PackedStringArray get_shape_names() const;
};

}  // namespace godot

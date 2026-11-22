#pragma once

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

/**
 * FarmSkinGenerator: stateless texture generator, the farm's counterpart of Aevoria's
 * ProceduralArtGenerator. A "skin recipe" is a Dictionary, so a look can be tuned or swapped from
 * GDScript without a rebuild, and the same seed always gives the same pattern.
 *
 * Recipe keys (every one optional):
 *   "kind"             String: "cellular" (default), "soil", or "panel"
 *   "seed"             int, default 0
 *   "frequency"        float, noise scale; higher = smaller, busier pattern
 *   "dark_color"       Color
 *   "base_color"       Color
 *   "highlight_color"  Color
 *   "cells"            int, "panel" only: panels per side, default 4
 *   "seam_color"       Color, "panel" only: the dark line between panels
 *
 * "cellular" is the stylised cracked-stone look; "soil" is a granular growing medium (dark earth,
 * lighter grains, a few pebbles; with rust colours it is Martian regolith); "panel" is painted
 * hull plating with seams and a little wear.
 */
class FarmSkinGenerator : public RefCounted {
    GDCLASS(FarmSkinGenerator, RefCounted)

protected:
    static void _bind_methods();

public:
    FarmSkinGenerator();
    ~FarmSkinGenerator();

    Ref<ImageTexture> generate_texture(const Dictionary &recipe, int width, int height);
};

}  // namespace godot

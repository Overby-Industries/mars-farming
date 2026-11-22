#include "farm_skin_generator.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace {

Color lerp_color(const Color &a, const Color &b, float t) {
    t = std::clamp(t, 0.0f, 1.0f);
    return Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1.0f);
}

// A tiny hash so speckles and pebbles repeat exactly for a given seed.
std::uint32_t hash2(std::uint32_t x, std::uint32_t y, std::uint32_t seed) {
    std::uint32_t h = x * 374761393u + y * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

float hash01(std::uint32_t x, std::uint32_t y, std::uint32_t seed) {
    return static_cast<float>(hash2(x, y, seed) & 0xFFFFFF) / 16777216.0f;
}

}  // namespace

void FarmSkinGenerator::_bind_methods() {
    ClassDB::bind_method(D_METHOD("generate_texture", "recipe", "width", "height"), &FarmSkinGenerator::generate_texture);
}

FarmSkinGenerator::FarmSkinGenerator() {}
FarmSkinGenerator::~FarmSkinGenerator() {}

Ref<ImageTexture> FarmSkinGenerator::generate_texture(const Dictionary &recipe, int width, int height) {
    width = std::max(8, width);
    height = std::max(8, height);
    const String kind = recipe.get("kind", "cellular");
    const int seed = static_cast<int>(recipe.get("seed", 0));
    const Color dark = recipe.get("dark_color", Color(0.15f, 0.12f, 0.10f));
    const Color base = recipe.get("base_color", Color(0.75f, 0.65f, 0.55f));
    const Color high = recipe.get("highlight_color", Color(0.85f, 0.78f, 0.68f));

    Ref<Image> img = Image::create_empty(width, height, false, Image::FORMAT_RGBA8);
    Ref<FastNoiseLite> noise;
    noise.instantiate();
    noise->set_seed(seed);

    if (kind == "soil") {
        // coarse clumps, fine grains, a few pebbles
        noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
        noise->set_frequency(static_cast<float>(static_cast<double>(recipe.get("frequency", 0.04))));
        Ref<FastNoiseLite> grain;
        grain.instantiate();
        grain->set_seed(seed + 101);
        grain->set_noise_type(FastNoiseLite::TYPE_CELLULAR);
        grain->set_frequency(0.35f);
        const std::uint32_t useed = static_cast<std::uint32_t>(seed);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const float clump = 0.5f + 0.5f * noise->get_noise_2d(static_cast<float>(x), static_cast<float>(y));
                const float g = 0.5f + 0.5f * grain->get_noise_2d(static_cast<float>(x), static_cast<float>(y));
                float v = 0.55f * clump + 0.45f * g;
                Color c = v < 0.5f ? lerp_color(dark, base, v * 2.0f) : lerp_color(base, high, (v - 0.5f) * 2.0f);
                if (hash01(static_cast<std::uint32_t>(x), static_cast<std::uint32_t>(y), useed) > 0.992f) c = lerp_color(c, high, 0.8f);   // a bright grain
                img->set_pixel(x, y, c);
            }
        }
    } else if (kind == "panel") {
        noise->set_noise_type(FastNoiseLite::TYPE_PERLIN);
        noise->set_frequency(static_cast<float>(static_cast<double>(recipe.get("frequency", 0.03))));
        const int cells = std::max(1, static_cast<int>(recipe.get("cells", 4)));
        const Color seam = recipe.get("seam_color", lerp_color(dark, Color(0, 0, 0), 0.4f));
        const std::uint32_t useed = static_cast<std::uint32_t>(seed);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const int cx = x * cells / width, cy = y * cells / height;
                const float wear = 0.5f + 0.5f * noise->get_noise_2d(static_cast<float>(x), static_cast<float>(y));
                // each panel is a slightly different tone, so the plating does not look flat
                const float tone = 0.35f + 0.3f * hash01(static_cast<std::uint32_t>(cx), static_cast<std::uint32_t>(cy), useed);
                Color c = lerp_color(base, high, std::clamp(tone + 0.25f * wear - 0.2f, 0.0f, 1.0f));
                const int lx = x - cx * width / cells, ly = y - cy * height / cells;
                const int pw = std::max(1, width / cells), ph = std::max(1, height / cells);
                const int edge = std::min(std::min(lx, pw - 1 - lx), std::min(ly, ph - 1 - ly));
                if (edge < std::max(1, width / 256)) c = seam;                          // the seam
                else if (edge < std::max(2, width / 128)) c = lerp_color(c, dark, 0.35f); // a shadowed lip
                img->set_pixel(x, y, c);
            }
        }
    } else {
        // "cellular": cracked, posterised, like Aevoria's asteroid skins
        noise->set_noise_type(FastNoiseLite::TYPE_CELLULAR);
        noise->set_cellular_return_type(FastNoiseLite::RETURN_DISTANCE2);
        noise->set_frequency(static_cast<float>(static_cast<double>(recipe.get("frequency", 0.05))));
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const float v = 0.5f + 0.5f * noise->get_noise_2d(static_cast<float>(x), static_cast<float>(y));
                img->set_pixel(x, y, v < 0.35f ? dark : (v < 0.65f ? base : high));
            }
        }
    }
    return ImageTexture::create_from_image(img);
}

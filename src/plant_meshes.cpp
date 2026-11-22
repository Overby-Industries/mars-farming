#include "plant_meshes.h"

#include <algorithm>
#include <cmath>

#include "plant.hpp"
#include "species.hpp"

namespace farm {

namespace {

using aevoria::farm::Kind;
using aevoria::farm::kSeedEnd;
using aevoria::farm::kSproutEnd;
using aevoria::farm::Species;
using aevoria::farm::Stage;

constexpr float kGolden = 2.39996323f;  // the golden angle in radians: how leaves spiral around a stem

// A small deterministic generator so one seed always draws the same plant.
struct Rng {
    std::uint32_t s;
    explicit Rng(std::uint32_t seed) : s(seed * 2654435761u + 0x9E3779B9u) {
        if (s == 0) s = 1;
        next();
        next();
    }
    std::uint32_t next() {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        return s;
    }
    float f() { return static_cast<float>(next() >> 8) * (1.0f / 16777216.0f); }
    float range(float a, float b) { return a + (b - a) * f(); }
};

float lerpf(float a, float b, float t) { return a + (b - a) * t; }

struct Palette {
    Color leaf_base;
    Color leaf_tip;
    Color stem;
};

Palette palette_for(int species) {
    switch (species) {
        case 0:  // lettuce: deep green outside, pale heart
            return {Color(0.15f, 0.40f, 0.13f), Color(0.55f, 0.78f, 0.30f), Color(0.55f, 0.75f, 0.35f)};
        case 1:  // radish: dark leaves on red stems
            return {Color(0.12f, 0.36f, 0.13f), Color(0.38f, 0.66f, 0.24f), Color(0.62f, 0.18f, 0.26f)};
        case 2:  // tomato
            return {Color(0.11f, 0.34f, 0.11f), Color(0.33f, 0.60f, 0.21f), Color(0.30f, 0.50f, 0.20f)};
        default:  // potato
            return {Color(0.13f, 0.37f, 0.12f), Color(0.38f, 0.63f, 0.21f), Color(0.30f, 0.48f, 0.20f)};
    }
}

struct Mood {
    float sick = 0.0f;         // 0 healthy .. 1 failing
    float senescence = 0.0f;   // 0 .. 1, foliage yellowing with age
    bool dead = false;
    float droop = 0.0f;        // extra droop added to every leaf
    float size = 1.0f;         // overall size multiplier (a dead plant has collapsed)
};

Color tint(const Color &c, const Mood &m) {
    if (m.dead) return mix(c, Color(0.30f, 0.22f, 0.12f), 0.92f);
    const Color sickly = mix(c, Color(0.66f, 0.60f, 0.18f), m.sick * 0.85f);
    return mix(sickly, Color(0.74f, 0.64f, 0.22f), m.senescence);
}

// ---- parts -----------------------------------------------------------------------------------

void compound_leaf(MeshBuilder &mb, const Vector3 &node, float yaw, float petiole, float leaflet, const Mood &m, const Palette &pal,
                   float shade) {
    const Vector3 dir(std::cos(yaw), 0.0f, std::sin(yaw));
    const float droop = 0.5f + m.droop;
    const Vector3 tip = node + dir * petiole + Vector3(0.0f, petiole * (0.28f - droop * 0.22f), 0.0f);
    const Color stem = tint(pal.stem, m);
    const Color c0 = tint(mix(pal.leaf_base, pal.leaf_tip, shade * 0.4f), m);
    const Color c1 = tint(mix(pal.leaf_base, pal.leaf_tip, 0.45f + shade * 0.45f), m);
    mb.rod(node, tip, 0.0015f, 0.0009f, 5, stem, stem);
    mb.leaf(tip, yaw, 0.30f - droop * 0.35f, leaflet, leaflet * 0.55f, droop * 0.8f, 0.3f, c0, c1, 4);
    for (int k = 0; k < 2; ++k) {
        const float along = 0.42f + 0.34f * static_cast<float>(k);
        const Vector3 at = node + (tip - node) * along;
        const float len = leaflet * (0.88f - 0.28f * static_cast<float>(k));
        for (int side = -1; side <= 1; side += 2) {
            mb.leaf(at, yaw + static_cast<float>(side) * 1.15f, 0.28f - droop * 0.35f, len, len * 0.52f, droop * 0.8f, 0.3f, c0, c1, 4);
        }
    }
}

void flower(MeshBuilder &mb, const Vector3 &at, float radius, const Color &petal, const Color &heart, Rng &rng) {
    const float tilt = rng.range(0.1f, 0.5f);
    const float spin = rng.range(0.0f, 6.28f);
    for (int i = 0; i < 5; ++i) {
        const float a = spin + 6.28318f * static_cast<float>(i) / 5.0f;
        mb.leaf(at, a, tilt, radius, radius * 0.75f, 0.2f, 0.0f, petal, mix(petal, Color(1, 1, 1), 0.3f), 2);
    }
    mb.ellipsoid(at + Vector3(0, 0.001f, 0), Vector3(radius * 0.22f, radius * 0.2f, radius * 0.22f), 6, 4, heart, heart);
}

// Two seed leaves on a short stem: every crop starts like this.
void sprout(MeshBuilder &mb, const PlantLook &look, const Palette &pal, const Mood &m, Rng &rng) {
    const float k = smooth(kSeedEnd, kSproutEnd, look.progress);
    const float h = (0.008f + 0.028f * k) * look.scale * m.size;
    const Color stem = tint(Color(0.62f, 0.78f, 0.45f), m);
    mb.rod(Vector3(0, -0.002f, 0), Vector3(0, h, 0), 0.0012f, 0.0008f, 5, stem, stem);
    const float len = (0.012f + 0.012f * k) * look.scale * m.size;
    const float yaw = rng.range(0.0f, 6.28f);
    for (int i = 0; i < 2; ++i) {
        mb.leaf(Vector3(0, h, 0), yaw + 3.14159f * static_cast<float>(i), 0.35f - m.droop * 0.3f, len, len * 0.62f, 0.4f + m.droop, 0.2f,
                tint(pal.leaf_base, m), tint(mix(pal.leaf_base, pal.leaf_tip, 0.6f), m), 3);
    }
}

void seed_mound(MeshBuilder &mb, const PlantLook &look, const Mood &m) {
    const Color top = tint(Color(0.43f, 0.33f, 0.20f), m), bottom = tint(Color(0.30f, 0.22f, 0.13f), m);
    mb.ellipsoid(Vector3(0, 0.0012f, 0), Vector3(0.007f, 0.0045f, 0.007f) * look.scale, 8, 4, top, bottom);
    if (look.progress > 0.03f && !m.dead) {
        const Color pale = Color(0.75f, 0.86f, 0.55f);
        mb.rod(Vector3(0, 0.0f, 0), Vector3(0, 0.006f, 0), 0.0008f, 0.0005f, 4, pale, pale);   // a first shoot
    }
}

// ---- crops -----------------------------------------------------------------------------------

void lettuce(MeshBuilder &mb, const PlantLook &look, const Palette &pal, const Mood &m, Rng &rng) {
    const float t = smooth(kSproutEnd, 1.0f, look.progress);
    const int n = 6 + static_cast<int>(8.0f * t);
    const float lmax = 0.115f * look.scale * m.size;
    for (int i = 0; i < n; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(n - 1);   // 0 = heart, 1 = outer leaf
        const float yaw = static_cast<float>(i) * kGolden + rng.range(-0.15f, 0.15f);
        const float pitch = lerpf(1.45f, 0.42f, u) + (m.dead ? -0.3f : 0.0f);
        const float len = lmax * (0.30f + 0.70f * t) * (0.55f + 0.45f * u) * rng.range(0.93f, 1.07f);
        const float width = len * rng.range(0.58f, 0.68f);
        const float droop = lerpf(0.10f, 0.90f, u) + m.droop;
        const Color c0 = tint(mix(pal.leaf_base, pal.stem, 0.25f * (1.0f - u)), m);
        const Color c1 = tint(mix(pal.leaf_tip, Color(0.84f, 0.94f, 0.58f), 0.55f * (1.0f - u)), m);
        mb.leaf(Vector3(rng.range(-0.003f, 0.003f), 0.003f * u, rng.range(-0.003f, 0.003f)), yaw, pitch, len, width, droop, 0.25f, c0, c1, 5);
    }
}

void radish(MeshBuilder &mb, const PlantLook &look, const Palette &pal, const Mood &m, Rng &rng) {
    const float t = smooth(kSproutEnd, 1.0f, look.progress);
    const int n = 5 + static_cast<int>(3.0f * t);
    const float lmax = 0.15f * look.scale * m.size;
    const float r = (0.004f + 0.016f * smooth(0.25f, 1.0f, look.progress)) * look.scale * m.size;   // bulb radius
    for (int i = 0; i < n; ++i) {
        const float yaw = static_cast<float>(i) * kGolden + rng.range(-0.2f, 0.2f);
        const float len = lmax * (0.35f + 0.65f * t) * rng.range(0.85f, 1.1f);
        const float lift = 0.004f + 0.02f * t;
        const Vector3 base(0, r * 0.7f, 0);
        const Vector3 stem_top = base + Vector3(std::cos(yaw) * 0.008f, lift, std::sin(yaw) * 0.008f);
        const Color stem = tint(pal.stem, m);
        mb.rod(base, stem_top, 0.0016f, 0.0011f, 5, stem, stem);
        mb.leaf(stem_top, yaw, rng.range(0.9f, 1.3f) - m.droop * 0.4f, len, len * 0.34f, 0.5f + m.droop, 0.3f, tint(pal.leaf_base, m),
                tint(pal.leaf_tip, m), 5);
    }
    // the bulb sits half out of the soil: red above, paler toward the root
    mb.ellipsoid(Vector3(0, r * 0.55f, 0), Vector3(r, r * 1.05f, r), 12, 8, tint(Color(0.82f, 0.10f, 0.22f), m), tint(Color(0.96f, 0.80f, 0.82f), m));
}

// Tomato and potato are both bushes of compound leaves; the tomato carries fruit, the potato flowers and ages.
void bush(MeshBuilder &mb, const PlantLook &look, const Species &sp, const Palette &pal, const Mood &m, Rng &rng) {
    const bool tomato = sp.kind == Kind::Fruiting;
    const float t = smooth(kSproutEnd, 1.0f, look.progress);
    const Stage stage = static_cast<Stage>(look.stage);
    const int stems = tomato ? 1 : 3;
    const float height = (tomato ? 0.46f : 0.36f) * (0.12f + 0.88f * t) * look.scale * m.size;
    const int nodes = 3 + static_cast<int>(6.0f * t);
    const float ripe = smooth(static_cast<float>(sp.fruit_start), 1.0f, look.progress);

    for (int s = 0; s < stems; ++s) {
        const float lean_yaw = static_cast<float>(s) * 2.094f + rng.range(0.0f, 1.0f);
        const float lean = tomato ? rng.range(0.0f, 0.04f) : rng.range(0.06f, 0.14f) * t;
        const Vector3 lean_dir(std::cos(lean_yaw), 0.0f, std::sin(lean_yaw));
        const float h = height * (s == 0 ? 1.0f : rng.range(0.7f, 0.9f));
        const Color stem = tint(pal.stem, m);

        Vector3 prev(0, 0, 0);
        for (int k = 1; k <= 6; ++k) {
            const float f = static_cast<float>(k) / 6.0f;
            const Vector3 cur = lean_dir * (lean * h * f * f * 4.0f) + Vector3(0.0f, h * f, 0.0f);
            mb.rod(prev, cur, 0.0042f * (1.15f - f * 0.6f), 0.0042f * (1.15f - (f + 0.17f) * 0.6f), 6, stem, stem);
            prev = cur;
        }

        for (int k = 0; k < nodes; ++k) {
            const float f = lerpf(0.22f, 0.97f, static_cast<float>(k) / static_cast<float>(std::max(1, nodes - 1)));
            const Vector3 node = lean_dir * (lean * h * f * f * 4.0f) + Vector3(0.0f, h * f, 0.0f);
            const float yaw = static_cast<float>(k + s * 3) * kGolden + rng.range(-0.2f, 0.2f);
            const float reach = (tomato ? 0.060f : 0.075f) * (0.4f + 0.6f * t) * (1.1f - 0.5f * f) * look.scale * m.size;
            const float leaflet = reach * 0.75f;
            Mood leaf_mood = m;
            if (!tomato) leaf_mood.senescence = std::max(m.senescence, smooth(0.86f, 1.0f, look.progress) * 0.85f);
            compound_leaf(mb, node, yaw, reach, leaflet, leaf_mood, pal, f);

            // flowers (tomato: yellow; potato: white with a yellow heart), only at the Flowering stage
            if (stage == Stage::Flowering && f > 0.5f && !m.dead) {
                const Color petal = tomato ? Color(0.98f, 0.84f, 0.18f) : Color(0.94f, 0.92f, 0.98f);
                const Color heart = tomato ? Color(0.85f, 0.6f, 0.1f) : Color(0.96f, 0.78f, 0.15f);
                flower(mb, node + Vector3(std::cos(yaw + 0.7f) * 0.015f, 0.012f, std::sin(yaw + 0.7f) * 0.015f), 0.009f * look.scale, petal, heart, rng);
            }

            // tomatoes: fruit hangs in small clusters from the middle nodes
            const bool has_fruit = stage == Stage::Fruiting || stage == Stage::Ready || stage == Stage::Overripe ||
                                   (m.dead && look.progress > static_cast<float>(sp.fruit_start));
            if (tomato && has_fruit && k > 0 && k % 2 == 1) {
                const int count = 2 + static_cast<int>(rng.range(0.0f, 2.0f));
                for (int c = 0; c < count; ++c) {
                    const float radius = (0.006f + 0.013f * ripe) * look.scale * m.size;
                    const float a = yaw + 2.2f + static_cast<float>(c) * 1.4f;
                    const Vector3 at = node + Vector3(std::cos(a) * 0.014f, -radius * 0.9f - 0.006f - 0.004f * static_cast<float>(c), std::sin(a) * 0.014f);
                    Color fruit = ripe < 0.5f ? mix(Color(0.35f, 0.62f, 0.20f), Color(0.95f, 0.62f, 0.18f), ripe * 2.0f)
                                              : mix(Color(0.95f, 0.62f, 0.18f), Color(0.82f, 0.13f, 0.10f), (ripe - 0.5f) * 2.0f);
                    if (stage == Stage::Overripe) fruit = mix(fruit, Color(0.50f, 0.07f, 0.06f), 0.7f);
                    if (m.dead) fruit = tint(fruit, m);
                    mb.rod(node, at + Vector3(0, radius, 0), 0.0008f, 0.0008f, 4, tint(pal.stem, m), tint(pal.stem, m));
                    mb.ellipsoid(at, Vector3(radius, radius * 0.92f, radius), 8, 6, fruit, mix(fruit, Color(0.2f, 0.1f, 0.05f), 0.25f));
                }
            }
        }
    }
}

}  // namespace

void build_plant(MeshBuilder &mb, const PlantLook &look) {
    const Species *sp = aevoria::farm::find_species(look.species);
    if (sp == nullptr) return;
    const Stage stage = static_cast<Stage>(look.stage);
    if (stage == Stage::Empty) return;

    Rng rng(look.seed);
    const Palette pal = palette_for(look.species);
    Mood m;
    m.dead = stage == Stage::Dead;
    m.sick = 1.0f - std::clamp(look.health, 0.0f, 1.0f);
    m.droop = m.sick * 0.5f;
    if (m.dead) {
        m.droop = 1.2f;
        m.size = 0.75f;
    }
    if (stage == Stage::Overripe) m.senescence = 0.55f;

    if (look.progress < static_cast<float>(kSeedEnd)) {
        seed_mound(mb, look, m);
        return;
    }
    if (look.progress < static_cast<float>(kSproutEnd)) {
        seed_mound(mb, look, m);   // the seed coat is still there beside the seedling
        sprout(mb, look, pal, m, rng);
        return;
    }
    switch (sp->kind) {
        case Kind::Leafy: lettuce(mb, look, pal, m, rng); break;
        case Kind::Root: radish(mb, look, pal, m, rng); break;
        case Kind::Tuber:
        case Kind::Fruiting: bush(mb, look, *sp, pal, m, rng); break;
    }
}

}  // namespace farm

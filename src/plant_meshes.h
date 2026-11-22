#pragma once

// Procedural plants. One function draws any crop at any point in its life from four numbers
// the simulation already tracks: progress, stage, health and a per-plant seed. The same inputs
// always give the same plant, and different seeds give plants that differ a little in leaf
// angle, size and colour, so a bed does not look stamped.

#include <cstdint>

#include "mesh_builder.h"

namespace farm {

struct PlantLook {
    int species = 0;        // index into aevoria::farm::kSpecies
    float progress = 1.0f;  // 0 (seed) .. 1 (ready)
    int stage = 0;          // aevoria::farm::Stage as an int
    float health = 1.0f;    // 0 (dead) .. 1
    std::uint32_t seed = 1;
    float scale = 1.0f;     // overall size multiplier
};

// Draws one plant standing on y = 0, +y up, in metres, into the builder's current surface.
// The surface's material must have culling off (leaves are single-sided) and take vertex colour as albedo.
void build_plant(MeshBuilder &mb, const PlantLook &look);

}  // namespace farm

#pragma once

// One plant: how it grows, what it needs, when it can be harvested.
//
// The model is deliberately small enough to read in one sitting. Each hour a
// plant gets four growth factors between 0 and 1 (light, temperature, water,
// nutrients), multiplies them, and gains progress only while the lights are on.
// Under ideal conditions on a 16 h photoperiod it reaches progress 1 in exactly
// Species::days_to_mature days, which is what the tests pin down. Water and
// nutrient shortage and bad temperature also cost health, and a plant at zero
// health is dead.

#include <algorithm>
#include <cstdint>
#include <optional>

#include "species.hpp"

namespace aevoria::farm {

inline constexpr double kRefPhotoperiodH = 16.0;  // the day length the maturity times assume
inline constexpr double kSeedEnd = 0.06;          // progress where Seed becomes Sprout
inline constexpr double kSproutEnd = 0.25;        // progress where Sprout becomes Vegetative
inline constexpr double kOkSupply = 0.35;         // water or nutrient level below which growth is limited
inline constexpr double kStressThreshold = 0.4;   // stress below this costs nothing
inline constexpr double kDamagePerHour = 0.023;   // health lost per hour at stress 1 beyond the threshold
inline constexpr double kRecoverBelow = 0.2;      // stress below this lets health recover
inline constexpr double kRecoverPerHour = 0.004;  // health regained per hour
inline constexpr double kPhotoinhibitionFloor = 0.4;

enum class Stage { Empty = 0, Seed, Sprout, Vegetative, Flowering, Fruiting, Ready, Overripe, Dead };

struct Plant {
    int species = -1;              // index into kSpecies, -1 = empty slot
    Stage stage = Stage::Empty;
    double progress = 0.0;         // 0 = seed, 1 = ready to harvest
    double health = 1.0;           // 0 = dead, 1 = perfect
    double vigor = 1.0;            // per-plant growth multiplier, about 0.95 to 1.05
    double age_hours = 0.0;
    double hours_ready = 0.0;      // time spent at full progress
    double quality_sum = 0.0;      // integral of the combined growth factor over lit hours
    double quality_hours = 0.0;
    std::uint32_t visual_seed = 0; // makes each plant look a little different

    // Mean of the combined growth factor over the plant's life so far, 0 to 1.
    double quality() const { return quality_hours > 0.0 ? quality_sum / quality_hours : 0.0; }
};

// What one plant feels during one step.
struct Conditions {
    double ppfd = 0.0;      // umol/m2/s at the canopy, 0 with the lights off
    double temp_c = 21.0;
    double water = 1.0;     // 0..1, how full the bed's moisture reserve is
    double nutrient = 1.0;  // 0..1, how full the bed's nutrient reserve is
};

struct StepResult {
    double water_l = 0.0;    // litres the plant wanted this step
    double nutrient = 0.0;   // share of a bed reserve it used
    double leaf_m2 = 0.0;    // canopy at work in the light this step (m2): what the plant gives the air
    bool stage_changed = false;
    Stage old_stage = Stage::Empty;
};

struct Harvest {
    int species = -1;
    double kg = 0.0;
    double quality = 0.0;
    Stage stage = Stage::Empty;
};

// ---- the four growth factors, each 0..1 -------------------------------------------------

inline double light_factor(const Species& s, double ppfd) {
    if (ppfd <= 0.0) return 0.0;
    if (ppfd <= s.ppfd_opt) return ppfd / s.ppfd_opt;
    if (ppfd <= s.ppfd_max) return 1.0;
    // too much light hurts: falls linearly with the excess, never below the floor
    return std::max(kPhotoinhibitionFloor, 1.0 - 0.6 * (ppfd - s.ppfd_max) / s.ppfd_max);
}

inline double temp_factor(const Species& s, double t) {
    if (t <= s.temp_min || t >= s.temp_max) return 0.0;
    if (t < s.temp_opt_low) return (t - s.temp_min) / (s.temp_opt_low - s.temp_min);
    if (t <= s.temp_opt_high) return 1.0;
    return (s.temp_max - t) / (s.temp_max - s.temp_opt_high);
}

// Water and nutrients: full speed above kOkSupply of the reserve, proportional below it.
inline double supply_factor(double level) {
    if (level >= kOkSupply) return 1.0;
    return std::max(0.0, level / kOkSupply);
}

// ---- stage ---------------------------------------------------------------------------

inline Stage compute_stage(const Species& s, const Plant& p) {
    if (p.species < 0) return Stage::Empty;
    if (p.health <= 0.0) return Stage::Dead;
    if (p.progress >= 1.0) return p.hours_ready > s.ready_window_days * 24.0 ? Stage::Overripe : Stage::Ready;
    if (p.progress < kSeedEnd) return Stage::Seed;
    if (p.progress < kSproutEnd) return Stage::Sprout;
    if (p.progress < s.flower_start) return Stage::Vegetative;
    if (p.progress < s.fruit_start) return Stage::Flowering;
    return Stage::Fruiting;
}

// ---- one step ------------------------------------------------------------------------

inline StepResult step_plant(const Species& s, Plant& p, const Conditions& c, double dt_h) {
    StepResult r;
    r.old_stage = p.stage;
    if (p.species < 0 || p.stage == Stage::Dead) return r;

    const bool lit = c.ppfd > 0.0;
    const double f_light = light_factor(s, c.ppfd);
    const double f_temp = temp_factor(s, c.temp_c);
    const double f_water = supply_factor(c.water);
    const double f_nutr = supply_factor(c.nutrient);

    // Transpiration grows with the plant and with the light.
    const double size = 0.15 + 0.85 * p.progress;
    const double activity = lit ? 0.5 + 0.5 * std::min(1.0, c.ppfd / s.ppfd_opt) : 0.25;
    r.water_l = s.water_use * s.canopy_m2 * size * activity * dt_h / 24.0;
    r.leaf_m2 = s.canopy_m2 * size * f_light;

    // Growth happens only in lit hours, and a sickly plant grows slower.
    if (lit && p.progress < 1.0) {
        const double f_all = f_light * f_temp * f_water * f_nutr;
        const double vitality = (0.5 + 0.5 * p.health) * p.vigor;
        const double before = p.progress;
        p.progress = std::min(1.0, p.progress + dt_h * f_all * vitality / (s.days_to_mature * kRefPhotoperiodH));
        r.nutrient = s.nutrient_use * (p.progress - before);
        p.quality_sum += f_all * dt_h;
        p.quality_hours += dt_h;
    }

    // Shortage of water or nutrients, or the wrong temperature, costs health.
    const double stress = 1.0 - std::min({f_water, f_nutr, f_temp});
    if (stress > kStressThreshold) {
        p.health -= (stress - kStressThreshold) * kDamagePerHour * dt_h;
    } else if (stress < kRecoverBelow) {
        p.health += kRecoverPerHour * dt_h;
    }
    p.health = std::clamp(p.health, 0.0, 1.0);

    p.age_hours += dt_h;
    if (p.progress >= 1.0) {
        p.hours_ready += dt_h;
        // left unharvested for three windows, the crop spoils
        if (p.hours_ready > 3.0 * s.ready_window_days * 24.0) p.health = 0.0;
    }

    p.stage = compute_stage(s, p);
    r.stage_changed = p.stage != r.old_stage;
    return r;
}

// ---- harvest -------------------------------------------------------------------------

// A plant can only be harvested when Ready or Overripe. An overripe crop has lost
// value, down to a fifth of a fresh one. Returns nothing if the plant is not ready.
inline std::optional<Harvest> harvest_plant(const Species& s, Plant& p) {
    if (p.stage != Stage::Ready && p.stage != Stage::Overripe) return std::nullopt;
    const double window_h = s.ready_window_days * 24.0;
    double freshness = 1.0;
    if (p.stage == Stage::Overripe) {
        freshness = std::max(0.2, 1.0 - 0.8 * (p.hours_ready - window_h) / (2.0 * window_h));
    }
    Harvest h;
    h.species = p.species;
    h.quality = p.quality();
    h.stage = p.stage;
    h.kg = s.yield_kg * p.health * (0.5 + 0.5 * h.quality) * freshness;
    p = Plant{};  // the slot is empty again
    return h;
}

}  // namespace aevoria::farm

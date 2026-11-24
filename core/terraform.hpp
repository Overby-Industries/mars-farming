#pragma once

// Mars only: the plants' oxygen slowly thickens the thin air. Every leaf at work in the light, in every dome of the settlement,
// adds to a terraforming index (0 to 1); the thin air gives some of it back to space every day. So the index settles where the
// gain and the loss meet, and that depends on how much plant there is: a dome or two never gets far, a handful of domes brings
// open-air farming, and only a settlement of many full domes can push the index to 1.0 and make the air breathable, which is
// the best way to win. (The station game leaves this switched off.)
//
// EVERY NUMBER HERE IS A DESIGN VALUE, chosen so that eight well-run domes finish the job with room to spare in a year or two of
// play, six well-run ones only just, and four never (the strategy runs of tests/test_colony.cpp and the notes in docs/DESIGN.md work
// it out), and to be tuned by playing.

#include <algorithm>
#include <array>

namespace aevoria::farm {

inline constexpr double kTerraformGainPerLeafDay = 0.0013;    // index gained per square metre of leaf at work, per day
inline constexpr double kTerraformLossPerDay = 0.005;         // share of the index the thin air gives back each day
// 1 the air is thickening, 2 open-air farming begins (more sites for domes), 3 breathable with a mask, 4 Mars is terraformed
inline constexpr std::array<double, 4> kTerraformStages = {0.2, 0.5, 0.8, 1.0};

class Terraform {
public:
    void enable(bool on) { enabled_ = on; }
    bool enabled() const { return enabled_; }

    // Leaf area at work in the plants' light, in square metre hours; the bays add it as time passes in each of them.
    void add_leaf_hours(double m2_hours) {
        if (enabled_) leaf_h_ += std::max(0.0, m2_hours);
    }

    // Time passes (called by the bay that holds the settlement's atmosphere). Returns the new stage if this step reached one the air has
    // not been in before, else 0: the air may wobble about a threshold (the harvests come in waves) and the stage is announced once.
    int advance(double hours) {
        if (!enabled_ || hours <= 0.0) {
            leaf_h_ = 0.0;
            return 0;
        }
        const double gain = kTerraformGainPerLeafDay * leaf_h_ / 24.0;                   // m2 hours are m2 days / 24
        leaf_avg_ += (leaf_h_ / hours - leaf_avg_) * std::min(1.0, hours / 24.0);        // the leaf area, smoothed over about a day
        leaf_h_ = 0.0;
        progress_ = std::clamp(progress_ + gain - kTerraformLossPerDay * progress_ * hours / 24.0, 0.0, 1.0);
        const int after = stage();
        if (after <= best_) return 0;
        best_ = after;
        return after;
    }

    double progress() const { return progress_; }
    int stage() const {
        int n = 0;
        for (double t : kTerraformStages) n += progress_ >= t ? 1 : 0;
        return n;
    }
    int best_stage() const { return best_; }                                             // the furthest the air has been (what has been announced and opened)
    bool complete() const { return progress_ >= 1.0; }
    double leaf_area_m2() const { return leaf_avg_; }                                    // leaf at work now, all domes together
    double equilibrium() const { return kTerraformGainPerLeafDay * leaf_avg_ / kTerraformLossPerDay; }   // where today's plants would settle it

private:
    bool enabled_ = false;
    double progress_ = 0.0;
    int best_ = 0;
    double leaf_h_ = 0.0;
    double leaf_avg_ = 0.0;
};

}  // namespace aevoria::farm

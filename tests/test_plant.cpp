// The plant model. The central promise, pinned here, is calibration: a plant under ideal
// conditions needs exactly 16 * days_to_mature lit hours to reach Ready. Everything else
// (shortage, heat, darkness, spoilage) is checked against numbers worked out by hand from
// the constants in plant.hpp, with tolerances written before the run.

#include <vector>

#include "check.hpp"
#include "plant.hpp"

using namespace aevoria::farm;

namespace {

Conditions ideal(const Species& s, bool lit) {
    Conditions c;
    c.ppfd = lit ? s.ppfd_opt : 0.0;
    c.temp_c = 0.5 * (s.temp_opt_low + s.temp_opt_high);
    c.water = 1.0;
    c.nutrient = 1.0;
    return c;
}

bool lit_at(int hour_of_day) { return hour_of_day >= 6 && hour_of_day < 22; }  // a 16 h photoperiod

struct Run {
    double hours = 0.0;
    double lit_hours = 0.0;
    double nutrient = 0.0;
    std::vector<Stage> stages;
    Plant plant;
};

// Grow one plant hour by hour in ideal conditions until it is Ready.
Run grow_ideal(const Species& s) {
    Run r;
    r.plant.species = s.id;
    r.plant.stage = Stage::Seed;
    r.stages.push_back(Stage::Seed);
    for (int h = 0; h < 24 * 400 && r.plant.progress < 1.0; ++h) {
        const bool lit = lit_at(h % 24);
        const StepResult sr = step_plant(s, r.plant, ideal(s, lit), 1.0);
        r.hours += 1.0;
        if (lit) r.lit_hours += 1.0;
        r.nutrient += sr.nutrient;
        if (r.plant.stage != r.stages.back()) r.stages.push_back(r.plant.stage);
    }
    return r;
}

Plant fresh(const Species& s) {
    Plant p;
    p.species = s.id;
    p.stage = Stage::Seed;
    return p;
}

}  // namespace

void runPlantTests() {
    const Species& lettuce = kSpecies[0];

    // ---- the growth factors -----------------------------------------------------------
    for (const Species& s : kSpecies) {
        CHECK_NEAR(light_factor(s, 0.0), 0.0, 0.0);
        CHECK_NEAR(light_factor(s, 0.5 * s.ppfd_opt), 0.5, 1e-12);
        CHECK_NEAR(light_factor(s, s.ppfd_opt), 1.0, 1e-12);
        CHECK_NEAR(light_factor(s, 0.5 * (s.ppfd_opt + s.ppfd_max)), 1.0, 1e-12);
        CHECK_NEAR(light_factor(s, s.ppfd_max), 1.0, 1e-12);
        CHECK_NEAR(light_factor(s, 1.5 * s.ppfd_max), 0.7, 1e-12);   // 1 - 0.6 * 0.5
        for (double x = 0.0; x <= 20.0 * s.ppfd_max; x += s.ppfd_max / 7.0) {
            const double f = light_factor(s, x);
            CHECK(f >= 0.0 && f <= 1.0);
            if (x > s.ppfd_max) CHECK(f >= kPhotoinhibitionFloor);   // the floor is for too much light, not too little
        }

        CHECK_NEAR(temp_factor(s, s.temp_min), 0.0, 0.0);
        CHECK_NEAR(temp_factor(s, s.temp_max), 0.0, 0.0);
        CHECK_NEAR(temp_factor(s, s.temp_opt_low), 1.0, 1e-12);
        CHECK_NEAR(temp_factor(s, s.temp_opt_high), 1.0, 1e-12);
        CHECK_NEAR(temp_factor(s, 0.5 * (s.temp_min + s.temp_opt_low)), 0.5, 1e-12);
        CHECK_NEAR(temp_factor(s, 0.5 * (s.temp_opt_high + s.temp_max)), 0.5, 1e-12);
        CHECK_NEAR(temp_factor(s, s.temp_min - 10.0), 0.0, 0.0);
        CHECK_NEAR(temp_factor(s, s.temp_max + 10.0), 0.0, 0.0);
    }
    CHECK_NEAR(supply_factor(1.0), 1.0, 0.0);
    CHECK_NEAR(supply_factor(kOkSupply), 1.0, 0.0);
    CHECK_NEAR(supply_factor(0.5 * kOkSupply), 0.5, 1e-12);
    CHECK_NEAR(supply_factor(0.0), 0.0, 0.0);
    CHECK_NEAR(supply_factor(-1.0), 0.0, 0.0);

    // ---- calibration, stage order and nutrient bookkeeping, for every species ------------
    for (const Species& s : kSpecies) {
        const Run r = grow_ideal(s);
        // 16 lit hours a day for days_to_mature days. The hourly loop may finish within one lit hour of it.
        CHECK_NEAR(r.lit_hours, kRefPhotoperiodH * s.days_to_mature, 1.0);
        // a plant takes up exactly Species::nutrient_use over a whole life cycle
        CHECK_NEAR(r.nutrient, s.nutrient_use, 1e-9);
        CHECK(r.plant.stage == Stage::Ready);
        CHECK_NEAR(r.plant.quality(), 1.0, 1e-12);

        std::vector<Stage> expected = {Stage::Seed, Stage::Sprout, Stage::Vegetative};
        if (s.flower_start < 1.0) {
            expected.push_back(Stage::Flowering);
            expected.push_back(Stage::Fruiting);
        }
        expected.push_back(Stage::Ready);
        CHECK(r.stages == expected);
    }

    // ---- no light, no growth ------------------------------------------------------------
    {
        Plant p = fresh(lettuce);
        for (int h = 0; h < 240; ++h) step_plant(lettuce, p, ideal(lettuce, false), 1.0);
        CHECK_NEAR(p.progress, 0.0, 0.0);
        CHECK_NEAR(p.health, 1.0, 0.0);
        CHECK(p.stage == Stage::Seed);
    }

    // ---- water: the numbers worked out by hand ---------------------------------------------
    {
        // lettuce: 2.0 L/m2/day * 0.05 m2 = 0.1 L/day at full size and full light
        Plant p = fresh(lettuce);
        const StepResult seed = step_plant(lettuce, p, ideal(lettuce, true), 1.0);
        CHECK_NEAR(seed.water_l, 0.1 * 0.15 / 24.0, 1e-7);   // a seed transpires 15% of a full plant
        Plant big = fresh(lettuce);
        big.progress = 0.9999999;
        big.stage = Stage::Fruiting;
        const StepResult full = step_plant(lettuce, big, ideal(lettuce, true), 1.0);
        CHECK_NEAR(full.water_l, 0.1 / 24.0, 1e-6);
        Plant dark = fresh(lettuce);
        const StepResult night = step_plant(lettuce, dark, ideal(lettuce, false), 1.0);
        CHECK_NEAR(night.water_l, 0.1 * 0.15 * 0.25 / 24.0, 1e-9);   // lights off: a quarter of the activity
    }

    // ---- shortage and heat kill, on a schedule that follows from the constants -----------------
    {
        // water 0 -> stress 1 -> health falls by (1 - 0.4) * 0.023 = 0.0138 per hour -> dead in 72.5 h
        Plant p = fresh(lettuce);
        Conditions c = ideal(lettuce, true);
        c.water = 0.0;
        int hours = 0;
        while (p.stage != Stage::Dead && hours < 500) {
            step_plant(lettuce, p, c, 1.0);
            ++hours;
        }
        CHECK(p.stage == Stage::Dead);
        CHECK(hours >= 72 && hours <= 73);
        CHECK_NEAR(p.progress, 0.0, 0.0);   // and it did not grow while it died

        // a dead plant does nothing and wants nothing
        const StepResult after = step_plant(lettuce, p, ideal(lettuce, true), 1.0);
        CHECK_NEAR(after.water_l, 0.0, 0.0);
        CHECK_NEAR(after.nutrient, 0.0, 0.0);
        CHECK(!after.stage_changed);

        // too hot, too cold: the same death
        for (const double t : {lettuce.temp_max + 1.0, lettuce.temp_min - 1.0}) {
            Plant q = fresh(lettuce);
            Conditions hot = ideal(lettuce, true);
            hot.temp_c = t;
            int h2 = 0;
            while (q.stage != Stage::Dead && h2 < 500) {
                step_plant(lettuce, q, hot, 1.0);
                ++h2;
            }
            CHECK(q.stage == Stage::Dead && h2 >= 72 && h2 <= 73);
            CHECK_NEAR(q.progress, 0.0, 0.0);
        }
    }
    {
        // moderate shortage: water 0.2 -> factor 0.2/0.35 -> stress 0.428571 -> (0.028571 * 0.023) = 0.000657143 per hour
        Plant p = fresh(lettuce);
        Conditions c = ideal(lettuce, true);
        c.water = 0.2;
        for (int h = 0; h < 100; ++h) step_plant(lettuce, p, c, 1.0);
        CHECK_NEAR(p.health, 1.0 - 100.0 * (1.0 - 0.2 / kOkSupply - kStressThreshold) * kDamagePerHour, 1e-9);
        CHECK(p.stage != Stage::Dead);
    }
    {
        // recovery: a sick plant in good conditions regains 0.004 per hour
        Plant p = fresh(lettuce);
        p.health = 0.5;
        for (int h = 0; h < 100; ++h) step_plant(lettuce, p, ideal(lettuce, false), 1.0);
        CHECK_NEAR(p.health, 0.9, 1e-9);
        for (int h = 0; h < 500; ++h) step_plant(lettuce, p, ideal(lettuce, false), 1.0);
        CHECK_NEAR(p.health, 1.0, 0.0);   // and it stops at 1
    }

    // ---- harvest ----------------------------------------------------------------------
    {
        Plant young = fresh(lettuce);
        CHECK(!harvest_plant(lettuce, young).has_value());   // nothing to take yet
        CHECK(young.species == lettuce.id);                  // and the plant is untouched

        Run r = grow_ideal(lettuce);
        const std::optional<Harvest> h = harvest_plant(lettuce, r.plant);
        CHECK(h.has_value());
        if (h) {
            CHECK_NEAR(h->kg, lettuce.yield_kg, 1e-9);        // perfect plant, perfect quality, fresh
            CHECK(h->stage == Stage::Ready);
        }
        CHECK(r.plant.species == -1 && r.plant.stage == Stage::Empty);   // the slot is empty again

        // Left to go overripe: at two windows past ready, freshness is 1 - 0.8 * 0.5 = 0.6
        Run late = grow_ideal(lettuce);
        const double window_h = lettuce.ready_window_days * 24.0;
        while (late.plant.hours_ready < 2.0 * window_h - 1e-9) step_plant(lettuce, late.plant, ideal(lettuce, false), 1.0);
        CHECK(late.plant.stage == Stage::Overripe);
        const std::optional<Harvest> old = harvest_plant(lettuce, late.plant);
        CHECK(old.has_value());
        if (old) CHECK_NEAR(old->kg, lettuce.yield_kg * 0.6, 1e-9);

        // Left for three windows, the crop spoils and cannot be harvested
        Run rot = grow_ideal(lettuce);
        while (rot.plant.hours_ready <= 3.0 * window_h) step_plant(lettuce, rot.plant, ideal(lettuce, false), 1.0);
        CHECK(rot.plant.stage == Stage::Dead);
        CHECK(!harvest_plant(lettuce, rot.plant).has_value());
    }

    // ---- a stressed life costs yield through quality -----------------------------------------
    {
        // dim the light to half of optimum all along: growth takes twice as long and quality is 0.5
        Plant p = fresh(lettuce);
        Conditions c = ideal(lettuce, true);
        c.ppfd = 0.5 * lettuce.ppfd_opt;
        int lit_hours = 0;
        for (int h = 0; h < 24 * 100 && p.progress < 1.0; ++h) {
            const bool lit = lit_at(h % 24);
            Conditions use = c;
            if (!lit) use.ppfd = 0.0;
            step_plant(lettuce, p, use, 1.0);
            if (lit) ++lit_hours;
        }
        CHECK_NEAR(static_cast<double>(lit_hours), 2.0 * kRefPhotoperiodH * lettuce.days_to_mature, 1.0);
        CHECK_NEAR(p.quality(), 0.5, 1e-9);
        const std::optional<Harvest> h = harvest_plant(lettuce, p);
        CHECK(h.has_value());
        if (h) CHECK_NEAR(h->kg, lettuce.yield_kg * 0.75, 1e-9);   // 0.5 + 0.5 * quality
    }
}

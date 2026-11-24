// The bay: schedule, sun, power, water and nutrient bookkeeping, events, determinism and a fuzz run.
// Numbers that are checked by hand are worked out in the comments beside them.

#include <cmath>
#include <cstdint>
#include <vector>

#include "bay.hpp"
#include "check.hpp"

using namespace aevoria::farm;

namespace {

Bay make_station(std::uint64_t seed = 1, int beds = 2) {
    Bay bay(seed);
    for (int i = 0; i < beds; ++i) bay.add_bed(2, 4, 0.72);
    return bay;
}

void sow_all(Bay& bay, int bed, int species) {
    for (int slot = 0; slot < bay.bed(bed).slots(); ++slot) bay.plant(bed, slot, species);
}

double total_water(const Bay& bay) {
    double w = bay.tank_l + bay.water_lost_l;
    for (int i = 0; i < bay.bed_count(); ++i) w += bay.bed(i).water_l;
    return w;
}

// xorshift64*: the fuzz test must make the same choices on every compiler
struct Rng {
    std::uint64_t s;
    std::uint64_t next() {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        return s * 2685821657736338717ULL;
    }
    double u01() { return static_cast<double>(next() >> 11) * (1.0 / 9007199254740992.0); }
    int below(int n) { return static_cast<int>(next() % static_cast<std::uint64_t>(n)); }
};

void check_invariants(const Bay& bay) {
    CHECK(std::isfinite(bay.tank_l) && bay.tank_l >= 0.0 && bay.tank_l <= bay.tank_capacity_l + 1e-9);
    CHECK(std::isfinite(bay.nutrient_stock) && bay.nutrient_stock >= 0.0);
    CHECK(bay.energy_wh >= 0.0 && bay.harvested_kg >= 0.0 && bay.water_lost_l >= -1e-9);
    CHECK(bay.clock_h >= 0.0 && bay.clock_h < 24.0);
    for (int bi = 0; bi < bay.bed_count(); ++bi) {
        const Bed& b = bay.bed(bi);
        CHECK(std::isfinite(b.water_l) && b.water_l >= -1e-9 && b.water_l <= b.water_capacity_l + 1e-9);
        CHECK(std::isfinite(b.nutrient) && b.nutrient >= 0.0 && b.nutrient <= 1.0 + 1e-12);
        for (const Plant& p : b.plants) {
            if (p.species < 0) {
                CHECK(p.stage == Stage::Empty);
                continue;
            }
            CHECK(std::isfinite(p.progress) && p.progress >= 0.0 && p.progress <= 1.0);
            CHECK(std::isfinite(p.health) && p.health >= 0.0 && p.health <= 1.0);
            CHECK(p.age_hours >= 0.0 && p.hours_ready >= 0.0);
        }
    }
}

}  // namespace

void runBayTests() {
    // ---- the light schedule ------------------------------------------------------------
    {
        Settings s;   // 06:00 to 22:00
        CHECK(!Bay::lights_on_at(s, 5.99));
        CHECK(Bay::lights_on_at(s, 6.0));
        CHECK(Bay::lights_on_at(s, 21.99));
        CHECK(!Bay::lights_on_at(s, 22.0));
        s.light_on_hour = 20.0;   // a night shift that wraps past midnight
        s.light_off_hour = 4.0;
        CHECK(Bay::lights_on_at(s, 22.0));
        CHECK(Bay::lights_on_at(s, 3.0));
        CHECK(!Bay::lights_on_at(s, 12.0));
        s.light_off_hour = s.light_on_hour;   // on == off means never
        CHECK(!Bay::lights_on_at(s, 20.0));
    }

    // ---- the sun, dust and shade (the Mars dome) ----------------------------------------------
    {
        Settings s;
        CHECK_NEAR(Bay::sun_ppfd_at(s, 12.0), 0.0, 0.0);   // a station has no sun on its beds
        s.sun_peak_ppfd = 700.0;
        CHECK_NEAR(Bay::sun_ppfd_at(s, 5.9), 0.0, 0.0);
        CHECK_NEAR(Bay::sun_ppfd_at(s, 18.1), 0.0, 0.0);
        CHECK_NEAR(Bay::sun_ppfd_at(s, 12.0), 700.0, 1e-9);                 // noon, clear sky, shade open
        CHECK_NEAR(Bay::sun_ppfd_at(s, 9.0), Bay::sun_ppfd_at(s, 15.0), 1e-9);   // symmetric about noon
        CHECK_NEAR(Bay::sun_ppfd_at(s, 9.0), 700.0 * std::sin(kPi / 4.0), 1e-9);
        s.dust_tau = 3.0;
        CHECK_NEAR(Bay::sun_ppfd_at(s, 12.0), 700.0 * std::exp(-1.25), 1e-9);   // exp(-0.5 * (3 - 0.5))
        s.dust_tau = 0.2;                                                       // clearer than the baseline does not add light
        CHECK_NEAR(Bay::sun_ppfd_at(s, 12.0), 700.0, 1e-9);
        s.dust_tau = 0.5;
        s.shade = 0.5;
        CHECK_NEAR(Bay::sun_ppfd_at(s, 12.0), 350.0, 1e-9);
        s.shade = 1.0;
        CHECK_NEAR(Bay::sun_ppfd_at(s, 12.0), 0.0, 1e-12);
    }
    {
        Settings s;
        s.temp_c = 20.0;
        s.temp_swing_c = 5.0;
        CHECK_NEAR(Bay::temp_at(s, 15.0), 25.0, 1e-9);   // warmest mid-afternoon
        CHECK_NEAR(Bay::temp_at(s, 3.0), 15.0, 1e-9);    // coolest before dawn
        CHECK_NEAR(Bay::temp_at(s, 9.0), 20.0, 1e-9);
    }

    // ---- power budget ------------------------------------------------------------------------
    {
        Bay bay = make_station(1, 4);
        bay.clock_h = 12.0;
        for (int i = 0; i < 4; ++i) bay.bed(i).light_level = 1.0;
        CHECK_NEAR(bay.power_demand_w(), 640.0, 1e-9);       // 4 beds x 160 W
        CHECK_NEAR(bay.power_scale(), 0.75, 1e-12);          // the budget is 480 W
        // 160 W x 0.75 x 2.6 umol/J x 0.85 / 0.72 m2
        CHECK_NEAR(bay.bed_ppfd(0), 160.0 * 0.75 * 2.6 * 0.85 / 0.72, 1e-9);
        bay.clock_h = 23.0;                                  // lights off
        CHECK_NEAR(bay.power_demand_w(), 0.0, 0.0);
        CHECK_NEAR(bay.bed_ppfd(0), 0.0, 0.0);
        bay.settings.sun_peak_ppfd = 600.0;                  // with a sun, lights off at noon still gives light
        bay.clock_h = 12.0;
        bay.settings.light_on_hour = 20.0;
        bay.settings.light_off_hour = 4.0;
        CHECK_NEAR(bay.bed_ppfd(0), 600.0, 1e-9);
    }
    {
        // energy: 2 beds at 0.6 -> 192 W (under the 480 W budget) for 16 lit hours = 3072 Wh
        Bay bay = make_station();
        bay.advance(24.0);
        CHECK_NEAR(bay.energy_wh, 192.0 * 16.0, 1e-6);
        CHECK_NEAR(bay.clock_h, 6.0, 1e-9);
        CHECK(bay.day == 2);
    }

    // ---- sowing, feeding, watering ---------------------------------------------------------------
    {
        Bay bay = make_station();
        CHECK(bay.plant(0, 0, 0));
        CHECK(!bay.plant(0, 0, 1));              // occupied
        CHECK(!bay.plant(0, 99, 0));             // no such slot
        CHECK(!bay.plant(5, 0, 0));              // no such bed
        CHECK(!bay.plant(0, 1, 99));             // no such species
        CHECK(bay.plant_at(0, 0).stage == Stage::Seed);

        const double stock = bay.nutrient_stock;
        bay.bed(0).nutrient = 0.8;
        // room for 0.2 / 0.1 = 2 units, however many are offered
        CHECK_NEAR(bay.feed(0, 100.0), 2.0, 1e-9);
        CHECK_NEAR(bay.bed(0).nutrient, 1.0, 1e-12);
        CHECK_NEAR(bay.nutrient_stock, stock - 2.0, 1e-9);
        CHECK_NEAR(bay.feed(0, 1.0), 0.0, 0.0);  // already full

        bay.bed(1).water_l = 1.0;                // capacity 4: room for 3 L
        const double tank = bay.tank_l;
        CHECK_NEAR(bay.irrigate(1, 10.0), 3.0, 1e-12);
        CHECK_NEAR(bay.tank_l, tank - 3.0, 1e-12);
        bay.tank_l = 1.0;
        bay.bed(1).water_l = 0.0;
        CHECK_NEAR(bay.irrigate(1, 10.0), 1.0, 1e-12);   // only what the tank has
        CHECK_NEAR(bay.irrigate(1, -3.0), 0.0, 0.0);
    }

    // ---- water is conserved: tank + beds + lost never changes ----------------------------------------
    {
        Bay bay = make_station();
        bay.settings.auto_irrigate = true;
        sow_all(bay, 0, 0);
        sow_all(bay, 1, 2);
        const double before = total_water(bay);
        bay.advance(24.0 * 25.0);
        CHECK_NEAR(total_water(bay), before, 1e-9);
        CHECK(bay.water_lost_l > 0.0);                     // some is lost: the dehumidifier is 90%
        check_invariants(bay);
        // with 90% recovery, the loss is a tenth of what the plants transpired
        Bay dry = make_station();
        dry.settings.reclaim_fraction = 0.0;
        dry.settings.auto_irrigate = true;
        sow_all(dry, 0, 0);
        const double w0 = total_water(dry);
        dry.advance(24.0 * 10.0);
        CHECK_NEAR(total_water(dry), w0, 1e-9);
        CHECK_NEAR(dry.tank_l + dry.bed(0).water_l + dry.bed(1).water_l, w0 - dry.water_lost_l, 1e-9);
    }

    // ---- ice melted for the tank (the Mars dome): it fills the tank, never past its capacity ------------
    {
        Bay bay = make_station();
        bay.tank_l = 10.0;
        bay.tank_capacity_l = 20.0;
        bay.advance(24.0);
        CHECK_NEAR(bay.tank_l, 10.0, 1e-12);                       // no resupply by default: the station has none
        bay.settings.tank_resupply_l_day = 2.4;
        bay.advance(24.0);
        CHECK_NEAR(bay.tank_l, 12.4, 1e-9);
        CHECK_NEAR(bay.water_added_l, 2.4, 1e-9);
        bay.advance(24.0 * 10.0);
        CHECK_NEAR(bay.tank_l, 20.0, 1e-9);                        // full is full
        CHECK_NEAR(bay.water_added_l, 10.0, 1e-9);                 // and only what fitted was counted
        check_invariants(bay);
    }

    // ---- a whole lettuce bed, start to harvest -----------------------------------------------------------
    {
        Bay bay = make_station();
        bay.settings.auto_irrigate = true;
        sow_all(bay, 0, 0);
        std::vector<Event> all;
        int hours = 0, slot0_ready_hour = -1;
        auto all_ready = [&]() {
            for (int slot = 0; slot < bay.bed(0).slots(); ++slot) {
                if (bay.plant_at(0, slot).stage != Stage::Ready) return false;
            }
            return true;
        };
        while (!all_ready() && hours < 24 * 60) {
            bay.advance(1.0);
            ++hours;
            if (slot0_ready_hour < 0 && bay.plant_at(0, 0).stage == Stage::Ready) slot0_ready_hour = hours;
            for (const Event& e : bay.take_events()) all.push_back(e);
        }
        CHECK(all_ready());
        // the nominal 30 days, moved a little by each plant's vigor (0.95 to 1.05): 28.6 to 31.6 days
        CHECK(slot0_ready_hour > 24 * 27 && slot0_ready_hour < 24 * 33);
        CHECK(hours > 24 * 27 && hours < 24 * 33);

        // slot 0's stage changes, in order, then Ready
        std::vector<int> stages;
        int days = 0;
        for (const Event& e : all) {
            if (e.type == EventType::StageChanged && e.bed == 0 && e.slot == 0) stages.push_back(e.value);
            if (e.type == EventType::DayChanged) ++days;
        }
        CHECK(stages == (std::vector<int>{static_cast<int>(Stage::Sprout), static_cast<int>(Stage::Vegetative),
                                          static_cast<int>(Stage::Ready)}));
        CHECK(days == (hours + 6) / 24);   // one DayChanged per midnight; the clock started at 06:00

        // Harvest everything that is ready: each lettuce about 0.2 kg, and part of it returns to the nutrient stock.
        double kg = 0.0;
        const double stock = bay.nutrient_stock;
        for (int slot = 0; slot < bay.bed(0).slots(); ++slot) {
            if (bay.plant_at(0, slot).stage != Stage::Ready) continue;
            const std::optional<Harvest> h = bay.harvest(0, slot);
            CHECK(h.has_value());
            if (h) kg += h->kg;
            CHECK(bay.plant_at(0, slot).species == -1);
            CHECK(!bay.harvest(0, slot).has_value());   // the slot is empty now
        }
        // eight plants, each healthy, fresh and grown in ideal conditions (294.7 umol/m2/s, 21 deg C, supplies above 0.4): 0.2 kg
        CHECK_NEAR(kg, 8.0 * 0.2, 1e-9);
        CHECK_NEAR(bay.harvested_kg, kg, 1e-9);
        CHECK_NEAR(bay.harvested_by_species[0], kg, 1e-9);
        CHECK_NEAR(bay.nutrient_stock, stock + kg * kCompostUnitsPerKg, 1e-9);
        check_invariants(bay);
    }

    // ---- neglect: no water, no auto-irrigation -> the plants die and the bay says so ------------------------
    {
        Bay bay = make_station();
        sow_all(bay, 0, 0);
        bay.bed(0).water_l = 0.0;
        bay.advance(24.0 * 5.0);
        int died = 0;
        for (const Event& e : bay.take_events()) {
            if (e.type == EventType::PlantDied) {
                ++died;
                CHECK(e.value == static_cast<int>(Stage::Dead));
            }
        }
        CHECK(died == bay.bed(0).slots());
        CHECK(bay.plant_at(0, 0).stage == Stage::Dead);
        const double stock = bay.nutrient_stock;
        CHECK(bay.remove(0, 0));
        CHECK(bay.plant_at(0, 0).species == -1);
        CHECK(bay.nutrient_stock > stock);   // composted
        CHECK(!bay.remove(0, 0));
    }

    // ---- determinism -------------------------------------------------------------------------------------
    {
        auto run = [](std::uint64_t seed) {
            Bay bay = make_station(seed);
            bay.settings.auto_irrigate = true;
            sow_all(bay, 0, 0);
            sow_all(bay, 1, 3);
            bay.advance(24.0 * 40.0);
            return bay;
        };
        const Bay a = run(7), b = run(7), c = run(8);
        bool same = true, differs = false;
        for (int bi = 0; bi < 2; ++bi) {
            for (int slot = 0; slot < a.bed(bi).slots(); ++slot) {
                const Plant& pa = a.plant_at(bi, slot);
                const Plant& pb = b.plant_at(bi, slot);
                const Plant& pc = c.plant_at(bi, slot);
                if (pa.progress != pb.progress || pa.visual_seed != pb.visual_seed || pa.vigor != pb.vigor) same = false;
                if (pa.visual_seed != pc.visual_seed) differs = true;
            }
        }
        CHECK(same);                      // same seed, same actions: bit-for-bit the same bay
        CHECK(differs);                   // another seed gives other plants
        CHECK(a.tank_l == b.tank_l && a.energy_wh == b.energy_wh);
        for (std::uint64_t seed = 1; seed <= 6; ++seed) {
            Bay bay = make_station(seed);
            bay.settings.auto_irrigate = true;
            bay.plant(0, 0, 0);
            int h = 0;
            while (bay.plant_at(0, 0).stage != Stage::Ready && h < 24 * 80) {
                bay.advance(1.0);
                ++h;
            }
            CHECK(h > 24 * 27 && h < 24 * 33);   // every seed matures near the nominal 30 days
        }
    }

    // ---- a Mars dome day: sun, dust, shade ------------------------------------------------------------------
    {
        Bay dome = make_station(1, 1);
        dome.settings.sun_peak_ppfd = 650.0;
        dome.settings.temp_swing_c = 4.0;
        dome.settings.temp_c = 20.0;
        dome.settings.light_on_hour = 0.0;     // LEDs off: the sun does the work
        dome.settings.light_off_hour = 0.0;
        dome.settings.auto_irrigate = true;
        dome.plant(0, 0, 3);                   // a potato
        dome.advance(24.0);
        CHECK_NEAR(dome.energy_wh, 0.0, 0.0);  // no LED energy was used
        CHECK(dome.plant_at(0, 0).progress > 0.0);
        const double clear = dome.plant_at(0, 0).progress;

        Bay storm = make_station(1, 1);
        storm.settings = dome.settings;
        storm.settings.dust_tau = 5.0;         // a global storm: exp(-0.5 * 4.5) = 0.105 of the light
        storm.plant(0, 0, 3);
        storm.advance(24.0);
        CHECK(storm.plant_at(0, 0).progress > 0.0);
        CHECK(storm.plant_at(0, 0).progress < 0.5 * clear);   // the storm slows growth a lot
    }

    // ---- fuzz: random actions and random settings never break an invariant ----------------------------------------
    {
        Rng rng{0x9E3779B97F4A7C15ULL};
        Bay bay = make_station(99, 3);
        for (int i = 0; i < 4000; ++i) {
            switch (rng.below(10)) {
                case 0: bay.plant(rng.below(3), rng.below(8), rng.below(static_cast<int>(kSpecies.size()))); break;
                case 1: bay.harvest(rng.below(3), rng.below(8)); break;
                case 2: bay.remove(rng.below(3), rng.below(8)); break;
                case 3: bay.irrigate(rng.below(3), 5.0 * rng.u01()); break;
                case 4: bay.feed(rng.below(3), 3.0 * rng.u01()); break;
                case 5: bay.settings.temp_c = -5.0 + 55.0 * rng.u01(); break;
                case 6: bay.bed(rng.below(3)).light_level = rng.u01(); break;
                case 7: bay.settings.shade = rng.u01(); bay.settings.dust_tau = 6.0 * rng.u01(); break;
                case 8: bay.settings.sun_peak_ppfd = rng.below(2) == 0 ? 0.0 : 900.0 * rng.u01(); break;
                default: bay.settings.auto_irrigate = rng.below(2) == 0; break;
            }
            bay.advance(30.0 * rng.u01());
            bay.take_events();
            check_invariants(bay);
        }
    }
}

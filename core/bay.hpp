#pragma once

// A growing bay: a few beds of plants under lights (and, optionally, sunlight),
// a water tank, a nutrient stock, and the clock that drives them.
//
// One station bay and one Mars dome are the same machine with different settings:
// the station has no sun on its beds and runs on LEDs inside a power budget; the
// dome has a sun that dust storms dim, a shade, and a day/night swing in temperature.
// Everything advances in steps of at most one hour, so the same code runs at any
// game speed and the results do not depend on the frame rate.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <random>
#include <utility>
#include <vector>

#include "colony.hpp"
#include "plant.hpp"
#include "terraform.hpp"

namespace aevoria::farm {

inline constexpr double kPi = 3.14159265358979323846;
inline constexpr double kCompostUnitsPerKg = 0.5;   // nutrient concentrate recovered per kg of produce harvested
inline constexpr double kFeedUnitStrength = 0.1;    // one unit of concentrate refills a tenth of a bed's reserve
inline constexpr double kSunRiseHour = 6.0;
inline constexpr double kSunSetHour = 18.0;

struct Bed {
    int rows = 2;
    int cols = 4;
    double area_m2 = 0.72;            // 1.2 m x 0.6 m
    double water_capacity_l = 4.0;
    double water_l = 3.0;
    double nutrient = 0.8;            // 0..1 of the bed's nutrient reserve
    double light_level = 0.6;         // LED dimmer, 0..1
    std::vector<Plant> plants;        // rows * cols slots, row-major

    int slots() const { return rows * cols; }
    double moisture() const { return water_capacity_l > 0.0 ? water_l / water_capacity_l : 0.0; }
};

struct Settings {
    // climate
    double temp_c = 21.0;             // set point
    double temp_swing_c = 0.0;        // day/night swing around it: warmest mid-afternoon, coolest before dawn
    // LEDs
    double light_on_hour = 6.0;
    double light_off_hour = 22.0;     // 16 h photoperiod
    double led_w_per_bed = 160.0;
    double led_umol_per_joule = 2.6;
    double led_optical_efficiency = 0.85;
    double power_budget_w = 480.0;    // what the station allots to the lights
    // sunlight (0 on a station: the beds have no windows)
    double sun_peak_ppfd = 0.0;       // umol/m2/s at the canopy at noon, clear sky, shade open
    double dust_tau = 0.5;            // optical depth of the dust; 0.5 is a clear Mars day, above 3 is a storm
    double shade = 0.0;               // 0 open, 1 closed
    // water
    double reclaim_fraction = 0.9;    // share of transpired water the dehumidifier returns to the tank
    double tank_resupply_l_day = 0.0; // water brought into the tank a day: ice melted from the regolith (the Mars dome); 0 on the station
    bool auto_irrigate = false;
};

enum class EventType { StageChanged, PlantDied, DayChanged, ColonyOutcome, ColonyArrival, ColonyEstablished, TerraformStage };

struct Event {
    EventType type = EventType::StageChanged;
    int bed = -1;
    int slot = -1;
    int value = 0;  // the new Stage, the new day number, the colony's Outcome, its new population, or the terraforming stage
};

class Bay {
public:
    explicit Bay(std::uint64_t seed = 1) : rng_(seed) {}

    Settings settings;

    // supplies and clock
    double tank_l = 120.0;
    double tank_capacity_l = 200.0;
    double nutrient_stock = 20.0;     // units of concentrate
    double clock_h = 6.0;             // hour of the day, 0..24
    int day = 1;

    // the colony this bay feeds (colony.hpp): not started until start_colony(), so a bare bay is a sandbox
    Colony colony;
    // Mars only (terraform.hpp): the air the settlement's plants thicken. Off until setup_terraform().
    Terraform terraform;

    // A colony is fed by every greenhouse or dome (every Bay) of the settlement. The first bay holds it and keeps its time; the others
    // are linked to it: what they harvest feeds it, the plants they lose count against it, and it is not advanced twice. The linked-to
    // bay must outlive the linking one (the pointer is not owning), and neither may be copied once linked.
    void link_colony(Bay& primary) {
        linked_colony_ = (&primary == this) ? nullptr : &primary.colony;
        linked_terraform_ = (&primary == this) ? nullptr : &primary.terraform;
    }
    void unlink_colony() {
        linked_colony_ = nullptr;
        linked_terraform_ = nullptr;
    }
    bool colony_linked() const { return linked_colony_ != nullptr; }
    Colony& active_colony() { return linked_colony_ != nullptr ? *linked_colony_ : colony; }
    Terraform& active_terraform() { return linked_terraform_ != nullptr ? *linked_terraform_ : terraform; }

    // running totals
    double energy_wh = 0.0;
    double water_lost_l = 0.0;        // transpired water the dehumidifier did not recover
    double water_added_l = 0.0;       // water the resupply has put in the tank
    double harvested_kg = 0.0;
    std::vector<double> harvested_by_species = std::vector<double>(kSpecies.size(), 0.0);

    // ---- layout -----------------------------------------------------------------------

    int add_bed(int rows, int cols, double area_m2) {
        Bed b;
        b.rows = std::max(1, rows);
        b.cols = std::max(1, cols);
        b.area_m2 = area_m2;
        b.plants.assign(static_cast<std::size_t>(b.slots()), Plant{});
        beds_.push_back(std::move(b));
        return static_cast<int>(beds_.size()) - 1;
    }
    int bed_count() const { return static_cast<int>(beds_.size()); }
    Bed& bed(int i) { return beds_.at(static_cast<std::size_t>(i)); }
    const Bed& bed(int i) const { return beds_.at(static_cast<std::size_t>(i)); }
    bool valid(int bed_index, int slot) const {
        return bed_index >= 0 && bed_index < bed_count() && slot >= 0 && slot < bed(bed_index).slots();
    }
    const Plant& plant_at(int bed_index, int slot) const {
        return bed(bed_index).plants.at(static_cast<std::size_t>(slot));
    }

    // ---- actions ----------------------------------------------------------------------

    // Start the colony the bay feeds, on a difficulty (a full reserve, no hunger, the score at zero). `demand_scale` and
    // `reserve_scale` shrink or stretch what the colony asks of the bay and the reserve it starts with, for a bay that
    // grows less or more, or more slowly.
    void start_colony(Difficulty d, double demand_scale = 1.0, double reserve_scale = 1.0) {
        colony.start(d, demand_scale, reserve_scale);
        colony.set_max_units(max_units_);
        colony.set_continue_after_goal(terraform_enabled_);
        terraform = Terraform{};
        terraform.enable(terraform_enabled_);
    }
    void stop_colony() {
        colony.stop();
        terraform = Terraform{};
        terraform.enable(terraform_enabled_);
    }
    // How many domes or greenhouses the settlement may have (4 unless a game says otherwise), and whether this game terraforms: then
    // the colony is only established at its goal and goes on, and `open_air_bonus` more sites open when the air is thick enough to farm in.
    void setup_settlement(int max_units, bool terraforming, int open_air_bonus) {
        max_units_ = max_units;
        terraform_enabled_ = terraforming;
        open_air_bonus_ = open_air_bonus;
        colony.set_max_units(max_units);
        colony.set_continue_after_goal(terraforming);
        terraform.enable(terraforming);
    }


    // Sow a seed in an empty slot. Returns false for a bad slot, an unknown species or an occupied slot.
    bool plant(int bed_index, int slot, int species_id) {
        if (!valid(bed_index, slot) || find_species(species_id) == nullptr) return false;
        Plant& p = bed(bed_index).plants[static_cast<std::size_t>(slot)];
        if (p.species >= 0) return false;
        p = Plant{};
        p.species = species_id;
        p.stage = Stage::Seed;
        p.vigor = 0.95 + 0.10 * u01();
        p.visual_seed = static_cast<std::uint32_t>(rng_() & 0xFFFFFFFFu);
        return true;
    }

    // Harvest a Ready or Overripe plant. Part of the crop goes back to the nutrient stock (the loop is zero-waste).
    std::optional<Harvest> harvest(int bed_index, int slot) {
        if (!valid(bed_index, slot)) return std::nullopt;
        Plant& p = bed(bed_index).plants[static_cast<std::size_t>(slot)];
        const Species* s = find_species(p.species);
        if (s == nullptr) return std::nullopt;
        std::optional<Harvest> h = harvest_plant(*s, p);
        if (h) {
            harvested_kg += h->kg;
            harvested_by_species[static_cast<std::size_t>(h->species)] += h->kg;
            nutrient_stock += h->kg * kCompostUnitsPerKg;
            active_colony().add_harvest(h->species, h->kg);
        }
        return h;
    }

    // Clear a slot (a dead plant, or a mistake). The plant is composted.
    bool remove(int bed_index, int slot) {
        if (!valid(bed_index, slot)) return false;
        Plant& p = bed(bed_index).plants[static_cast<std::size_t>(slot)];
        if (p.species < 0) return false;
        nutrient_stock += 0.05;
        p = Plant{};
        return true;
    }

    // Move water from the tank into a bed. Returns the litres actually moved.
    double irrigate(int bed_index, double liters) {
        if (bed_index < 0 || bed_index >= bed_count() || liters <= 0.0) return 0.0;
        Bed& b = bed(bed_index);
        const double moved = std::min({liters, tank_l, b.water_capacity_l - b.water_l});
        if (moved <= 0.0) return 0.0;
        tank_l -= moved;
        b.water_l += moved;
        return moved;
    }

    // Add nutrient concentrate to a bed. Returns the units actually used.
    double feed(int bed_index, double units) {
        if (bed_index < 0 || bed_index >= bed_count() || units <= 0.0) return 0.0;
        Bed& b = bed(bed_index);
        const double room = (1.0 - b.nutrient) / kFeedUnitStrength;
        const double used = std::min({units, nutrient_stock, room});
        if (used <= 0.0) return 0.0;
        nutrient_stock -= used;
        b.nutrient = std::min(1.0, b.nutrient + used * kFeedUnitStrength);
        return used;
    }

    // ---- environment, for the UI and for the plants ------------------------------------

    static bool lights_on_at(const Settings& s, double hour) {
        const double on = s.light_on_hour, off = s.light_off_hour;
        if (on == off) return false;
        return on < off ? (hour >= on && hour < off) : (hour >= on || hour < off);
    }
    bool lights_on() const { return lights_on_at(settings, clock_h); }

    static double sun_ppfd_at(const Settings& s, double hour) {
        if (s.sun_peak_ppfd <= 0.0 || hour <= kSunRiseHour || hour >= kSunSetHour) return 0.0;
        const double arc = std::sin(kPi * (hour - kSunRiseHour) / (kSunSetHour - kSunRiseHour));
        const double dust = std::exp(-0.5 * std::max(0.0, s.dust_tau - 0.5));
        return s.sun_peak_ppfd * arc * dust * (1.0 - std::clamp(s.shade, 0.0, 1.0));
    }
    double sun_ppfd() const { return sun_ppfd_at(settings, clock_h); }

    static double temp_at(const Settings& s, double hour) {
        return s.temp_c + s.temp_swing_c * std::sin(2.0 * kPi * (hour - 9.0) / 24.0);  // peak at 15:00
    }
    double temp_c() const { return temp_at(settings, clock_h); }

    // Electrical demand of the LEDs right now, and the share of it the budget can supply.
    static double power_demand_at(const Settings& s, const std::vector<Bed>& beds, double hour) {
        if (!lights_on_at(s, hour)) return 0.0;
        double w = 0.0;
        for (const Bed& b : beds) w += s.led_w_per_bed * b.light_level;
        return w;
    }
    double power_demand_w() const { return power_demand_at(settings, beds_, clock_h); }
    double power_scale() const {
        const double demand = power_demand_w();
        return demand <= settings.power_budget_w || demand <= 0.0 ? 1.0 : settings.power_budget_w / demand;
    }

    // Light at the canopy of a bed: the LEDs (dimmed, and scaled down if over the power budget) plus the sun.
    double bed_ppfd(int bed_index) const { return bed_ppfd_at(bed_index, clock_h); }

    // ---- time -------------------------------------------------------------------------

    void advance(double hours) {
        while (hours > 1e-12) {
            const double dt = std::min(1.0, hours);
            step(dt);
            hours -= dt;
        }
    }

    std::vector<Event> take_events() {
        std::vector<Event> out;
        out.swap(events_);
        return out;
    }

private:
    std::vector<Bed> beds_;
    std::vector<Event> events_;
    std::mt19937_64 rng_;
    Colony* linked_colony_ = nullptr;   // the colony of the bay this one is linked to, or null
    Terraform* linked_terraform_ = nullptr;
    int max_units_ = kMaxUnits;
    bool terraform_enabled_ = false;
    int open_air_bonus_ = 0;

    // A uniform number in [0, 1) that is identical on every compiler (the std distributions are not).
    double u01() { return static_cast<double>(rng_() >> 11) * (1.0 / 9007199254740992.0); }

    double bed_ppfd_at(int bed_index, double hour) const {
        const Bed& b = bed(bed_index);
        double led = 0.0;
        if (lights_on_at(settings, hour)) {
            const double demand = power_demand_at(settings, beds_, hour);
            const double scale = demand <= settings.power_budget_w || demand <= 0.0 ? 1.0 : settings.power_budget_w / demand;
            led = settings.led_w_per_bed * b.light_level * scale * settings.led_umol_per_joule *
                  settings.led_optical_efficiency / b.area_m2;
        }
        return led + sun_ppfd_at(settings, hour);
    }

    void step(double dt) {
        const double mid = std::fmod(clock_h + 0.5 * dt, 24.0);  // the step is judged at its midpoint
        const double temp = temp_at(settings, mid);
        const double demand_w = power_demand_at(settings, beds_, mid);
        energy_wh += std::min(demand_w, settings.power_budget_w) * dt;

        double leaf_m2h = 0.0;
        for (int bi = 0; bi < bed_count(); ++bi) {
            Bed& b = bed(bi);
            Conditions c;
            c.ppfd = bed_ppfd_at(bi, mid);
            c.temp_c = temp;
            c.water = b.moisture();
            c.nutrient = b.nutrient;

            double water_wanted = 0.0, nutrient_used = 0.0;
            for (int slot = 0; slot < b.slots(); ++slot) {
                Plant& p = b.plants[static_cast<std::size_t>(slot)];
                const Species* s = find_species(p.species);
                if (s == nullptr) continue;
                const StepResult r = step_plant(*s, p, c, dt);
                water_wanted += r.water_l;
                nutrient_used += r.nutrient;
                leaf_m2h += r.leaf_m2 * dt;
                if (r.stage_changed) {
                    if (p.stage == Stage::Dead) active_colony().note_plant_lost();
                    events_.push_back({p.stage == Stage::Dead ? EventType::PlantDied : EventType::StageChanged, bi, slot,
                                       static_cast<int>(p.stage)});
                }
            }

            // Plants can only draw what the bed holds. The dehumidifier recovers most of what they transpire.
            const double drawn = std::min(water_wanted, b.water_l);
            b.water_l -= drawn;
            const double returned = std::min(drawn * settings.reclaim_fraction, tank_capacity_l - tank_l);
            tank_l += returned;
            water_lost_l += drawn - returned;
            b.nutrient = std::max(0.0, b.nutrient - nutrient_used);

            if (settings.auto_irrigate && b.moisture() < 0.4) irrigate(bi, 0.9 * b.water_capacity_l - b.water_l);
        }

        if (settings.tank_resupply_l_day > 0.0) {           // ice melted for the tank, up to what it holds
            const double added = std::clamp(settings.tank_resupply_l_day * dt / 24.0, 0.0, std::max(0.0, tank_capacity_l - tank_l));
            tank_l += added;
            water_added_l += added;
        }

        active_terraform().add_leaf_hours(leaf_m2h);
        if (linked_colony_ == nullptr) {      // a linked bay leaves the colony's (and the air's) clock to the bay that holds it
            Outcome decided = colony.advance(dt);
            if (decided != Outcome::Running) events_.push_back({EventType::ColonyOutcome, -1, -1, static_cast<int>(decided)});
            if (colony.take_arrivals() > 0) events_.push_back({EventType::ColonyArrival, -1, -1, colony.population()});
            if (colony.take_established()) events_.push_back({EventType::ColonyEstablished, -1, -1, 0});
            if (terraform.enabled()) {
                const int stage = terraform.advance(dt);
                colony.set_max_units(max_units_ + (terraform.best_stage() >= 2 ? open_air_bonus_ : 0));   // open-air farming opens more sites, for good
                if (stage > 0) events_.push_back({EventType::TerraformStage, -1, -1, stage});
                if (terraform.complete() && colony.running()) {
                    decided = colony.finish_terraformed();
                    events_.push_back({EventType::ColonyOutcome, -1, -1, static_cast<int>(decided)});
                }
            }
        }

        clock_h += dt;
        if (clock_h >= 24.0) {
            clock_h -= 24.0;
            ++day;
            events_.push_back({EventType::DayChanged, -1, -1, day});
        }
    }
};

}  // namespace aevoria::farm

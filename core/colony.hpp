#pragma once

// The colony the bay feeds: how many people it has, how much food it asks of the bay each day, what happens when the
// food runs out, and how well the player did. Three difficulties (Easy, Intermediate, Difficult) differ in how much the
// colony needs, how long it can wait, how long the player must keep it fed, and what failing means:
//
//   Easy          Earth is fine. If the food runs out the colony is evacuated home and fails: nobody is lost.
//   Intermediate  Earth is damaged and can take only part of the crew back: the colony fails and the rest are lost.
//   Difficult     Earth cannot be lived on. There is nowhere to go: if the food runs out, the colony is extinct.
//
// The player wins by keeping the crew fed for the whole goal period. The food counts in kcal, harvested crops times their
// kcal per kg (species.hpp); the colony eats a little every hour from a store, which the harvests refill.
//
// EVERY NUMBER HERE IS A DESIGN VALUE. One bay of 32 plants cannot feed a crew (a person eats about 2,500 kcal a day;
// this bay grows 30 to 80 kcal a day), so the colony here asks the bay for a fresh-food share scaled to what the bay can
// grow, and the rest of its diet is imagined to come from elsewhere. The tests (tests/test_colony.cpp) play simple
// strategies against each difficulty and pin down which of them win, so retuning a number shows what it changes.

#include <algorithm>
#include <array>
#include <bitset>
#include <cmath>
#include <cstddef>

#include "species.hpp"

namespace aevoria::farm {

enum class Difficulty { Easy = 0, Intermediate = 1, Difficult = 2 };

enum class Outcome {
    Running = 0,           // the colony is being fed (or none has been started)
    Success,               // the farm kept the crew fed for the whole goal period
    Evacuated,             // the food ran out and everyone was taken home: the colony failed
    EvacuatedWithLosses,   // the food ran out and Earth could take only part of the crew back
    Extinct,               // the food ran out and there was nowhere to go
    Terraformed,           // (Mars) the plants made the air breathable: the best way to win
};

struct ColonyRules {
    const char* name;
    int crew;                    // people to feed
    double need_kcal_day;        // what the colony asks of this bay each day, for the whole crew
    double start_reserve_days;   // the food in store at the start, in days of need
    double grace_days;           // days the colony can go hungry before it fails
    double goal_days;            // days to keep it fed to win
    double evacuation_share;     // share of the crew an evacuation can take home: 1 = Earth is fine, 0 = no way back
    double score_multiplier;
    int arrival_batch;           // colonists that arrive each time the food has been plentiful for long enough
};

inline constexpr std::array<ColonyRules, 3> kColonyRules = {{
    //  name            crew  need   reserve  grace  goal   evac  score  arrivals
    //                        kcal/d days     days   days   share x      per time
    {"Easy",            4,    24.0,  100.0,   14.0,  120.0, 1.0,  1.0,   2},
    {"Intermediate",    8,    50.0,   60.0,   10.0,  200.0, 0.5,  1.5,   3},
    {"Difficult",      12,    66.0,   95.0,    7.0,  300.0, 0.0,  2.0,   4},
}};

inline const ColonyRules& colony_rules(Difficulty d) { return kColonyRules[static_cast<std::size_t>(d)]; }

// Design values for the score (see Colony::score).
inline constexpr double kPointsPerDay = 3.0;             // each day the colony has lasted
inline constexpr double kPointsPerKcal = 0.5;            // each kcal the farm has grown
inline constexpr double kPointsPerCrop = 150.0;          // each different crop harvested at least once
inline constexpr double kPointsPerReserveDay = 10.0;     // each day of food in store, up to kReserveBonusCapDays
inline constexpr double kReserveBonusCapDays = 60.0;
inline constexpr double kPointsPerPlantLost = 40.0;      // taken off for each plant that died
inline constexpr double kPointsPerHungryDay = 25.0;      // taken off for each day the crew went short
inline constexpr double kSuccessBonus = 1000.0;
// However large a game makes the starting reserve, the food still has to run out this many days before the goal: a colony
// that grows nothing must always fail.
inline constexpr double kMinFailureMarginDays = 6.0;

// ---- growth and expansion ----------------------------------------------------------------------------------------
// A greenhouse or a dome (a "unit") houses kHousingFactor starting crews. Two things follow from the food:
//   - Expansion: once the colony has food to spare (a store of kExpandMinReserveDays and a harvest of some size behind it) it may
//     build another unit, up to kMaxUnits, at the price of some of that food. More units grow more food (and, on Mars, more air).
//   - Growth: when the farm has out-grown the crew by a clear margin over a whole growing season (plenty), more people come (ships
//     from Earth, births), up to the housing, and only as many as that harvest would still have fed with the margin: the newcomers eat
//     too. A colony that only just feeds itself does not grow, which keeps the three difficulties as hard as the strategy runs in
//     tests/test_colony.cpp pin them. Design values, like the rest.
inline constexpr double kPlentyReserveDays = 40.0;     // food in store that counts as plenty ...
inline constexpr double kSurplusFactor = 1.5;          // ... with a farm that grew this many times what the crew needed ...
inline constexpr int kSurplusWindowDays = 105;         // ... over the last growing season (the potato, the slowest crop, takes about this long) ...
inline constexpr int kPlentyMinAgeDays = 20;           // ... once the colony has been going this many days ...
inline constexpr double kGrowthIntervalDays = 6.0;     // ... and the days of it before the next colonists arrive
inline constexpr double kHousingFactor = 1.5;          // one unit houses this many starting crews
inline constexpr int kMaxUnits = 4;                    // sites for greenhouses or domes
inline constexpr double kExpandMinReserveDays = 30.0;  // food that must be in store to start building ...
inline constexpr double kExpandMinHarvestDays = 10.0;  // ... after the farm has grown at least this many days of the crew's food
inline constexpr double kExpansionCostDays = 10.0;     // days of food the colony spends on building a unit
inline constexpr double kPointsPerNewColonist = 20.0;
inline constexpr double kPointsPerNewUnit = 400.0;
inline constexpr double kTerraformBonus = 5000.0;       // for making Mars breathable

struct ScoreBreakdown {
    double days = 0.0;
    double food = 0.0;
    double variety = 0.0;
    double reserve = 0.0;
    double lost = 0.0;       // a deduction, positive here
    double hunger = 0.0;     // a deduction, positive here
    double growth = 0.0;     // for the colonists who have arrived
    double expansion = 0.0;  // for the units built
    double bonus = 0.0;      // for making it, and for terraforming
    double multiplier = 1.0;
    long total = 0;
};

class Colony {
public:
    bool started() const { return started_; }
    bool running() const { return started_ && outcome_ == Outcome::Running; }
    Difficulty difficulty() const { return difficulty_; }
    Outcome outcome() const { return outcome_; }
    const ColonyRules& rules() const { return colony_rules(difficulty_); }

    // Begin (or begin again): a full reserve, no hunger, the score at zero. `demand_scale` stretches or shrinks what the
    // colony asks of the bay and `reserve_scale` the reserve it starts with (in days), for a game whose bay grows less or
    // more or more slowly (the Mars dome under its sun).
    void start(Difficulty d, double demand_scale = 1.0, double reserve_scale = 1.0) {
        *this = Colony{};
        started_ = true;
        difficulty_ = d;
        const ColonyRules& r = colony_rules(d);
        population_ = r.crew;
        need_per_person_ = r.need_kcal_day * std::max(0.01, demand_scale) / r.crew;
        const double reserve_days =
            std::min(r.start_reserve_days * std::max(0.01, reserve_scale), std::max(0.0, r.goal_days - r.grace_days - kMinFailureMarginDays));
        stock_kcal_ = reserve_days * need_kcal_day();
    }
    void stop() { *this = Colony{}; }   // forget the colony: the bay is a sandbox again

    // Options a game sets after start(): how many units there may be, and whether reaching the goal ends the run (the default) or only
    // establishes the colony, which then goes on, past hunger, towards bigger things (the Mars dome: terraforming).
    void set_max_units(int n) { max_units_ = std::clamp(n, 1, 16); }
    int max_units() const { return max_units_; }
    void set_continue_after_goal(bool on) { continue_after_goal_ = on; }
    bool continue_after_goal() const { return continue_after_goal_; }
    bool established() const { return established_; }                    // the goal was reached and the run goes on
    bool take_established() {                                             // true once, when the colony has just been established
        const bool now = established_pending_;
        established_pending_ = false;
        return now;
    }
    // End an established run here, as a success.
    Outcome finish_established() { return established_ && running() ? finish(Outcome::Success) : Outcome::Running; }
    // The air has become breathable: the colony wins in the best way.
    Outcome finish_terraformed() { return running() ? finish(Outcome::Terraformed) : Outcome::Running; }

    // The farm grew food.
    void add_harvest(int species_id, double kg) {
        if (!running()) return;
        const Species* s = find_species(species_id);
        if (s == nullptr || kg <= 0.0) return;
        const double kcal = kg * s->kcal_per_kg;
        stock_kcal_ += kcal;
        harvested_kcal_ += kcal;
        harvest_bins_[bin_] += kcal;
        crops_.set(static_cast<std::size_t>(species_id));
    }
    void note_plant_lost() {
        if (running()) ++plants_lost_;
    }

    // Time passes. Returns the outcome if this step decided it, otherwise Outcome::Running.
    Outcome advance(double hours) {
        if (!running() || hours <= 0.0) return Outcome::Running;
        elapsed_h_ += hours;
        const double want = need_kcal_day() * hours / 24.0;
        if (stock_kcal_ >= want) {
            stock_kcal_ -= want;
            eaten_kcal_ += want;
                hunger_h_ = 0.0;
        } else {
            eaten_kcal_ += stock_kcal_;
            stock_kcal_ = 0.0;
            hunger_h_ += hours;
            hungry_total_h_ += hours;
        }
        bin_hours_ += hours;
        while (bin_hours_ >= 24.0 - 1e-9) {                 // a day has gone: start a new bin
            bin_hours_ -= 24.0;
            bin_ = (bin_ + 1) % kBins;
            harvest_bins_[bin_] = 0.0;
            if (age_days_ < kBins - 1) ++age_days_;
        }
        grow(hours);
        const ColonyRules& r = rules();
        if (!established_ && hunger_h_ >= r.grace_days * 24.0) return finish(failure_outcome());   // an established colony is past this
        if (!established_ && elapsed_h_ >= r.goal_days * 24.0) {
            if (!continue_after_goal_) return finish(Outcome::Success);
            established_ = true;
            established_pending_ = true;
        }
        return Outcome::Running;
    }

    // ---- people, housing, expansion ------------------------------------------------------
    int population() const { return population_; }
    int units() const { return started_ ? units_ : 0; }
    int housing() const { return started_ ? static_cast<int>(std::ceil(rules().crew * kHousingFactor)) * units_ : 0; }
    // What the farm has grown, over what the crew needs to eat, over the last growing season (or as long as the colony has lasted).
    double surplus_ratio() const {
        const double need = need_kcal_day() * window_elapsed_days();
        return need > 0.0 ? window_harvest() / need : 0.0;
    }
    // Plenty: the crew is fed, the store holds kPlentyReserveDays or more, and the farm has out-grown the crew by kSurplusFactor
    // over the last season. Only the farm counts: the store the colony started with does not.
    bool plenty() const {
        return running() && hunger_h_ <= 0.0 && reserve_days() >= kPlentyReserveDays && age_days_ >= kPlentyMinAgeDays &&
               surplus_ratio() >= kSurplusFactor;
    }
    // Food to spare, and a site left: a new unit may be built.
    bool expansion_ready() const {
        return running() && units_ < max_units_ && reserve_days() >= kExpandMinReserveDays && hunger_h_ <= 0.0 &&
               harvested_kcal_ >= kExpandMinHarvestDays * need_kcal_day();
    }
    // The units are full: more colonists would have to wait for a new one.
    bool crowded() const { return started_ && population_ >= housing(); }
    // Build a unit: more housing, and the building crew eats kExpansionCostDays of the colony's food. False if it may not be built now.
    bool add_unit() {
        if (!expansion_ready()) return false;
        stock_kcal_ = std::max(0.0, stock_kcal_ - kExpansionCostDays * need_kcal_day());
        ++units_;
        return true;
    }
    double growth_progress() const { return std::clamp(plenty_h_ / (kGrowthIntervalDays * 24.0), 0.0, 1.0); }   // towards the next arrivals
    int arrivals_total() const { return arrivals_total_; }
    int take_arrivals() {                     // colonists who came since the last call
        const int n = arrivals_pending_;
        arrivals_pending_ = 0;
        return n;
    }
    void set_growth(bool on) {                // off: nobody arrives (the strategy tests of the food balance use this)
        growth_enabled_ = on;
        plenty_h_ = 0.0;
    }
    bool growth_enabled() const { return growth_enabled_; }

    // ---- what the colony looks like now -------------------------------------------------
    double day() const { return elapsed_h_ / 24.0; }
    double need_kcal_day() const { return need_per_person_ * population_; }
    double stock_kcal() const { return stock_kcal_; }
    double reserve_days() const { return need_kcal_day() > 0.0 ? stock_kcal_ / need_kcal_day() : 0.0; }
    bool starving() const { return running() && hunger_h_ > 0.0; }
    double hunger_days() const { return hunger_h_ / 24.0; }
    double hungry_days_total() const { return hungry_total_h_ / 24.0; }
    double harvested_kcal() const { return harvested_kcal_; }
    double eaten_kcal() const { return eaten_kcal_; }
    int crops_grown() const { return static_cast<int>(crops_.count()); }
    int plants_lost() const { return plants_lost_; }
    // People who are alive and well at the end: all of them after a success or a full evacuation, a share after a partial
    // one, none when extinct. While the colony is running it is the whole population.
    int survivors() const {
        switch (outcome_) {
            case Outcome::EvacuatedWithLosses: return static_cast<int>(std::floor(population_ * rules().evacuation_share));
            case Outcome::Extinct: return 0;
            default: return population_;
        }
    }

    // The score so far, with its parts. The same number a finished run is ranked by.
    ScoreBreakdown score() const {
        ScoreBreakdown b;
        if (!started_) return b;
        b.days = kPointsPerDay * day();
        b.food = kPointsPerKcal * harvested_kcal_;
        b.variety = kPointsPerCrop * crops_grown();
        b.reserve = kPointsPerReserveDay * std::min(reserve_days(), kReserveBonusCapDays);
        b.lost = kPointsPerPlantLost * plants_lost_;
        b.hunger = kPointsPerHungryDay * hungry_days_total();
        b.growth = kPointsPerNewColonist * (population_ - rules().crew);
        b.expansion = kPointsPerNewUnit * (units_ - 1);
        b.bonus = (outcome_ == Outcome::Success || outcome_ == Outcome::Terraformed || established_ ? kSuccessBonus : 0.0) + (outcome_ == Outcome::Terraformed ? kTerraformBonus : 0.0);
        b.multiplier = rules().score_multiplier;
        const double sum = b.days + b.food + b.variety + b.reserve + b.growth + b.expansion + b.bonus - b.lost - b.hunger;
        b.total = std::max(0L, std::lround(sum * b.multiplier));
        return b;
    }

private:
    bool started_ = false;
    Difficulty difficulty_ = Difficulty::Easy;
    Outcome outcome_ = Outcome::Running;
    int population_ = 0;
    int units_ = 1;
    double need_per_person_ = 0.0;   // kcal a day for one person
    double stock_kcal_ = 0.0;
    double elapsed_h_ = 0.0;
    double hunger_h_ = 0.0;          // the present spell of hunger: it ends the moment the crew eats in full again
    double hungry_total_h_ = 0.0;
    double harvested_kcal_ = 0.0;
    double eaten_kcal_ = 0.0;
    int plants_lost_ = 0;
    std::bitset<kSpecies.size()> crops_;
    bool growth_enabled_ = true;
    static constexpr int kBins = 128;                  // days of history kept (a bit more than the longest window)
    double harvest_bins_[kBins] = {};                  // kcal grown, per day (a ring: bin_ is today)
    int bin_ = 0;
    int age_days_ = 0;                                 // whole days the colony has lasted
    double bin_hours_ = 0.0;
    double plenty_h_ = 0.0;          // hours of plenty towards the next arrivals
    int arrivals_total_ = 0;
    int arrivals_pending_ = 0;
    int max_units_ = kMaxUnits;
    bool continue_after_goal_ = false;
    bool established_ = false;
    bool established_pending_ = false;

    // The days the surplus looks back over: the last growing season (or as long as the colony has lasted), and the part of today.
    double window_elapsed_days() const { return std::min(age_days_, kSurplusWindowDays) + bin_hours_ / 24.0; }
    // What the farm grew over them, in kcal.
    double window_harvest() const {
        const int days = std::min(age_days_, kSurplusWindowDays);
        double t = 0.0;
        for (int i = 0; i <= days; ++i) t += harvest_bins_[(bin_ + kBins - i) % kBins];     // today, and the days before it
        return t;
    }
    // Plenty for long enough brings more people, as many as the housing allows.
    void grow(double hours) {
        if (!growth_enabled_) return;
        if (!plenty()) {
            plenty_h_ = 0.0;
            return;
        }
        if (population_ >= housing()) return;          // full: the wait is over, the colony needs a new unit
        plenty_h_ += hours;
        if (plenty_h_ < kGrowthIntervalDays * 24.0) return;
        int arriving = std::min(rules().arrival_batch, housing() - population_);
        // the newcomers eat too: only as many as the last season's harvest would still have fed, with the margin
        const double grown = window_harvest();
        while (arriving > 0 && grown < kSurplusFactor * need_per_person_ * (population_ + arriving) * window_elapsed_days()) --arriving;
        if (arriving <= 0) return;                     // not yet: the clock stays full, and they come when the farm can feed them
        plenty_h_ = 0.0;
        population_ += arriving;
        arrivals_total_ += arriving;
        arrivals_pending_ += arriving;
    }
    Outcome failure_outcome() const {
        const double share = rules().evacuation_share;
        if (share >= 1.0) return Outcome::Evacuated;
        if (share > 0.0) return Outcome::EvacuatedWithLosses;
        return Outcome::Extinct;
    }
    Outcome finish(Outcome o) {
        outcome_ = o;
        return o;
    }
};

}  // namespace aevoria::farm

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
};

inline constexpr std::array<ColonyRules, 3> kColonyRules = {{
    //  name            crew  need   reserve  grace  goal   evac  score
    //                        kcal/d days     days   days   share x
    {"Easy",            4,    24.0,  100.0,   14.0,  120.0, 1.0,  1.0},
    {"Intermediate",    8,    50.0,   60.0,   10.0,  200.0, 0.5,  1.5},
    {"Difficult",      12,    66.0,   95.0,    7.0,  300.0, 0.0,  2.0},
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

struct ScoreBreakdown {
    double days = 0.0;
    double food = 0.0;
    double variety = 0.0;
    double reserve = 0.0;
    double lost = 0.0;       // a deduction, positive here
    double hunger = 0.0;     // a deduction, positive here
    double bonus = 0.0;
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
        need_per_day_ = r.need_kcal_day * std::max(0.01, demand_scale);
        const double reserve_days =
            std::min(r.start_reserve_days * std::max(0.01, reserve_scale), std::max(0.0, r.goal_days - r.grace_days - kMinFailureMarginDays));
        stock_kcal_ = reserve_days * need_per_day_;
    }
    void stop() { *this = Colony{}; }   // forget the colony: the bay is a sandbox again

    // The farm grew food.
    void add_harvest(int species_id, double kg) {
        if (!running()) return;
        const Species* s = find_species(species_id);
        if (s == nullptr || kg <= 0.0) return;
        const double kcal = kg * s->kcal_per_kg;
        stock_kcal_ += kcal;
        harvested_kcal_ += kcal;
        crops_.set(static_cast<std::size_t>(species_id));
    }
    void note_plant_lost() {
        if (running()) ++plants_lost_;
    }

    // Time passes. Returns the outcome if this step decided it, otherwise Outcome::Running.
    Outcome advance(double hours) {
        if (!running() || hours <= 0.0) return Outcome::Running;
        elapsed_h_ += hours;
        const double want = need_per_day_ * hours / 24.0;
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
        const ColonyRules& r = rules();
        if (hunger_h_ >= r.grace_days * 24.0) return finish(failure_outcome());
        if (elapsed_h_ >= r.goal_days * 24.0) return finish(Outcome::Success);
        return Outcome::Running;
    }

    // ---- what the colony looks like now -------------------------------------------------
    double day() const { return elapsed_h_ / 24.0; }
    double need_kcal_day() const { return need_per_day_; }
    double stock_kcal() const { return stock_kcal_; }
    double reserve_days() const { return need_per_day_ > 0.0 ? stock_kcal_ / need_per_day_ : 0.0; }
    bool starving() const { return running() && hunger_h_ > 0.0; }
    double hunger_days() const { return hunger_h_ / 24.0; }
    double hungry_days_total() const { return hungry_total_h_ / 24.0; }
    double harvested_kcal() const { return harvested_kcal_; }
    double eaten_kcal() const { return eaten_kcal_; }
    int crops_grown() const { return static_cast<int>(crops_.count()); }
    int plants_lost() const { return plants_lost_; }
    // People who are alive and well at the end: all of them after a success or a full evacuation, a share after a partial
    // one, none when extinct. While the colony is running it is the whole crew.
    int survivors() const {
        const int crew = started_ ? rules().crew : 0;
        switch (outcome_) {
            case Outcome::EvacuatedWithLosses: return static_cast<int>(std::floor(crew * rules().evacuation_share));
            case Outcome::Extinct: return 0;
            default: return crew;
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
        b.bonus = outcome_ == Outcome::Success ? kSuccessBonus : 0.0;
        b.multiplier = rules().score_multiplier;
        const double sum = b.days + b.food + b.variety + b.reserve + b.bonus - b.lost - b.hunger;
        b.total = std::max(0L, std::lround(sum * b.multiplier));
        return b;
    }

private:
    bool started_ = false;
    Difficulty difficulty_ = Difficulty::Easy;
    Outcome outcome_ = Outcome::Running;
    double need_per_day_ = 0.0;
    double stock_kcal_ = 0.0;
    double elapsed_h_ = 0.0;
    double hunger_h_ = 0.0;          // the present spell of hunger: it ends the moment the crew eats in full again
    double hungry_total_h_ = 0.0;
    double harvested_kcal_ = 0.0;
    double eaten_kcal_ = 0.0;
    int plants_lost_ = 0;
    std::bitset<kSpecies.size()> crops_;

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

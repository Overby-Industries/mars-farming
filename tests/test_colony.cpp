// The colony: the rules of the three difficulties, food, hunger, the outcomes, the score, and the whole thing played by
// simple strategies. The strategy runs are the calibration: they pin down which ways of farming win each difficulty, so
// retuning a number in colony.hpp or species.hpp shows up here as the change in who wins.
// Numbers that are checked by hand are worked out in the comments beside them.

#include <cmath>
#include <functional>
#include <vector>

#include "bay.hpp"
#include "check.hpp"

using namespace aevoria::farm;

namespace {

constexpr int kLettuce = 0;
constexpr int kRadish = 1;
constexpr int kPotato = 3;

// Run a colony for `hours`, an hour at a time as the bay does; returns the outcome if it was decided on the way.
Outcome run(Colony& c, double hours) {
    Outcome decided = Outcome::Running;
    for (double h = 0.0; h < hours - 1e-9; h += 1.0) {
        const Outcome o = c.advance(1.0);
        if (o != Outcome::Running) decided = o;
    }
    return decided;
}

// What a strategy sows in a bed on a colony day (-1: leave the bed empty).
using Sow = std::function<int(int bed, int day)>;

struct Played {
    Outcome outcome = Outcome::Running;
    double day = 0.0;
    long score = 0;
    int survivors = 0;
};

// Four beds of eight slots like the game's, the LEDs at the most the power budget allows (480 W: 0.75 of 160 W a bed), automatic
// irrigation, and a daily routine: feed a bed that is low, harvest what is ready, clear what has died, sow what the strategy says.
Played play(const Sow& sow, Difficulty d, std::uint64_t seed = 7) {
    Bay bay(seed);
    for (int i = 0; i < 4; ++i) {
        bay.add_bed(2, 4, 0.72);
        bay.bed(i).light_level = 0.75;
    }
    bay.settings.auto_irrigate = true;
    bay.start_colony(d);
    int day = 0;
    while (bay.colony.running() && day < 500) {
        ++day;
        for (int bi = 0; bi < 4; ++bi) {
            if (bay.bed(bi).nutrient < 0.5 && bay.nutrient_stock > 0.0) bay.feed(bi, 3.0);
            for (int slot = 0; slot < 8; ++slot) {
                const Plant& p = bay.plant_at(bi, slot);
                if (p.stage == Stage::Ready || p.stage == Stage::Overripe) bay.harvest(bi, slot);
                if (p.stage == Stage::Dead) bay.remove(bi, slot);
                if (bay.plant_at(bi, slot).species < 0) {
                    const int crop = sow(bi, day);
                    if (crop >= 0) bay.plant(bi, slot, crop);
                }
            }
        }
        bay.advance(24.0);
    }
    Played out;
    out.outcome = bay.colony.outcome();
    out.day = bay.colony.day();
    out.score = bay.colony.score().total;
    out.survivors = bay.colony.survivors();
    return out;
}

const Sow kNothing = [](int, int) { return -1; };
const Sow kAllLettuce = [](int, int) { return kLettuce; };
const Sow kAllPotato = [](int, int) { return kPotato; };
const Sow kLettuce1Potato3 = [](int bed, int) { return bed == 0 ? kLettuce : kPotato; };
const Sow kLettuce2Potato2 = [](int bed, int) { return bed < 2 ? kLettuce : kPotato; };

}  // namespace

void runColonyTests() {
    // ---- the rules of the three difficulties -------------------------------------------
    {
        double last_need = 0.0, last_goal = 0.0, last_multiplier = 0.0;
        double last_grace = 1e9;
        for (std::size_t i = 0; i < kColonyRules.size(); ++i) {
            const ColonyRules& r = colony_rules(static_cast<Difficulty>(i));
            CHECK(r.name != nullptr && r.crew > 0 && r.need_kcal_day > 0.0);
            CHECK(r.start_reserve_days > 0.0 && r.grace_days > 0.0 && r.goal_days > 0.0);
            // a colony that grows nothing runs out of food, then out of patience, before the goal
            CHECK(r.start_reserve_days + r.grace_days + kMinFailureMarginDays <= r.goal_days);
            CHECK(r.evacuation_share >= 0.0 && r.evacuation_share <= 1.0);
            // each step up asks for more food for longer, gives less patience, and scores more
            CHECK(r.need_kcal_day > last_need && r.goal_days > last_goal && r.grace_days < last_grace && r.score_multiplier > last_multiplier);
            last_need = r.need_kcal_day;
            last_goal = r.goal_days;
            last_grace = r.grace_days;
            last_multiplier = r.score_multiplier;
        }
        // Earth is fine, damaged, or gone
        CHECK_NEAR(colony_rules(Difficulty::Easy).evacuation_share, 1.0, 0.0);
        CHECK(colony_rules(Difficulty::Intermediate).evacuation_share > 0.0 && colony_rules(Difficulty::Intermediate).evacuation_share < 1.0);
        CHECK_NEAR(colony_rules(Difficulty::Difficult).evacuation_share, 0.0, 0.0);
    }

    // ---- no colony: a sandbox -------------------------------------------------------
    {
        Colony c;
        CHECK(!c.started() && !c.running() && c.outcome() == Outcome::Running);
        CHECK(c.advance(24.0) == Outcome::Running);
        c.add_harvest(kLettuce, 1.0);
        c.note_plant_lost();
        CHECK_NEAR(c.harvested_kcal(), 0.0, 0.0);
        CHECK(c.plants_lost() == 0 && c.score().total == 0 && c.survivors() == 0);
    }

    // ---- food: the reserve, eating, harvests ----------------------------------------
    {
        Colony c;
        c.start(Difficulty::Easy);
        CHECK(c.started() && c.running() && c.difficulty() == Difficulty::Easy);
        CHECK_NEAR(c.need_kcal_day(), 24.0, 1e-12);
        CHECK_NEAR(c.stock_kcal(), 2400.0, 1e-9);        // 100 days of 24 kcal
        CHECK_NEAR(c.reserve_days(), 100.0, 1e-9);
        CHECK(c.advance(24.0) == Outcome::Running);
        CHECK_NEAR(c.stock_kcal(), 2376.0, 1e-9);         // a day's food eaten
        CHECK_NEAR(c.eaten_kcal(), 24.0, 1e-9);
        CHECK_NEAR(c.day(), 1.0, 1e-12);
        c.add_harvest(kPotato, 1.0);                      // 1 kg of potato is 770 kcal
        CHECK_NEAR(c.stock_kcal(), 3146.0, 1e-9);
        CHECK_NEAR(c.harvested_kcal(), 770.0, 1e-9);
        CHECK(c.crops_grown() == 1);
        c.add_harvest(kPotato, 0.5);                      // the same crop again: no new variety
        CHECK(c.crops_grown() == 1);
        c.add_harvest(kLettuce, 1.0);
        CHECK(c.crops_grown() == 2);
        const double before = c.harvested_kcal();
        c.add_harvest(99, 1.0);                           // not a crop
        c.add_harvest(kRadish, -1.0);                     // not a harvest
        c.add_harvest(kRadish, 0.0);
        CHECK_NEAR(c.harvested_kcal(), before, 0.0);
        CHECK(c.crops_grown() == 2);
    }

    // ---- hunger comes when the store is empty, and ends when the crew eats in full again -------
    {
        Colony c;
        c.start(Difficulty::Easy);
        CHECK(run(c, 100.0 * 24.0) == Outcome::Running);   // 100 days: the reserve lasts exactly that long
        CHECK_NEAR(c.stock_kcal(), 0.0, 1e-6);
        CHECK(!c.starving());
        CHECK(run(c, 24.0) == Outcome::Running);
        CHECK(c.starving());
        CHECK_NEAR(c.hunger_days(), 1.0, 1e-9);
        CHECK_NEAR(c.hungry_days_total(), 1.0, 1e-9);
        c.add_harvest(kLettuce, 1.0);                      // 150 kcal: six days of food
        CHECK(run(c, 24.0) == Outcome::Running);
        CHECK(!c.starving());
        CHECK_NEAR(c.hunger_days(), 0.0, 0.0);             // the spell is over ...
        CHECK_NEAR(c.hungry_days_total(), 1.0, 1e-9);      // ... but it is remembered for the score
    }

    // ---- failing: what it means on each difficulty -----------------------------------
    struct Failure {
        Difficulty d;
        Outcome outcome;
        double day;       // the reserve, then the grace
        int survivors;
    };
    const Failure failures[] = {
        {Difficulty::Easy, Outcome::Evacuated, 100.0 + 14.0, 4},                  // everyone goes home
        {Difficulty::Intermediate, Outcome::EvacuatedWithLosses, 60.0 + 10.0, 4}, // Earth takes half of the eight
        {Difficulty::Difficult, Outcome::Extinct, 95.0 + 7.0, 0},                 // nowhere to go
    };
    for (const Failure& f : failures) {
        Colony c;
        c.start(f.d);
        const Outcome o = run(c, 400.0 * 24.0);
        CHECK(o == f.outcome);
        CHECK(c.outcome() == f.outcome && !c.running());
        CHECK_NEAR(c.day(), f.day, 0.05);
        CHECK(c.survivors() == f.survivors);
        // decided once: later time changes nothing
        const double day = c.day();
        CHECK(c.advance(24.0) == Outcome::Running);
        CHECK_NEAR(c.day(), day, 0.0);
        CHECK(c.outcome() == f.outcome);
    }

    // ---- winning: keep the crew fed for the goal period ------------------------------
    for (std::size_t i = 0; i < kColonyRules.size(); ++i) {
        const Difficulty d = static_cast<Difficulty>(i);
        Colony c;
        c.start(d);
        Outcome o = Outcome::Running;
        for (int day = 0; day < 400 && o == Outcome::Running; ++day) {
            c.add_harvest(kPotato, 0.2);                   // 154 kcal a day: more than any difficulty eats
            const Outcome step = run(c, 24.0);
            if (step != Outcome::Running) o = step;
        }
        CHECK(o == Outcome::Success && c.outcome() == Outcome::Success);
        CHECK_NEAR(c.day(), colony_rules(d).goal_days, 0.05);
        CHECK(c.survivors() == colony_rules(d).crew);
        CHECK(c.score().bonus > 0.0);
    }

    // ---- a game can scale the colony, but doing nothing always fails ----------------------
    {
        Colony c;
        c.start(Difficulty::Easy, 2.0, 1.0);               // twice the demand
        CHECK_NEAR(c.need_kcal_day(), 48.0, 1e-12);
        CHECK_NEAR(c.reserve_days(), 100.0, 1e-9);
        c.start(Difficulty::Intermediate, 1.0, 1.6);       // a longer reserve: 60 x 1.6 = 96 days
        CHECK_NEAR(c.reserve_days(), 96.0, 1e-9);
        c.start(Difficulty::Easy, 1.0, 5.0);               // a huge reserve is cut to goal - grace - margin = 120 - 14 - 6 = 100 days
        CHECK_NEAR(c.reserve_days(), 100.0, 1e-9);
        CHECK(run(c, 400.0 * 24.0) == Outcome::Evacuated);
        c.stop();
        CHECK(!c.started() && c.outcome() == Outcome::Running && c.score().total == 0);
    }

    // ---- the score ---------------------------------------------------------------------
    {
        // Easy, two kilos of lettuce (300 kcal) and ten days:
        //   days 3 x 10 = 30, food 0.5 x 300 = 150, variety 150 x 1 crop, reserve: (2400 + 300 - 240) = 2460 kcal is 102.5 days,
        //   counted to the 60-day cap = 600, nothing lost, no hunger, no bonus; x1.0 = 930
        Colony c;
        c.start(Difficulty::Easy);
        c.add_harvest(kLettuce, 2.0);
        run(c, 10.0 * 24.0);
        ScoreBreakdown b = c.score();
        CHECK_NEAR(b.days, 30.0, 1e-9);
        CHECK_NEAR(b.food, 150.0, 1e-9);
        CHECK_NEAR(b.variety, 150.0, 1e-9);
        CHECK_NEAR(b.reserve, 600.0, 1e-9);
        CHECK_NEAR(b.lost, 0.0, 0.0);
        CHECK_NEAR(b.hunger, 0.0, 0.0);
        CHECK_NEAR(b.bonus, 0.0, 0.0);
        CHECK_NEAR(b.multiplier, 1.0, 0.0);
        CHECK(b.total == 930);
        c.note_plant_lost();
        c.note_plant_lost();                               // two plants lost: 2 x 40 = 80 off
        CHECK(c.score().total == 850);
        CHECK(c.plants_lost() == 2);

        // Difficult, a kilo of radish (160 kcal) and five days:
        //   days 15, food 80, variety 150, reserve (95 x 66 + 160 - 5 x 66 = 6100 kcal, 92.4 days, capped) 600; x2.0 = 1690
        Colony h;
        h.start(Difficulty::Difficult);
        h.add_harvest(kRadish, 1.0);
        run(h, 5.0 * 24.0);
        CHECK(h.score().total == 1690);

        // a failed run never scores below zero, and a hungry colony loses points
        Colony n;
        n.start(Difficulty::Easy);
        run(n, 400.0 * 24.0);
        CHECK(n.score().total >= 0);
        CHECK_NEAR(n.score().hunger, 25.0 * 14.0, 1e-6);   // fourteen hungry days
    }

    // ---- inside the bay: harvests feed the colony, deaths cost points, the outcome is an event --------
    {
        Bay bay(3);
        bay.add_bed(2, 4, 0.72);
        bay.settings.auto_irrigate = true;
        CHECK(!bay.colony.started());
        bay.advance(48.0);                                  // a bare bay is a sandbox: nothing happens to a colony
        CHECK(!bay.colony.started() && bay.take_events().size() <= 2);

        bay.start_colony(Difficulty::Easy);
        CHECK(bay.colony.running());
        CHECK(bay.plant(0, 0, kLettuce));
        int guard = 0;
        while (bay.plant_at(0, 0).stage != Stage::Ready && guard++ < 90 * 24) bay.advance(1.0);
        CHECK(bay.plant_at(0, 0).stage == Stage::Ready);
        const auto h = bay.harvest(0, 0);
        CHECK(h.has_value());
        CHECK_NEAR(bay.colony.harvested_kcal(), h->kg * kSpecies[static_cast<std::size_t>(kLettuce)].kcal_per_kg, 1e-9);
        CHECK(bay.colony.crops_grown() == 1);
        bay.take_events();

        // a plant that dies is counted against the colony: radishes in a bed with no water
        Bay dry(4);
        dry.add_bed(2, 4, 0.72);
        dry.bed(0).water_l = 0.0;
        dry.start_colony(Difficulty::Easy);
        CHECK(dry.plant(0, 0, kRadish));
        dry.advance(24.0 * 6.0);
        CHECK(dry.plant_at(0, 0).stage == Stage::Dead);
        CHECK(dry.colony.plants_lost() == 1);

        // the outcome arrives as one event, on the step that decides it
        Bay doomed(5);
        doomed.add_bed(2, 4, 0.72);
        doomed.start_colony(Difficulty::Difficult);
        doomed.advance(24.0 * 101.0);
        int outcomes = 0;
        for (const Event& e : doomed.take_events()) outcomes += e.type == EventType::ColonyOutcome ? 1 : 0;
        CHECK(outcomes == 0 && doomed.colony.running());    // day 101 of 102: still hanging on
        doomed.advance(24.0 * 2.0);
        int extinct = 0;
        for (const Event& e : doomed.take_events()) {
            if (e.type == EventType::ColonyOutcome) {
                ++extinct;
                CHECK(e.value == static_cast<int>(Outcome::Extinct));
            }
        }
        CHECK(extinct == 1 && doomed.colony.outcome() == Outcome::Extinct);
        doomed.advance(24.0 * 30.0);
        for (const Event& e : doomed.take_events()) CHECK(e.type != EventType::ColonyOutcome);   // not again
    }

    // ---- played by strategies: who wins each difficulty ------------------------------
    {
        // Easy: doing nothing fails (the food runs out on day 114), and almost any farming wins
        const Played easy_none = play(kNothing, Difficulty::Easy);
        CHECK(easy_none.outcome == Outcome::Evacuated);
        CHECK_NEAR(easy_none.day, 114.0, 0.05);
        CHECK(easy_none.survivors == 4);
        const Played easy_lettuce = play(kAllLettuce, Difficulty::Easy);
        CHECK(easy_lettuce.outcome == Outcome::Success && easy_lettuce.survivors == 4);
        CHECK(play(kAllPotato, Difficulty::Easy).outcome == Outcome::Success);

        // Intermediate: lettuce alone is not enough, and neither is waiting for potatoes; two lettuce beds to bridge and two of potato are
        const Played mid_none = play(kNothing, Difficulty::Intermediate);
        CHECK(mid_none.outcome == Outcome::EvacuatedWithLosses && mid_none.survivors == 4);
        CHECK_NEAR(mid_none.day, 70.0, 0.05);
        CHECK(play(kAllLettuce, Difficulty::Intermediate).outcome == Outcome::EvacuatedWithLosses);
        CHECK(play(kAllPotato, Difficulty::Intermediate).outcome == Outcome::EvacuatedWithLosses);   // the first potatoes come on day 105
        const Played mid_mix = play(kLettuce2Potato2, Difficulty::Intermediate);
        CHECK(mid_mix.outcome == Outcome::Success);

        // Difficult: potatoes are the only crop with the food in them, but they take 105 days, so lettuce must carry the colony until then
        const Played hard_none = play(kNothing, Difficulty::Difficult);
        CHECK(hard_none.outcome == Outcome::Extinct && hard_none.survivors == 0);
        CHECK_NEAR(hard_none.day, 102.0, 0.05);
        CHECK(play(kAllLettuce, Difficulty::Difficult).outcome == Outcome::Extinct);
        CHECK(play(kAllPotato, Difficulty::Difficult).outcome == Outcome::Extinct);
        CHECK(play(kLettuce2Potato2, Difficulty::Difficult).outcome == Outcome::Extinct);
        const Played hard_mix = play(kLettuce1Potato3, Difficulty::Difficult);
        CHECK(hard_mix.outcome == Outcome::Success && hard_mix.survivors == 12);

        // a win on a harder difficulty is worth more, and a loss on any difficulty is worth less than a win on it
        CHECK(hard_mix.score > mid_mix.score && mid_mix.score > easy_lettuce.score);
        CHECK(easy_none.score < easy_lettuce.score && hard_none.score < hard_mix.score);

        // the same play gives the same game
        const Played again = play(kLettuce1Potato3, Difficulty::Difficult);
        CHECK(again.outcome == hard_mix.outcome && again.score == hard_mix.score);
        CHECK_NEAR(again.day, hard_mix.day, 0.0);
    }
}

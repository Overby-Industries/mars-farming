// The colony: the rules of the three difficulties, food, hunger, the outcomes, the score, and the whole thing played by
// simple strategies. The strategy runs are the calibration: they pin down which ways of farming win each difficulty, so
// retuning a number in colony.hpp or species.hpp shows up here as the change in who wins.
// Numbers that are checked by hand are worked out in the comments beside them.

#include <cmath>
#include <functional>
#include <memory>
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
    bay.colony.set_growth(false);         // these runs are about the food balance: nobody arrives
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

// The same strategies with growth ON, over several greenhouses: the daily routine of play() in every bay, and, if `build`, a new greenhouse
// (farmed the same way) as soon as the colony may have one.
struct Grown {
    Outcome outcome = Outcome::Running;
    double day = 0.0;
    long score = 0;
    int units = 0;
    int population = 0;
};

Grown play_grown(const Sow& sow, Difficulty d, bool build, std::uint64_t seed = 7) {
    auto make = [](std::uint64_t s) {
        auto b = std::make_unique<Bay>(s);
        for (int i = 0; i < 4; ++i) {
            b->add_bed(2, 4, 0.72);
            b->bed(i).light_level = 0.75;
        }
        b->settings.auto_irrigate = true;
        return b;
    };
    std::vector<std::unique_ptr<Bay>> bays;
    bays.push_back(make(seed));
    Bay& first = *bays[0];
    first.start_colony(d);
    int day = 0;
    while (first.colony.running() && day < 500) {
        ++day;
        for (auto& bay : bays) {
            for (int bi = 0; bi < 4; ++bi) {
                if (bay->bed(bi).nutrient < 0.5 && bay->nutrient_stock > 0.0) bay->feed(bi, 3.0);
                for (int slot = 0; slot < 8; ++slot) {
                    const Plant& p = bay->plant_at(bi, slot);
                    if (p.stage == Stage::Ready || p.stage == Stage::Overripe) bay->harvest(bi, slot);
                    if (p.stage == Stage::Dead) bay->remove(bi, slot);
                    if (bay->plant_at(bi, slot).species < 0) {
                        const int crop = sow(bi, day);
                        if (crop >= 0) bay->plant(bi, slot, crop);
                    }
                }
            }
        }
        for (auto& bay : bays) {
            bay->advance(24.0);
            bay->take_events();
        }
        if (build && first.colony.add_unit()) {
            bays.push_back(make(seed + bays.size()));
            bays.back()->link_colony(first);
        }
    }
    Grown out;
    out.outcome = first.colony.outcome();
    out.day = first.colony.day();
    out.score = first.colony.score().total;
    out.units = first.colony.units();
    out.population = first.colony.population();
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
            CHECK(r.arrival_batch > 0 && static_cast<int>(std::ceil(r.crew * kHousingFactor)) > r.crew);   // there is room to grow into
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
        c.set_growth(false);
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


    // ---- food to spare: the colony may expand, and when the farm out-grows the crew, more people come --------------
    {
        Colony c;
        c.start(Difficulty::Easy);
        CHECK(c.population() == 4 && c.units() == 1 && c.housing() == 6 && !c.crowded());   // housing: ceil(4 x 1.5) a unit
        CHECK(!c.expansion_ready());                                      // a big reserve, but the farm has grown nothing yet
        run(c, 50.0 * 24.0);                                              // ... and it stays that way: nobody comes either
        CHECK(c.population() == 4 && c.arrivals_total() == 0 && !c.plenty() && !c.expansion_ready() && c.surplus_ratio() == 0.0);

        // a farm that feeds the colony and more: Difficult, 66 kcal a day asked and 770 harvested every day
        Colony f;
        f.start(Difficulty::Difficult);                                   // 12 people, 18 housed per unit, four arrive at a time
        auto day = [&]() {
            f.add_harvest(kPotato, 1.0);
            run(f, 24.0);
        };
        day();
        CHECK(f.expansion_ready() && !f.plenty());                        // the store and a harvest behind it: it may build already; but no one comes yet
        CHECK(f.surplus_ratio() > 11.0 && f.surplus_ratio() < 12.0);      // 770 grown for 66 eaten
        for (int i = 1; i < 25; ++i) day();
        CHECK(f.plenty() && f.population() == 12 && f.growth_progress() > 0.8 && f.growth_progress() < 1.0);   // twenty days old: plenty began
        day();                                                            // six days of plenty: four more colonists
        CHECK(f.population() == 16 && f.arrivals_total() == 4 && f.take_arrivals() == 4 && f.take_arrivals() == 0);
        CHECK_NEAR(f.need_kcal_day(), 88.0, 1e-9);                        // 5.5 kcal a day each
        CHECK(f.expansion_ready() && !f.crowded());                       // food to spare, room to spare
        for (int i = 0; i < 6; ++i) day();                                // two more fill the housing (18)
        CHECK(f.population() == 18 && f.crowded() && f.expansion_ready());
        CHECK_NEAR(f.score().growth, 120.0, 0.0);                         // 6 x 20 points
        const double before = f.stock_kcal();
        CHECK(f.add_unit() && f.units() == 2 && f.housing() == 36 && !f.crowded());
        CHECK_NEAR(before - f.stock_kcal(), 10.0 * 99.0, 1e-6);           // the building crew ate ten days of food (18 x 5.5 kcal)
        CHECK(f.expansion_ready());                                       // with this much food it may build the next at once
        CHECK_NEAR(f.score().expansion, 400.0, 0.0);
        int guard = 0;
        while (f.units() < kMaxUnits && guard++ < 300) {                  // keep building
            day();
            if (f.expansion_ready()) CHECK(f.add_unit());
        }
        CHECK(f.units() == kMaxUnits && f.housing() == 72);
        while (f.population() < f.housing() && guard++ < 400) day();      // ... and the people fill it
        CHECK(f.population() == 72 && !f.expansion_ready() && !f.add_unit());   // no site left
        CHECK(f.running() && f.day() < 300.0);

        // the newcomers eat too: a farm that out-grows twelve people by half, but not eighteen, brings only as many as it can feed
        Colony g;
        g.start(Difficulty::Difficult);                                   // 12 people, 66 kcal a day; 18 would need 99
        for (int i = 0; i < 80; ++i) {
            g.add_harvest(kPotato, 1.8 * 66.0 / 770.0);                   // 118.8 kcal a day: 1.8 times what twelve need, 1.2 times what eighteen do
            run(g, 24.0);
        }
        CHECK(g.plenty() && g.population() > 12 && g.population() < 18);   // some came while the margin lasted ...
        const int settled = g.population();
        for (int i = 0; i < 60; ++i) {
            g.add_harvest(kPotato, 1.8 * 66.0 / 770.0);
            run(g, 24.0);
        }
        CHECK(g.population() == settled);                                 // ... and no more once a larger crew would leave it under 1.5 times

        // expansion costs food: not with a thin store, and not while the crew is hungry
        Colony t;
        t.start(Difficulty::Intermediate);                                // 8 people, 50 kcal a day, 60 days in store
        t.add_harvest(kPotato, 1.0);                                      // 770 kcal, a harvest behind it (15 days of food)
        CHECK(t.expansion_ready());
        run(t, 40.0 * 24.0);                                              // 40 days of eating: 3770 - 2000 = 1770 kcal, 35 days in store
        CHECK(t.reserve_days() > 30.0 && t.expansion_ready());
        run(t, 8.0 * 24.0);                                               // 3770 - 2400 = 1370 kcal, 27 days: too thin to spend ten of them on building
        CHECK(t.reserve_days() < 30.0 && !t.expansion_ready() && !t.add_unit() && t.units() == 1);
    }
    {
        // arrivals can be switched off, and they stop when the plenty does
        Colony c;
        c.start(Difficulty::Easy);
        c.set_growth(false);
        for (int i = 0; i < 40; ++i) {
            c.add_harvest(kPotato, 0.2);
            run(c, 24.0);
        }
        CHECK(!c.growth_enabled() && c.population() == 4 && c.plenty());

        // Intermediate with a small harvest: the reserve is large, but the farm has not out-grown the crew, so nobody comes
        Colony m;
        m.start(Difficulty::Intermediate);                                // 8 people, 50 kcal a day, 60 days in store
        m.add_harvest(kPotato, 1.0);                                      // 770 kcal: 63.5 days in store
        run(m, 60.0 * 24.0);                                              // eaten 3000 against 770 grown (0.26): no plenty, ever
        CHECK(m.population() == 8 && m.arrivals_total() == 0 && !m.plenty() && m.surplus_ratio() < 0.3);
        const Outcome o = run(m, 400.0 * 24.0);
        CHECK(o == Outcome::EvacuatedWithLosses && m.survivors() == 4);   // the half of 8 that Earth can take back

        // a farm that only just feeds the crew (every day 1.2 times what it eats) has no surplus to share either
        Colony j;
        j.start(Difficulty::Easy);
        for (int i = 0; i < 60; ++i) {
            j.add_harvest(kLettuce, 1.2 * 24.0 / 150.0);                  // 28.8 kcal of lettuce a day against 24 eaten
            run(j, 24.0);
        }
        CHECK(!j.plenty() && j.population() == 4 && j.surplus_ratio() > 1.1 && j.surplus_ratio() < 1.3);
        for (int i = 0; i < 50; ++i) {                                    // twice what it eats does
            j.add_harvest(kLettuce, 2.0 * 24.0 / 150.0);
            run(j, 24.0);
        }
        CHECK(j.surplus_ratio() > 1.5 && j.plenty());                     // (the last season: 55 days at 1.2 and 50 at 2: 3,984 against 2,520)
    }

    // ---- several bays, one colony ---------------------------------------------------------
    {
        Bay a(11);
        Bay b(12);
        a.add_bed(2, 4, 0.72);
        b.add_bed(2, 4, 0.72);
        a.settings.auto_irrigate = b.settings.auto_irrigate = true;
        b.link_colony(a);
        a.start_colony(Difficulty::Easy);
        CHECK(b.colony_linked() && !a.colony_linked() && !b.colony.started());
        Bay self(13);
        self.link_colony(self);                                           // a bay cannot link to itself
        CHECK(!self.colony_linked());

        CHECK(b.plant(0, 0, kLettuce));
        int guard = 0;
        while (b.plant_at(0, 0).stage != Stage::Ready && guard++ < 90 * 24) {
            a.advance(1.0);
            b.advance(1.0);
        }
        CHECK(b.plant_at(0, 0).stage == Stage::Ready);
        CHECK_NEAR(a.colony.day(), guard / 24.0, 1e-6);                   // the colony's clock is the first bay's alone
        const auto h = b.harvest(0, 0);
        CHECK(h.has_value());
        CHECK_NEAR(a.colony.harvested_kcal(), h->kg * kSpecies[static_cast<std::size_t>(kLettuce)].kcal_per_kg, 1e-9);   // what b grew fed a's colony
        CHECK(!b.colony.started() && b.colony.harvested_kcal() == 0.0);

        // plants lost in b count against a's colony
        b.bed(0).water_l = 0.0;
        b.settings.auto_irrigate = false;
        CHECK(b.plant(0, 1, kRadish));
        for (int i = 0; i < 6 * 24; ++i) {
            a.advance(1.0);
            b.advance(1.0);
        }
        CHECK(b.plant_at(0, 1).stage == Stage::Dead && a.colony.plants_lost() == 1);
        b.unlink_colony();
        CHECK(!b.colony_linked());

        // arrivals are an event of the bay that holds the colony
        Bay c(14);
        c.add_bed(2, 4, 0.72);
        c.start_colony(Difficulty::Easy);
        c.colony.add_harvest(kPotato, 10.0);                              // 7,700 kcal: plenty from the twentieth day
        c.advance(27.0 * 24.0);
        int arrivals = 0;
        for (const Event& e : c.take_events()) {
            if (e.type == EventType::ColonyArrival) {
                ++arrivals;
                CHECK(e.value == 6);                                      // the new population
            }
        }
        CHECK(arrivals == 1 && c.colony.population() == 6);
    }


    // ---- Mars: the plants' oxygen thickens the air ------------------------------------------------
    {
        Terraform off;
        off.add_leaf_hours(1000.0);
        CHECK(!off.enabled() && off.advance(24.0) == 0 && off.progress() == 0.0);       // the station game leaves it off

        // five square metres of leaf at work, a hundred days: the index climbs towards where the gain and the loss meet
        Terraform t;
        t.enable(true);
        const double equilibrium = kTerraformGainPerLeafDay * 4.0 / kTerraformLossPerDay;    // 1.04
        std::vector<int> stages;
        for (int h = 0; h < 100 * 24; ++h) {
            t.add_leaf_hours(4.0);
            const int crossed = t.advance(1.0);
            if (crossed > 0) stages.push_back(crossed);
        }
        CHECK_NEAR(t.progress(), equilibrium * (1.0 - std::exp(-kTerraformLossPerDay * 100.0)), 0.01);   // 0.41
        CHECK(stages == (std::vector<int>{1}) && t.stage() == 1 && !t.complete());      // the air is thickening
        CHECK_NEAR(t.leaf_area_m2(), 4.0, 0.01);
        CHECK_NEAR(t.equilibrium(), equilibrium, 0.01);
        for (int h = 0; h < 100 * 24; ++h) {                                              // another hundred days: 0.66, past half
            t.add_leaf_hours(4.0);
            const int crossed = t.advance(1.0);
            if (crossed > 0) stages.push_back(crossed);
        }
        CHECK(stages == (std::vector<int>{1, 2}) && t.stage() == 2 && !t.complete());   // and open-air farming begins
        // the thin air takes it back when the plants go: half a percent of what there is, each day
        const double before = t.progress();
        for (int h = 0; h < 24; ++h) t.advance(1.0);
        CHECK_NEAR(t.progress(), before * (1.0 - kTerraformLossPerDay), 0.002);
        // enough leaf for long enough finishes it, and it stays at 1
        for (int h = 0; h < 600 * 24; ++h) {
            t.add_leaf_hours(8.0);
            t.advance(1.0);
        }
        CHECK(t.complete() && t.stage() == 4 && t.progress() <= 1.0);
    }
    {
        // in a bay: the plants of every linked dome work for the same air
        Bay mars(21);
        for (int i = 0; i < 4; ++i) mars.add_bed(2, 4, 0.72);
        Bay second(22);
        for (int i = 0; i < 4; ++i) second.add_bed(2, 4, 0.72);
        for (Bay* b : {&mars, &second}) {
            b->settings.auto_irrigate = true;
            for (int i = 0; i < 4; ++i) {
                b->bed(i).light_level = 0.75;
                for (int slot = 0; slot < 8; ++slot) b->plant(i, slot, kPotato);
            }
        }
        mars.setup_settlement(6, true, 2);
        mars.start_colony(Difficulty::Easy);
        CHECK(mars.terraform.enabled() && mars.colony.max_units() == 6);
        second.link_colony(mars);
        for (int h = 0; h < 40 * 24; ++h) {
            mars.advance(1.0);
            second.advance(1.0);
        }
        const double with_two = mars.terraform.leaf_area_m2();
        CHECK(with_two > 0.5 && mars.terraform.progress() > 0.0);
        CHECK(!second.terraform.enabled() || second.terraform.progress() == 0.0);       // only the first bay holds the air
        // the same dome alone puts about half as much leaf to work
        Bay alone(21);
        for (int i = 0; i < 4; ++i) {
            alone.add_bed(2, 4, 0.72);
            alone.bed(i).light_level = 0.75;
            for (int slot = 0; slot < 8; ++slot) alone.plant(i, slot, kPotato);
        }
        alone.settings.auto_irrigate = true;
        alone.setup_settlement(6, true, 2);
        for (int h = 0; h < 40 * 24; ++h) alone.advance(1.0);
        CHECK(with_two > 1.6 * alone.terraform.leaf_area_m2() && with_two < 2.4 * alone.terraform.leaf_area_m2());

        // open-air farming opens two more sites; a finished job is a win
        Bay w(23);
        w.add_bed(2, 4, 0.72);
        w.setup_settlement(6, true, 2);
        w.start_colony(Difficulty::Easy);
        w.terraform.add_leaf_hours(0.6 * 24.0 / kTerraformGainPerLeafDay);          // enough in one go for about 0.6
        w.advance(1.0);
        CHECK(w.terraform.stage() == 2 && w.colony.max_units() == 8);
        int staged = 0;
        for (const Event& e : w.take_events()) {
            if (e.type == EventType::TerraformStage) {
                ++staged;
                CHECK(e.value == 2);
            }
        }
        CHECK(staged == 1);
        // the air wobbles about a threshold (the harvests come in waves): the stage is announced once, and the sites it opened stay open
        for (int h = 0; h < 45 * 24; ++h) w.advance(1.0);                            // no leaf at work: the thin air takes it back (0.6 to 0.48)
        CHECK(w.terraform.stage() < 2 && w.terraform.best_stage() == 2 && w.colony.max_units() == 8);
        w.take_events();
        w.terraform.add_leaf_hours(0.25 * 24.0 / kTerraformGainPerLeafDay);          // and back over half
        w.advance(1.0);
        int again = 0;
        for (const Event& e : w.take_events()) again += e.type == EventType::TerraformStage ? 1 : 0;
        CHECK(w.terraform.stage() == 2 && again == 0);
        w.terraform.add_leaf_hours(1.0e7);
        w.advance(1.0);
        CHECK(w.terraform.complete() && w.colony.outcome() == Outcome::Terraformed && !w.colony.running());
        int won = 0;
        for (const Event& e : w.take_events()) won += e.type == EventType::ColonyOutcome && e.value == static_cast<int>(Outcome::Terraformed) ? 1 : 0;
        CHECK(won == 1);
        CHECK(w.colony.survivors() == w.colony.population() && w.colony.score().bonus == kSuccessBonus + kTerraformBonus);
    }

    // ---- reaching the goal: end the run (the station), or go on (Mars) ------------------------
    {
        Bay mars(31);
        mars.add_bed(2, 4, 0.72);
        mars.setup_settlement(6, true, 2);
        mars.start_colony(Difficulty::Easy);
        mars.colony.set_growth(false);
        mars.colony.add_harvest(kPotato, 20.0);                      // food for a long time
        mars.advance(120.0 * 24.0);
        CHECK(mars.colony.established() && mars.colony.running() && mars.colony.outcome() == Outcome::Running);
        int established = 0;
        int outcomes = 0;
        for (const Event& e : mars.take_events()) {
            established += e.type == EventType::ColonyEstablished ? 1 : 0;
            outcomes += e.type == EventType::ColonyOutcome ? 1 : 0;
        }
        CHECK(established == 1 && outcomes == 0);
        CHECK(mars.colony.score().bonus == kSuccessBonus);          // the success is banked
        CHECK(!mars.colony.take_established());
        // an established colony is past starving: it carries on, with the hunger on the score
        mars.colony.add_harvest(kPotato, 0.0);
        const Outcome o = mars.colony.finish_established();
        CHECK(o == Outcome::Success && mars.colony.outcome() == Outcome::Success && !mars.colony.running());
        CHECK(mars.colony.finish_established() == Outcome::Running);

        Colony hungry;
        hungry.start(Difficulty::Easy);
        hungry.set_continue_after_goal(true);
        hungry.set_growth(false);
        for (int i = 0; i < 119; ++i) {
            hungry.add_harvest(kLettuce, 0.2);                       // fed, but only just
            run(hungry, 24.0);
        }
        hungry.add_harvest(kLettuce, 0.2);
        run(hungry, 24.0);
        CHECK(hungry.established());
        run(hungry, 200.0 * 24.0);                                   // nothing more is grown: it goes hungry for ever
        CHECK(hungry.running() && hungry.starving() && hungry.hungry_days_total() > 60.0 && hungry.hungry_days_total() < 80.0);   // the store (130 days) ran out
        CHECK(hungry.survivors() == hungry.population());

        Bay station(32);                                              // the station: the goal ends the run as before
        station.add_bed(2, 4, 0.72);
        station.start_colony(Difficulty::Easy);
        station.colony.set_growth(false);
        station.colony.add_harvest(kPotato, 20.0);
        station.advance(120.0 * 24.0);
        CHECK(!station.colony.established() && station.colony.outcome() == Outcome::Success);
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

    // ---- with growth on: the same strategies still win, with or without building; building makes the colony bigger and the score higher -----
    {
        struct Case {
            const char* name;
            const Sow* sow;
            Difficulty d;
        };
        const Case cases[] = {
            {"Easy, all lettuce", &kAllLettuce, Difficulty::Easy},
            {"Easy, all potato", &kAllPotato, Difficulty::Easy},
            {"Intermediate, two lettuce and two potato", &kLettuce2Potato2, Difficulty::Intermediate},
            {"Difficult, one lettuce and three potato", &kLettuce1Potato3, Difficulty::Difficult},
        };
        for (const Case& c : cases) {
            const Grown idle = play_grown(*c.sow, c.d, false);        // nobody builds: the colony's growth alone changes nothing that matters
            const Grown busy = play_grown(*c.sow, c.d, true);         // a greenhouse as soon as it is allowed
            const ColonyRules& r = colony_rules(c.d);
            CHECK(idle.outcome == Outcome::Success && idle.units == 1 && idle.population >= r.crew);
            CHECK(busy.outcome == Outcome::Success && busy.units == kMaxUnits);
            CHECK(busy.population >= idle.population && busy.score > idle.score);
        }
        // building is a way to win what one greenhouse cannot: lettuce alone fails Intermediate and Difficult in one greenhouse, and wins in four
        CHECK(play_grown(kAllLettuce, Difficulty::Intermediate, false).outcome == Outcome::EvacuatedWithLosses);
        CHECK(play_grown(kAllLettuce, Difficulty::Intermediate, true).outcome == Outcome::Success);
        CHECK(play_grown(kAllLettuce, Difficulty::Difficult, false).outcome == Outcome::Extinct);
        CHECK(play_grown(kAllLettuce, Difficulty::Difficult, true).outcome == Outcome::Success);
        CHECK(play_grown(kLettuce2Potato2, Difficulty::Difficult, false).outcome == Outcome::Extinct);
        CHECK(play_grown(kLettuce2Potato2, Difficulty::Difficult, true).outcome == Outcome::Success);
        // but only a colony that has grown some food can build: waiting for the potatoes fails exactly as it did, with nothing built
        const Grown wait_mid = play_grown(kAllPotato, Difficulty::Intermediate, true);
        const Grown wait_hard = play_grown(kAllPotato, Difficulty::Difficult, true);
        CHECK(wait_mid.outcome == Outcome::EvacuatedWithLosses && wait_mid.units == 1);
        CHECK(wait_hard.outcome == Outcome::Extinct && wait_hard.units == 1);
        // the colonies that are fed and have the room do grow: the Difficult one nearly threefold
        CHECK(play_grown(kLettuce1Potato3, Difficulty::Difficult, true).population >= 24);
        CHECK(play_grown(kAllLettuce, Difficulty::Intermediate, true).population >= 12);
    }
}

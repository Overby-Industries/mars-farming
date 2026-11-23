// The species table is data, and bad data breaks the model quietly: a trapezoid with its corners in the
// wrong order, a flowering threshold after the fruit threshold. These checks keep the table honest.

#include <set>
#include <string>

#include "check.hpp"
#include "plant.hpp"   // for kSproutEnd; it includes species.hpp

using namespace aevoria::farm;

void runSpeciesTests() {
    std::set<std::string> keys;
    for (std::size_t i = 0; i < kSpecies.size(); ++i) {
        const Species& s = kSpecies[i];
        CHECK(s.id == static_cast<int>(i));                    // the id is the index
        CHECK(!s.key.empty() && !s.name.empty());
        CHECK(keys.insert(std::string(s.key)).second);         // keys are unique
        CHECK(find_species(s.id) == &s);
        CHECK(find_species(s.key) == &s);

        CHECK(s.days_to_mature > 0.0);
        CHECK(s.ppfd_opt > 0.0 && s.ppfd_max > s.ppfd_opt);
        CHECK(s.temp_min < s.temp_opt_low && s.temp_opt_low < s.temp_opt_high && s.temp_opt_high < s.temp_max);
        CHECK(s.water_use > 0.0 && s.canopy_m2 > 0.0 && s.nutrient_use > 0.0 && s.yield_kg > 0.0);
        CHECK(s.kcal_per_kg > 50.0 && s.kcal_per_kg < 1000.0);        // fresh vegetables: 100 to 800 kcal per kg
        CHECK(s.ready_window_days > 0.0);

        // flowering and fruiting thresholds: absent (1.0) for crops that never flower on screen,
        // ordered and past the sprout stage for the ones that do
        CHECK(s.flower_start <= s.fruit_start && s.fruit_start <= 1.0);
        if (s.kind == Kind::Leafy || s.kind == Kind::Root) {
            CHECK_NEAR(s.flower_start, 1.0, 0.0);
            CHECK_NEAR(s.fruit_start, 1.0, 0.0);
        } else {
            CHECK(s.flower_start > kSproutEnd && s.flower_start < s.fruit_start && s.fruit_start < 1.0);
        }
    }
    CHECK(find_species(-1) == nullptr);
    CHECK(find_species(static_cast<int>(kSpecies.size())) == nullptr);
    CHECK(find_species(std::string_view("no-such-crop")) == nullptr);
}

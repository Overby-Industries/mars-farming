#pragma once

// The crops the first slice of the game can grow, as plain data.
//
// Every number here is a DESIGN VALUE, a tuning starting point chosen to sit
// inside the ranges used in controlled-environment growing (light of a few
// hundred umol/m2/s for 16 h a day, 15 to 25 deg C, a month for lettuce and
// nearly three for a dwarf tomato). They have not been validated against
// growth trials and should be tuned by playing, not trusted as agronomy.
//
// Units: light is PPFD in umol/m2/s at the canopy, temperature is deg C,
// water is litres, areas are m2, mass is kg of fresh produce.

#include <array>
#include <cstddef>
#include <string_view>

namespace aevoria::farm {

enum class Kind {
    Leafy,     // a rosette of leaves, harvested whole (lettuce)
    Root,      // a root swelling at the soil line (radish)
    Tuber,     // a leafy bush with the crop underground (potato)
    Fruiting,  // a bush that flowers and then carries fruit (tomato)
};

struct Species {
    int id;                       // index into kSpecies; stable, used in saves
    std::string_view key;         // stable text id, used in recipes and scripts
    std::string_view name;        // what the player sees
    Kind kind;
    double days_to_mature;        // seed to Ready under ideal conditions
    double ppfd_opt;              // light at which growth is no longer light-limited
    double ppfd_max;              // above this, extra light starts to hurt
    double temp_min;              // growth is zero at or below this ...
    double temp_opt_low;          // ... ramps up to full speed here ...
    double temp_opt_high;         // ... stays full speed up to here ...
    double temp_max;              // ... and falls to zero here
    double water_use;             // L per m2 of canopy per day, full size, lights on
    double canopy_m2;             // canopy of one full-size plant
    double nutrient_use;          // share of a bed's nutrient reserve one plant uses per life cycle
    double yield_kg;              // fresh mass of one healthy plant at harvest
    double flower_start;          // progress at which flowering begins (1 = never)
    double fruit_start;           // progress at which fruit begins (1 = never)
    double ready_window_days;     // days a Ready plant keeps full value before it spoils
};

inline constexpr std::array<Species, 4> kSpecies = {{
    //  id  key        name                    kind          days   ppfd  ppfd   temp:  min  low  high  max  water  canopy  nutr   yield  flower fruit window
    //                                                       mature opt   max                               use    m2      use    kg     start  start days
    {0, "lettuce", "Butterhead lettuce",  Kind::Leafy,    30.0, 250.0, 500.0,  4.0, 16.0, 22.0, 30.0, 2.0, 0.050, 0.020, 0.20, 1.00, 1.00, 5.0},
    {1, "radish",  "Cherry Belle radish", Kind::Root,     26.0, 250.0, 500.0,  5.0, 14.0, 20.0, 28.0, 1.5, 0.020, 0.012, 0.03, 1.00, 1.00, 4.0},
    {2, "tomato",  "Dwarf tomato",        Kind::Fruiting, 85.0, 450.0, 900.0, 10.0, 18.0, 26.0, 35.0, 3.5, 0.090, 0.060, 0.90, 0.55, 0.72, 7.0},
    // The tuber crop's "flowering" and "fruiting" stages are the flowering and the tuber-bulking phases; the
    // tubers are underground, so the plant's look only changes colour as the foliage ages toward harvest.
    {3, "potato",  "Dwarf potato",        Kind::Tuber,   100.0, 400.0, 800.0,  7.0, 15.0, 21.0, 30.0, 3.0, 0.100, 0.050, 0.35, 0.55, 0.70, 10.0},
}};

inline const Species* find_species(int id) {
    if (id < 0 || static_cast<std::size_t>(id) >= kSpecies.size()) return nullptr;
    return &kSpecies[static_cast<std::size_t>(id)];
}

inline const Species* find_species(std::string_view key) {
    for (const Species& s : kSpecies) {
        if (s.key == key) return &s;
    }
    return nullptr;
}

}  // namespace aevoria::farm

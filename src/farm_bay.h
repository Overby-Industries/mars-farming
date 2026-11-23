#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include "bay.hpp"

namespace godot {

/**
 * FarmBay: the Godot face of the pure C++ farm simulation in core/. It owns one bay (beds, plants,
 * lights, water, nutrients), advances it with the game clock, and hands scripts plain Dictionaries
 * and signals, so scene code never touches the model's internals.
 *
 * Time: `time_scale` is game hours per real second (1 = a day every 24 s). advance_hours() steps the
 * simulation directly, which is how tests drive it. Nothing advances in the editor.
 *
 * The colony (core/colony.hpp): start_colony(difficulty, demand_scale, reserve_scale) begins feeding a crew from this bay's
 * harvests; get_colony() reports its food, hunger, outcome and score; the colony_outcome signal says how it ended (OUTCOME_*).
 * Without start_colony() the bay is a sandbox.
 *
 * Settings (set_setting / get_setting), all numbers except auto_irrigate which is a bool:
 *   temp_c temp_swing_c light_on_hour light_off_hour led_w_per_bed led_umol_per_joule
 *   led_optical_efficiency power_budget_w sun_peak_ppfd dust_tau shade reclaim_fraction auto_irrigate
 */
class FarmBay : public Node {
    GDCLASS(FarmBay, Node)

private:
    aevoria::farm::Bay bay_;
    double time_scale_ = 1.0;
    bool paused_ = false;
    int seed_ = 1;

    void emit_events();

protected:
    static void _bind_methods();

public:
    FarmBay();
    ~FarmBay();

    void _process(double delta) override;

    void set_seed(int seed);
    int get_seed() const;

    int add_bed(int rows, int cols, double area_m2);
    int get_bed_count() const;
    Dictionary get_bed_info(int bed) const;
    void set_bed_light_level(int bed, double level);

    bool plant(int bed, int slot, const String &species_key);
    Dictionary harvest(int bed, int slot);
    bool remove(int bed, int slot);
    double irrigate(int bed, double liters);
    double feed(int bed, double units);
    Dictionary get_plant(int bed, int slot) const;

    Array get_species_list() const;
    Dictionary get_status() const;

    void set_setting(const String &key, const Variant &value);
    Variant get_setting(const String &key) const;

    void start_colony(int difficulty, double demand_scale = 1.0, double reserve_scale = 1.0);
    void stop_colony();
    Dictionary get_colony() const;
    static Dictionary get_difficulty_rules(int difficulty);

    void advance_hours(double hours);
    void set_time_scale(double hours_per_second);
    double get_time_scale() const;
    void set_paused(bool paused);
    bool is_paused() const;

    static String get_stage_name(int stage);
};

}  // namespace godot

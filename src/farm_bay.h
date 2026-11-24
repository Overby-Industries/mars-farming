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
 * A settlement has several bays (greenhouses or domes) and one colony: the first bay holds it, the others call link_colony(first), so
 * what they harvest feeds it and it is advanced once. setup_settlement() says how many sites there are and whether the game terraforms
 * (Mars: the plants' oxygen thickens the air, get_terraform()). The people grow in number when food is plentiful (colony_arrival) and
 * the colony may build another unit when they fill the housing (colony_add_unit()).
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
    int64_t linked_id_ = 0;        // the instance id of the bay this one is linked to (0: none), checked before every step

    void emit_events();
    void check_link();

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
    Dictionary get_terraform() const;
    void setup_settlement(int max_units, bool terraforming, int open_air_bonus);
    void link_colony(FarmBay *primary);
    void unlink_colony();
    bool colony_add_unit();
    void set_colony_growth(bool on);
    void colony_finish_established();
    static Dictionary get_expansion_rules();
    static Dictionary get_difficulty_rules(int difficulty);

    void advance_hours(double hours);
    void set_time_scale(double hours_per_second);
    double get_time_scale() const;
    void set_paused(bool paused);
    bool is_paused() const;

    static String get_stage_name(int stage);
};

}  // namespace godot

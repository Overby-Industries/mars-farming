#include "farm_bay.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <string_view>

using namespace godot;
using aevoria::farm::Bay;
using aevoria::farm::Bed;
using aevoria::farm::Difficulty;
using aevoria::farm::Outcome;
using aevoria::farm::EventType;
using aevoria::farm::Kind;
using aevoria::farm::Plant;
using aevoria::farm::Species;
using aevoria::farm::Stage;

namespace {

const char *kind_name(Kind k) {
    switch (k) {
        case Kind::Leafy: return "leafy";
        case Kind::Root: return "root";
        case Kind::Tuber: return "tuber";
        case Kind::Fruiting: return "fruiting";
    }
    return "leafy";
}

const char *outcome_name(Outcome o) {
    switch (o) {
        case Outcome::Running: return "running";
        case Outcome::Success: return "success";
        case Outcome::Evacuated: return "evacuated";
        case Outcome::EvacuatedWithLosses: return "evacuated_with_losses";
        case Outcome::Extinct: return "extinct";
        case Outcome::Terraformed: return "terraformed";
    }
    return "running";
}

Difficulty difficulty_from(int d) { return static_cast<Difficulty>(std::clamp(d, 0, 2)); }

String to_godot(std::string_view sv) { return String::utf8(sv.data(), static_cast<int64_t>(sv.size())); }

const Species *species_by_key(const String &key) {
    const CharString utf8 = key.utf8();
    return aevoria::farm::find_species(std::string_view(utf8.get_data()));
}

}  // namespace

void FarmBay::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_seed", "seed"), &FarmBay::set_seed);
    ClassDB::bind_method(D_METHOD("get_seed"), &FarmBay::get_seed);
    ClassDB::bind_method(D_METHOD("add_bed", "rows", "cols", "area_m2"), &FarmBay::add_bed);
    ClassDB::bind_method(D_METHOD("get_bed_count"), &FarmBay::get_bed_count);
    ClassDB::bind_method(D_METHOD("get_bed_info", "bed"), &FarmBay::get_bed_info);
    ClassDB::bind_method(D_METHOD("set_bed_light_level", "bed", "level"), &FarmBay::set_bed_light_level);
    ClassDB::bind_method(D_METHOD("plant", "bed", "slot", "species_key"), &FarmBay::plant);
    ClassDB::bind_method(D_METHOD("harvest", "bed", "slot"), &FarmBay::harvest);
    ClassDB::bind_method(D_METHOD("remove", "bed", "slot"), &FarmBay::remove);
    ClassDB::bind_method(D_METHOD("irrigate", "bed", "liters"), &FarmBay::irrigate);
    ClassDB::bind_method(D_METHOD("feed", "bed", "units"), &FarmBay::feed);
    ClassDB::bind_method(D_METHOD("get_plant", "bed", "slot"), &FarmBay::get_plant);
    ClassDB::bind_method(D_METHOD("get_species_list"), &FarmBay::get_species_list);
    ClassDB::bind_method(D_METHOD("get_status"), &FarmBay::get_status);
    ClassDB::bind_method(D_METHOD("set_setting", "key", "value"), &FarmBay::set_setting);
    ClassDB::bind_method(D_METHOD("get_setting", "key"), &FarmBay::get_setting);
    ClassDB::bind_method(D_METHOD("start_colony", "difficulty", "demand_scale", "reserve_scale"), &FarmBay::start_colony, DEFVAL(1.0), DEFVAL(1.0));
    ClassDB::bind_method(D_METHOD("stop_colony"), &FarmBay::stop_colony);
    ClassDB::bind_method(D_METHOD("get_colony"), &FarmBay::get_colony);
    ClassDB::bind_method(D_METHOD("get_terraform"), &FarmBay::get_terraform);
    ClassDB::bind_method(D_METHOD("setup_settlement", "max_units", "terraforming", "open_air_bonus"), &FarmBay::setup_settlement);
    ClassDB::bind_method(D_METHOD("link_colony", "primary"), &FarmBay::link_colony);
    ClassDB::bind_method(D_METHOD("unlink_colony"), &FarmBay::unlink_colony);
    ClassDB::bind_method(D_METHOD("colony_add_unit"), &FarmBay::colony_add_unit);
    ClassDB::bind_method(D_METHOD("set_colony_growth", "on"), &FarmBay::set_colony_growth);
    ClassDB::bind_method(D_METHOD("colony_finish_established"), &FarmBay::colony_finish_established);
    ClassDB::bind_static_method("FarmBay", D_METHOD("get_expansion_rules"), &FarmBay::get_expansion_rules);
    ClassDB::bind_static_method("FarmBay", D_METHOD("get_difficulty_rules", "difficulty"), &FarmBay::get_difficulty_rules);
    ClassDB::bind_method(D_METHOD("advance_hours", "hours"), &FarmBay::advance_hours);
    ClassDB::bind_method(D_METHOD("set_time_scale", "hours_per_second"), &FarmBay::set_time_scale);
    ClassDB::bind_method(D_METHOD("get_time_scale"), &FarmBay::get_time_scale);
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &FarmBay::set_paused);
    ClassDB::bind_method(D_METHOD("is_paused"), &FarmBay::is_paused);
    ClassDB::bind_static_method("FarmBay", D_METHOD("get_stage_name", "stage"), &FarmBay::get_stage_name);

    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "time_scale"), "set_time_scale", "get_time_scale");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paused"), "set_paused", "is_paused");

    ADD_SIGNAL(MethodInfo("plant_stage_changed", PropertyInfo(Variant::INT, "bed"), PropertyInfo(Variant::INT, "slot"),
                          PropertyInfo(Variant::INT, "stage")));
    ADD_SIGNAL(MethodInfo("plant_died", PropertyInfo(Variant::INT, "bed"), PropertyInfo(Variant::INT, "slot")));
    ADD_SIGNAL(MethodInfo("day_changed", PropertyInfo(Variant::INT, "day")));
    ADD_SIGNAL(MethodInfo("colony_outcome", PropertyInfo(Variant::INT, "outcome")));
    ADD_SIGNAL(MethodInfo("colony_arrival", PropertyInfo(Variant::INT, "population")));
    ADD_SIGNAL(MethodInfo("colony_established"));
    ADD_SIGNAL(MethodInfo("terraform_stage", PropertyInfo(Variant::INT, "stage")));

    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_EMPTY", static_cast<int>(Stage::Empty));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_SEED", static_cast<int>(Stage::Seed));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_SPROUT", static_cast<int>(Stage::Sprout));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_VEGETATIVE", static_cast<int>(Stage::Vegetative));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_FLOWERING", static_cast<int>(Stage::Flowering));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_FRUITING", static_cast<int>(Stage::Fruiting));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_READY", static_cast<int>(Stage::Ready));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_OVERRIPE", static_cast<int>(Stage::Overripe));
    ClassDB::bind_integer_constant(get_class_static(), "", "STAGE_DEAD", static_cast<int>(Stage::Dead));

    ClassDB::bind_integer_constant(get_class_static(), "", "DIFFICULTY_EASY", static_cast<int>(Difficulty::Easy));
    ClassDB::bind_integer_constant(get_class_static(), "", "DIFFICULTY_INTERMEDIATE", static_cast<int>(Difficulty::Intermediate));
    ClassDB::bind_integer_constant(get_class_static(), "", "DIFFICULTY_DIFFICULT", static_cast<int>(Difficulty::Difficult));
    ClassDB::bind_integer_constant(get_class_static(), "", "OUTCOME_RUNNING", static_cast<int>(Outcome::Running));
    ClassDB::bind_integer_constant(get_class_static(), "", "OUTCOME_SUCCESS", static_cast<int>(Outcome::Success));
    ClassDB::bind_integer_constant(get_class_static(), "", "OUTCOME_EVACUATED", static_cast<int>(Outcome::Evacuated));
    ClassDB::bind_integer_constant(get_class_static(), "", "OUTCOME_EVACUATED_WITH_LOSSES", static_cast<int>(Outcome::EvacuatedWithLosses));
    ClassDB::bind_integer_constant(get_class_static(), "", "OUTCOME_EXTINCT", static_cast<int>(Outcome::Extinct));
    ClassDB::bind_integer_constant(get_class_static(), "", "OUTCOME_TERRAFORMED", static_cast<int>(Outcome::Terraformed));
}

FarmBay::FarmBay() : bay_(1) {}
FarmBay::~FarmBay() {}

void FarmBay::check_link() {
    if (linked_id_ != 0 && !UtilityFunctions::is_instance_id_valid(linked_id_)) {      // the bay it fed was freed: feed nothing
        bay_.unlink_colony();
        linked_id_ = 0;
    }
}

void FarmBay::_process(double delta) {
    if (Engine::get_singleton()->is_editor_hint() || paused_ || time_scale_ <= 0.0) return;
    check_link();
    // at most six game hours a frame, so a long frame at a high speed cannot stall the game
    bay_.advance(std::min(delta * time_scale_, 6.0));
    emit_events();
}

void FarmBay::emit_events() {
    for (const aevoria::farm::Event &e : bay_.take_events()) {
        switch (e.type) {
            case EventType::StageChanged: emit_signal("plant_stage_changed", e.bed, e.slot, e.value); break;
            case EventType::PlantDied: emit_signal("plant_died", e.bed, e.slot); break;
            case EventType::DayChanged: emit_signal("day_changed", e.value); break;
            case EventType::ColonyOutcome: emit_signal("colony_outcome", e.value); break;
            case EventType::ColonyArrival: emit_signal("colony_arrival", e.value); break;
            case EventType::ColonyEstablished: emit_signal("colony_established"); break;
            case EventType::TerraformStage: emit_signal("terraform_stage", e.value); break;
        }
    }
}

void FarmBay::set_seed(int seed) {
    if (bay_.bed_count() > 0) {
        UtilityFunctions::push_warning("FarmBay.set_seed ignored: the bay already has beds");
        return;
    }
    seed_ = seed;
    bay_ = Bay(static_cast<std::uint64_t>(seed));
}
int FarmBay::get_seed() const { return seed_; }

int FarmBay::add_bed(int rows, int cols, double area_m2) { return bay_.add_bed(rows, cols, area_m2); }
int FarmBay::get_bed_count() const { return bay_.bed_count(); }

Dictionary FarmBay::get_bed_info(int bed) const {
    Dictionary d;
    if (bed < 0 || bed >= bay_.bed_count()) return d;
    const Bed &b = bay_.bed(bed);
    d["rows"] = b.rows;
    d["cols"] = b.cols;
    d["slots"] = b.slots();
    d["area_m2"] = b.area_m2;
    d["water_l"] = b.water_l;
    d["water_capacity_l"] = b.water_capacity_l;
    d["moisture"] = b.moisture();
    d["nutrient"] = b.nutrient;
    d["light_level"] = b.light_level;
    d["ppfd"] = bay_.bed_ppfd(bed);
    return d;
}

void FarmBay::set_bed_light_level(int bed, double level) {
    if (bed < 0 || bed >= bay_.bed_count()) return;
    bay_.bed(bed).light_level = std::clamp(level, 0.0, 1.0);
}

bool FarmBay::plant(int bed, int slot, const String &species_key) {
    const Species *sp = species_by_key(species_key);
    if (sp == nullptr) return false;
    const bool ok = bay_.plant(bed, slot, sp->id);
    if (ok) emit_signal("plant_stage_changed", bed, slot, static_cast<int>(Stage::Seed));
    return ok;
}

Dictionary FarmBay::harvest(int bed, int slot) {
    Dictionary d;
    const auto h = bay_.harvest(bed, slot);
    d["ok"] = h.has_value();
    if (h) {
        d["species"] = to_godot(aevoria::farm::kSpecies[static_cast<size_t>(h->species)].key);
        d["kg"] = h->kg;
        d["quality"] = h->quality;
        d["stage"] = static_cast<int>(h->stage);
    }
    return d;
}

bool FarmBay::remove(int bed, int slot) { return bay_.remove(bed, slot); }
double FarmBay::irrigate(int bed, double liters) { return bay_.irrigate(bed, liters); }
double FarmBay::feed(int bed, double units) { return bay_.feed(bed, units); }

Dictionary FarmBay::get_plant(int bed, int slot) const {
    Dictionary d;
    d["empty"] = true;
    if (!bay_.valid(bed, slot)) return d;
    const Plant &p = bay_.plant_at(bed, slot);
    const Species *sp = aevoria::farm::find_species(p.species);
    if (sp == nullptr) return d;
    d["empty"] = false;
    d["species"] = to_godot(sp->key);
    d["name"] = to_godot(sp->name);
    d["stage"] = static_cast<int>(p.stage);
    d["stage_name"] = get_stage_name(static_cast<int>(p.stage));
    d["progress"] = p.progress;
    d["health"] = p.health;
    d["quality"] = p.quality();
    d["age_days"] = p.age_hours / 24.0;
    d["ready"] = p.stage == Stage::Ready || p.stage == Stage::Overripe;
    d["visual_seed"] = static_cast<int64_t>(p.visual_seed);
    return d;
}

Array FarmBay::get_species_list() const {
    Array out;
    for (const Species &s : aevoria::farm::kSpecies) {
        Dictionary d;
        d["id"] = s.id;
        d["key"] = to_godot(s.key);
        d["name"] = to_godot(s.name);
        d["kind"] = kind_name(s.kind);
        d["days_to_mature"] = s.days_to_mature;
        d["ppfd_opt"] = s.ppfd_opt;
        d["ppfd_max"] = s.ppfd_max;
        d["temp_min"] = s.temp_min;
        d["temp_opt_low"] = s.temp_opt_low;
        d["temp_opt_high"] = s.temp_opt_high;
        d["temp_max"] = s.temp_max;
        d["water_use"] = s.water_use;
        d["yield_kg"] = s.yield_kg;
        d["flower_start"] = s.flower_start;
        d["fruit_start"] = s.fruit_start;
        d["kcal_per_kg"] = s.kcal_per_kg;
        out.push_back(d);
    }
    return out;
}

Dictionary FarmBay::get_status() const {
    const aevoria::farm::Settings &s = bay_.settings;
    Dictionary d;
    d["day"] = bay_.day;
    d["clock_h"] = bay_.clock_h;
    d["lights_on"] = bay_.lights_on();
    d["sun_ppfd"] = bay_.sun_ppfd();
    d["temp_c"] = bay_.temp_c();
    d["tank_l"] = bay_.tank_l;
    d["tank_capacity_l"] = bay_.tank_capacity_l;
    d["nutrient_stock"] = bay_.nutrient_stock;
    d["energy_kwh"] = bay_.energy_wh / 1000.0;
    d["water_lost_l"] = bay_.water_lost_l;
    d["harvested_kg"] = bay_.harvested_kg;
    Dictionary by_species;
    for (size_t i = 0; i < aevoria::farm::kSpecies.size(); ++i) by_species[to_godot(aevoria::farm::kSpecies[i].key)] = bay_.harvested_by_species[i];
    d["harvested_by_species"] = by_species;
    d["power_demand_w"] = bay_.power_demand_w();
    d["power_budget_w"] = s.power_budget_w;
    d["power_scale"] = bay_.power_scale();
    d["auto_irrigate"] = s.auto_irrigate;
    d["shade"] = s.shade;
    d["dust_tau"] = s.dust_tau;
    d["sun_peak_ppfd"] = s.sun_peak_ppfd;
    d["time_scale"] = time_scale_;
    d["paused"] = paused_;
    return d;
}

void FarmBay::set_setting(const String &key, const Variant &value) {
    aevoria::farm::Settings &s = bay_.settings;
    const double v = value.get_type() == Variant::BOOL ? (static_cast<bool>(value) ? 1.0 : 0.0) : static_cast<double>(value);
    if (key == "temp_c") s.temp_c = v;
    else if (key == "temp_swing_c") s.temp_swing_c = v;
    else if (key == "light_on_hour") s.light_on_hour = v;
    else if (key == "light_off_hour") s.light_off_hour = v;
    else if (key == "led_w_per_bed") s.led_w_per_bed = v;
    else if (key == "led_umol_per_joule") s.led_umol_per_joule = v;
    else if (key == "led_optical_efficiency") s.led_optical_efficiency = v;
    else if (key == "power_budget_w") s.power_budget_w = v;
    else if (key == "sun_peak_ppfd") s.sun_peak_ppfd = v;
    else if (key == "dust_tau") s.dust_tau = v;
    else if (key == "shade") s.shade = std::clamp(v, 0.0, 1.0);
    else if (key == "reclaim_fraction") s.reclaim_fraction = std::clamp(v, 0.0, 1.0);
    else if (key == "tank_resupply_l_day") s.tank_resupply_l_day = std::max(0.0, v);
    else if (key == "auto_irrigate") s.auto_irrigate = v != 0.0;
    else if (key == "tank_l") bay_.tank_l = std::clamp(v, 0.0, bay_.tank_capacity_l);
    else if (key == "tank_capacity_l") bay_.tank_capacity_l = std::max(0.0, v);
    else if (key == "nutrient_stock") bay_.nutrient_stock = std::max(0.0, v);
    else UtilityFunctions::push_warning("FarmBay.set_setting: unknown setting '", key, "'");
}

Variant FarmBay::get_setting(const String &key) const {
    const aevoria::farm::Settings &s = bay_.settings;
    if (key == "temp_c") return s.temp_c;
    if (key == "temp_swing_c") return s.temp_swing_c;
    if (key == "light_on_hour") return s.light_on_hour;
    if (key == "light_off_hour") return s.light_off_hour;
    if (key == "led_w_per_bed") return s.led_w_per_bed;
    if (key == "led_umol_per_joule") return s.led_umol_per_joule;
    if (key == "led_optical_efficiency") return s.led_optical_efficiency;
    if (key == "power_budget_w") return s.power_budget_w;
    if (key == "sun_peak_ppfd") return s.sun_peak_ppfd;
    if (key == "dust_tau") return s.dust_tau;
    if (key == "shade") return s.shade;
    if (key == "reclaim_fraction") return s.reclaim_fraction;
    if (key == "tank_resupply_l_day") return s.tank_resupply_l_day;
    if (key == "auto_irrigate") return s.auto_irrigate;
    if (key == "tank_l") return bay_.tank_l;
    if (key == "tank_capacity_l") return bay_.tank_capacity_l;
    if (key == "nutrient_stock") return bay_.nutrient_stock;
    return Variant();
}

void FarmBay::start_colony(int difficulty, double demand_scale, double reserve_scale) {
    bay_.start_colony(difficulty_from(difficulty), demand_scale, reserve_scale);
}

void FarmBay::stop_colony() { bay_.stop_colony(); }

void FarmBay::setup_settlement(int max_units, bool terraforming, int open_air_bonus) { bay_.setup_settlement(std::clamp(max_units, 1, 16), terraforming, std::max(0, open_air_bonus)); }

void FarmBay::link_colony(FarmBay *primary) {
    if (primary == nullptr || primary == this) {
        unlink_colony();
        return;
    }
    bay_.link_colony(primary->bay_);
    linked_id_ = static_cast<int64_t>(primary->get_instance_id());
}

void FarmBay::unlink_colony() {
    bay_.unlink_colony();
    linked_id_ = 0;
}

bool FarmBay::colony_add_unit() { return bay_.active_colony().add_unit(); }
void FarmBay::set_colony_growth(bool on) { bay_.active_colony().set_growth(on); }

void FarmBay::colony_finish_established() {
    const Outcome o = bay_.active_colony().finish_established();
    if (o != Outcome::Running) emit_signal("colony_outcome", static_cast<int>(o));
}

Dictionary FarmBay::get_terraform() const {
    const aevoria::farm::Terraform &t = bay_.colony_linked() ? const_cast<aevoria::farm::Bay &>(bay_).active_terraform() : bay_.terraform;
    Dictionary d;
    d["enabled"] = t.enabled();
    d["progress"] = t.progress();
    d["stage"] = t.stage();
    d["complete"] = t.complete();
    d["leaf_area"] = t.leaf_area_m2();
    d["equilibrium"] = t.equilibrium();
    d["best_stage"] = t.best_stage();
    Array stages;
    for (double v : aevoria::farm::kTerraformStages) stages.push_back(v);
    d["stages"] = stages;
    return d;
}

Dictionary FarmBay::get_expansion_rules() {
    Dictionary d;
    d["plenty_reserve_days"] = aevoria::farm::kPlentyReserveDays;
    d["growth_interval_days"] = aevoria::farm::kGrowthIntervalDays;
    d["housing_factor"] = aevoria::farm::kHousingFactor;
    d["max_units"] = aevoria::farm::kMaxUnits;
    d["expand_min_reserve_days"] = aevoria::farm::kExpandMinReserveDays;
    d["expand_min_harvest_days"] = aevoria::farm::kExpandMinHarvestDays;
    d["expansion_cost_days"] = aevoria::farm::kExpansionCostDays;
    d["surplus_factor"] = aevoria::farm::kSurplusFactor;
    d["surplus_window_days"] = aevoria::farm::kSurplusWindowDays;
    d["plenty_min_age_days"] = aevoria::farm::kPlentyMinAgeDays;
    return d;
}

Dictionary FarmBay::get_difficulty_rules(int difficulty) {
    const aevoria::farm::ColonyRules &r = aevoria::farm::colony_rules(difficulty_from(difficulty));
    Dictionary d;
    d["difficulty"] = std::clamp(difficulty, 0, 2);
    d["name"] = String(r.name);
    d["crew"] = r.crew;
    d["need_kcal_day"] = r.need_kcal_day;
    d["start_reserve_days"] = r.start_reserve_days;
    d["grace_days"] = r.grace_days;
    d["goal_days"] = r.goal_days;
    d["evacuation_share"] = r.evacuation_share;
    d["score_multiplier"] = r.score_multiplier;
    return d;
}

Dictionary FarmBay::get_colony() const {
    const aevoria::farm::Colony &c = bay_.colony;
    Dictionary d;
    d["started"] = c.started();
    d["running"] = c.running();
    d["outcome"] = static_cast<int>(c.outcome());
    d["outcome_name"] = String(outcome_name(c.outcome()));
    if (!c.started()) return d;
    const aevoria::farm::ColonyRules &r = c.rules();
    d["difficulty"] = static_cast<int>(c.difficulty());
    d["difficulty_name"] = String(r.name);
    d["crew"] = r.crew;
    d["population"] = c.population();
    d["housing"] = c.housing();
    d["units"] = c.units();
    d["max_units"] = c.max_units();
    d["plenty"] = c.plenty();
    d["surplus_ratio"] = c.surplus_ratio();
    d["crowded"] = c.crowded();
    d["expansion_ready"] = c.expansion_ready();
    d["growth_progress"] = c.growth_progress();
    d["growth_enabled"] = c.growth_enabled();
    d["arrivals_total"] = c.arrivals_total();
    d["established"] = c.established();
    d["survivors"] = c.survivors();
    d["day"] = c.day();
    d["goal_days"] = r.goal_days;
    d["grace_days"] = r.grace_days;
    d["need_kcal_day"] = c.need_kcal_day();
    d["stock_kcal"] = c.stock_kcal();
    d["reserve_days"] = c.reserve_days();
    d["starving"] = c.starving();
    d["hunger_days"] = c.hunger_days();
    d["hungry_days_total"] = c.hungry_days_total();
    d["harvested_kcal"] = c.harvested_kcal();
    d["eaten_kcal"] = c.eaten_kcal();
    d["crops_grown"] = c.crops_grown();
    d["plants_lost"] = c.plants_lost();
    const aevoria::farm::ScoreBreakdown b = c.score();
    Dictionary parts;
    parts["days"] = b.days;
    parts["food"] = b.food;
    parts["variety"] = b.variety;
    parts["reserve"] = b.reserve;
    parts["lost"] = b.lost;
    parts["hunger"] = b.hunger;
    parts["growth"] = b.growth;
    parts["expansion"] = b.expansion;
    parts["bonus"] = b.bonus;
    parts["multiplier"] = b.multiplier;
    parts["total"] = static_cast<int64_t>(b.total);
    d["score"] = static_cast<int64_t>(b.total);
    d["score_parts"] = parts;
    return d;
}

void FarmBay::advance_hours(double hours) {
    check_link();
    bay_.advance(hours);
    emit_events();
}

void FarmBay::set_time_scale(double hours_per_second) { time_scale_ = std::max(0.0, hours_per_second); }
double FarmBay::get_time_scale() const { return time_scale_; }
void FarmBay::set_paused(bool paused) { paused_ = paused; }
bool FarmBay::is_paused() const { return paused_; }

String FarmBay::get_stage_name(int stage) {
    switch (static_cast<Stage>(stage)) {
        case Stage::Empty: return "Empty";
        case Stage::Seed: return "Seed";
        case Stage::Sprout: return "Sprout";
        case Stage::Vegetative: return "Growing";
        case Stage::Flowering: return "Flowering";
        case Stage::Fruiting: return "Fruiting";
        case Stage::Ready: return "Ready";
        case Stage::Overripe: return "Overripe";
        case Stage::Dead: return "Dead";
    }
    return "Unknown";
}

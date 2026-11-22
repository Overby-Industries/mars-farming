#include "farm_shape_builder.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cstdint>
#include <string_view>

#include "farm_skin_generator.h"
#include "mesh_builder.h"
#include "plant.hpp"
#include "plant_meshes.h"
#include "species.hpp"

using namespace godot;
using farm::MeshBuilder;
using farm::Vtx;

namespace {

float num(const Dictionary &d, const char *key, double fallback) {
    return static_cast<float>(static_cast<double>(d.get(key, fallback)));
}

// The Mars palette: dusty white, rust orange, basalt (the counterparts of Aevoria's cloud white, gold and midnight).
const Color kDust(0.929f, 0.902f, 0.863f);
const Color kRust(0.773f, 0.376f, 0.180f);
const Color kBasalt(0.180f, 0.157f, 0.145f);
const Color kSteel(0.55f, 0.58f, 0.64f);

Ref<StandardMaterial3D> vertex_color_material(float roughness, float metallic) {
    Ref<StandardMaterial3D> m;
    m.instantiate();
    m->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    m->set_cull_mode(BaseMaterial3D::CULL_DISABLED);   // leaves are single-sided; winding is handled by MeshBuilder
    m->set_roughness(roughness);
    m->set_metallic(metallic);
    return m;
}

Ref<StandardMaterial3D> recipe_material(const Dictionary &r) {
    Ref<StandardMaterial3D> m;
    m.instantiate();
    m->set_albedo(r.get("albedo_color", Color(0.8f, 0.8f, 0.8f)));
    m->set_roughness(num(r, "roughness", 0.7));
    m->set_metallic(num(r, "metallic", 0.0));
    if (r.has("emission_color")) {
        m->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
        m->set_emission(r.get("emission_color", Color(1, 1, 1)));
        m->set_emission_energy_multiplier(num(r, "emission_energy", 1.0));
    }
    return m;
}

MeshInstance3D *instance_of(const Ref<Mesh> &mesh, const String &name) {
    MeshInstance3D *mi = memnew(MeshInstance3D);
    mi->set_mesh(mesh);
    mi->set_name(name);
    return mi;
}

Ref<ImageTexture> skin_texture(const Variant &recipe_variant, int size) {
    Ref<FarmSkinGenerator> gen;
    gen.instantiate();
    const Dictionary skin = recipe_variant;
    return gen->generate_texture(skin, size, size);
}

struct Planter {
    float length, height, width, wall, soil_y;
    int rows, cols;
};

Planter planter_of(const Dictionary &r) {
    const Vector3 size = r.get("size", Vector3(1.2f, 0.22f, 0.6f));
    Planter p;
    p.length = size.x;
    p.height = size.y;
    p.width = size.z;
    p.wall = num(r, "wall", 0.03);
    p.soil_y = p.height - 0.05f;
    p.rows = std::max(1, static_cast<int>(r.get("rows", 2)));
    p.cols = std::max(1, static_cast<int>(r.get("cols", 4)));
    return p;
}

Node3D *build_planter(const Dictionary &r) {
    const Planter p = planter_of(r);
    const Color body = r.get("albedo_color", kDust);
    const Color rust = r.get("accent_color", kRust);
    const Color base = r.get("base_color", kBasalt);
    const Color soil = r.get("soil_color", Color(0.17f, 0.13f, 0.09f));
    const float L = p.length, H = p.height, W = p.width, t = p.wall;

    MeshBuilder mb;
    mb.add_surface(vertex_color_material(0.5f, 0.1f));
    mb.box(Vector3(0, 0.01f, 0), Vector3(L, 0.02f, W), base);                                     // floor slab
    mb.box(Vector3(0, H * 0.5f, W * 0.5f - t * 0.5f), Vector3(L, H, t), body);                    // long walls
    mb.box(Vector3(0, H * 0.5f, -W * 0.5f + t * 0.5f), Vector3(L, H, t), body);
    mb.box(Vector3(L * 0.5f - t * 0.5f, H * 0.5f, 0), Vector3(t, H, W - 2.0f * t), body);         // end walls
    mb.box(Vector3(-L * 0.5f + t * 0.5f, H * 0.5f, 0), Vector3(t, H, W - 2.0f * t), body);
    // the rust rim: a slightly wider lip around the top edge
    const float lip = 0.016f, over = 0.012f;
    mb.box(Vector3(0, H - lip * 0.5f, W * 0.5f - t * 0.5f + over * 0.5f), Vector3(L + 2.0f * over, lip, t + over), rust);
    mb.box(Vector3(0, H - lip * 0.5f, -W * 0.5f + t * 0.5f - over * 0.5f), Vector3(L + 2.0f * over, lip, t + over), rust);
    mb.box(Vector3(L * 0.5f - t * 0.5f + over * 0.5f, H - lip * 0.5f, 0), Vector3(t + over, lip, W - 2.0f * t), rust);
    mb.box(Vector3(-L * 0.5f + t * 0.5f - over * 0.5f, H - lip * 0.5f, 0), Vector3(t + over, lip, W - 2.0f * t), rust);
    // a drain stub and a rust band on the +x end
    mb.frustum(Vector3(L * 0.5f, 0.06f, 0), Vector3(1, 0, 0), 0.04f, 0.016f, 0.016f, 10, kSteel, kSteel);
    mb.box(Vector3(L * 0.5f + 0.0005f, H * 0.5f, 0), Vector3(0.002f, 0.03f, W * 0.7f), rust);

    // the soil: one surface with UVs so a "soil" skin can be painted on
    Ref<StandardMaterial3D> soil_mat;
    soil_mat.instantiate();
    soil_mat->set_albedo(soil);
    soil_mat->set_roughness(1.0f);
    if (r.has("soil_skin")) {
        soil_mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, skin_texture(r["soil_skin"], 256));
        soil_mat->set_albedo(Color(1, 1, 1));
    }
    mb.add_surface(soil_mat);
    const float x0 = -L * 0.5f + t, x1 = L * 0.5f - t, z0 = -W * 0.5f + t, z1 = W * 0.5f - t, y = p.soil_y;
    const Vector3 up(0, 1, 0);
    const Vtx a{Vector3(x0, y, z0), up, Color(1, 1, 1), Vector2(0, 0)}, b{Vector3(x1, y, z0), up, Color(1, 1, 1), Vector2(1, 0)};
    const Vtx c{Vector3(x1, y, z1), up, Color(1, 1, 1), Vector2(1, 1)}, d{Vector3(x0, y, z1), up, Color(1, 1, 1), Vector2(0, 1)};
    mb.tri(a, b, c);
    mb.tri(a, c, d);

    Node3D *root = memnew(Node3D);
    root->add_child(instance_of(mb.build(), "Tray"));
    return root;
}

Node3D *build_grow_light(const Dictionary &r) {
    const float L = num(r, "length", 1.2);
    const Color body = r.get("albedo_color", kDust);
    const Color rust = r.get("accent_color", kRust);

    MeshBuilder mb;
    mb.add_surface(vertex_color_material(0.4f, 0.2f));
    mb.box(Vector3(0, -0.025f, 0), Vector3(L, 0.05f, 0.11f), body);                               // housing
    mb.box(Vector3(L * 0.5f + 0.005f, -0.025f, 0), Vector3(0.01f, 0.056f, 0.118f), rust);         // end caps
    mb.box(Vector3(-L * 0.5f - 0.005f, -0.025f, 0), Vector3(0.01f, 0.056f, 0.118f), rust);
    for (int i = -1; i <= 1; i += 2) {                                                            // two hangers
        mb.frustum(Vector3(static_cast<float>(i) * L * 0.33f, 0, 0), Vector3(0, 1, 0), 0.12f, 0.004f, 0.004f, 8, kSteel, kSteel);
    }

    Ref<StandardMaterial3D> led;
    led.instantiate();
    led->set_albedo(Color(0.10f, 0.05f, 0.08f));
    led->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
    led->set_emission(r.get("emission_color", Color(1.0f, 0.60f, 0.86f)));
    led->set_emission_energy_multiplier(num(r, "emission_energy", 2.5));
    mb.add_surface(led);
    mb.box(Vector3(0, -0.0515f, 0), Vector3(L - 0.04f, 0.003f, 0.085f), Color(1, 1, 1));          // the LED strip

    Node3D *root = memnew(Node3D);
    root->add_child(instance_of(mb.build(), "Light"));
    root->set_meta("led_material", led);
    return root;
}

Node3D *build_tank(const Dictionary &r) {
    const float R = num(r, "radius", 0.35);
    const float H = num(r, "height", 0.9);
    const float dome = std::min(R, num(r, "dome", 0.12) * H);
    const Color body = r.get("albedo_color", kDust);
    const Color rust = r.get("accent_color", kRust);

    MeshBuilder mb;
    mb.add_surface(vertex_color_material(0.35f, 0.25f));
    mb.frustum(Vector3(0, dome, 0), Vector3(0, 1, 0), H - 2.0f * dome, R, R, 28, body, body, false, false);
    mb.ellipsoid(Vector3(0, H - dome, 0), Vector3(R, dome, R), 28, 8, body, body);
    mb.ellipsoid(Vector3(0, dome, 0), Vector3(R, dome, R), 28, 8, body, body);
    for (const float f : {0.22f, 0.78f}) {                                                        // two rust bands
        mb.frustum(Vector3(0, H * f, 0), Vector3(0, 1, 0), 0.035f, R + 0.006f, R + 0.006f, 28, rust, rust);
    }
    for (int i = 0; i < 3; ++i) {                                                                 // three legs
        const float a = 6.28318f * static_cast<float>(i) / 3.0f;
        mb.box(Vector3(std::cos(a) * R * 0.7f, 0.04f, std::sin(a) * R * 0.7f), Vector3(0.05f, 0.08f, 0.05f), kSteel);
    }

    Ref<StandardMaterial3D> glass;
    glass.instantiate();
    glass->set_albedo(Color(0.1f, 0.3f, 0.4f));
    glass->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
    glass->set_emission(Color(0.35f, 0.85f, 0.95f));
    glass->set_emission_energy_multiplier(1.4f);
    mb.add_surface(glass);
    mb.box(Vector3(0, H * 0.5f, R + 0.003f), Vector3(0.06f, H * 0.5f, 0.006f), Color(1, 1, 1));   // the level gauge

    Node3D *root = memnew(Node3D);
    root->add_child(instance_of(mb.build(), "Tank"));
    return root;
}

Node3D *build_plant_node(const Dictionary &r) {
    const String key = r.get("species", "lettuce");
    const CharString utf8 = key.utf8();
    const aevoria::farm::Species *sp = aevoria::farm::find_species(std::string_view(utf8.get_data()));
    Node3D *root = memnew(Node3D);
    if (sp == nullptr) {
        UtilityFunctions::push_warning("FarmShapeBuilder: unknown species '", key, "'");
        return root;
    }
    farm::PlantLook look;
    look.species = sp->id;
    look.progress = num(r, "progress", 1.0);
    look.stage = static_cast<int>(r.get("stage", static_cast<int>(aevoria::farm::Stage::Ready)));
    look.health = num(r, "health", 1.0);
    look.seed = static_cast<std::uint32_t>(static_cast<int64_t>(r.get("seed", 1)));
    look.scale = num(r, "scale", 1.0);

    farm::MeshBuilder mb;
    mb.add_surface(vertex_color_material(0.8f, 0.0f));
    farm::build_plant(mb, look);
    root->add_child(instance_of(mb.build(), "Plant"));
    root->set_meta("triangles", static_cast<int64_t>(mb.triangle_count()));
    return root;
}

}  // namespace

void FarmShapeBuilder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("build_node", "recipe"), &FarmShapeBuilder::build_node);
    ClassDB::bind_method(D_METHOD("get_slot_positions", "recipe"), &FarmShapeBuilder::get_slot_positions);
    ClassDB::bind_method(D_METHOD("get_shape_names"), &FarmShapeBuilder::get_shape_names);
}

FarmShapeBuilder::FarmShapeBuilder() {}
FarmShapeBuilder::~FarmShapeBuilder() {}

PackedStringArray FarmShapeBuilder::get_shape_names() const {
    PackedStringArray names;
    for (const char *n : {"box", "cylinder", "capsule", "sphere", "planter_tray", "grow_light", "tank", "plant"}) names.push_back(n);
    return names;
}

PackedVector3Array FarmShapeBuilder::get_slot_positions(const Dictionary &recipe) {
    PackedVector3Array out;
    const Planter p = planter_of(recipe);
    const float inner_l = p.length - 2.0f * p.wall, inner_w = p.width - 2.0f * p.wall;
    for (int j = 0; j < p.rows; ++j) {          // row-major, matching the simulation's slot index (row * cols + col)
        for (int i = 0; i < p.cols; ++i) {
            out.push_back(Vector3(-inner_l * 0.5f + (static_cast<float>(i) + 0.5f) * inner_l / static_cast<float>(p.cols), p.soil_y,
                                  -inner_w * 0.5f + (static_cast<float>(j) + 0.5f) * inner_w / static_cast<float>(p.rows)));
        }
    }
    return out;
}

Node3D *FarmShapeBuilder::build_node(const Dictionary &recipe) {
    const String shape = recipe.get("shape", "box");
    const String name = recipe.get("name", shape);

    // The imported-model seam: a hand-modelled asset replaces the procedural shape, and nothing else changes.
    if (recipe.has("model")) {
        const String path = recipe["model"];
        if (!path.is_empty() && ResourceLoader::get_singleton()->exists(path)) {
            Ref<PackedScene> scene = ResourceLoader::get_singleton()->load(path);
            if (scene.is_valid()) {
                Node3D *imported = Object::cast_to<Node3D>(scene->instantiate());
                if (imported != nullptr) {
                    imported->set_name(name);
                    if (recipe.has("model_scale")) imported->set_scale(recipe["model_scale"]);
                    return imported;
                }
            }
        }
    }

    Node3D *root = nullptr;
    if (shape == "box") {
        Ref<BoxMesh> m;
        m.instantiate();
        m->set_size(recipe.get("size", Vector3(1, 1, 1)));
        m->set_material(recipe_material(recipe));
        root = memnew(Node3D);
        root->add_child(instance_of(m, "Mesh"));
    } else if (shape == "cylinder") {
        Ref<CylinderMesh> m;
        m.instantiate();
        const float radius = num(recipe, "radius", 0.5);
        m->set_top_radius(radius);
        m->set_bottom_radius(radius);
        m->set_height(num(recipe, "height", 1.0));
        m->set_material(recipe_material(recipe));
        root = memnew(Node3D);
        root->add_child(instance_of(m, "Mesh"));
    } else if (shape == "capsule") {
        Ref<CapsuleMesh> m;
        m.instantiate();
        m->set_radius(num(recipe, "radius", 0.5));
        m->set_height(num(recipe, "height", 1.0));
        m->set_material(recipe_material(recipe));
        root = memnew(Node3D);
        root->add_child(instance_of(m, "Mesh"));
    } else if (shape == "sphere") {
        Ref<SphereMesh> m;
        m.instantiate();
        const float radius = num(recipe, "radius", 0.5);
        m->set_radius(radius);
        m->set_height(radius * 2.0f);
        m->set_radial_segments(static_cast<int>(recipe.get("radial_segments", 16)));
        m->set_rings(static_cast<int>(recipe.get("rings", 8)));
        m->set_material(recipe_material(recipe));
        root = memnew(Node3D);
        root->add_child(instance_of(m, "Mesh"));
    } else if (shape == "planter_tray") {
        root = build_planter(recipe);
    } else if (shape == "grow_light") {
        root = build_grow_light(recipe);
    } else if (shape == "tank") {
        root = build_tank(recipe);
    } else if (shape == "plant") {
        root = build_plant_node(recipe);
    } else {
        UtilityFunctions::push_warning("FarmShapeBuilder: unknown shape '", shape, "'");
        root = memnew(Node3D);
    }
    root->set_name(name);
    return root;
}

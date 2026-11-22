#pragma once

// MeshBuilder: collects triangles (with colour, normal and UV per vertex) into one or more
// surfaces and turns them into an ArrayMesh. Every procedural shape in this extension is
// built with it, the way Aevoria's PartDefinition uses SurfaceTool for shapes the built-in
// primitives cannot make.
//
// Winding: Godot treats clockwise triangles as front faces, and a back face gets its normal
// flipped even when culling is off, which would light a shape inside out. tri() therefore
// looks at the normals it was given and orients each triangle clockwise as seen from the
// side the normals point to, so callers never have to think about vertex order.

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <utility>
#include <vector>

namespace farm {

using godot::Color;
using godot::Vector2;
using godot::Vector3;

struct Vtx {
    Vector3 p;
    Vector3 n;
    Color c;
    Vector2 uv;
};

inline Color mix(const Color &a, const Color &b, float t) {
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    return Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
}

inline float smooth(float edge0, float edge1, float x) {
    if (edge1 <= edge0) return x >= edge1 ? 1.0f : 0.0f;
    float t = (x - edge0) / (edge1 - edge0);
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    return t * t * (3.0f - 2.0f * t);
}

class MeshBuilder {
public:
    // Start a new surface; later calls draw into it. The material is optional.
    int add_surface(const godot::Ref<godot::Material> &material = godot::Ref<godot::Material>()) {
        surfaces_.emplace_back();
        surfaces_.back().material = material;
        current_ = static_cast<int>(surfaces_.size()) - 1;
        return current_;
    }
    void use_surface(int index) { current_ = index; }

    // ---- the one primitive everything reduces to ------------------------------------------------
    void tri(Vtx a, Vtx b, Vtx c) {
        ensure_surface();
        const Vector3 gn = (b.p - a.p).cross(c.p - a.p);
        if (gn.length_squared() < 1e-14f) return;                 // degenerate
        if (gn.dot(a.n + b.n + c.n) > 0.0f) std::swap(b, c);      // counter-clockwise from the normal side: flip
        std::vector<Vtx> &v = surfaces_[static_cast<size_t>(current_)].v;
        v.push_back(a);
        v.push_back(b);
        v.push_back(c);
    }

    // A quad a-b-c-d (in order around its edge), lit with one explicit normal.
    void quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d, const Vector3 &n, const Color &col) {
        const Vtx va{a, n, col, Vector2(0, 0)}, vb{b, n, col, Vector2(1, 0)}, vc{c, n, col, Vector2(1, 1)}, vd{d, n, col, Vector2(0, 1)};
        tri(va, vb, vc);
        tri(va, vc, vd);
    }

    // The same with a colour per corner and per-corner normals (for smooth, curved faces).
    void quad_smooth(const Vtx &a, const Vtx &b, const Vtx &c, const Vtx &d) {
        tri(a, b, c);
        tri(a, c, d);
    }

    // ---- shapes ---------------------------------------------------------------------------------
    void box(const Vector3 &center, const Vector3 &size, const Color &col) {
        const Vector3 h = size * 0.5f;
        const Vector3 c = center;
        const Vector3 p000 = c + Vector3(-h.x, -h.y, -h.z), p100 = c + Vector3(h.x, -h.y, -h.z);
        const Vector3 p110 = c + Vector3(h.x, h.y, -h.z), p010 = c + Vector3(-h.x, h.y, -h.z);
        const Vector3 p001 = c + Vector3(-h.x, -h.y, h.z), p101 = c + Vector3(h.x, -h.y, h.z);
        const Vector3 p111 = c + Vector3(h.x, h.y, h.z), p011 = c + Vector3(-h.x, h.y, h.z);
        quad(p001, p101, p111, p011, Vector3(0, 0, 1), col);    // +z
        quad(p100, p000, p010, p110, Vector3(0, 0, -1), col);   // -z
        quad(p101, p100, p110, p111, Vector3(1, 0, 0), col);    // +x
        quad(p000, p001, p011, p010, Vector3(-1, 0, 0), col);   // -x
        quad(p011, p111, p110, p010, Vector3(0, 1, 0), col);    // +y
        quad(p000, p100, p101, p001, Vector3(0, -1, 0), col);   // -y
    }

    // A frustum (cylinder when r0 == r1) from `base` along unit vector `axis`, with a colour at each end.
    void frustum(const Vector3 &base, const Vector3 &axis, float length, float r0, float r1, int segs, const Color &c0,
                 const Color &c1, bool cap0 = true, bool cap1 = true) {
        Vector3 u, w;
        basis_for(axis, u, w);
        const float slope = (r0 - r1) / (length > 1e-6f ? length : 1e-6f);   // how far the wall leans outward per metre
        const Vector3 top = base + axis * length;
        for (int i = 0; i < segs; ++i) {
            const float a0 = 6.28318530718f * static_cast<float>(i) / static_cast<float>(segs);
            const float a1 = 6.28318530718f * static_cast<float>(i + 1) / static_cast<float>(segs);
            const Vector3 d0 = u * std::cos(a0) + w * std::sin(a0), d1 = u * std::cos(a1) + w * std::sin(a1);
            const Vector3 n0 = (d0 + axis * slope).normalized(), n1 = (d1 + axis * slope).normalized();
            const Vtx b0{base + d0 * r0, n0, c0, Vector2(0, 0)}, b1{base + d1 * r0, n1, c0, Vector2(1, 0)};
            const Vtx t0{top + d0 * r1, n0, c1, Vector2(0, 1)}, t1{top + d1 * r1, n1, c1, Vector2(1, 1)};
            quad_smooth(b0, b1, t1, t0);
            if (cap0 && r0 > 1e-6f) tri({base, -axis, c0, Vector2()}, {base + d1 * r0, -axis, c0, Vector2()}, {base + d0 * r0, -axis, c0, Vector2()});
            if (cap1 && r1 > 1e-6f) tri({top, axis, c1, Vector2()}, {top + d0 * r1, axis, c1, Vector2()}, {top + d1 * r1, axis, c1, Vector2()});
        }
    }

    // A rod between two points.
    void rod(const Vector3 &a, const Vector3 &b, float ra, float rb, int segs, const Color &ca, const Color &cb, bool caps = false) {
        const Vector3 d = b - a;
        const float len = d.length();
        if (len < 1e-6f) return;
        frustum(a, d / len, len, ra, rb, segs, ca, cb, caps, caps);
    }

    // An ellipsoid with a colour that blends from `bottom` to `top`.
    void ellipsoid(const Vector3 &center, const Vector3 &radii, int lon, int lat, const Color &top, const Color &bottom) {
        for (int j = 0; j < lat; ++j) {
            const float v0 = 3.14159265359f * static_cast<float>(j) / static_cast<float>(lat);
            const float v1 = 3.14159265359f * static_cast<float>(j + 1) / static_cast<float>(lat);
            for (int i = 0; i < lon; ++i) {
                const float a0 = 6.28318530718f * static_cast<float>(i) / static_cast<float>(lon);
                const float a1 = 6.28318530718f * static_cast<float>(i + 1) / static_cast<float>(lon);
                const Vtx p00 = sphere_vtx(center, radii, v0, a0, top, bottom), p01 = sphere_vtx(center, radii, v0, a1, top, bottom);
                const Vtx p10 = sphere_vtx(center, radii, v1, a0, top, bottom), p11 = sphere_vtx(center, radii, v1, a1, top, bottom);
                tri(p00, p10, p11);
                if (j > 0) tri(p00, p11, p01);
            }
        }
    }

    // A leaf: a strip along a gentle curve, widest past the middle, folded along the midrib. Drawn single-sided
    // (the material has culling off). `pitch` is the angle above horizontal in radians, `droop` bends the tip down.
    void leaf(const Vector3 &base, float yaw, float pitch, float length, float width, float droop, float fold, const Color &c0,
              const Color &c1, int segs = 5) {
        const Vector3 dir(std::cos(yaw), 0.0f, std::sin(yaw));
        const Vector3 side(-std::sin(yaw), 0.0f, std::cos(yaw));
        const Vector3 up(0, 1, 0);
        auto center_at = [&](float t) {
            const float x = length * t * std::cos(pitch);
            const float y = length * (t * std::sin(pitch) - 0.5f * droop * t * t);
            return base + dir * x + up * y;
        };
        auto half_width = [&](float t) { return width * 0.5f * std::sin(3.14159265359f * std::pow(t, 1.3f)); };

        std::vector<Vtx> left, mid, right;
        for (int i = 0; i <= segs; ++i) {
            const float t = static_cast<float>(i) / static_cast<float>(segs);
            const float t2 = t + 0.01f < 1.0f ? t + 0.01f : 1.0f, t1 = t2 - 0.01f;
            const Vector3 tangent = (center_at(t2) - center_at(t1)).normalized();
            Vector3 n = side.cross(tangent).normalized();
            if (n.y < 0.0f) n = -n;
            const Vector3 p = center_at(t);
            const float w = half_width(t);
            const Color col = mix(c0, c1, t);
            const Color rib = mix(col, Color(1, 1, 1), 0.12f);
            left.push_back({p - side * w + up * (fold * w), (n - side * fold).normalized(), col, Vector2(0.0f, t)});
            mid.push_back({p, n, rib, Vector2(0.5f, t)});
            right.push_back({p + side * w + up * (fold * w), (n + side * fold).normalized(), col, Vector2(1.0f, t)});
        }
        for (int i = 0; i < segs; ++i) {
            const size_t s = static_cast<size_t>(i);
            quad_smooth(left[s], mid[s], mid[s + 1], left[s + 1]);
            quad_smooth(mid[s], right[s], right[s + 1], mid[s + 1]);
        }
    }

    // ---- result -----------------------------------------------------------------------------------
    godot::Ref<godot::ArrayMesh> build() const {
        godot::Ref<godot::ArrayMesh> mesh;
        mesh.instantiate();
        for (const Surface &s : surfaces_) {
            if (s.v.empty()) continue;
            const int64_t n = static_cast<int64_t>(s.v.size());
            godot::PackedVector3Array pos, nrm;
            godot::PackedColorArray col;
            godot::PackedVector2Array uv;
            pos.resize(n);
            nrm.resize(n);
            col.resize(n);
            uv.resize(n);
            Vector3 *pw = pos.ptrw();
            Vector3 *nw = nrm.ptrw();
            Color *cw = col.ptrw();
            Vector2 *uw = uv.ptrw();
            for (int64_t i = 0; i < n; ++i) {
                const Vtx &v = s.v[static_cast<size_t>(i)];
                pw[i] = v.p;
                nw[i] = v.n;
                cw[i] = v.c;
                uw[i] = v.uv;
            }
            godot::Array arrays;
            arrays.resize(godot::Mesh::ARRAY_MAX);
            arrays[godot::Mesh::ARRAY_VERTEX] = pos;
            arrays[godot::Mesh::ARRAY_NORMAL] = nrm;
            arrays[godot::Mesh::ARRAY_COLOR] = col;
            arrays[godot::Mesh::ARRAY_TEX_UV] = uv;
            mesh->add_surface_from_arrays(godot::Mesh::PRIMITIVE_TRIANGLES, arrays);
            if (s.material.is_valid()) mesh->surface_set_material(mesh->get_surface_count() - 1, s.material);
        }
        return mesh;
    }

    size_t triangle_count() const {
        size_t n = 0;
        for (const Surface &s : surfaces_) n += s.v.size() / 3;
        return n;
    }

private:
    struct Surface {
        std::vector<Vtx> v;
        godot::Ref<godot::Material> material;
    };
    std::vector<Surface> surfaces_;
    int current_ = -1;

    void ensure_surface() {
        if (current_ < 0) add_surface();
    }

    // Two unit vectors perpendicular to `axis` and to each other.
    static void basis_for(const Vector3 &axis, Vector3 &u, Vector3 &w) {
        const Vector3 ref = std::fabs(axis.y) < 0.9f ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
        u = axis.cross(ref).normalized();
        w = axis.cross(u).normalized();
    }

    static Vtx sphere_vtx(const Vector3 &center, const Vector3 &radii, float v, float a, const Color &top, const Color &bottom) {
        const float sv = std::sin(v), cv = std::cos(v);
        const Vector3 unit(sv * std::cos(a), cv, sv * std::sin(a));
        const Vector3 p = center + Vector3(unit.x * radii.x, unit.y * radii.y, unit.z * radii.z);
        const Vector3 n = Vector3(unit.x / radii.x, unit.y / radii.y, unit.z / radii.z).normalized();
        return {p, n, mix(top, bottom, 0.5f - 0.5f * cv), Vector2(a / 6.28318530718f, v / 3.14159265359f)};
    }
};

}  // namespace farm

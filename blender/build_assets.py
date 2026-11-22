"""Blender-modelled props for Mars Farming, exported as glTF binaries.

    blender -b --factory-startup --python blender/build_assets.py -- godot/models [asset ...]

regolith_bed, led_bar and ice_tank match the procedural shapes of FarmShapeBuilder ("planter_tray", "grow_light",
"tank"): same size, same origin, so a recipe's "model" key can replace one with nothing else changing. supply_crate
and airlock are extra props. Everything is real metres.

Coordinates: the geometry below is written in GODOT space (x right, y up, z toward the viewer) and G() converts to
Blender space, so that the glTF exporter's Y-up conversion (Blender x, y, z -> glTF x, z, -y) lands each point back
on the same Godot coordinates. Materials are plain Principled BSDF colours, no textures. The Mars palette: dusty
white, rust orange, basalt, regolith."""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(ARGS[0] if ARGS else "models")
WANT = ARGS[1:]
os.makedirs(OUT, exist_ok=True)


def G(x, y, z):
    """Godot-space point -> Blender-space point."""
    return Vector((x, -z, y))


def srgb(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    f = lambda v: v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return (f(c[0]), f(c[1]), f(c[2]), 1.0)


MATERIALS = {
    # name: (hex, metallic, roughness, emission hex or None, emission strength)
    "Body_White": ("#EDE6DC", 0.15, 0.55, None, 0.0),
    "Body_Dim": ("#CFC5B8", 0.15, 0.6, None, 0.0),
    "Trim_Rust": ("#C5602E", 0.5, 0.5, None, 0.0),
    "Base_Basalt": ("#2E2825", 0.3, 0.6, None, 0.0),
    "Steel": ("#8A93A8", 0.85, 0.35, None, 0.0),
    "Dark_Panel": ("#1B1715", 0.3, 0.65, None, 0.0),
    "Soil_Regolith": ("#6E3B22", 0.0, 1.0, None, 0.0),
    "LED_Emissive": ("#1A0D14", 0.0, 0.4, "#FF99DB", 3.0),
    "Gauge_Emissive": ("#0A2830", 0.0, 0.3, "#59D9F2", 1.6),
    "Strip_Emissive": ("#10141C", 0.0, 0.4, "#E8F1FF", 1.4),
    "Status_Emissive": ("#0A2A12", 0.0, 0.4, "#46F08A", 2.0),
}
_mat_cache = {}


def material(name):
    if name in _mat_cache and _mat_cache[name].name in bpy.data.materials:
        return _mat_cache[name]
    hexcol, metal, rough, emit_hex, emit = MATERIALS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = srgb(hexcol)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if emit_hex:
        b.inputs["Emission Color"].default_value = srgb(emit_hex)
        b.inputs["Emission Strength"].default_value = emit
    _mat_cache[name] = m
    return m


class Asset:
    """Collects geometry into one bmesh per material, then writes one object per material and exports."""

    def __init__(self, name):
        self.name = name
        self.parts = {}
        self.empties = []

    def _bm(self, mat):
        if mat not in self.parts:
            self.parts[mat] = bmesh.new()
        return self.parts[mat]

    @staticmethod
    def _merge(dst, src):
        vmap = {v: dst.verts.new(v.co) for v in src.verts}
        for f in src.faces:
            dst.faces.new([vmap[v] for v in f.verts])

    def _add(self, mat, src):
        self._merge(self._bm(mat), src)
        src.free()

    def box(self, mat, center, size, bevel=0.0, segments=2):
        """center and size in Godot space."""
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        s = Vector((size[0], size[2], size[1]))   # Blender axes: x, y = Godot z, z = Godot y
        c = G(*center)
        for v in bm.verts:
            v.co = Vector((v.co.x * s.x, v.co.y * s.y, v.co.z * s.z)) + c
        b = min(bevel, 0.45 * min(size))
        if b > 1e-4:
            bmesh.ops.bevel(bm, geom=list(bm.edges), offset=b, segments=segments, affect="EDGES")
        self._add(mat, bm)

    def cyl(self, mat, p0, p1, r0, r1, seg=28, caps=True):
        """A cone or cylinder between two Godot-space points; r0 at p0."""
        a, b = G(*p0), G(*p1)
        d = b - a
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=seg, radius1=r0, radius2=r1, depth=d.length)
        rot = Vector((0, 0, 1)).rotation_difference(d).to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=Matrix.Translation((a + b) / 2.0) @ rot, verts=bm.verts)
        self._add(mat, bm)

    def ellipsoid(self, mat, center, radii, seg=24, rings=12):
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
        c = G(*center)
        for v in bm.verts:
            v.co = Vector((v.co.x * radii[0], v.co.y * radii[2], v.co.z * radii[1])) + c
        self._add(mat, bm)

    def lathe(self, mat, profile, seg=40):
        """Revolve a profile of (radius, height) points about the vertical axis through the origin (Godot space)."""
        bm = bmesh.new()
        rings = []
        for r, h in profile:
            if r < 1e-6:
                rings.append([bm.verts.new(G(0, h, 0))])
            else:
                rings.append([bm.verts.new(G(r * math.cos(2 * math.pi * k / seg), h, r * math.sin(2 * math.pi * k / seg))) for k in range(seg)])
        for i in range(len(rings) - 1):
            a, b = rings[i], rings[i + 1]
            for k in range(seg):
                k2 = (k + 1) % seg
                if len(a) == 1:
                    bm.faces.new((a[0], b[k2], b[k]))
                elif len(b) == 1:
                    bm.faces.new((a[k], a[k2], b[0]))
                else:
                    bm.faces.new((a[k], a[k2], b[k2], b[k]))
        self._add(mat, bm)

    def grid(self, mat, y, x0, x1, z0, z1, nx, nz, relief=0.0, seed=1):
        """A flat grid facing up at height y with a little random relief (soil)."""
        rnd = random.Random(seed)
        bm = bmesh.new()
        verts = [[bm.verts.new(G(x0 + (x1 - x0) * i / nx, y + rnd.uniform(0.0, relief), z0 + (z1 - z0) * j / nz)) for i in range(nx + 1)] for j in range(nz + 1)]
        for j in range(nz):
            for i in range(nx):
                bm.faces.new((verts[j][i], verts[j][i + 1], verts[j + 1][i + 1], verts[j + 1][i]))
        self._add(mat, bm)

    def empty(self, name, pos):
        self.empties.append((name, G(*pos)))

    def export(self):
        for matname, bm in self.parts.items():
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
            lim = math.radians(35.0)
            for f in bm.faces:
                f.smooth = True
            for e in bm.edges:
                e.smooth = len(e.link_faces) == 2 and e.link_faces[0].normal.angle(e.link_faces[1].normal, 0.0) < lim
            me = bpy.data.meshes.new(matname)
            bm.to_mesh(me)
            bm.free()
            me.materials.append(material(matname))
            ob = bpy.data.objects.new(matname, me)
            bpy.context.scene.collection.objects.link(ob)
        for name, pos in self.empties:
            e = bpy.data.objects.new(name, None)
            e.empty_display_type = "PLAIN_AXES"
            e.empty_display_size = 0.02
            e.location = pos
            bpy.context.scene.collection.objects.link(e)
        path = os.path.join(OUT, self.name + ".glb")
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=False, export_apply=True, export_yup=True,
                                  export_cameras=False, export_lights=False, export_materials="EXPORT")
        print("wrote", path, os.path.getsize(path), "bytes;", sum(1 for o in bpy.data.objects if o.type == "MESH"), "meshes,", len(self.empties), "empties")


def fresh():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mat_cache.clear()


# ---- the assets ------------------------------------------------------------------------------------------

def planter_tray():
    """1.2 x 0.22 x 0.6 m regolith trough. Origin: middle of the bottom. Soil surface at y = 0.17. Matches the procedural 'planter_tray'."""
    a = Asset("regolith_bed")
    L, H, W, t = 1.2, 0.22, 0.6, 0.03
    lip, over = 0.016, 0.012
    a.box("Base_Basalt", (0, 0.01, 0), (L, 0.02, W), 0.004)
    a.box("Body_White", (0, H / 2, W / 2 - t / 2), (L, H, t), 0.006)
    a.box("Body_White", (0, H / 2, -W / 2 + t / 2), (L, H, t), 0.006)
    a.box("Body_White", (L / 2 - t / 2, H / 2, 0), (t, H, W - 2 * t), 0.006)
    a.box("Body_White", (-L / 2 + t / 2, H / 2, 0), (t, H, W - 2 * t), 0.006)
    # the rust lip around the top edge
    a.box("Trim_Rust", (0, H - lip / 2, W / 2 - t / 2 + over / 2), (L + 2 * over, lip, t + over), 0.004)
    a.box("Trim_Rust", (0, H - lip / 2, -W / 2 + t / 2 - over / 2), (L + 2 * over, lip, t + over), 0.004)
    a.box("Trim_Rust", (L / 2 - t / 2 + over / 2, H - lip / 2, 0), (t + over, lip, W - 2 * t), 0.004)
    a.box("Trim_Rust", (-L / 2 + t / 2 - over / 2, H - lip / 2, 0), (t + over, lip, W - 2 * t), 0.004)
    # three shallow panels on each long side, a label plate on the front
    for z in (W / 2 + 0.001, -W / 2 - 0.001):
        for x in (-0.38, 0.0, 0.38):
            a.box("Body_Dim", (x, 0.105, z), (0.30, 0.13, 0.002), 0.002)
    a.box("Trim_Rust", (0, 0.105, W / 2 + 0.0035), (0.16, 0.045, 0.003), 0.001)
    # end fittings: a drain stub at +x (as the procedural shape), an irrigation inlet at -x
    a.cyl("Steel", (L / 2, 0.06, 0), (L / 2 + 0.04, 0.06, 0), 0.016, 0.016, 16)
    a.cyl("Steel", (-L / 2 - 0.05, H - 0.07, 0), (-L / 2, H - 0.07, 0), 0.012, 0.012, 16)
    a.cyl("Trim_Rust", (-L / 2 - 0.02, H - 0.07, 0), (-L / 2 - 0.004, H - 0.07, 0), 0.02, 0.02, 16)
    # soil: a faintly lumpy surface 5 cm below the rim
    soil_y = H - 0.05
    a.grid("Soil_Regolith", soil_y - 0.002, -L / 2 + t, L / 2 - t, -W / 2 + t, W / 2 - t, 32, 16, relief=0.004, seed=7)
    # planting slots, row-major, exactly where FarmShapeBuilder.get_slot_positions() puts them
    rows, cols = 2, 4
    il, iw = L - 2 * t, W - 2 * t
    for j in range(rows):
        for i in range(cols):
            a.empty("Slot_%d" % (j * cols + i), (-il / 2 + (i + 0.5) * il / cols, soil_y, -iw / 2 + (j + 0.5) * iw / rows))
    a.export()


def grow_light():
    """A 1.2 m LED bar. Origin: the mount point at the middle of the top. Matches the procedural 'grow_light'."""
    a = Asset("led_bar")
    L = 1.2
    a.box("Body_White", (0, -0.025, 0), (L, 0.05, 0.11), 0.008)
    for i in range(9):                                          # heat-sink fins along the top
        a.box("Body_Dim", (-0.5 + i * 0.125, 0.008, 0), (0.008, 0.02, 0.09), 0.001)
    for s in (-1, 1):                                           # rust end caps
        a.box("Trim_Rust", (s * (L / 2 + 0.005), -0.025, 0), (0.01, 0.056, 0.118), 0.003)
    a.box("Base_Basalt", (0.3, 0.012, 0), (0.12, 0.028, 0.06), 0.004)   # the driver box
    a.box("LED_Emissive", (0, -0.0515, 0), (L - 0.04, 0.003, 0.085))      # the LED panel
    for s in (-1, 1):                                           # two hangers with ceiling plates
        a.cyl("Steel", (s * L * 0.33, 0, 0), (s * L * 0.33, 0.12, 0), 0.004, 0.004, 10)
        a.cyl("Steel", (s * L * 0.33, 0.118, 0), (s * L * 0.33, 0.122, 0), 0.016, 0.016, 16)
    a.export()


def water_tank():
    """A domed vertical tank, 0.7 m across and 0.9 m tall. Origin: middle of the bottom. Level gauge faces +z (the viewer). Matches 'tank'."""
    a = Asset("ice_tank")
    R, H = 0.35, 0.9
    d = 0.12 * H
    prof = [(0, 0.0), (R * 0.55, 0.0), (R * 0.9, 0.03), (R, d), (R, H - d), (R * 0.9, H - 0.03), (R * 0.55, H), (0, H)]
    a.lathe("Body_White", prof, 48)
    for f in (0.22, 0.78):                                      # two rust bands
        a.cyl("Trim_Rust", (0, H * f, 0), (0, H * f + 0.035, 0), R + 0.006, R + 0.006, 48)
    # the level gauge: a window with a rust frame, glowing
    a.box("Trim_Rust", (0, H * 0.5, R + 0.001), (0.09, H * 0.52, 0.008), 0.003)
    a.box("Gauge_Emissive", (0, H * 0.5, R + 0.0055), (0.05, H * 0.46, 0.004))
    for i in range(3):                                          # legs
        ang = 2 * math.pi * i / 3 + math.pi / 2
        a.box("Steel", (math.cos(ang) * R * 0.7, 0.04, math.sin(ang) * R * 0.7), (0.05, 0.08, 0.05), 0.006)
    a.cyl("Steel", (0, H, 0), (0, H + 0.09, 0), 0.03, 0.03, 20)  # the fill pipe on top, with a rust collar
    a.cyl("Trim_Rust", (0, H + 0.06, 0), (0, H + 0.075, 0), 0.04, 0.04, 20)
    a.cyl("Steel", (R * 0.95, 0.14, 0), (R + 0.12, 0.14, 0), 0.025, 0.025, 18)   # the outlet and its valve
    a.cyl("Trim_Rust", (R + 0.05, 0.14, 0), (R + 0.09, 0.14, 0), 0.035, 0.035, 18)
    a.export()


def seed_crate():
    """A stackable supply crate, 0.40 x 0.25 x 0.30 m. Origin: middle of the bottom."""
    a = Asset("supply_crate")
    a.box("Body_White", (0, 0.11, 0), (0.40, 0.22, 0.30), 0.01)
    a.box("Body_Dim", (0, 0.235, 0), (0.41, 0.03, 0.31), 0.008)           # the lid
    for sx in (-1, 1):
        for sz in (-1, 1):
            a.box("Steel", (sx * 0.19, 0.125, sz * 0.14), (0.03, 0.25, 0.03), 0.004)   # corner posts
    for s in (-1, 1):                                                      # handle cut-outs on the short ends
        a.box("Dark_Panel", (s * 0.2005, 0.14, 0), (0.004, 0.04, 0.12), 0.002)
    a.box("Trim_Rust", (0, 0.12, 0.1505), (0.16, 0.07, 0.003), 0.001)      # the label plate
    a.box("Trim_Rust", (0, 0.222, 0.158), (0.05, 0.03, 0.01), 0.003)       # the latch
    a.export()


def airlock():
    """A dome airlock hatch, 1.4 m wide, 2.2 m tall, 0.4 m deep. Origin: middle of the bottom; the door faces +z."""
    a = Asset("airlock")
    a.box("Base_Basalt", (0, 0.05, 0), (1.5, 0.1, 0.5), 0.01)                       # threshold slab
    for s in (-1, 1):                                                              # frame posts
        a.box("Trim_Rust", (s * 0.68, 1.1, 0), (0.12, 2.2, 0.4), 0.01)
    a.box("Trim_Rust", (0, 2.14, 0), (1.5, 0.12, 0.4), 0.01)                        # lintel
    a.box("Body_White", (0, 1.05, -0.02), (1.24, 2.1, 0.12), 0.01)                  # the door leaf
    a.box("Body_Dim", (0, 1.05, 0.045), (1.0, 1.86, 0.02), 0.006)                   # raised panel
    a.cyl("Dark_Panel", (0, 1.45, 0.056), (0, 1.45, 0.07), 0.2, 0.2, 32)             # the porthole: rim, then glass
    a.cyl("Gauge_Emissive", (0, 1.45, 0.068), (0, 1.45, 0.075), 0.16, 0.16, 32)
    a.cyl("Steel", (0.3, 0.95, 0.056), (0.3, 0.95, 0.09), 0.1, 0.1, 24)            # the handle wheel: hub and rim
    for k in range(4):
        ang = math.pi * k / 4
        a.box("Steel", (0.3 + math.cos(ang) * 0.0, 0.95, 0.09), (0.016, 0.2 if k % 2 == 0 else 0.016, 0.016), 0.002)
        a.box("Steel", (0.3, 0.95, 0.09), (0.2 if k % 2 == 1 else 0.016, 0.016, 0.016), 0.002)
    a.box("Status_Emissive", (-0.4, 1.9, 0.056), (0.08, 0.05, 0.01), 0.002)          # status light
    for i in range(6):                                                              # hazard stripes on the lintel face
        a.box("Trim_Rust" if i % 2 == 0 else "Body_White", (-0.55 + i * 0.22, 2.14, 0.2005), (0.2, 0.08, 0.002))
    a.export()


BUILDERS = {"regolith_bed": planter_tray, "led_bar": grow_light, "ice_tank": water_tank, "supply_crate": seed_crate, "airlock": airlock}

for name, fn in BUILDERS.items():
    if WANT and name not in WANT:
        continue
    fresh()
    fn()

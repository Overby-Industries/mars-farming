"""The crew astronaut as modular suit components, each exported as its own glTF binary.

    blender -b --factory-startup --python blender/build_astronaut.py -- godot/models/astronaut [component ...]

A chunky sci-fi EVA suit about 1.8 m tall: white hard armour plates over a black undersuit, orange accents (shoulder
caps, thigh and shin panels, the strap under the backpack), thin glowing blue light strips, a round helmet with a dark
visor and a headset disc on each side, a boxy backpack with a vent grille, black gloves, chunky boots, and a green leaf
in a dark ring on the chest and on the backpack.

The suit is NOT one model. It is eleven components, so each can be animated, swapped, recoloured or left out, and the
same files serve every game:

    torso      waist to collar: pelvis, belt, chest, neck.  Sockets: Neck, Back, ShoulderR/L, HipR/L
    helmet     shell, visor, headset discs, seal ring       origin at the base of the neck
    backpack   frame, vent grille, strips, leaf, canisters  origin at the middle of its mounting face
    arm_r/l    shoulder armour, upper arm, forearm          origin at the shoulder; Forearm pivots at the elbow; Socket_Wrist
    glove_r/l  the hand                                     origin at the wrist
    leg_r/l    thigh, knee and shin                         origin at the hip; Shin pivots at the knee; Socket_Ankle
    boot_r/l   the boot                                     origin at the ankle

Every component is modelled in the suit's own axes (+x is the figure's right hand, y up, the figure FACES -z, Godot's
forward) with its origin at its joint and its limbs hanging straight down; the stance (arms out a little, elbows
bent) is data in godot/scripts/astronaut.gd, not baked in. Components hang on each other through SOCKETS: empties named
Socket_* that the host component places, so a torso with other proportions brings its own sockets with it. Inside a
component the moving pivots (Chest, Forearm, Shin) are empties too; each mesh is named <Part>_<Material>.

Same conventions as build_assets.py: real metres, geometry written in GODOT space and converted to Blender's axes at the
end (so the glTF exporter's Y-up conversion lands every point back on the same Godot coordinates), plain Principled BSDF
colours with no textures, material names that say what the surface is (Suit_White, Strip_Blue ...).
"""
import contextlib
import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(ARGS[0] if ARGS else "models/astronaut")
WANT = ARGS[1:]
os.makedirs(OUT, exist_ok=True)

G_MAT = Matrix.Rotation(math.radians(90.0), 4, "X")   # Godot space -> Blender space: (x, y, z) -> (x, -z, y)


def V(x, y, z):
    return Vector((x, y, z))


def srgb(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    f = lambda v: v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return (f(c[0]), f(c[1]), f(c[2]), 1.0)


MATERIALS = {
    # name: (hex, metallic, roughness, emission hex or None, emission strength)
    "Suit_White": ("#E7E9ED", 0.25, 0.42, None, 0.0),      # the hard armour plates
    "Suit_Grey": ("#B3B8C0", 0.35, 0.45, None, 0.0),       # recessed panels between the white plates
    "Undersuit": ("#1B1D22", 0.0, 0.92, None, 0.0),        # the undersuit: a technical fabric, matte, woven (astronaut.gd gives it its weave)
    "Suit_Orange": ("#EF7B1D", 0.2, 0.42, None, 0.0),      # shoulder caps, shin and thigh panels, the backpack strap
    "Metal_Dark": ("#3A3E46", 0.85, 0.38, None, 0.0),      # gunmetal fittings, rings, the vent grille
    "Rubber": ("#0F1013", 0.0, 0.90, None, 0.0),           # boot soles
    "Glove": ("#17191D", 0.0, 0.70, None, 0.0),            # the gloves
    "Strip_Blue": ("#0B1730", 0.0, 0.30, "#2A74FF", 2.0),  # the light strips: small emissive accents
    "Indicator_Amber": ("#2A1604", 0.0, 0.30, "#FFAA2B", 2.0),   # the odd status light
    "Visor": ("#04060C", 0.9, 0.07, None, 0.0),            # the dark reflective visor
    "Visor_Glint": ("#0A1630", 0.0, 0.20, "#4C9BFF", 0.9), # a little blue Earth in the reflection
    "Logo_Dark": ("#111418", 0.2, 0.50, None, 0.0),        # the ring of the leaf logo
    "Logo_Green": ("#2FA24A", 0.0, 0.45, None, 0.0),       # the lit half of the leaf
    "Logo_Green_Dark": ("#1B7433", 0.0, 0.50, None, 0.0),  # the shaded half
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


def euler_matrix(rot):
    return Euler(tuple(math.radians(a) for a in rot), "XYZ").to_matrix().to_4x4()


class Component:
    """One exported file: a tree of pivots (Parts) around an origin, in the suit's absolute coordinates."""

    def __init__(self, name, origin):
        self.name, self.origin, self.parts = name, Vector(origin), []

    def part(self, name, pivot, parent=None):
        p = Part(self, name, pivot, parent)
        self.parts.append(p)
        return p


class Part:
    """One pivot of a component and the geometry that moves with it. Geometry is written in absolute suit coordinates
    (or in a local frame, see frame()) and stored per material."""

    def __init__(self, comp, name, pivot, parent=None):
        self.comp, self.name, self.pivot, self.parent = comp, name, Vector(pivot), parent
        self.bms = {}
        self.sockets = []
        self.frame_m = Matrix.Identity(4)

    @contextlib.contextmanager
    def frame(self, origin=(0, 0, 0), rot=(0, 0, 0)):
        """Everything drawn inside the block is in a local frame: its origin at `origin`, turned by `rot` (degrees)."""
        old = self.frame_m
        self.frame_m = old @ Matrix.Translation(Vector(origin)) @ euler_matrix(rot)
        try:
            yield
        finally:
            self.frame_m = old

    def socket(self, name, pos):
        self.sockets.append((name, Vector(pos)))

    def _put(self, mat, bm, center=(0, 0, 0), rot=(0, 0, 0)):
        bmesh.ops.transform(bm, matrix=self.frame_m @ Matrix.Translation(Vector(center)) @ euler_matrix(rot), verts=bm.verts)
        dst = self.bms.setdefault(mat, bmesh.new())
        vmap = {v: dst.verts.new(v.co) for v in bm.verts}
        for f in bm.faces:
            dst.faces.new([vmap[v] for v in f.verts])
        bm.free()

    def box(self, mat, center, size, bevel=0.0, seg=None, rot=(0, 0, 0)):
        """A bevelled box; `seg` bevel segments, by default more for a rounder edge (3 from 2 cm, 2 from 8 mm, else 1)."""
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        for v in bm.verts:
            v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
        b = min(bevel, 0.45 * min(size))
        if seg is None:
            seg = 3 if b >= 0.02 else (2 if b >= 0.008 else 1)
        if b > 1e-4:
            bmesh.ops.bevel(bm, geom=list(bm.edges), offset=b, segments=seg, profile=0.5, affect="EDGES", clamp_overlap=True)
        self._put(mat, bm, center, rot)

    def cyl(self, mat, p0, p1, r0, r1=None, seg=20, caps=True):
        """A cone or cylinder between two points; r0 at p0."""
        r1 = r0 if r1 is None else r1
        a, b = Vector(p0), Vector(p1)
        d = b - a
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=seg, radius1=r0, radius2=r1, depth=d.length)
        rot = Vector((0, 0, 1)).rotation_difference(d).to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=Matrix.Translation((a + b) / 2.0) @ rot, verts=bm.verts)
        self._put(mat, bm)

    def bellows(self, mat, p0, p1, r, ribs=4, depth=0.2, seg=14):
        """A corrugated tube between two points, like the accordion of a flexible joint: `ribs` ridges, each `depth` (a
        fraction of r) tall. It starts and ends at radius r."""
        a, b = Vector(p0), Vector(p1)
        d = b - a
        length = d.length
        bm = bmesh.new()
        n = ribs * 4
        rings = []
        for i in range(n + 1):
            t = i / n
            rad = r * (1.0 + depth * 0.5 * (1.0 - math.cos(2.0 * math.pi * ribs * t)))
            z = -length / 2.0 + length * t
            rings.append([bm.verts.new((rad * math.cos(2.0 * math.pi * k / seg), rad * math.sin(2.0 * math.pi * k / seg), z)) for k in range(seg)])
        for i in range(n):
            for k in range(seg):
                k2 = (k + 1) % seg
                bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
        bm.faces.new(rings[0][::-1])
        bm.faces.new(rings[-1])
        rot = Vector((0, 0, 1)).rotation_difference(d).to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=Matrix.Translation((a + b) / 2.0) @ rot, verts=bm.verts)
        self._put(mat, bm)

    def ball(self, mat, center, radii, seg=20, rings=10, rot=(0, 0, 0)):
        """An ellipsoid with radii (rx, ry, rz) in Godot axes, its poles up and down."""
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
        for v in bm.verts:   # the UV sphere's poles are on its z axis: scale there, then stand it up (x, y, z) -> (x, z, -y)
            v.co = Vector((v.co.x * radii[0], v.co.z * radii[1], -v.co.y * radii[2]))
        self._put(mat, bm, center, rot)

    def torus(self, mat, center, R, r, rot=(0, 0, 0), seg=40, tube=8, scale=(1.0, 1.0, 1.0)):
        """A ring around the local z axis: major radius R, tube radius r, and an optional stretch."""
        bm = bmesh.new()
        grid = []
        for i in range(seg):
            th = 2.0 * math.pi * i / seg
            row = []
            for j in range(tube):
                ph = 2.0 * math.pi * j / tube
                rr = R + r * math.cos(ph)
                row.append(bm.verts.new((rr * math.cos(th) * scale[0], rr * math.sin(th) * scale[1], r * math.sin(ph) * scale[2])))
            grid.append(row)
        for i in range(seg):
            for j in range(tube):
                bm.faces.new((grid[i][j], grid[(i + 1) % seg][j], grid[(i + 1) % seg][(j + 1) % tube], grid[i][(j + 1) % tube]))
        self._put(mat, bm, center, rot)

    def prism(self, mat, pts, depth, center=(0, 0, 0), rot=(0, 0, 0)):
        """A flat polygon (points in the local xy plane) extruded `depth` along z, centred on z = 0."""
        bm = bmesh.new()
        lo = [bm.verts.new((x, y, -depth / 2.0)) for x, y in pts]
        hi = [bm.verts.new((x, y, depth / 2.0)) for x, y in pts]
        bm.faces.new(lo[::-1])
        bm.faces.new(hi)
        n = len(pts)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
        self._put(mat, bm, center, rot)

    def logo(self, center, R, facing):
        """The leaf logo: a green leaf in a dark ring, radius R, on a flat plate that faces +z (facing = 1) or -z
        (facing = -1). `center` is on the plate surface; the art stands a few millimetres proud of it."""
        rot = (0, 0, 0) if facing > 0 else (0, 180, 0)
        with self.frame(center, rot):
            self.torus("Logo_Dark", (0, 0, 0.0025), R * 0.93, R * 0.075, seg=48, tube=8, scale=(1.0, 1.0, 0.55))
            for base, tip, width, bend in (((-0.34 * R, -0.52 * R), (0.56 * R, 0.56 * R), 0.36 * R, 0.16),
                                           ((-0.36 * R, -0.50 * R), (-0.78 * R, 0.06 * R), 0.17 * R, -0.12)):
                lit, shaded = leaf_halves(base, tip, width, bend)
                self.prism("Logo_Green", lit, 0.004, (0, 0, 0.002))
                self.prism("Logo_Green_Dark", shaded, 0.004, (0, 0, 0.002))
            self.prism("Logo_Green_Dark", [(-0.42 * R, -0.80 * R), (-0.36 * R, -0.82 * R), (-0.24 * R, -0.52 * R), (-0.32 * R, -0.48 * R)], 0.004, (0, 0, 0.002))

    def finish(self, objects):
        """Make the empty, its sockets and its meshes (Blender space, relative to the pivot) and link them under the parent."""
        e = bpy.data.objects.new(self.name, None)
        e.empty_display_type = "PLAIN_AXES"
        e.empty_display_size = 0.03
        if self.parent is not None:
            e.parent = objects[self.parent.name]
            e.location = G_MAT @ (self.pivot - self.parent.pivot)
        else:
            e.location = G_MAT @ (self.pivot - self.comp.origin)
        bpy.context.scene.collection.objects.link(e)
        objects[self.name] = e
        for sname, pos in self.sockets:
            s = bpy.data.objects.new(sname, None)
            s.empty_display_type = "ARROWS"
            s.empty_display_size = 0.03
            s.parent = e
            s.location = G_MAT @ (pos - self.pivot)
            bpy.context.scene.collection.objects.link(s)
        tris = 0
        for matname, bm in self.bms.items():
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
            bmesh.ops.transform(bm, matrix=G_MAT @ Matrix.Translation(-self.pivot), verts=bm.verts)
            lim = math.radians(40.0)
            for f in bm.faces:
                f.smooth = True
            for ed in bm.edges:
                ed.smooth = len(ed.link_faces) == 2 and ed.link_faces[0].normal.angle(ed.link_faces[1].normal, 0.0) < lim
            tris += sum(len(f.verts) - 2 for f in bm.faces)
            me = bpy.data.meshes.new("%s_%s" % (self.name, matname))
            bm.to_mesh(me)
            bm.free()
            me.materials.append(material(matname))
            ob = bpy.data.objects.new("%s_%s" % (self.name, matname), me)
            ob.parent = e
            bpy.context.scene.collection.objects.link(ob)
        return tris


def leaf_halves(base, tip, width, bend=0.0, n=12):
    """The two halves of a pointed-oval leaf from base to tip (2D points): the half on each side of the midrib."""
    b, t = Vector(base), Vector(tip)
    ax = t - b
    length = ax.length
    u = ax / length
    w = Vector((-u.y, u.x))
    centre, left, right = [], [], []
    for k in range(n + 1):
        s = k / n
        c = b + u * (length * s) + w * (bend * length * math.sin(math.pi * s))
        h = width * ((4.0 * s * (1.0 - s)) ** 0.75) * (1.0 - 0.25 * s)
        centre.append(c)
        left.append(c + w * h)
        right.append(c - w * h)
    mid = centre[-2:0:-1]
    return [(p.x, p.y) for p in left + mid], [(p.x, p.y) for p in right + mid]


# ---- the components --------------------------------------------------------------------------------------------
# Authored in the suit's absolute coordinates (floor at y = 0, figure facing -z) or, for the limbs, relative to the joint
# the component hangs from; the exporter subtracts the component's origin.

def comp_torso(c):
    t = c.part("Torso", (0.0, 1.02, 0.0))
    # the pelvis and belt, which stay still when the chest breathes
    t.box("Undersuit", (0, 0.985, 0), (0.34, 0.16, 0.22), 0.05, 3)
    t.box("Undersuit", (0, 1.06, 0), (0.355, 0.06, 0.235), 0.018)
    t.box("Metal_Dark", (0, 1.06, -0.1235), (0.075, 0.05, 0.018), 0.008)                   # buckle
    t.box("Suit_Orange", (0, 1.06, -0.1335), (0.022, 0.022, 0.004))                        # an orange stud
    t.box("Indicator_Amber", (0.045, 1.06, -0.1335), (0.008, 0.008, 0.004))                # and a status light
    for s in (-1.0, 1.0):
        t.box("Metal_Dark", (s * 0.195, 1.0, -0.02), (0.065, 0.11, 0.12), 0.02)            # pouches...
        t.box("Undersuit", (s * 0.195, 1.052, -0.02), (0.07, 0.025, 0.125), 0.008)         # ...and their flaps
        t.box("Suit_White", (s * 0.172, 0.915, 0.0), (0.035, 0.12, 0.13), 0.012)           # side hip plates, each with
        t.box("Suit_Orange", (s * 0.1895, 0.915, 0.0), (0.012, 0.07, 0.09), 0.004)         # an orange hip accent
    t.prism("Suit_White", [(-0.085, 0.045), (0.085, 0.045), (0.085, 0.0), (0.0, -0.09), (-0.085, 0.0)], 0.035, (0, 0.93, -0.115))
    t.box("Suit_White", (0, 0.945, 0.115), (0.16, 0.14, 0.03), 0.015)                      # rear hip plate
    t.socket("Socket_HipR", (0.105, 0.93, 0.0))
    t.socket("Socket_HipL", (-0.105, 0.93, 0.0))

    ch = c.part("Chest", (0.0, 1.02, 0.0), parent=t)
    ch.box("Undersuit", (0, 1.23, 0), (0.335, 0.40, 0.215), 0.06, 3)                      # the undersuit core
    ch.box("Suit_White", (0, 1.30, -0.118), (0.27, 0.19, 0.06), 0.028)                     # chest plate
    ch.box("Suit_Grey", (0, 1.185, -0.112), (0.15, 0.05, 0.04), 0.018)                     # a lower chest panel
    ch.box("Suit_Orange", (0, 1.1545, -0.1345), (0.07, 0.01, 0.005))                       # with an orange chevron
    ch.box("Suit_White", (0, 1.09, -0.108), (0.15, 0.07, 0.04), 0.018)                     # abdomen plate
    for s in (-1.0, 1.0):
        ch.box("Metal_Dark", (s * 0.095, 1.30, -0.1485), (0.022, 0.10, 0.006))             # the strips' dark slots...
        ch.box("Strip_Blue", (s * 0.095, 1.30, -0.1515), (0.012, 0.085, 0.006))            # ...and the strips
        ch.box("Suit_White", (s * 0.105, 1.425, -0.04), (0.12, 0.05, 0.15), 0.022, rot=(0, 0, -s * 14.0))   # clavicle plates
    ch.logo((0, 1.305, -0.148), 0.05, -1)                                                  # the leaf, on the chest
    ch.bellows("Undersuit", (0, 1.43, 0), (0, 1.525, 0), 0.058, 3, 0.2)                    # the neck: a corrugated fabric sleeve
    ch.cyl("Metal_Dark", (0, 1.462, 0), (0, 1.495, 0), 0.098, 0.092, 24)                   # collar ring
    ch.socket("Socket_Neck", (0.0, 1.50, 0.0))
    ch.socket("Socket_Back", (0.0, 1.30, 0.1075))
    ch.socket("Socket_ShoulderR", (0.215, 1.42, 0.0))
    ch.socket("Socket_ShoulderL", (-0.215, 1.42, 0.0))


def comp_helmet(c):
    h = c.part("Helmet", (0.0, 1.50, 0.0))
    h.cyl("Metal_Dark", (0, 1.49, 0), (0, 1.53, 0), 0.112, 0.106, 28)                      # the seal ring under the helmet
    h.ball("Suit_White", (0, 1.655, 0.005), (0.145, 0.142, 0.162), 32, 18)                 # the shell
    h.ball("Suit_Grey", (0, 1.655, 0.005), (0.0135, 0.1475, 0.1665), 12, 18)               # a seam along the middle of the shell
    h.ball("Visor", (0, 1.662, -0.063), (0.117, 0.094, 0.125), 32, 16)                     # the dark reflective face plate...
    h.torus("Suit_Grey", (0, 1.662, -0.103), 1.0, 0.0065, seg=40, tube=6, scale=(0.109, 0.088, 1.0))   # ...and its bezel
    h.ball("Visor_Glint", (0.052, 1.69, -0.1845), (0.02, 0.011, 0.006), 12, 8, rot=(0, 0, 25))         # the Earth, reflected
    h.ball("Visor_Glint", (0.082, 1.667, -0.171), (0.006, 0.006, 0.004), 8, 6)
    h.ball("Metal_Dark", (0, 1.585, 0.145), (0.06, 0.04, 0.03), 12, 8)                     # a rear vent
    for s in (-1.0, 1.0):
        h.cyl("Suit_White", (s * 0.135, 1.655, 0.015), (s * 0.165, 1.655, 0.015), 0.05, 0.047, 24)     # the headset discs
        h.cyl("Suit_Grey", (s * 0.162, 1.655, 0.015), (s * 0.172, 1.655, 0.015), 0.04, 0.038, 24)
        h.cyl("Metal_Dark", (s * 0.17, 1.655, 0.015), (s * 0.179, 1.655, 0.015), 0.024, 0.024, 20)
        h.ball("Suit_Orange", (s * 0.05, 1.7595, -0.085), (0.022, 0.012, 0.03), 10, 6, rot=(-35, 0, s * 10.0))   # orange marks by the seam


def comp_backpack(c):
    b = c.part("Backpack", (0.0, 1.30, 0.11))
    b.box("Suit_White", (0, 1.325, 0.20), (0.34, 0.40, 0.18), 0.035)                       # the frame
    b.box("Suit_Grey", (0, 1.52, 0.19), (0.27, 0.035, 0.15), 0.012)                        # top cap
    b.box("Metal_Dark", (0, 1.5455, 0.19), (0.12, 0.012, 0.022), 0.004)                    # a carry handle
    for i, mat in enumerate(("Strip_Blue", "Strip_Blue", "Indicator_Amber")):              # three status lights on the cap
        b.box(mat, (-0.045 + i * 0.03, 1.5385, 0.262), (0.014, 0.004, 0.01))
    b.box("Suit_Grey", (0, 1.355, 0.2965), (0.26, 0.29, 0.012), 0.008)                     # the raised back panel
    for s in (-1.0, 1.0):
        b.box("Metal_Dark", (s * 0.115, 1.355, 0.3015), (0.036, 0.23, 0.006), 0.002)       # the strips' slots
        b.box("Strip_Blue", (s * 0.115, 1.355, 0.3045), (0.022, 0.19, 0.006))              # the two vertical blue strips
        b.box("Suit_White", (s * 0.2, 1.215, 0.20), (0.055, 0.13, 0.10), 0.02)             # a canister at each side...
        b.box("Strip_Blue", (s * 0.2, 1.215, 0.2525), (0.012, 0.07, 0.006))
        b.cyl("Metal_Dark", (s * 0.2, 1.28, 0.2), (s * 0.2, 1.305, 0.2), 0.012, 0.012, 14)  # ...with a valve and an orange ring
        b.cyl("Suit_Orange", (s * 0.2, 1.285, 0.2), (s * 0.2, 1.292, 0.2), 0.017, 0.017, 14)
        b.bellows("Undersuit", (s * 0.2, 1.305, 0.2), (s * 0.2, 1.50, 0.2), 0.011, 9, 0.35, 10)   # the life-support hose up the side
    b.cyl("Metal_Dark", (0.17, 1.40, 0.2), (0.177, 1.40, 0.2), 0.026, 0.026, 20)           # a pressure gauge on the right side...
    b.cyl("Strip_Blue", (0.177, 1.40, 0.2), (0.1795, 1.40, 0.2), 0.017, 0.017, 20)         # ...with a glowing face
    b.logo((0, 1.41, 0.3025), 0.066, 1)                                                    # the leaf, on the back
    b.box("Metal_Dark", (0, 1.19, 0.3), (0.22, 0.085, 0.012), 0.004)                       # the vent panel...
    for i in range(5):
        b.box("Undersuit", (0, 1.165 + i * 0.0155, 0.3075), (0.20, 0.007, 0.006))          # ...and its slats
    b.box("Suit_Orange", (0, 1.14, 0.20), (0.33, 0.028, 0.19), 0.008)                      # the orange strap under the pack


def comp_arm(c, s):
    side = "R" if s > 0 else "L"
    P = V(s * 0.215, 1.42, 0.0)                    # the shoulder
    E = P + V(0, -0.255, 0)                        # the elbow
    a = c.part("Arm" + side, P)
    f = c.part("Forearm" + side, E, parent=a)
    a.bellows("Undersuit", P + V(0, 0.015, 0), P + V(0, -0.045, 0), 0.058, 3, 0.2)         # the shoulder joint: a corrugated sleeve
    with a.frame(P, (0, 0, -s * 12.0)):                                                    # shoulder armour, its outer edge dropped
        a.ball("Suit_White", (s * 0.012, 0.03, 0), (0.088, 0.07, 0.097), 24, 12)           # a white dome...
        a.ball("Suit_Orange", (s * 0.05, 0.045, 0), (0.058, 0.05, 0.092), 24, 12)          # ...with an orange panel on its outer top
    a.cyl("Undersuit", P + V(0, -0.04, 0), P + V(0, -0.215, 0), 0.056, 0.05, 16)           # the upper arm
    a.box("Suit_White", P + V(s * 0.058, -0.135, 0), (0.04, 0.15, 0.10), 0.016)
    a.box("Suit_White", P + V(0, -0.125, -0.057), (0.085, 0.14, 0.03), 0.012)
    a.box("Metal_Dark", P + V(s * 0.07, -0.165, 0), (0.024, 0.055, 0.055), 0.008)          # a little pod with a status light
    a.box("Strip_Blue", P + V(s * 0.0825, -0.165, 0), (0.004, 0.024, 0.012))
    a.cyl("Metal_Dark", P + V(0, -0.205, 0), P + V(0, -0.225, 0), 0.062, 0.062, 18)        # the band above the elbow
    a.bellows("Undersuit", E + V(0, 0.032, 0), E, 0.052, 2, 0.2)                           # the elbow
    f.bellows("Undersuit", E, E + V(0, -0.055, 0), 0.05, 2, 0.2)
    f.cyl("Undersuit", E + V(0, -0.055, 0), E + V(0, -0.12, 0), 0.05, 0.047, 16)
    f.box("Suit_White", E + V(0, -0.125, 0), (0.105, 0.17, 0.11), 0.025)                   # the forearm armour
    f.box("Suit_White", E + V(0, -0.03, 0.058), (0.07, 0.06, 0.03), 0.012)                 # the elbow pad
    f.box("Metal_Dark", E + V(s * 0.0545, -0.125, 0), (0.008, 0.15, 0.04), 0.002)          # the blue strip's slot...
    f.box("Strip_Blue", E + V(s * 0.0585, -0.125, 0), (0.006, 0.13, 0.026))                # ...and the strip
    if s < 0:                                                                               # a wrist display on the left forearm
        f.box("Metal_Dark", E + V(0, -0.105, -0.0575), (0.058, 0.078, 0.007), 0.003)
        f.box("Strip_Blue", E + V(0, -0.095, -0.0615), (0.044, 0.05, 0.004))
        f.box("Indicator_Amber", E + V(0.013, -0.139, -0.0615), (0.008, 0.008, 0.004))
        f.box("Strip_Blue", E + V(-0.013, -0.139, -0.0615), (0.008, 0.008, 0.004))
    f.cyl("Metal_Dark", E + V(0, -0.19, 0), E + V(0, -0.222, 0), 0.056, 0.056, 18)         # the cuff
    f.socket("Socket_Wrist" + side, E + V(0, -0.222, 0))


def comp_glove(c, s):
    side = "R" if s > 0 else "L"
    g = c.part("Glove" + side, (0.0, 0.0, 0.0))     # origin at the wrist, the hand hanging below it
    g.cyl("Metal_Dark", V(0, 0.004, 0), V(0, -0.02, 0), 0.05, 0.05, 18)                    # the wrist ring
    g.box("Glove", V(0, -0.055, 0), (0.082, 0.085, 0.05), 0.02)                            # the palm
    for dx, ln in ((-0.0265, 0.058), (-0.0088, 0.067), (0.0088, 0.063), (0.0265, 0.052)):   # four fingers, a little curled
        g.box("Glove", V(dx, -0.0975 - ln / 2.0, -0.014), (0.0175, ln, 0.026), 0.007, rot=(-14, 0, 0))
    g.box("Glove", V(-s * 0.045, -0.05, -0.034), (0.03, 0.07, 0.034), 0.012, rot=(-18, 0, -s * 8))   # the thumb
    g.box("Suit_Grey", V(0, -0.062, -0.0275), (0.066, 0.04, 0.012), 0.005)                 # a knuckle plate
    g.box("Metal_Dark", V(0, -0.0995, -0.0295), (0.07, 0.006, 0.01), 0.002)                # and its edge


def comp_leg(c, s):
    side = "R" if s > 0 else "L"
    H = V(s * 0.105, 0.93, 0.0)                     # the hip
    K = H + V(0, -0.405, 0)                         # the knee
    leg = c.part("Leg" + side, H)
    shin = c.part("Shin" + side, K, parent=leg)
    leg.bellows("Undersuit", H, H + V(0, -0.075, 0), 0.08, 3, 0.18)                        # the hip joint: a corrugated sleeve
    leg.cyl("Undersuit", H + V(0, -0.075, 0), K + V(0, 0.05, 0), 0.085, 0.074, 20)         # the thigh
    leg.box("Suit_White", H + V(0, -0.185, -0.09), (0.145, 0.27, 0.05), 0.022)             # front plate
    leg.box("Suit_White", H + V(s * 0.10, -0.2, -0.01), (0.04, 0.26, 0.13), 0.016)         # outer plate
    leg.box("Suit_Orange", H + V(s * 0.1215, -0.15, -0.02), (0.012, 0.13, 0.085), 0.004)   # orange panel
    leg.box("Strip_Blue", H + V(s * 0.045, -0.25, -0.1165), (0.012, 0.14, 0.006))          # blue strip
    leg.box("Suit_Grey", H + V(0, -0.2, 0.088), (0.11, 0.22, 0.03), 0.014)                 # rear panel
    leg.bellows("Undersuit", K + V(0, 0.05, 0), K, 0.07, 2, 0.2)                           # above the knee: corrugated fabric
    shin.bellows("Undersuit", K, K + V(0, -0.05, 0), 0.07, 2, 0.2)                         # below the knee
    shin.box("Suit_White", K + V(0, 0.01, -0.088), (0.14, 0.14, 0.04), 0.02)               # knee armour: a white frame...
    shin.box("Rubber", K + V(0, 0.01, -0.1105), (0.10, 0.10, 0.025), 0.014)                # ...a black pad...
    for dy in (-0.027, 0.0, 0.027):
        shin.box("Metal_Dark", K + V(0, 0.01 + dy, -0.1245), (0.08, 0.007, 0.004), 0.001)  # ...with three ridges...
    for sx in (-1.0, 1.0):
        shin.box("Suit_Orange", K + V(sx * 0.073, 0.01, -0.083), (0.01, 0.06, 0.03), 0.004)   # ...and orange hinges
    shin.cyl("Undersuit", K + V(0, -0.05, -0.006), K + V(0, -0.245, -0.015), 0.073, 0.066, 18)   # the shin
    shin.box("Suit_White", K + V(0, -0.15, -0.083), (0.125, 0.24, 0.05), 0.02)             # shin plate
    shin.box("Suit_White", K + V(s * 0.077, -0.145, -0.02), (0.035, 0.20, 0.11), 0.014)    # outer guard
    shin.box("Suit_Orange", K + V(s * 0.0955, -0.125, -0.02), (0.012, 0.12, 0.075), 0.004) # orange side panel
    shin.box("Strip_Blue", K + V(s * 0.045, -0.195, -0.1095), (0.012, 0.12, 0.006))        # blue strip
    shin.box("Suit_White", K + V(0, -0.135, 0.065), (0.11, 0.19, 0.04), 0.016)             # calf plate
    shin.bellows("Undersuit", K + V(0, -0.245, -0.015), K + V(0, -0.345, -0.02), 0.065, 2, 0.15)   # the ankle
    shin.cyl("Metal_Dark", K + V(0, -0.335, -0.02), K + V(0, -0.30, -0.02), 0.074, 0.074, 18)     # the ankle ring
    shin.socket("Socket_Ankle" + side, K + V(0, -0.335, -0.02))


def comp_boot(c, s):
    side = "R" if s > 0 else "L"
    b = c.part("Boot" + side, (0.0, 0.0, 0.0))      # origin at the ankle; the floor is 0.19 m below it
    b.box("Rubber", V(0, -0.16, -0.015), (0.19, 0.06, 0.35), 0.02)                         # sole
    b.box("Suit_White", V(0, -0.065, 0.0), (0.17, 0.135, 0.30), 0.04)                      # upper
    b.box("Suit_White", V(0, -0.09, -0.145), (0.16, 0.10, 0.10), 0.04)                     # toe cap
    b.box("Metal_Dark", V(0, -0.128, -0.195), (0.15, 0.05, 0.035), 0.012)                  # toe bumper
    b.box("Metal_Dark", V(0, -0.075, 0.135), (0.14, 0.11, 0.06), 0.02)                     # heel block
    b.box("Suit_Grey", V(0, 0.0, -0.085), (0.10, 0.014, 0.11), 0.006)                      # an instep plate
    b.box("Metal_Dark", V(0, -0.024, 0.0), (0.178, 0.028, 0.17), 0.008)                    # an ankle strap...
    b.box("Suit_Orange", V(s * 0.0905, -0.024, -0.02), (0.008, 0.03, 0.04), 0.003)         # ...with an orange buckle
    b.box("Strip_Blue", V(s * 0.0875, -0.075, 0.0), (0.006, 0.022, 0.15))                  # side strip
    b.box("Strip_Blue", V(0, -0.115, 0.1675), (0.07, 0.014, 0.006))                        # heel strip
    b.box("Strip_Blue", V(0, -0.085, -0.2025), (0.07, 0.014, 0.006))                       # toe strip


COMPONENTS = {
    # file name: (origin in the suit's coordinates, builder)
    "torso": ((0.0, 1.02, 0.0), comp_torso),
    "helmet": ((0.0, 1.50, 0.0), comp_helmet),
    "backpack": ((0.0, 1.30, 0.11), comp_backpack),
    "arm_r": ((0.215, 1.42, 0.0), lambda c: comp_arm(c, 1.0)),
    "arm_l": ((-0.215, 1.42, 0.0), lambda c: comp_arm(c, -1.0)),
    "glove_r": ((0.0, 0.0, 0.0), lambda c: comp_glove(c, 1.0)),
    "glove_l": ((0.0, 0.0, 0.0), lambda c: comp_glove(c, -1.0)),
    "leg_r": ((0.105, 0.93, 0.0), lambda c: comp_leg(c, 1.0)),
    "leg_l": ((-0.105, 0.93, 0.0), lambda c: comp_leg(c, -1.0)),
    "boot_r": ((0.0, 0.0, 0.0), lambda c: comp_boot(c, 1.0)),
    "boot_l": ((0.0, 0.0, 0.0), lambda c: comp_boot(c, -1.0)),
}

total = 0
for name, (origin, builder) in COMPONENTS.items():
    if WANT and name not in WANT:
        continue
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mat_cache.clear()
    comp = Component(name, origin)
    builder(comp)
    objects = {}
    tris = sum(p.finish(objects) for p in comp.parts)
    path = os.path.join(OUT, name + ".glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=False, export_apply=True, export_yup=True,
                              export_cameras=False, export_lights=False, export_materials="EXPORT")
    print("wrote %-14s %7d bytes %6d triangles" % (path, os.path.getsize(path), tris))
    total += tris
print("total", total, "triangles")

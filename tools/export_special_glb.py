"""不依赖 Blender，把学堂 / 牧场规格写成 glb。

    python3 tools/export_special_glb.py

材质名与 ModelPaint.COLORS 对齐，运行时仍走三平面着色器。
坐标：Blender Z-up、门朝 -Y，写入 glTF 时换成 Y-up（x, z, -y），与 Blender 导出一致。
"""

import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import special_buildings as spec


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
OUT_DIR = os.environ.get("FZ_OUT", os.path.join(ROOT, "assets", "models"))

# 显示色，仅作 glb 回退；进游戏后会被 ModelPaint 覆盖
_DISPLAY = {
    "Plaster": (0.87, 0.81, 0.67),
    "Wood": (0.30, 0.20, 0.13),
    "WoodLight": (0.53, 0.38, 0.24),
    "RoofShingle": (0.60, 0.33, 0.24),
    "RoofDark": (0.50, 0.28, 0.20),
    "Stone": (0.60, 0.59, 0.55),
    "StoneDark": (0.44, 0.43, 0.40),
    "Glass": (0.22, 0.29, 0.34),
    "BarnWall": (0.60, 0.45, 0.28),
    "Hay": (0.62, 0.52, 0.26),
    "Thatch": (0.72, 0.62, 0.35),
    "Water": (0.20, 0.36, 0.44),
    "Sign": (0.68, 0.17, 0.15),
}


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _to_gltf(x, y, z):
    return (x, z, -y)


def _rot_xyz(v, rot):
    x, y, z = v
    rx, ry, rz = rot
    cx, sx = math.cos(rx), math.sin(rx)
    y, z = y * cx - z * sx, y * sx + z * cx
    cy, sy = math.cos(ry), math.sin(ry)
    x, z = x * cy + z * sy, -x * sy + z * cy
    cz, sz = math.cos(rz), math.sin(rz)
    x, y = x * cz - y * sz, x * sz + y * cz
    return (x, y, z)


class _Prim:
    def __init__(self):
        self.pos = []
        self.nrm = []
        self.idx = []

    def add(self, a, b, c):
        ga, gb, gc = _to_gltf(*a), _to_gltf(*b), _to_gltf(*c)
        # (x, y, z) -> (x, z, -y) 与这里的面序组合后法线朝外，不再额外翻面
        ux, uy, uz = gb[0] - ga[0], gb[1] - ga[1], gb[2] - ga[2]
        vx, vy, vz = gc[0] - ga[0], gc[1] - ga[1], gc[2] - ga[2]
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        length = math.sqrt(nx * nx + ny * ny + nz * nz)
        if length < 1e-8:
            return
        n = (nx / length, ny / length, nz / length)
        base = len(self.pos)
        for p in (ga, gb, gc):
            self.pos.append(p)
            self.nrm.append(n)
        self.idx.extend((base, base + 1, base + 2))


def _quad(prim, corners):
    prim.add(corners[0], corners[1], corners[2])
    prim.add(corners[0], corners[2], corners[3])


def _add_box(prim, part):
    hx, hy, hz = part["sx"] * 0.5, part["sy"] * 0.5, part["sz"] * 0.5
    rot = part.get("rot", (0.0, 0.0, 0.0))
    loc = part["loc"]
    local = [
        (-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
        (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz),
    ]
    verts = []
    for v in local:
        r = _rot_xyz(v, rot)
        verts.append((r[0] + loc[0], r[1] + loc[1], r[2] + loc[2]))
    faces = (
        (0, 1, 5, 4), (3, 7, 6, 2), (0, 4, 7, 3),
        (1, 2, 6, 5), (4, 5, 6, 7), (0, 3, 2, 1),
    )
    for f in faces:
        _quad(prim, [verts[i] for i in f])


def _add_prism(prim, part):
    hw, hd = part["w"] * 0.5, part["d"] * 0.5
    h, z0 = part["h"], part["z"]
    ox, oy = part.get("loc", (0.0, 0.0))
    co = [
        (-hw + ox, -hd + oy, z0), (hw + ox, -hd + oy, z0),
        (hw + ox, hd + oy, z0), (-hw + ox, hd + oy, z0),
        (ox, -hd + oy, z0 + h), (ox, hd + oy, z0 + h),
    ]
    faces = (
        (0, 3, 5, 4),
        (1, 4, 5, 2),
        (0, 4, 1),
        (3, 2, 5),
        (0, 1, 2, 3),
    )
    for f in faces:
        pts = [co[i] for i in reversed(f)]
        if len(pts) == 4:
            _quad(prim, pts)
        else:
            prim.add(pts[0], pts[1], pts[2])


def _ring(n, radius, y, axis):
    pts = []
    for i in range(n):
        a = math.tau * i / n
        x, z = math.cos(a) * radius, math.sin(a) * radius
        if axis == "Z":
            pts.append((x, z, y))
        elif axis == "Y":
            pts.append((x, y, z))
        else:
            pts.append((y, x, z))
    return pts


def _add_lathe(prim, r0, r1, h, loc, axis, seg, cap=True):
    n = max(int(seg), 3)
    bot = _ring(n, r0, -h * 0.5, axis)
    top = _ring(n, r1, h * 0.5, axis)

    def shift(p):
        return (p[0] + loc[0], p[1] + loc[1], p[2] + loc[2])

    bot = [shift(p) for p in bot]
    top = [shift(p) for p in top]
    for i in range(n):
        j = (i + 1) % n
        prim.add(bot[i], bot[j], top[j])
        prim.add(bot[i], top[j], top[i])
    if not cap:
        return
    center_b = shift((0.0, 0.0, -h * 0.5) if axis == "Z" else (0.0, -h * 0.5, 0.0) if axis == "Y" else (-h * 0.5, 0.0, 0.0))
    center_t = shift((0.0, 0.0, h * 0.5) if axis == "Z" else (0.0, h * 0.5, 0.0) if axis == "Y" else (h * 0.5, 0.0, 0.0))
    for i in range(n):
        j = (i + 1) % n
        prim.add(center_b, bot[j], bot[i])
        prim.add(center_t, top[i], top[j])


def _add_sphere(prim, part):
    r = part["r"]
    loc = part["loc"]
    seg = max(int(part.get("seg", 8)), 3)
    rings = max(int(part.get("rings", 5)), 2)
    sx, sy, sz = part.get("scale", (1.0, 1.0, 1.0))
    rows = []
    for iy in range(rings + 1):
        phi = math.pi * iy / rings
        row = []
        for ix in range(seg):
            theta = math.tau * ix / seg
            x = math.sin(phi) * math.cos(theta) * r * sx
            y = math.sin(phi) * math.sin(theta) * r * sy
            z = math.cos(phi) * r * sz
            row.append((loc[0] + x, loc[1] + y, loc[2] + z))
        rows.append(row)
    for iy in range(rings):
        for ix in range(seg):
            j = (ix + 1) % seg
            a, b = rows[iy][ix], rows[iy][j]
            c, d = rows[iy + 1][ix], rows[iy + 1][j]
            prim.add(a, c, b)
            prim.add(b, c, d)


def build_prims(parts):
    by_mat = {}
    for part in parts:
        prim = by_mat.setdefault(part["mat"], _Prim())
        op = part["op"]
        if op == "box":
            _add_box(prim, part)
        elif op == "prism":
            _add_prism(prim, part)
        elif op == "cyl":
            _add_lathe(prim, part["r"], part["r"], part["h"], part["loc"], part.get("axis", "Z"), part.get("seg", 10))
        elif op == "cone":
            _add_lathe(prim, part["r1"], part["r2"], part["h"], part["loc"], "Z", part.get("seg", 10))
        elif op == "sphere":
            _add_sphere(prim, part)
        else:
            raise ValueError(op)
    return by_mat


def _pack(prims, node_name):
    blob = bytearray()
    views = []
    accessors = []
    materials = []
    primitives = []
    mat_index = {}

    def push(data, target=None):
        while len(blob) % 4:
            blob.append(0)
        offset = len(blob)
        blob.extend(data)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        views.append(view)
        return len(views) - 1

    def accessor(view, count, ctype, atype, mins=None, maxs=None):
        acc = {
            "bufferView": view,
            "componentType": ctype,
            "count": count,
            "type": atype,
        }
        if mins is not None:
            acc["min"] = mins
            acc["max"] = maxs
        accessors.append(acc)
        return len(accessors) - 1

    for key, prim in prims.items():
        if not prim.idx:
            continue
        name = spec.MAT_NAME[key]
        if name not in mat_index:
            rgb = _DISPLAY[name]
            lin = [_srgb_to_linear(c) for c in rgb]
            mat_index[name] = len(materials)
            materials.append({
                "name": name,
                "pbrMetallicRoughness": {
                    "baseColorFactor": [lin[0], lin[1], lin[2], 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.9,
                },
            })
        pos = b"".join(struct.pack("<fff", *p) for p in prim.pos)
        nrm = b"".join(struct.pack("<fff", *n) for n in prim.nrm)
        idx = b"".join(struct.pack("<I", i) for i in prim.idx)
        pv = push(pos, 34962)
        nv = push(nrm, 34962)
        iv = push(idx, 34963)
        xs = [p[0] for p in prim.pos]
        ys = [p[1] for p in prim.pos]
        zs = [p[2] for p in prim.pos]
        primitives.append({
            "attributes": {
                "POSITION": accessor(pv, len(prim.pos), 5126, "VEC3",
                                     [min(xs), min(ys), min(zs)],
                                     [max(xs), max(ys), max(zs)]),
                "NORMAL": accessor(nv, len(prim.nrm), 5126, "VEC3"),
            },
            "indices": accessor(iv, len(prim.idx), 5125, "SCALAR"),
            "material": mat_index[name],
        })

    gltf = {
        "asset": {"version": "2.0", "generator": "fzzc-export-special"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": node_name, "mesh": 0}],
        "meshes": [{"name": node_name, "primitives": primitives}],
        "materials": materials,
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accessors,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    while len(js) % 4:
        js += b" "
    while len(blob) % 4:
        blob.append(0)
    out = bytearray()
    length = 12 + 8 + len(js) + 8 + len(blob)
    out += struct.pack("<4sII", b"glTF", 2, length)
    out += struct.pack("<I4s", len(js), b"JSON")
    out += js
    out += struct.pack("<I4s", len(blob), b"BIN\0")
    out += blob
    return bytes(out)


def write_one(name, parts):
    path = os.path.join(OUT_DIR, name + ".glb")
    data = _pack(build_prims(parts), name)
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    print("EXPORTED", path, len(data))


def main():
    write_one("school", spec.school_parts())
    write_one("pasture", spec.pasture_parts())


if __name__ == "__main__":
    main()

"""学堂与牧场的网格规格。

坐标系与 tools/build_assets.py 一致：Blender Z 轴朝上，门朝 -Y。
1 单位 = 1 米。学堂占地 6×6 米，牧场 4×4 米。

Blender 管线经 build_assets.realize() 读取这里；
没有 Blender 时用 tools/export_special_glb.py 直接写成 glb。
"""


def box(sx, sy, sz, loc, mat, rot=(0.0, 0.0, 0.0)):
    return {"op": "box", "sx": sx, "sy": sy, "sz": sz, "loc": loc, "mat": mat, "rot": rot}


def prism(w, d, h, base_z, mat, loc=(0.0, 0.0)):
    return {"op": "prism", "w": w, "d": d, "h": h, "z": base_z, "mat": mat, "loc": loc}


def cyl(r, h, loc, mat, axis="Z", seg=10):
    return {"op": "cyl", "r": r, "h": h, "loc": loc, "mat": mat, "axis": axis, "seg": seg}


def cone(r1, r2, h, loc, mat, seg=10):
    return {"op": "cone", "r1": r1, "r2": r2, "h": h, "loc": loc, "mat": mat, "seg": seg}


def sphere(r, loc, mat, seg=8, rings=5, scale=(1.0, 1.0, 1.0)):
    return {
        "op": "sphere", "r": r, "loc": loc, "mat": mat,
        "seg": seg, "rings": rings, "scale": scale,
    }


MAT_NAME = {
    "plaster": "Plaster",
    "wood": "Wood",
    "wood_light": "WoodLight",
    "roof": "RoofShingle",
    "roof_dark": "RoofDark",
    "stone": "Stone",
    "stone_dark": "StoneDark",
    "glass": "Glass",
    "barn": "BarnWall",
    "hay": "Hay",
    "thatch": "Thatch",
    "water": "Water",
    "sign": "Sign",
}


def school_parts():
    """带钟亭的木构学堂。钟亭和长窗是轮廓，避免再做成教堂尖塔。"""
    p = []

    def b(*args):
        p.append(box(*args))

    b(5.55, 5.20, 0.30, (0.0, 0.05, 0.15), "stone")
    b(5.35, 5.00, 0.08, (0.0, 0.05, 0.32), "stone_dark")
    b(4.90, 4.30, 2.25, (0.0, 0.10, 1.48), "plaster")
    for sx in (-1, 1):
        for sy in (-1, 1):
            b(0.16, 0.16, 2.32, (sx * 2.38, 0.10 + sy * 2.08, 1.50), "wood")
    for z in (0.62, 1.38, 2.52):
        b(5.05, 0.10, 0.11, (0.0, -2.08, z), "wood")
        b(5.05, 0.10, 0.11, (0.0, 2.28, z), "wood")
        b(0.10, 4.45, 0.11, (-2.48, 0.10, z), "wood")
        b(0.10, 4.45, 0.11, (2.48, 0.10, z), "wood")
    # 正面竖向木筋，把长窗分成教室格子
    for x in (-1.55, 0.0, 1.55):
        b(0.10, 0.12, 1.55, (x, -2.12, 1.42), "wood")

    p.append(prism(5.55, 4.95, 1.55, 2.58, "roof", loc=(0.0, 0.10)))
    b(0.22, 5.05, 0.12, (0.0, 0.10, 4.20), "roof_dark")
    b(5.70, 0.12, 0.16, (0.0, -2.42, 2.52), "wood_light")
    b(5.70, 0.12, 0.16, (0.0, 2.62, 2.52), "wood_light")

    # 屋脊钟亭：矮、开敞、有钟，没有尖塔和十字架
    b(1.15, 1.15, 0.16, (0.0, -0.20, 4.22), "wood")
    for sx in (-1, 1):
        for sy in (-1, 1):
            b(0.10, 0.10, 0.78, (sx * 0.40, -0.20 + sy * 0.40, 4.66), "wood_light")
    p.append(sphere(0.18, (0.0, -0.20, 4.70), "wood_light", seg=8, rings=5, scale=(0.9, 0.9, 1.15)))
    b(0.08, 0.08, 0.42, (0.0, -0.20, 5.05), "wood")
    b(1.05, 0.08, 0.08, (0.0, -0.58, 4.92), "wood")
    b(1.05, 0.08, 0.08, (0.0, 0.18, 4.92), "wood")
    b(0.08, 1.05, 0.08, (-0.52, -0.20, 4.92), "wood")
    b(0.08, 1.05, 0.08, (0.52, -0.20, 4.92), "wood")
    p.append(cone(0.78, 0.02, 0.58, (0.0, -0.20, 5.32), "roof_dark", seg=8))
    p.append(sphere(0.09, (0.0, -0.20, 5.66), "wood_light", seg=6, rings=4))

    b(0.84, 0.10, 1.58, (0.0, -2.18, 1.02), "wood")
    b(0.10, 0.12, 1.70, (-0.48, -2.18, 1.06), "wood_light")
    b(0.10, 0.12, 1.70, (0.48, -2.18, 1.06), "wood_light")
    b(1.06, 0.12, 0.10, (0.0, -2.18, 1.84), "wood_light")
    for x in (-1.45, 1.45):
        b(0.95, 0.08, 0.82, (x, -2.20, 1.50), "glass")
        b(1.08, 0.10, 0.08, (x, -2.18, 1.06), "wood_light")
        b(1.08, 0.10, 0.08, (x, -2.18, 1.92), "wood_light")
    for y in (-0.55, 0.85):
        b(0.08, 0.62, 0.62, (-2.52, y, 1.48), "glass")
        b(0.08, 0.62, 0.62, (2.52, y, 1.48), "glass")

    b(1.55, 0.72, 0.14, (0.0, -2.58, 0.22), "stone")
    for x in (-1.62, 1.62):
        b(0.08, 0.08, 0.40, (x - 0.32, -2.55, 0.28), "wood")
        b(0.08, 0.08, 0.40, (x + 0.32, -2.55, 0.28), "wood")
        b(0.78, 0.28, 0.08, (x, -2.55, 0.48), "wood_light")
        b(0.78, 0.08, 0.22, (x, -2.42, 0.60), "wood")
    b(0.10, 0.10, 1.30, (-2.20, -2.35, 0.82), "wood")
    b(0.82, 0.08, 0.48, (-2.20, -2.44, 1.52), "sign")
    b(0.40, 0.40, 1.05, (1.55, 1.30, 3.50), "stone")
    b(0.52, 0.52, 0.08, (1.55, 1.30, 4.04), "stone_dark")
    return p


def pasture_parts():
    """敞口草料棚 + 围栏羊圈。和采集小屋的茅屋、晾架不是同一轮廓。"""
    p = []

    def b(*args):
        p.append(box(*args))

    b(3.75, 3.75, 0.12, (0.0, 0.05, 0.06), "stone")
    b(3.20, 0.14, 1.50, (0.0, 1.78, 0.88), "barn")
    b(0.14, 2.00, 1.50, (-1.55, 0.82, 0.88), "barn")
    b(0.14, 2.00, 1.50, (1.55, 0.82, 0.88), "barn")
    b(0.16, 0.16, 1.68, (-1.55, -0.16, 0.90), "wood")
    b(0.16, 0.16, 1.68, (1.55, -0.16, 0.90), "wood")
    b(3.30, 0.14, 0.12, (0.0, -0.16, 1.52), "wood_light")
    b(1.35, 1.05, 0.62, (-0.35, 1.05, 0.46), "hay")
    b(0.85, 0.75, 0.42, (0.55, 1.15, 0.90), "hay")
    p.append(prism(3.75, 2.45, 1.00, 1.62, "thatch", loc=(0.0, 0.82)))
    b(0.18, 2.55, 0.10, (0.0, 0.82, 2.66), "wood")

    for x, y in (
        (-1.55, -0.40), (1.55, -0.40),
        (-1.55, -1.70), (1.55, -1.70),
        (-0.55, -1.70), (0.55, -1.70),
    ):
        b(0.10, 0.10, 0.82, (x, y, 0.46), "wood")
    for x in (-1.55, 1.55):
        b(0.08, 1.35, 0.08, (x, -1.05, 0.52), "wood_light")
        b(0.08, 1.35, 0.08, (x, -1.05, 0.74), "wood_light")
    for x in (-1.05, 1.05):
        b(0.85, 0.08, 0.08, (x, -1.70, 0.52), "wood_light")
        b(0.85, 0.08, 0.08, (x, -1.70, 0.74), "wood_light")

    b(0.95, 0.38, 0.22, (0.90, -0.90, 0.22), "wood_light")
    b(0.72, 0.22, 0.06, (0.90, -0.90, 0.32), "water")

    def sheep(x, y, s):
        p.append(sphere(0.26 * s, (x, y, 0.40 * s), "plaster", seg=8, rings=5, scale=(1.15, 1.45, 0.95)))
        p.append(sphere(0.11 * s, (x, y - 0.36 * s, 0.44 * s), "wood", seg=6, rings=4))
        for sx in (-1, 1):
            for sy in (-1, 1):
                b(0.06, 0.06, 0.20, (x + sx * 0.11 * s, y + sy * 0.14 * s, 0.12), "wood")

    sheep(-0.40, -0.95, 1.0)
    sheep(0.40, -1.25, 0.82)
    return p

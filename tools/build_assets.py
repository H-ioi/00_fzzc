"""
放逐之城复刻 · 美术资产生成脚本（Blender 5.0）

用法：
    blender --background --factory-startup --python tools/build_assets.py

环境变量：
    FZ_OUT           导出目录，默认 <仓库>/assets/models
    FZ_SKIP_PREVIEW  设为 1 时跳过合影渲染与 .blend 保存

产出：
    assets/models/house.glb      民居
    assets/models/storage.glb    仓库
    assets/models/woodcutter.glb 伐木场
    assets/models/school.glb     学堂（独立造型，不再复用教堂）
    assets/models/pasture.glb    牧场（敞棚 + 羊圈，不再复用采集小屋）
    assets/models/character.glb  居民（带骨骼与 Walk / Idle 动画）
    tools/preview.png            资产合影预览

约定：
    - 1 Blender 单位 = 1 米
    - 建筑占地与 Godot 侧格子对齐：民居/伐木场 4x4m，仓库 6x6m
    - 建筑正面（门）朝 Blender -Y，导出后在 Godot 里正好朝 +Z（面向镜头）
    - 角色 24fps，Walk 为 24 帧循环
"""

import bpy
import bmesh
import math
import os
import sys
from mathutils import Vector, Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import special_buildings

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
OUT_DIR = os.environ.get("FZ_OUT", os.path.join(ROOT, "assets", "models"))
PREVIEW = os.path.join(ROOT, "tools", "preview.png")
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)

MADE = []  # (name, [objects])


# ----------------------------------------------------------------- 基础工具

def fresh():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _s2l(c):
    """sRGB 显示值 -> 线性值。Blender 的 Base Color 是线性的，直接填 0-1 的显示色会发白。"""
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(name, rgb, rough=0.85, metal=0.0):
    m = bpy.data.materials.get(name)
    if m:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    lin = (_s2l(rgb[0]), _s2l(rgb[1]), _s2l(rgb[2]))
    bsdf = None
    for n in m.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            bsdf = n
            break
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (lin[0], lin[1], lin[2], 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
    m.diffuse_color = (lin[0], lin[1], lin[2], 1.0)
    return m


def _finish(name, bm, material):
    me = bpy.data.meshes.new(name)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def box(name, sx, sy, sz, loc, material, rot=(0.0, 0.0, 0.0)):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= sx
        v.co.y *= sy
        v.co.z *= sz
    if any(rot):
        m = (Matrix.Rotation(rot[2], 3, "Z")
             @ Matrix.Rotation(rot[1], 3, "Y")
             @ Matrix.Rotation(rot[0], 3, "X"))
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=m, verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return _finish(name, bm, material)


def prism(name, w, d, h, base_z, material):
    """人字屋顶：屋脊沿 Y 轴，前后是三角形山墙。"""
    bm = bmesh.new()
    hw, hd = w * 0.5, d * 0.5
    co = [
        (-hw, -hd, 0), (hw, -hd, 0), (hw, hd, 0), (-hw, hd, 0),
        (0, -hd, h), (0, hd, h),
    ]
    vs = [bm.verts.new(c) for c in co]
    bm.verts.ensure_lookup_table()
    faces = [
        (vs[0], vs[3], vs[5], vs[4]),   # 左坡
        (vs[1], vs[4], vs[5], vs[2]),   # 右坡
        (vs[0], vs[4], vs[1]),          # 前山墙
        (vs[3], vs[2], vs[5]),          # 后山墙
        (vs[0], vs[1], vs[2], vs[3]),   # 底
    ]
    for f in faces:
        try:
            bm.faces.new(f)
        except ValueError:
            pass
    for v in bm.verts:
        v.co.z += base_z
    return _finish(name, bm, material)


def cylinder(name, radius, depth, loc, material, axis="Z", segments=8):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                          radius1=radius, radius2=radius, depth=depth)
    if axis == "X":
        bmesh.ops.rotate(bm, cent=(0, 0, 0),
                         matrix=Matrix.Rotation(math.radians(90), 3, "Y"),
                         verts=bm.verts)
    elif axis == "Y":
        bmesh.ops.rotate(bm, cent=(0, 0, 0),
                         matrix=Matrix.Rotation(math.radians(90), 3, "X"),
                         verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return _finish(name, bm, material)


def uvsphere(name, radius, loc, material, seg=8, rings=5, scale=(1.0, 1.0, 1.0)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=max(rings, 3), radius=radius)
    for v in bm.verts:
        v.co.x *= scale[0]
        v.co.y *= scale[1]
        v.co.z *= scale[2]
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return _finish(name, bm, material)


def realize(M, parts, name):
    """把 special_buildings 的规格收成一个物体，和 export_special_glb.py 同一套数据。"""
    objs = []
    for i, part in enumerate(parts):
        material = M[part["mat"]]
        tag = "%s_%d" % (name, i)
        op = part["op"]
        if op == "box":
            objs.append(box(tag, part["sx"], part["sy"], part["sz"], part["loc"], material, part.get("rot", (0.0, 0.0, 0.0))))
        elif op == "prism":
            ob = prism(tag, part["w"], part["d"], part["h"], part["z"], material)
            ox, oy = part.get("loc", (0.0, 0.0))
            for v in ob.data.vertices:
                v.co.x += ox
                v.co.y += oy
            objs.append(ob)
        elif op == "cyl":
            objs.append(cylinder(tag, part["r"], part["h"], part["loc"], material, part.get("axis", "Z"), part.get("seg", 10)))
        elif op == "cone":
            objs.append(cone(tag, part["r1"], part["r2"], part["h"], part["loc"], material, "Z", part.get("seg", 10)))
        elif op == "sphere":
            objs.append(uvsphere(tag, part["r"], part["loc"], material, part.get("seg", 8), part.get("rings", 5), part.get("scale", (1.0, 1.0, 1.0))))
        else:
            raise ValueError(op)
    return join(objs, name)


def cone(name, r1, r2, depth, loc, material, axis="Z", segments=8):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                          radius1=r1, radius2=r2, depth=depth)
    if axis == "X":
        bmesh.ops.rotate(bm, cent=(0, 0, 0),
                         matrix=Matrix.Rotation(math.radians(90), 3, "Y"),
                         verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return _finish(name, bm, material)


def join(objs, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


# ----------------------------------------------------------------- 材质

def build_materials():
    M = {}
    M["plaster"] = mat("Plaster", (0.87, 0.81, 0.67), 0.9)
    M["wood"] = mat("Wood", (0.30, 0.20, 0.13), 0.85)
    M["wood_light"] = mat("WoodLight", (0.53, 0.38, 0.24), 0.85)
    M["roof"] = mat("RoofShingle", (0.44, 0.25, 0.18), 0.8)
    M["roof_dark"] = mat("RoofDark", (0.34, 0.20, 0.15), 0.8)
    M["stone"] = mat("Stone", (0.56, 0.55, 0.51), 0.9)
    M["glass"] = mat("Glass", (0.20, 0.27, 0.32), 0.35)
    M["barn"] = mat("BarnWall", (0.51, 0.38, 0.23), 0.9)
    M["hay"] = mat("Hay", (0.78, 0.68, 0.33), 0.95)
    M["skin"] = mat("Skin", (0.84, 0.66, 0.51), 0.7)
    M["tunic"] = mat("Tunic", (0.40, 0.47, 0.30), 0.9)
    M["pants"] = mat("Pants", (0.33, 0.31, 0.27), 0.9)
    M["boots"] = mat("Boots", (0.22, 0.17, 0.13), 0.85)
    M["thatch"] = mat("Thatch", (0.72, 0.62, 0.35), 0.95)
    M["basket"] = mat("Basket", (0.62, 0.50, 0.30), 0.95)
    M["berry"] = mat("Berry", (0.45, 0.12, 0.14), 0.8)
    M["pelt"] = mat("Pelt", (0.58, 0.44, 0.31), 0.95)
    M["crop"] = mat("Crop", (0.55, 0.62, 0.25), 0.95)
    M["wheat"] = mat("Wheat", (0.80, 0.70, 0.35), 0.95)
    M["stone_dark"] = mat("StoneDark", (0.44, 0.43, 0.40), 0.9)
    M["rope"] = mat("Rope", (0.70, 0.64, 0.50), 0.95)
    M["dirt"] = mat("Dirt", (0.40, 0.32, 0.23), 0.98)
    M["water"] = mat("Water", (0.20, 0.36, 0.44), 0.25, 0.05)
    M["sign"] = mat("Sign", (0.68, 0.17, 0.15), 0.85)
    return M


# ----------------------------------------------------------------- 民居

def build_house_hd(M):
    """高细节民居样板：真实瓦楞、分层窗框、门套、檐口"""
    objs = []
    HW = 1.78          # 半宽
    HD = 1.78
    objs.append(box("plinth", 3.96, 3.96, 0.34, (0, 0, 0.17), M["stone"]))
    objs.append(box("plinth_top", 3.86, 3.86, 0.07, (0, 0, 0.37), M["stone_dark"]))
    # 墙体分三段，避免一整块方盒
    objs.append(box("wall_base", 3.50, 3.50, 0.62, (0, 0, 0.70), M["stone_dark"]))
    objs.append(box("wall_mid", 3.54, 3.54, 1.10, (0, 0, 1.58), M["plaster"]))
    objs.append(box("wall_top", 3.54, 3.54, 0.42, (0, 0, 2.34), M["wood_light"]))
    # 角柱与腰线
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post_%d_%d" % (sx, sy), 0.26, 0.26, 2.55,
                            (sx * 1.70, sy * 1.70, 1.62), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("beam_f_%d" % sy, 3.62, 0.18, 0.20, (0, sy * 1.74, 2.56), M["wood"]))
        objs.append(box("belt_%d" % sy, 3.60, 0.10, 0.12, (0, sy * 1.76, 1.02), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("beam_s_%d" % sx, 0.18, 3.62, 0.20, (sx * 1.74, 0, 2.56), M["wood"]))
        objs.append(box("belt_s_%d" % sx, 0.10, 3.60, 0.12, (sx * 1.76, 0, 1.02), M["wood"]))
    # 屋顶主体
    objs.append(prism("roof_core", 4.40, 4.30, 1.62, 2.66, M["roof_dark"]))
    # 真实瓦楞：两级屋檐上各铺 9 道横向瓦条
    slope = math.atan2(1.62, 2.15)
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            y = sy * (2.15 * (1.0 - t))
            z = 2.66 + 1.62 * t + 0.05
            objs.append(box("tile_%d_%d" % (sy, k), 4.46, 0.30, 0.075,
                            (0, y, z), M["roof"], rot=(sy * -slope, 0, 0)))
    # 檐口与封檐板
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, 4.52, 0.10, 0.22, (0, sy * 2.19, 2.62), M["wood_light"]))
    objs.append(box("ridge_cap", 0.30, 4.36, 0.14, (0, 0, 4.30), M["roof_dark"]))
    objs.append(box("ridge_top", 0.16, 4.40, 0.07, (0, 0, 4.39), M["wood_light"]))
    # 山墙灰泥三角
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.56, 1.60, 2.66, sy * 2.16, M["plaster"]))
    # 门：门套 + 门板 + 门槛 + 台阶
    objs.append(box("door_frame_l", 0.13, 0.14, 1.90, (-0.52, -1.80, 1.02), M["wood_light"]))
    objs.append(box("door_frame_r", 0.13, 0.14, 1.90, (0.52, -1.80, 1.02), M["wood_light"]))
    objs.append(box("door_frame_t", 1.16, 0.14, 0.14, (0, -1.80, 1.98), M["wood_light"]))
    # 门头雨棚
    objs.append(box("awning_board", float(0.90) + 0.30, 0.46, 0.07,
                    (0, float(-1.74) - 0.18, float(0.94) + float(1.82) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(0.90) * 0.5 + 0.06), float(-1.74) - 0.34, float(0.94) + float(1.82) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.90, 0.10, 1.82, (0, -1.74, 0.94), M["wood"]))
    objs.append(box("door_plank1", 0.06, 0.04, 1.70, (-0.24, -1.68, 0.94), M["wood_light"]))
    objs.append(box("door_plank2", 0.06, 0.04, 1.70, (0.24, -1.68, 0.94), M["wood_light"]))
    objs.append(box("knob", 0.08, 0.08, 0.08, (0.32, -1.66, 0.98), M["stone"]))
    objs.append(box("threshold", 1.34, 0.30, 0.10, (0, -1.92, 0.42), M["stone"]))
    objs.append(box("step1", 1.50, 0.44, 0.12, (0, -2.14, 0.30), M["stone_dark"]))
    objs.append(box("step2", 1.66, 0.30, 0.10, (0, -2.42, 0.17), M["stone_dark"]))
    # 窗：外框 + 内框 + 玻璃 + 窗台 + 百叶
    for sx in (-1, 1):
        x = sx * 1.05
        objs.append(box("win_outer", 0.86, 0.10, 0.80, (x, -1.79, 1.62), M["wood_light"]))
        objs.append(box("win_inner", 0.70, 0.12, 0.64, (x, -1.76, 1.62), M["wood"]))
        # 窗框
        objs.append(box("win_frame", float(0.58) + 0.13, float(0.10) + 0.13, float(0.52) * 0.75,
                        (x, -1.74, 1.62), M["wood_light"]))
        objs.append(box("win_glass", 0.58, 0.10, 0.52, (x, -1.74, 1.62), M["glass"]))
        objs.append(box("win_mull_v", 0.05, 0.06, 0.52, (x, -1.72, 1.62), M["wood_light"]))
        objs.append(box("win_mull_h", 0.58, 0.06, 0.05, (x, -1.72, 1.62), M["wood_light"]))
        objs.append(box("win_sill", 0.94, 0.22, 0.09, (x, -1.83, 1.20), M["wood_light"]))
        objs.append(box("shutter_l", 0.12, 0.09, 0.72, (x - 0.47, -1.78, 1.62), M["wood"]))
        objs.append(box("shutter_r", 0.12, 0.09, 0.72, (x + 0.47, -1.78, 1.62), M["wood"]))
        objs.append(box("winbox", 0.80, 0.24, 0.18, (x, -1.86, 1.06), M["wood_light"]))
        for k in range(3):
            objs.append(box("bloom_%d" % k, 0.15, 0.15, 0.15,
                            (x - 0.22 + k * 0.22, -1.86, 1.18),
                            M["sign"] if k == 1 else M["berry"]))
        # 侧窗
        objs.append(box("win_s_outer", 0.10, 0.80, 0.74, (sx * 1.80, 0.45, 1.62), M["wood_light"]))
        # 窗框
        objs.append(box("win_frame", float(0.10) + 0.13, float(0.60) + 0.13, float(0.56) * 0.75,
                        (sx * 1.78, 0.45, 1.62), M["wood_light"]))
        objs.append(box("win_s_glass", 0.10, 0.60, 0.56, (sx * 1.78, 0.45, 1.62), M["glass"]))
    # 烟囱（带顶帽）
    objs.append(box("chimney", 0.54, 0.54, 1.30, (1.12, 0.95, 3.30), M["stone"]))
    objs.append(box("chimney_cap", 0.66, 0.66, 0.10, (1.12, 0.95, 3.98), M["stone_dark"]))
    objs.append(box("chimney_pot", 0.30, 0.30, 0.26, (1.12, 0.95, 4.14), M["stone_dark"]))
    return join(objs, "house_hd")


def build_house(M):
    objs = []
    objs.append(box("foundation", 3.9, 3.9, 0.34, (0, 0, 0.17), M["stone"]))
    objs.append(box("skirt_band", float(3.5) + 0.14, float(3.5) + 0.14, 0.20,
                    (0, 0, float(1.35) - float(2.05) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.05),
                            (float(0) + csx * (float(3.5) * 0.5 - 0.06), float(0) + csy * (float(3.5) * 0.5 - 0.06), 1.35), M["wood"]))
    objs.append(box("wall", 3.5, 3.5, 2.05, (0, 0, 1.35), M["plaster"]))

    # 木框架：四角立柱 + 顶部横梁
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.24, 0.24, 2.05, (sx * 1.72, sy * 1.72, 1.35), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("beam_f", 3.6, 0.16, 0.18, (0, sy * 1.76, 2.28), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("beam_s", 0.16, 3.6, 0.18, (sx * 1.76, 0, 2.28), M["wood"]))
        objs.append(box("beam_m", 0.14, 3.6, 0.14, (sx * 1.76, 0, 0.55), M["wood"]))

    # 屋顶（含山墙）
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(4.35) + 0.10, 0.09, 0.20,
                        (0, sy * (float(4.25) * 0.5 + 0.03), float(2.36) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(4.35) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(4.25) * 0.5 + 0.03), (float(2.36) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 4.35, 4.25, 1.55, 2.36, M["roof"]))
    # 瓦楞：沿坡面 8 级台阶（水平薄板叠放，不做旋转）
    for sy in (-1, 1):
        for k in range(8):
            t = (k + 0.5) / 8.0
            yy = sy * (2.125 * (1.0 - t))
            zz = 2.36 + 1.55 * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), 4.38, 0.30, 0.055,
                            (0, yy, zz), M["roof_dark"]))
    # 屋脊压顶
    objs.append(box("ridge_cap", 0.24, 4.30, 0.13, (0, 0, 3.95), M["roof_dark"]))
    # 前坡老虎窗
    objs.append(box("dormer", 1.00, 1.05, 0.86, (0.05, -1.02, 3.56), M["plaster"]))
    objs.append(prism("dormer_roof", 1.22, 1.12, 0.40, 3.99, M["roof_dark"]))
    objs.append(box("dormer_win", 0.52, 0.08, 0.46, (0.05, -1.56, 3.52), M["glass"]))
    objs.append(box("dormer_sill", 0.62, 0.12, 0.07, (0.05, -1.58, 3.28), M["wood_light"]))
    # 山墙外贴一层灰泥三角（贴在屋顶山墙面外侧，避免被屋顶遮住）
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.52, 1.53, 2.36, sy * 2.15, M["plaster"]))

    # 门
    # 门头雨棚
    objs.append(box("awning_board", float(0.82) + 0.30, 0.46, 0.07,
                    (0, float(-1.78) - 0.18, float(0.88) + float(1.72) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(0.82) * 0.5 + 0.06), float(-1.78) - 0.34, float(0.88) + float(1.72) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.82, 0.10, 1.72, (0, -1.78, 0.88), M["wood"]))
    objs.append(box("door_frame_l", 0.10, 0.12, 1.80, (-0.46, -1.78, 0.92), M["wood_light"]))
    objs.append(box("door_frame_r", 0.10, 0.12, 1.80, (0.46, -1.78, 0.92), M["wood_light"]))
    objs.append(box("door_frame_t", 1.02, 0.12, 0.10, (0, -1.78, 1.82), M["wood_light"]))

    # 窗（带窗台与百叶）
    for sx in (-1, 1):
        x = sx * 1.05
        # 窗框
        objs.append(box("win_frame", float(0.66) + 0.13, float(0.08) + 0.13, float(0.62) * 0.75,
                        (x, -1.77, 1.55), M["wood_light"]))
        objs.append(box("win", 0.66, 0.08, 0.62, (x, -1.77, 1.55), M["glass"]))
        objs.append(box("win_sill", 0.80, 0.14, 0.08, (x, -1.77, 1.22), M["wood_light"]))
        objs.append(box("shutter_l", 0.10, 0.07, 0.64, (x - 0.40, -1.78, 1.55), M["wood"]))
        objs.append(box("shutter_r", 0.10, 0.07, 0.64, (x + 0.40, -1.78, 1.55), M["wood"]))
        # 窗台花箱
        objs.append(box("winbox", 0.78, 0.24, 0.20, (x, -1.86, 1.06), M["wood_light"]))
        for k in range(3):
            objs.append(box("bloom_%d" % k, 0.16, 0.16, 0.16,
                            (x - 0.22 + k * 0.22, -1.86, 1.19),
                            M["sign"] if k == 1 else M["berry"]))
        # 侧窗
        # 窗框
        objs.append(box("win_frame", float(0.08) + 0.13, float(0.62) + 0.13, float(0.58) * 0.75,
                        (sx * 1.77, 0.4, 1.55), M["wood_light"]))
        objs.append(box("win_s", 0.08, 0.62, 0.58, (sx * 1.77, 0.4, 1.55), M["glass"]))

    # 烟囱
    objs.append(box("chimney", 0.52, 0.52, 1.25, (1.10, 0.95, 3.10), M["stone"]))
    objs.append(box("chimney_cap", 0.62, 0.62, 0.10, (1.10, 0.95, 3.72), M["stone"]))

    # 山墙上的阁楼小窗
    objs.append(box("gable_win", 0.52, 0.07, 0.42, (0.0, -2.28, 3.05), M["glass"]))
    objs.append(box("gable_win_sill", 0.64, 0.12, 0.08, (0.0, -2.29, 2.80), M["wood_light"]))
    objs.append(box("gable_beam", 3.52, 0.10, 0.12, (0.0, -2.28, 2.62), M["wood"]))

    add_house_trim(objs, 4.35, 4.25, 2.36, M, -1.95)
    return join(objs, "house")

def _gable(name, w, h, base_z, y, material):
    """薄三棱柱，双面可见（单面片会被背面剔除掉）。"""
    ob = prism(name, w, 0.16, h, base_z, material)
    ob.location.y = y
    return ob


# ----------------------------------------------------------------- 仓库

def build_storage(M):
    objs = []
    objs.append(box("foundation", 5.9, 5.9, 0.40, (0, 0, 0.20), M["stone"]))
    objs.append(box("skirt_band", float(5.5) + 0.14, float(5.5) + 0.14, 0.20,
                    (0, 0, float(1.75) - float(2.70) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.70),
                            (float(0) + csx * (float(5.5) * 0.5 - 0.06), float(0) + csy * (float(5.5) * 0.5 - 0.06), 1.75), M["wood"]))
    objs.append(box("wall", 5.5, 5.5, 2.70, (0, 0, 1.75), M["barn"]))

    # 竖向木板纹理感：几条深色竖梁
    for i in range(-2, 3):
        objs.append(box("plank_beam", 0.12, 0.06, 2.70, (i * 1.05, -2.77, 1.75), M["wood"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("corner", 0.28, 0.28, 2.70, (sx * 2.68, sy * 2.68, 1.75), M["wood"]))

    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(6.30) + 0.10, 0.09, 0.20,
                        (0, sy * (float(6.10) * 0.5 + 0.03), float(3.10) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(6.30) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(6.10) * 0.5 + 0.03), (float(3.10) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 6.30, 6.10, 1.75, 3.10, M["roof_dark"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(6.10) * 0.5 * (1.0 - t))
            zz = float(3.10) + float(1.75) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(6.30) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    # 山墙气窗（百叶）
    objs.append(box("vent_frame", 1.10, 0.14, 0.86, (0, -3.12, 3.86), M["wood"]))
    for k in range(4):
        objs.append(box("louver_%d" % k, 0.94, 0.06, 0.12, (0, -3.20, 3.56 + k * 0.20), M["wood_light"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 5.52, 1.72, 3.10, sy * 3.07, M["barn"]))

    # 大门
    objs.append(box("door_l", 1.10, 0.12, 2.10, (-0.56, -2.79, 1.35), M["wood_light"]))
    objs.append(box("door_r", 1.10, 0.12, 2.10, (0.56, -2.79, 1.35), M["wood_light"]))
    objs.append(box("door_beam", 2.50, 0.14, 0.16, (0, -2.80, 2.48), M["wood"]))
    objs.append(box("door_brace", 0.14, 0.06, 2.2, (0, -2.86, 1.35), M["wood"]))

    # 阁楼窗
    objs.append(box("loft", 0.90, 0.10, 0.70, (0, -2.77, 3.55), M["glass"]))
    objs.append(box("loft_t", 1.05, 0.12, 0.10, (0, -2.79, 3.20), M["wood"]))

    # 侧边草垛 / 木桶（必须留在 6x6 占地内）
    objs.append(box("haystack", 1.10, 1.10, 0.80, (2.05, 1.90, 0.40), M["hay"]))
    objs.append(box("barrel", 0.52, 0.52, 0.78, (-2.20, 2.00, 0.39), M["wood_light"]))

    # 山墙外侧的吊装横梁
    objs.append(box("hoist_beam", 0.18, 1.55, 0.18, (0, -3.62, 4.30), M["wood"]))
    objs.append(box("hoist_rope", 0.04, 0.04, 0.95, (0, -4.32, 3.75), M["rope"]))
    objs.append(box("hoist_block", 0.30, 0.30, 0.26, (0, -4.32, 3.20), M["wood_light"]))
    objs.append(box("hoist_brace", 0.14, 0.90, 0.14, (0, -3.05, 4.05), M["wood"],
                    rot=(math.radians(-32), 0, 0)))
    # 阁楼货门
    objs.append(box("loft_door", 1.24, 0.10, 1.30, (0, -3.12, 3.45), M["wood"]))
    objs.append(box("loft_frame_l", 0.10, 0.12, 1.40, (-0.68, -3.13, 3.45), M["wood_light"]))
    objs.append(box("loft_frame_r", 0.10, 0.12, 1.40, (0.68, -3.13, 3.45), M["wood_light"]))
    objs.append(box("loft_frame_t", 1.46, 0.12, 0.10, (0, -3.13, 4.15), M["wood_light"]))

    # 钟楼（放在屋顶后侧角落，避免挡住正面轮廓）
    objs.append(box("tower", 0.90, 0.90, 2.10, (-2.05, 1.95, 3.75), M["wood_light"]))
    objs.append(box("tower_band", 1.02, 1.02, 0.12, (-2.05, 1.95, 4.78), M["wood"]))
    objs.append(prism("tower_roof", 1.30, 1.30, 0.92, 4.84, M["roof_dark"]))
    objs.append(box("clock_face", 0.46, 0.06, 0.46, (-2.05, 1.48, 4.30), M["glass"]))
    objs.append(box("clock_rim", 0.55, 0.05, 0.55, (-2.05, 1.51, 4.30), M["wood"]))

    add_house_trim(objs, 6.30, 6.10, 3.10, M, -2.98)
    return join(objs, "storage")


# ----------------------------------------------------------------- 伐木场

def build_woodcutter(M):
    objs = []
    # 后墙与侧墙（敞开式工棚）
    objs.append(box("back_wall", 3.8, 0.20, 2.0, (0, 1.7, 1.0), M["barn"]))
    objs.append(box("side_l", 0.20, 3.6, 2.0, (-1.8, 0, 1.0), M["barn"]))
    objs.append(box("side_r", 0.20, 1.2, 2.0, (1.8, -1.2, 1.0), M["barn"]))

    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.22, 0.22, 2.15, (sx * 1.82, sy * 1.82, 1.07), M["wood"]))

    # 人字屋顶（平屋顶从俯视角看就是一块悬空的板，必须给山墙）
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(4.30) + 0.10, 0.09, 0.20,
                        (0, sy * (float(4.20) * 0.5 + 0.03), float(2.05) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(4.30) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(4.20) * 0.5 + 0.03), (float(2.05) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 4.30, 4.20, 1.20, 2.05, M["roof"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(4.20) * 0.5 * (1.0 - t))
            zz = float(2.05) + float(1.20) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(4.30) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.90, 1.18, 2.05, sy * 2.11, M["barn"]))

    # 原木堆
    for i, (z, y) in enumerate([(0.22, 1.05), (0.62, 0.80), (0.62, 1.30), (1.00, 1.05)]):
        objs.append(cylinder("log_%d" % i, 0.20, 3.2, (0, y, z), M["wood_light"], axis="X"))

    # 砧木 + 斧头
    objs.append(cylinder("stump", 0.38, 0.55, (-1.3, -1.2, 0.27), M["wood"], axis="Z", segments=10))
    objs.append(box("axe_handle", 0.06, 0.06, 0.62, (-1.3, -1.2, 0.82), M["wood_light"]))
    objs.append(box("axe_head", 0.10, 0.26, 0.14, (-1.3, -1.32, 1.10), M["stone"]))

    # 木屑堆
    objs.append(box("chips", 0.9, 0.9, 0.16, (-1.3, -1.2, 0.08), M["hay"]))

    return join(objs, "woodcutter")


# ----------------------------------------------------------------- 采集小屋

def build_gatherer(M):
    objs = []
    # 小屋（偏移到左侧，右侧留给晾架和篮子）
    objs.append(box("hut", 2.40, 2.40, 1.85, (-0.75, 0.70, 0.92), M["wood_light"]))
    objs.append(box("hut_base", 2.55, 2.55, 0.18, (-0.75, 0.70, 0.09), M["stone"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(2.95) + 0.10, 0.09, 0.20,
                        (0, sy * (float(2.95) * 0.5 + 0.03), float(1.85) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(2.95) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(2.95) * 0.5 + 0.03), (float(1.85) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 2.95, 2.95, 1.00, 1.85, M["thatch"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(2.95) * 0.5 * (1.0 - t))
            zz = float(1.85) + float(1.00) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(2.95) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    # 门头雨棚
    objs.append(box("awning_board", float(0.68) + 0.30, 0.46, 0.07,
                    (-0.75, float(-0.48) - 0.18, float(0.66) + float(1.30) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(-0.75) + sx * (float(0.68) * 0.5 + 0.06), float(-0.48) - 0.34, float(0.66) + float(1.30) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.68, 0.08, 1.30, (-0.75, -0.48, 0.66), M["wood"]))
    # 窗框
    objs.append(box("win_frame", float(0.42) + 0.13, float(0.07) + 0.13, float(0.36) * 0.75,
                    (-0.20, -0.48, 1.25), M["wood_light"]))
    objs.append(box("win", 0.42, 0.07, 0.36, (-0.20, -0.48, 1.25), M["glass"]))
    # 屋檐下的横杆
    objs.append(box("eave", 3.05, 0.10, 0.10, (-0.75, -1.48, 1.85), M["wood"]))

    # 晾晒架
    for sx in (-0.55, 0.55):
        objs.append(box("rack_post", 0.10, 0.10, 1.55, (1.25 + sx, 1.10, 0.78), M["wood"]))
    for i, z in enumerate((0.55, 0.95, 1.35)):
        objs.append(box("rack_bar", 1.30, 0.07, 0.07, (1.25, 1.10, z), M["wood_light"]))
        objs.append(box("herb_%d" % i, 0.16, 0.06, 0.30, (1.25 - 0.25 + i * 0.22, 1.10, z - 0.20), M["berry"]))

    # 篮子
    objs.append(box("basket_a", 0.42, 0.42, 0.34, (1.55, -0.55, 0.17), M["basket"]))
    objs.append(box("basket_b", 0.34, 0.34, 0.28, (1.05, -1.05, 0.14), M["basket"]))
    objs.append(box("basket_c", 0.38, 0.38, 0.30, (1.75, 0.15, 0.15), M["basket"]))

    # 浆果丛
    for i, (bx, by) in enumerate(((-1.55, -1.35), (-0.95, -1.65), (-1.35, -0.70))):
        objs.append(box("bush_%d" % i, 0.46, 0.46, 0.42, (bx, by, 0.21), M["crop"]))
        objs.append(box("berry_%d" % i, 0.12, 0.12, 0.12, (bx + 0.10, by + 0.12, 0.42), M["berry"]))

    return join(objs, "gatherer")


# ----------------------------------------------------------------- 猎人小屋

def build_hunter(M):
    objs = []
    # 原木小屋
    objs.append(box("cabin", 2.45, 2.35, 1.75, (-0.70, 0.85, 0.88), M["barn"]))
    objs.append(box("cabin_base", 2.60, 2.50, 0.16, (-0.70, 0.85, 0.08), M["stone"]))
    # 横向原木纹理
    for i in range(4):
        objs.append(box("log_line_%d" % i, 2.52, 0.06, 0.10, (-0.70, 0.85 - 1.19, 0.26 + i * 0.42), M["wood"]))
        objs.append(box("log_side_%d" % i, 0.06, 2.42, 0.10, (-0.70 + 1.24, 0.85, 0.26 + i * 0.42), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(2.95) + 0.10, 0.09, 0.20,
                        (0, sy * (float(2.85) * 0.5 + 0.03), float(1.75) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(2.95) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(2.85) * 0.5 + 0.03), (float(1.75) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 2.95, 2.85, 1.05, 1.75, M["roof_dark"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(2.85) * 0.5 * (1.0 - t))
            zz = float(1.75) + float(1.05) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(2.95) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    # 门头雨棚
    objs.append(box("awning_board", float(0.70) + 0.30, 0.46, 0.07,
                    (-0.70, float(-0.33) - 0.18, float(0.68) + float(1.35) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(-0.70) + sx * (float(0.70) * 0.5 + 0.06), float(-0.33) - 0.34, float(0.68) + float(1.35) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.70, 0.08, 1.35, (-0.70, -0.33, 0.68), M["wood_light"]))
    # 鹿角装饰
    for sx in (-0.28, 0.28):
        objs.append(box("antler_%d" % int(sx * 100), 0.06, 0.06, 0.42,
                        (-0.70 + sx, -0.36, 1.62), M["wood_light"],
                        rot=(math.radians(18), 0, math.radians(-sx * 80))))
    # 兽皮晾架
    for sx in (-0.45, 0.45):
        objs.append(box("pelt_post", 0.09, 0.09, 1.45, (1.35 + sx, 1.30, 0.73), M["wood"]))
    objs.append(box("pelt_bar", 1.20, 0.07, 0.07, (1.35, 1.30, 1.42), M["wood_light"]))
    objs.append(box("pelt_a", 0.44, 0.05, 0.78, (1.10, 1.30, 1.02), M["pelt"]))
    objs.append(box("pelt_b", 0.38, 0.05, 0.66, (1.62, 1.30, 1.08), M["pelt"]))
    # 栅栏与木桶
    for i in range(3):
        objs.append(box("fence_post_%d" % i, 0.08, 0.08, 0.85, (0.55 + i * 0.55, -1.55, 0.42), M["wood"]))
    objs.append(box("fence_rail", 1.65, 0.06, 0.08, (1.10, -1.55, 0.66), M["wood_light"]))
    objs.append(box("barrel", 0.44, 0.44, 0.62, (-1.65, -1.35, 0.31), M["wood_light"]))

    return join(objs, "hunter")


# ----------------------------------------------------------------- 农田

def build_farm(M):
    objs = []
    # 地块 10x10
    objs.append(box("soil", 9.70, 9.70, 0.20, (0, 0, 0.10), M["barn"]))
    # 垄（沿 X 方向的条带）
    rows = 8
    for r in range(rows):
        y = -4.0 + r * (8.0 / (rows - 1))
        objs.append(box("ridge_%d" % r, 9.10, 0.55, 0.10, (0, y, 0.22), M["wood_light"]))
        # 作物
        for c in range(7):
            x = -3.9 + c * 1.30
            h = 0.30 + 0.10 * ((r + c) % 3)
            objs.append(box("crop_%d_%d" % (r, c), 0.75, 0.42, h, (x, y, 0.22 + h * 0.5),
                            M["wheat"] if r % 2 == 0 else M["crop"]))

    # 围栏
    for i in range(6):
        t = -4.8 + i * 1.92
        objs.append(box("fence_ns_%d" % i, 0.10, 0.10, 0.90, (-4.85, t, 0.45), M["wood"]))
        objs.append(box("fence_ns2_%d" % i, 0.10, 0.10, 0.90, (4.85, t, 0.45), M["wood"]))
        objs.append(box("fence_ew_%d" % i, 0.10, 0.10, 0.90, (t, -4.85, 0.45), M["wood"]))
        objs.append(box("fence_ew2_%d" % i, 0.10, 0.10, 0.90, (t, 4.85, 0.45), M["wood"]))
    objs.append(box("rail_n", 9.80, 0.06, 0.07, (0, -4.85, 0.68), M["wood_light"]))
    objs.append(box("rail_s", 9.80, 0.06, 0.07, (0, 4.85, 0.68), M["wood_light"]))
    objs.append(box("rail_w", 0.06, 9.80, 0.07, (-4.85, 0, 0.68), M["wood_light"]))
    objs.append(box("rail_e", 0.06, 9.80, 0.07, (4.85, 0, 0.68), M["wood_light"]))

    # 稻草人
    objs.append(box("sc_pole", 0.09, 0.09, 2.20, (-2.2, 1.2, 1.10), M["wood"]))
    objs.append(box("sc_arm", 1.10, 0.09, 0.09, (-2.2, 1.2, 1.65), M["wood"]))
    objs.append(box("sc_body", 0.52, 0.26, 0.62, (-2.2, 1.2, 1.42), M["thatch"]))
    objs.append(box("sc_head", 0.30, 0.30, 0.30, (-2.2, 1.2, 1.95), M["thatch"]))
    objs.append(box("sc_hat", 0.44, 0.44, 0.06, (-2.2, 1.2, 2.13), M["wood_light"]))

    return join(objs, "farm")


# ----------------------------------------------------------------- 柴火棚

def build_firewood(M):
    objs = []
    # 背墙 + 侧墙，朝 -Y 敞开
    objs.append(box("back", 3.70, 0.18, 1.95, (0, 1.70, 0.97), M["barn"]))
    objs.append(box("side_l", 0.18, 3.50, 1.95, (-1.76, 0, 0.97), M["barn"]))
    objs.append(box("side_r", 0.18, 3.50, 1.95, (1.76, 0, 0.97), M["barn"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.18, 0.18, 2.05, (sx * 1.80, sy * 1.80, 1.02), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(4.30) + 0.10, 0.09, 0.20,
                        (0, sy * (float(4.20) * 0.5 + 0.03), float(2.05) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(4.30) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(4.20) * 0.5 + 0.03), (float(2.05) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 4.30, 4.20, 1.20, 2.05, M["roof_dark"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(4.20) * 0.5 * (1.0 - t))
            zz = float(2.05) + float(1.20) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(4.30) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.85, 1.18, 2.05, sy * 2.11, M["barn"]))

    # 柴堆：交错码放的木段
    layers = 5
    for l in range(layers):
        z = 0.20 + l * 0.24
        for i in range(6):
            x = -1.30 + i * 0.46 + (0.23 if l % 2 else 0.0)
            objs.append(cylinder("log_%d_%d" % (l, i), 0.11, 0.42, (x, 0.35, z),
                                 M["wood_light"], axis="Y", segments=6))

    # 砧木与斧头
    objs.append(cylinder("stump", 0.34, 0.50, (1.15, -1.15, 0.25), M["wood"], axis="Z", segments=10))
    objs.append(box("axe_handle", 0.05, 0.05, 0.58, (1.15, -1.15, 0.75), M["wood_light"]))
    objs.append(box("axe_head", 0.09, 0.24, 0.13, (1.15, -1.26, 1.02), M["stone"]))

    # 锯木架
    objs.append(box("sawhorse", 1.05, 0.12, 0.12, (-1.10, -1.25, 0.52), M["wood_light"]))
    for sx in (-0.42, 0.42):
        objs.append(box("leg", 0.10, 0.10, 0.52, (-1.10 + sx, -1.25, 0.26), M["wood"],
                        rot=(0, math.radians(14 * (1 if sx > 0 else -1)), 0)))

    return join(objs, "firewood")


# ----------------------------------------------------------------- 采石场

def build_quarry(M):
    objs = []
    # 石料场地
    objs.append(box("ground", 3.85, 3.85, 0.10, (0, 0, 0.05), M["dirt"]))

    # 切好的石料堆
    for i in range(3):
        for j in range(3 - i):
            objs.append(box("block_%d_%d" % (i, j), 0.72, 0.60, 0.44,
                            (-1.15 + i * 0.76, 0.65 + j * 0.66, 0.34 + i * 0.46), M["stone"]))

    # 毛石堆
    rubble = [(-1.35, -1.25, 0.22, 0.55, 0.35), (-0.95, -1.55, 0.18, 0.42, 0.28),
              (-1.55, -0.85, 0.16, 0.38, 0.26), (0.15, -1.45, 0.20, 0.50, 0.32)]
    for i, (x, y, z, w, h) in enumerate(rubble):
        objs.append(box("rubble_%d" % i, w, w * 0.85, h, (x, y, z), M["stone"],
                        rot=(0, math.radians(17 * (i + 1)), 0)))

    # 木制吊架
    objs.append(box("derrick_l", 0.14, 0.14, 2.60, (-0.95, 1.55, 1.30), M["wood"],
                    rot=(0, 0, math.radians(11))))
    objs.append(box("derrick_r", 0.14, 0.14, 2.60, (-0.35, 1.55, 1.30), M["wood"],
                    rot=(0, 0, math.radians(-11))))
    objs.append(box("derrick_top", 0.90, 0.16, 0.16, (-0.65, 1.55, 2.52), M["wood"]))
    objs.append(box("rope", 0.04, 0.04, 1.30, (-0.65, 1.55, 1.85), M["rope"]))
    objs.append(box("hook_load", 0.46, 0.42, 0.34, (-0.65, 1.55, 1.10), M["stone"]))

    # 手推车
    objs.append(box("cart", 1.05, 0.62, 0.30, (1.05, -0.95, 0.48), M["wood_light"]))
    for sx in (-0.42, 0.42):
        objs.append(cylinder("wheel", 0.24, 0.10, (1.05 + sx, -0.95, 0.30),
                             M["wood"], axis="X", segments=10))

    # 靠着的镐头
    objs.append(box("pick_handle", 0.05, 0.05, 0.90, (1.55, 1.35, 0.50), M["wood_light"],
                    rot=(math.radians(12), 0, 0)))
    objs.append(box("pick_head", 0.10, 0.42, 0.10, (1.55, 1.30, 0.92), M["stone"]))

    return join(objs, "quarry")


# ----------------------------------------------------------------- 水井

def build_well(M):
    objs = []
    objs.append(cylinder("ring", 1.28, 0.95, (0, 0, 0.475), M["stone"], axis="Z", segments=12))
    objs.append(cylinder("water", 1.02, 0.05, (0, 0, 0.94), M["water"], axis="Z", segments=12))
    for sx in (-1, 1):
        objs.append(box("post", 0.14, 0.14, 2.30, (sx * 0.95, 0, 1.15), M["wood"]))
    objs.append(box("beam", 2.10, 0.14, 0.14, (0, 0, 2.28), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(2.45) + 0.10, 0.09, 0.20,
                        (0, sy * (float(1.95) * 0.5 + 0.03), float(2.36) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(2.45) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(1.95) * 0.5 + 0.03), (float(2.36) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 2.45, 1.95, 0.55, 2.36, M["roof_dark"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(1.95) * 0.5 * (1.0 - t))
            zz = float(2.36) + float(0.55) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(2.45) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    objs.append(box("rope", 0.05, 0.05, 0.85, (0, 0, 1.85), M["rope"]))
    objs.append(box("bucket", 0.30, 0.30, 0.30, (0, 0, 1.30), M["wood_light"]))
    objs.append(box("bucket_band", 0.34, 0.04, 0.30, (0, 0, 1.30), M["wood"]))
    return join(objs, "well")


# ----------------------------------------------------------------- 医院

def build_hospital(M):
    objs = []
    objs.append(box("base", 5.70, 5.70, 0.36, (0, 0, 0.18), M["stone"]))
    objs.append(box("skirt_band", float(5.30) + 0.14, float(5.30) + 0.14, 0.20,
                    (0, 0, float(1.71) - float(2.70) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.70),
                            (float(0) + csx * (float(5.30) * 0.5 - 0.06), float(0) + csy * (float(5.30) * 0.5 - 0.06), 1.71), M["wood"]))
    objs.append(box("wall", 5.30, 5.30, 2.70, (0, 0, 1.71), M["plaster"]))

    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.26, 0.26, 2.70, (sx * 2.55, sy * 2.55, 1.71), M["wood"]))

    for sy in (-1, 1):
        objs.append(box("beam", 5.36, 0.16, 0.18, (0, sy * 2.60, 2.92), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("beam_s", 0.16, 5.36, 0.18, (sx * 2.60, 0, 2.92), M["wood"]))

    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(6.20) + 0.10, 0.09, 0.20,
                        (0, sy * (float(6.00) * 0.5 + 0.03), float(3.06) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(6.20) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(6.00) * 0.5 + 0.03), (float(3.06) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 6.20, 6.00, 1.60, 3.06, M["roof"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(6.00) * 0.5 * (1.0 - t))
            zz = float(3.06) + float(1.60) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(6.20) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 5.30, 1.58, 3.06, sy * 3.02, M["plaster"]))

    # 门与红色十字
    # 门头雨棚
    objs.append(box("awning_board", float(1.10) + 0.30, 0.46, 0.07,
                    (0, float(-2.66) - 0.18, float(1.00) + float(2.00) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(1.10) * 0.5 + 0.06), float(-2.66) - 0.34, float(1.00) + float(2.00) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 1.10, 0.10, 2.00, (0, -2.66, 1.00), M["wood"]))
    objs.append(box("cross_v", 0.24, 0.07, 0.86, (0, -3.12, 3.95), M["sign"]))
    objs.append(box("cross_h", 0.78, 0.07, 0.24, (0, -3.12, 3.95), M["sign"]))

    # 屋脊钟亭
    objs.append(box("cupola", 0.98, 0.98, 1.15, (0, 0.20, 4.88), M["plaster"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("cup_post_%d_%d" % (sx, sy), 0.10, 0.10, 1.15,
                            (sx * 0.44, 0.20 + sy * 0.44, 4.88), M["wood"]))
    objs.append(box("cup_band", 1.16, 1.16, 0.14, (0, 0.20, 5.50), M["wood"]))
    objs.append(cone("cup_roof", 1.24, 0.02, 0.92, (0, 0.20, 6.03), M["roof"], segments=6))
    objs.append(box("cup_cross_v", 0.09, 0.09, 0.62, (0, 0.20, 6.72), M["wood_light"]))

    # 侧窗与正窗
    for sx in (-1, 1):
        # 窗框
        objs.append(box("win_frame", float(0.70) + 0.13, float(0.08) + 0.13, float(0.70) * 0.75,
                        (sx * 1.55, -2.66, 1.60), M["wood_light"]))
        objs.append(box("win", 0.70, 0.08, 0.70, (sx * 1.55, -2.66, 1.60), M["glass"]))
        objs.append(box("win_sill", 0.86, 0.12, 0.08, (sx * 1.55, -2.66, 1.20), M["wood_light"]))
        # 窗框
        objs.append(box("win_frame", float(0.08) + 0.13, float(0.70) + 0.13, float(0.66) * 0.75,
                        (sx * 2.66, 0.6, 1.60), M["wood_light"]))
        objs.append(box("win_side", 0.08, 0.70, 0.66, (sx * 2.66, 0.6, 1.60), M["glass"]))

    # 门前长椅与药草箱
    objs.append(box("bench", 1.40, 0.42, 0.12, (0, -2.20, 0.58), M["wood_light"]))
    for sx in (-1, 1):
        objs.append(box("bench_leg", 0.12, 0.36, 0.52, (sx * 0.55, -2.20, 0.30), M["wood"]))
    objs.append(box("herb_box", 0.90, 0.55, 0.45, (2.15, -1.90, 0.22), M["dirt"]))
    for i in range(3):
        objs.append(box("herb_%d" % i, 0.16, 0.16, 0.28, (1.90 + i * 0.25, -1.90, 0.58), M["crop"]))

    return join(objs, "hospital")


# ----------------------------------------------------------------- 裁缝铺

def build_tailor(M):
    objs = []
    objs.append(box("base", 3.60, 3.10, 0.24, (-0.15, 0.45, 0.12), M["stone"]))
    objs.append(box("skirt_band", float(3.30) + 0.14, float(2.80) + 0.14, 0.20,
                    (-0.15, 0.45, float(1.10) - float(1.95) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(1.95),
                            (float(-0.15) + csx * (float(3.30) * 0.5 - 0.06), float(0.45) + csy * (float(2.80) * 0.5 - 0.06), 1.10), M["wood"]))
    objs.append(box("wall", 3.30, 2.80, 1.95, (-0.15, 0.45, 1.10), M["wood_light"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(3.75) + 0.10, 0.09, 0.20,
                        (0, sy * (float(3.30) * 0.5 + 0.03), float(2.08) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(3.75) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(3.30) * 0.5 + 0.03), (float(2.08) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 3.75, 3.30, 0.95, 2.08, M["roof"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(3.30) * 0.5 * (1.0 - t))
            zz = float(2.08) + float(0.95) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(3.75) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.30, 0.93, 2.08, sy * 1.66, M["wood_light"]))

    # 门与窗
    # 门头雨棚
    objs.append(box("awning_board", float(0.72) + 0.30, 0.46, 0.07,
                    (-0.15, float(-0.96) - 0.18, float(0.65) + float(1.30) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(-0.15) + sx * (float(0.72) * 0.5 + 0.06), float(-0.96) - 0.34, float(0.65) + float(1.30) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.72, 0.08, 1.30, (-0.15, -0.96, 0.65), M["wood"]))
    # 窗框
    objs.append(box("win_frame", float(0.60) + 0.13, float(0.07) + 0.13, float(0.52) * 0.75,
                    (1.05, -0.96, 1.35), M["wood_light"]))
    objs.append(box("win", 0.60, 0.07, 0.52, (1.05, -0.96, 1.35), M["glass"]))

    # 门前布篷（两色条纹）
    for i in range(4):
        objs.append(box("awning_%d" % i, 0.46, 1.30, 0.07,
                        (-0.85 + i * 0.47, -1.55, 2.02), M["sign"] if i % 2 == 0 else M["pelt"],
                        rot=(math.radians(-14), 0, 0)))
    for sx in (-1, 1):
        objs.append(box("awning_post", 0.08, 0.08, 2.05, (-1.05 + (0 if sx < 0 else 1.75), -2.10, 1.02), M["wood"]))

    # 晾衣绳与衣服
    objs.append(box("rail", 2.20, 0.06, 0.06, (1.55, -0.20, 1.75), M["wood"]))
    for i, c in enumerate((M["sign"], M["tunic"], M["pelt"])):
        objs.append(box("cloth_%d" % i, 0.34, 0.04, 0.62, (0.85 + i * 0.62, -0.20, 1.38), c))

    # 染缸与布卷
    objs.append(cylinder("vat_a", 0.30, 0.62, (-1.15, -1.35, 0.31), M["wood"], axis="Z", segments=10))
    objs.append(cylinder("vat_b", 0.26, 0.52, (-0.55, -1.55, 0.26), M["wood"], axis="Z", segments=10))
    objs.append(box("bale", 0.70, 0.50, 0.42, (1.45, 0.95, 0.21), M["pelt"]))
    objs.append(box("bale2", 0.60, 0.44, 0.36, (1.45, 0.95, 0.60), M["sign"]))

    # 挑出的布招牌
    objs.append(box("sign_arm", 0.07, 0.62, 0.07, (1.30, -1.35, 2.05), M["wood"]))
    objs.append(box("sign_board", 0.07, 0.58, 0.72, (1.30, -1.68, 1.62), M["sign"]))
    objs.append(box("sign_trim", 0.09, 0.66, 0.08, (1.30, -1.68, 2.00), M["wood"]))

    add_house_trim(objs, 3.75, 3.30, 2.08, M, -1.12)
    return join(objs, "tailor")


# ----------------------------------------------------------------- 铁匠铺

def build_blacksmith(M):
    objs = []
    objs.append(box("base", 3.60, 3.20, 0.22, (-0.15, 0.40, 0.11), M["stone"]))
    objs.append(box("skirt_band", float(3.25) + 0.14, float(2.85) + 0.14, 0.20,
                    (-0.15, 0.40, float(1.28) - float(2.15) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.15),
                            (float(-0.15) + csx * (float(3.25) * 0.5 - 0.06), float(0.40) + csy * (float(2.85) * 0.5 - 0.06), 1.28), M["wood"]))
    objs.append(box("wall", 3.25, 2.85, 2.15, (-0.15, 0.40, 1.28), M["stone_dark"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(3.70) + 0.10, 0.09, 0.20,
                        (0, sy * (float(3.35) * 0.5 + 0.03), float(2.36) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(3.70) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(3.35) * 0.5 + 0.03), (float(2.36) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 3.70, 3.35, 1.00, 2.36, M["roof_dark"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(3.35) * 0.5 * (1.0 - t))
            zz = float(2.36) + float(1.00) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(3.70) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.25, 0.98, 2.36, sy * 1.68, M["stone_dark"]))

    # 烟囱
    objs.append(box("chimney", 0.62, 0.62, 2.40, (1.05, 1.05, 3.10), M["stone"]))
    objs.append(box("chimney_cap", 0.74, 0.74, 0.12, (1.05, 1.05, 4.30), M["stone_dark"]))

    # 炉口（暗色 + 火光）
    objs.append(box("forge", 0.95, 0.12, 0.85, (0.55, -1.02, 0.62), M["wood"]))
    objs.append(box("forge_fire", 0.70, 0.10, 0.55, (0.55, -1.06, 0.55), M["sign"]))

    # 门
    # 门头雨棚
    objs.append(box("awning_board", float(0.85) + 0.30, 0.46, 0.07,
                    (-0.55, float(-1.02) - 0.18, float(0.78) + float(1.55) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(-0.55) + sx * (float(0.85) * 0.5 + 0.06), float(-1.02) - 0.34, float(0.78) + float(1.55) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.85, 0.09, 1.55, (-0.55, -1.02, 0.78), M["wood"]))
    # 窗框
    objs.append(box("win_frame", float(0.55) + 0.13, float(0.08) + 0.13, float(0.45) * 0.75,
                    (-1.35, -1.02, 1.55), M["wood_light"]))
    objs.append(box("win", 0.55, 0.08, 0.45, (-1.35, -1.02, 1.55), M["glass"]))

    # 铁砧
    objs.append(box("anvil_base", 0.34, 0.34, 0.52, (1.35, -1.35, 0.26), M["wood"]))
    objs.append(box("anvil", 0.52, 0.34, 0.24, (1.35, -1.35, 0.64), M["stone_dark"]))
    objs.append(box("anvil_horn", 0.22, 0.16, 0.14, (1.60, -1.35, 0.66), M["stone_dark"]))

    # 工具架与煤堆
    objs.append(box("rack", 1.00, 0.08, 0.08, (-1.55, 1.10, 1.55), M["wood"]))
    for i in range(3):
        objs.append(box("tool_%d" % i, 0.06, 0.06, 0.55, (-1.85 + i * 0.30, 1.10, 1.28), M["stone"]))
    objs.append(box("coal", 0.80, 0.70, 0.28, (1.30, 0.20, 0.14), M["stone_dark"]))

    # 门前门廊（四柱 + 雨棚）
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("porch_post", 0.14, 0.14, 2.30,
                            (sx * 1.25, -3.05 + (0 if sy < 0 else 0.55), 1.15), M["wood"]))
    objs.append(box("porch_roof", 2.90, 1.30, 0.14, (0, -3.30, 2.36), M["roof_dark"]))
    objs.append(box("porch_beam", 2.90, 0.12, 0.16, (0, -2.72, 2.24), M["wood"]))

    add_house_trim(objs, 3.70, 3.35, 2.36, M, -1.18)
    return join(objs, "blacksmith")


# ----------------------------------------------------------------- 贸易站

def build_trade(M):
    objs = []
    objs.append(box("floor", 5.60, 5.20, 0.16, (0, 0, 0.08), M["wood_light"]))
    # 四根立柱 + 顶棚
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.18, 0.18, 2.65, (sx * 2.45, sy * 2.20, 1.33), M["wood"]))
    objs.append(box("roof", 5.90, 5.10, 0.16, (0, 0, 2.70), M["roof"]))
    objs.append(box("roof_trim", 5.95, 0.12, 0.24, (0, -2.53, 2.60), M["wood"]))

    # 柜台
    objs.append(box("counter", 4.60, 0.55, 0.95, (0, -1.55, 0.48), M["wood_light"]))
    objs.append(box("counter_top", 4.75, 0.68, 0.10, (0, -1.55, 1.00), M["wood"]))

    # 货架与货物
    objs.append(box("shelf", 4.60, 0.40, 0.12, (0, 1.85, 1.35), M["wood"]))
    objs.append(box("shelf2", 4.60, 0.40, 0.12, (0, 1.85, 0.75), M["wood"]))
    for i, c in enumerate((M["hay"], M["sign"], M["basket"], M["pelt"], M["hay"])):
        objs.append(box("good_%d" % i, 0.52, 0.36, 0.38, (-1.80 + i * 0.90, 1.85, 1.62), c))
        objs.append(box("good2_%d" % i, 0.48, 0.34, 0.34, (-1.80 + i * 0.90, 1.85, 1.00), c))

    # 板条箱与木桶
    for i in range(3):
        objs.append(box("crate_%d" % i, 0.62, 0.62, 0.62, (-2.35 + i * 0.72, -0.10, 0.31 + (0.0 if i != 2 else 0.62)), M["wood_light"]))
    objs.append(cylinder("barrel_a", 0.34, 0.78, (2.20, 0.60, 0.39), M["wood"], axis="Z", segments=10))
    objs.append(cylinder("barrel_b", 0.30, 0.70, (2.25, 1.30, 0.35), M["wood"], axis="Z", segments=10))

    # 市集钟楼
    objs.append(box("tower", 1.18, 1.18, 2.10, (1.85, 1.55, 3.75), M["wood_light"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("t_post_%d_%d" % (sx, sy), 0.12, 0.12, 2.10,
                            (1.85 + sx * 0.53, 1.55 + sy * 0.53, 3.75), M["wood"]))
    objs.append(box("t_band", 1.38, 1.38, 0.16, (1.85, 1.55, 4.86), M["wood"]))
    objs.append(box("bell_open", 0.52, 0.14, 0.62, (1.85, 0.94, 4.20), M["glass"]))
    objs.append(cone("t_roof", 1.52, 0.02, 1.15, (1.85, 1.55, 5.51), M["roof_dark"], segments=6))
    objs.append(box("t_finial", 0.10, 0.10, 0.34, (1.85, 1.55, 6.24), M["wood_light"]))

    # 招牌
    objs.append(box("sign_post", 0.12, 0.12, 2.20, (-2.60, -2.30, 1.10), M["wood"]))
    objs.append(box("sign_board", 1.05, 0.10, 0.68, (-2.60, -2.36, 2.05), M["wood_light"]))
    objs.append(box("sign_coin", 0.26, 0.06, 0.26, (-2.60, -2.42, 2.05), M["sign"]))

    return join(objs, "trade")


# ----------------------------------------------------------------- 石屋（民居二级）

def build_tavern(M):
    objs = []
    W, D = 5.6, 5.0
    objs.append(box("foundation", W + 0.30, D + 0.30, 0.36, (0, 0, 0.18), M["stone"]))
    objs.append(box("skirt_band", float(W) + 0.14, float(D) + 0.14, 0.20,
                    (0, 0, float(1.50) - float(2.30) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.30),
                            (float(0) + csx * (float(W) * 0.5 - 0.06), float(0) + csy * (float(D) * 0.5 - 0.06), 1.50), M["wood"]))
    objs.append(box("wall1", W, D, 2.30, (0, 0, 1.50), M["plaster"]))
    # 一层木框
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post_%d_%d" % (sx, sy), 0.22, 0.22, 2.30,
                            (sx * (W * 0.5 - 0.05), sy * (D * 0.5 - 0.05), 1.50), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("beam_%d" % sy, W + 0.1, 0.16, 0.18, (0, sy * (D * 0.5 - 0.02), 2.52), M["wood"]))
    # 二层出挑
    objs.append(box("jetty", W + 0.34, D + 0.34, 0.20, (0, 0, 2.70), M["wood_light"]))
    objs.append(box("wall2", W + 0.30, D + 0.30, 1.85, (0, 0, 3.72), M["plaster"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(W + 0.80) + 0.10, 0.09, 0.20,
                        (0, sy * (float(D + 0.75) * 0.5 + 0.03), float(4.65) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(W + 0.80) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(D + 0.75) * 0.5 + 0.03), (float(4.65) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", W + 0.80, D + 0.75, 1.85, 4.65, M["roof"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (float(D + 0.75) * 0.5 * (1.0 - t))
            zz = float(4.65) + float(1.85) * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), float(W + 0.80) + 0.03, 0.30, 0.055,
                                (0, yy, zz), M["roof_dark"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, W + 0.30, 1.83, 4.65, sy * (D * 0.5 + 0.28), M["plaster"]))
    # 屋脊压顶 + 老虎窗
    objs.append(box("ridge_cap", 0.26, D + 0.85, 0.14, (0, 0, 6.52), M["roof_dark"]))
    objs.append(box("dormer", 1.00, 1.05, 0.86, (0.1, -1.15, 6.10), M["plaster"]))
    objs.append(prism("dormer_roof", 1.22, 1.12, 0.40, 6.54, M["roof_dark"]))
    # 门与窗
    objs.append(box("door_frame", 1.30, 0.12, 2.10, (0, -D * 0.5 - 0.04, 1.35), M["wood_light"]))
    # 门头雨棚
    objs.append(box("awning_board", float(1.10) + 0.30, 0.46, 0.07,
                    (0, float(-D * 0.5) - 0.18, float(1.28) + float(1.94) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(1.10) * 0.5 + 0.06), float(-D * 0.5) - 0.34, float(1.28) + float(1.94) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 1.10, 0.14, 1.94, (0, -D * 0.5, 1.28), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("win1_%d" % sx, 0.86, 0.10, 0.92, (sx * 1.75, -D * 0.5 - 0.02, 1.62), M["glass"]))
        objs.append(box("win2_%d" % sx, 0.80, 0.10, 0.88, (sx * 1.65, -D * 0.5 - 0.18, 3.72), M["glass"]))
    # 外挂招牌
    objs.append(box("sign_arm", 1.55, 0.10, 0.10, (W * 0.5 + 0.55, -D * 0.5 + 0.6, 2.95), M["wood"]))
    objs.append(box("sign_board", 1.10, 0.10, 0.72, (W * 0.5 + 1.05, -D * 0.5 + 0.6, 2.45), M["wood_light"]))
    for i in range(3):
        objs.append(box("sign_mark_%d" % i, 0.70, 0.04, 0.07,
                        (W * 0.5 + 1.05, -D * 0.5 + 0.57, 2.66 - i * 0.20), M["sign"]))
    # 门口长凳与酒桶
    objs.append(box("bench_a", 1.85, 0.52, 0.14, (-1.7, -D * 0.5 - 0.85, 0.55), M["wood_light"]))
    objs.append(box("bench_b", 1.85, 0.52, 0.14, (1.7, -D * 0.5 - 0.85, 0.55), M["wood_light"]))
    for i in range(2):
        objs.append(cylinder("barrel_%d" % i, 0.30, 0.70, (W * 0.5 + 0.55, -D * 0.5 - 0.35 - i * 0.75, 0.35),
                             M["wood"], segments=8))
    objs.append(box("tray", 0.46, 0.34, 0.10, (2.35, -D * 0.5 - 0.85, 0.70), M["basket"]))
    return join(objs, "tavern")


def build_house_stone(M):
    objs = []
    objs.append(box("foundation", 3.90, 3.90, 0.40, (0, 0, 0.20), M["stone"]))
    objs.append(box("skirt_band", float(3.50) + 0.14, float(3.50) + 0.14, 0.20,
                    (0, 0, float(1.60) - float(2.45) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.45),
                            (float(0) + csx * (float(3.50) * 0.5 - 0.06), float(0) + csy * (float(3.50) * 0.5 - 0.06), 1.60), M["wood"]))
    objs.append(box("wall", 3.50, 3.50, 2.45, (0, 0, 1.60), M["stone_dark"]))

    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.22, 0.22, 2.45, (sx * 1.74, sy * 1.74, 1.60), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("beam_f", 3.60, 0.16, 0.16, (0, sy * 1.78, 2.74), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("beam_s", 0.16, 3.60, 0.16, (sx * 1.78, 0, 2.74), M["wood"]))

    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(4.45) + 0.10, 0.09, 0.20,
                        (0, sy * (float(4.35) * 0.5 + 0.03), float(2.82) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(4.45) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(4.35) * 0.5 + 0.03), (float(2.82) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 4.45, 4.35, 1.70, 2.82, M["roof_dark"]))
    for sy in (-1, 1):
        for k in range(9):
            t = (k + 0.5) / 9.0
            yy = sy * (2.175 * (1.0 - t))
            zz = 2.82 + 1.70 * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), 4.48, 0.32, 0.06, (0, yy, zz), M["roof"]))
    # 屋脊压顶 + 前坡老虎窗
    objs.append(box("ridge_cap", 0.24, 4.40, 0.13, (0, 0, 4.55), M["roof"]))
    objs.append(box("dormer", 0.96, 1.05, 0.82, (0.05, -1.02, 4.16), M["stone_dark"]))
    objs.append(prism("dormer_roof", 1.18, 1.12, 0.38, 4.57, M["roof"]))
    objs.append(box("dormer_win", 0.50, 0.08, 0.44, (0.05, -1.56, 4.12), M["glass"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.55, 1.68, 2.82, sy * 2.18, M["stone_dark"]))

    # 门头雨棚
    objs.append(box("awning_board", float(0.86) + 0.30, 0.46, 0.07,
                    (0, float(-1.80) - 0.18, float(0.92) + float(1.78) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(0.86) * 0.5 + 0.06), float(-1.80) - 0.34, float(0.92) + float(1.78) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.86, 0.10, 1.78, (0, -1.80, 0.92), M["wood"]))
    objs.append(box("door_frame", 1.06, 0.12, 0.10, (0, -1.80, 1.86), M["wood_light"]))
    for sx in (-1, 1):
        # 窗框
        objs.append(box("win_frame", float(0.68) + 0.13, float(0.08) + 0.13, float(0.68) * 0.75,
                        (sx * 1.10, -1.79, 1.62), M["wood_light"]))
        objs.append(box("win", 0.68, 0.08, 0.68, (sx * 1.10, -1.79, 1.62), M["glass"]))
        objs.append(box("win_sill", 0.84, 0.14, 0.08, (sx * 1.10, -1.79, 1.26), M["wood_light"]))
        # 窗框
        objs.append(box("win_frame", float(0.08) + 0.13, float(0.68) + 0.13, float(0.62) * 0.75,
                        (sx * 1.79, 0.55, 1.62), M["wood_light"]))
        objs.append(box("win_s", 0.08, 0.68, 0.62, (sx * 1.79, 0.55, 1.62), M["glass"]))
    # 窗框
    objs.append(box("win_frame", float(0.62) + 0.13, float(0.07) + 0.13, float(0.52) * 0.75,
                    (0, -1.79, 2.28), M["wood_light"]))
    objs.append(box("win_up", 0.62, 0.07, 0.52, (0, -1.79, 2.28), M["glass"]))

    objs.append(box("chimney", 0.56, 0.56, 1.45, (1.20, 0.95, 3.35), M["stone"]))
    objs.append(box("chimney_cap", 0.68, 0.68, 0.12, (1.20, 0.95, 4.10), M["stone_dark"]))

    add_house_trim(objs, 4.45, 4.35, 2.82, M, -1.98)
    return join(objs, "house_stone")


# ----------------------------------------------------------------- 大宅（民居三级）

def build_house_manor(M):
    objs = []
    objs.append(box("foundation", 3.95, 3.95, 0.45, (0, 0, 0.22), M["stone"]))

    # 一层石砌
    objs.append(box("floor1", 3.55, 3.55, 1.55, (0, 0, 1.22), M["stone_dark"]))
    # 二层木框 + 灰泥
    objs.append(box("floor2", 3.60, 3.60, 1.85, (0, 0, 2.92), M["plaster"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post", 0.20, 0.20, 3.40, (sx * 1.78, sy * 1.78, 2.15), M["wood"]))
    for z in (2.00, 3.10):
        for sy in (-1, 1):
            objs.append(box("band", 3.66, 0.14, 0.14, (0, sy * 1.82, z), M["wood"]))
        for sx in (-1, 1):
            objs.append(box("band_s", 0.14, 3.66, 0.14, (sx * 1.82, 0, z), M["wood"]))
    # 斜撑
    for sx in (-1, 1):
        objs.append(box("brace", 0.10, 0.10, 1.00, (sx * 1.78, -1.83, 2.60), M["wood"],
                        rot=(0, 0, math.radians(28 * sx))))

    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(4.55) + 0.10, 0.09, 0.20,
                        (0, sy * (float(4.45) * 0.5 + 0.03), float(3.85) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(4.55) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(4.45) * 0.5 + 0.03), (float(3.85) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", 4.55, 4.45, 1.85, 3.85, M["roof"]))
    for sy in (-1, 1):
        for k in range(10):
            t = (k + 0.5) / 10.0
            yy = sy * (2.225 * (1.0 - t))
            zz = 3.85 + 1.85 * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), 4.58, 0.32, 0.06, (0, yy, zz), M["roof_dark"]))
    # 屋脊压顶 + 前坡老虎窗
    objs.append(box("ridge_cap", 0.26, 4.50, 0.14, (0, 0, 5.72), M["roof_dark"]))
    objs.append(box("dormer", 1.02, 1.10, 0.88, (0.05, -1.05, 5.32), M["plaster"]))
    objs.append(prism("dormer_roof", 1.26, 1.18, 0.42, 5.76, M["roof_dark"]))
    objs.append(box("dormer_win", 0.54, 0.08, 0.48, (0.05, -1.62, 5.28), M["glass"]))
    for sy in (-1, 1):
        objs.append(_gable("gable_%d" % sy, 3.60, 1.83, 3.85, sy * 2.23, M["plaster"]))

    # 门廊
    objs.append(box("porch_roof", 2.10, 0.95, 0.12, (0, -2.15, 2.32), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("porch_post", 0.14, 0.14, 2.28, (sx * 0.90, -2.48, 1.14), M["wood"]))
    # 门头雨棚
    objs.append(box("awning_board", float(0.94) + 0.30, 0.46, 0.07,
                    (0, float(-1.84) - 0.18, float(1.00) + float(1.92) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(0.94) * 0.5 + 0.06), float(-1.84) - 0.34, float(1.00) + float(1.92) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.94, 0.10, 1.92, (0, -1.84, 1.00), M["wood"]))
    objs.append(box("door_top", 1.10, 0.12, 0.12, (0, -1.86, 2.02), M["wood_light"]))

    # 两层窗户
    for sx in (-1, 1):
        # 窗框
        objs.append(box("win_frame", float(0.66) + 0.13, float(0.08) + 0.13, float(0.62) * 0.75,
                        (sx * 1.12, -1.83, 1.30), M["wood_light"]))
        objs.append(box("win1", 0.66, 0.08, 0.62, (sx * 1.12, -1.83, 1.30), M["glass"]))
        # 窗框
        objs.append(box("win_frame", float(0.66) + 0.13, float(0.08) + 0.13, float(0.66) * 0.75,
                        (sx * 1.12, -1.84, 2.85), M["wood_light"]))
        objs.append(box("win2", 0.66, 0.08, 0.66, (sx * 1.12, -1.84, 2.85), M["glass"]))
        # 窗框
        objs.append(box("win_frame", float(0.08) + 0.13, float(0.66) + 0.13, float(0.60) * 0.75,
                        (sx * 1.83, 0.60, 1.30), M["wood_light"]))
        objs.append(box("win_s1", 0.08, 0.66, 0.60, (sx * 1.83, 0.60, 1.30), M["glass"]))
        # 窗框
        objs.append(box("win_frame", float(0.08) + 0.13, float(0.66) + 0.13, float(0.62) * 0.75,
                        (sx * 1.83, 0.60, 2.85), M["wood_light"]))
        objs.append(box("win_s2", 0.08, 0.66, 0.62, (sx * 1.83, 0.60, 2.85), M["glass"]))

    objs.append(box("chimney", 0.60, 0.60, 1.60, (1.25, 1.00, 4.30), M["stone"]))
    objs.append(box("chimney_cap", 0.72, 0.72, 0.12, (1.25, 1.00, 5.12), M["stone_dark"]))

    # 二层阳台与栏杆
    objs.append(box("balcony", 1.90, 0.70, 0.12, (0, -2.10, 2.12), M["wood_light"]))
    objs.append(box("balcony_rail", 1.90, 0.07, 0.08, (0, -2.42, 2.62), M["wood"]))
    for i in range(5):
        objs.append(box("baluster_%d" % i, 0.07, 0.07, 0.46,
                        (-0.80 + i * 0.40, -2.42, 2.36), M["wood"]))
    objs.append(box("balcony_brace", 0.10, 0.60, 0.10, (-0.70, -2.10, 1.95), M["wood"],
                    rot=(math.radians(38), 0, 0)))
    objs.append(box("balcony_brace2", 0.10, 0.60, 0.10, (0.70, -2.10, 1.95), M["wood"],
                    rot=(math.radians(38), 0, 0)))

    add_house_trim(objs, 4.55, 4.45, 3.85, M, -2.02)
    return join(objs, "house_manor")


# ----------------------------------------------------------------- 道具

def add_house_trim(objs, w, d, base_z, M, door_y=None):
    """封檐板 + 门口石阶，让建筑轮廓不那么"干净"。"""
    for sy in (-1, 1):
        objs.append(box("fascia", w * 1.03, 0.09, 0.17, (0, sy * d * 0.5, base_z + 0.02), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("corner_barge", 0.10, d * 0.98, 0.14, (sx * w * 0.5, 0, base_z + 0.02), M["wood"]))
    if door_y is not None:
        objs.append(box("step", 1.40, 0.60, 0.15, (0, door_y, 0.075), M["stone"]))
        objs.append(box("step2", 1.10, 0.34, 0.10, (0, door_y + 0.28, 0.20), M["stone"]))


def build_house_row(M):
    w, d = 4.0, 5.8
    objs = []
    objs.append(box("base", w + 0.20, d + 0.20, 0.34, (0, 0, 0.17), M["stone"]))
    objs.append(box("skirt_band", float(w) + 0.14, float(d) + 0.14, 0.20,
                    (0, 0, float(1.60) - float(2.55) * 0.5 + 0.10), M["stone_dark"]))
    for csx in (-1, 1):
        for csy in (-1, 1):
            objs.append(box("corner_board_%d_%d" % (csx, csy), 0.20, 0.20, float(2.55),
                            (float(0) + csx * (float(w) * 0.5 - 0.06), float(0) + csy * (float(d) * 0.5 - 0.06), 1.60), M["wood"]))
    objs.append(box("walls", w, d, 2.55, (0, 0, 1.60), M["plaster"]))
    # 二层出挑
    objs.append(box("jetty", w + 0.30, d + 0.30, 0.20, (0, 0, 2.98), M["wood"]))
    objs.append(box("walls2", w + 0.26, d + 0.26, 2.15, (0, 0, 4.16), M["plaster"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post_%d_%d" % (sx, sy), 0.18, 0.18, 2.15,
                            (sx * (w * 0.5 + 0.11), sy * (d * 0.5 + 0.11), 4.16), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("fascia_%d" % sy, float(w + 0.52) + 0.10, 0.09, 0.20,
                        (0, sy * (float(d + 0.56) * 0.5 + 0.03), float(5.24) - 0.05), M["wood_light"]))
        for rk in range(7):
            objs.append(box("rafter_%d" % rk, 0.11, 0.26, 0.11,
                            ((float(w + 0.52) + 0.10 - 0.7) * (rk / 6.0 - 0.5), sy * (float(d + 0.56) * 0.5 + 0.03), (float(5.24) - 0.05) - 0.16), M["wood"]))
    objs.append(prism("roof", w + 0.52, d + 0.56, 2.30, 5.24, M["roof"]))
    for sy in (-1, 1):
        for k in range(11):
            t = (k + 0.5) / 11.0
            yy = sy * (3.18 * (1.0 - t))
            zz = 5.24 + 2.30 * t - 0.02
            objs.append(box("tile_%d_%d" % (sy, k), w + 0.56, 0.32, 0.06, (0, yy, zz), M["roof_dark"]))
    # 屋脊压顶 + 前坡老虎窗
    objs.append(box("ridge_cap", 0.24, d + 0.60, 0.13, (0, 0, 7.56), M["roof_dark"]))
    objs.append(box("dormer", 0.92, 1.00, 0.78, (0.05, -1.05, 7.24), M["plaster"]))
    objs.append(prism("dormer_roof", 1.14, 1.06, 0.36, 7.62, M["roof_dark"]))
    objs.append(box("dormer_win", 0.48, 0.08, 0.42, (0.05, -1.56, 7.20), M["glass"]))
    # 大门
    objs.append(box("door_frame", 1.12, 0.12, 2.02, (0, -d * 0.5 - 0.06, 1.31), M["wood_light"]))
    # 门头雨棚
    objs.append(box("awning_board", float(0.94) + 0.30, 0.46, 0.07,
                    (0, float(-d * 0.5 - 0.02) - 0.18, float(1.26) + float(1.86) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(0.94) * 0.5 + 0.06), float(-d * 0.5 - 0.02) - 0.34, float(1.26) + float(1.86) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.94, 0.14, 1.86, (0, -d * 0.5 - 0.02, 1.26), M["wood"]))
    # 一二层窗
    for sx in (-1, 1):
        objs.append(box("win1_%d" % sx, 0.72, 0.12, 0.80, (sx * 1.18, -d * 0.5 - 0.02, 1.78), M["glass"]))
        objs.append(box("win1f_%d" % sx, 0.86, 0.10, 0.92, (sx * 1.18, -d * 0.5 - 0.05, 1.78), M["wood_light"]))
        objs.append(box("win2_%d" % sx, 0.72, 0.12, 0.86, (sx * 1.18, -d * 0.5 - 0.22, 4.18), M["glass"]))
        # 一层窗台花箱
        objs.append(box("winbox_%d" % sx, 0.84, 0.24, 0.20, (sx * 1.18, -d * 0.5 - 0.16, 1.28), M["wood_light"]))
        for k in range(3):
            objs.append(box("bloom_%d_%d" % (sx, k), 0.16, 0.16, 0.16,
                            (sx * 1.18 - 0.24 + k * 0.24, -d * 0.5 - 0.16, 1.41),
                            M["sign"] if k == 1 else M["berry"]))
    # 二层小阳台
    objs.append(box("balcony", 2.30, 0.58, 0.10, (0, -d * 0.5 - 0.40, 3.12), M["wood_light"]))
    for i in range(3):
        objs.append(box("bal_%d" % i, 0.07, 0.07, 0.46, (-0.92 + i * 0.92, -d * 0.5 - 0.64, 3.36), M["wood"]))
    objs.append(box("bal_rail", 2.30, 0.07, 0.07, (0, -d * 0.5 - 0.64, 3.60), M["wood"]))
    add_house_trim(objs, w + 0.26, d + 0.26, 5.24, M, -d * 0.5 - 0.28)
    return join(objs, "house_row")


def build_carpenter(M):
    objs = []
    objs.append(box("base", 4.40, 4.40, 0.30, (0, 0, 0.15), M["stone"]))
    objs.append(box("back", 4.20, 0.26, 2.60, (0, 1.95, 1.60), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("side_%d" % sx, 0.26, 4.00, 2.60, (sx * 2.02, 0, 1.60), M["wood"]))
        objs.append(box("post_%d" % sx, 0.22, 0.22, 2.80, (sx * 1.95, -1.95, 1.60), M["wood_light"]))
    objs.append(box("roof", 4.95, 4.75, 0.20, (0, 0, 3.16), M["roof_dark"],
                    rot=(math.radians(-7), 0, 0)))
    objs.append(box("roof_beam", 4.95, 0.16, 0.16, (0, -2.05, 2.72), M["wood"]))
    # 工作台
    objs.append(box("bench_top", 2.60, 0.85, 0.16, (-0.55, -0.35, 1.06), M["wood_light"]))
    objs.append(box("bench_body", 2.40, 0.70, 0.90, (-0.55, -0.35, 0.55), M["wood"]))
    # 木料堆
    for i in range(4):
        objs.append(box("log_%d" % i, 0.26, 2.90, 0.26, (1.48, 0.15, 0.42 + i * 0.02), M["wood_light"]))
    # 锯架
    objs.append(box("saw_horse", 0.12, 0.12, 1.00, (-1.60, -1.30, 0.80), M["wood"]))
    objs.append(box("saw_horse2", 0.12, 0.12, 1.00, (-1.60, -0.60, 0.80), M["wood"]))
    objs.append(box("saw_log", 0.34, 1.30, 0.30, (-1.60, -0.95, 1.10), M["wood_light"]))
    # 挂牌
    objs.append(box("sign_arm", 0.08, 0.55, 0.08, (1.55, -1.95, 2.55), M["wood"]))
    objs.append(box("sign_board", 0.08, 0.52, 0.62, (1.55, -2.20, 2.16), M["sign"]))
    add_house_trim(objs, 4.40, 4.40, 3.16, M, -2.30)
    return join(objs, "carpenter")


def build_dock(M):
    objs = []
    # 栈桥甲板（朝 -Y 伸向水面）
    objs.append(box("deck", 4.40, 5.20, 0.22, (0, -0.40, 0.62), M["wood_light"]))
    for i in range(9):
        objs.append(box("plank_%d" % i, 4.44, 0.10, 0.06,
                        (0, -2.90 + i * 0.60, 0.74), M["wood"]))
    # 木桩
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(cylinder("pile_%d_%d" % (sx, sy), 0.14, 2.6,
                                 (sx * 2.00, -0.40 + sy * 2.45, -0.65), M["wood"], segments=6))
    # 岸边小屋
    objs.append(box("hut", 2.60, 2.00, 2.05, (0, 2.30, 1.65), M["plaster"]))
    objs.append(prism("hut_roof", 2.95, 2.35, 1.05, 2.68, M["roof"]))
    objs.append(box("hut_door", 0.80, 0.12, 1.55, (0, 1.28, 1.30), M["wood"]))
    objs.append(box("hut_win", 0.55, 0.10, 0.45, (0.68, 1.28, 2.05), M["glass"]))
    # 甲板上的货
    objs.append(box("crate_a", 0.70, 0.70, 0.62, (-1.45, 0.55, 1.04), M["wood_light"]))
    objs.append(box("crate_b", 0.60, 0.60, 0.54, (-1.40, 0.60, 1.60), M["wood_light"]))
    objs.append(cylinder("barrel_a", 0.32, 0.78, (1.45, 0.70, 1.12), M["wood"], segments=8))
    # 渔网架
    objs.append(box("net_post_a", 0.12, 0.12, 1.60, (1.60, -2.20, 1.35), M["wood"]))
    objs.append(box("net_post_b", 0.12, 0.12, 1.60, (-1.60, -2.20, 1.35), M["wood"]))
    objs.append(box("net_bar", 3.40, 0.10, 0.10, (0, -2.20, 2.12), M["wood"]))
    objs.append(box("net_cloth", 3.00, 0.06, 0.95, (0, -2.18, 1.65), M["pelt"]))
    return join(objs, "dock")


def build_prop_boat(M):
    objs = []
    objs.append(box("hull", 1.15, 3.00, 0.42, (0, 0, 0.18), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("side_%d" % sx, 0.13, 3.00, 0.52, (sx * 0.56, 0, 0.50), M["wood_light"]))
    objs.append(box("bow", 0.75, 0.55, 0.46, (0, -1.65, 0.26), M["wood"], rot=(0, 0, 0)))
    objs.append(box("stern", 0.90, 0.30, 0.40, (0, 1.55, 0.22), M["wood"]))
    for sy in (-1, 1):
        objs.append(box("seat_%d" % sy, 1.05, 0.30, 0.09, (0, sy * 0.65, 0.72), M["wood_light"]))
    objs.append(box("oar_a", 0.09, 2.40, 0.07, (0.30, 0.10, 0.80), M["wood_light"],
                    rot=(0, math.radians(12), 0)))
    objs.append(box("oar_b", 0.09, 2.40, 0.07, (-0.30, 0.10, 0.78), M["wood_light"],
                    rot=(0, math.radians(-12), 0)))
    return join(objs, "prop_boat")


def blob(name, rx, ry, rz, loc, material, subdiv=1):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    for v in bm.verts:
        v.co.x *= rx
        v.co.y *= ry
        v.co.z *= rz
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return _finish(name, bm, material)


def build_prop_pier(M):
    objs = []
    L, W = 8.0, 2.8
    objs.append(box("deck", L, W, 0.20, (0, 0, 1.05), M["wood_light"]))
    for i in range(9):
        objs.append(box("plank_%d" % i, 0.22, W + 0.06, 0.06,
                        (-L * 0.5 + 0.45 + i * 0.9, 0, 1.18), M["wood"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(cylinder("pile_%d_%d" % (sx, sy), 0.15, 2.6,
                                 (sx * (L * 0.5 - 0.5), sy * (W * 0.5 - 0.2), -0.25), M["wood"], segments=6))
    for i in range(4):
        objs.append(cylinder("post_%d" % i, 0.13, 0.85, (-L * 0.5 + 0.5 + i * 2.4, W * 0.5 - 0.12, 1.58),
                             M["wood"], segments=6))
    objs.append(box("rope", L - 0.6, 0.05, 0.05, (0, W * 0.5 - 0.12, 1.95), M["rope"]))
    objs.append(cylinder("bollard", 0.16, 0.55, (L * 0.5 - 0.9, -W * 0.5 + 0.3, 1.42), M["wood"], segments=6))
    objs.append(box("crate", 0.62, 0.62, 0.58, (-L * 0.5 + 1.3, -0.3, 1.44), M["wood_light"]))
    return join(objs, "prop_pier")


def build_prop_ship(M):
    objs = []
    L, W = 8.4, 2.5
    objs.append(box("hull_mid", W, L * 0.55, 0.95, (0, 0, 0.55), M["wood"]))
    objs.append(box("hull_bow", W * 0.72, L * 0.24, 1.05, (0, -L * 0.38, 0.62), M["wood"]))
    objs.append(box("hull_stern", W * 0.80, L * 0.22, 1.00, (0, L * 0.37, 0.60), M["wood"]))
    for sx in (-1, 1):
        objs.append(box("rail_%d" % sx, 0.14, L * 0.58, 0.34,
                        (sx * W * 0.5, 0, 1.08), M["wood_light"]))
    objs.append(box("deck", W * 0.9, L * 0.55, 0.10, (0, 0, 1.02), M["wood_light"]))
    objs.append(box("cabin", W * 0.62, L * 0.16, 0.75, (0, L * 0.26, 1.45), M["wood_light"]))
    objs.append(box("cabin_roof", W * 0.70, L * 0.18, 0.10, (0, L * 0.26, 1.86), M["roof_dark"]))
    for i, my in enumerate((-L * 0.16, L * 0.12)):
        h = 5.4 if i == 0 else 4.2
        objs.append(cylinder("mast_%d" % i, 0.11, h, (0, my, 1.0 + h * 0.5), M["wood"], segments=6))
        objs.append(box("yard_%d" % i, W * 1.5, 0.10, 0.10, (0, my, 1.0 + h * 0.82), M["wood"]))
        objs.append(box("sail_%d" % i, W * 1.35, 0.06, h * 0.42, (0, my, 1.0 + h * 0.58), M["plaster"]))
    objs.append(box("bowsprit", 0.10, 1.6, 0.10, (0, -L * 0.55, 1.35), M["wood"],
                    rot=(math.radians(-22), 0, 0)))
    return join(objs, "prop_ship")


def build_prop_anvil_yard(M):
    objs = []
    # 树桩 + 铁砧
    objs.append(cylinder("stump", 0.44, 0.62, (0, 0, 0.31), M["wood"], segments=8))
    objs.append(box("anvil_base", 0.52, 0.34, 0.20, (0, 0, 0.72), M["stone_dark"]))
    objs.append(box("anvil_body", 0.74, 0.28, 0.22, (0.04, 0, 0.95), M["stone_dark"]))
    objs.append(box("anvil_horn", 0.26, 0.14, 0.12, (0.52, 0, 0.97), M["stone_dark"]))
    # 淬火水桶
    objs.append(cylinder("quench", 0.30, 0.52, (1.15, 0.35, 0.26), M["wood"], segments=8))
    objs.append(cylinder("quench_top", 0.27, 0.04, (1.15, 0.35, 0.53), M["water"], segments=8))
    # 工具架
    for sx in (-1, 1):
        objs.append(box("rack_post_%d" % sx, 0.10, 0.10, 1.55, (-1.05, sx * 0.55, 0.78), M["wood"]))
    objs.append(box("rack_bar", 0.12, 1.30, 0.10, (-1.05, 0, 1.50), M["wood"]))
    for i in range(3):
        objs.append(box("tool_%d" % i, 0.06, 0.06, 0.55,
                        (-1.05, -0.35 + i * 0.35, 1.22), M["stone_dark"]))
    # 木桶与铁料
    objs.append(cylinder("barrel_a", 0.28, 0.62, (-0.15, -1.10, 0.31), M["wood"], segments=8))
    objs.append(box("ingot_a", 0.44, 0.20, 0.14, (0.95, -0.85, 0.07), M["stone_dark"]))
    objs.append(box("ingot_b", 0.44, 0.20, 0.14, (0.95, -0.85, 0.21), M["wood"]))
    return join(objs, "prop_anvil_yard")


def build_prop_stall(M):
    objs = []
    W, D = 2.6, 1.9
    # 四根立柱
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("post_%d_%d" % (sx, sy), 0.12, 0.12, 2.10,
                            (sx * (W * 0.5 - 0.1), sy * (D * 0.5 - 0.1), 1.05), M["wood"]))
    # 柜台
    objs.append(box("counter", W - 0.1, 0.70, 0.85, (0, D * 0.5 - 0.42, 0.45), M["wood_light"]))
    objs.append(box("counter_top", W, 0.78, 0.09, (0, D * 0.5 - 0.42, 0.92), M["wood"]))
    # 条纹遮阳棚
    for i in range(4):
        c = M["sign"] if i % 2 == 0 else M["plaster"]
        objs.append(box("awning_%d" % i, W / 4.0, D + 0.5, 0.06,
                        (-W * 0.5 + W / 8.0 + i * (W / 4.0), 0, 2.22), c))
    objs.append(box("awning_front", W, 0.08, 0.30, (0, -D * 0.5 - 0.2, 2.05), M["wood"]))
    # 摊上的货物
    objs.append(box("crate_a", 0.42, 0.40, 0.34, (-0.7, 0.55, 1.14), M["wood_light"]))
    objs.append(blob("produce", 0.26, 0.24, 0.20, (0.1, 0.58, 1.10), M["crop"]))
    objs.append(blob("produce2", 0.22, 0.20, 0.18, (0.72, 0.56, 1.08), M["wheat"]))
    return join(objs, "prop_stall")


def build_prop_stoneblocks(M):
    objs = []
    objs.append(box("blk_a", 0.90, 0.70, 0.52, (0, 0, 0.26), M["stone"]))
    objs.append(box("blk_b", 0.72, 0.58, 0.46, (0.22, 0.52, 0.23), M["stone_dark"]))
    objs.append(box("blk_c", 0.60, 0.80, 0.44, (-0.55, 0.16, 0.22), M["stone"]))
    objs.append(box("blk_d", 0.48, 0.44, 0.34, (-0.10, -0.02, 0.69), M["stone_dark"]))
    objs.append(box("chisel_log", 0.90, 0.10, 0.10, (0.05, -0.55, 0.10), M["wood"]))
    return join(objs, "prop_stoneblocks")


def build_prop_sheep(M):
    objs = []
    objs.append(blob("wool", 0.34, 0.50, 0.32, (0, 0, 0.58), M["plaster"], subdiv=2))
    objs.append(blob("head", 0.15, 0.19, 0.17, (0, -0.52, 0.66), M["wood"]))
    objs.append(box("ear_l", 0.10, 0.06, 0.05, (-0.14, -0.56, 0.74), M["wood"]))
    objs.append(box("ear_r", 0.10, 0.06, 0.05, (0.14, -0.56, 0.74), M["wood"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("leg_%d_%d" % (sx, sy), 0.09, 0.09, 0.42,
                            (sx * 0.20, sy * 0.26, 0.21), M["wood"]))
    objs.append(box("tail", 0.10, 0.10, 0.16, (0, 0.48, 0.66), M["plaster"]))
    return join(objs, "prop_sheep")


def build_prop_lighthouse(M):
    objs = []
    objs.append(cylinder("base", 1.75, 1.10, (0, 0, 0.55), M["stone"], segments=8))
    objs.append(cone("tower", 1.45, 0.95, 7.40, (0, 0, 4.80), M["plaster"], segments=8))
    for z in (2.2, 4.2, 6.2):
        objs.append(cylinder("band_%d" % int(z * 10), 1.32 - (z - 2.2) * 0.06, 0.18,
                             (0, 0, z), M["sign"], segments=8))
    objs.append(cylinder("gallery", 1.42, 0.18, (0, 0, 8.58), M["stone_dark"], segments=8))
    for i in range(8):
        a = i * math.pi * 0.25
        objs.append(box("rail_%d" % i, 0.08, 0.08, 0.45,
                        (math.cos(a) * 1.32, math.sin(a) * 1.32, 8.90), M["wood"]))
    objs.append(cylinder("lantern", 0.86, 1.20, (0, 0, 9.40), M["glass"], segments=8))
    objs.append(cone("lamp_roof", 1.08, 0.02, 0.95, (0, 0, 10.45), M["roof_dark"], segments=8))
    # 门头雨棚
    objs.append(box("awning_board", float(0.75) + 0.30, 0.46, 0.07,
                    (0, float(-1.42) - 0.18, float(0.95) + float(1.45) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(0.75) * 0.5 + 0.06), float(-1.42) - 0.34, float(0.95) + float(1.45) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 0.75, 0.18, 1.45, (0, -1.42, 0.95), M["wood"]))
    for z in (3.4, 5.6):
        objs.append(box("win_%d" % int(z * 10), 0.30, 0.16, 0.45, (0, -1.15, z), M["glass"]))
    return join(objs, "prop_lighthouse")


def build_bridge(M):
    objs = []
    L, W = 13.0, 3.8
    R = 3.5
    spring = 0.30
    deck_z = spring + R + 0.28
    # 桥面
    objs.append(box("deck", L, W, 0.42, (0, 0, deck_z), M["stone"]))
    for sy in (-1, 1):
        objs.append(box("edge_%d" % sy, L, 0.22, 0.18,
                        (0, sy * (W * 0.5 - 0.10), deck_z + 0.26), M["stone_dark"]))
        objs.append(box("parapet_%d" % sy, L, 0.34, 1.00,
                        (0, sy * (W * 0.5 - 0.12), deck_z + 0.76), M["stone"]))
        objs.append(box("parapet_top_%d" % sy, L, 0.46, 0.12,
                        (0, sy * (W * 0.5 - 0.12), deck_z + 1.30), M["stone_dark"]))
        for pi in range(4):
            objs.append(box("post_%d_%d" % (sy, pi), 0.42, 0.42, 1.45,
                            (-4.6 + pi * 3.05, sy * (W * 0.5 - 0.12), deck_z + 0.95), M["stone_dark"]))
    # 拱圈
    for i in range(11):
        a = math.pi * (0.06 + 0.88 * i / 10.0)
        x = math.cos(a) * R
        z = spring + math.sin(a) * R
        objs.append(box("arch_%d" % i, 1.05, W + 0.45, 1.05, (x, 0, z),
                        M["stone_dark"], rot=(0, -a, 0)))
    # 桥台
    for sx in (-1, 1):
        objs.append(box("abut_%d" % sx, 2.2, W + 0.6, deck_z - 0.2,
                        (sx * 4.9, 0, (deck_z - 0.2) * 0.5), M["stone"]))
    # 桥面石板
    for i in range(6):
        objs.append(box("pave_%d" % i, 2.1, W - 0.9, 0.08,
                        (-5.2 + i * 2.1, 0, deck_z + 0.22), M["stone_dark"]))
    return join(objs, "bridge")


def build_fountain(M):
    objs = []
    # 八角形石砌水池
    objs.append(cylinder("basin_outer", 2.05, 0.62, (0, 0, 0.31), M["stone"], axis="Z", segments=8))
    objs.append(cylinder("basin_rim", 2.12, 0.10, (0, 0, 0.64), M["stone_dark"], axis="Z", segments=8))
    objs.append(cylinder("basin_inner", 1.70, 0.12, (0, 0, 0.60), M["stone_dark"], axis="Z", segments=8))
    objs.append(cylinder("water", 1.66, 0.05, (0, 0, 0.64), M["water"], axis="Z", segments=8))
    # 中央柱与水盘
    objs.append(cylinder("pillar", 0.34, 1.05, (0, 0, 1.15), M["stone"], axis="Z", segments=8))
    objs.append(cylinder("bowl", 0.95, 0.16, (0, 0, 1.72), M["stone_dark"], axis="Z", segments=8))
    objs.append(cylinder("bowl_water", 0.86, 0.04, (0, 0, 1.81), M["water"], axis="Z", segments=8))
    objs.append(cylinder("stem", 0.16, 0.55, (0, 0, 2.02), M["stone"], axis="Z", segments=8))
    objs.append(blob("finial", 0.22, 0.22, 0.26, (0, 0, 2.38), M["stone_dark"]))
    # 四向小出水口
    for i in range(4):
        a = i * math.pi * 0.5 + math.pi * 0.25
        objs.append(box("spout_%d" % i, 0.10, 0.55, 0.10,
                        (math.cos(a) * 0.42, math.sin(a) * 0.42, 1.30), M["stone"],
                        rot=(0, 0, a)))
    return join(objs, "fountain")


def build_prop_scarecrow(M):
    objs = []
    objs.append(box("post", 0.14, 0.14, 2.10, (0, 0, 1.05), M["wood"]))
    objs.append(box("cross", 1.55, 0.12, 0.12, (0, 0, 1.55), M["wood_light"]))
    objs.append(box("body", 0.62, 0.34, 0.95, (0, 0, 1.22), M["tunic"]))
    objs.append(blob("head", 0.19, 0.19, 0.21, (0, 0, 1.86), M["hay"]))
    objs.append(box("hat_top", 0.46, 0.46, 0.10, (0, 0, 2.02), M["hay"]))
    objs.append(box("hat_brim", 0.62, 0.62, 0.05, (0, 0, 1.96), M["hay"]))
    for sx in (-1, 1):
        objs.append(box("arm_%d" % sx, 0.30, 0.16, 0.20, (sx * 0.62, 0, 1.55), M["tunic"]))
    objs.append(box("belt", 0.66, 0.36, 0.10, (0, 0, 0.95), M["rope"]))
    return join(objs, "prop_scarecrow")


def build_prop_veggarden(M):
    objs = []
    # 菜畦
    objs.append(box("soil", 2.20, 1.70, 0.10, (0, 0, 0.05), M["dirt"]))
    for i in range(3):
        y = -0.52 + i * 0.52
        objs.append(box("row_%d" % i, 1.90, 0.30, 0.10, (0, y, 0.12), M["dirt"]))
        objs.append(box("crop_%d" % i, 1.80, 0.24, 0.22, (0, y, 0.24), M["crop"]))
    # 边框木板
    for sy in (-1, 1):
        objs.append(box("edge_%d" % sy, 2.36, 0.10, 0.14, (0, sy * 0.92, 0.10), M["wood_light"]))
    for sx in (-1, 1):
        objs.append(box("edge_x_%d" % sx, 0.10, 1.94, 0.14, (sx * 1.16, 0, 0.10), M["wood_light"]))
    # 角落立柱 + 短篱笆
    objs.append(box("post_a", 0.10, 0.10, 0.90, (1.20, 0.95, 0.45), M["wood"]))
    objs.append(box("post_b", 0.10, 0.10, 0.90, (1.20, -0.95, 0.45), M["wood"]))
    objs.append(box("rail", 0.06, 1.94, 0.08, (1.20, 0, 0.70), M["wood_light"]))
    objs.append(box("rail2", 0.06, 1.94, 0.08, (1.20, 0, 0.38), M["wood_light"]))
    return join(objs, "prop_veggarden")


def build_prop_clothesline(M):
    objs = []
    for sx in (-1, 1):
        objs.append(box("post_%d" % sx, 0.12, 0.12, 1.90, (sx * 1.65, 0, 0.95), M["wood"]))
    objs.append(box("rope", 3.35, 0.03, 0.03, (0, 0, 1.84), M["rope"]))
    cloths = [
        (-1.05, 0.46, 0.72, M["plaster"]),
        (-0.25, 0.40, 0.62, M["pelt"]),
        (0.55, 0.44, 0.78, M["tunic"]),
        (1.25, 0.38, 0.58, M["plaster"]),
    ]
    for i, c in enumerate(cloths):
        objs.append(box("cloth_%d" % i, c[1], 0.04, c[2], (c[0], 0, 1.84 - c[2] * 0.5 - 0.02), c[3]))
    return join(objs, "prop_clothesline")


def build_prop_woodpile(M):
    objs = []
    for row in range(3):
        for i in range(3 - row):
            x = -0.45 + i * 0.52 + row * 0.26
            objs.append(cylinder("log_%d_%d" % (row, i), 0.17, 1.25,
                                 (x, 0, 0.20 + row * 0.33), M["wood"], axis="Y", segments=6))
    objs.append(box("stump", 0.52, 0.52, 0.46, (1.35, 0.10, 0.23), M["wood_light"]))
    objs.append(box("axe_handle", 0.06, 0.06, 0.52, (1.35, 0.16, 0.66), M["wood"],
                    rot=(math.radians(14), 0, 0)))
    objs.append(box("axe_head", 0.20, 0.07, 0.16, (1.35, 0.30, 0.90), M["stone"]))
    return join(objs, "prop_woodpile")


def build_prop_haycart(M):
    objs = []
    objs.append(box("bed", 1.90, 1.20, 0.14, (0, 0, 0.56), M["wood_light"]))
    for sy in (-1, 1):
        objs.append(box("side_%d" % sy, 1.90, 0.10, 0.42, (0, sy * 0.55, 0.80), M["wood"]))
    for sx in (-1, 1):
        objs.append(cylinder("wheel_%d" % sx, 0.38, 0.10, (sx * 0.78, 0.58, 0.38),
                             M["wood"], axis="X", segments=10))
    objs.append(box("hay", 1.70, 1.00, 0.72, (0, 0, 1.06), M["hay"]))
    objs.append(box("shaft", 0.95, 0.07, 0.07, (-1.40, 0.30, 0.60), M["wood"]))
    return join(objs, "prop_haycart")


def build_prop_trough(M):
    objs = []
    objs.append(box("trough", 1.50, 0.62, 0.46, (0, 0, 0.23), M["wood_light"]))
    objs.append(box("water", 1.28, 0.46, 0.05, (0, 0, 0.44), M["water"]))
    objs.append(box("bucket", 0.34, 0.34, 0.34, (0.98, 0.12, 0.17), M["wood"]))
    objs.append(box("post", 0.12, 0.12, 1.15, (-0.90, 0.12, 0.58), M["wood"]))
    objs.append(box("rope", 0.03, 0.03, 0.52, (-0.90, 0.12, 0.90), M["rope"]))
    return join(objs, "prop_trough")


def build_prop_signpost(M):
    objs = []
    objs.append(box("post", 0.14, 0.14, 1.80, (0, 0, 0.90), M["wood"]))
    objs.append(box("arm_a", 0.82, 0.08, 0.22, (0.36, 0, 1.48), M["wood_light"]))
    objs.append(box("arm_b", 0.72, 0.08, 0.20, (-0.30, 0, 1.12), M["wood_light"]))
    objs.append(box("cap", 0.20, 0.20, 0.10, (0, 0, 1.84), M["wood"]))
    return join(objs, "prop_signpost")


def build_prop_chicken(M):
    objs = []
    objs.append(blob("body", 0.20, 0.27, 0.19, (0, 0, 0.27), M["plaster"]))
    objs.append(blob("head", 0.11, 0.12, 0.12, (0, -0.17, 0.46), M["plaster"]))
    objs.append(box("beak", 0.05, 0.11, 0.05, (0, -0.27, 0.44), M["wheat"]))
    objs.append(box("comb", 0.05, 0.11, 0.08, (0, -0.15, 0.55), M["sign"]))
    objs.append(blob("tail", 0.09, 0.11, 0.15, (0, 0.22, 0.36), M["plaster"]))
    for sx in (-1, 1):
        objs.append(box("leg_%d" % sx, 0.035, 0.035, 0.20, (sx * 0.06, 0.0, 0.10), M["wheat"]))
    return join(objs, "prop_chicken")


def build_prop_dog(M):
    objs = []
    objs.append(blob("body", 0.15, 0.33, 0.16, (0, 0, 0.36), M["barn"]))
    objs.append(blob("head", 0.12, 0.14, 0.12, (0, -0.34, 0.48), M["barn"]))
    objs.append(box("muzzle", 0.09, 0.13, 0.08, (0, -0.46, 0.43), M["wood_light"]))
    for sx in (-1, 1):
        objs.append(box("ear_%d" % sx, 0.04, 0.06, 0.11, (sx * 0.07, -0.31, 0.59), M["wood"]))
        for sy in (-1, 1):
            objs.append(box("leg_%d_%d" % (sx, sy), 0.06, 0.06, 0.24,
                            (sx * 0.09, sy * 0.21, 0.14), M["barn"]))
    objs.append(box("tail", 0.04, 0.05, 0.20, (0, 0.35, 0.50), M["barn"],
                    rot=(math.radians(-35), 0, 0)))
    return join(objs, "prop_dog")


def build_church(M):
    objs = []
    # 台基
    objs.append(box("base", 6.70, 7.70, 0.40, (0, 0, 0.20), M["stone"]))
    objs.append(box("base_top", 6.40, 7.40, 0.14, (0, 0, 0.45), M["stone_dark"]))
    # 中殿墙体
    objs.append(box("nave", 5.40, 5.90, 3.90, (0, 0.75, 2.40), M["plaster"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("corner_%d_%d" % (sx, sy), 0.24, 0.24, 3.90,
                            (sx * 2.58, 0.75 + sy * 2.83, 2.40), M["wood"]))
    # 中殿屋顶
    objs.append(prism("nave_roof", 6.00, 6.40, 2.70, 4.35, M["roof_dark"]))
    # 侧墙彩色玻璃
    for sx in (-1, 1):
        for k in range(3):
            yy = -0.75 + k * 1.55
            objs.append(box("win_%d_%d" % (sx, k), 0.10, 0.70, 1.55,
                            (sx * 2.71, yy, 2.55), M["glass"]))
            objs.append(box("win_frame_%d_%d" % (sx, k), 0.12, 0.82, 1.68,
                            (sx * 2.69, yy, 2.55), M["wood"]))
    # 钟楼
    objs.append(box("tower", 2.50, 2.50, 8.30, (0, -3.30, 4.55), M["plaster"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(box("t_corner_%d_%d" % (sx, sy), 0.22, 0.22, 8.30,
                            (sx * 1.15, -3.30 + sy * 1.15, 4.55), M["wood"]))
    objs.append(box("tower_band", 2.78, 2.78, 0.26, (0, -3.30, 8.85), M["wood"]))
    # 钟室开口
    objs.append(box("bell_open", 1.30, 0.16, 1.35, (0, -4.56, 7.75), M["glass"]))
    objs.append(box("bell_beam", 1.60, 0.14, 0.16, (0, -4.58, 7.10), M["wood"]))
    # 尖顶（石板灰，和暗红屋顶区分开）
    objs.append(cone("spire", 1.30, 0.02, 6.40, (0, -3.30, 12.15), M["stone_dark"], segments=8))
    # 十字架
    objs.append(box("cross_v", 0.12, 0.12, 1.00, (0, -3.30, 15.60), M["wood_light"]))
    objs.append(box("cross_h", 0.58, 0.12, 0.12, (0, -3.30, 15.80), M["wood_light"]))
    # 大门
    objs.append(box("door_frame", 1.30, 0.18, 2.55, (0, -4.52, 1.72), M["wood"]))
    # 门头雨棚
    objs.append(box("awning_board", float(1.06) + 0.30, 0.46, 0.07,
                    (0, float(-4.55) - 0.18, float(1.60) + float(2.30) * 0.5 + 0.16), M["roof_dark"]))
    for sx in (-1, 1):
        objs.append(box("awning_br_%d" % sx, 0.07, 0.07, 0.42,
                        (float(0) + sx * (float(1.06) * 0.5 + 0.06), float(-4.55) - 0.34, float(1.60) + float(2.30) * 0.5 - 0.06), M["wood"]))
    objs.append(box("door", 1.06, 0.20, 2.30, (0, -4.55, 1.60), M["wood_light"]))
    objs.append(box("door_step", 1.60, 0.70, 0.18, (0, -4.85, 0.55), M["stone"]))
    # 塔前小玫瑰窗
    objs.append(box("rose", 0.90, 0.14, 0.90, (0, -4.56, 4.85), M["glass"]))
    objs.append(box("rose_rim", 1.02, 0.12, 1.02, (0, -4.54, 4.85), M["stone"]))
    return join(objs, "church")


def build_windmill(M):
    body = []
    body.append(cone("tower", 1.78, 1.12, 7.00, (0, 0, 3.50), M["stone"], segments=8))
    body.append(cylinder("band", 1.22, 0.22, (0, 0, 7.02), M["wood"], segments=8))
    body.append(cone("cap", 1.36, 0.0, 1.45, (0, 0, 7.85), M["roof_dark"], segments=8))
    body.append(box("door", 0.92, 0.18, 1.70, (0, -1.62, 0.88), M["wood"]))
    body.append(box("door_frame", 1.08, 0.14, 1.86, (0, -1.68, 0.93), M["wood_light"]))
    body.append(box("door_step", 1.30, 0.55, 0.16, (0, -1.88, 0.08), M["stone"]))
    for z in (2.70, 4.60):
        body.append(box("win_%d" % int(z * 10), 0.40, 0.16, 0.52, (0, -1.44, z), M["glass"]))
    body.append(box("tail_beam", 0.14, 0.14, 1.60, (0, 1.15, 7.30), M["wood"],
                    rot=(math.radians(24), 0, 0)))
    body_ob = join(body, "windmill_body")

    groups = []
    for i in range(4):
        parts = []
        # 主臂
        parts.append(box("arm_%d" % i, 0.15, 0.15, 3.60, (0, 0, 1.85), M["wood"]))
        # 帆布面
        parts.append(box("canvas_%d" % i, 0.92, 0.05, 3.30, (0.48, 0.05, 1.80), M["plaster"]))
        # 帆格横档
        for k in range(4):
            zz = 0.85 + k * 0.78
            parts.append(box("bar_%d_%d" % (i, k), 0.98, 0.08, 0.11,
                             (0.48, 0.0, zz), M["wood_light"]))
        parts.append(box("edge_%d" % i, 0.09, 0.09, 3.40, (0.94, 0.0, 1.80), M["wood_light"]))
        arm = join(parts, "blade_group_%d" % i)
        arm.data.transform(Matrix.Rotation(i * math.pi / 2, 4, "Y"))
        groups.append(arm)
    groups.append(cylinder("hub", 0.32, 0.60, (0, 0, 0), M["wood_light"], axis="Y", segments=8))
    blades = join(groups, "windmill_blades")
    blades.location = (0, -1.62, 7.75)
    return body_ob, blades


def build_prop_cart(M):
    objs = []
    objs.append(box("bed", 1.70, 1.10, 0.12, (0, 0, 0.62), M["wood_light"]))
    for sy in (-1, 1):
        objs.append(box("side", 1.70, 0.08, 0.34, (0, sy * 0.51, 0.82), M["wood"]))
    objs.append(box("back", 0.10, 1.10, 0.34, (-0.80, 0, 0.82), M["wood"]))
    for sx in (-1, 1):
        objs.append(cylinder("wheel", 0.40, 0.10, (sx * 0.62, 0, 0.40), M["wood"], axis="X", segments=10))
        objs.append(box("shaft", 0.90, 0.07, 0.07, (1.25, sy * 0.30, 0.56), M["wood"]))
    objs.append(box("load", 1.40, 0.90, 0.45, (0, 0, 1.00), M["hay"]))
    return join(objs, "prop_cart")


def build_prop_haystack(M):
    objs = []
    objs.append(cylinder("stack", 1.05, 1.50, (0, 0, 0.75), M["hay"], axis="Z", segments=9))
    objs.append(cylinder("top", 0.62, 0.55, (0, 0, 1.72), M["hay"], axis="Z", segments=8))
    for i in range(5):
        a = i * 1.26
        objs.append(box("straw_%d" % i, 0.10, 0.10, 0.70,
                        (math.cos(a) * 0.95, math.sin(a) * 0.95, 0.42), M["hay"],
                        rot=(math.radians(18), 0, a)))
    return join(objs, "prop_haystack")


def build_prop_barrel(M):
    objs = []
    objs.append(cylinder("body", 0.36, 0.86, (0, 0, 0.43), M["wood_light"], axis="Z", segments=10))
    for z in (0.18, 0.68):
        objs.append(cylinder("hoop", 0.375, 0.07, (0, 0, z), M["stone"], axis="Z", segments=10))
    objs.append(cylinder("lid", 0.34, 0.06, (0, 0, 0.88), M["wood"], axis="Z", segments=10))
    return join(objs, "prop_barrel")


def build_prop_crate(M):
    objs = []
    objs.append(box("box", 0.72, 0.72, 0.66, (0, 0, 0.33), M["wood_light"]))
    for sy in (-1, 1):
        objs.append(box("batten", 0.76, 0.05, 0.08, (0, sy * 0.36, 0.33), M["wood"]))
        objs.append(box("batten2", 0.76, 0.05, 0.08, (0, sy * 0.36, 0.60), M["wood"]))
    objs.append(box("lid", 0.76, 0.76, 0.05, (0, 0, 0.68), M["wood"]))
    return join(objs, "prop_crate")


def build_prop_bench(M):
    objs = []
    objs.append(box("seat", 1.50, 0.42, 0.09, (0, 0, 0.46), M["wood_light"]))
    for sx in (-1, 1):
        objs.append(box("leg", 0.10, 0.36, 0.44, (sx * 0.62, 0, 0.22), M["wood"]))
    objs.append(box("back", 1.50, 0.08, 0.34, (0, 0.18, 0.78), M["wood_light"]))
    for sx in (-1, 1):
        objs.append(box("post", 0.09, 0.09, 0.42, (sx * 0.62, 0.18, 0.66), M["wood"]))
    return join(objs, "prop_bench")


def build_prop_lamp(M):
    objs = []
    objs.append(box("base", 0.34, 0.34, 0.16, (0, 0, 0.08), M["stone"]))
    objs.append(box("post", 0.12, 0.12, 2.30, (0, 0, 1.20), M["wood"]))
    objs.append(box("arm", 0.52, 0.10, 0.10, (0.24, 0, 2.32), M["wood"]))
    objs.append(box("lantern", 0.26, 0.26, 0.34, (0.46, 0, 2.05), M["glass"]))
    objs.append(box("lantern_top", 0.32, 0.32, 0.06, (0.46, 0, 2.26), M["wood"]))
    objs.append(box("lantern_bot", 0.32, 0.32, 0.06, (0.46, 0, 1.86), M["wood"]))
    return join(objs, "prop_lamp")


def build_prop_fence(M):
    objs = []
    objs.append(box("post_a", 0.12, 0.12, 1.05, (-1.0, 0, 0.52), M["wood"]))
    objs.append(box("post_b", 0.12, 0.12, 1.05, (1.0, 0, 0.52), M["wood"]))
    for z in (0.42, 0.80):
        objs.append(box("rail", 2.10, 0.07, 0.09, (0, 0, z), M["wood_light"]))
    return join(objs, "prop_fence")


# ----------------------------------------------------------------- 角色

def build_character(M):
    parts = []

    def part(name, sx, sy, sz, loc, material, bone):
        ob = box(name, sx, sy, sz, loc, material)
        vg = ob.vertex_groups.new(name=bone)
        vg.add(list(range(len(ob.data.vertices))), 1.0, "REPLACE")
        parts.append(ob)
        return ob

    # 正面朝 -Y
    part("pelvis", 0.36, 0.24, 0.20, (0, 0, 0.94), M["pants"], "hips")
    part("chest", 0.38, 0.25, 0.44, (0, 0, 1.28), M["tunic"], "spine")
    part("collar", 0.40, 0.27, 0.07, (0, 0, 1.49), M["tunic"], "spine")
    part("head", 0.23, 0.22, 0.24, (0, 0, 1.64), M["skin"], "head")
    part("nose", 0.06, 0.06, 0.06, (0, -0.13, 1.63), M["skin"], "head")
    part("hat_brim", 0.30, 0.30, 0.04, (0, 0, 1.76), M["wood_light"], "head")
    part("hat_top", 0.22, 0.22, 0.12, (0, 0, 1.83), M["wood_light"], "head")

    for tag, sx in (("L", 1), ("R", -1)):
        part("arm_" + tag, 0.12, 0.13, 0.50, (sx * 0.24, 0, 1.24), M["tunic"], "arm." + tag)
        part("hand_" + tag, 0.11, 0.12, 0.11, (sx * 0.24, 0, 0.96), M["skin"], "arm." + tag)
        part("leg_" + tag, 0.15, 0.16, 0.72, (sx * 0.10, 0, 0.48), M["pants"], "leg." + tag)
        part("boot_" + tag, 0.16, 0.22, 0.14, (sx * 0.10, -0.03, 0.07), M["boots"], "leg." + tag)

    bpy.ops.object.select_all(action="DESELECT")
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    mesh_obj = bpy.context.view_layer.objects.active
    mesh_obj.name = "character_mesh"

    # ---- 骨骼
    arm_data = bpy.data.armatures.new("character_arm")
    arm_obj = bpy.data.objects.new("character", arm_data)
    bpy.context.scene.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm_data.edit_bones

    def bone(name, head, tail, parent=None):
        b = eb.new(name)
        b.head = head
        b.tail = tail
        if parent:
            b.parent = eb[parent]
        return b

    bone("hips", (0, 0, 0.86), (0, 0, 1.06))
    bone("spine", (0, 0, 1.06), (0, 0, 1.46), "hips")
    bone("head", (0, 0, 1.46), (0, 0, 1.78), "spine")
    for tag, sx in (("L", 1), ("R", -1)):
        bone("arm." + tag, (sx * 0.24, 0, 1.42), (sx * 0.24, 0, 0.92), "spine")
        bone("leg." + tag, (sx * 0.10, 0, 0.86), (sx * 0.10, 0, 0.03), "hips")

    bpy.ops.object.mode_set(mode="OBJECT")

    bpy.ops.object.select_all(action="DESELECT")
    mesh_obj.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.parent_set(type="ARMATURE")

    # 搬运用的原木（独立网格，游戏里按需显隐）
    log_obj = box("carry_log", 0.30, 0.30, 1.45, (0, -0.46, 1.12), M["wood_light"])
    vg = log_obj.vertex_groups.new(name="spine")
    vg.add(list(range(len(log_obj.data.vertices))), 1.0, "REPLACE")

    bpy.ops.object.select_all(action="DESELECT")
    log_obj.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.parent_set(type="ARMATURE")

    for pb in arm_obj.pose.bones:
        pb.rotation_mode = "XYZ"

    arm_obj.animation_data_create()

    def make_action(name, frames):
        act = bpy.data.actions.new(name)
        act.use_fake_user = True
        arm_obj.animation_data.action = act
        for f, poses in frames:
            for bname, rot, loc in poses:
                pb = arm_obj.pose.bones[bname]
                pb.rotation_euler = rot
                pb.keyframe_insert("rotation_euler", frame=f)
                if loc is not None:
                    pb.location = loc
                    pb.keyframe_insert("location", frame=f)
        return act

    r = math.radians
    # 走路：24 帧循环
    walk = []
    for f, s in ((1, 1), (7, 0), (13, -1), (19, 0), (25, 1)):
        walk.append((f, [
            ("leg.L", (r(26) * s, 0, 0), None),
            ("leg.R", (r(-26) * s, 0, 0), None),
            ("arm.L", (r(-22) * s, 0, 0), None),
            ("arm.R", (r(22) * s, 0, 0), None),
            ("hips", (0, 0, 0), (0, 0, 0.035 if abs(s) else 0.0)),
        ]))
    make_action("Walk", walk)

    # 待机：轻微呼吸摆动
    idle = []
    for f, s in ((1, 1), (25, 0), (49, 1)):
        idle.append((f, [
            ("spine", (r(2.5) * s, 0, 0), None),
            ("arm.L", (r(4) * s, 0, 0), None),
            ("arm.R", (r(-4) * s, 0, 0), None),
            ("hips", (0, 0, 0), (0, 0, 0.012 * s)),
        ]))
    make_action("Idle", idle)

    # 搬运：双臂前伸抬木头，腿继续走
    carry = []
    for f, s in ((1, 1), (7, 0), (13, -1), (19, 0), (25, 1)):
        carry.append((f, [
            ("leg.L", (r(24) * s, 0, 0), None),
            ("leg.R", (r(-24) * s, 0, 0), None),
            ("arm.L", (r(-78), 0, 0), None),
            ("arm.R", (r(-78), 0, 0), None),
            ("spine", (r(6), 0, 0), None),
            ("hips", (0, 0, 0), (0, 0, 0.030 if abs(s) else 0.0)),
        ]))
    make_action("Carry", carry)

    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 25
    bpy.context.scene.render.fps = 24

    return arm_obj, mesh_obj, log_obj


# ----------------------------------------------------------------- 导出

def export(name, objs):
    path = os.path.join(OUT_DIR, name + ".glb")
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]

    want = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_nla_strips=False,
        export_skins=True,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
        export_normals=True,
    )
    props = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
    kwargs = {k: v for k, v in want.items() if k in props}
    bpy.ops.export_scene.gltf(**kwargs)
    print("EXPORTED", path, os.path.getsize(path))


# ----------------------------------------------------------------- 预览渲染

def render_preview():
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 48
    sc.cycles.use_denoising = True
    sc.render.resolution_x = 1200
    sc.render.resolution_y = 900
    sc.render.filepath = PREVIEW
    sc.view_settings.view_transform = "Standard"
    try:
        sc.view_settings.view_transform = "Khronos PBR Neutral"
    except TypeError:
        pass
    sc.view_settings.look = "None"
    sc.view_settings.exposure = 0.0

    world = bpy.data.worlds.new("W")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.50, 0.60, 0.74, 1.0)
        bg.inputs[1].default_value = 0.45

    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = 2.2
    sun_data.angle = math.radians(8)
    sun = bpy.data.objects.new("Sun", sun_data)
    sc.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50), 0, math.radians(35))

    floor_mat = mat("FloorPreview", (0.30, 0.42, 0.22), 1.0)
    box("floor", 90, 90, 0.4, (0, 0, -0.2), floor_mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 50.0
    cam = bpy.data.objects.new("Cam", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    cam.location = (3.0, -32.0, 46.0)

    target = bpy.data.objects.new("Target", None)
    sc.collection.objects.link(target)
    target.location = (3.0, 1.0, 0.5)
    c = cam.constraints.new("TRACK_TO")
    c.target = target
    c.track_axis = "TRACK_NEGATIVE_Z"
    c.up_axis = "UP_Y"

    bpy.ops.render.render(write_still=True)
    print("PREVIEW", PREVIEW)


# ----------------------------------------------------------------- 主流程

def main():
    fresh()
    M = build_materials()

    house = build_house(M)
    export("house", [house])
    house_hd = build_house_hd(M)
    export("house_hd", [house_hd])
    house_hd.location = (74.0, 74.0, 0)
    house.location = (-12.0, -8.0, 0)

    storage = build_storage(M)
    export("storage", [storage])
    storage.location = (-4.5, -8.0, 0)

    wood = build_woodcutter(M)
    export("woodcutter", [wood])
    wood.location = (3.0, -8.0, 0)

    gatherer = build_gatherer(M)
    export("gatherer", [gatherer])
    gatherer.location = (9.5, -8.0, 0)

    hunter = build_hunter(M)
    export("hunter", [hunter])
    hunter.location = (-12.0, 1.0, 0)

    firewood = build_firewood(M)
    export("firewood", [firewood])
    firewood.location = (-4.5, 1.0, 0)

    well = build_well(M)
    export("well", [well])
    well.location = (2.0, 1.0, 0)

    hospital = build_hospital(M)
    export("hospital", [hospital])
    hospital.location = (8.5, 1.0, 0)

    trade = build_trade(M)
    export("trade", [trade])
    trade.location = (17.0, 1.0, 0)

    quarry = build_quarry(M)
    export("quarry", [quarry])
    quarry.location = (-12.0, 9.0, 0)

    farm = build_farm(M)
    export("farm", [farm])
    farm.location = (-4.0, 11.0, 0)

    tailor = build_tailor(M)
    export("tailor", [tailor])
    tailor.location = (6.0, 9.0, 0)

    blacksmith = build_blacksmith(M)
    export("blacksmith", [blacksmith])
    blacksmith.location = (12.5, 9.0, 0)

    arm_obj, mesh_obj, log_obj = build_character(M)
    export("character", [arm_obj, mesh_obj, log_obj])
    arm_obj.location = (18.0, 9.5, 0)

    house_stone = build_house_stone(M)
    tavern = build_tavern(M)
    export("tavern", [tavern])
    tavern.location = (73.0, 73.0, 0)

    export("house_stone", [house_stone])
    house_stone.location = (15.5, -8.0, 0)

    house_manor = build_house_manor(M)
    export("house_manor", [house_manor])
    house_manor.location = (21.5, -8.0, 0)

    windmill_body, windmill_blades = build_windmill(M)
    export("windmill", [windmill_body, windmill_blades])
    windmill_body.location = (60.0, 60.0, 0)
    windmill_blades.location = (60.0, 60.0, 0)

    church = build_church(M)
    export("church", [church])
    church.location = (61.0, 61.0, 0)

    dock = build_dock(M)
    export("dock", [dock])
    dock.location = (62.0, 62.0, 0)

    fountain = build_fountain(M)
    export("fountain", [fountain])
    fountain.location = (69.0, 69.0, 0)

    bridge = build_bridge(M)
    export("bridge", [bridge])
    bridge.location = (70.0, 70.0, 0)

    boat = build_prop_boat(M)
    export("prop_boat", [boat])
    boat.location = (63.0, 63.0, 0)

    chicken = build_prop_chicken(M)
    export("prop_chicken", [chicken])
    chicken.location = (66.0, 66.0, 0)

    dog = build_prop_dog(M)
    export("prop_dog", [dog])
    dog.location = (67.0, 67.0, 0)

    for name, fn in (
        ("prop_clothesline", build_prop_clothesline),
        ("prop_woodpile", build_prop_woodpile),
        ("prop_haycart", build_prop_haycart),
        ("prop_trough", build_prop_trough),
        ("prop_signpost", build_prop_signpost),
        ("prop_veggarden", build_prop_veggarden),
        ("prop_scarecrow", build_prop_scarecrow),
        ("prop_pier", build_prop_pier),
        ("prop_ship", build_prop_ship),
        ("prop_sheep", build_prop_sheep),
        ("prop_stoneblocks", build_prop_stoneblocks),
        ("prop_stall", build_prop_stall),
        ("prop_anvil_yard", build_prop_anvil_yard),
    ):
        ob = fn(M)
        export(name, [ob])
        ob.location = (68.0, 68.0, 0)

    row = build_house_row(M)
    export("house_row", [row])
    row.location = (64.0, 64.0, 0)

    carp = build_carpenter(M)
    export("carpenter", [carp])
    carp.location = (65.0, 65.0, 0)

    # 道具（只导出，不进预览合影）
    for name, fn in (
        ("prop_cart", build_prop_cart),
        ("prop_haystack", build_prop_haystack),
        ("prop_barrel", build_prop_barrel),
        ("prop_crate", build_prop_crate),
        ("prop_bench", build_prop_bench),
        ("prop_lamp", build_prop_lamp),
        ("prop_fence", build_prop_fence),
    ):
        ob = fn(M)
        export(name, [ob])
        ob.location = (60.0, 60.0, 0)

    school = realize(M, special_buildings.school_parts(), "school")
    export("school", [school])
    school.location = (76.0, 8.0, 0)

    pasture = realize(M, special_buildings.pasture_parts(), "pasture")
    export("pasture", [pasture])
    pasture.location = (76.0, 14.0, 0)

    if os.environ.get("FZ_SKIP_PREVIEW") == "1":
        print("DONE")
        return
    try:
        render_preview()
    except Exception as exc:
        print("SKIP preview", exc)
    blend_path = os.environ.get("FZ_BLEND_OUT", r"D:\01_code\00_fzzc_art\assets.blend")
    try:
        os.makedirs(os.path.dirname(blend_path), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    except Exception as exc:
        print("SKIP blend save", exc)
    print("DONE")


main()

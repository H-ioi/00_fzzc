"""
可达目标 · 效果图

和 concept_render.py 的区别：
  - 只用项目里现成的 16 种建筑，不虚构新建筑
  - 地形保持平坦（不做悬崖/瀑布/河道，那是几周以上的重构）
  - 等距正交相机 + 烘焙风格材质 + 地面装饰 + 景深调色

也就是"材质 + 装饰 + 相机与后期"三件事做完之后的样子，对应 3~4 周的工作量。

用法：
    blender --background --factory-startup --python tools/target_render.py -- [宽] [高] [采样] [输出]
"""

import bpy
import bmesh
import math
import os
import sys
from mathutils import Vector
from mathutils import noise as bnoise

argv = sys.argv
args = argv[argv.index("--") + 1:] if "--" in argv else []
RES_X = int(args[0]) if len(args) > 0 else 1600
RES_Y = int(args[1]) if len(args) > 1 else 900
SAMPLES = int(args[2]) if len(args) > 2 else 64
OUT = args[3] if len(args) > 3 else r"D:\01_code\00_fzzc\tools\target.png"

MODELS = r"D:\01_code\00_fzzc\assets\models"


def rnd():
    return bnoise.random()


# ----------------------------------------------------------------- 材质

def nodes_new(mat):
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return nt, bsdf


def add_bump(nt, bsdf, tex_out, strength=0.25):
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    nt.links.new(tex_out, bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])


def mat_noise(name, c1, c2, scale=7.0, rough=0.85, bump=0.25, stretch=None):
    m = bpy.data.materials.new("C_" + name)
    nt, bsdf = nodes_new(m)
    coord = nt.nodes.new("ShaderNodeTexCoord")
    tex = nt.nodes.new("ShaderNodeTexNoise")
    tex.inputs["Scale"].default_value = scale
    tex.inputs["Detail"].default_value = 8.0
    tex.inputs["Roughness"].default_value = 0.62
    if stretch:
        mp = nt.nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = stretch
        nt.links.new(coord.outputs["Object"], mp.inputs["Vector"])
        nt.links.new(mp.outputs["Vector"], tex.inputs["Vector"])
    else:
        nt.links.new(coord.outputs["Object"], tex.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*c1, 1.0)
    ramp.color_ramp.elements[1].color = (*c2, 1.0)
    nt.links.new(tex.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    add_bump(nt, bsdf, tex.outputs["Fac"], bump)
    return m


def mat_brick(name, c1, c2, mortar, scale=18.0, rough=0.8):
    m = bpy.data.materials.new("C_" + name)
    nt, bsdf = nodes_new(m)
    coord = nt.nodes.new("ShaderNodeTexCoord")
    brick = nt.nodes.new("ShaderNodeTexBrick")
    brick.inputs["Scale"].default_value = scale
    brick.inputs["Mortar Size"].default_value = 0.035
    brick.inputs["Brick Width"].default_value = 0.55
    brick.inputs["Row Height"].default_value = 0.24
    brick.inputs["Color1"].default_value = (*c1, 1.0)
    brick.inputs["Color2"].default_value = (*c2, 1.0)
    brick.inputs["Mortar"].default_value = (*mortar, 1.0)
    nt.links.new(coord.outputs["Object"], brick.inputs["Vector"])
    nt.links.new(brick.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    add_bump(nt, bsdf, brick.outputs["Fac"], 0.35)
    return m


def mat_stone(name):
    m = bpy.data.materials.new("C_" + name)
    nt, bsdf = nodes_new(m)
    coord = nt.nodes.new("ShaderNodeTexCoord")
    vor = nt.nodes.new("ShaderNodeTexVoronoi")
    vor.feature = "DISTANCE_TO_EDGE"
    vor.inputs["Scale"].default_value = 14.0
    nt.links.new(coord.outputs["Object"], vor.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.30, 0.29, 0.27, 1)
    ramp.color_ramp.elements[1].color = (0.52, 0.51, 0.48, 1)
    nt.links.new(vor.outputs["Distance"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.9
    add_bump(nt, bsdf, vor.outputs["Distance"], 0.5)
    return m


def build_palette():
    return {
        "Plaster": mat_noise("plaster", (0.50, 0.44, 0.32), (0.78, 0.72, 0.56), 11.0, 0.9, 0.45),
        "Wood": mat_noise("wood", (0.055, 0.034, 0.018), (0.21, 0.13, 0.075), 26.0, 0.85, 0.55,
                          stretch=(1.0, 8.0, 1.0)),
        "WoodLight": mat_noise("woodlight", (0.11, 0.07, 0.04), (0.34, 0.23, 0.13), 22.0, 0.85, 0.55,
                               stretch=(1.0, 7.0, 1.0)),
        "BarnWall": mat_noise("barn", (0.10, 0.065, 0.035), (0.32, 0.21, 0.12), 20.0, 0.88, 0.5,
                              stretch=(1.0, 6.0, 1.0)),
        "Stone": mat_stone("stone"),
        "StoneDark": mat_stone("stonedark"),
        "RoofShingle": mat_brick("roof", (0.20, 0.075, 0.050), (0.38, 0.165, 0.105), (0.14, 0.085, 0.065), 30.0, 0.8),
        "RoofDark": mat_brick("roofdark", (0.15, 0.065, 0.050), (0.30, 0.14, 0.105), (0.11, 0.075, 0.060), 30.0, 0.8),
        "Thatch": mat_noise("thatch", (0.30, 0.24, 0.10), (0.46, 0.37, 0.16), 34.0, 0.95, 0.55,
                            stretch=(1.0, 10.0, 1.0)),
        "Hay": mat_noise("hay", (0.36, 0.29, 0.11), (0.50, 0.41, 0.17), 30.0, 0.95, 0.5,
                         stretch=(1.0, 9.0, 1.0)),
        "Pelt": mat_noise("pelt", (0.24, 0.16, 0.10), (0.36, 0.26, 0.17), 20.0, 0.95, 0.3),
        "Basket": mat_noise("basket", (0.30, 0.22, 0.12), (0.42, 0.32, 0.18), 24.0, 0.95, 0.35),
        "Berry": mat_noise("berry", (0.22, 0.03, 0.04), (0.36, 0.07, 0.08), 30.0, 0.8, 0.2),
        "Crop": mat_noise("crop", (0.14, 0.20, 0.045), (0.26, 0.32, 0.085), 32.0, 0.9, 0.45),
        "Wheat": mat_noise("wheat", (0.38, 0.31, 0.10), (0.54, 0.45, 0.16), 32.0, 0.9, 0.45),
        "Dirt": mat_noise("dirt", (0.13, 0.09, 0.055), (0.24, 0.17, 0.10), 16.0, 0.98, 0.5),
        "Rope": mat_noise("rope", (0.36, 0.31, 0.21), (0.48, 0.42, 0.29), 40.0, 0.95, 0.3),
        "Sign": mat_noise("sign", (0.28, 0.04, 0.035), (0.42, 0.08, 0.06), 12.0, 0.8, 0.2),
        "Skin": mat_noise("skin", (0.44, 0.29, 0.20), (0.55, 0.38, 0.27), 12.0, 0.7, 0.1),
        "Tunic": mat_noise("tunic", (0.12, 0.16, 0.08), (0.20, 0.25, 0.13), 24.0, 0.9, 0.25),
        "Pants": mat_noise("pants", (0.10, 0.095, 0.08), (0.17, 0.16, 0.14), 24.0, 0.9, 0.25),
        "Boots": mat_noise("boots", (0.06, 0.045, 0.032), (0.11, 0.085, 0.06), 20.0, 0.85, 0.25),
        "Water": None,
    }


def mat_ground():
    m = bpy.data.materials.new("C_ground")
    nt, bsdf = nodes_new(m)
    coord = nt.nodes.new("ShaderNodeTexCoord")

    big = nt.nodes.new("ShaderNodeTexNoise")
    big.inputs["Scale"].default_value = 0.30
    big.inputs["Detail"].default_value = 6.0
    nt.links.new(coord.outputs["Object"], big.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.060, 0.110, 0.032, 1)
    ramp.color_ramp.elements[1].color = (0.140, 0.210, 0.065, 1)
    nt.links.new(big.outputs["Fac"], ramp.inputs["Fac"])

    fine = nt.nodes.new("ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = 9.0
    fine.inputs["Detail"].default_value = 10.0
    nt.links.new(coord.outputs["Object"], fine.inputs["Vector"])
    fmix = nt.nodes.new("ShaderNodeMixRGB")
    fmix.blend_type = "MULTIPLY"
    fmix.inputs["Fac"].default_value = 0.35
    nt.links.new(ramp.outputs["Color"], fmix.inputs["Color1"])
    fmix.inputs["Color2"].default_value = (0.85, 0.90, 0.75, 1)

    nt.links.new(fmix.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.96
    add_bump(nt, bsdf, fine.outputs["Fac"], 0.35)
    return m


# ----------------------------------------------------------------- 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build_ground(material):
    bpy.ops.mesh.primitive_plane_add(size=260)
    ob = bpy.context.object
    ob.name = "ground"
    ob.data.materials.append(material)
    return ob


def catmull(pts, n=10):
    """把折线插值成平滑曲线，避免急转弯处路带自交产生黑块。"""
    out = []
    m = len(pts)
    for i in range(m - 1):
        p0 = pts[max(0, i - 1)]
        p1 = pts[i]
        p2 = pts[i + 1]
        p3 = pts[min(m - 1, i + 2)]
        for t in range(n):
            u = t / n
            u2 = u * u
            u3 = u2 * u
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * u
                       + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * u2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * u3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * u
                       + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * u2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * u3)
            out.append((x, y))
    out.append(pts[-1])
    return out


def build_path(pts, width, mat, z=0.02):
    """沿平滑曲线生成连续的土路带。"""
    P = [Vector((p[0], p[1], z)) for p in catmull(pts)]
    norms = []
    for i in range(len(P)):
        if i == 0:
            d = (P[1] - P[0]).normalized()
        elif i == len(P) - 1:
            d = (P[-1] - P[-2]).normalized()
        else:
            d = ((P[i] - P[i - 1]).normalized() + (P[i + 1] - P[i]).normalized()).normalized()
        norms.append(Vector((-d.y, d.x, 0.0)) * (width * 0.5))

    bm = bmesh.new()
    left = []
    right = []
    for i, p in enumerate(P):
        left.append(bm.verts.new(p + norms[i]))
        right.append(bm.verts.new(p - norms[i]))
    for i in range(len(P) - 1):
        bm.faces.new((left[i], right[i], right[i + 1], left[i + 1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("path")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("path", me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(mat)
    return ob


def build_roads(mat_dirt):
    # 每条路给不同的 z，避免交叉处共面产生自阴影黑斑
    paths = [
        ([(-40, 7), (-26, 3), (-14, 6), (-2, 2), (10, 4), (22, 0), (34, 2)], 3.0),
        ([(-14, 6), (-16, 14), (-16, 22)], 2.4),
        ([(-2, 2), (0, -8), (2, -18)], 2.4),
        ([(-16, 22), (-30, 26)], 2.4),
    ]
    for i, (pts, w) in enumerate(paths):
        build_path(pts, w, mat_dirt, 0.02 + i * 0.035)


def import_glb(name):
    path = os.path.join(MODELS, name + ".glb")
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in new if o.parent is None]
    for o in new:
        o.select_set(False)
    empty = bpy.data.objects.new("rig_" + name, None)
    bpy.context.scene.collection.objects.link(empty)
    for r in roots:
        r.parent = empty
    return empty


def place(rig, x, y, rot=0.0):
    rig.location = (x, y, 0.0)
    rig.rotation_euler = (0, 0, rot)


# ----------------------------------------------------------------- 装饰

def make_tree_mesh(mat_leaf, mat_bark):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=6,
                          radius1=0.18, radius2=0.11, depth=1.8)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 0.9)), verts=bm.verts)
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8,
                          radius1=1.35, radius2=0.5, depth=2.9)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 2.9)), verts=bm.verts)
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8,
                          radius1=0.9, radius2=0.0, depth=2.0)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 4.4)), verts=bm.verts)
    me = bpy.data.meshes.new("tree")
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat_bark)
    me.materials.append(mat_leaf)
    for p in me.polygons:
        p.material_index = 0 if p.center.z < 1.9 else 1
    return me


def make_bush_mesh(mat_leaf):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=5, radius=0.55)
    bmesh.ops.scale(bm, vec=Vector((1.0, 1.0, 0.75)), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 0.32)), verts=bm.verts)
    me = bpy.data.meshes.new("bush")
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat_leaf)
    return me


def scatter(me, count, xr, yr, blocked, label):
    made = 0
    tries = 0
    while made < count and tries < count * 40:
        tries += 1
        x = xr[0] + rnd() * (xr[1] - xr[0])
        y = yr[0] + rnd() * (yr[1] - yr[0])
        skip = False
        for bx, by, br in blocked:
            if (x - bx) ** 2 + (y - by) ** 2 < br * br:
                skip = True
                break
        if skip:
            continue
        ob = bpy.data.objects.new("%s_%d" % (label, made), me)
        bpy.context.scene.collection.objects.link(ob)
        s = 0.7 + rnd() * 0.8
        ob.location = (x, y, 0.0)
        ob.rotation_euler = (0, 0, rnd() * math.pi * 2)
        ob.scale = (s, s, s * (0.85 + rnd() * 0.4))
        made += 1
    return made


def build_fences(mat_wood):
    """农田四周围栏：点之间连柱子与横杆。"""
    lines = [
        ((-3.5, -20.5), (7.5, -20.5)),
        ((-3.5, -9.5), (7.5, -9.5)),
        ((-3.5, -20.5), (-3.5, -9.5)),
        ((7.5, -20.5), (7.5, -9.5)),
    ]
    for (x0, y0), (x1, y1) in lines:
        length = math.hypot(x1 - x0, y1 - y0)
        n = max(2, int(length / 1.8))
        for i in range(n + 1):
            t = i / n
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y, 0.5))
            ob = bpy.context.object
            ob.scale = (0.13, 0.13, 1.0)
            ob.data.materials.append(mat_wood)
        # 两道横杆
        for z in (0.45, 0.82):
            bpy.ops.mesh.primitive_cube_add(size=1, location=((x0 + x1) / 2, (y0 + y1) / 2, z))
            ob = bpy.context.object
            ang = math.atan2(y1 - y0, x1 - x0)
            ob.rotation_euler = (0, 0, ang)
            ob.scale = (length, 0.06, 0.06)
            ob.data.materials.append(mat_wood)


def build_flowers():
    cols = [(0.72, 0.62, 0.18), (0.80, 0.76, 0.62), (0.62, 0.26, 0.30)]
    meshes = []
    for c in cols:
        me = bpy.data.meshes.new("flower")
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=5, v_segments=3, radius=0.055)
        bm.to_mesh(me)
        bm.free()
        m = bpy.data.materials.new("C_flower")
        nt, bsdf = nodes_new(m)
        bsdf.inputs["Base Color"].default_value = (*c, 1)
        bsdf.inputs["Roughness"].default_value = 0.85
        me.materials.append(m)
        meshes.append(me)

    made = 0
    tries = 0
    while made < 520 and tries < 6000:
        tries += 1
        x = -46 + rnd() * 92
        y = -26 + rnd() * 52
        # 避开街道
        if abs(y) < 3.6 or (abs(x + 14) < 3.6 and y > 0) or (abs(x - 6) < 3.6 and y < 0):
            continue
        if abs(x + 2) < 8 and abs(y) < 6:
            continue
        ob = bpy.data.objects.new("flower_%d" % made, meshes[made % 3])
        bpy.context.scene.collection.objects.link(ob)
        ob.location = (x, y, 0.10)
        ob.scale = (0.8 + rnd() * 0.6,) * 3
        made += 1
    return made


# ----------------------------------------------------------------- 渲染

def setup_world():
    world = bpy.data.worlds.new("W")
    bpy.context.scene.world = world
    world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    sky = nt.nodes.new("ShaderNodeTexSky")
    for t in ("MULTIPLE_SCATTERING", "SINGLE_SCATTERING"):
        try:
            sky.sky_type = t
            break
        except TypeError:
            continue
    for attr, val in (
        ("sun_elevation", math.radians(34.0)),
        ("sun_rotation", math.radians(120.0)),
        ("altitude", 200.0),
        ("air_density", 0.8),
        ("dust_density", 1.0),
    ):
        if hasattr(sky, attr):
            try:
                setattr(sky, attr, val)
            except Exception:
                pass

    bg_cam = nt.nodes.new("ShaderNodeBackground")
    bg_cam.inputs["Strength"].default_value = 1.1
    bg_lit = nt.nodes.new("ShaderNodeBackground")
    bg_lit.inputs["Strength"].default_value = 0.12
    nt.links.new(sky.outputs["Color"], bg_cam.inputs["Color"])
    nt.links.new(sky.outputs["Color"], bg_lit.inputs["Color"])
    lp = nt.nodes.new("ShaderNodeLightPath")
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(lp.outputs["Is Camera Ray"], mix.inputs["Fac"])
    nt.links.new(bg_lit.outputs["Background"], mix.inputs[1])
    nt.links.new(bg_cam.outputs["Background"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])


def setup_sun():
    d = bpy.data.lights.new("Sun", "SUN")
    d.energy = 2.4
    d.angle = math.radians(3.0)
    d.color = (1.0, 0.93, 0.80)
    ob = bpy.data.objects.new("Sun", d)
    bpy.context.scene.collection.objects.link(ob)
    ob.rotation_euler = (math.radians(46.0), 0.0, math.radians(-32.0))


def setup_camera():
    d = bpy.data.cameras.new("Cam")
    d.type = "ORTHO"
    d.ortho_scale = 47.0
    cam = bpy.data.objects.new("Cam", d)
    bpy.context.scene.collection.objects.link(cam)
    # 等距视角
    dist = 120.0
    elev = math.radians(31.0)
    cam.location = (-6.0, -dist * math.cos(elev) + 6.0, dist * math.sin(elev))
    bpy.context.scene.camera = cam

    target = bpy.data.objects.new("Target", None)
    bpy.context.scene.collection.objects.link(target)
    target.location = (-6.0, 6.0, 2.8)
    c = cam.constraints.new("TRACK_TO")
    c.target = target
    c.track_axis = "TRACK_NEGATIVE_Z"
    c.up_axis = "UP_Y"

    # 轻微景深，模仿移轴效果
    d.dof.use_dof = True
    d.dof.focus_distance = dist
    d.dof.aperture_fstop = 5.6
    return cam


def setup_render():
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 5
    sc.render.resolution_x = RES_X
    sc.render.resolution_y = RES_Y
    sc.render.filepath = OUT
    sc.render.image_settings.file_format = "PNG"
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = -0.35


# ----------------------------------------------------------------- 主流程

def main():
    clear()
    palette = build_palette()
    m_ground = mat_ground()

    build_ground(m_ground)
    build_roads(palette["Dirt"])

    layout = [
        ("woodcutter", -31, 11, 0.10),
        ("gatherer", 20, 8, 0.05),
        ("house", -25, 3, 0.0),
        ("house", -18, 10, 0.04),
        ("house_stone", -12, 3, -0.03),
        ("house_manor", -5, 9, 0.02),
        ("tailor", 2, 12, -0.05),
        ("blacksmith", 3, 4, 0.0),
        ("hospital", 11, 8, 0.02),
        ("trade", 17, 1, -0.03),
        ("hunter", -29, -7, 0.06),
        ("firewood", -23, -11, 0.0),
        ("well", -18, -4, 0.0),
        ("storage", -8, -10, 0.0),
        ("farm", 2, -15, 0.0),
        ("quarry", 14, -8, 0.04),
    ]

    for name, x, y, rot in layout:
        rig = import_glb(name)
        place(rig, x, y, rot)

    # 替换材质
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        for slot in ob.material_slots:
            if slot.material is None:
                continue
            key = slot.material.name.split(".")[0]
            rep = palette.get(key)
            if rep is not None:
                slot.material = rep
            elif key == "Glass":
                m = bpy.data.materials.new("C_glass")
                nt, bsdf = nodes_new(m)
                bsdf.inputs["Base Color"].default_value = (0.05, 0.075, 0.09, 1)
                bsdf.inputs["Roughness"].default_value = 0.18
                bsdf.inputs["Metallic"].default_value = 0.25
                slot.material = m

    # 植被
    m_leaf = mat_noise("leaf", (0.050, 0.100, 0.032), (0.115, 0.185, 0.060), 3.5, 0.9, 0.5)
    m_bark = mat_noise("bark", (0.055, 0.038, 0.024), (0.115, 0.080, 0.050), 12.0, 0.9, 0.4,
                       stretch=(1.0, 5.0, 1.0))
    tree_me = make_tree_mesh(m_leaf, m_bark)
    bush_me = make_bush_mesh(m_leaf)

    blocked = [(-10.0, 2.0, 25.0), (2.0, -15.0, 9.0)]
    for name, x, y, rot in layout:
        r = 4.0
        if name in ("storage", "hospital", "trade"):
            r = 5.2
        elif name == "farm":
            r = 8.0
        blocked.append((x, y, r))
    n_tree = scatter(tree_me, 150, (-64, 64), (-42, 42), blocked, "tree")
    n_bush = scatter(bush_me, 170, (-56, 56), (-36, 36), blocked, "bush")
    n_flower = build_flowers()
    build_fences(palette["Wood"])
    print("DECOR", n_tree, n_bush, n_flower)

    setup_world()
    setup_sun()
    setup_camera()
    setup_render()
    bpy.ops.render.render(write_still=True)
    print("RENDERED", OUT)


main()

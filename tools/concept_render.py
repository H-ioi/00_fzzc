"""
未来优化目标 · 概念渲染图

把现有的低模资产放进一个"理想化"的场景里渲染出来，用来表达后续三个方向
（地形起伏 / 材质细节 / 大气与光照）都做完之后的目标画面。
这不是游戏内实时截图，是一张概念图。

用法：
    blender --background --factory-startup --python tools/concept_render.py -- [宽] [高] [采样] [输出路径]
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
OUT = args[3] if len(args) > 3 else r"D:\01_code\00_fzzc\tools\concept.png"

MODELS = r"D:\01_code\00_fzzc\assets\models"


# ----------------------------------------------------------------- 噪声

def fbm(x, y, octaves=5):
    v = 0.0
    amp = 1.0
    f = 1.0
    for _ in range(octaves):
        v += amp * bnoise.noise(Vector((x * f, y * f, 0.5)))
        f *= 2.0
        amp *= 0.5
    return v


def smoothstep(a, b, x):
    if a == b:
        return 1.0 if x >= b else 0.0
    t = (x - a) / (b - a)
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


VILLAGE = Vector((-4.0, 2.0))


def height(x, y):
    # 基础地面抬高到 4~13 米，只有河道会低于水面
    h = 4.0 + 9.0 * (fbm(x * 0.011, y * 0.011, 5) * 0.5 + 0.5)
    d = math.hypot(x, y)
    h += max(0.0, (d - 110.0) * 0.40)          # 远处隆起成山
    # 河谷
    river_x = 30.0 + 14.0 * math.sin(y * 0.0095)
    dx = abs(x - river_x)
    h -= 13.0 * math.exp(-(dx * dx) / (2.0 * 12.0 * 12.0))
    # 村庄平台
    r = math.hypot(x - VILLAGE.x, y - VILLAGE.y)
    t = smoothstep(40.0, 20.0, r)
    h = h * (1.0 - t) + 5.0 * t
    return h


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


def mat_terrain():
    m = bpy.data.materials.new("C_terrain")
    nt, bsdf = nodes_new(m)

    coord = nt.nodes.new("ShaderNodeTexCoord")
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Normal"], sep.inputs["Vector"])

    # 坡度：法线 Z 越小越陡 -> 岩石
    slope = nt.nodes.new("ShaderNodeMapRange")
    slope.inputs["From Min"].default_value = 0.62
    slope.inputs["From Max"].default_value = 0.98
    slope.inputs["To Min"].default_value = 1.0
    slope.inputs["To Max"].default_value = 0.0
    nt.links.new(sep.outputs["Z"], slope.inputs["Value"])

    grass = nt.nodes.new("ShaderNodeTexNoise")
    grass.inputs["Scale"].default_value = 0.55
    grass.inputs["Detail"].default_value = 10.0
    nt.links.new(coord.outputs["Object"], grass.inputs["Vector"])
    gramp = nt.nodes.new("ShaderNodeValToRGB")
    gramp.color_ramp.elements[0].color = (0.085, 0.150, 0.050, 1)
    gramp.color_ramp.elements[1].color = (0.185, 0.280, 0.085, 1)
    nt.links.new(grass.outputs["Fac"], gramp.inputs["Fac"])

    rock = nt.nodes.new("ShaderNodeTexNoise")
    rock.inputs["Scale"].default_value = 3.5
    rock.inputs["Detail"].default_value = 8.0
    nt.links.new(coord.outputs["Object"], rock.inputs["Vector"])
    rramp = nt.nodes.new("ShaderNodeValToRGB")
    rramp.color_ramp.elements[0].color = (0.26, 0.24, 0.21, 1)
    rramp.color_ramp.elements[1].color = (0.40, 0.38, 0.34, 1)
    nt.links.new(rock.outputs["Fac"], rramp.inputs["Fac"])

    mix = nt.nodes.new("ShaderNodeMixRGB")
    nt.links.new(slope.outputs["Result"], mix.inputs["Fac"])
    nt.links.new(gramp.outputs["Color"], mix.inputs["Color1"])
    nt.links.new(rramp.outputs["Color"], mix.inputs["Color2"])

    # 水边沙滩
    sepx = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Position"], sepx.inputs["Vector"])
    sandmask = nt.nodes.new("ShaderNodeMapRange")
    sandmask.inputs["From Min"].default_value = 0.0
    sandmask.inputs["From Max"].default_value = 1.6
    sandmask.inputs["To Min"].default_value = 1.0
    sandmask.inputs["To Max"].default_value = 0.0
    nt.links.new(sepx.outputs["Z"], sandmask.inputs["Value"])

    sand = nt.nodes.new("ShaderNodeMixRGB")
    nt.links.new(sandmask.outputs["Result"], sand.inputs["Fac"])
    nt.links.new(mix.outputs["Color"], sand.inputs["Color1"])
    sand.inputs["Color2"].default_value = (0.46, 0.41, 0.29, 1)

    nt.links.new(sand.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.95
    add_bump(nt, bsdf, grass.outputs["Fac"], 0.22)
    return m


def mat_water():
    m = bpy.data.materials.new("C_water")
    nt, bsdf = nodes_new(m)
    bsdf.inputs["Base Color"].default_value = (0.035, 0.085, 0.105, 1)
    bsdf.inputs["Roughness"].default_value = 0.04
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["IOR"].default_value = 1.33
    return m


# ----------------------------------------------------------------- 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build_terrain(material):
    size = 340.0
    seg = 240
    verts = []
    for j in range(seg + 1):
        for i in range(seg + 1):
            x = (i / seg - 0.5) * size
            y = (j / seg - 0.5) * size
            verts.append((x, y, height(x, y)))
    faces = []
    for j in range(seg):
        for i in range(seg):
            a = j * (seg + 1) + i
            faces.append((a, a + 1, a + seg + 2, a + seg + 1))
    me = bpy.data.meshes.new("terrain")
    me.from_pydata(verts, [], faces)
    me.update()
    ob = bpy.data.objects.new("terrain", me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(material)
    for p in me.polygons:
        p.use_smooth = True
    return ob


def build_water(material):
    bpy.ops.mesh.primitive_plane_add(size=420, location=(0, 0, 2.2))
    ob = bpy.context.object
    ob.name = "water"
    ob.data.materials.append(material)
    return ob


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


def place(rig, x, y, rot=0.0, scale=1.0):
    rig.location = (x, y, 5.0)
    rig.rotation_euler = (0, 0, rot)
    rig.scale = (scale, scale, scale)


def make_tree_mesh(mat_leaf, mat_bark):
    """一棵低模树：树干 + 两层锥形树冠。"""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=6,
                          radius1=0.20, radius2=0.12, depth=2.0)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 1.0)), verts=bm.verts)
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8,
                          radius1=1.55, radius2=0.55, depth=3.2)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 3.3)), verts=bm.verts)
    bmesh.ops.create_cone(bm, cap_ends=True, segments=8,
                          radius1=1.05, radius2=0.0, depth=2.2)
    bmesh.ops.translate(bm, vec=Vector((0, 0, 5.0)), verts=bm.verts)
    me = bpy.data.meshes.new("tree")
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat_bark)
    me.materials.append(mat_leaf)
    for p in me.polygons:
        p.material_index = 0 if p.center.z < 2.2 else 1
    return me


def scatter_trees(mat_leaf, mat_bark, count=520):
    tree_me = make_tree_mesh(mat_leaf, mat_bark)
    made = 0
    tries = 0
    while made < count and tries < count * 30:
        tries += 1
        x = (bnoise.random() - 0.5) * 300.0
        y = (bnoise.random() - 0.5) * 300.0
        z = height(x, y)
        if z < 3.4:
            continue
        if math.hypot(x - VILLAGE.x, y - VILLAGE.y) < 22.0:
            continue
        # 相机与村庄之间留出视线通道，避免前景大树挡住主体
        if y < -12.0 and abs(x + 4.0) < 30.0:
            continue
        if math.hypot(x - 30.0, y) < 16.0:
            continue
        s = 0.6 + bnoise.random() * 0.7
        ob = bpy.data.objects.new("tree_%d" % made, tree_me)
        bpy.context.scene.collection.objects.link(ob)
        ob.location = (x, y, z - 0.25)
        ob.rotation_euler = (0, 0, bnoise.random() * math.pi * 2.0)
        ob.scale = (s, s, s * (0.85 + bnoise.random() * 0.4))
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
    # Blender 5.0 把 Nishita 改名成 MULTIPLE_SCATTERING
    for t in ("MULTIPLE_SCATTERING", "SINGLE_SCATTERING", "NISHITA"):
        try:
            sky.sky_type = t
            break
        except TypeError:
            continue
    for attr, val in (
        ("sun_elevation", math.radians(22.0)),
        ("sun_rotation", math.radians(140.0)),
        ("altitude", 400.0),
        ("air_density", 1.0),
        ("dust_density", 1.4),
    ):
        if hasattr(sky, attr):
            try:
                setattr(sky, attr, val)
            except Exception:
                pass

    # 相机看到的天空保持明亮，但参与光照的部分压暗，避免整场被天光洗白
    bg_cam = nt.nodes.new("ShaderNodeBackground")
    bg_cam.inputs["Strength"].default_value = 0.22
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
    d.energy = 3.0
    d.angle = math.radians(2.2)
    d.color = (1.0, 0.82, 0.60)
    ob = bpy.data.objects.new("Sun", d)
    bpy.context.scene.collection.objects.link(ob)
    ob.rotation_euler = (math.radians(64.0), 0.0, math.radians(-40.0))
    return ob


def setup_haze():
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 14))
    ob = bpy.context.object
    ob.name = "haze"
    ob.scale = (360, 360, 30)
    m = bpy.data.materials.new("haze")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    vol.inputs["Density"].default_value = 0.00030
    vol.inputs["Color"].default_value = (1.0, 0.93, 0.84, 1)
    vol.inputs["Anisotropy"].default_value = 0.45
    nt.links.new(vol.outputs["Volume"], out.inputs["Volume"])
    ob.data.materials.append(m)
    return ob


def setup_camera():
    d = bpy.data.cameras.new("Cam")
    d.lens = 32
    cam = bpy.data.objects.new("Cam", d)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = (-12.0, -40.0, 13.0)
    bpy.context.scene.camera = cam
    target = bpy.data.objects.new("Target", None)
    bpy.context.scene.collection.objects.link(target)
    target.location = (2.0, 8.0, 6.0)
    c = cam.constraints.new("TRACK_TO")
    c.target = target
    c.track_axis = "TRACK_NEGATIVE_Z"
    c.up_axis = "UP_Y"
    return cam


def setup_render():
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 6
    sc.cycles.volume_bounces = 1
    sc.render.resolution_x = RES_X
    sc.render.resolution_y = RES_Y
    sc.render.resolution_percentage = 100
    sc.render.filepath = OUT
    sc.render.image_settings.file_format = "PNG"
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = -0.35


# ----------------------------------------------------------------- 主流程

def main():
    clear()
    m_terrain = mat_terrain()
    m_water = mat_water()

    build_terrain(m_terrain)
    build_water(m_water)

    # 程序化材质表
    mats = {
        "Plaster": mat_noise("plaster", (0.50, 0.44, 0.32), (0.78, 0.72, 0.56), 11.0, 0.9, 0.45),
        "Wood": mat_noise("wood", (0.055, 0.034, 0.018), (0.21, 0.13, 0.075), 26.0, 0.85, 0.55,
                          stretch=(1.0, 8.0, 1.0)),
        "WoodLight": mat_noise("woodlight", (0.11, 0.07, 0.04), (0.34, 0.23, 0.13), 22.0, 0.85, 0.55,
                               stretch=(1.0, 7.0, 1.0)),
        "BarnWall": mat_noise("barn", (0.10, 0.065, 0.035), (0.32, 0.21, 0.12), 20.0, 0.88, 0.5,
                              stretch=(1.0, 6.0, 1.0)),
        "Stone": mat_stone("stone"),
        "StoneDark": mat_stone("stonedark"),
        "Glass": None,
        "RoofShingle": mat_brick("roof", (0.20, 0.075, 0.050), (0.38, 0.165, 0.105), (0.14, 0.085, 0.065), 30.0, 0.8),
        "RoofDark": mat_brick("roofdark", (0.15, 0.065, 0.050), (0.30, 0.14, 0.105), (0.11, 0.075, 0.060), 30.0, 0.8),
        "Thatch": mat_noise("thatch", (0.38, 0.30, 0.13), (0.52, 0.42, 0.19), 30.0, 0.95, 0.5,
                            stretch=(1.0, 9.0, 1.0)),
        "Hay": mat_noise("hay", (0.42, 0.34, 0.14), (0.55, 0.46, 0.20), 26.0, 0.95, 0.45,
                         stretch=(1.0, 8.0, 1.0)),
        "Pelt": mat_noise("pelt", (0.24, 0.16, 0.10), (0.36, 0.26, 0.17), 20.0, 0.95, 0.3),
        "Basket": mat_noise("basket", (0.30, 0.22, 0.12), (0.42, 0.32, 0.18), 24.0, 0.95, 0.35),
        "Berry": mat_noise("berry", (0.22, 0.03, 0.04), (0.36, 0.07, 0.08), 30.0, 0.8, 0.2),
        "Crop": mat_noise("crop", (0.16, 0.22, 0.05), (0.28, 0.34, 0.09), 30.0, 0.9, 0.4),
        "Wheat": mat_noise("wheat", (0.42, 0.34, 0.12), (0.58, 0.48, 0.18), 30.0, 0.9, 0.4),
        "Dirt": mat_noise("dirt", (0.16, 0.11, 0.07), (0.26, 0.18, 0.11), 14.0, 0.95, 0.4),
        "Rope": mat_noise("rope", (0.36, 0.31, 0.21), (0.48, 0.42, 0.29), 40.0, 0.95, 0.3),
        "Sign": mat_noise("sign", (0.28, 0.04, 0.035), (0.42, 0.08, 0.06), 12.0, 0.8, 0.2),
        "Water": None,
        "Skin": mat_noise("skin", (0.44, 0.29, 0.20), (0.55, 0.38, 0.27), 12.0, 0.7, 0.1),
        "Tunic": mat_noise("tunic", (0.12, 0.16, 0.08), (0.20, 0.25, 0.13), 24.0, 0.9, 0.25),
        "Pants": mat_noise("pants", (0.10, 0.095, 0.08), (0.17, 0.16, 0.14), 24.0, 0.9, 0.25),
        "Boots": mat_noise("boots", (0.06, 0.045, 0.032), (0.11, 0.085, 0.06), 20.0, 0.85, 0.25),
    }

    layout = [
        ("house", -20, -8, 0.15),
        ("house", -14, -8, 0.0),
        ("house", -20, -2, -0.1),
        ("storage", -5, -10, 0.0),
        ("tailor", 3, -7, 0.25),
        ("blacksmith", 7, -1, 0.0),
        ("hospital", -2, 7, 0.1),
        ("trade", 11, 5, -0.2),
        ("woodcutter", -23, 4, 0.3),
        ("gatherer", 3, 2, 0.0),
        ("well", -9, 2, 0.0),
        ("firewood", -14, 6, 0.2),
        ("farm", 12, -14, 0.0),
        ("quarry", -27, -2, 0.0),
    ]

    for name, x, y, rot in layout:
        rig = import_glb(name)
        place(rig, x, y, rot)

    # 替换导入材质的节点树
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        for i, slot in enumerate(ob.material_slots):
            if slot.material is None:
                continue
            key = slot.material.name.split(".")[0]
            rep = mats.get(key)
            if rep is not None:
                slot.material = rep
            elif key == "Glass":
                m = bpy.data.materials.new("C_glass")
                nt, bsdf = nodes_new(m)
                bsdf.inputs["Base Color"].default_value = (0.03, 0.05, 0.06, 1)
                bsdf.inputs["Roughness"].default_value = 0.12
                bsdf.inputs["Metallic"].default_value = 0.3
                slot.material = m

    m_leaf = mat_noise("leaf", (0.055, 0.105, 0.040), (0.13, 0.20, 0.07), 3.0, 0.9, 0.5)
    m_bark = mat_noise("bark", (0.06, 0.04, 0.025), (0.12, 0.08, 0.05), 12.0, 0.9, 0.4,
                       stretch=(1.0, 5.0, 1.0))
    n = scatter_trees(m_leaf, m_bark)
    print("TREES", n)

    setup_world()
    setup_sun()
    setup_haze()
    setup_camera()
    setup_render()

    bpy.ops.render.render(write_still=True)
    print("RENDERED", OUT)


main()

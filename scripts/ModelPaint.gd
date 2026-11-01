class_name ModelPaint
extends RefCounted
## 用 Godot 侧统一调色板 + 三平面程序化着色器覆盖 glb 自带材质。
## 好处：不依赖 UV 与贴图，改配色/纹理强度只改这张表。

const SURFACE_SHADER := preload("res://shaders/surface.gdshader")

const COLORS := {
	"Plaster": Color(0.87, 0.81, 0.67),
	"Wood": Color(0.30, 0.20, 0.13),
	"WoodLight": Color(0.53, 0.38, 0.24),
	"RoofShingle": Color(0.60, 0.33, 0.24),
	"RoofDark": Color(0.50, 0.28, 0.20),
	"Stone": Color(0.60, 0.59, 0.55),
	"Glass": Color(0.22, 0.29, 0.34),
	"BarnWall": Color(0.60, 0.45, 0.28),
	"Hay": Color(0.62, 0.52, 0.26),
	"Skin": Color(0.84, 0.66, 0.51),
	"Tunic": Color(0.40, 0.47, 0.30),
	"Pants": Color(0.33, 0.31, 0.27),
	"Boots": Color(0.22, 0.17, 0.13),
	"Thatch": Color(0.72, 0.62, 0.35),
	"Basket": Color(0.62, 0.50, 0.30),
	"Berry": Color(0.45, 0.12, 0.14),
	"Pelt": Color(0.58, 0.44, 0.31),
	"Crop": Color(0.55, 0.62, 0.25),
	"Wheat": Color(0.66, 0.56, 0.28),
	"StoneDark": Color(0.44, 0.43, 0.40),
	"Rope": Color(0.70, 0.64, 0.50),
	"Dirt": Color(0.40, 0.32, 0.23),
	"Water": Color(0.20, 0.36, 0.44),
	"Sign": Color(0.68, 0.17, 0.15),
}

# 材质名 -> [pattern, detail_scale, detail_strength]
const PATTERNS := {
	"Plaster": [0, 1.4, 0.06],
	"Wood": [1, 1.0, 0.14],
	"WoodLight": [1, 1.0, 0.14],
	"BarnWall": [1, 0.85, 0.16],
	"RoofShingle": [2, 6.0, 0.18],
	"RoofDark": [2, 6.0, 0.18],
	"Stone": [3, 0.55, 0.12],
	"StoneDark": [3, 0.55, 0.12],
	"Thatch": [1, 1.8, 0.16],
	"Hay": [1, 1.8, 0.16],
	"Crop": [0, 2.4, 0.14],
	"Wheat": [0, 2.4, 0.14],
	"Dirt": [0, 2.0, 0.10],
	"Glass": [4, 1.0, 0.0],
}

static var _cache: Dictionary = {}
static var _winter_cache: Dictionary = {}
## 夜晚时窗户透出暖光
static var night := false

static func apply(root: Node, rough: float = 0.9, variant: int = 0) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.get_active_material(i)
			var key := ""
			if src != null:
				key = str(src.resource_name)
			var m := mat_for(key, rough, variant)
			if m != null:
				mi.set_surface_override_material(i, m)

## variant 用来给同一材质做细微色差，避免整条街一个颜色
static func mat_for(key: String, rough: float, variant: int = 0) -> Material:
	var cache_key := "%s|%.2f|%d|%s" % [key, rough, variant, "n" if night else "d"]
	if _cache.has(cache_key):
		return _cache[cache_key]
	if not COLORS.has(key):
		return null
	var pat: Array = PATTERNS.get(key, [0, 1.0, 0.08])
	var base: Color = COLORS[key]
	var mult: float = [1.0, 1.07, 0.92, 1.03][variant % 4]
	var warm: float = [0.0, 0.025, -0.02, 0.012][variant % 4]
	var c := Color(base.r * (mult + warm), base.g * mult, base.b * (mult - warm))
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("base_color", c.srgb_to_linear())
	m.set_shader_parameter("pattern", int(pat[0]))
	m.set_shader_parameter("detail_scale", float(pat[1]))
	m.set_shader_parameter("detail_strength", float(pat[2]))
	m.set_shader_parameter("surface_roughness", rough)
	if night and (key == "Glass" or key == "Sign"):
		m.set_shader_parameter("emission_color", Color(1.0, 0.72, 0.36).srgb_to_linear())
		m.set_shader_parameter("emission_strength", 2.6 if key == "Glass" else 0.8)
	m.resource_name = "paint_" + key
	_cache[cache_key] = m
	return m

## 村民衣服的配色，按人随机取，避免所有人一模一样
const TUNIC_PALETTE := [
	Color(0.40, 0.47, 0.30),
	Color(0.34, 0.42, 0.57),
	Color(0.56, 0.38, 0.26),
	Color(0.55, 0.30, 0.28),
	Color(0.62, 0.52, 0.30),
	Color(0.45, 0.38, 0.50),
]

static func tunic_mat(idx: int) -> Material:
	var key := "tunic_%d" % idx
	if _cache.has(key):
		return _cache[key]
	var col: Color = TUNIC_PALETTE[idx % TUNIC_PALETTE.size()]
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("base_color", col.srgb_to_linear())
	m.set_shader_parameter("pattern", 0)
	m.set_shader_parameter("detail_scale", 3.0)
	m.set_shader_parameter("detail_strength", 0.06)
	m.set_shader_parameter("surface_roughness", 0.88)
	m.resource_name = "paint_Tunic"
	_cache[key] = m
	return m

## 冬季屋顶积雪：在基色上混入雪白
static func snow_roof_mat(key: String) -> Material:
	var ck := "snowroof|" + key
	if _cache.has(ck):
		return _cache[ck]
	var base: Color = COLORS.get(key, Color(0.5, 0.5, 0.5))
	var snowy := base.lerp(Color(0.90, 0.92, 0.96), 0.72)
	var is_roof := key.begins_with("Roof")
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("base_color", snowy.srgb_to_linear())
	m.set_shader_parameter("pattern", 2 if is_roof else 1)
	m.set_shader_parameter("detail_scale", 4.2 if is_roof else 1.8)
	m.set_shader_parameter("detail_strength", 0.08)
	m.set_shader_parameter("surface_roughness", 0.95)
	m.resource_name = "paint_" + key
	_cache[ck] = m
	return m

## 冬季雪色（农田作物用）
static func winter_mat(key: String) -> Material:
	var ck := "winter|" + key
	if _winter_cache.has(ck):
		return _winter_cache[ck]
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("base_color", Color(0.84, 0.87, 0.92).srgb_to_linear())
	m.set_shader_parameter("pattern", 0)
	m.set_shader_parameter("detail_scale", 3.0)
	m.set_shader_parameter("detail_strength", 0.12)
	m.set_shader_parameter("surface_roughness", 0.95)
	m.resource_name = "paint_winter_" + key
	_winter_cache[ck] = m
	return m

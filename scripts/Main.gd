extends Node3D
## 垂直切片主场景：地图、光照、相机、建造、居民、UI 全部在运行时构建。

const CELL := GridSystem.CELL
const MAP := 64
const WATER_LEVEL := 1.15
const BUILD_ORDER: Array[String] = [
	"woodcutter", "gatherer", "hunter", "farm",
	"firewood", "house", "storage", "quarry", "road",
]

var grid: GridSystem
var terrain_mat: ShaderMaterial
var water_mat: ShaderMaterial
var camera_rig: Node3D
var camera_pivot: Node3D
var camera: Camera3D
var buildings_root: Node3D
var citizens_root: Node3D
var props_root: Node3D
var steps_root: Node3D
var refl_vp: SubViewport = null
var refl_cam: Camera3D = null
var ghost_root: Node3D
var _mmb_dragging := false
var _mmb_last := Vector2.ZERO
var ghost_mesh: MeshInstance3D
var ui: GameUI

var build_mode := ""
var selected: Building = null

var pine_trunk: MultiMeshInstance3D
var pine_leaf: MultiMeshInstance3D
var broad_trunk: MultiMeshInstance3D
var broad_canopy: MultiMeshInstance3D
var rock_mm: MultiMeshInstance3D
var birch_trunk: MultiMeshInstance3D
var birch_canopy: MultiMeshInstance3D
var birch_top: MultiMeshInstance3D
var pine_top: MultiMeshInstance3D
var broad_top: MultiMeshInstance3D
var bush_mm: MultiMeshInstance3D
var grass_mm: MultiMeshInstance3D
var flower_mm: MultiMeshInstance3D
var road_mask_img: Image
var road_mask_tex: ImageTexture
var dirt_mask_img: Image
var dirt_mask_tex: ImageTexture
var plaza_img: Image
var plaza_tex: ImageTexture
var fountain_node: Node3D = null
var bridge_node: Node3D = null
var pier_node: Node3D = null
var _sheep_done := false
var _far_forest_done := false
var _pasture_done := false
var _footbridge_done := false
var _courtyard_done := false
var _market_done := false
var _range_done := false
var _sapling_done := false
var _tall_done := false
var _quarry_done := false
var _fence_meshes_ready := false
var _fence_post: BoxMesh
var _fence_rail: BoxMesh
var _fence_mat: Material
var ship_node: Node3D = null
var pine_lookup: Dictionary = {}
var broad_lookup: Dictionary = {}
var birch_lookup: Dictionary = {}
var rock_lookup: Dictionary = {}
var _grid_alpha := 0.22

var rng := RandomNumberGenerator.new()
var _winter_mix := 0.0
var _assign_timer := 0.0

func _ready() -> void:
	rng.seed = 20261101
	grid = GridSystem.new(MAP)
	grid.set_border(2)
	GameState.grid = grid

	_build_environment()
	_build_camera()
	_build_water()
	_build_rain()
	_build_snow()
	_init_road_mask()
	_build_ground()
	_build_water_depth()
	_build_decor()

	buildings_root = Node3D.new()
	add_child(buildings_root)
	citizens_root = Node3D.new()
	add_child(citizens_root)
	props_root = Node3D.new()
	add_child(props_root)
	steps_root = Node3D.new()
	add_child(steps_root)

	_build_ghost()

	ui = GameUI.new()
	ui.main = self
	add_child(ui)
	_build_vignette()

	GameState.log_message.connect(_on_log)
	GameState.season_changed.connect(_on_season)
	GameState.day_passed.connect(_on_day)

	_build_town()
	GameState.started = true
	GameState.log_msg("流放者抵达这片土地。先建伐木场和采集小屋，再考虑过冬。")
	_handle_cmdline()

# ---------------------------------------------------------------- 场景

func _build_vignette() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/grade.gdshader")
	rect.material = mat
	layer.add_child(rect)

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.40, 0.70)
	sm.sky_horizon_color = Color(0.87, 0.80, 0.68)
	sm.ground_bottom_color = Color(0.10, 0.12, 0.10)
	sm.ground_horizon_color = Color(0.55, 0.56, 0.48)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.63, 0.73)
	env.ambient_light_energy = 0.52
	env.ambient_light_sky_contribution = 0.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.18
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.78, 0.84)
	env.fog_density = 0.0011
	env.fog_aerial_perspective = 0.25
	env.ssao_enabled = true
	env.ssao_radius = 2.4
	env.ssao_intensity = 2.8
	env.glow_enabled = true
	env.glow_intensity = 0.42
	env.glow_bloom = 0.12
	env.glow_hdr_threshold = 0.85
	env.adjustment_enabled = false
	env.adjustment_contrast = 1.0
	env.adjustment_saturation = 1.0
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -40, 0)
	sun.light_energy = 2.15
	sun.light_color = Color(1.0, 0.93, 0.80)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 2.2
	sun.shadow_blur = 0.12
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_split_1 = 0.12
	sun.directional_shadow_split_2 = 0.30
	sun.directional_shadow_split_3 = 0.62
	sun.light_angular_distance = 0.4
	add_child(sun)

## 平面反射：用一台镜像相机把场景再渲染一次，给水面当反射贴图
func _build_reflection() -> void:
	refl_vp = SubViewport.new()
	refl_vp.size = Vector2i(1280, 720)
	refl_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	refl_vp.msaa_3d = Viewport.MSAA_DISABLED
	refl_vp.world_3d = get_world_3d()
	add_child(refl_vp)

	refl_cam = Camera3D.new()
	refl_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	refl_cam.cull_mask = 0xFFFFF & ~2
	refl_cam.near = 1.0
	refl_cam.far = 700.0
	refl_vp.add_child(refl_cam)

	if water_mat != null:
		water_mat.set_shader_parameter("reflection_tex", refl_vp.get_texture())

func _update_reflection() -> void:
	if refl_cam == null or camera == null:
		return
	var mirror := Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1)),
		Vector3(0.0, 2.0 * WATER_LEVEL, 0.0)
	)
	refl_cam.global_transform = mirror * camera.global_transform
	refl_cam.size = camera.size
	refl_cam.near = camera.near
	refl_cam.far = camera.far

func _build_camera() -> void:
	camera_rig = Node3D.new()
	camera_rig.position = Vector3(MAP * CELL * 0.5, 0.0, MAP * CELL * 0.5)
	add_child(camera_rig)

	var pivot := Node3D.new()
	pivot.rotation_degrees = Vector3(-37, 0, 0)
	camera_rig.add_child(pivot)
	camera_pivot = pivot

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 46.0
	camera.position = Vector3(0, 0, 150)
	camera.near = 1.0
	camera.far = 700.0
	# Godot 4.4+ 的景深挂在 CameraAttributes 上
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 165.0
	attrs.dof_blur_far_transition = 85.0
	attrs.dof_blur_amount = 0.10
	camera.attributes = attrs
	pivot.add_child(camera)

## 远海上的岛屿/山影：等距视角看不到天空，所以用两层远山填满背景
func _build_distant_islands() -> void:
	var bands := [
		[26, 150.0, 195.0, 26.0, 52.0, Color(0.38, 0.46, 0.52)],
		[30, 215.0, 300.0, 34.0, 78.0, Color(0.52, 0.58, 0.64)],
	]
	for band in bands:
		var count: int = band[0]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 1.0
		cone.height = 1.0
		cone.radial_segments = 6
		cone.rings = 1
		mm.mesh = cone
		mm.instance_count = count
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = (band[5] as Color).srgb_to_linear()
		mat.roughness = 1.0
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)

		for i in count:
			var a := TAU * float(i) / float(count) + rng.randf_range(-0.10, 0.10)
			var r := rng.randf_range(float(band[1]), float(band[2]))
			var p := Vector3(64.0 + cos(a) * r, -5.0, 64.0 + sin(a) * r)
			var w := rng.randf_range(38.0, 92.0)
			var h := rng.randf_range(float(band[3]), float(band[4]))
			var basis := Basis().scaled(Vector3(w, h, w * rng.randf_range(0.75, 1.25)))
			mm.set_instance_transform(i, Transform3D(basis, p + Vector3(0, h * 0.5, 0)))

func _build_water() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/water.gdshader")
	mat.set_shader_parameter("island_center", Vector2(MAP * CELL * 0.5, MAP * CELL * 0.5))
	mat.set_shader_parameter("island_half", MAP * CELL * 0.5)
	mat.set_shader_parameter("world_size", float(MAP) * CELL)
	water_mat = mat
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1700, 1700)
	pm.subdivide_width = 220
	pm.subdivide_depth = 220
	mi.mesh = pm
	mi.position = Vector3(MAP * CELL * 0.5, -0.55, MAP * CELL * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = mat
	mi.layers = 2          # 第 2 层：反射相机不渲染水面自身
	add_child(mi)

func _init_road_mask() -> void:
	road_mask_img = Image.create(MAP, MAP, false, Image.FORMAT_R8)
	road_mask_img.fill(Color(0, 0, 0))
	road_mask_tex = ImageTexture.create_from_image(road_mask_img)
	dirt_mask_img = Image.create(MAP, MAP, false, Image.FORMAT_R8)
	dirt_mask_img.fill(Color(0, 0, 0))
	dirt_mask_tex = ImageTexture.create_from_image(dirt_mask_img)
	plaza_img = Image.create(MAP, MAP, false, Image.FORMAT_R8)
	plaza_img.fill(Color(0, 0, 0))
	plaza_tex = ImageTexture.create_from_image(plaza_img)

## 建筑周围被踩踏的裸土，按建筑占地向外做衰减
func _rebuild_dirt_mask() -> void:
	if dirt_mask_img == null:
		return
	dirt_mask_img.fill(Color(0, 0, 0))
	for b in GameState.buildings:
		if not is_instance_valid(b) or b.is_road():
			continue
		var bw: int = int(b.size.x)
		var bh: int = int(b.size.y)
		var r: int = 2 + maxi(bw, bh)
		var cx: int = int(b.cell.x) + bw / 2
		var cy: int = int(b.cell.y) + bh / 2
		for y in range(cy - r, cy + r + 1):
			for x in range(cx - r, cx + r + 1):
				if x < 0 or y < 0 or x >= MAP or y >= MAP:
					continue
				var d := Vector2(float(x - cx), float(y - cy)).length()
				var v := clampf(1.0 - d / float(r), 0.0, 1.0)
				v *= 0.85
				if v > dirt_mask_img.get_pixel(x, y).r:
					dirt_mask_img.set_pixel(x, y, Color(v, v, v))
	dirt_mask_tex.update(dirt_mask_img)

func _set_road_mask(cell: Vector2i, on: bool) -> void:
	if road_mask_img == null:
		return
	if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
		return
	road_mask_img.set_pixel(cell.x, cell.y, Color(1, 1, 1) if on else Color(0, 0, 0))
	road_mask_tex.update(road_mask_img)
	_rebuild_road_steps()

## 坡道上的石阶：相邻两段路面高差超过阈值时铺一块石板
func _rebuild_road_steps() -> void:
	if steps_root == null or not grid.has_heights():
		return
	for ch in steps_root.get_children():
		ch.queue_free()
	var dirs := [Vector2i(1, 0), Vector2i(0, 1)]
	for cell in grid.road_cells:
		if not bool(grid.road_cells[cell]):
			continue
		var h0 := grid.height_at_cell(cell)
		for d in dirs:
			var n: Vector2i = cell + d
			if not bool(grid.road_cells.get(n, false)):
				continue
			var h1 := grid.height_at_cell(n)
			var dh := h1 - h0
			if absf(dh) < 0.28:
				continue
			var lo := minf(h0, h1)
			var c0 := grid.cell_center(cell)
			var c1 := grid.cell_center(n)
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(CELL * 0.96, 0.16, 0.62)
			mi.mesh = bm
			mi.position = Vector3((c0.x + c1.x) * 0.5, lo + 0.10, (c0.z + c1.z) * 0.5)
			if d.y != 0:
				mi.rotation.y = PI * 0.5
			mi.material_override = ModelPaint.mat_for("StoneDark", 0.9, 0)
			steps_root.add_child(mi)

func _rebuild_road_mask() -> void:
	if road_mask_img == null:
		return
	road_mask_img.fill(Color(0, 0, 0))
	for c in grid.road_cells:
		if bool(grid.road_cells[c]):
			road_mask_img.set_pixel(c.x, c.y, Color(1, 1, 1))
	road_mask_tex.update(road_mask_img)

func _hash2(x: int, y: int) -> float:
	var n := x * 374761393 + y * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	return float((n ^ (n >> 16)) & 0x7fffffff) / 2147483647.0

func _noise(x: float, z: float) -> float:
	var ix := int(floor(x))
	var iz := int(floor(z))
	var fx := x - float(ix)
	var fz := z - float(iz)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fz = fz * fz * (3.0 - 2.0 * fz)
	var a := _hash2(ix, iz)
	var b := _hash2(ix + 1, iz)
	var c := _hash2(ix, iz + 1)
	var d := _hash2(ix + 1, iz + 1)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz) * 2.0 - 1.0

func _height_f(x: float, z: float) -> float:
	var base := 2.55
	var n := _noise(x * 0.011, z * 0.011) * 0.85
	n += _noise(x * 0.033 + 11.0, z * 0.033 + 7.0) * 0.35
	var d := Vector2(x - 64.0, z - 64.0).length()
	var flat := clampf((d - 21.0) / 16.0, 0.0, 1.0)
	var h := base + n * flat

	# 河道：从北岸蜿蜒到南岸，走在村庄西侧
	var river_x := 64.0 - (40.0 + 11.0 * sin(z * 0.048 + 0.7) + 3.0 * sin(z * 0.115 + 2.1))
	var dx := x - river_x
	# 窄谷 + 河槽：谷肩收窄，水面才会像一条河而不是一片湖
	h -= 0.85 * exp(-(dx * dx) / (2.0 * 7.0 * 7.0))
	h -= 3.6 * exp(-(dx * dx) / (2.0 * 3.6 * 3.6))

	# 远处扩展成起伏的平原与小丘（地图外同样适用）
	var far := smoothstep(34.0, 96.0, d)
	var hills := (_noise(x * 0.0135 + 31.0, z * 0.0135 + 17.0) * 0.5 + 0.5) * 9.5
	hills += (_noise(x * 0.031 + 5.0, z * 0.031 + 3.0) * 0.5 + 0.5) * 2.6

	# 北端雪山：整片山脉退到地图之外，村庄看到的是远处连绵雪峰
	var north := clampf((6.0 - z) / 78.0, 0.0, 1.0)
	var ridge := absf(_noise(x * 0.017 + 7.0, z * 0.017 + 41.0))
	ridge += absf(_noise(x * 0.041 + 19.0, z * 0.041 + 5.0)) * 0.55
	var mountain := (11.0 + 19.0 * ridge) * pow(north, 1.4)

	# 南端入海：地势逐渐沉到水面以下
	var south := smoothstep(96.0, 138.0, z)
	var sea_drop := 9.5 * south

	# 河道要在丘陵/雪山/入海口都切穿，否则远段会被填平、河就断了
	var valley := 1.0 - exp(-(dx * dx) / (2.0 * 17.0 * 17.0))
	h += far * hills * valley
	h += mountain * valley
	h -= sea_drop * valley
	return h

## 世界坐标版地形高度（含地图外裙边），用于水深贴图
func _terrain_h_world(wx: float, wz: float) -> float:
	var inx := wx >= 0.0 and wx < float(MAP) * CELL and wz >= 0.0 and wz < float(MAP) * CELL
	if inx:
		return grid.height_at_world(wx, wz)
	var cx := int(floor(wx / CELL))
	var cz := int(floor(wz / CELL))
	var ex := 0
	var ez := 0
	if cx < 0:
		ex = -cx
	elif cx >= MAP:
		ex = cx - MAP + 1
	if cz < 0:
		ez = -cz
	elif cz >= MAP:
		ez = cz - MAP + 1
	return _height_f(wx, wz)

func _build_water_depth() -> void:
	if water_mat == null or not grid.has_heights():
		return
	# 水深贴图覆盖地图 + 外侧裙边，这样浅滩到深海是连续过渡
	var origin := -24.0
	var extent := float(MAP) * CELL + 48.0
	var res := int(extent)
	var img := Image.create(res, res, false, Image.FORMAT_R8)
	for j in res:
		for i in res:
			var wx := origin + (float(i) + 0.5)
			var wz := origin + (float(j) + 0.5)
			var h := _terrain_h_world(wx, wz)
			var d := clampf((WATER_LEVEL - h) / 9.0, 0.0, 1.0)
			img.set_pixel(i, j, Color(d, d, d))
	var tex := ImageTexture.create_from_image(img)
	water_mat.set_shader_parameter("depth_mask", tex)
	water_mat.set_shader_parameter("mask_origin", Vector2(origin, origin))
	water_mat.set_shader_parameter("mask_extent", extent)

## 地形高度（含地图外的下沉裙边）：地图边界不再是可见的方形切边
func _terrain_h(cx: int, cz: int) -> float:
	var x0 := float(cx) * CELL
	var z0 := float(cz) * CELL
	if cx >= 0 and cz >= 0 and cx < MAP and cz < MAP:
		return grid.height_at_world(x0, z0)
	var ex := 0
	var ez := 0
	if cx < 0:
		ex = -cx
	elif cx >= MAP:
		ex = cx - MAP + 1
	if cz < 0:
		ez = -cz
	elif cz >= MAP:
		ez = cz - MAP + 1
	return _height_f(x0, z0)

func _build_ground() -> void:
	grid.build_heights(_height_f)
	grid.mark_water(WATER_LEVEL)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apron := 120
	for z in range(-apron, MAP + apron):
		for x in range(-apron, MAP + apron):
			var x0 := float(x) * CELL
			var z0 := float(z) * CELL
			var x1 := x0 + CELL
			var z1 := z0 + CELL
			var p00 := Vector3(x0, _terrain_h(x, z), z0)
			var p10 := Vector3(x1, _terrain_h(x + 1, z), z0)
			var p01 := Vector3(x0, _terrain_h(x, z + 1), z1)
			var p11 := Vector3(x1, _terrain_h(x + 1, z + 1), z1)
			st.add_vertex(p00)
			st.add_vertex(p10)
			st.add_vertex(p11)
			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p01)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/ground.gdshader")
	terrain_mat.set_shader_parameter("world_size", float(MAP) * CELL)
	terrain_mat.set_shader_parameter("cell_size", CELL)
	terrain_mat.set_shader_parameter("road_mask", road_mask_tex)
	terrain_mat.set_shader_parameter("dirt_mask", dirt_mask_tex)
	terrain_mat.set_shader_parameter("plaza_mask", plaza_tex)
	mi.material_override = terrain_mat
	# 地形不参与投影：它在平缓起伏上会自阴影出条纹
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _build_town() -> void:
	place_building("storage", Vector2i(31, 31), true, true)
	place_building("house", Vector2i(28, 30), true, true)
	place_building("house", Vector2i(28, 34), true, true)
	place_building("house", Vector2i(34, 34), true, true)
	for i in 8:
		var a := TAU * float(i) / 8.0
		spawn_citizen(Vector3(64.0 + cos(a) * 4.0, 0.0, 64.0 + sin(a) * 4.0))
	_scatter_props()
	_scatter_far_forest()
	_spawn_fountain()

# ---------------------------------------------------------------- 道具

const PROP_MODELS := {
	"cart": "res://assets/models/prop_cart.glb",
	"haystack": "res://assets/models/prop_haystack.glb",
	"barrel": "res://assets/models/prop_barrel.glb",
	"crate": "res://assets/models/prop_crate.glb",
	"bench": "res://assets/models/prop_bench.glb",
	"lamp": "res://assets/models/prop_lamp.glb",
	"fence": "res://assets/models/prop_fence.glb",
}

var _props_done := false

func _scatter_props() -> void:
	if _props_done:
		return
	_props_done = true
	# 不再随机撒道具：只保留按建筑类型规则摆放的"场景道具"（菜园/晾衣绳/干草车等）
	_scatter_boats()
	_spawn_critters()

func _scatter_props_unused() -> void:
	var scenes := {}
	for k in PROP_MODELS:
		var p: String = PROP_MODELS[k]
		if ResourceLoader.exists(p):
			scenes[k] = load(p)
	if scenes.is_empty():
		return

	var weights := [
		["barrel", 30], ["crate", 26], ["haystack", 18],
		["bench", 14], ["lamp", 12], ["cart", 9], ["fence", 16],
	]
	var total := 0
	for w in weights:
		total += int(w[1])

	var used := {}
	var placed := 0
	var attempts := 0
	while placed < 80 and attempts < 1400:
		attempts += 1
		var cell := Vector2i(rng.randi_range(3, MAP - 4), rng.randi_range(3, MAP - 4))
		if used.has(cell):
			continue
		if not grid.footprint_free(cell, Vector2i.ONE):
			continue
		if grid.is_road(cell):
			continue
		var pos := grid.cell_center(cell)
		if not _near_building(pos, 18.0):
			continue

		var roll := rng.randi_range(1, total)
		var kind := "barrel"
		for w in weights:
			roll -= int(w[1])
			if roll <= 0:
				kind = str(w[0])
				break

		var ps: PackedScene = scenes.get(kind)
		if ps == null:
			continue
		var node: Node3D = ps.instantiate()
		props_root.add_child(node)
		node.position = pos + Vector3(rng.randf_range(-0.5, 0.5), 0.0, rng.randf_range(-0.5, 0.5))
		node.rotation.y = rng.randf() * TAU
		ModelPaint.apply(node)
		used[cell] = true
		placed += 1

	_scatter_boats()
	_spawn_critters()

var _critters_done := false

# ---------------------------------------------------------------- 场景道具
# 按建筑类型放置的道具，只出现在"合理的地方"

const CTX_MODELS := {
	"clothesline": "res://assets/models/prop_clothesline.glb",
	"woodpile": "res://assets/models/prop_woodpile.glb",
	"haycart": "res://assets/models/prop_haycart.glb",
	"trough": "res://assets/models/prop_trough.glb",
	"signpost": "res://assets/models/prop_signpost.glb",
	"veggarden": "res://assets/models/prop_veggarden.glb",
	"scarecrow": "res://assets/models/prop_scarecrow.glb",
}

const CTX_WANT := {
	"house": ["veggarden", "clothesline", "woodpile"],
	"house_row": ["veggarden", "clothesline"],
	"house_stone": ["veggarden", "clothesline", "woodpile"],
	"house_manor": ["veggarden", "clothesline"],
	"woodcutter": ["woodpile"],
	"firewood": ["woodpile"],
	"blacksmith": ["woodpile", "stoneblocks"],
	"carpenter": ["woodpile", "stoneblocks"],
	"farm": ["scarecrow", "haycart"],
	"well": ["trough"],
	"storage": ["haycart", "signpost"],
	"trade": ["signpost"],
}

var _ctx_cache: Dictionary = {}

func _ctx_scene(kind: String) -> PackedScene:
	if _ctx_cache.has(kind):
		return _ctx_cache[kind]
	if not CTX_MODELS.has(kind):
		return null
	var path: String = CTX_MODELS[kind]
	if not ResourceLoader.exists(path):
		return null
	var ps: PackedScene = load(path)
	_ctx_cache[kind] = ps
	return ps

## 给一栋建筑在周围找个空位放对应道具
func spawn_context_prop(b: Building) -> void:
	if b == null or not is_instance_valid(b) or b.is_road():
		return
	var kinds: Array = CTX_WANT.get(b.def_id, [])
	if kinds.is_empty():
		return
	var takes := 3 if b.def_id in ["woodcutter", "firewood", "blacksmith", "carpenter", "quarry"] else (2 if b.def_id in ["house", "house_stone", "house_row", "house_manor", "farm"] else 1)
	for n in takes:
		var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
		var ps := _ctx_scene(kind)
		if ps == null:
			continue
		for attempt in 14:
			var a := rng.randf() * TAU
			var rr := (maxi(b.size.x, b.size.y) * 0.5 + rng.randf_range(1.4, 2.6)) * CELL
			var p := b.global_position + Vector3(cos(a) * rr, 0.0, sin(a) * rr)
			var cell := grid.world_to_cell(p)
			if not grid.footprint_free(cell, Vector2i.ONE):
				continue
			if grid.is_road(cell):
				continue
			var node: Node3D = ps.instantiate()
			props_root.add_child(node)
			var cp := grid.cell_center(cell)
			node.position = Vector3(cp.x, cp.y, cp.z)
			node.rotation.y = rng.randf() * TAU
			if kind == "clothesline":
				node.rotation.y = rng.randf_range(0.0, 0.6) + (0.0 if rng.randf() < 0.5 else PI * 0.5)
			ModelPaint.apply(node)
			break

func _spawn_all_context_props() -> void:
	for b in GameState.buildings:
		spawn_context_prop(b)

## 村里的鸡和狗
func _spawn_critters() -> void:
	if _critters_done:
		return
	_critters_done = true
	var chickens: PackedScene = null
	var dogs: PackedScene = null
	if ResourceLoader.exists("res://assets/models/prop_chicken.glb"):
		chickens = load("res://assets/models/prop_chicken.glb")
	if ResourceLoader.exists("res://assets/models/prop_dog.glb"):
		dogs = load("res://assets/models/prop_dog.glb")
	var homes: Array[Vector3] = []
	for b in GameState.buildings:
		if is_instance_valid(b) and not b.is_road():
			homes.append(b.global_position)
	if homes.is_empty():
		homes.append(Vector3(64.0, 0.0, 64.0))
	for i in 7:
		if chickens == null:
			break
		var h: Vector3 = homes[rng.randi_range(0, homes.size() - 1)]
		var a := rng.randf() * TAU
		var p := h + Vector3(cos(a) * rng.randf_range(2.0, 5.0), 0.0, sin(a) * rng.randf_range(2.0, 5.0))
		p.y = grid.height_at_world(p.x, p.z)
		var c := Critter.new()
		add_child(c)
		c.setup(chickens, p, rng.randf_range(0.55, 0.95))
	for i in 3:
		if dogs == null:
			break
		var h: Vector3 = homes[rng.randi_range(0, homes.size() - 1)]
		var a := rng.randf() * TAU
		var p := h + Vector3(cos(a) * rng.randf_range(3.0, 6.0), 0.0, sin(a) * rng.randf_range(3.0, 6.0))
		p.y = grid.height_at_world(p.x, p.z)
		var c := Critter.new()
		add_child(c)
		c.setup(dogs, p, rng.randf_range(1.4, 2.1))

## 水面上的小船
## 地图外的丘陵上铺一片远景森林
func _scatter_far_forest() -> void:
	if _far_forest_done:
		return
	_far_forest_done = true
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.45
	cone.height = 4.6
	cone.radial_segments = 6
	cone.rings = 1
	var n := 1500
	var mm := _make_multimesh(cone, n, Color(0.13, 0.26, 0.14))
	mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mm)
	var mmx := mm.multimesh
	for i in n:
		var a := rng.randf() * TAU
		# 内侧半径带抖动，避免形成整齐的"树线"
		var r_in := 44.0 + rng.randf_range(0.0, 16.0)
		var r := rng.randf_range(r_in, 216.0)
		var x := 64.0 + cos(a) * r
		var z := 64.0 + sin(a) * r
		var h := _height_f(x, z)
		if h < WATER_LEVEL + 0.25 or h > 24.0:
			continue
		var s := rng.randf_range(0.72, 1.75)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.95, 1.45), s))
		mmx.set_instance_transform(i, Transform3D(basis, Vector3(x, h + 2.3 * s, z)))

	# 林缘灌木带：在草地与森林之间做过渡
	var bm2 := SphereMesh.new()
	bm2.radius = 0.85
	bm2.height = 1.15
	bm2.radial_segments = 6
	bm2.rings = 3
	var nsh := 950
	var mms := _make_multimesh(bm2, nsh, Color(0.15, 0.25, 0.12))
	mms.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mms)
	var msx := mms.multimesh
	for i in nsh:
		var ang_s := rng.randf() * TAU
		var rs := rng.randf_range(34.0, 78.0)
		var xs := 64.0 + cos(ang_s) * rs
		var zs := 64.0 + sin(ang_s) * rs
		var hs := _height_f(xs, zs)
		if hs < WATER_LEVEL + 0.6:
			continue
		var ss := rng.randf_range(0.55, 1.35)
		var bs := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(ss, ss * rng.randf_range(0.8, 1.1), ss))
		msx.set_instance_transform(i, Transform3D(bs, Vector3(xs, hs + 0.32 * ss, zs)))
	# 远处阔叶林：球形树冠，掺在松林里
	var ball := SphereMesh.new()
	ball.radius = 1.55
	ball.height = 2.6
	ball.radial_segments = 7
	ball.rings = 4
	var nb := 620
	var mmb := _make_multimesh(ball, nb, Color.WHITE, true)
	mmb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmb)
	var mbx := mmb.multimesh
	for i in nb:
		var a2 := rng.randf() * TAU
		var r2 := rng.randf_range(48.0 + rng.randf_range(0.0, 12.0), 210.0)
		var x2 := 64.0 + cos(a2) * r2
		var z2 := 64.0 + sin(a2) * r2
		var h2 := _height_f(x2, z2)
		if h2 < WATER_LEVEL + 0.30 or h2 > 24.0:
			continue
		var s2 := rng.randf_range(0.8, 1.6)
		var b2 := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s2, s2 * rng.randf_range(0.9, 1.2), s2))
		mbx.set_instance_transform(i, Transform3D(b2, Vector3(x2, h2 + 1.6 * s2, z2)))
		mbx.set_instance_color(i, Color(0.27, 0.40, 0.17).lerp(Color(0.21, 0.34, 0.15), rng.randf()).srgb_to_linear())
	# 阔叶需要实例色
	if mmb.material_override is StandardMaterial3D:
		var bm := mmb.material_override as StandardMaterial3D
		bm.vertex_color_use_as_albedo = true
		bm.albedo_color = Color.WHITE

## 牧场围栏：把南边羊群圈起来
func _build_pasture_fence() -> void:
	if _pasture_done:
		return
	_pasture_done = true
	var x0 := 50.0
	var x1 := 67.0
	var z0 := 82.0
	var z1 := 95.0
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.20, 1.15, 0.20)
	var rail_mesh := BoxMesh.new()
	rail_mesh.size = Vector3(0.16, 0.14, 1.0)
	var mat := ModelPaint.mat_for("Wood", 0.9, 0)
	var runs := [
		[Vector3(x0, 0, z0), Vector3(x1, 0, z0)],
		[Vector3(x0, 0, z1), Vector3(x1, 0, z1)],
		[Vector3(x0, 0, z0), Vector3(x0, 0, z1)],
		[Vector3(x1, 0, z0), Vector3(x1, 0, z1)],
	]
	var step := 1.6
	for run in runs:
		var a: Vector3 = run[0]
		var b: Vector3 = run[1]
		var seg := a.distance_to(b)
		var n := int(seg / step)
		var prev := Vector3.ZERO
		var has_prev := false
		for k in n + 1:
			var p := a.lerp(b, float(k) / float(maxi(n, 1)))
			p.y = grid.height_at_world(p.x, p.z)
			var cell := grid.world_to_cell(p)
			if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
				has_prev = false
				continue
			if grid.is_water(cell) or grid.is_road(cell):
				has_prev = false
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = post_mesh
			mi.material_override = mat
			mi.position = p + Vector3(0.0, 0.52, 0.0)
			add_child(mi)
			if has_prev:
				var mid := (p + prev) * 0.5
				var dir := p - prev
				var len := dir.length()
				if len > 0.3 and len < 2.6:
					for hz in [0.42, 0.82]:
						var ri := MeshInstance3D.new()
						ri.mesh = rail_mesh
						ri.material_override = mat
						ri.position = Vector3(mid.x, mid.y + hz, mid.z)
						ri.rotation.y = atan2(dir.x, dir.z)
						ri.scale = Vector3(1.0, 1.0, len)
						add_child(ri)
			prev = p
			has_prev = true
	# 牧场里的水槽与草料车
	_place_prop_at("prop_trough", Vector3(53.0, 0.0, 86.0), 0.3)
	_place_prop_at("prop_trough", Vector3(64.0, 0.0, 84.5), 1.9)
	_place_prop_at("prop_haycart", Vector3(58.0, 0.0, 92.0), 2.4)
	_place_prop_at("prop_woodpile", Vector3(51.5, 0.0, 92.5), 0.9)

## 木栈桥：南边过河用的小桥
func _build_footbridge() -> void:
	if _footbridge_done:
		return
	_footbridge_done = true
	var deck := BoxMesh.new()
	deck.size = Vector3(14.0, 0.22, 2.4)
	var post := BoxMesh.new()
	post.size = Vector3(0.22, 1.0, 0.22)
	var rail := BoxMesh.new()
	rail.size = Vector3(14.0, 0.10, 0.10)
	var mat := ModelPaint.mat_for("Wood", 0.9, 0)
	var cx := 32.0
	var cz := 95.0
	var deck_y := WATER_LEVEL + 1.55
	var mi := MeshInstance3D.new()
	mi.mesh = deck
	mi.material_override = mat
	mi.position = Vector3(cx, deck_y, cz)
	add_child(mi)
	for sx in [-1.0, 1.0]:
		var ri := MeshInstance3D.new()
		ri.mesh = rail
		ri.material_override = mat
		ri.position = Vector3(cx, deck_y + 0.95, cz + sx * 1.05)
		add_child(ri)
	var x := cx - 6.4
	while x <= cx + 6.4:
		for sx2 in [-1.0, 1.0]:
			var pi := MeshInstance3D.new()
			pi.mesh = post
			pi.material_override = mat
			pi.position = Vector3(x, deck_y + 0.50, cz + sx2 * 1.05)
			add_child(pi)
			if absf(x - cx) > 5.0:
				var leg := MeshInstance3D.new()
				leg.mesh = post
				leg.material_override = mat
				leg.position = Vector3(x, deck_y - 1.2, cz + sx2 * 1.05)
				leg.scale = Vector3(1.0, 3.0, 1.0)
				add_child(leg)
		x += 2.1

## 两点之间铺一条土路（宽度 1 格）
func _paint_road_line(from: Vector2, to: Vector2) -> void:
	var steps := int(from.distance_to(to) / CELL * 2.0)
	if steps < 2:
		return
	for i in steps + 1:
		var t := float(i) / float(steps)
		var w := from.lerp(to, t)
		var cell := grid.world_to_cell(Vector3(w.x, 0.0, w.y))
		if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
			continue
		if grid.is_water(cell):
			continue
		if bool(grid.road_cells.get(cell, false)):
			continue
		grid.road_cells[cell] = true
		_set_road_mask(cell, true)

## 教堂前的小广场：铺地 + 座椅 + 路灯
func _build_church_forecourt() -> void:
	if _courtyard_done:
		return
	_courtyard_done = true
	var cx := 66.0
	var cz := 80.0
	for dz in range(-2, 3):
		for dx in range(-4, 5):
			if absi(dx) + absi(dz) > 5:
				continue
			var cell := grid.world_to_cell(Vector3(cx + float(dx) * CELL, 0.0, cz + float(dz) * CELL))
			if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
				continue
			if grid.is_water(cell):
				continue
			grid.road_cells[cell] = true
			_set_road_mask(cell, true)
	_place_prop_at("prop_bench", Vector3(cx - 4.5, 0.0, cz), PI * 0.5)
	_place_prop_at("prop_bench", Vector3(cx + 4.5, 0.0, cz), -PI * 0.5)
	_place_prop_at("prop_lamp", Vector3(cx - 4.5, 0.0, cz + 5.0), 0.0)
	_place_prop_at("prop_lamp", Vector3(cx + 4.5, 0.0, cz + 5.0), 0.0)

## 贸易站前的集市：铺地 + 三个摊位
func _build_market() -> void:
	if _market_done:
		return
	_market_done = true
	var cx := 72.0
	var cz := 56.0
	for dz in range(-2, 3):
		for dx in range(-3, 4):
			if absi(dx) + absi(dz) > 4:
				continue
			var cell := grid.world_to_cell(Vector3(cx + float(dx) * CELL, 0.0, cz + float(dz) * CELL))
			if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
				continue
			if grid.is_water(cell):
				continue
			grid.road_cells[cell] = true
			_set_road_mask(cell, true)
	_place_prop_at("prop_stall", Vector3(cx - 4.0, 0.0, cz - 2.4), PI)
	_place_prop_at("prop_stall", Vector3(cx + 4.0, 0.0, cz - 2.4), PI)
	_place_prop_at("prop_stall", Vector3(cx, 0.0, cz + 3.0), 0.0)
	# 铁匠铺前的工作场
	_place_prop_at("prop_anvil_yard", Vector3(63.5, 0.0, 51.5), 0.4)
	_paint_road_line(Vector2(63.0, 50.0), Vector2(66.0, 53.0))

## 采石场工作面：石料堆 + 碎石地面
func _build_quarry_yard() -> void:
	if _quarry_done:
		return
	_quarry_done = true
	var cx := 77.0
	var cz := 51.0
	for dz in range(-2, 3):
		for dx in range(-3, 4):
			if absi(dx) + absi(dz) > 4:
				continue
			var cell := grid.world_to_cell(Vector3(cx + float(dx) * CELL, 0.0, cz + float(dz) * CELL))
			if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
				continue
			if grid.is_water(cell):
				continue
			grid.road_cells[cell] = true
			_set_road_mask(cell, true)
	_place_prop_at("prop_stoneblocks", Vector3(73.5, 0.0, 49.0), 0.2)
	_place_prop_at("prop_stoneblocks", Vector3(80.0, 0.0, 50.5), 1.9)
	_place_prop_at("prop_stoneblocks", Vector3(76.5, 0.0, 54.0), 3.4)

## 一段直线篱笆（用于村子边界）
func _fence_line(from: Vector2, to: Vector2) -> void:
	if not _fence_meshes_ready:
		_fence_meshes_ready = true
		_fence_post = BoxMesh.new()
		_fence_post.size = Vector3(0.20, 1.15, 0.20)
		_fence_rail = BoxMesh.new()
		_fence_rail.size = Vector3(0.16, 0.13, 1.0)
		_fence_mat = ModelPaint.mat_for("Wood", 0.9, 0)
	var steps := int(from.distance_to(to) / 1.7)
	if steps < 1:
		return
	var prev := Vector3.ZERO
	var has_prev := false
	for i in steps + 1:
		var t := float(i) / float(steps)
		var w := from.lerp(to, t)
		var p := Vector3(w.x, grid.height_at_world(w.x, w.y), w.y)
		var cell := grid.world_to_cell(p)
		if cell.x < 0 or cell.y < 0 or cell.x >= MAP or cell.y >= MAP:
			has_prev = false
			continue
		if grid.is_water(cell) or grid.is_road(cell):
			has_prev = false
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = _fence_post
		mi.material_override = _fence_mat
		mi.position = p + Vector3(0.0, 0.52, 0.0)
		add_child(mi)
		if has_prev:
			var mid := (p + prev) * 0.5
			var dir := p - prev
			var seg := dir.length()
			if seg > 0.3 and seg < 2.8:
				for hz in [0.42, 0.84]:
					var ri := MeshInstance3D.new()
					ri.mesh = _fence_rail
					ri.material_override = _fence_mat
					ri.position = Vector3(mid.x, mid.y + hz, mid.z)
					ri.rotation.y = atan2(dir.x, dir.z)
					ri.scale = Vector3(1.0, 1.0, seg)
					add_child(ri)
		prev = p
		has_prev = true

## 村口门柱：两根石柱 + 木门楣
func _build_gate(pos: Vector3, rot: float) -> void:
	if not _fence_meshes_ready:
		_fence_meshes_ready = true
		_fence_post = BoxMesh.new()
		_fence_post.size = Vector3(0.20, 1.15, 0.20)
		_fence_rail = BoxMesh.new()
		_fence_rail.size = Vector3(0.16, 0.13, 1.0)
		_fence_mat = ModelPaint.mat_for("Wood", 0.9, 0)
	var pillar := BoxMesh.new()
	pillar.size = Vector3(0.62, 2.30, 0.62)
	var cap := BoxMesh.new()
	cap.size = Vector3(0.84, 0.18, 0.84)
	var lintel := BoxMesh.new()
	lintel.size = Vector3(3.40, 0.26, 0.22)
	var stone_mat := ModelPaint.mat_for("StoneDark", 0.92, 0)
	for sx in [-1.0, 1.0]:
		var off := Vector3(cos(rot) * sx * 1.55, 0.0, -sin(rot) * sx * 1.55)
		var p := pos + off
		p.y = grid.height_at_world(p.x, p.z)
		var pi := MeshInstance3D.new()
		pi.mesh = pillar
		pi.material_override = stone_mat
		pi.position = p + Vector3(0.0, 1.15, 0.0)
		pi.rotation.y = rot
		add_child(pi)
		var ci := MeshInstance3D.new()
		ci.mesh = cap
		ci.material_override = stone_mat
		ci.position = p + Vector3(0.0, 2.40, 0.0)
		ci.rotation.y = rot
		add_child(ci)
	var lpos := pos
	lpos.y = grid.height_at_world(lpos.x, lpos.z)
	var li := MeshInstance3D.new()
	li.mesh = lintel
	li.material_override = _fence_mat
	li.position = lpos + Vector3(0.0, 2.72, 0.0)
	li.rotation.y = rot
	add_child(li)

## 远处的连绵雪山：一排白色山体，立在地图北缘之外
func _build_mountain_range() -> void:
	if _range_done:
		return
	_range_done = true
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.radial_segments = 7
	cone.rings = 1
	var n := 26
	var mm := _make_multimesh(cone, n, Color.WHITE, true)
	mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mm)
	var mmx := mm.multimesh
	for i in n:
		var x := -60.0 + float(i) * 12.0 + rng.randf_range(-4.0, 4.0)
		var z := -16.0 + rng.randf_range(-12.0, 10.0)
		var base_y := _height_f(x, z) - 6.0
		var r := rng.randf_range(16.0, 27.0)
		var hgt := rng.randf_range(34.0, 58.0)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(r, hgt, r))
		mmx.set_instance_transform(i, Transform3D(basis, Vector3(x, base_y + hgt * 0.5, z)))
		var tone := rng.randf_range(0.86, 0.99)
		mmx.set_instance_color(i, Color(tone * 0.94, tone * 0.96, tone).srgb_to_linear())
	if mm.material_override is StandardMaterial3D:
		var m2 := mm.material_override as StandardMaterial3D
		m2.vertex_color_use_as_albedo = true
		m2.albedo_color = Color.WHITE

## 幼树层：在森林里散布小树，增加层次
func _scatter_saplings() -> void:
	if _sapling_done:
		return
	_sapling_done = true
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.9
	cone.height = 2.4
	cone.radial_segments = 6
	cone.rings = 1
	var n := 1800
	var mm := _make_multimesh(cone, n, Color.WHITE, true)
	mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mm)
	var mmx := mm.multimesh
	for i in n:
		var x := rng.randf_range(-40.0, 200.0)
		var z := rng.randf_range(-40.0, 200.0)
		var h := _height_f(x, z)
		if h < WATER_LEVEL + 0.22 or h > 22.0:
			continue
		var cell := grid.world_to_cell(Vector3(x, 0.0, z))
		if cell.x >= 0 and cell.y >= 0 and cell.x < MAP and cell.y < MAP:
			if not grid.footprint_free(cell, Vector2i.ONE):
				continue
			if grid.is_road(cell):
				continue
		var s := rng.randf_range(0.42, 0.78)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
		mmx.set_instance_transform(i, Transform3D(basis, Vector3(x, h + 1.2 * s, z)))
		var tone := rng.randf_range(0.75, 1.1)
		mmx.set_instance_color(i, Color(0.16 * tone, 0.30 * tone, 0.15 * tone).srgb_to_linear())
	if mm.material_override is StandardMaterial3D:
		var m2 := mm.material_override as StandardMaterial3D
		m2.vertex_color_use_as_albedo = true
		m2.albedo_color = Color.WHITE

## 高瘦针叶树：打破轮廓，增加树种多样性
func _scatter_tall_pines() -> void:
	if _tall_done:
		return
	_tall_done = true
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.15
	cone.height = 7.6
	cone.radial_segments = 6
	cone.rings = 1
	var n := 620
	var mm := _make_multimesh(cone, n, Color.WHITE, true)
	mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mm)
	var mmx := mm.multimesh
	for i in n:
		var x := rng.randf_range(-30.0, 190.0)
		var z := rng.randf_range(-30.0, 190.0)
		var h := _height_f(x, z)
		if h < WATER_LEVEL + 0.28 or h > 20.0:
			continue
		var cell := grid.world_to_cell(Vector3(x, 0.0, z))
		if cell.x >= 0 and cell.y >= 0 and cell.x < MAP and cell.y < MAP:
			if not grid.footprint_free(cell, Vector2i.ONE) or grid.is_road(cell):
				continue
		var s := rng.randf_range(0.75, 1.25)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s * 0.72, s, s * 0.72))
		mmx.set_instance_transform(i, Transform3D(basis, Vector3(x, h + 3.7 * s, z)))
		var tone := rng.randf_range(0.8, 1.05)
		mmx.set_instance_color(i, Color(0.10 * tone, 0.24 * tone, 0.13 * tone).srgb_to_linear())
	if mm.material_override is StandardMaterial3D:
		var m2 := mm.material_override as StandardMaterial3D
		m2.vertex_color_use_as_albedo = true
		m2.albedo_color = Color.WHITE

func _place_prop_at(kind: String, pos: Vector3, rot: float) -> void:
	var p := "res://assets/models/%s.glb" % kind
	if not ResourceLoader.exists(p):
		return
	var ps: PackedScene = load(p)
	if ps == null:
		return
	var node: Node3D = ps.instantiate()
	props_root.add_child(node)
	node.position = Vector3(pos.x, grid.height_at_world(pos.x, pos.z), pos.z)
	node.rotation.y = rot
	ModelPaint.apply(node)

func _scatter_boats() -> void:
	var path := "res://assets/models/prop_boat.glb"
	if not ResourceLoader.exists(path):
		return
	var ps: PackedScene = load(path)
	var placed := 0
	var tries := 0
	while placed < 6 and tries < 600:
		tries += 1
		var cell := Vector2i(rng.randi_range(3, MAP - 4), rng.randi_range(3, MAP - 4))
		if not grid.is_water(cell):
			continue
		if grid.height_at_cell(cell) > WATER_LEVEL - 0.8:
			continue
		var node: Node3D = ps.instantiate()
		props_root.add_child(node)
		var p := grid.cell_center(cell)
		node.position = Vector3(p.x, WATER_LEVEL + 0.10, p.z)
		node.rotation.y = rng.randf() * TAU
		ModelPaint.apply(node)
		placed += 1

func _near_building(pos: Vector3, radius: float) -> bool:
	for b in GameState.buildings:
		if is_instance_valid(b) and b.global_position.distance_to(pos) <= radius:
			return true
	return false

## 占地周围一圈是否存在水面
func _near_water(cell: Vector2i, size: Vector2i) -> bool:
	for x in range(cell.x - 1, cell.x + size.x + 1):
		for y in range(cell.y - 1, cell.y + size.y + 1):
			if grid.is_water(Vector2i(x, y)):
				return true
	return false

# ---------------------------------------------------------------- 植被

func _pine_trunk_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.09
	m.bottom_radius = 0.18
	m.height = 1.6
	m.radial_segments = 6
	m.rings = 1
	return m

func _pine_leaf_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = 1.05
	m.height = 2.9
	m.radial_segments = 8
	m.rings = 1
	return m

func _broad_trunk_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.12
	m.bottom_radius = 0.22
	m.height = 1.5
	m.radial_segments = 6
	m.rings = 1
	return m

func _broad_canopy_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 1.25
	m.height = 2.4
	m.radial_segments = 8
	m.rings = 4
	return m

func _rock_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 0.55
	m.height = 0.75
	m.radial_segments = 5
	m.rings = 3
	return m

func _bush_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 0.50
	m.height = 0.70
	m.radial_segments = 6
	m.rings = 3
	return m

func _grass_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = 0.17
	m.height = 0.36
	m.radial_segments = 4
	m.rings = 1
	return m

func _birch_trunk_mesh() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.08
	m.bottom_radius = 0.12
	m.height = 2.6
	m.radial_segments = 6
	m.rings = 1
	return m

func _birch_canopy_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 1.00
	m.height = 2.0
	m.radial_segments = 7
	m.rings = 3
	return m

func _make_multimesh(mesh: Mesh, count: int, color: Color, per_instance_color := false) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if per_instance_color:
		mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	mmi.multimesh = mm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.WHITE if per_instance_color else color
	if per_instance_color:
		m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	mmi.material_override = m
	return mmi

## 在基准色上做轻微的明度/冷暖扰动，避免整片森林一个颜色
## 注意：MultiMesh 的实例色按线性色解释，所以这里要转成线性，否则会整体发白
func _tint_variant(base: Color) -> Color:
	var v := rng.randf_range(0.84, 1.16)
	var w := rng.randf_range(-0.035, 0.035)
	return Color(
		clampf(base.r * v + w, 0.0, 1.0),
		clampf(base.g * v, 0.0, 1.0),
		clampf(base.b * v - w, 0.0, 1.0)
	)

func _apply_tree_colors(mmi_body: MultiMeshInstance3D, mmi_top: MultiMeshInstance3D, i: int, base: Color) -> void:
	var c := _tint_variant(base).srgb_to_linear()
	mmi_body.multimesh.set_instance_color(i, c)
	# 顶部只做轻微提亮（线性空间里乘系数），避免变成"白色帽子"
	mmi_top.multimesh.set_instance_color(i, Color(
		minf(c.r * 1.30, 1.0), minf(c.g * 1.30, 1.0), minf(c.b * 1.30, 1.0)
	))

func _build_decor() -> void:
	var used := {}
	var cells: Array[Vector2i] = []
	var centers: Array[Vector2i] = []
	var attempts := 0
	while centers.size() < 22 and attempts < 900:
		attempts += 1
		var cx := rng.randi_range(5, MAP - 6)
		var cy := rng.randi_range(5, MAP - 6)
		if Vector2(cx, cy).distance_to(Vector2(32, 32)) < 13.0:
			continue
		centers.append(Vector2i(cx, cy))

	for c in centers:
		var n := rng.randi_range(10, 22)
		for i in n:
			var cell: Vector2i = c + Vector2i(rng.randi_range(-5, 5), rng.randi_range(-5, 5))
			if cell.x < 5 or cell.y < 5 or cell.x >= MAP - 5 or cell.y >= MAP - 5:
				continue
			if used.has(cell):
				continue
			if grid.height_at_cell(cell) < 0.35:
				continue
			used[cell] = true
			cells.append(cell)

	var pine_cells: Array[Vector2i] = []
	var broad_cells: Array[Vector2i] = []
	var birch_cells: Array[Vector2i] = []
	for c in cells:
		var r := rng.randf()
		if r < 0.52:
			pine_cells.append(c)
		elif r < 0.84:
			broad_cells.append(c)
		else:
			birch_cells.append(c)

	# 雪线以上不长树
	var keep_pine: Array[Vector2i] = []
	var keep_broad: Array[Vector2i] = []
	var keep_birch: Array[Vector2i] = []
	for c in pine_cells:
		if grid.height_at_cell(c) <= 24.0:
			keep_pine.append(c)
	for c in broad_cells:
		if grid.height_at_cell(c) <= 24.0:
			keep_broad.append(c)
	for c in birch_cells:
		if grid.height_at_cell(c) <= 24.0:
			keep_birch.append(c)

	_build_forest(keep_pine, keep_broad, keep_birch)
	_scatter_rocks(used)
	_scatter_bushes(used)
	_scatter_grass()
	_scatter_flowers()
	_scatter_shore()

## 把树冠的 StandardMaterial 换成带手绘笔触的材质
func _apply_foliage(mmi: MultiMeshInstance3D) -> void:
	if mmi == null:
		return
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	if m.shader == null:
		return
	mmi.material_override = m

func _build_forest(pine_cells: Array[Vector2i], broad_cells: Array[Vector2i], birch_cells: Array[Vector2i] = []) -> void:
	if not pine_cells.is_empty():
		var n := pine_cells.size()
		pine_trunk = _make_multimesh(_pine_trunk_mesh(), n, Color(0.24, 0.16, 0.10))
		pine_leaf = _make_multimesh(_pine_leaf_mesh(), n, Color(0.11, 0.23, 0.12), true)
		pine_top = _make_multimesh(_pine_leaf_mesh(), n, Color(0.14, 0.28, 0.15), true)
		_apply_foliage(pine_leaf)
		_apply_foliage(pine_top)
		add_child(pine_trunk)
		add_child(pine_leaf)
		add_child(pine_top)
		for i in n:
			var cell: Vector2i = pine_cells[i]
			var p := grid.cell_center(cell) + Vector3(rng.randf_range(-0.35, 0.35), 0.0, rng.randf_range(-0.35, 0.35))
			var s := rng.randf_range(0.72, 1.32)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.90, 1.15), s))
			pine_trunk.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.8 * s, 0)))
			pine_leaf.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 3.0 * s, 0)))
			var top_basis := basis.scaled(Vector3(0.60, 0.55, 0.60))
			pine_top.multimesh.set_instance_transform(i, Transform3D(top_basis, p + Vector3(0, 3.65 * s, 0)))
			_apply_tree_colors(pine_leaf, pine_top, i, Color(0.11, 0.23, 0.12))
			grid.astar.set_point_solid(cell, true)
			pine_lookup[cell] = i

	if not broad_cells.is_empty():
		var n := broad_cells.size()
		broad_trunk = _make_multimesh(_broad_trunk_mesh(), n, Color(0.28, 0.19, 0.11))
		broad_canopy = _make_multimesh(_broad_canopy_mesh(), n, Color(0.20, 0.34, 0.13), true)
		broad_top = _make_multimesh(_broad_canopy_mesh(), n, Color(0.25, 0.40, 0.16), true)
		_apply_foliage(broad_canopy)
		_apply_foliage(broad_top)
		add_child(broad_trunk)
		add_child(broad_canopy)
		add_child(broad_top)
		for i in n:
			var cell: Vector2i = broad_cells[i]
			var p := grid.cell_center(cell) + Vector3(rng.randf_range(-0.35, 0.35), 0.0, rng.randf_range(-0.35, 0.35))
			var s := rng.randf_range(0.80, 1.28)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.10), s))
			broad_trunk.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.75 * s, 0)))
			broad_canopy.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 1.95 * s, 0)))
			var top_basis := basis.scaled(Vector3(0.58, 0.62, 0.58))
			broad_top.multimesh.set_instance_transform(i, Transform3D(top_basis, p + Vector3(0.14, 2.42 * s, -0.10)))
			_apply_tree_colors(broad_canopy, broad_top, i, Color(0.20, 0.34, 0.13))
			grid.astar.set_point_solid(cell, true)
			broad_lookup[cell] = i

	if not birch_cells.is_empty():
		var n := birch_cells.size()
		birch_trunk = _make_multimesh(_birch_trunk_mesh(), n, Color(0.70, 0.68, 0.62))
		birch_canopy = _make_multimesh(_birch_canopy_mesh(), n, Color(0.27, 0.40, 0.15), true)
		birch_top = _make_multimesh(_birch_canopy_mesh(), n, Color(0.32, 0.47, 0.18), true)
		_apply_foliage(birch_canopy)
		_apply_foliage(birch_top)
		add_child(birch_trunk)
		add_child(birch_canopy)
		add_child(birch_top)
		for i in n:
			var cell: Vector2i = birch_cells[i]
			var p := grid.cell_center(cell) + Vector3(rng.randf_range(-0.35, 0.35), 0.0, rng.randf_range(-0.35, 0.35))
			var s := rng.randf_range(0.85, 1.3)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.95, 1.2), s))
			birch_trunk.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 1.3 * s, 0)))
			birch_canopy.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 2.9 * s, 0)))
			var top_basis := basis.scaled(Vector3(0.54, 0.58, 0.54))
			birch_top.multimesh.set_instance_transform(i, Transform3D(top_basis, p + Vector3(0.10, 3.20 * s, 0.06)))
			_apply_tree_colors(birch_canopy, birch_top, i, Color(0.27, 0.40, 0.15))
			grid.astar.set_point_solid(cell, true)
			birch_lookup[cell] = i

## 水陆交界：芦苇 + 岸边碎石
func _scatter_shore() -> void:
	var shore: Array[Vector2i] = []
	for z in range(2, MAP - 2):
		for x in range(2, MAP - 2):
			var c := Vector2i(x, z)
			var h := grid.height_at_cell(c)
			if h < WATER_LEVEL - 0.10 or h > WATER_LEVEL + 0.90:
				continue
			var near := grid.is_water(Vector2i(x + 1, z)) or grid.is_water(Vector2i(x - 1, z)) \
				or grid.is_water(Vector2i(x, z + 1)) or grid.is_water(Vector2i(x, z - 1))
			if near:
				shore.append(c)
	if shore.is_empty():
		return

	var reed := CylinderMesh.new()
	reed.top_radius = 0.0
	reed.bottom_radius = 0.075
	reed.height = 1.50
	reed.radial_segments = 4
	reed.rings = 1

	var n := shore.size() * 7
	var reeds := _make_multimesh(reed, n, Color(0.56, 0.54, 0.30))
	reeds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(reeds)
	for i in n:
		var c: Vector2i = shore[i % shore.size()]
		var p := grid.cell_center(c) + Vector3(rng.randf_range(-0.95, 0.95), 0.0, rng.randf_range(-0.95, 0.95))
		p.y = grid.height_at_world(p.x, p.z)
		if p.y < WATER_LEVEL + 0.02 or p.y > WATER_LEVEL + 1.30:
			continue
		var s := rng.randf_range(0.65, 1.35)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.75, 1.35), s))
		reeds.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.58 * s, 0)))

	# 水线卵石带：贴着水面的小石头
	var peb := SphereMesh.new()
	peb.radius = 0.20
	peb.height = 0.13
	peb.radial_segments = 5
	peb.rings = 2
	var npeb := shore.size() * 9
	var pebbles := _make_multimesh(peb, npeb, Color(0.52, 0.50, 0.46))
	pebbles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pebbles)
	for i in npeb:
		var c2: Vector2i = shore[i % shore.size()]
		var q := grid.cell_center(c2) + Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
		var qy := grid.height_at_world(q.x, q.z)
		if qy < WATER_LEVEL - 0.05 or qy > WATER_LEVEL + 0.55:
			continue
		var ps2 := rng.randf_range(0.55, 1.5)
		var b2 := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(ps2, ps2 * rng.randf_range(0.5, 0.9), ps2))
		pebbles.multimesh.set_instance_transform(i, Transform3D(b2, Vector3(q.x, qy + 0.05, q.z)))

	# 岸边大块礁石：沿整条海岸线点缀
	var bold := []
	for i in shore.size():
		if i % 2 == 0:
			bold.append(shore[i])
	if not bold.is_empty():
		var rocks := _make_multimesh(_rock_mesh(), bold.size(), Color(0.46, 0.45, 0.41))
		add_child(rocks)
		for i in bold.size():
			var c: Vector2i = bold[i]
			var p := grid.cell_center(c) + Vector3(rng.randf_range(-1.1, 1.1), 0.0, rng.randf_range(-1.1, 1.1))
			p.y = grid.height_at_world(p.x, p.z) - 0.15
			var s := rng.randf_range(0.55, 1.45)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.6, 0.95), s))
			rocks.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.22 * s, 0)))
	# 岸边碎石
	var stones := _make_multimesh(_rock_mesh(), shore.size(), Color(0.52, 0.51, 0.47))
	stones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stones)
	for i in shore.size():
		var c: Vector2i = shore[i]
		var p := grid.cell_center(c) + Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
		p.y = grid.height_at_world(p.x, p.z)
		var s := rng.randf_range(0.26, 0.66)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * 0.65, s))
		stones.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.10 * s, 0)))

func _scatter_rocks(used: Dictionary) -> void:
	var list: Array[Vector2i] = []
	var tries := 0
	while list.size() < 55 and tries < 600:
		tries += 1
		var cell := Vector2i(rng.randi_range(5, MAP - 6), rng.randi_range(5, MAP - 6))
		if used.has(cell):
			continue
		if grid.height_at_cell(cell) < 0.35:
			continue
		used[cell] = true
		list.append(cell)
	if list.is_empty():
		return
	rock_mm = _make_multimesh(_rock_mesh(), list.size(), Color(0.44, 0.43, 0.41))
	add_child(rock_mm)
	for i in list.size():
		var cell: Vector2i = list[i]
		var p := grid.cell_center(cell) + Vector3(rng.randf_range(-0.45, 0.45), 0.0, rng.randf_range(-0.45, 0.45))
		var s := rng.randf_range(0.45, 1.15)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * 0.75, s))
		rock_mm.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.18 * s, 0)))
		rock_lookup[cell] = i

func _scatter_bushes(used: Dictionary) -> void:
	var list: Array[Vector2i] = []
	var tries := 0
	while list.size() < 150 and tries < 1500:
		tries += 1
		var cell := Vector2i(rng.randi_range(4, MAP - 5), rng.randi_range(4, MAP - 5))
		if used.has(cell):
			continue
		if grid.height_at_cell(cell) < 0.35:
			continue
		used[cell] = true
		list.append(cell)
	if list.is_empty():
		return
	bush_mm = _make_multimesh(_bush_mesh(), list.size(), Color(0.17, 0.29, 0.13))
	add_child(bush_mm)
	for i in list.size():
		var cell: Vector2i = list[i]
		var p := grid.cell_center(cell) + Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
		var s := rng.randf_range(0.55, 1.15)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.7, 1.0), s))
		bush_mm.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.22 * s, 0)))

func _scatter_grass() -> void:
	var n := 1700
	grass_mm = _make_multimesh(_grass_mesh(), n, Color(0.30, 0.45, 0.20))
	grass_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(grass_mm)
	# 成簇分布，避免均匀撒点像噪点
	var centers: Array[Vector3] = []
	for k in 300:
		centers.append(Vector3(
			rng.randf_range(5.0, MAP * CELL - 5.0), 0.0,
			rng.randf_range(5.0, MAP * CELL - 5.0)
		))
	for i in n:
		var c: Vector3 = centers[rng.randi_range(0, centers.size() - 1)]
		var p := c + Vector3(rng.randf_range(-2.2, 2.2), 0.0, rng.randf_range(-2.2, 2.2))
		p.y = grid.height_at_world(p.x, p.z)
		if p.y < 0.30:
			continue
		var s := rng.randf_range(0.6, 1.5)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.3), s))
		grass_mm.multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.17 * s, 0)))

func _scatter_flowers() -> void:
	var sm := SphereMesh.new()
	sm.radius = 0.075
	sm.height = 0.10
	sm.radial_segments = 5
	sm.rings = 2

	var palette := [
		Color(0.93, 0.91, 0.80),
		Color(0.88, 0.76, 0.32),
		Color(0.80, 0.44, 0.48),
		Color(0.74, 0.68, 0.88),
	]

	# 成簇分布：一部分在村镇附近，一部分散在野外
	var clusters: Array[Vector3] = []
	for i in 22:
		var p: Vector3
		if i < 10:
			var a := rng.randf() * TAU
			var rr := rng.randf_range(12.0, 34.0)
			p = Vector3(64.0 + cos(a) * rr, 0.0, 64.0 + sin(a) * rr)
		else:
			p = Vector3(rng.randf_range(18.0, 110.0), 0.0, rng.randf_range(18.0, 110.0))
		clusters.append(p)

	var instances: Array = []
	for c in clusters:
		var n := rng.randi_range(18, 40)
		var col: Color = palette[rng.randi_range(0, palette.size() - 1)]
		for k in n:
			var off := Vector3(rng.randf_range(-2.4, 2.4), 0.0, rng.randf_range(-2.4, 2.4))
			var p := c + off
			p.y = grid.height_at_world(p.x, p.z) + 0.05
			if p.y < 0.30:
				continue
			instances.append([p, col])

	flower_mm = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sm
	mm.instance_count = instances.size()
	flower_mm.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	flower_mm.material_override = mat
	add_child(flower_mm)

	for i in instances.size():
		var p: Vector3 = instances[i][0]
		var col: Color = instances[i][1]
		var s := rng.randf_range(0.7, 1.5)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, s, s)), p))
		mm.set_instance_color(i, col)

func _clear_trees(cell: Vector2i, size: Vector2i) -> void:
	var zero := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for x in size.x:
		for y in size.y:
			var c := cell + Vector2i(x, y)
			if pine_lookup.has(c):
				var i: int = pine_lookup[c]
				if pine_trunk != null:
					pine_trunk.multimesh.set_instance_transform(i, zero)
				if pine_leaf != null:
					pine_leaf.multimesh.set_instance_transform(i, zero)
				if pine_top != null:
					pine_top.multimesh.set_instance_transform(i, zero)
				pine_lookup.erase(c)
				grid.astar.set_point_solid(c, false)
			if broad_lookup.has(c):
				var j: int = broad_lookup[c]
				if broad_trunk != null:
					broad_trunk.multimesh.set_instance_transform(j, zero)
				if broad_canopy != null:
					broad_canopy.multimesh.set_instance_transform(j, zero)
				if broad_top != null:
					broad_top.multimesh.set_instance_transform(j, zero)
				broad_lookup.erase(c)
				grid.astar.set_point_solid(c, false)
			if birch_lookup.has(c):
				var b: int = birch_lookup[c]
				if birch_trunk != null:
					birch_trunk.multimesh.set_instance_transform(b, zero)
				if birch_canopy != null:
					birch_canopy.multimesh.set_instance_transform(b, zero)
				if birch_top != null:
					birch_top.multimesh.set_instance_transform(b, zero)
				birch_lookup.erase(c)
				grid.astar.set_point_solid(c, false)
			if rock_lookup.has(c):
				var k: int = rock_lookup[c]
				if rock_mm != null:
					rock_mm.multimesh.set_instance_transform(k, zero)
				rock_lookup.erase(c)

# ---------------------------------------------------------------- 建造

func _build_ghost() -> void:
	ghost_root = Node3D.new()
	ghost_root.visible = false
	add_child(ghost_root)

	ghost_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(3, 1.6, 3)
	ghost_mesh.mesh = bm
	ghost_mesh.position.y = 0.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.95, 0.45, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_mesh.material_override = mat
	ghost_root.add_child(ghost_mesh)
	ghost_root.set_meta("cell", Vector2i(-1, -1))

## 快捷栏"拆除"：优先拆当前选中的建筑，否则进入拆除模式
func quick_demolish() -> void:
	if selected != null and is_instance_valid(selected):
		demolish(selected)
		return
	GameState.log_msg("先点选一栋建筑，再按拆除。")

func start_build(id: String) -> void:
	if not BuildingDefs.DEFS.has(id):
		return
	build_mode = id
	ghost_root.visible = true
	var size: Vector2i = BuildingDefs.DEFS[id]["size"]
	var bm := ghost_mesh.mesh as BoxMesh
	bm.size = Vector3(size.x * CELL * 0.95, 1.6, size.y * CELL * 0.95)
	if ui != null:
		ui.set_build_mode(id)
	select(null)

func cancel_build() -> void:
	build_mode = ""
	ghost_root.visible = false
	if ui != null:
		ui.set_build_mode("")

func place_building(id: String, cell: Vector2i, free := false, force_complete := false) -> Building:
	if not BuildingDefs.DEFS.has(id):
		return null
	var d: Dictionary = BuildingDefs.DEFS[id]
	var size: Vector2i = d["size"]
	var needs_water := bool(d.get("needs_water", false))
	var is_road_def := bool(d.get("road", false))
	# 所有建筑都会清掉占地内的树，先清再判定占位（否则林地里什么都建不了）
	_clear_trees(cell, size)
	if not grid.footprint_free(cell, size):
		return null
	# 码头建在岸坡上、道路要能爬山，容许更大高差
	var max_slope := 1.2
	if needs_water:
		max_slope = 2.8
	elif is_road_def:
		max_slope = 2.6
	if grid.slope_in(cell, size) > max_slope:
		return null
	if needs_water and not _near_water(cell, size):
		return null
	if not free:
		if not GameState.can_afford(d["cost"]):
			return null
		GameState.pay(d["cost"])

	_clear_trees(cell, size)

	var b := Building.new()
	buildings_root.add_child(b)
	b.setup(id, cell)
	b.completed.connect(_on_building_completed)

	for x in size.x:
		for y in size.y:
			grid.occupied[cell + Vector2i(x, y)] = b

	if b.is_road():
		grid.set_road(cell, true)
		_set_road_mask(cell, true)
	else:
		grid.set_solid(cell, size, true)

	GameState.buildings.append(b)
	_rebuild_dirt_mask()
	if force_complete and not b.complete:
		b.finish_now()

	var nm := str(d.get("name", id))
	GameState.log_msg(("建成：%s" if b.complete else "开工：%s") % nm)
	return b

func upgrade_building(b: Building) -> void:
	if b == null or not is_instance_valid(b) or not b.complete:
		return
	var next := str(b.def.get("upgrades_to", ""))
	if next == "" or not BuildingDefs.DEFS.has(next):
		return
	var nd: Dictionary = BuildingDefs.DEFS[next]
	var cost: Dictionary = nd.get("cost", {})
	if not GameState.can_afford(cost):
		GameState.log_msg("资源不足，无法升级")
		return
	GameState.pay(cost)
	var old_name := str(b.def.get("name", b.def_id))
	b.begin_upgrade()
	GameState.log_msg("%s 开始升级为 %s" % [old_name, str(nd.get("name", next))])
	_assign_jobs()

## 中央广场：以村镇中心为圆心画一块石板铺装
const PLAZA_CELL := Vector2i(31, 31)
const PLAZA_RADIUS := 7.0

func _paint_plaza() -> void:
	if plaza_img == null:
		return
	for z in MAP:
		for x in MAP:
			var d := Vector2(float(x - PLAZA_CELL.x), float(z - PLAZA_CELL.y)).length()
			var v := clampf(1.0 - (d - PLAZA_RADIUS * 0.55) / (PLAZA_RADIUS * 0.45), 0.0, 1.0)
			if v > 0.0:
				plaza_img.set_pixel(x, z, Color(v, v, v))
	plaza_tex.update(plaza_img)

## 广场中心的喷泉
func _spawn_fountain() -> void:
	if fountain_node != null:
		return
	var path := "res://assets/models/fountain.glb"
	if not ResourceLoader.exists(path):
		return
	var ps: PackedScene = load(path)
	if ps == null:
		return
	fountain_node = ps.instantiate()
	props_root.add_child(fountain_node)
	var c := grid.cell_center(Vector2i(32, 30))
	fountain_node.position = Vector3(c.x, c.y, c.z)
	ModelPaint.apply(fountain_node)

## 河上的石拱桥
func _spawn_bridge() -> void:
	if bridge_node != null:
		return
	var path := "res://assets/models/bridge.glb"
	if not ResourceLoader.exists(path):
		return
	var ps: PackedScene = load(path)
	if ps == null:
		return
	bridge_node = ps.instantiate()
	props_root.add_child(bridge_node)
	bridge_node.position = Vector3(31.0, WATER_LEVEL - 1.35, 66.0)
	ModelPaint.apply(bridge_node)

## 港口：栈桥 + 停泊的帆船
func _spawn_harbor() -> void:
	if pier_node != null:
		return
	var pier_path := "res://assets/models/prop_pier.glb"
	if ResourceLoader.exists(pier_path):
		var ps: PackedScene = load(pier_path)
		if ps != null:
			pier_node = ps.instantiate()
			props_root.add_child(pier_node)
			pier_node.position = Vector3(28.5, WATER_LEVEL - 0.15, 55.0)
			ModelPaint.apply(pier_node)
	var ship_path := "res://assets/models/prop_ship.glb"
	if ResourceLoader.exists(ship_path):
		var ss: PackedScene = load(ship_path)
		if ss != null:
			ship_node = ss.instantiate()
			props_root.add_child(ship_node)
			ship_node.position = Vector3(28.5, WATER_LEVEL - 0.18, 74.0)
			ship_node.rotation.y = deg_to_rad(-8.0)
			ModelPaint.apply(ship_node)

## 村子南边的羊群
func _spawn_sheep() -> void:
	if _sheep_done:
		return
	_sheep_done = true
	var path := "res://assets/models/prop_sheep.glb"
	if not ResourceLoader.exists(path):
		return
	var ps: PackedScene = load(path)
	if ps == null:
		return
	for i in 9:
		var c := Vector2i(26 + rng.randi_range(0, 7), 42 + rng.randi_range(0, 5))
		var p := grid.cell_center(c)
		p.y = grid.height_at_world(p.x, p.z)
		p += Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
		var s := Critter.new()
		add_child(s)
		s.setup(ps, p, rng.randf_range(0.25, 0.5))

## 从门口向外铺一小段土路，让建筑和道路连起来
func _paint_door_path(b: Building) -> void:
	if b == null or not is_instance_valid(b) or b.is_road():
		return
	var half := b.size.y / 2
	var start := Vector2i(b.cell.x + b.size.x / 2, b.cell.y + b.size.y)
	for k in 4:
		var c := Vector2i(start.x, start.y + k)
		if c.x < 0 or c.y < 0 or c.x >= MAP or c.y >= MAP:
			break
		if grid.is_water(c):
			break
		if bool(grid.road_cells.get(c, false)):
			break
		grid.road_cells[c] = true
		_set_road_mask(c, true)

func _on_building_completed(b: Building) -> void:
	GameState.capacity += b.storage_capacity()
	_assign_jobs()
	spawn_context_prop(b)
	_paint_door_path(b)

func demolish(b: Building, refund := true) -> void:
	if b == null or not is_instance_valid(b):
		return
	for c in b.workers.duplicate():
		if is_instance_valid(c):
			c.workplace = null
	for c in b.builders.duplicate():
		if is_instance_valid(c):
			c.site = null
	b.workers.clear()
	b.builders.clear()

	GameState.buildings.erase(b)
	GameState.capacity -= b.storage_capacity()
	_rebuild_dirt_mask()
	for x in b.size.x:
		for y in b.size.y:
			grid.occupied.erase(b.cell + Vector2i(x, y))
	if b.is_road():
		grid.set_road(b.cell, false)
		_set_road_mask(b.cell, false)
	else:
		grid.set_solid(b.cell, b.size, false)

	if refund:
		var cost: Dictionary = b.def.get("cost", {})
		GameState.refund(cost, 0.5)

	if selected == b:
		select(null)
	GameState.log_msg("拆除：%s" % str(b.def.get("name", b.def_id)))
	b.queue_free()

func _try_place() -> void:
	var cell: Vector2i = ghost_root.get_meta("cell", Vector2i(-1, -1))
	if cell.x < 0:
		return
	var b := place_building(build_mode, cell)
	if b != null:
		cancel_build()
	else:
		GameState.log_msg("无法在此建造：位置被占用或资源不足。")

# ---------------------------------------------------------------- 选择

func screen_to_ground(screen_pos: Vector2):
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return null
	var t := -origin.y / dir.y
	if t < 0.0:
		return null
	return origin + dir * t

func _select_at(screen_pos: Vector2) -> void:
	var hit = screen_to_ground(screen_pos)
	if hit == null:
		select(null)
		return
	var cell: Vector2i = grid.world_to_cell(hit)
	if grid.occupied.has(cell):
		select(grid.occupied[cell])
	else:
		select(null)

func select(b: Building) -> void:
	selected = b
	if ui != null:
		ui.show_building(b)

# ---------------------------------------------------------------- 居民

func spawn_citizen(pos: Vector3) -> Citizen:
	var c := Citizen.new()
	citizens_root.add_child(c)
	var gy := grid.height_at_world(pos.x, pos.z)
	c.global_position = Vector3(pos.x, gy, pos.z)
	c.setup()
	c.died.connect(_on_citizen_died)
	GameState.citizens.append(c)
	return c

func _on_citizen_died(c: Citizen) -> void:
	GameState.citizens.erase(c)
	GameState.log_msg("一名居民死去了。")
	c.queue_free()

func _find_idle() -> Citizen:
	for c in GameState.citizens:
		if is_instance_valid(c) and not c.dead and c.workplace == null and c.site == null:
			return c
	return null

func _assign_jobs() -> void:
	# 工地优先：空闲居民先去盖房子
	for b in GameState.buildings:
		if not is_instance_valid(b) or b.complete:
			continue
		while b.builders.size() < 2:
			var cb := _find_idle()
			if cb == null:
				break
			b.add_builder(cb)
			cb.site = b
			cb._set_state(Citizen.St.IDLE)
	# 剩下的去生产岗位
	for b in GameState.buildings:
		if not is_instance_valid(b):
			continue
		if b.slots() <= 0:
			continue
		while b.workers.size() < b.slots():
			var c := _find_idle()
			if c == null:
				return
			b.add_worker(c)
			c._set_state(Citizen.St.IDLE)

func _try_growth() -> void:
	if GameState.citizens.size() >= GameState.home_capacity():
		return
	if float(GameState.stock.get("food", 0.0)) < 100.0:
		return
	if rng.randf() > 0.4:
		return
	var house := _random_house()
	if house == null:
		return
	spawn_citizen(house.global_position + Vector3(rng.randf_range(-2, 2), 0.0, rng.randf_range(-2, 2)))
	GameState.log_msg("一名新生儿降生。")

func _random_house() -> Building:
	var houses: Array = []
	for b in GameState.buildings:
		if int(b.def.get("homes", 0)) > 0:
			houses.append(b)
	if houses.is_empty():
		return null
	return houses[rng.randi_range(0, houses.size() - 1)]

# ---------------------------------------------------------------- 主循环

func _process(delta: float) -> void:
	_camera_input(delta)
	_update_ghost()

	if not _force_dusk and GameState.started and not GameState.paused:
		var frac := fmod(GameState.t, DAYLIGHT_CYCLE) / DAYLIGHT_CYCLE
		_set_daylight(_dusk_curve(frac))
	_tick_weather(delta)
	# 云影缓慢漂移（每 0.1 秒刷新一次即可）
	_cloud_time += delta
	_cloud_tick += delta
	if terrain_mat != null and _cloud_tick >= 0.1:
		_cloud_tick = 0.0
		terrain_mat.set_shader_parameter("cloud_time", _cloud_time)

	var target := 0.92 if GameState.is_winter() else 0.0
	_winter_mix = move_toward(_winter_mix, target, delta * 0.3)
	if terrain_mat != null:
		terrain_mat.set_shader_parameter("winter_mix", _winter_mix)
		var gt := 1.0 if build_mode != "" else 0.22
		_grid_alpha = lerpf(_grid_alpha, gt, minf(1.0, delta * 10.0))
		terrain_mat.set_shader_parameter("grid_alpha", _grid_alpha)

	_assign_timer += delta
	if _assign_timer >= 1.0:
		_assign_timer = 0.0
		_assign_jobs()

func _camera_input(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.z -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0

	var vp := get_viewport().get_visible_rect().size
	var mp := get_viewport().get_mouse_position()
	var edge := 14.0
	if mp.x >= 0.0 and mp.x < edge:
		dir.x -= 1.0
	elif mp.x > vp.x - edge and mp.x <= vp.x:
		dir.x += 1.0
	if mp.y >= 0.0 and mp.y < edge:
		dir.z -= 1.0
	elif mp.y > vp.y - edge and mp.y <= vp.y:
		dir.z += 1.0

	if dir != Vector3.ZERO:
		dir = dir.normalized().rotated(Vector3.UP, camera_rig.rotation.y)
		var spd := 42.0 * (camera.size / 46.0)
		camera_rig.position += dir * spd * delta
		camera_rig.position.x = clampf(camera_rig.position.x, 8.0, MAP * CELL - 8.0)
		camera_rig.position.z = clampf(camera_rig.position.z, 8.0, MAP * CELL - 8.0)

func _update_ghost() -> void:
	if build_mode == "":
		ghost_root.visible = false
		return
	ghost_root.visible = true

	var hit = screen_to_ground(get_viewport().get_mouse_position())
	if hit == null:
		return
	var size: Vector2i = BuildingDefs.DEFS[build_mode]["size"]
	# 让建筑以光标为中心，而不是以光标为左上角
	var cell: Vector2i = grid.world_to_cell(hit) - Vector2i(size.x / 2, size.y / 2)
	ghost_root.position = Vector3(
		(cell.x + size.x * 0.5) * CELL,
		grid.height_at_cell(cell),
		(cell.y + size.y * 0.5) * CELL
	)
	ghost_root.set_meta("cell", cell)

	var ok: bool = grid.footprint_free(cell, size) \
		and grid.slope_in(cell, size) <= (2.8 if bool(BuildingDefs.DEFS[build_mode].get("needs_water", false)) else 0.9) \
		and GameState.can_afford(BuildingDefs.DEFS[build_mode]["cost"])
	var mat := ghost_mesh.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(0.35, 0.95, 0.45, 0.35) if ok else Color(0.95, 0.30, 0.25, 0.40)

# ---------------------------------------------------------------- 输入

func _unhandled_input(event: InputEvent) -> void:
	if build_mode == "road":
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				_paint_road(event.position)
				return
			if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_erase_road(event.position)
				return
		elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_paint_road(event.position)
			return
		elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			cancel_build()
			return

	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if build_mode != "":
					_try_place()
				else:
					_select_at(event.position)
			MOUSE_BUTTON_RIGHT:
				if build_mode != "":
					cancel_build()
			MOUSE_BUTTON_MIDDLE:
				_mmb_dragging = true
				_mmb_last = event.position
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(-4.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(4.0)
	elif event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_mmb_dragging = false
	elif event is InputEventMouseMotion and _mmb_dragging:
		# 中键拖动：水平转视角，垂直调俯角
		var dx: float = event.relative.x
		var dy: float = event.relative.y
		camera_rig.rotation.y -= dx * 0.006
		if camera_pivot != null:
			var pitch := rad_to_deg(camera_pivot.rotation.x) - dy * 0.15
			camera_pivot.rotation.x = deg_to_rad(clampf(pitch, -78.0, -18.0))
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				if build_mode != "":
					cancel_build()
				else:
					select(null)
			KEY_SPACE:
				GameState.paused = not GameState.paused
			KEY_Q:
				camera_rig.rotation.y += deg_to_rad(15.0)
			KEY_E:
				camera_rig.rotation.y -= deg_to_rad(15.0)
			KEY_F5:
				save_game()
			KEY_F9:
				load_game()
			KEY_F11:
				var w := get_window()
				w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				var idx := int(event.keycode) - int(KEY_1)
				if idx >= 0 and idx < BUILD_ORDER.size():
					start_build(BUILD_ORDER[idx])

func _paint_road(screen_pos: Vector2) -> void:
	var hit = screen_to_ground(screen_pos)
	if hit == null:
		return
	var cell: Vector2i = grid.world_to_cell(hit)
	if not grid.footprint_free(cell, Vector2i.ONE):
		return
	place_building("road", cell)

func _erase_road(screen_pos: Vector2) -> void:
	var hit = screen_to_ground(screen_pos)
	if hit == null:
		return
	var cell: Vector2i = grid.world_to_cell(hit)
	var b = grid.occupied.get(cell, null)
	if b != null and b.is_road():
		demolish(b)

func _zoom(amount: float) -> void:
	camera.size = clampf(camera.size + amount, 16.0, 100.0)
	_update_label_scale()

func _update_label_scale() -> void:
	var k := camera.size / 46.0
	for b in GameState.buildings:
		if not is_instance_valid(b):
			continue
		for c in b.get_children():
			if c is Label3D:
				(c as Label3D).pixel_size = 0.013 * k

func _on_log(text: String) -> void:
	if ui != null:
		ui.add_log(text)

func _on_day(_d: int) -> void:
	_try_growth()
	_tick_sites()
	_try_disaster()
	_tick_fires()
	_tick_trade()
	_tick_happiness()

## 幸福度：有伙计的酒馆每天提升，否则缓慢下降
func _tick_happiness() -> void:
	var has_tavern := false
	for b in GameState.buildings:
		if is_instance_valid(b) and b.complete and b.def_id == "tavern" and not b.workers.is_empty():
			has_tavern = true
			break
	var target := 62.0
	if has_tavern:
		target = minf(100.0, GameState.happiness + 1.6)
	else:
		target = maxf(0.0, GameState.happiness - 0.9)
	GameState.happiness = move_toward(GameState.happiness, target, 0.8)

## 贸易站：每 6 天用最富余的资源换回最缺的工具/衣物
func _staffed_trade() -> Building:
	for b in GameState.buildings:
		if is_instance_valid(b) and b.complete and bool(b.def.get("trade", false)) and not b.workers.is_empty():
			return b
	return null

func _tick_trade() -> void:
	if GameState.total_days() % 6 != 0:
		return
	if _staffed_trade() == null:
		return
	var sell := ""
	var best := 60.0
	for r in ["wood", "stone", "food", "firewood", "leather"]:
		var amt := float(GameState.stock.get(r, 0.0))
		if amt > best:
			best = amt
			sell = r
	if sell == "":
		return
	var buy := "tools"
	if float(GameState.stock.get("tools", 0.0)) > float(GameState.stock.get("clothes", 0.0)):
		buy = "clothes"
	var amount := 20.0
	if not GameState.take(sell, amount):
		return
	GameState.add(buy, amount * 0.25)
	GameState.log_msg("贸易站：卖出 %d %s，换回 %.0f %s" % [
		int(amount), _res_name(sell), amount * 0.25, _res_name(buy)])

func _res_name(r: String) -> String:
	return str({"wood": "木材", "stone": "石头", "food": "食物", "firewood": "柴火",
		"tools": "工具", "clothes": "衣物", "leather": "皮革"}.get(r, r))

## 没有空闲工人时，工地也有一点点自发进度，避免完全卡死
func _tick_sites() -> void:
	for b in GameState.buildings:
		if is_instance_valid(b) and not b.complete:
			b.add_progress(0.25)

func _try_disaster() -> void:
	if GameState.buildings.size() < 3:
		return
	var s := GameState.season()
	var fire_chance := 0.008 if (s == 1 or s == 2) else 0.002
	if rng.randf() < fire_chance:
		_ignite_random()
	elif rng.randf() < 0.009:
		_outbreak()

func _well_near(b: Building) -> bool:
	for other in GameState.buildings:
		if not is_instance_valid(other) or not other.complete or not other.is_well():
			continue
		if other.global_position.distance_to(b.global_position) <= other.well_radius():
			return true
	return false

func _ignite_random() -> void:
	var candidates: Array = []
	for b in GameState.buildings:
		if is_instance_valid(b) and b.complete and not b.is_road():
			candidates.append(b)
	if candidates.is_empty():
		return
	var b: Building = candidates[rng.randi_range(0, candidates.size() - 1)]
	# 水井覆盖范围内，大概率根本烧不起来
	if _well_near(b) and rng.randf() < 0.65:
		return
	b.ignite()

func _outbreak() -> void:
	if GameState.citizens.is_empty():
		return
	var n := mini(4, maxi(2, GameState.citizens.size() / 6))
	var pool := GameState.citizens.duplicate()
	for i in n:
		if pool.is_empty():
			break
		var idx := rng.randi_range(0, pool.size() - 1)
		var c = pool[idx]
		pool.remove_at(idx)
		if is_instance_valid(c) and not c.dead:
			c.infect(rng.randi_range(3, 5))
	GameState.log_msg("瘟疫爆发！有居民病倒了。")

func _tick_fires() -> void:
	for b in GameState.buildings.duplicate():
		if not is_instance_valid(b) or not b.burning:
			continue
		b.burn_timer += 1.0
		var helped := _well_near(b)
		if b.burn_timer >= 0.9 and b.burn_timer < 2.5:
			for other in _nearby_buildings(b, 3.5):
				if other == b or other.burning or not other.complete or other.is_road():
					continue
				if rng.randf() < (0.05 if helped else 0.16):
					other.ignite()
		# 有可能自行熄灭，附近有水井时概率大幅提高
		if b.burn_timer >= 2.0 and rng.randf() < (0.75 if helped else 0.35):
			GameState.log_msg("%s 的火被扑灭了" % str(b.def.get("name", b.def_id)))
			b.extinguish()
			continue
		if b.burn_timer >= 3.5:
			GameState.log_msg("%s 被大火烧毁" % str(b.def.get("name", b.def_id)))
			demolish(b, false)

func _nearby_buildings(b: Building, radius: float) -> Array:
	var out: Array = []
	for other in GameState.buildings:
		if not is_instance_valid(other) or other == b:
			continue
		if b.global_position.distance_to(other.global_position) <= radius:
			out.append(other)
	return out

func _on_season(s: int) -> void:
	for b in GameState.buildings:
		if is_instance_valid(b) and b.def_id == "farm":
			b.apply_season_visual(s == 3)
	# 草簇与灌木入冬转雪色
	var grass_col := Color(0.30, 0.45, 0.20)
	var bush_col := Color(0.17, 0.29, 0.13)
	if s == 3:
		grass_col = Color(0.72, 0.76, 0.80)
		bush_col = Color(0.64, 0.68, 0.72)
	if grass_mm != null and grass_mm.material_override is StandardMaterial3D:
		(grass_mm.material_override as StandardMaterial3D).albedo_color = grass_col
	if bush_mm != null and bush_mm.material_override is StandardMaterial3D:
		(bush_mm.material_override as StandardMaterial3D).albedo_color = bush_col
	if flower_mm != null:
		flower_mm.visible = s != 3
	_apply_tree_season(s)
	match s:
		0: GameState.log_msg("春天来了，抓紧囤粮。")
		2: GameState.log_msg("秋收季节，农田产量最高。")
		3: GameState.log_msg("冬季来临，检查柴火储备！")

## 树冠随季节换色：秋天阔叶与白桦转黄橙，松树保持常绿
func _apply_tree_season(s: int) -> void:
	var broad_pal: Array[Color] = []
	var birch_pal: Array[Color] = []
	var pine_pal: Array[Color] = []
	match s:
		0:
			broad_pal = [Color(0.26, 0.44, 0.16), Color(0.31, 0.50, 0.19), Color(0.23, 0.40, 0.15)]
			birch_pal = [Color(0.34, 0.50, 0.20), Color(0.40, 0.56, 0.24)]
			pine_pal = [Color(0.12, 0.26, 0.14), Color(0.15, 0.30, 0.16)]
		1:
			broad_pal = [Color(0.22, 0.40, 0.14), Color(0.27, 0.46, 0.17), Color(0.19, 0.36, 0.13)]
			birch_pal = [Color(0.30, 0.46, 0.18), Color(0.36, 0.52, 0.21)]
			pine_pal = [Color(0.10, 0.23, 0.12), Color(0.13, 0.27, 0.14)]
		2:
			broad_pal = [Color(0.62, 0.44, 0.15), Color(0.72, 0.54, 0.18), Color(0.50, 0.34, 0.12)]
			birch_pal = [Color(0.78, 0.64, 0.24), Color(0.66, 0.50, 0.18)]
			pine_pal = [Color(0.13, 0.26, 0.14), Color(0.16, 0.30, 0.16)]
		_:
			broad_pal = [Color(0.42, 0.44, 0.42), Color(0.48, 0.50, 0.48)]
			birch_pal = [Color(0.52, 0.54, 0.52)]
			pine_pal = [Color(0.26, 0.32, 0.30), Color(0.30, 0.36, 0.34)]
	_retint_canopy(broad_canopy, broad_pal)
	_retint_canopy(broad_top, broad_pal)
	_retint_canopy(birch_canopy, birch_pal)
	_retint_canopy(birch_top, birch_pal)
	_retint_canopy(pine_leaf, pine_pal)
	_retint_canopy(pine_top, pine_pal)

func _retint_canopy(mmi: MultiMeshInstance3D, pal: Array[Color]) -> void:
	if mmi == null or pal.is_empty():
		return
	var mm := mmi.multimesh
	if mm == null:
		return
	for i in mm.instance_count:
		var c: Color = pal[rng.randi_range(0, pal.size() - 1)]
		var v := rng.randf_range(0.9, 1.1)
		c = Color(clampf(c.r * v, 0.0, 1.0), clampf(c.g * v, 0.0, 1.0), clampf(c.b * v, 0.0, 1.0))
		mm.set_instance_color(i, c.srgb_to_linear())

# ---------------------------------------------------------------- 存档

const SAVE_PATH := "user://save.json"

func save_game() -> void:
	var data := {
		"version": 1,
		"t": GameState.t,
		"stock": GameState.stock,
		"happiness": GameState.happiness,
		"buildings": [],
		"citizens": [],
	}
	for b in GameState.buildings:
		if not is_instance_valid(b):
			continue
		data["buildings"].append({
			"id": b.def_id,
			"cell": [b.cell.x, b.cell.y],
			"complete": b.complete,
			"progress": b.progress,
		})
	for c in GameState.citizens:
		if not is_instance_valid(c) or c.dead:
			continue
		data["citizens"].append({
			"pos": [c.global_position.x, c.global_position.z],
			"hunger": c.hunger,
			"warmth": c.warmth,
			"health": c.health,
			"carry": c.carry,
			"carry_res": c.carry_res,
			"home": GameState.buildings.find(c.home),
			"work": GameState.buildings.find(c.workplace),
		})

	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		GameState.log_msg("存档失败：无法写入")
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	GameState.log_msg("已存档（%d 建筑 / %d 居民）" % [data["buildings"].size(), data["citizens"].size()])

func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		GameState.log_msg("没有找到存档")
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		GameState.log_msg("存档损坏")
		return
	var data: Dictionary = parsed

	# 清空旧世界
	for b in GameState.buildings.duplicate():
		if is_instance_valid(b):
			b.queue_free()
	GameState.buildings.clear()
	for c in GameState.citizens.duplicate():
		if is_instance_valid(c):
			c.queue_free()
	GameState.citizens.clear()
	grid.occupied.clear()
	grid.road_cells.clear()
	for x in grid.map_size:
		for y in grid.map_size:
			grid.astar.set_point_solid(Vector2i(x, y), false)
			grid.astar.set_point_weight_scale(Vector2i(x, y), 1.0)
	# 恢复边界与树木的阻挡
	grid.set_border(2)
	for c in pine_lookup:
		grid.astar.set_point_solid(c, true)
	for c in broad_lookup:
		grid.astar.set_point_solid(c, true)

	GameState.capacity = GameState.BASE_CAPACITY
	GameState.stock = {}
	for k in data.get("stock", {}):
		GameState.stock[k] = float(data["stock"][k])
	GameState.t = float(data.get("t", 0.0))
	GameState.happiness = float(data.get("happiness", 62.0))

	var placed: Array = []
	for bd in data.get("buildings", []):
		var cell := Vector2i(int(bd["cell"][0]), int(bd["cell"][1]))
		var b := place_building(str(bd["id"]), cell, true, false)
		placed.append(b)
		if b == null:
			continue
		if bool(bd.get("complete", true)):
			b.finish_now()
		else:
			b.progress = float(bd.get("progress", 0.0))
			b.add_progress(0.0)

	for cd in data.get("citizens", []):
		var p: Array = cd["pos"]
		var c := spawn_citizen(Vector3(float(p[0]), 0.0, float(p[1])))
		c.hunger = float(cd.get("hunger", 100.0))
		c.warmth = float(cd.get("warmth", 100.0))
		c.health = float(cd.get("health", 100.0))
		c.carry = float(cd.get("carry", 0.0))
		c.carry_res = str(cd.get("carry_res", "wood"))
		var hi := int(cd.get("home", -1))
		var wi := int(cd.get("work", -1))
		if hi >= 0 and hi < placed.size() and is_instance_valid(placed[hi]) and placed[hi].complete:
			c.home = placed[hi]
		if wi >= 0 and wi < placed.size() and is_instance_valid(placed[wi]) and placed[wi].complete:
			placed[wi].add_worker(c)

	_assign_jobs()
	select(null)
	_rebuild_road_mask()
	_rebuild_dirt_mask()
	GameState.log_msg("读档完成")

# ---------------------------------------------------------------- 调试入口

func _handle_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if "--autotest" in args:
		GameState.speed = 8.0
		GameState.verbose = true
		GameState.log_msg("自动测试开始。")
		var plan := [
			["woodcutter", Vector2i(24, 28)],
			["gatherer", Vector2i(36, 28)],
			["gatherer", Vector2i(36, 32)],
			["firewood", Vector2i(31, 26)],
			["farm", Vector2i(20, 34)],
			["hunter", Vector2i(25, 24)],
			["house", Vector2i(38, 36)],
			["house", Vector2i(40, 30)],
		]
		for item in plan:
			var b: Building = place_building(str(item[0]), item[1])
			if b == null:
				print("AUTOPLAY 建造失败: ", item[0], " @", item[1])
		for i in range(1, 9):
			await get_tree().create_timer(10.0).timeout
			_print_stats(i)
		_selftest()
		get_tree().quit()
	elif "--savetest" in args:
		GameState.speed = 4.0
		GameState.verbose = true
		place_building("woodcutter", Vector2i(24, 28), true, true)
		place_building("house", Vector2i(43, 30), true, false)
		for i in 3:
			place_building("road", Vector2i(40 + i, 32), true, true)
		await get_tree().create_timer(5.0).timeout
		var before := _snapshot()
		save_game()
		for b in GameState.buildings.duplicate():
			demolish(b, false)
		await get_tree().create_timer(1.0).timeout
		print("SAVETEST 清空后: ", _snapshot())
		load_game()
		await get_tree().create_timer(1.0).timeout
		print("SAVETEST before=", before)
		print("SAVETEST after =", _snapshot())
		get_tree().quit()
	elif "--distest" in args:
		GameState.speed = 8.0
		GameState.verbose = true
		place_building("well", Vector2i(40, 40), true, true)
		var wood: Building = place_building("woodcutter", Vector2i(43, 40), true, true)
		var far: Building = place_building("woodcutter", Vector2i(52, 52), true, true)
		print("DISTEST 水井覆盖内=", _well_near(wood), " 远处=", _well_near(far))
		wood.ignite()

		var hosp: Building = place_building("hospital", Vector2i(44, 45), true, true)
		var doc: Citizen = GameState.citizens[0]
		hosp.add_worker(doc)
		print("DISTEST 医院有医生=", GameState.active_hospital() != null)
		var pat: Citizen = GameState.citizens[1]
		pat.infect(4)
		var hp0 := pat.health
		await get_tree().create_timer(13.0).timeout
		print("DISTEST 病人 health %.0f -> %.0f, sick=%d" % [hp0, pat.health, pat.sick])
		print("DISTEST 水井旁伐木场 存活=%s burning=%s" % [
			is_instance_valid(wood), (wood.burning if is_instance_valid(wood) else false)])
		get_tree().quit()
	elif "--econtest" in args:
		GameState.speed = 8.0
		GameState.verbose = true
		var h: Building = place_building("hunter", Vector2i(26, 24), true, true)
		var t: Building = place_building("tailor", Vector2i(30, 24), true, true)
		var s: Building = place_building("blacksmith", Vector2i(34, 24), true, true)
		var p: Building = place_building("trade", Vector2i(38, 24), true, true)
		await get_tree().create_timer(4.0).timeout
		print("ECON 开局 工具=%d 衣物=%d 皮革=%d" % [
			int(float(GameState.stock["tools"])), int(float(GameState.stock["clothes"])),
			int(float(GameState.stock["leather"]))])
		print("ECON 岗位 猎人=%d 裁缝=%d 铁匠=%d 贸易=%d" % [
			h.workers.size(), t.workers.size(), s.workers.size(), p.workers.size()])
		await get_tree().create_timer(22.0).timeout
		print("ECON 结算 工具=%d 衣物=%d 皮革=%d" % [
			int(float(GameState.stock["tools"])), int(float(GameState.stock["clothes"])),
			int(float(GameState.stock["leather"]))])
		print("ECON 累计 皮革产物=%.1f 衣物产物=%.1f 工具产物=%.1f" % [
			h.produced, t.produced, s.produced])
		get_tree().quit()
	elif "--uptest" in args:
		GameState.speed = 8.0
		GameState.verbose = true
		var h: Building = place_building("house", Vector2i(44, 44), true, true)
		print("UPTEST 初始 id=%s homes=%d 总居住位=%d" % [h.def_id, int(h.def.get("homes", 0)), GameState.home_capacity()])
		upgrade_building(h)
		print("UPTEST 升级后 id=%s complete=%s 进度=0" % [h.def_id, h.complete])
		await get_tree().create_timer(28.0).timeout
		print("UPTEST 完成 id=%s complete=%s 总居住位=%d" % [h.def_id, h.complete, GameState.home_capacity()])
		get_tree().quit()
	elif "--shot" in args:
		if "--town" in args:
			_build_demo_town()
		if "--fire" in args:
			_build_demo_town()
			for b in GameState.buildings:
				if b.def_id == "storage":
					b.ignite()
					break
		if "--close" in args:
			camera.size = 13.0
			camera_rig.position = Vector3(60.0, 0.0, 62.0)
			_update_label_scale()
		if "--far" in args:
			camera.size = 115.0
			camera_rig.position = Vector3(64.0, 0.0, 64.0)
			_update_label_scale()
		if "--winter" in args:
			_setup_winter_scene()
		if "--at" in args:
			var ai := args.find("--at")
			camera_rig.position = Vector3(float(args[ai + 1]), 0.0, float(args[ai + 2]))
			_update_label_scale()
		if "--size" in args:
			camera.size = float(args[args.find("--size") + 1])
		if "--cutshadow" in args:
			_cut_shadows(str(args[args.find("--cutshadow") + 1]))
		if "--dusk" in args:
			_apply_dusk()
		if "--rain" in args:
			set_weather(true)
			if not GameState.is_winter():
				_wet = 1.0
				if terrain_mat != null:
					terrain_mat.set_shader_parameter("wet", 1.0)
		if "--season" in args:
			var si := int(args[args.find("--season") + 1])
			GameState.t = float(si) * GameState.DAYS_PER_SEASON * GameState.DAY_SECONDS + 1.0
			_on_season(GameState.season())
		await get_tree().create_timer(2.0).timeout
		await RenderingServer.frame_post_draw
		print("WINTERCHECK mix=%.2f is_winter=%s shader=%.2f" % [
			_winter_mix, GameState.is_winter(), float(terrain_mat.get_shader_parameter("winter_mix"))])
		var vc := get_viewport().get_visible_rect().size * 0.5
		print("RAYTEST 视口中心=", vc, " 射线落点=", screen_to_ground(vc), " 相机焦点=", camera_rig.position)
		var img := get_viewport().get_texture().get_image()
		var p := "res://shot.png"
		img.save_png(p)
		print("screenshot: ", p)
		get_tree().quit()

## 天气：雨
var rain_node: GPUParticles3D = null
var snow_node: GPUParticles3D = null
var _raining := false
var _wet := 0.0
var _cloud_time := 0.0
var _cloud_tick := 0.0
var _weather_timer := 0.0

func _build_rain() -> void:
	rain_node = GPUParticles3D.new()
	rain_node.amount = 2600
	rain_node.lifetime = 1.6
	rain_node.preprocess = 1.2
	rain_node.emitting = false
	rain_node.local_coords = false
	rain_node.visibility_aabb = AABB(Vector3(-60, -40, -60), Vector3(120, 80, 120))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(42, 2, 42)
	pm.direction = Vector3(0.12, -1.0, 0.05)
	pm.spread = 4.0
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 22.0
	pm.gravity = Vector3(0.6, -9.0, 0.4)
	pm.scale_min = 0.8
	pm.scale_max = 1.5
	rain_node.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.030, 1.05)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/rain.gdshader")
	quad.material = mat
	rain_node.draw_pass_1 = quad
	rain_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rain_node)

func set_weather(rain: bool) -> void:
	_raining = rain
	if rain_node != null:
		rain_node.emitting = rain and not GameState.is_winter()
	if snow_node != null:
		snow_node.emitting = rain and GameState.is_winter()

## 雪：冬季降水换成慢速飘落的雪花
func _build_snow() -> void:
	snow_node = GPUParticles3D.new()
	snow_node.amount = 1400
	snow_node.lifetime = 9.0
	snow_node.preprocess = 4.0
	snow_node.emitting = false
	snow_node.local_coords = false
	snow_node.visibility_aabb = AABB(Vector3(-60, -40, -60), Vector3(120, 80, 120))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(40, 2, 40)
	pm.direction = Vector3(0.15, -1.0, 0.10)
	pm.spread = 22.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 3.8
	pm.gravity = Vector3(0.5, -0.6, 0.3)
	pm.scale_min = 0.7
	pm.scale_max = 1.8
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.4
	pm.turbulence_noise_scale = 2.2
	snow_node.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/smoke.gdshader")
	quad.material = mat
	snow_node.draw_pass_1 = quad
	snow_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(snow_node)

## 天气与湿度每帧推进：雨停后地面慢慢变干
func _tick_weather(delta: float) -> void:
	if rain_node == null:
		return
	if not GameState.paused and GameState.started:
		_weather_timer += delta
		if _weather_timer > 45.0:
			_weather_timer = 0.0
			set_weather(not _raining)
	if rain_node != null and camera_rig != null:
		rain_node.global_position = camera_rig.position + Vector3(0, 32, 0)
	if snow_node != null and camera_rig != null:
		snow_node.global_position = camera_rig.position + Vector3(0, 30, 0)
	# 季节切换时自动换降水类型
	if _raining:
		var winter := GameState.is_winter()
		if rain_node != null:
			rain_node.emitting = not winter
		if snow_node != null:
			snow_node.emitting = winter
	var target := 1.0 if (_raining and not GameState.is_winter()) else 0.0
	_wet = move_toward(_wet, target, delta * (0.8 if _raining else 0.12))
	if terrain_mat != null:
		terrain_mat.set_shader_parameter("wet", _wet)
	# 雨天压暗、偏冷
	_ensure_light_refs()
	if _sun != null:
		_sun.light_energy *= (1.0 - 0.30 * _wet)
	if _env != null:
		_env.ambient_light_color = _env.ambient_light_color.lerp(Color(0.46, 0.50, 0.60), _wet * 0.20)


const DAYLIGHT_CYCLE := 80.0
var _sun: DirectionalLight3D = null
var _env: Environment = null
var _night_flag := false
var _force_dusk := false

func _dusk_curve(f: float) -> float:
	if f < 0.62:
		return 0.0
	if f < 0.76:
		return smoothstep(0.62, 0.76, f)
	if f < 0.94:
		return 1.0
	return 1.0 - smoothstep(0.94, 1.0, f)

func _ensure_light_refs() -> void:
	if _sun != null:
		return
	for c in get_children():
		if c is DirectionalLight3D:
			_sun = c
		elif c is WorldEnvironment:
			_env = (c as WorldEnvironment).environment

func _set_daylight(k: float) -> void:
	_ensure_light_refs()
	if _sun == null:
		return
	_sun.rotation_degrees = Vector3(-44, -38, 0).lerp(Vector3(-15, -32, 0), k)
	_sun.light_energy = lerpf(2.05, 1.20, k)
	_sun.light_color = Color(1.0, 0.94, 0.82).lerp(Color(1.0, 0.58, 0.33), k)
	if _env != null:
		_env.ambient_light_color = Color(0.64, 0.65, 0.68).lerp(Color(0.34, 0.38, 0.58), k)
		_env.ambient_light_energy = lerpf(0.60, 0.66, k)
		# 雪面反射强，冬季把环境光提一档并调暖，阴影里的雪不会发紫
		if GameState.is_winter():
			_env.ambient_light_energy *= 1.35
			_env.ambient_light_color = _env.ambient_light_color.lerp(Color(0.68, 0.70, 0.76), 0.55)
		_env.fog_light_color = Color(0.68, 0.68, 0.70).lerp(Color(0.30, 0.30, 0.40), k)
		_env.tonemap_exposure = lerpf(1.15, 1.30, k)
		_env.glow_intensity = lerpf(0.32, 0.75, k)
	var night_now := k > 0.55
	if night_now != _night_flag:
		_night_flag = night_now
		ModelPaint.night = night_now
		for b in GameState.buildings:
			if is_instance_valid(b):
				b.refresh_materials()

## 阴影二分排查：--cutshadow <组名>
func _cut_shadows(which: String) -> void:
	var targets: Array = []
	match which:
		"buildings":
			targets.append(buildings_root)
		"props":
			targets.append(props_root)
		"citizens":
			targets.append(citizens_root)
		"particles":
			if rain_node != null:
				rain_node.visible = false
			if snow_node != null:
				snow_node.visible = false
			for b in GameState.buildings:
				if is_instance_valid(b) and b.smoke != null:
					b.smoke.visible = false
			return
		"canopy":
			targets = [pine_leaf, pine_top, broad_canopy, broad_top, birch_canopy, birch_top, pine_trunk, broad_trunk, birch_trunk]
	for t in targets:
		if t == null:
			continue
		for m in (t as Node).find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## 黄昏/夜晚（命令行强制）
func _apply_dusk() -> void:
	_force_dusk = true
	_set_daylight(1.0)

func _build_demo_town() -> void:
	var layout := [
		["woodcutter", Vector2i(24, 28)],
		["gatherer", Vector2i(36, 28)],
		["hunter", Vector2i(24, 24)],
		["firewood", Vector2i(31, 26)],
		["farm", Vector2i(20, 34)],
		["quarry", Vector2i(38, 24)],
		["well", Vector2i(26, 36)],
		["hospital", Vector2i(37, 34)],
		["tailor", Vector2i(26, 24)],
		["blacksmith", Vector2i(30, 24)],
		["trade", Vector2i(34, 24)],
		["tavern", Vector2i(41, 27)],
		["firewood", Vector2i(45, 36)],
		["windmill", Vector2i(30, 40)],
		["church", Vector2i(33, 37)],
		["dock", Vector2i(18, 29)],
		["house_row", Vector2i(25, 33)],
		["house_row", Vector2i(27, 33)],
		["carpenter", Vector2i(33, 33)],
	]
	for item in layout:
		place_building(str(item[0]), item[1], true, true)
	# 主干道
	for x in range(26, 40):
		place_building("road", Vector2i(x, 32), true, true)
	for y in range(24, 38):
		place_building("road", Vector2i(30, y), true, true)
	# 通往山坡的小路
	for x in range(18, 26):
		place_building("road", Vector2i(x, 42), true, true)
	# 一栋在建的民居，用来展示脚手架
	var site := place_building("house", Vector2i(43, 30), true, false)
	if site != null:
		site.add_progress(3.0)
	# 一栋升级成石屋、一栋升级成大宅的民居
	for b in GameState.buildings:
		if b.def_id == "house" and b.cell == Vector2i(28, 34):
			b.begin_upgrade()
			b.finish_now()
		elif b.def_id == "house" and b.cell == Vector2i(34, 34):
			b.begin_upgrade()
			b.finish_now()
			b.begin_upgrade()
			b.finish_now()
	for i in 6:
		var a := TAU * float(i) / 6.0
		spawn_citizen(Vector3(62.0 + cos(a) * 6.0, 0.0, 66.0 + sin(a) * 5.0))
	camera.size = 46.0
	camera_rig.position = Vector3(60.0, 0.0, 62.0)
	_update_label_scale()
	_scatter_props()
	_scatter_far_forest()
	_spawn_fountain()
	_spawn_bridge()
	_spawn_harbor()
	_spawn_sheep()
	_build_pasture_fence()
	_build_footbridge()
	_build_church_forecourt()
	_build_market()
	_build_quarry_yard()
	_build_mountain_range()
	_scatter_saplings()
	_scatter_tall_pines()
	_fence_line(Vector2(46.0, 44.0), Vector2(66.0, 44.0))
	_fence_line(Vector2(74.0, 44.0), Vector2(90.0, 46.0))
	_fence_line(Vector2(46.0, 46.0), Vector2(46.0, 76.0))
	_fence_line(Vector2(89.0, 48.0), Vector2(89.0, 76.0))
	_build_gate(Vector3(60.0, 0.0, 44.0), 0.0)
	_build_gate(Vector3(60.0, 0.0, 92.0), 0.0)
	# 村门与主路之间的衔接
	_paint_road_line(Vector2(60.0, 44.0), Vector2(60.0, 52.0))
	_paint_road_line(Vector2(60.0, 92.0), Vector2(60.0, 84.0))
	# 村内小巷
	_paint_road_line(Vector2(52.0, 60.0), Vector2(52.0, 74.0))
	_paint_road_line(Vector2(72.0, 56.0), Vector2(72.0, 70.0))
	_paint_road_line(Vector2(44.0, 72.0), Vector2(57.0, 82.0))
	_paint_road_line(Vector2(57.0, 82.0), Vector2(66.0, 88.0))
	_spawn_all_context_props()

func _setup_winter_scene() -> void:
	place_building("woodcutter", Vector2i(24, 28), true, true)
	place_building("gatherer", Vector2i(36, 28), true, true)
	place_building("firewood", Vector2i(31, 26), true, true)
	place_building("farm", Vector2i(20, 34), true, true)
	place_building("hunter", Vector2i(25, 24), true, true)
	GameState.t = 3.0 * float(GameState.DAYS_PER_SEASON) * GameState.DAY_SECONDS \
		+ 1.5 * GameState.DAY_SECONDS
	_winter_mix = 0.85
	if terrain_mat != null:
		terrain_mat.set_shader_parameter("winter_mix", _winter_mix)

func _selftest() -> void:
	print("SELFTEST 交互路径")
	var cell := Vector2i(44, 44)
	start_build("quarry")
	ghost_root.set_meta("cell", cell)
	_try_place()
	var b: Building = grid.occupied.get(cell, null)
	print("  建造摆放: ", "OK" if b != null else "FAIL", " | build_mode 已重置=", build_mode == "")
	if b != null:
		select(b)
		print("  选中面板可见: ", ui.sel_panel.visible, " | 标题: ", ui.sel_title.text)
		demolish(b)
		print("  拆除后格子释放: ", not grid.occupied.has(cell), " | 面板隐藏: ", not ui.sel_panel.visible)
	print("  屏幕中心射线落点: ", screen_to_ground(Vector2(800, 450)))

func _snapshot() -> String:
	return "pop=%d bld=%d wood=%d food=%d fire=%d day=%d" % [
		GameState.citizens.size(),
		GameState.buildings.size(),
		int(float(GameState.stock.get("wood", 0.0))),
		int(float(GameState.stock.get("food", 0.0))),
		int(float(GameState.stock.get("firewood", 0.0))),
		GameState.total_days(),
	]

func _print_stats(step: int) -> void:
	var working := 0
	var idle := 0
	var moving := 0
	for c in GameState.citizens:
		if c.state == Citizen.St.WORK:
			working += 1
		elif c.state == Citizen.St.IDLE:
			idle += 1
		else:
			moving += 1
	var sites := 0
	for b in GameState.buildings:
		if not b.complete:
			sites += 1
	print("    状态: 工作=%d 闲置=%d 移动/吃饭=%d | 工地=%d | 累计进餐=%d 入库食物=%.0f" % [
		working, idle, moving, sites, GameState.stat_meals, GameState.stat_food_in])
	if not GameState.citizens.is_empty():
		var carrying := 0
		for c in GameState.citizens:
			if c.carry > 0.5:
				carrying += 1
		print("    搬运中: %d" % carrying)
		for c in GameState.citizens:
			if c._anim != null:
				print("    角色动画: %s (speed=%.2f, carry=%.1f)" % [
					c._anim.current_animation, c._anim.speed_scale, c.carry])
				break
	for b in GameState.buildings:
		if b.slots() > 0:
			print("    %s 工人=%d/%d 累计产出=%.1f" % [
				str(b.def["name"]), b.workers.size(), b.slots(), b.produced])
	print("[%d] 第%d年 %s 第%d天 | 人口=%d | 木=%d 石=%d 食=%d 柴=%d | 建筑=%d | 仓容=%d" % [
		step, GameState.year(), GameState.season_name(), GameState.day_in_season() + 1,
		GameState.citizens.size(),
		int(float(GameState.stock["wood"])), int(float(GameState.stock["stone"])),
		int(float(GameState.stock["food"])), int(float(GameState.stock["firewood"])),
		GameState.buildings.size(), int(GameState.capacity),
	])

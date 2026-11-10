class_name Building
extends Node3D
## 一栋建筑：占位、外观、工人槽位、施工进度、火灾状态。

signal completed(b)

const MODELS := {
	"house": "res://assets/models/house.glb",
	"storage": "res://assets/models/storage.glb",
	"woodcutter": "res://assets/models/woodcutter.glb",
	"gatherer": "res://assets/models/gatherer.glb",
	"pasture": "res://assets/models/pasture.glb",
	"hunter": "res://assets/models/hunter.glb",
	"farm": "res://assets/models/farm.glb",
	"firewood": "res://assets/models/firewood.glb",
	"quarry": "res://assets/models/quarry.glb",
	"well": "res://assets/models/well.glb",
	"hospital": "res://assets/models/hospital.glb",
	"tailor": "res://assets/models/tailor.glb",
	"blacksmith": "res://assets/models/blacksmith.glb",
	"trade": "res://assets/models/trade.glb",
	"house_stone": "res://assets/models/house_stone.glb",
	"house_manor": "res://assets/models/house_manor.glb",
	"windmill": "res://assets/models/windmill.glb",
	"church": "res://assets/models/church.glb",
	"school": "res://assets/models/school.glb",
	"dock": "res://assets/models/dock.glb",
	"house_row": "res://assets/models/house_row.glb",
	"carpenter": "res://assets/models/carpenter.glb",
	"tavern": "res://assets/models/tavern.glb",
}

## 水井消防：与 Main._tick_fires / _ignite_random 共用同一组概率
const WELL_IGNITE_BLOCK := 0.65
const WELL_EXTINGUISH := 0.75
const WELL_FIRE_SPREAD := 0.05
const FIRE_SPREAD := 0.16

## 采石场：由 Main 注入，统计/消耗地图石矿
static var quarry_rock_count: Callable = Callable()
static var quarry_take_rock: Callable = Callable()

var blades: Node3D = null
var smoke: CPUParticles3D = null
var crop_mm: MultiMeshInstance3D = null
var _crop_pos: Array[Vector2] = []

var def_id := ""
var def: Dictionary = {}
var cell := Vector2i.ZERO
var size := Vector2i.ONE

var workers: Array = []
var builders: Array = []
var produced := 0.0

var complete := true
var progress := 0.0
var need_work := 0.0

var burning := false
var burn_timer := 0.0

## 当日已付学堂维护费，学童加成生效
var school_running := false

## 锁定后自动排班不会把在岗工人调离（病亡除外）。
var lock_workers := false
## 自动 `_assign_jobs` 时优先补满岗位。
var job_priority := false

## 牧场羊群。herd_ready 为 false 时完工会按 def.herd 引进；读档若已有 herd_count 则先置位，避免覆盖。
var herd_count := 0
var herd_health := 80.0
var herd_keep := 4
var herd_sick := 0
var herd_ready := false
var herd_full_warned := false

var _quarry_extract := 0.0

var _visual: Node3D
var _scaffold: Node3D
var _progress_label: Label3D
var _flame: Node3D
var _time := 0.0

func setup(id: String, c: Vector2i) -> void:
	def_id = id
	def = BuildingDefs.DEFS[id]
	cell = c
	size = def["size"]
	var mid := Vector2i(cell.x + size.x / 2, cell.y + size.y / 2)
	var gy := 0.0
	if GameState.grid != null:
		gy = GameState.grid.height_at_cell(mid)
	position = Vector3(
		(cell.x + size.x * 0.5) * GridSystem.CELL,
		gy,
		(cell.y + size.y * 0.5) * GridSystem.CELL
	)
	need_work = float(def.get("build_work", 8.0))
	complete = need_work <= 0.001
	_build_visual()
	_add_skirt()
	_build_contact_shadow()
	_add_smoke()
	_build_crops()
	if not is_road():
		_add_label()
	if not complete:
		_visual.visible = false
		_build_scaffold()

func is_road() -> bool:
	return bool(def.get("road", false))

func is_well() -> bool:
	return bool(def.get("well", false))

func is_hospital() -> bool:
	return bool(def.get("hospital", false))

func is_school() -> bool:
	return bool(def.get("school", false))

func is_pasture() -> bool:
	var herd: Variant = def.get("herd", {})
	return herd is Dictionary and not (herd as Dictionary).is_empty()

func well_radius() -> float:
	return float(def.get("radius", 12.0))

## 覆盖该世界坐标的已建成且当日开课的学堂（水平距离 ≤ radius）
static func school_covering(pos: Vector3) -> Building:
	var best: Building = null
	var best_d := INF
	for other in GameState.buildings:
		if not is_instance_valid(other) or not other.complete or not other.is_school():
			continue
		if not other.school_running:
			continue
		var d := pos.distance_to(other.global_position)
		if d <= other.well_radius() and d < best_d:
			best = other
			best_d = d
	return best

## 是否有已建成水井覆盖该建筑（水平距离 ≤ 水井 radius）
static func covered_by_well(target: Building) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var pos := target.global_position
	for other in GameState.buildings:
		if not is_instance_valid(other) or not other.complete or not other.is_well():
			continue
		if pos.distance_to(other.global_position) <= other.well_radius():
			return true
	return false

func slots() -> int:
	return 0 if not complete else int(def.get("slots", 0))

func homes() -> int:
	return 0 if not complete else int(def.get("homes", 0))

func storage_capacity() -> float:
	return 0.0 if not complete else float(def.get("capacity", 0.0))

func has_worker(c) -> bool:
	return workers.has(c)

func add_worker(c) -> void:
	if workers.has(c):
		return
	workers.append(c)
	c.workplace = self
	if c.has_method("ensure_home"):
		c.ensure_home()

func remove_worker(c) -> void:
	workers.erase(c)
	if c.workplace == self:
		c.workplace = null

func add_builder(c) -> void:
	if builders.has(c):
		return
	if is_instance_valid(c) and c.site != null and c.site != self:
		c.site.remove_builder(c)
	builders.append(c)
	if is_instance_valid(c):
		c.site = self

func remove_builder(c) -> void:
	builders.erase(c)
	if is_instance_valid(c) and c.site == self:
		c.site = null
		if c.state == Citizen.St.BUILD or c.state == Citizen.St.TO_BUILD:
			c._set_state(Citizen.St.IDLE)

func work_point() -> Vector3:
	return GameState.grid.nearest_free_point(global_position)

## 建筑 seasonal 表（春/夏/秋/冬），无表则 1.0
func season_mult() -> float:
	var seasonal: Array = def.get("seasonal", [])
	if seasonal.size() == 4:
		return float(seasonal[GameState.season()])
	return 1.0

## 占地外一圈是否存在水面（与 Main 放置校验一致）
static func footprint_near_water(cell: Vector2i, size: Vector2i) -> bool:
	if GameState.grid == null:
		return false
	for x in range(cell.x - 1, cell.x + size.x + 1):
		for y in range(cell.y - 1, cell.y + size.y + 1):
			if GameState.grid.is_water(Vector2i(x, y)):
				return true
	return false

## 场地修正：码头离水、采石场矿脉等（与 BuildingDefs seasonal 叠乘）
func site_production_mult() -> float:
	if def_id == "dock" and bool(def.get("needs_water", false)):
		return 1.0 if footprint_near_water(cell, size) else 0.0
	if def_id == "quarry" and quarry_rock_count.is_valid():
		var n: int = int(quarry_rock_count.call(cell, size))
		if n <= 0:
			return 0.0
		return clampf(float(n) / 4.0, 0.4, 1.0)
	return 1.0

## 采石累计产出后消耗一块地图石矿
func tick_quarry_extraction(amount: float) -> void:
	if def_id != "quarry" or amount <= 0.001 or not quarry_take_rock.is_valid():
		return
	_quarry_extract += amount
	while _quarry_extract >= 8.0:
		_quarry_extract -= 8.0
		if not bool(quarry_take_rock.call(cell, size)):
			break

# ---------------------------------------------------------------- 施工

func add_progress(days: float) -> void:
	if complete:
		return
	progress = minf(need_work, progress + days)
	if _progress_label != null:
		_progress_label.text = "建造 %d%%" % int(progress / maxf(need_work, 0.001) * 100.0)
	if progress >= need_work - 0.0001:
		_complete_now()

func finish_now() -> void:
	progress = need_work
	_complete_now()

func _complete_now() -> void:
	if complete:
		return
	complete = true
	if _scaffold != null:
		_scaffold.queue_free()
		_scaffold = null
	if _progress_label != null:
		_progress_label.queue_free()
		_progress_label = null
	if _visual != null:
		_visual.visible = true
	for c in builders:
		if is_instance_valid(c):
			c.site = null
	builders.clear()
	apply_season_visual(GameState.is_winter())
	var introduce_herd := is_pasture() and not herd_ready
	ensure_herd()
	GameState.log_msg("%s 建造完成" % str(def.get("name", def_id)))
	if introduce_herd:
		GameState.log_msg("引进羊群 %d 只，保留目标 %d。超出部分在春夏秋屠宰；冬天要留口粮喂羊。" % [herd_count, herd_keep])
	if is_pasture():
		refresh_herd_label()
	if GameState.grid != null:
		GameState.grid.sync_building_block(self)
	completed.emit(self)

## 仅在尚未读档恢复时按数据表引进初始羊群。
func ensure_herd() -> void:
	var herd: Dictionary = def.get("herd", {})
	if herd.is_empty() or herd_ready:
		return
	herd_count = int(herd.get("start", 6))
	herd_health = 80.0
	herd_keep = int(herd.get("keep", 4))
	herd_sick = 0
	herd_ready = true

## 旧档没有这些键时不改内存里的默认羊群。
func apply_herd_save(bd: Dictionary) -> void:
	if not is_pasture() or not bd.has("herd_count"):
		return
	var herd: Dictionary = def.get("herd", {})
	var cap := int(herd.get("cap", 14))
	herd_count = maxi(0, int(bd.get("herd_count", herd_count)))
	herd_health = clampf(float(bd.get("herd_health", herd_health)), 0.0, 100.0)
	herd_keep = clampi(int(bd.get("herd_keep", herd_keep)), 0, cap)
	herd_sick = maxi(0, int(bd.get("herd_sick", herd_sick)))
	herd_ready = true

func refresh_herd_label() -> void:
	if not is_pasture():
		return
	for child in get_children():
		if not (child is Label3D):
			continue
		var label := child as Label3D
		if label.text.begins_with("建造"):
			continue
		var mark := ""
		if herd_count <= 0:
			mark = " 绝"
		elif herd_sick > 0:
			mark = " 疫"
		label.text = "牧场 %d%s" % [herd_count, mark]
		return

## 原地升级：换成下一级的数据与外观，重新变回工地
func begin_upgrade() -> void:
	if not complete or burning:
		return
	var next := str(def.get("upgrades_to", ""))
	if next == "" or not BuildingDefs.DEFS.has(next):
		return
	def_id = next
	def = BuildingDefs.DEFS[next]
	need_work = float(def.get("build_work", 8.0))
	progress = 0.0
	complete = false

	for c in workers.duplicate():
		if is_instance_valid(c):
			c.workplace = null
	workers.clear()

	for child in get_children():
		child.queue_free()
	_visual = null
	_scaffold = null
	_progress_label = null

	_build_visual()
	_add_skirt()
	_build_contact_shadow()
	_add_smoke()
	_build_crops()
	_add_label()
	_visual.visible = false
	_build_scaffold()
	if GameState.grid != null:
		GameState.grid.sync_building_block(self)

## 农田在冬天换成雪色，避免雪地里还长着绿油油的麦子
## 重新套用材质（昼夜切换时用）
func refresh_materials() -> void:
	if _visual == null:
		return
	ModelPaint.apply(_visual, 0.9, 0)

func apply_season_visual(winter: bool) -> void:
	if _visual == null:
		return
	var is_farm := def_id == "farm"
	for child in _visual.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i)
			var key := "" if src == null else str(src.resource_name)
			if key.begins_with("paint_"):
				key = key.substr(6)
			if is_farm and (key == "Crop" or key == "Wheat"):
				mi.set_surface_override_material(
					i, ModelPaint.winter_mat(key) if winter else ModelPaint.mat_for(key, 0.92)
				)
			elif key == "RoofShingle" or key == "RoofDark" or key == "Thatch":
				mi.set_surface_override_material(
					i, ModelPaint.snow_roof_mat(key) if winter else ModelPaint.mat_for(key, 0.9)
				)
	_update_crops()

# ---------------------------------------------------------------- 火灾

func ignite() -> void:
	if burning or not complete or is_road():
		return
	burning = true
	burn_timer = 0.0
	_flame = Node3D.new()
	add_child(_flame)

	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 1.15
	cm.height = 2.8
	cm.radial_segments = 7
	mi.mesh = cm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.45, 0.10)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.45, 0.10)
	m.emission_energy_multiplier = 2.4
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	# 火苗要露在屋顶上方，否则会被建筑模型挡住
	var fy := float(def.get("height", 2.4)) * 1.55 + 0.5
	mi.position.y = fy
	_flame.add_child(mi)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 4.0
	light.omni_range = 14.0
	light.position.y = fy
	_flame.add_child(light)

	GameState.log_msg("%s 起火了！" % str(def.get("name", def_id)))

func extinguish() -> void:
	burning = false
	burn_timer = 0.0
	if _flame != null:
		_flame.queue_free()
		_flame = null

func _process(delta: float) -> void:
	_time += delta
	if smoke != null:
		smoke.emitting = complete
	if blades != null:
		# 只有建好并且有工人时才转
		var spinning := complete and not workers.is_empty()
		if spinning:
			var spd := 2.0 * season_mult()
			blades.rotation.z += delta * spd
	if _flame == null:
		return
	var s := 1.0 + sin(_time * 11.0) * 0.12
	_flame.scale = Vector3(s, 1.0 + sin(_time * 7.0) * 0.18, s)

# ---------------------------------------------------------------- 外观

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.srgb_to_linear()
	m.roughness = 0.9
	m.metallic = 0.0
	return m

func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	var yaw := float(def.get("yaw", 0.0))
	if yaw != 0.0:
		_visual.rotation.y = deg_to_rad(yaw)

	if is_road():
		# 道路不生成网格，直接由地面着色器按遮罩绘制土路
		return

	var model_path: String = MODELS.get(def_id, "")
	if model_path != "" and ResourceLoader.exists(model_path):
		var ps := load(model_path) as PackedScene
		if ps != null:
			var node: Node3D = ps.instantiate()
			_visual.add_child(node)
			ModelPaint.apply(node, 0.9, randi() % 4)
			blades = node.find_child("windmill_blades", true, false) as Node3D
			return

	_build_primitive_visual()

func _build_scaffold() -> void:
	_scaffold = Node3D.new()
	add_child(_scaffold)

	var w := size.x * GridSystem.CELL
	var d := size.y * GridSystem.CELL
	var wood := _mat(Color(0.58, 0.45, 0.28))
	var h := 2.3

	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var post := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.13, h, 0.13)
			post.mesh = bm
			post.position = Vector3(sx * (w * 0.5 - 0.28), h * 0.5, sy * (d * 0.5 - 0.28))
			post.material_override = wood
			_scaffold.add_child(post)

	for z in [0.8, 1.7]:
		for sy in [-1, 1]:
			var rail := MeshInstance3D.new()
			var rm := BoxMesh.new()
			rm.size = Vector3(w - 0.4, 0.10, 0.08)
			rail.mesh = rm
			rail.position = Vector3(0, z, sy * (d * 0.5 - 0.28))
			rail.material_override = wood
			_scaffold.add_child(rail)
		for sx in [-1, 1]:
			var rail2 := MeshInstance3D.new()
			var rm2 := BoxMesh.new()
			rm2.size = Vector3(0.08, 0.10, d - 0.4)
			rail2.mesh = rm2
			rail2.position = Vector3(sx * (w * 0.5 - 0.28), z, 0)
			rail2.material_override = wood
			_scaffold.add_child(rail2)

	_progress_label = Label3D.new()
	_progress_label.text = "建造 0%"
	_progress_label.font = GameState.ui_font
	_progress_label.font_size = 44
	_progress_label.pixel_size = 0.014
	_progress_label.outline_size = 14
	_progress_label.outline_modulate = Color(0, 0, 0, 0.85)
	_progress_label.modulate = Color(1.0, 0.88, 0.55)
	_progress_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_progress_label.position = Vector3(0, 2.7, 0)
	_scaffold.add_child(_progress_label)

## 石基裙边：建筑的 base 在占地中心高度上，坡地低侧会露缝，用一圈下沉的基座盖住
func _add_skirt() -> void:
	if is_road():
		return
	var w := size.x * GridSystem.CELL
	var d := size.y * GridSystem.CELL
	var skirt := MeshInstance3D.new()
	var bm := BoxMesh.new()
	# 露出地面 0.15 米的石砌台基，比占地略大一圈；向下延伸到坡地低侧以下
	bm.size = Vector3(w + 0.30, 1.10, d + 0.30)
	skirt.mesh = bm
	skirt.position.y = -0.40
	var mat := ModelPaint.mat_for("StoneDark", 0.95, 0)
	if mat == null:
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.32, 0.29, 0.24).srgb_to_linear()
		sm.roughness = 0.95
		mat = sm
	skirt.material_override = mat
	add_child(skirt)

## 建筑底部的接触阴影（软边黑片），把建筑压在地面上
func _build_contact_shadow() -> void:
	var cell_size := float(GridSystem.CELL)
	var w := float(size.x) * cell_size
	var d := float(size.y) * cell_size
	var quad := PlaneMesh.new()
	quad.size = Vector2(w * 1.36, d * 1.36)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.position = Vector3(0.0, 0.03, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/contact_shadow.gdshader")
	if mat.shader != null:
		mat.set_shader_parameter("strength", 0.34)
	mi.material_override = mat
	add_child(mi)

## 每类建筑的烟囱顶位置（Blender 坐标 x,y,z → Godot x,z,-y）
const CHIMNEY := {
	"house": Vector3(1.10, 3.80, -0.95),
	"house_stone": Vector3(1.05, 4.38, -1.05),
	"house_row": Vector3(1.20, 4.18, -0.95),
	"house_manor": Vector3(1.25, 5.20, -1.00),
}

## 烟囱炊烟：只有建好的住宅/作坊才有
func _add_smoke() -> void:
	if not bool(def.get("smoke", false)):
		return
	var p := CPUParticles3D.new()
	p.amount = 14
	p.lifetime = 6.5
	p.preprocess = 3.0
	p.direction = Vector3.UP
	p.spread = 6.0
	p.initial_velocity_min = 0.35
	p.initial_velocity_max = 0.85
	p.gravity = Vector3(0.12, 0.08, 0.0)
	p.scale_amount_min = 0.30
	p.scale_amount_max = 0.80
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.14
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.0))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.18, Color(1, 1, 1, 0.30))
	g.add_point(0.60, Color(1, 1, 1, 0.15))
	p.color_ramp = g
	var quad := QuadMesh.new()
	quad.size = Vector2(1.35, 1.35)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/smoke.gdshader")
	quad.material = mat
	p.mesh = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var h := float(def.get("height", 2.4))
	p.position = CHIMNEY.get(def_id, Vector3(0.95, h * 0.92, -0.95))
	add_child(p)
	smoke = p

## 农田的作物：按季节改变高度与颜色
func _build_crops() -> void:
	if def_id != "farm":
		return
	var w := size.x * GridSystem.CELL
	var d := size.y * GridSystem.CELL
	var n := 240
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.16
	cone.height = 1.0
	cone.radial_segments = 4
	cone.rings = 1

	crop_mm = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cone
	mm.instance_count = n
	crop_mm.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.55, 0.22)
	mat.roughness = 0.95
	crop_mm.material_override = mat
	add_child(crop_mm)

	for i in n:
		_crop_pos.append(Vector2(
			randf_range(-w * 0.5 + 0.8, w * 0.5 - 0.8),
			randf_range(-d * 0.5 + 0.8, d * 0.5 - 0.8)
		))
	_update_crops()

func _update_crops() -> void:
	if crop_mm == null:
		return
	var season := GameState.season()
	var height: float = [0.95, 1.35, 1.85, 0.0][season]
	var col: Color = [
		Color(0.34, 0.58, 0.20),
		Color(0.30, 0.55, 0.16),
		Color(0.74, 0.62, 0.22),
		Color(0.52, 0.50, 0.40),
	][season]
	if crop_mm.material_override is StandardMaterial3D:
		(crop_mm.material_override as StandardMaterial3D).albedo_color = col.srgb_to_linear()
	var zero := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in _crop_pos.size():
		if height <= 0.01:
			crop_mm.multimesh.set_instance_transform(i, zero)
			continue
		var s := height * randf_range(0.82, 1.18)
		var p := _crop_pos[i]
		var basis := Basis().scaled(Vector3(randf_range(0.85, 1.15), s, randf_range(0.85, 1.15)))
		crop_mm.multimesh.set_instance_transform(i, Transform3D(basis, Vector3(p.x, s * 0.5, p.y)))

func _add_label() -> void:
	var h := float(def.get("height", 2.4))
	var ly := float(def.get("label_y", h * 1.55 + 0.8))
	var label := Label3D.new()
	label.text = str(def.get("name", def_id))
	label.font = GameState.ui_font
	label.font_size = 64
	label.pixel_size = 0.013
	label.outline_size = 18
	label.outline_modulate = Color(0, 0, 0, 0.85)
	label.modulate = Color(1.0, 0.97, 0.9, 0.95)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, ly, 0)
	add_child(label)

func _build_primitive_visual() -> void:
	var w := size.x * GridSystem.CELL
	var d := size.y * GridSystem.CELL
	var h := float(def.get("height", 2.4))
	var body_color: Color = def.get("color", Color(0.7, 0.6, 0.45))
	var roof_color: Color = def.get("roof", Color(0.35, 0.22, 0.16))

	if bool(def.get("flat", false)):
		_build_field(w, d)
		return

	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w * 0.86, h, d * 0.86)
	body.mesh = bm
	body.position.y = h * 0.5
	body.material_override = _mat(body_color)
	_visual.add_child(body)

	var roof := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(w * 0.98, h * 0.55, d * 0.98)
	roof.mesh = pm
	roof.position.y = h + h * 0.275
	roof.material_override = _mat(roof_color)
	_visual.add_child(roof)

	var door := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(0.7, 1.1, 0.12)
	door.mesh = dm
	door.position = Vector3(0, 0.55, d * 0.435)
	door.material_override = _mat(Color(0.22, 0.16, 0.11))
	_visual.add_child(door)

func _build_field(w: float, d: float) -> void:
	var soil := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(w * 0.94, 0.22, d * 0.94)
	soil.mesh = sm
	soil.position.y = 0.11
	soil.material_override = _mat(Color(0.34, 0.25, 0.17))
	_visual.add_child(soil)

	var rows := 6
	for i in rows:
		var row := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(w * 0.86, 0.14, 0.34)
		row.mesh = rm
		row.position = Vector3(0, 0.28, -d * 0.40 + i * (d * 0.80 / float(rows - 1)))
		row.material_override = _mat(Color(0.46, 0.56, 0.24))
		_visual.add_child(row)

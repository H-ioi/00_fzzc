class_name Citizen
extends Node3D
## 一个居民：会走路、会饿、会干活、会把货物背回仓库。
## 没有“人口数字”，每个人都是真实个体（和原作一致）。

signal died(c)

enum St { IDLE, TO_WORK, WORK, TO_STORE, TO_HOME, HOME, WANDER, TO_BUILD, BUILD, TO_PANTRY }

const SPEED := 3.4
const CARRY_MAX := 12.0
const HUNGER_PER_DAY := 12.0
const EAT_AMOUNT := 60.0

var home: Building = null
var workplace: Building = null
var site: Building = null
var sick := 0
## 存活天数（每日 +1）；未满 16 岁为儿童，生产效率折减。
var age := 0
var hunger := 100.0
var warmth := 100.0
var health := 100.0
var carry := 0.0
var carry_res := "wood"

var state: int = St.IDLE
var path: Array[Vector3] = []
var path_i := 0
var arrived := true
var dead := false
var state_timer := 0.0

var _body: MeshInstance3D
var _head: MeshInstance3D
var _model: Node3D
var _anim: AnimationPlayer
var _log_mesh: MeshInstance3D
var _sick_label: Label3D
var _bob := 0.0
var _eat_timer := 0.0
var _work_pos := Vector3.ZERO

const CHAR_MODEL := "res://assets/models/character.glb"

func setup() -> void:
	_build_mesh()
	ensure_home()
	_set_state(St.IDLE)

func _process(delta: float) -> void:
	if dead or GameState.paused:
		return
	var dt := delta * GameState.speed
	if dt <= 0.0:
		return
	_tick_needs(dt)
	_move(dt)
	_tick_state(dt)
	_apply_color()
	if _log_mesh != null:
		_log_mesh.visible = carry > 0.5

# ---------------------------------------------------------------- 需求

func _tick_needs(dt: float) -> void:
	var days := dt / GameState.DAY_SECONDS
	hunger = maxf(0.0, hunger - HUNGER_PER_DAY * days)
	if not GameState.is_winter():
		warmth = minf(100.0, warmth + 10.0 * days)
	if hunger <= 0.0:
		health -= 18.0 * days
	if warmth <= 0.0:
		health -= 18.0 * days
	if hunger > 40.0 and warmth > 40.0:
		health = minf(100.0, health + 2.0 * days)
	# 有教堂时，全村健康缓慢回升
	if GameState.has_church():
		health = minf(100.0, health + 1.5 * days)
	if health <= 0.0 and not dead:
		_die()

func daily_update(fire_ratio: float, winter: bool) -> void:
	if dead:
		return
	if sick > 0:
		var cared := GameState.active_hospital() != null
		sick -= 2 if cared else 1
		health -= 4.0 if cared else 14.0
		if sick <= 0:
			sick = 0
			_clear_sick()
			GameState.log_msg("一名居民康复了。")
	if winter:
		var mult := GameState.cloth_factor()
		var loss := (6.0 + 40.0 * (1.0 - fire_ratio)) * mult
		if GameState.cold_snap_active():
			loss *= 1.12
		warmth = maxf(0.0, warmth - loss)
	else:
		warmth = minf(100.0, warmth + 25.0)
	if warmth < 10.0:
		health -= 8.0
	if health <= 0.0:
		_die()

func infect(days: int) -> void:
	if dead:
		return
	sick = maxi(sick, days)
	if _sick_label != null:
		return
	_sick_label = Label3D.new()
	_sick_label.text = "病"
	_sick_label.font = GameState.ui_font
	_sick_label.font_size = 48
	_sick_label.pixel_size = 0.009
	_sick_label.outline_size = 12
	_sick_label.outline_modulate = Color(0, 0, 0, 0.85)
	_sick_label.modulate = Color(1.0, 0.45, 0.35)
	_sick_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sick_label.position = Vector3(0, 2.15, 0)
	add_child(_sick_label)

func _clear_sick() -> void:
	if _sick_label != null:
		_sick_label.queue_free()
		_sick_label = null

# ---------------------------------------------------------------- 移动

func _move(dt: float) -> void:
	if path_i >= path.size():
		arrived = true
		_play("Idle")
		return
	arrived = false
	var target: Vector3 = path[path_i]
	var to := target - global_position
	to.y = 0.0
	var dist := to.length()
	var on_road := GameState.grid.is_road(GameState.grid.world_to_cell(global_position))
	var step := SPEED * (1.5 if on_road else 1.0) * dt
	if dist <= step or dist < 0.06:
		global_position = Vector3(target.x, target.y, target.z)
		path_i += 1
	else:
		var dir := to / dist
		global_position += dir * step
		global_position.y = GameState.grid.height_at_world(global_position.x, global_position.z)
		# 平滑转身，避免瞬间朝向跳变
		var target_yaw := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(dt * 9.0, 0.0, 1.0))
		_play("Walk")
	_bob += dt * 9.0
	if _body != null:
		_body.position.y = 0.62 + absf(sin(_bob)) * 0.05

func _play(anim_name: String) -> void:
	if _anim == null:
		return
	var target := anim_name
	if target == "Walk" and carry > 0.5 and _anim.has_animation("Carry"):
		target = "Carry"
	if _anim.current_animation != target:
		_anim.play(target, 0.12)
	var base := clampf(GameState.speed, 0.6, 12.0)
	_anim.speed_scale = base * (1.7 if target != "Idle" else 1.0)

func _set_path(target: Vector3) -> void:
	path = GameState.grid.find_path(global_position, target)
	if path.is_empty():
		path = [Vector3(target.x, 0.0, target.z)]
	else:
		path = _smooth_path(path)
	path_i = 0

## 用 Catmull-Rom 把折线路径插值成平滑曲线，避免直角硬拐
func _smooth_path(pts: Array[Vector3]) -> Array[Vector3]:
	if pts.size() < 3:
		return pts
	var out: Array[Vector3] = [pts[0]]
	for i in pts.size() - 1:
		var p0: Vector3 = pts[maxi(i - 1, 0)]
		var p1: Vector3 = pts[i]
		var p2: Vector3 = pts[i + 1]
		var p3: Vector3 = pts[mini(i + 2, pts.size() - 1)]
		for s in range(1, 4):
			var t := float(s) / 4.0
			var t2 := t * t
			var t3 := t2 * t
			var p := 0.5 * (
				2.0 * p1
				+ (p2 - p0) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
			)
			p.y = GameState.grid.height_at_world(p.x, p.z)
			out.append(p)
	out.append(pts[pts.size() - 1])
	return out

func _set_state(s: int) -> void:
	state = s
	state_timer = 0.0

## 只比较水平距离：地形有高度后，三维距离会让居民永远"走不到"工作点
func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

# ---------------------------------------------------------------- 状态机

func _tick_state(dt: float) -> void:
	if dead:
		return
	state_timer += dt

	if workplace != null and not is_instance_valid(workplace):
		workplace = null
	if home != null and not is_instance_valid(home):
		home = null
	if site != null and (not is_instance_valid(site) or site.complete):
		site = null
		if state == St.BUILD or state == St.TO_BUILD:
			_set_state(St.IDLE)

	if sick > 0 and state in [St.TO_WORK, St.WORK, St.TO_BUILD, St.BUILD]:
		_go_home()
		return

	match state:
		St.IDLE:
			if home == null:
				ensure_home()
			if sick > 0:
				if hunger < 55.0:
					_go_meal()
				else:
					_go_home()
				return
			if hunger < 55.0:
				_go_meal()
			elif site != null:
				_go_build()
			elif workplace != null:
				_go_work()
			elif state_timer > 3.0:
				_wander()
		St.TO_WORK:
			if arrived:
				_set_state(St.WORK)
		St.WORK:
			if workplace == null:
				_set_state(St.IDLE)
				return
			if hunger < 55.0:
				_go_meal()
				return
			if carry >= _carry_threshold():
				_go_store()
				return
			if GameState.storage_urgent() and carry > 0.5 and (carry_res == "food" or GameState.room_left() < 40.0):
				_go_store()
				return
			if _flat_dist(global_position, _work_pos) > 2.0:
				_go_work()
				return
			_produce(dt)
		St.TO_STORE:
			if arrived:
				_deposit()
		St.TO_HOME:
			if arrived:
				_set_state(St.HOME)
		St.HOME:
			_rest(dt)
		St.WANDER:
			if arrived:
				_set_state(St.IDLE)
		St.TO_BUILD:
			if arrived:
				_set_state(St.BUILD)
		St.TO_PANTRY:
			if arrived:
				_eat_from_stock()
				_resume_after_meal()
		St.BUILD:
			if site == null or not is_instance_valid(site) or site.complete:
				site = null
				_set_state(St.IDLE)
				return
			if hunger < 55.0:
				_go_meal()
				return
			if _flat_dist(global_position, _work_pos) > 2.0:
				_go_build()
				return
			site.add_progress(dt / GameState.DAY_SECONDS * work_efficiency())

# ---------------------------------------------------------------- 行为

func _go_work() -> void:
	if sick > 0:
		_go_home()
		return
	if workplace == null or not is_instance_valid(workplace):
		_set_state(St.IDLE)
		return
	_work_pos = workplace.work_point() + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
	_set_path(_work_pos)
	_set_state(St.TO_WORK)

func _go_build() -> void:
	if sick > 0:
		_go_home()
		return
	if site == null or not is_instance_valid(site) or site.complete:
		site = null
		_set_state(St.IDLE)
		return
	_work_pos = site.work_point() + Vector3(randf_range(-0.6, 0.6), 0.0, randf_range(-0.6, 0.6))
	_set_path(_work_pos)
	_set_state(St.TO_BUILD)

func _go_store() -> void:
	var target := global_position
	var s := GameState.find_storage()
	if s != null:
		target = s.work_point()
	elif home != null and is_instance_valid(home):
		target = home.work_point()
	_set_path(target)
	_set_state(St.TO_STORE)

func _go_home() -> void:
	if home == null or not is_instance_valid(home):
		_set_state(St.IDLE)
		return
	_set_path(home.work_point())
	_set_state(St.TO_HOME)

func _go_meal() -> void:
	if home != null and is_instance_valid(home):
		_go_home()
		return
	var store := GameState.find_storage()
	if store != null:
		_set_path(store.work_point())
		_set_state(St.TO_PANTRY)
	else:
		_set_state(St.IDLE)

func _wander() -> void:
	var base := global_position
	if home != null and is_instance_valid(home):
		base = home.global_position
	var ang := randf() * TAU
	var r := randf_range(1.2, 3.5) if sick > 0 else randf_range(2.0, 7.0)
	var target := base + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	_set_path(GameState.grid.nearest_free_point(target))
	_set_state(St.WANDER)

func _produce(dt: float) -> void:
	var p: Dictionary = workplace.def.get("produce", {})
	if p.is_empty():
		return
	var days := dt / GameState.DAY_SECONDS
	var mult := workplace.season_mult() * workplace.site_production_mult()
	mult *= work_efficiency() * GameState.season_work_mult()
	if mult <= 0.001:
		return
	var consume: Dictionary = p.get("consume", {})
	for k in consume:
		var need := float(consume[k]) * days
		if float(GameState.stock.get(k, 0.0)) < need:
			return
	for k in consume:
		GameState.take(k, float(consume[k]) * days)
	carry_res = str(p.get("res", "wood"))
	var amt := float(p.get("rate", 1.0)) * mult * days
	if amt <= 0.001:
		return
	carry += amt
	workplace.produced += amt
	workplace.tick_quarry_extraction(amt)
	# 副产物直接入库（例如猎人产皮革）；仓满时只入库剩余空间
	var bp: Dictionary = workplace.def.get("byproduct", {})
	if not bp.is_empty():
		var bp_amt := float(bp.get("rate", 0.0)) * mult * days
		if bp_amt > 0.001 and GameState.room_left() > 0.001:
			GameState.add(str(bp.get("res", "leather")), bp_amt)
	if _body != null:
		_body.position.y = 0.62 + absf(sin(_bob)) * 0.05

func _carry_threshold() -> float:
	if carry_res == "food":
		var pop := maxi(1, GameState.citizens.size())
		var food := float(GameState.stock.get("food", 0.0))
		if food < pop * 2.0:
			return 4.0
		if food < pop * 3.0:
			return 6.0
	if carry_res == "firewood" and (GameState.is_winter() or GameState.season() == 2):
		var pop2 := maxi(1, GameState.citizens.size())
		if float(GameState.stock.get("firewood", 0.0)) < pop2 * 2.0:
			return 6.0
	return CARRY_MAX

func _deposit() -> void:
	if carry > 0.0:
		var added := GameState.add(carry_res, carry)
		if added < carry - 0.01:
			GameState.log_msg("仓库已满，%.0f %s 未能入库。" % [
				carry - added, GameState.RES_ZH.get(carry_res, carry_res)])
		if carry_res == "food":
			GameState.stat_food_in += added
		carry = maxf(0.0, carry - added)
	if sick > 0:
		_go_home()
	elif workplace != null and is_instance_valid(workplace):
		_go_work()
	else:
		_set_state(St.IDLE)

func _rest(dt: float) -> void:
	if hunger < 85.0:
		_eat_timer += dt
		if _eat_timer >= 1.5:
			_eat_timer = 0.0
			_eat_from_stock()
	else:
		_eat_timer = 0.0

	if sick > 0:
		if hunger > 70.0 and state_timer > 10.0 and randf() < 0.06:
			_wander()
		return

	if hunger > 70.0 and state_timer > 2.0:
		_resume_after_meal()

func _eat_from_stock() -> bool:
	if float(GameState.stock.get("food", 0.0)) < 1.0:
		return false
	if GameState.take("food", 1.0):
		hunger = minf(100.0, hunger + EAT_AMOUNT)
		GameState.stat_meals += 1
		return true
	return false

func is_child() -> bool:
	return age < GameState.adult_age_days()

func work_efficiency() -> float:
	var m := GameState.tool_factor() * GameState.mood_factor()
	if sick > 0:
		m *= 0.55
	if is_child():
		m *= GameState.child_work_mult(self)
	return m

func ensure_home() -> void:
	if home != null and is_instance_valid(home):
		var cap := int(home.def.get("homes", 0))
		if cap > 0:
			var n := 0
			for other in GameState.citizens:
				if other != self and is_instance_valid(other) and not other.dead and other.home == home:
					n += 1
			if n < cap:
				return
		home = null
	home = _find_home()

func _resume_after_meal() -> void:
	if sick > 0:
		return
	if site != null and is_instance_valid(site) and not site.complete:
		_go_build()
	elif workplace != null and is_instance_valid(workplace):
		_go_work()
	else:
		_set_state(St.IDLE)

# ---------------------------------------------------------------- 杂项

func _find_home() -> Building:
	for b in GameState.buildings:
		if not is_instance_valid(b) or not b.complete:
			continue
		var h := int(b.def.get("homes", 0))
		if h <= 0:
			continue
		var n := 0
		for c in GameState.citizens:
			if c != self and is_instance_valid(c) and not c.dead and c.home == b:
				n += 1
		if n < h:
			return b
	return null

func _build_mesh() -> void:
	if ResourceLoader.exists(CHAR_MODEL):
		var ps := load(CHAR_MODEL) as PackedScene
		if ps != null:
			_model = ps.instantiate()
			_model.rotation.y = PI   # 模型正面朝 +Z，翻过来对齐 -Z 前进方向
			add_child(_model)
			ModelPaint.apply(_model, 0.88)
			# 每个人衣服颜色、身高略有差异
			var cloth := randi() % ModelPaint.TUNIC_PALETTE.size()
			var height_scale := randf_range(0.93, 1.07)
			_model.scale = Vector3(height_scale, height_scale, height_scale)
			for m in _model.find_children("*", "MeshInstance3D", true, false):
				var mi := m as MeshInstance3D
				if mi.mesh == null:
					continue
				for si in mi.mesh.get_surface_count():
					var cur := mi.get_surface_override_material(si)
					if cur != null and str(cur.resource_name) == "paint_Tunic":
						mi.set_surface_override_material(si, ModelPaint.tunic_mat(cloth))
			var aps := _model.find_children("*", "AnimationPlayer", true, false)
			if not aps.is_empty():
				_anim = aps[0]
				_play("Idle")
			for m in _model.find_children("*", "MeshInstance3D", true, false):
				if str(m.name).to_lower().contains("carry"):
					_log_mesh = m
					_log_mesh.visible = false
			return

	# 兜底：没有模型时用胶囊体
	_body = MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.26
	cm.height = 1.15
	_body.mesh = cm
	_body.position.y = 0.62
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.45, 0.60)
	mat.roughness = 0.85
	_body.material_override = mat
	add_child(_body)

	_head = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.20
	sm.height = 0.40
	_head.mesh = sm
	_head.position.y = 1.36
	var hm := StandardMaterial3D.new()
	hm.albedo_color = Color(0.87, 0.71, 0.57)
	hm.roughness = 0.8
	_head.material_override = hm
	add_child(_head)

func _apply_color() -> void:
	if _body == null:
		return
	var mat := _body.material_override as StandardMaterial3D
	if mat == null:
		return
	var c := Color(0.55, 0.50, 0.44)
	if workplace != null:
		c = Color(0.36, 0.45, 0.60)
	if hunger < 25.0:
		c = Color(0.78, 0.36, 0.26)
	mat.albedo_color = c

func role_text() -> String:
	if workplace == null:
		return "闲置"
	return str(workplace.def.get("name", "工人"))

func _die() -> void:
	if dead:
		return
	dead = true
	died.emit(self)

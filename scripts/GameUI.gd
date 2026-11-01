class_name GameUI
extends CanvasLayer
## 全部 UI 用代码构建，避免手写 .tscn 出错。

var main: Node = null

var time_label: Label
var pop_label: Label
var cap_label: Label
var mood_label: Label
var res_labels: Dictionary = {}
var speed_buttons: Array[Button] = []
var build_buttons: Dictionary = {}
var build_panel: PanelContainer
var sel_panel: PanelContainer
var sel_title: Label
var sel_body: Label
var sel_upgrade: Button
var sel_demolish: Button
var log_box: VBoxContainer
var minimap_rect: TextureRect
var minimap_vp: SubViewport
var minimap_cam: Camera3D
var _acc := 0.0
var _current: Building = null

const RES_ORDER: Array[String] = ["wood", "stone", "food", "firewood", "tools", "clothes", "leather"]
const RES_NAME := {
	"wood": "木材", "stone": "石头", "food": "食物", "firewood": "柴火",
	"tools": "工具", "clothes": "衣物", "leather": "皮革",
}
const RES_COLOR := {
	"wood": Color(0.74, 0.55, 0.33),
	"stone": Color(0.74, 0.74, 0.76),
	"food": Color(0.62, 0.82, 0.40),
	"firewood": Color(0.92, 0.62, 0.30),
	"tools": Color(0.70, 0.72, 0.78),
	"clothes": Color(0.84, 0.62, 0.70),
	"leather": Color(0.66, 0.48, 0.32),
}
const SPEEDS := [[0.0, "暂停"], [1.0, "1x"], [2.0, "2x"], [4.0, "4x"], [8.0, "8x"]]

func _ready() -> void:
	_build()

func _build() -> void:
	var theme := _ui_theme()

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme
	add_child(root)

	_build_top_bar(root)
	_build_build_panel(root)
	_build_selected(root)
	_build_log(root)
	_build_hint(root)
	_build_minimap(root)
	_build_quick_bar(root)
	_load_icons()

## 左下角快捷栏：建造 / 道路 / 拆除 / 保存 / 读取
func _build_quick_bar(root: Control) -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_left = 16
	bar.offset_top = -104
	bar.offset_right = 16 + 5 * 92
	bar.offset_bottom = -16
	bar.add_theme_constant_override("separation", 8)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)

	var spec := [
		["建造", "toggle_build"],
		["道路", "road"],
		["拆除", "demolish"],
		["保存", "save"],
		["读取", "load"],
	]
	for s in spec:
		var b := Button.new()
		b.text = str(s[0])
		b.custom_minimum_size = Vector2(84, 84)
		b.add_theme_font_size_override("font_size", 17)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		var act := str(s[1])
		b.pressed.connect(func() -> void: _quick_action(act))
		bar.add_child(b)

func _quick_action(act: String) -> void:
	var main := get_parent()
	match act:
		"toggle_build":
			if build_panel != null:
				build_panel.visible = not build_panel.visible
		"road":
			if main != null and main.has_method("start_build"):
				main.start_build("road")
		"demolish":
			if main != null and main.has_method("quick_demolish"):
				main.quick_demolish()
		"save":
			if main != null and main.has_method("save_game"):
				main.save_game()
				GameState.log_msg("已保存。")
		"load":
			if main != null and main.has_method("load_game"):
				main.load_game()

# ---------------------------------------------------------------- 构建

## 羊皮纸 + 木牌的 UI 主题，和 3D 场景的手绘质感统一
func _ui_theme() -> Theme:
	var t := Theme.new()
	t.default_font = GameState.ui_font
	t.default_font_size = 15

	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.87, 0.81, 0.67, 0.97)
	panel.border_color = Color(0.36, 0.26, 0.17)
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(7)
	panel.content_margin_left = 12
	panel.content_margin_right = 12
	panel.content_margin_top = 10
	panel.content_margin_bottom = 10
	panel.shadow_color = Color(0, 0, 0, 0.32)
	panel.shadow_size = 6
	panel.shadow_offset = Vector2(2, 3)
	t.set_stylebox("panel", "PanelContainer", panel)

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.47, 0.35, 0.23)
	normal.border_color = Color(0.27, 0.19, 0.12)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	normal.content_margin_left = 8
	normal.content_margin_right = 8
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	normal.shadow_color = Color(0, 0, 0, 0.22)
	normal.shadow_size = 2
	normal.shadow_offset = Vector2(0, 1)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.58, 0.44, 0.29)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.36, 0.27, 0.17)

	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", normal)
	t.set_color("font_color", "Button", Color(0.97, 0.93, 0.84))
	t.set_color("font_pressed_color", "Button", Color(0.92, 0.86, 0.72))
	t.set_color("font_hover_color", "Button", Color(1, 1, 1))
	t.set_color("font_color", "Label", Color(0.24, 0.17, 0.11))
	return t

func _sb(bg: Color, border: Color = Color(0, 0, 0, 0), radius: int = 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

func _build_top_bar(root: Control) -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 46
	bar.add_theme_stylebox_override("panel", _sb(Color(0.17, 0.14, 0.11, 0.96), Color(0.38, 0.28, 0.18), 0))
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(bar)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	bar.add_child(hb)

	time_label = Label.new()
	time_label.custom_minimum_size.x = 210
	time_label.add_theme_color_override("font_color", Color(0.94, 0.90, 0.78))
	hb.add_child(time_label)

	pop_label = Label.new()
	pop_label.custom_minimum_size.x = 92
	pop_label.add_theme_color_override("font_color", Color(0.84, 0.86, 0.90))
	hb.add_child(pop_label)

	for r in RES_ORDER:
		var l := Label.new()
		l.add_theme_color_override("font_color", RES_COLOR[r])
		l.custom_minimum_size.x = 88
		res_labels[r] = l
		hb.add_child(l)

	# 幸福度
	mood_label = Label.new()
	mood_label.add_theme_color_override("font_color", Color(0.92, 0.78, 0.42))
	mood_label.custom_minimum_size.x = 96
	mood_label.text = "幸福 62"
	hb.add_child(mood_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(spacer)

	cap_label = Label.new()
	cap_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
	hb.add_child(cap_label)

	for item in SPEEDS:
		var b := Button.new()
		b.text = str(item[1])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_speed.bind(float(item[0])))
		hb.add_child(b)
		speed_buttons.append(b)

func _build_build_panel(root: Control) -> void:
	var panel := PanelContainer.new()
	build_panel = panel
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 12
	panel.offset_top = 58
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "建 造"
	title.add_theme_color_override("font_color", Color(0.30, 0.20, 0.12))
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	# 建筑种类多了以后需要滚动，否则会压到底部的日志区
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 596)
	vb.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	scroll.add_child(list)

	for id in BuildingDefs.DEFS:
		var d: Dictionary = BuildingDefs.DEFS[id]
		if bool(d.get("upgrade_only", false)):
			continue
		var b := Button.new()
		b.text = "%s　%s" % [str(d["name"]), BuildingDefs.cost_text(id)]
		b.tooltip_text = "%s\n造价：%s" % [str(d.get("desc", "")), BuildingDefs.cost_text(id)]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.x = 200
		b.pressed.connect(_on_build_pressed.bind(id))
		list.add_child(b)
		build_buttons[id] = b

	var cancel := Button.new()
	cancel.text = "取消建造 (Esc)"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.pressed.connect(_on_cancel_build)
	vb.add_child(cancel)

func _build_selected(root: Control) -> void:
	sel_panel = PanelContainer.new()
	sel_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	sel_panel.offset_left = -262
	sel_panel.offset_right = -12
	sel_panel.offset_top = 58
	sel_panel.offset_bottom = 390
	sel_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	sel_panel.visible = false
	root.add_child(sel_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	sel_panel.add_child(vb)

	sel_title = Label.new()
	sel_title.add_theme_color_override("font_color", Color(0.30, 0.20, 0.12))
	sel_title.add_theme_font_size_override("font_size", 18)
	vb.add_child(sel_title)

	sel_body = Label.new()
	sel_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sel_body.custom_minimum_size.x = 230
	sel_body.add_theme_color_override("font_color", Color(0.28, 0.20, 0.13))
	vb.add_child(sel_body)

	sel_upgrade = Button.new()
	sel_upgrade.focus_mode = Control.FOCUS_NONE
	sel_upgrade.visible = false
	sel_upgrade.pressed.connect(_on_upgrade)
	vb.add_child(sel_upgrade)

	sel_demolish = Button.new()
	sel_demolish.text = "拆除（返还 50%）"
	sel_demolish.focus_mode = Control.FOCUS_NONE
	sel_demolish.pressed.connect(_on_demolish)
	vb.add_child(sel_demolish)

func _build_log(root: Control) -> void:
	log_box = VBoxContainer.new()
	log_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	log_box.offset_left = 316
	log_box.offset_right = 700
	log_box.offset_top = -246
	log_box.offset_bottom = -112
	log_box.alignment = BoxContainer.ALIGNMENT_END
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(log_box)

func _build_minimap(root: Control) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.offset_left = -212
	panel.offset_right = -14
	panel.offset_top = -212
	panel.offset_bottom = -14
	panel.add_theme_stylebox_override("panel", _sb(Color(0.34, 0.25, 0.17, 0.96), Color(0.16, 0.11, 0.07), 90))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	minimap_vp = SubViewport.new()
	minimap_vp.size = Vector2i(180, 180)
	minimap_vp.own_world_3d = false
	minimap_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	minimap_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(minimap_vp)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 90.0
	cam.near = 1.0
	cam.far = 800.0
	cam.position = Vector3(64.0, 260.0, 64.0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	minimap_vp.add_child(cam)
	minimap_cam = cam

	minimap_rect = TextureRect.new()
	minimap_rect.texture = minimap_vp.get_texture()
	minimap_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	minimap_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	minimap_rect.custom_minimum_size = Vector2(180, 180)
	minimap_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mm := ShaderMaterial.new()
	mm.shader = load("res://shaders/minimap.gdshader")
	minimap_rect.material = mm
	panel.add_child(minimap_rect)

func _build_hint(root: Control) -> void:
	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hint.offset_left = -640
	hint.offset_right = -14
	hint.offset_top = -40
	hint.offset_bottom = -12
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.text = "WASD 平移 · 滚轮 缩放 · Q/E 旋转 · 空格 暂停 · 1-9 快建 · 道路按住左键拖动 · F5 存档 / F9 读档"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.70, 0.73, 0.76))
	hint.add_theme_constant_override("outline_size", 4)
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hint)

# ---------------------------------------------------------------- 图标

func _load_icons() -> void:
	for id in build_buttons.keys():
		if not BuildingDefs.DEFS.has(id):
			continue
		var tex: Texture2D = await _make_icon(str(id))
		if tex == null or not build_buttons.has(id):
			continue
		var b: Button = build_buttons[id]
		b.icon = tex
		b.add_theme_constant_override("icon_max_width", 26)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(236, 36)

func _make_icon(id: String) -> Texture2D:
	var path := str(Building.MODELS.get(id, ""))
	if path == "" or not ResourceLoader.exists(path):
		return null

	var vp := SubViewport.new()
	vp.size = Vector2i(128, 128)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.86, 0.86, 0.90)
	e.ambient_light_energy = 1.15
	env.environment = e
	vp.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = false
	vp.add_child(sun)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.5
	cam.near = 0.5
	cam.far = 100.0
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(6.5, 6.5, 8.5), Vector3(0, 1.4, 0), Vector3.UP)

	var inst: Node3D = load(path).instantiate()
	vp.add_child(inst)
	ModelPaint.apply(inst)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var tex: Texture2D = ImageTexture.create_from_image(img)
	vp.queue_free()
	return tex

# ---------------------------------------------------------------- 刷新

func _process(delta: float) -> void:
	_acc += delta
	if _acc < 0.1:
		return
	_acc = 0.0
	_refresh()
	if minimap_cam != null and main != null and main.camera_rig != null:
		var p: Vector3 = main.camera_rig.position
		minimap_cam.position = Vector3(p.x, 260.0, p.z)

func _refresh() -> void:
	time_label.text = "第 %d 年 · %s · 第 %d/%d 天" % [
		GameState.year(), GameState.season_name(),
		GameState.day_in_season() + 1, GameState.DAYS_PER_SEASON,
	]
	pop_label.text = "人口 %d" % GameState.citizens.size()
	for r in RES_ORDER:
		res_labels[r].text = "%s %d" % [RES_NAME[r], int(float(GameState.stock.get(r, 0.0)))]
	cap_label.text = "仓储 %d/%d" % [int(GameState.total_stock()), int(GameState.capacity)]
	if mood_label != null:
		mood_label.text = "幸福 %d" % int(round(GameState.happiness))
		var hv := GameState.happiness
		if hv < 35.0:
			mood_label.add_theme_color_override("font_color", Color(0.90, 0.42, 0.32))
		elif hv < 55.0:
			mood_label.add_theme_color_override("font_color", Color(0.90, 0.68, 0.34))
		else:
			mood_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.46))

	var active := -1
	if GameState.paused:
		active = 0
	else:
		for i in range(1, SPEEDS.size()):
			if is_equal_approx(float(SPEEDS[i][0]), GameState.speed):
				active = i
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = (i == active)

	if _current != null and is_instance_valid(_current):
		_refresh_selected()
	elif _current != null:
		show_building(null)

func _refresh_selected() -> void:
	var b := _current
	var d := b.def
	var lines: Array[String] = []

	if not b.complete:
		var pct := int(b.progress / maxf(b.need_work, 0.001) * 100.0)
		lines.append("建造中：%d%%" % pct)
		lines.append("建造工：%d 人" % b.builders.size())
		if b.builders.is_empty():
			lines.append("（等待空闲居民）")
		lines.append("")
		lines.append(str(d.get("desc", "")))
		sel_body.text = "\n".join(lines)
		sel_upgrade.visible = false
		return

	lines.append("工人：%d / %d" % [b.workers.size(), b.slots()])

	var next := str(d.get("upgrades_to", ""))
	if next != "" and BuildingDefs.DEFS.has(next):
		var nd: Dictionary = BuildingDefs.DEFS[next]
		sel_upgrade.visible = true
		sel_upgrade.text = "升级为 %s（%s）" % [str(nd.get("name", next)), BuildingDefs.cost_text(next)]
		sel_upgrade.disabled = not GameState.can_afford(nd.get("cost", {}))
	else:
		sel_upgrade.visible = false

	if b.is_hospital():
		lines.append("在治病人：%d" % GameState.sick_count())
		lines.append("状态：%s" % ("有医生值守" if not b.workers.is_empty() else "缺医生"))
	if b.is_well():
		lines.append("覆盖半径：%d 米" % int(b.well_radius()))

	var h := int(d.get("homes", 0))
	if h > 0:
		var n := 0
		for c in GameState.citizens:
			if c.home == b:
				n += 1
		lines.append("居住：%d / %d" % [n, h])

	if float(d.get("capacity", 0.0)) > 0.0:
		lines.append("仓储：+%d" % int(float(d["capacity"])))

	var p: Dictionary = d.get("produce", {})
	if not p.is_empty():
		var mult := 1.0
		var seasonal: Array = d.get("seasonal", [])
		if seasonal.size() == 4:
			mult = float(seasonal[GameState.season()])
		var res := str(p.get("res", "wood"))
		lines.append("产出：%s +%.2f/日（%d 人）" % [RES_NAME.get(res, res), float(p.get("rate", 0.0)) * mult * b.workers.size(), b.workers.size()])
		var consume: Dictionary = p.get("consume", {})
		if not consume.is_empty():
			var parts: Array[String] = []
			for k in consume:
				parts.append("%s %.2f" % [RES_NAME.get(k, k), float(consume[k]) * b.workers.size()])
			lines.append("消耗：%s /日" % "，".join(parts))

	lines.append("")
	lines.append(str(d.get("desc", "")))
	sel_body.text = "\n".join(lines)

func show_building(b: Building) -> void:
	_current = b
	if b == null:
		sel_panel.visible = false
		return
	sel_panel.visible = true
	sel_title.text = str(b.def.get("name", b.def_id))
	_refresh_selected()

func set_build_mode(id: String) -> void:
	for k in build_buttons:
		build_buttons[k].button_pressed = (k == id)

# ---------------------------------------------------------------- 日志

func add_log(text: String) -> void:
	var l := Label.new()
	l.text = "· " + text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.86, 0.87, 0.83))
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_box.add_child(l)
	while log_box.get_child_count() > 7:
		var old := log_box.get_child(0)
		log_box.remove_child(old)
		old.queue_free()
	_fade_out(l)

func _fade_out(l: Label) -> void:
	await get_tree().create_timer(10.0).timeout
	if not is_instance_valid(l):
		return
	var tw := create_tween()
	tw.tween_property(l, "modulate:a", 0.0, 1.5)
	tw.tween_callback(l.queue_free)

# ---------------------------------------------------------------- 回调

func _on_speed(v: float) -> void:
	if v <= 0.0:
		GameState.paused = true
	else:
		GameState.paused = false
		GameState.speed = v

func _on_build_pressed(id: String) -> void:
	if main != null:
		main.start_build(id)

func _on_cancel_build() -> void:
	if main != null:
		main.cancel_build()

func _on_demolish() -> void:
	if main != null and _current != null:
		main.demolish(_current)

func _on_upgrade() -> void:
	if main != null and _current != null:
		main.upgrade_building(_current)

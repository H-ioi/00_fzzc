class_name GameUI
extends CanvasLayer
## 全部 UI 用代码构建，避免手写 .tscn 出错。

var main: Node = null

var time_label: Label
var pop_label: Label
var cap_label: Label
var mood_label: Label
var eff_label: Label
var res_labels: Dictionary = {}
var speed_buttons: Array[Button] = []
var build_buttons: Dictionary = {}
var build_panel: PanelContainer
var sel_panel: PanelContainer
var sel_title: Label
var sel_body: Label
var sel_upgrade: Button
var sel_demolish: Button
var sel_trade: Button
var sel_assign: Button
var sel_lock_workers: CheckButton
var herd_row: HBoxContainer
var herd_keep_down: Button
var herd_keep_up: Button
var herd_slaughter: Button
var herd_restock: Button
var log_box: VBoxContainer
var event_debug_panel: PanelContainer
var event_enabled_check: CheckButton
var _event_weight_value_labels: Dictionary = {}
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
	if not GameState.resources_changed.is_connected(_on_resources_changed):
		GameState.resources_changed.connect(_on_resources_changed)

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
	_build_event_debug_panel(root)
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

	eff_label = Label.new()
	eff_label.custom_minimum_size.x = 168
	eff_label.add_theme_color_override("font_color", Color(0.78, 0.72, 0.58))
	eff_label.text = ""
	hb.add_child(eff_label)

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

	var menu_idx := 0
	for id in BuildingDefs.menu_build_ids():
		var d: Dictionary = BuildingDefs.DEFS[id]
		var b := Button.new()
		b.text = _build_button_label(id, menu_idx)
		b.tooltip_text = _build_button_tooltip(id, true)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.x = 200
		b.pressed.connect(_on_build_pressed.bind(id))
		list.add_child(b)
		build_buttons[id] = b
		menu_idx += 1

	var cancel := Button.new()
	cancel.text = "取消建造 (Esc)"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.pressed.connect(_on_cancel_build)
	vb.add_child(cancel)

func _build_selected(root: Control) -> void:
	sel_panel = PanelContainer.new()
	sel_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	sel_panel.offset_left = -292
	sel_panel.offset_right = -12
	sel_panel.offset_top = 58
	sel_panel.offset_bottom = 640
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

	var worker_row := HBoxContainer.new()
	worker_row.add_theme_constant_override("separation", 6)
	vb.add_child(worker_row)

	sel_assign = Button.new()
	sel_assign.text = "优先指派"
	sel_assign.focus_mode = Control.FOCUS_NONE
	sel_assign.visible = false
	sel_assign.pressed.connect(_on_prioritize_workers)
	worker_row.add_child(sel_assign)

	sel_lock_workers = CheckButton.new()
	sel_lock_workers.text = "锁定工人"
	sel_lock_workers.focus_mode = Control.FOCUS_NONE
	sel_lock_workers.visible = false
	sel_lock_workers.tooltip_text = "锁定后自动排班不会调离在岗工人"
	sel_lock_workers.toggled.connect(_on_lock_workers_toggled)
	worker_row.add_child(sel_lock_workers)

	herd_row = HBoxContainer.new()
	herd_row.add_theme_constant_override("separation", 6)
	herd_row.visible = false
	vb.add_child(herd_row)
	herd_keep_down = Button.new()
	herd_keep_down.text = "保留−"
	herd_keep_down.focus_mode = Control.FOCUS_NONE
	herd_keep_down.tooltip_text = "降低保留目标。春夏秋超出的羊会被屠宰。"
	herd_keep_down.pressed.connect(_on_herd_keep_down)
	herd_row.add_child(herd_keep_down)
	herd_keep_up = Button.new()
	herd_keep_up.text = "保留+"
	herd_keep_up.focus_mode = Control.FOCUS_NONE
	herd_keep_up.tooltip_text = "提高保留目标，留下更多种羊过冬。"
	herd_keep_up.pressed.connect(_on_herd_keep_up)
	herd_row.add_child(herd_keep_up)
	herd_slaughter = Button.new()
	herd_slaughter.text = "屠宰一只"
	herd_slaughter.focus_mode = Control.FOCUS_NONE
	herd_slaughter.tooltip_text = "立刻屠宰 1 只，获得食物和皮革。冬天也能用。"
	herd_slaughter.pressed.connect(_on_herd_slaughter)
	herd_row.add_child(herd_slaughter)
	herd_restock = Button.new()
	herd_restock.text = "引进种羊"
	herd_restock.focus_mode = Control.FOCUS_NONE
	herd_restock.visible = false
	herd_restock.pressed.connect(_on_herd_restock)
	vb.add_child(herd_restock)

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

	sel_trade = Button.new()
	sel_trade.text = "手动贸易（4:1）"
	sel_trade.focus_mode = Control.FOCUS_NONE
	sel_trade.visible = false
	sel_trade.pressed.connect(_on_manual_trade)
	vb.add_child(sel_trade)

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

func toggle_event_debug_panel() -> void:
	if event_debug_panel == null:
		return
	event_debug_panel.visible = not event_debug_panel.visible
	if event_debug_panel.visible:
		_refresh_event_debug_panel()

func _build_event_debug_panel(root: Control) -> void:
	var panel := PanelContainer.new()
	event_debug_panel = panel
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 224
	panel.offset_top = 58
	panel.offset_right = 224 + 248
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.visible = false
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "随机事件 (F8)"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.30, 0.20, 0.12))
	vb.add_child(title)

	event_enabled_check = CheckButton.new()
	event_enabled_check.text = "random_events_enabled"
	event_enabled_check.focus_mode = Control.FOCUS_NONE
	event_enabled_check.toggled.connect(_on_event_enabled_toggled)
	vb.add_child(event_enabled_check)

	var sub := Label.new()
	sub.text = "event_weights（±0.1）"
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.28, 0.20, 0.13))
	vb.add_child(sub)

	for id in GameEvents.WEIGHT_DEFAULTS.keys():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		vb.add_child(row)

		var id_l := Label.new()
		id_l.text = str(id)
		id_l.custom_minimum_size.x = 118
		id_l.add_theme_font_size_override("font_size", 13)
		row.add_child(id_l)

		var val_l := Label.new()
		val_l.custom_minimum_size.x = 44
		val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_l.add_theme_font_size_override("font_size", 13)
		row.add_child(val_l)
		_event_weight_value_labels[id] = val_l

		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size = Vector2(28, 24)
		minus.focus_mode = Control.FOCUS_NONE
		minus.pressed.connect(_on_event_weight_delta.bind(str(id), -0.1))
		row.add_child(minus)

		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(28, 24)
		plus.focus_mode = Control.FOCUS_NONE
		plus.pressed.connect(_on_event_weight_delta.bind(str(id), 0.1))
		row.add_child(plus)

func _refresh_event_debug_panel() -> void:
	if event_enabled_check == null:
		return
	event_enabled_check.set_block_signals(true)
	event_enabled_check.button_pressed = GameState.random_events_enabled
	event_enabled_check.set_block_signals(false)
	for id in _event_weight_value_labels:
		var l: Label = _event_weight_value_labels[id]
		l.text = "%.1f" % float(GameState.event_weights.get(id, GameEvents.WEIGHT_DEFAULTS.get(id, 1.0)))

func _on_event_enabled_toggled(on: bool) -> void:
	GameState.random_events_enabled = on

func _on_event_weight_delta(id: String, delta: float) -> void:
	if not GameEvents.WEIGHT_DEFAULTS.has(id):
		return
	var v := float(GameState.event_weights.get(id, GameEvents.WEIGHT_DEFAULTS[id]))
	v = clampf(v + delta, 0.0, 5.0)
	GameState.event_weights[id] = v
	_refresh_event_debug_panel()

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

func _build_button_label(id: String, menu_idx: int) -> String:
	var d: Dictionary = BuildingDefs.DEFS[id]
	var prefix := ""
	if menu_idx >= 0 and menu_idx < 9:
		prefix = "[%d] " % (menu_idx + 1)
	return "%s%s　%s" % [prefix, str(d["name"]), BuildingDefs.cost_text(id)]

func _build_button_tooltip(id: String, can_afford: bool) -> String:
	var d: Dictionary = BuildingDefs.DEFS[id]
	var desc := str(d.get("desc", ""))
	var ct := BuildingDefs.cost_text(id)
	if can_afford:
		return "%s\n造价：%s" % [desc, ct]
	return "%s\n造价：%s\n资源不足，无法建造" % [desc, ct]

func _menu_index_for(id: String) -> int:
	var ids := BuildingDefs.menu_build_ids()
	return ids.find(id)

func _process(delta: float) -> void:
	_acc += delta
	if _acc < 0.1:
		return
	_acc = 0.0
	_refresh()
	if minimap_cam != null and main != null and main.camera_rig != null:
		var p: Vector3 = main.camera_rig.position
		minimap_cam.position = Vector3(p.x, 260.0, p.z)

func _on_resources_changed() -> void:
	_refresh_top_bar()
	_refresh_build_buttons()
	if _current != null and is_instance_valid(_current):
		_refresh_selected()

func _refresh() -> void:
	_refresh_top_bar()
	_refresh_build_buttons()
	if event_debug_panel != null and event_debug_panel.visible:
		_refresh_event_debug_panel()

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

func _refresh_top_bar() -> void:
	time_label.text = "第 %d 年 · %s · 第 %d/%d 天" % [
		GameState.year(), GameState.season_name(),
		GameState.day_in_season() + 1, GameState.DAYS_PER_SEASON,
	]
	var pop := GameState.citizens.size()
	var sick := GameState.sick_count()
	var dead := GameState.dead_count
	var pop_parts: Array[String] = ["人口 %d" % pop]
	if sick > 0:
		pop_parts.append("病 %d" % sick)
	if dead > 0:
		pop_parts.append("亡 %d" % dead)
	if GameState.pasture_count() > 0:
		pop_parts.append("羊 %d" % GameState.herd_headcount())
	pop_label.text = " · ".join(pop_parts)
	if sick > 0:
		if sick >= pop / 2 and pop > 0:
			pop_label.add_theme_color_override("font_color", Color(0.95, 0.38, 0.34))
		else:
			pop_label.add_theme_color_override("font_color", Color(0.92, 0.52, 0.48))
	elif dead > 0:
		pop_label.add_theme_color_override("font_color", Color(0.72, 0.74, 0.78))
	elif GameState.herd_alert_summary() != "":
		pop_label.add_theme_color_override("font_color", Color(0.92, 0.62, 0.38))
	else:
		pop_label.add_theme_color_override("font_color", Color(0.84, 0.86, 0.90))

	for r in RES_ORDER:
		var l: Label = res_labels[r]
		var amt := int(float(GameState.stock.get(r, 0.0)))
		l.text = "%s %d" % [RES_NAME[r], amt]
		if GameState.resource_label_warn(r):
			l.text = "%s %d ⚠" % [RES_NAME[r], amt]
			if r == "food" and float(GameState.stock.get("food", 0.0)) <= 0.0:
				l.add_theme_color_override("font_color", Color(0.95, 0.38, 0.32))
			else:
				l.add_theme_color_override("font_color", Color(0.95, 0.45, 0.32))
		else:
			l.add_theme_color_override("font_color", RES_COLOR[r])

	cap_label.text = "仓储 %d/%d 余%.0f" % [
		int(GameState.total_stock()), int(GameState.capacity), GameState.room_left()]
	if GameState.room_left() < 40.0:
		cap_label.add_theme_color_override("font_color", Color(0.92, 0.55, 0.38))
	else:
		cap_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
	if eff_label != null:
		var parts: Array[String] = []
		var alerts := GameState.resource_alert_summary()
		if alerts != "":
			parts.append(alerts)
		var tp := GameState.tool_efficiency_pct()
		if tp < 99 and not GameState.resource_label_warn("tools"):
			parts.append("工具 %d%%" % tp)
		var cloth := GameState.cloth_stress_label()
		if cloth != "":
			parts.append(cloth)
		eff_label.text = " · ".join(parts)
		if GameState.ui_winter_crisis() or GameState.ui_no_firewood():
			eff_label.add_theme_color_override("font_color", Color(0.95, 0.48, 0.36))
		elif GameState.ui_low_clothes() or GameState.cold_snap_active() or GameState.herd_alert_summary() != "":
			eff_label.add_theme_color_override("font_color", Color(0.92, 0.62, 0.38))
		else:
			eff_label.add_theme_color_override("font_color", Color(0.78, 0.72, 0.58))
	if mood_label != null:
		var hv := GameState.happiness
		var mood_txt := "幸福 %d" % int(round(hv))
		if hv < 35.0:
			mood_txt += " · 低迷"
			mood_label.add_theme_color_override("font_color", Color(0.90, 0.42, 0.32))
		elif hv < 55.0:
			mood_txt += " · 偏低"
			mood_label.add_theme_color_override("font_color", Color(0.90, 0.68, 0.34))
		else:
			mood_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.46))
		mood_label.text = mood_txt

func _refresh_build_buttons() -> void:
	for id in build_buttons:
		if not BuildingDefs.DEFS.has(id):
			continue
		var d: Dictionary = BuildingDefs.DEFS[id]
		var btn: Button = build_buttons[id]
		var cost: Dictionary = d.get("cost", {})
		var ok := GameState.can_afford(cost)
		btn.disabled = not ok
		var mid := _menu_index_for(id)
		btn.text = _build_button_label(id, mid)
		btn.tooltip_text = _build_button_tooltip(id, ok)

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
		sel_trade.visible = false
		sel_assign.visible = false
		sel_lock_workers.visible = false
		_show_herd_controls(null)
		return

	lines.append("工人：%d / %d" % [b.workers.size(), b.slots()])
	var has_job_slots := b.slots() > 0
	sel_assign.visible = has_job_slots
	sel_lock_workers.visible = has_job_slots
	if has_job_slots:
		sel_assign.disabled = b.workers.size() >= b.slots()
		sel_lock_workers.set_block_signals(true)
		sel_lock_workers.button_pressed = b.lock_workers
		sel_lock_workers.set_block_signals(false)
		if b.workers.is_empty():
			lines.append("（尚无工人，可点「优先指派」）")
		else:
			var names: Array[String] = []
			for w in b.workers:
				if is_instance_valid(w):
					names.append(GameState.citizen_label(w))
			if not names.is_empty():
				lines.append("在岗：%s" % "、".join(names))
		if b.job_priority:
			lines.append("（已标记优先补员）")
		if b.lock_workers:
			lines.append("（工人已锁定）")
	else:
		sel_assign.visible = false
		sel_lock_workers.visible = false

	var next := str(d.get("upgrades_to", ""))
	if next != "" and BuildingDefs.DEFS.has(next):
		var nd: Dictionary = BuildingDefs.DEFS[next]
		var up_cost: Dictionary = nd.get("cost", {})
		var can_up := GameState.can_afford(up_cost) and not b.burning
		sel_upgrade.visible = true
		sel_upgrade.text = "升级为 %s（%s）" % [str(nd.get("name", next)), BuildingDefs.cost_text(next)]
		sel_upgrade.disabled = not can_up
		if b.burning:
			sel_upgrade.tooltip_text = "建筑着火中，无法升级"
		elif not GameState.can_afford(up_cost):
			sel_upgrade.tooltip_text = "资源不足\n需要：%s" % BuildingDefs.cost_text(next)
		else:
			sel_upgrade.tooltip_text = ""
	else:
		sel_upgrade.visible = false

	if b.is_hospital():
		lines.append("在治病人：%d" % GameState.sick_count())
		lines.append("状态：%s" % ("有医生值守" if not b.workers.is_empty() else "缺医生"))
	if b.is_well():
		lines.append("覆盖半径：%d 米" % int(b.well_radius()))
	if b.def_id == "tavern":
		lines.append("幸福：%s" % ("有伙计，每日提升" if not b.workers.is_empty() else "缺伙计，幸福缓慢下降"))
	if bool(d.get("school", false)):
		lines.append("覆盖半径：%d 米" % int(b.well_radius()))
		var up: Dictionary = d.get("upkeep", {})
		if not up.is_empty():
			var parts: Array[String] = []
			for k in ["wood", "food", "stone", "firewood"]:
				if up.has(k):
					parts.append("%s %.1f/日" % [RES_NAME.get(k, k), float(up[k])])
			if parts.is_empty():
				for k in up:
					parts.append("%s %.1f/日" % [RES_NAME.get(k, k), float(up[k])])
			lines.append("维护：%s" % " ".join(parts))
		var pct := int(round(float(d.get("child_work_mult", 0.75)) * 100.0))
		lines.append("状态：%s" % ("开课，半径内学童效率 %d%%" % pct if b.school_running else "停课（维护资源不足）"))
		lines.append("外观：暂用教堂模型")

	var h := int(d.get("homes", 0))
	if h > 0:
		var n := 0
		for c in GameState.citizens:
			if c.home == b:
				n += 1
		lines.append("居住：%d / %d" % [n, h])

	if float(d.get("capacity", 0.0)) > 0.0:
		lines.append("仓储：+%d" % int(float(d["capacity"])))

	if b.is_pasture():
		for herd_line in GameState.herd_status_lines(b):
			lines.append(herd_line)
		_show_herd_controls(b)
	else:
		_show_herd_controls(null)

	if bool(d.get("trade", false)):
		sel_trade.visible = true
		if b.workers.is_empty():
			lines.append("贸易：缺商人，无法交易")
			sel_trade.disabled = true
		else:
			var until := GameState.trade_days_until_auto()
			if until <= 0:
				lines.append("自动贸易：今日结算")
			else:
				lines.append("自动贸易：%d 天后" % until)
			var prev: Dictionary = GameState.trade_preview()
			var sell := str(prev.get("sell", ""))
			var buy := str(prev.get("buy", "tools"))
			var buy_disp := GameState.trade_buy_label(buy)
			if sell != "":
				lines.append("可卖 %s %d → %s %.0f（4:1）" % [
					RES_NAME.get(sell, sell), int(prev.get("sell_amount", 20.0)),
					buy_disp, float(prev.get("buy_amount", 5.0))])
			else:
				lines.append("暂无富余资源可卖（单项需 >60）")
			lines.append("可购入（卖 %d 得）：" % int(prev.get("sell_amount", 20.0)))
			for row in prev.get("buy_catalog", []):
				if row is Dictionary:
					var rd: Dictionary = row
					var tag := " ◀" if bool(rd.get("active", false)) else ""
					lines.append("  %s +%.0f%s" % [
						str(rd.get("label", "")), float(rd.get("amount", 0.0)), tag])
			sel_trade.disabled = not GameState.can_manual_trade()
			if sel_trade.disabled:
				if GameState.trade_manual_day == GameState.total_days():
					sel_trade.tooltip_text = "今日已手动贸易一次"
				elif sell == "":
					sel_trade.tooltip_text = "没有富余资源可卖"
				else:
					sel_trade.tooltip_text = "需要商人值守且资源充足"
			else:
				sel_trade.tooltip_text = "立即按预览比例交易"
			if GameState.trade_manual_day == GameState.total_days():
				lines.append("（今日已手动贸易一次）")
	else:
		sel_trade.visible = false

	var p: Dictionary = d.get("produce", {})
	if not p.is_empty():
		var sm := b.season_mult()
		var site := b.site_production_mult()
		var mult := sm * site
		var res := str(p.get("res", "wood"))
		var wc := b.workers.size()
		var daily := 0.0 if wc == 0 else float(p.get("rate", 0.0)) * mult * GameState.season_work_mult() * wc
		lines.append("产出：%s +%.2f/日（%d 人）" % [RES_NAME.get(res, res), daily, wc])
		if site <= 0.01 and b.def_id == "dock":
			lines.append("（已脱离水域，无法捕鱼）")
		elif site <= 0.01 and b.def_id == "quarry":
			lines.append("（附近石矿已采尽）")
		elif site < 0.99 and b.def_id == "quarry":
			lines.append("（石矿偏少，效率约 %.0f%%）" % (site * 100.0))
		if b.produced > 0.01:
			lines.append("累计产出：%s %.0f" % [RES_NAME.get(res, res), b.produced])
		var consume: Dictionary = p.get("consume", {})
		if not consume.is_empty():
			var parts: Array[String] = []
			for k in consume:
				if wc == 0:
					parts.append("%s %.2f/人" % [RES_NAME.get(k, k), float(consume[k])])
				else:
					parts.append("%s %.2f" % [RES_NAME.get(k, k), float(consume[k]) * wc])
			lines.append("消耗：%s /日" % "，".join(parts))
		var season_bits: Array[String] = []
		var seasonal: Array = d.get("seasonal", [])
		if seasonal.size() == 4:
			season_bits.append("%s 建筑×%.0f%%" % [GameState.season_name(), sm * 100.0])
		elif not seasonal.is_empty():
			season_bits.append("%s" % GameState.season_name())
		var gm := GameState.season_work_mult()
		if absf(gm - 1.0) > 0.01:
			season_bits.append("全局×%.0f%%" % (gm * 100.0))
		if GameState.cold_snap_active():
			season_bits.append("寒潮中")
		if not season_bits.is_empty():
			lines.append("季节系数：%s" % " · ".join(season_bits))

	lines.append("")
	lines.append(str(d.get("desc", "")))
	sel_body.text = "\n".join(lines)

func show_building(b: Building) -> void:
	if b != null and not is_instance_valid(b):
		b = null
	_current = b
	if b == null:
		sel_panel.visible = false
		return
	sel_panel.visible = true
	sel_title.text = str(b.def.get("name", b.def_id))
	if b.burning:
		sel_title.text += " · 着火"
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

func _on_manual_trade() -> void:
	if GameState.try_manual_trade() and _current != null:
		_refresh_selected()

func _on_prioritize_workers() -> void:
	if main != null and _current != null:
		main.prioritize_building(_current)

func _on_lock_workers_toggled(pressed: bool) -> void:
	if main != null and _current != null:
		main.set_building_lock_workers(_current, pressed)
	_refresh_selected()

func _show_herd_controls(b: Building) -> void:
	var show := b != null and is_instance_valid(b) and b.is_pasture() and b.complete
	if herd_row != null:
		herd_row.visible = show
	if not show:
		if herd_restock != null:
			herd_restock.visible = false
		return
	var spec: Dictionary = b.def.get("herd", {})
	var cap := int(spec.get("cap", 14))
	herd_keep_down.disabled = b.herd_keep <= 0
	herd_keep_up.disabled = b.herd_keep >= cap
	herd_slaughter.disabled = b.herd_count <= 0
	herd_restock.visible = b.herd_count <= 0
	herd_restock.disabled = float(GameState.stock.get("food", 0.0)) < float(spec.get("restock_food", 24.0))
	herd_restock.text = "引进种羊（食 %d）" % int(spec.get("restock_food", 24.0))

func _on_herd_keep_down() -> void:
	if _current != null:
		GameState.adjust_herd_keep(_current, -1)
		_refresh_selected()

func _on_herd_keep_up() -> void:
	if _current != null:
		GameState.adjust_herd_keep(_current, 1)
		_refresh_selected()

func _on_herd_slaughter() -> void:
	if _current != null and GameState.slaughter_one_herd(_current, true):
		_refresh_selected()

func _on_herd_restock() -> void:
	if _current != null and GameState.restock_herd(_current):
		_refresh_selected()

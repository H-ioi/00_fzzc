class_name BuildingDefs
extends RefCounted
## 所有建筑 / 生产链的静态数据定义。
## 改数值只需要改这张表，不用动逻辑代码。

const _BUILTIN: Dictionary = {
	"house": {
		"smoke": true,
		"name": "民居",
		"size": Vector2i(2, 2),
		"cost": {"wood": 24.0, "stone": 4.0},
		"slots": 0,
		"homes": 3,
		"build_work": 10.0,
		"upgrades_to": "house_stone",
		"color": Color(0.80, 0.68, 0.50),
		"roof": Color(0.44, 0.27, 0.19),
		"height": 2.6,
		"desc": "提供 3 个居住位。没有空房就不会有人口增长。",
	},
	"storage": {
		"name": "仓库",
		"size": Vector2i(3, 3),
		"cost": {"wood": 40.0, "stone": 20.0},
		"slots": 0,
		"homes": 0,
		"capacity": 300.0,
		"build_work": 18.0,
		"color": Color(0.62, 0.55, 0.44),
		"roof": Color(0.33, 0.25, 0.19),
		"height": 3.0,
		"label_y": 7.4,
		"desc": "增加 300 点总仓储上限。所有资源共用总容量。",
	},
	"woodcutter": {
		"name": "伐木场",
		"size": Vector2i(2, 2),
		"cost": {"wood": 20.0},
		"slots": 2,
		"homes": 0,
		"build_work": 8.0,
		"produce": {"res": "wood", "rate": 1.0},
		"seasonal": [1.0, 1.0, 1.1, 0.8],
		"color": Color(0.55, 0.40, 0.26),
		"roof": Color(0.34, 0.22, 0.14),
		"height": 2.2,
		"desc": "砍伐周边林木产出木材。",
	},
	"quarry": {
		"name": "采石场",
		"size": Vector2i(2, 2),
		"cost": {"wood": 30.0, "stone": 10.0},
		"slots": 2,
		"homes": 0,
		"build_work": 12.0,
		"produce": {"res": "stone", "rate": 0.7},
		"color": Color(0.56, 0.56, 0.58),
		"roof": Color(0.35, 0.35, 0.38),
		"height": 2.2,
		"desc": "开采石料。",
	},
	"gatherer": {
		"name": "采集小屋",
		"size": Vector2i(2, 2),
		"cost": {"wood": 16.0},
		"slots": 2,
		"homes": 0,
		"build_work": 8.0,
		"produce": {"res": "food", "rate": 1.0},
		"seasonal": [1.1, 1.1, 1.2, 0.15],
		"color": Color(0.70, 0.62, 0.36),
		"roof": Color(0.40, 0.30, 0.16),
		"height": 2.0,
		"desc": "采集野果与菌类。冬季几乎停产。",
	},
	"hunter": {
		"name": "猎人小屋",
		"size": Vector2i(2, 2),
		"cost": {"wood": 20.0},
		"slots": 1,
		"homes": 0,
		"build_work": 8.0,
		"produce": {"res": "food", "rate": 1.2},
		"byproduct": {"res": "leather", "rate": 0.35},
		"seasonal": [1.0, 1.0, 1.0, 0.6],
		"color": Color(0.48, 0.42, 0.28),
		"roof": Color(0.28, 0.24, 0.16),
		"height": 2.0,
		"desc": "狩猎产出食物，冬季依然有效。",
	},
	"farm": {
		"name": "农田",
		"size": Vector2i(5, 5),
		"cost": {"wood": 32.0},
		"slots": 3,
		"homes": 0,
		"flat": true,
		"build_work": 24.0,
		"produce": {"res": "food", "rate": 1.2},
		"seasonal": [0.15, 0.55, 2.3, 0.0],
		"color": Color(0.40, 0.30, 0.18),
		"roof": Color(0.30, 0.22, 0.14),
		"height": 0.3,
		"desc": "秋季集中收获，冬季停产。占用 5x5 土地。",
	},
	"windmill": {
		"name": "风车",
		"size": Vector2i(3, 3),
		"cost": {"wood": 70.0, "stone": 40.0},
		"slots": 1,
		"homes": 0,
		"build_work": 22.0,
		"produce": {"res": "food", "rate": 2.6},
		"seasonal": [0.8, 0.9, 1.4, 0.7],
		"color": Color(0.60, 0.59, 0.55),
		"roof": Color(0.42, 0.26, 0.18),
		"height": 8.4,
		"label_y": 11.4,
		"desc": "把谷物磨成面粉，四季稳定产出食物。",
	},
	"church": {
		"name": "教堂",
		"size": Vector2i(4, 4),
		"cost": {"wood": 90.0, "stone": 120.0},
		"slots": 0,
		"homes": 0,
		"build_work": 42.0,
		"church": true,
		"color": Color(0.74, 0.70, 0.60),
		"roof": Color(0.34, 0.24, 0.30),
		"height": 16.0,
		"label_y": 18.4,
		"desc": "全村的信仰中心，缓慢改善居民健康。不占用工人。",
	},
	"dock": {
		"name": "渔码头",
		"size": Vector2i(3, 3),
		"cost": {"wood": 45.0, "stone": 12.0},
		"slots": 2,
		"homes": 0,
		"build_work": 18.0,
		"produce": {"res": "food", "rate": 1.7},
		"seasonal": [1.0, 1.0, 1.1, 0.35],
		"needs_water": true,
		"yaw": -90.0,
		"color": Color(0.55, 0.45, 0.30),
		"roof": Color(0.36, 0.26, 0.18),
		"height": 3.2,
		"label_y": 5.4,
		"desc": "必须建在水边，两个工人下网捕鱼。冬季产量下降。",
	},
	"house_row": {
		"smoke": true,
		"name": "联排民居",
		"size": Vector2i(2, 3),
		"cost": {"wood": 40.0, "stone": 8.0},
		"slots": 0,
		"homes": 4,
		"build_work": 14.0,
		"color": Color(0.82, 0.76, 0.62),
		"roof": Color(0.58, 0.32, 0.24),
		"height": 7.6,
		"label_y": 9.0,
		"desc": "面宽窄、进深大的两层联排住宅，住 4 户，适合并排成街。",
	},
	"carpenter": {
		"name": "木工坊",
		"size": Vector2i(2, 2),
		"cost": {"wood": 28.0, "stone": 6.0},
		"slots": 1,
		"homes": 0,
		"build_work": 12.0,
		"produce": {"res": "tools", "rate": 0.7, "consume": {"wood": 1.1}},
		"color": Color(0.58, 0.46, 0.30),
		"roof": Color(0.36, 0.24, 0.18),
		"height": 3.2,
		"label_y": 4.6,
		"desc": "用木材加工工具，不需要石头。和铁匠铺互补。",
	},
	"firewood": {
		"name": "柴火棚",
		"size": Vector2i(2, 2),
		"cost": {"wood": 18.0},
		"slots": 2,
		"homes": 0,
		"build_work": 8.0,
		"produce": {"res": "firewood", "rate": 2.2, "consume": {"wood": 1.3}},
		"seasonal": [1.0, 1.0, 1.2, 1.4],
		"color": Color(0.50, 0.36, 0.24),
		"roof": Color(0.30, 0.20, 0.13),
		"height": 2.0,
		"desc": "把木材劈成柴火。冬天没有柴火会冻死人。",
	},
	"road": {
		"name": "道路",
		"size": Vector2i(1, 1),
		"cost": {"wood": 1.0},
		"slots": 0,
		"homes": 0,
		"road": true,
		"build_work": 0.0,
		"color": Color(0.42, 0.34, 0.24),
		"roof": Color(0.30, 0.24, 0.17),
		"height": 0.1,
		"desc": "按住左键拖动连续铺设。居民在路上移动速度 +50%，寻路也会优先选择道路。",
	},
	"well": {
		"name": "水井",
		"size": Vector2i(2, 2),
		"cost": {"wood": 10.0, "stone": 20.0},
		"slots": 0,
		"homes": 0,
		"build_work": 8.0,
		"well": true,
		"radius": 12.0,
		"color": Color(0.56, 0.55, 0.51),
		"roof": Color(0.34, 0.20, 0.15),
		"height": 2.4,
		"desc": "消防设施。半径 12 米内的建筑起火后每天有 75% 概率被扑灭，火势蔓延也大幅减弱。",
	},
	"hospital": {
		"name": "医院",
		"size": Vector2i(3, 3),
		"cost": {"wood": 45.0, "stone": 30.0},
		"slots": 2,
		"homes": 0,
		"build_work": 20.0,
		"hospital": true,
		"color": Color(0.87, 0.81, 0.67),
		"roof": Color(0.44, 0.25, 0.18),
		"height": 2.7,
		"desc": "需要至少 1 名医生。有医生时，病人每天只掉 4 点健康，且康复速度翻倍。",
	},
	"tailor": {
		"name": "裁缝铺",
		"size": Vector2i(2, 2),
		"cost": {"wood": 25.0, "stone": 5.0},
		"slots": 1,
		"homes": 0,
		"build_work": 10.0,
		"produce": {"res": "clothes", "rate": 1.2, "consume": {"leather": 1.0}},
		"color": Color(0.62, 0.50, 0.34),
		"roof": Color(0.44, 0.25, 0.18),
		"height": 2.4,
		"desc": "把皮革做成衣物。冬天缺衣物时，居民取暖消耗会大幅增加。",
	},
	"blacksmith": {
		"name": "铁匠铺",
		"size": Vector2i(2, 2),
		"cost": {"wood": 30.0, "stone": 15.0},
		"slots": 1,
		"homes": 0,
		"build_work": 12.0,
		"produce": {"res": "tools", "rate": 0.8, "consume": {"stone": 0.6, "wood": 0.4}},
		"color": Color(0.48, 0.47, 0.45),
		"roof": Color(0.34, 0.20, 0.15),
		"height": 2.6,
		"desc": "打造工具。工具不足时，所有生产建筑效率最低降到 55%。",
	},
	"tavern": {
		"smoke": true,
		"name": "酒馆",
		"size": Vector2i(3, 3),
		"cost": {"wood": 45.0, "stone": 25.0},
		"slots": 1,
		"homes": 0,
		"build_work": 14.0,
		"color": Color(0.62, 0.50, 0.34),
		"roof": Color(0.42, 0.24, 0.16),
		"height": 3.4,
		"desc": "需要 1 名伙计。有伙计值守时每天提升村庄幸福度（幸福度低于 55 时居民干活变慢）。",
	},
	"trade": {
		"name": "贸易站",
		"size": Vector2i(3, 3),
		"cost": {"wood": 50.0, "stone": 20.0},
		"slots": 1,
		"homes": 0,
		"build_work": 16.0,
		"trade": true,
		"color": Color(0.55, 0.42, 0.27),
		"roof": Color(0.40, 0.24, 0.17),
		"height": 2.8,
		"desc": "需要 1 名商人。每 6 天自动用最富余的资源换回最缺的工具或衣物（4:1）。",
	},
	"house_stone": {
		"smoke": true,
		"name": "石屋",
		"size": Vector2i(2, 2),
		"cost": {"wood": 30.0, "stone": 30.0},
		"slots": 0,
		"homes": 5,
		"build_work": 16.0,
		"upgrades_to": "house_manor",
		"upgrade_only": true,
		"color": Color(0.56, 0.55, 0.51),
		"roof": Color(0.34, 0.20, 0.15),
		"height": 3.0,
		"desc": "民居的第一次升级：5 个居住位。",
	},
	"house_manor": {
		"smoke": true,
		"name": "大宅",
		"size": Vector2i(2, 2),
		"cost": {"wood": 50.0, "stone": 60.0},
		"slots": 0,
		"homes": 8,
		"build_work": 24.0,
		"upgrade_only": true,
		"color": Color(0.87, 0.81, 0.67),
		"roof": Color(0.44, 0.25, 0.18),
		"height": 4.2,
		"desc": "民居的终极形态：8 个居住位、两层、带门廊。",
	},
}

static var DEFS: Dictionary = {}
static var _loaded := false
const JSON_PATH := "res://data/buildings.json"

## 用内置表初始化，然后用 data/buildings.json 覆盖（Mod 数据外置）。
## JSON 缺失或解析失败时保持内置表，不影响启动。
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	DEFS = _BUILTIN.duplicate(true)
	if not FileAccess.file_exists(JSON_PATH):
		return
	var txt := FileAccess.get_file_as_string(JSON_PATH)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("buildings.json 解析失败，使用内置数据")
		return
	var n := 0
	for id in parsed:
		var d = parsed[id]
		if typeof(d) != TYPE_DICTIONARY:
			continue
		DEFS[str(id)] = _convert(d)
		n += 1
	if n > 0:
		print("[BuildingDefs] 已从 JSON 载入 %d 条建筑数据" % n)

static func _convert(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d:
		var v = d[k]
		match str(k):
			"size":
				if v is Array and v.size() >= 2:
					out[k] = Vector2i(int(v[0]), int(v[1]))
				else:
					out[k] = Vector2i(1, 1)
			"color", "roof":
				if v is Array and v.size() >= 3:
					out[k] = Color(float(v[0]), float(v[1]), float(v[2]))
			_:
				out[k] = v
	return out

static func get_def(id: String) -> Dictionary:
	ensure_loaded()
	return DEFS.get(id, {})

static func cost_text(id: String) -> String:
	ensure_loaded()
	var d: Dictionary = DEFS.get(id, {})
	var c: Dictionary = d.get("cost", {})
	var names := {"wood": "木", "stone": "石", "food": "食", "firewood": "柴",
		"tools": "具", "clothes": "衣", "leather": "皮"}
	var order := ["wood", "stone", "food", "firewood", "tools", "clothes", "leather"]
	var parts: Array[String] = []
	for k in order:
		if c.has(k):
			parts.append("%s%d" % [names.get(k, k), int(c[k])])
	return " ".join(parts)

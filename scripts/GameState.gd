extends Node
## 全局状态：资源、时间、人口、建筑注册表、寻路网格。

signal resources_changed
signal season_changed(season: int)
signal day_passed(day: int)
signal log_message(text: String)

const DAY_SECONDS := 20.0        ## 1 个游戏日 = 20 秒（1 倍速）
const DAYS_PER_SEASON := 6
const SEASONS: Array[String] = ["春", "夏", "秋", "冬"]
const BASE_CAPACITY := 800.0

var stock: Dictionary = {
	"wood": 250.0,
	"stone": 120.0,
	"food": 400.0,
	"firewood": 80.0,
	"tools": 30.0,
	"clothes": 30.0,
	"leather": 20.0,
}

var capacity := BASE_CAPACITY
var happiness := 62.0
var t := 0.0
var speed := 1.0
var paused := false
var started := false

var citizens: Array = []
var buildings: Array = []
var grid: GridSystem
var ui_font: SystemFont

var _day := -1
var _season := -1
var _res_dirty := false
var _res_timer := 0.0
var verbose := false

# 调试统计
var stat_meals := 0
var stat_food_in := 0.0

func _ready() -> void:
	BuildingDefs.ensure_loaded()
	ui_font = SystemFont.new()
	ui_font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei",
		"PingFang SC", "Noto Sans CJK SC", "sans-serif",
	])
	ui_font.allow_system_fallback = true

func _process(delta: float) -> void:
	_res_timer += delta
	if _res_dirty and _res_timer >= 0.1:
		_res_timer = 0.0
		_res_dirty = false
		resources_changed.emit()

	if not started or paused:
		return

	t += delta * speed

	var d := total_days()
	if d != _day:
		_day = d
		_new_day()

	var s := season()
	if s != _season:
		_season = s
		season_changed.emit(s)

# ---------------------------------------------------------------- 时间

func total_days() -> int:
	return int(t / DAY_SECONDS)

func day_in_season() -> int:
	return total_days() % DAYS_PER_SEASON

func season() -> int:
	return (total_days() / DAYS_PER_SEASON) % 4

func year() -> int:
	return 1 + total_days() / (DAYS_PER_SEASON * 4)

func is_winter() -> bool:
	return season() == 3

func season_name() -> String:
	return SEASONS[season()]

# ---------------------------------------------------------------- 资源

func total_stock() -> float:
	var s := 0.0
	for k in stock:
		s += float(stock[k])
	return s

func room_left() -> float:
	return maxf(0.0, capacity - total_stock())

func add(res: String, amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var real := minf(amount, room_left())
	stock[res] = float(stock.get(res, 0.0)) + real
	_res_dirty = true
	return real

func take(res: String, amount: float) -> bool:
	if float(stock.get(res, 0.0)) + 0.0001 < amount:
		return false
	stock[res] = float(stock.get(res, 0.0)) - amount
	_res_dirty = true
	return true

func can_afford(cost: Dictionary) -> bool:
	for k in cost:
		if float(stock.get(k, 0.0)) + 0.0001 < float(cost[k]):
			return false
	return true

func pay(cost: Dictionary) -> void:
	for k in cost:
		stock[k] = float(stock.get(k, 0.0)) - float(cost[k])
	_res_dirty = true

func refund(cost: Dictionary, ratio: float = 0.5) -> void:
	for k in cost:
		add(k, float(cost[k]) * ratio)

# ---------------------------------------------------------------- 建筑 / 人口

func find_storage() -> Building:
	for b in buildings:
		if float(b.def.get("capacity", 0.0)) > 0.0:
			return b
	return null

## 有医生值守的医院
func active_hospital() -> Building:
	for b in buildings:
		if is_instance_valid(b) and b.complete and b.is_hospital() and not b.workers.is_empty():
			return b
	return null

## 建成的教堂：不占工人，缓慢提升全城健康
func has_church() -> bool:
	for b in buildings:
		if is_instance_valid(b) and b.complete and bool(b.def.get("church", false)):
			return true
	return false

func sick_count() -> int:
	var n := 0
	for c in citizens:
		if is_instance_valid(c) and not c.dead and c.sick > 0:
			n += 1
	return n

## 工具充足度：不足时生产效率最低降到 55%
func tool_factor() -> float:
	var need := maxf(4.0, float(citizens.size()) * 0.8)
	return clampf(float(stock.get("tools", 0.0)) / need, 0.55, 1.0)

## 衣物充足度：不足时冬季取暖消耗放大
func cloth_factor() -> float:
	var need := maxf(3.0, float(citizens.size()) * 0.5)
	return 1.0 if float(stock.get("clothes", 0.0)) >= need else 1.7

## 士气系数：幸福度过低时居民干活变慢
func mood_factor() -> float:
	if happiness >= 55.0:
		return 1.0
	if happiness >= 35.0:
		return 0.85
	return 0.7

func home_capacity() -> int:
	var total := 0
	for b in buildings:
		total += int(b.def.get("homes", 0))
	return total

func free_homes() -> int:
	return home_capacity() - citizens.size()

func log_msg(text: String) -> void:
	if verbose:
		print("[LOG] ", text)
	log_message.emit(text)

# ---------------------------------------------------------------- 每日结算

func _new_day() -> void:
	var pop := citizens.size()
	if pop > 0:
		# 工具与衣物磨损
		stock["tools"] = maxf(0.0, float(stock.get("tools", 0.0)) - pop * 0.03)
		stock["clothes"] = maxf(0.0, float(stock.get("clothes", 0.0)) - pop * 0.02)
		if float(stock.get("tools", 0.0)) <= 0.0 and total_days() % 6 == 0:
			log_msg("工具耗尽，生产效率下降！")
		if is_winter() and float(stock.get("clothes", 0.0)) < pop * 0.5 and total_days() % 6 == 0:
			log_msg("衣物不足，居民这个冬天更难熬。")
		# 食物由居民自己回家吃饭消耗（见 Citizen._rest），这里只结算冬季取暖。
		var fire_ratio := 1.0
		if is_winter():
			var need_fire := pop * 0.30
			var got_fire := minf(need_fire, float(stock.get("firewood", 0.0)))
			stock["firewood"] = float(stock.get("firewood", 0.0)) - got_fire
			fire_ratio = got_fire / need_fire if need_fire > 0.0 else 1.0
			if got_fire <= 0.0:
				log_msg("柴火耗尽，居民正在挨冻！")

		for c in citizens.duplicate():
			if is_instance_valid(c):
				c.daily_update(fire_ratio, is_winter())
		_res_dirty = true

	day_passed.emit(total_days())

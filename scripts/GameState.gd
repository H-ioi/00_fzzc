extends Node
## 全局状态：资源、时间、人口、建筑注册表、寻路网格。

signal resources_changed
signal season_changed(season: int)
signal day_passed(day: int)
signal log_message(text: String)

const DAY_SECONDS := 20.0        ## 1 个游戏日 = 20 秒（1 倍速）
const DAYS_PER_SEASON := 6
const DAYS_PER_YEAR := DAYS_PER_SEASON * 4
const ADULT_AGE_YEARS := 16
const CHILD_WORK_MULT := 0.55
const SEASONS: Array[String] = ["春", "夏", "秋", "冬"]
const BASE_CAPACITY := 800.0
const TRADE_INTERVAL := 6
const TRADE_SELL_AMOUNT := 20.0
const TRADE_BUY_RATIO := 0.25  ## 卖出 4 份换 1 份
const TRADE_SELL_KEYS: Array[String] = ["wood", "stone", "food", "firewood", "leather"]
const TRADE_BUY_KEYS: Array[String] = ["food", "stone", "firewood", "tools", "clothes"]
const RES_ZH := {
	"wood": "木材", "stone": "石头", "food": "食物", "firewood": "柴火",
	"tools": "工具", "clothes": "衣物", "leather": "皮革",
}
## 消耗 / 冬季 / 幸福（Banished 向：冬柴占比高、衣物工具缓磨、幸福慢漂移）
const WINTER_FIREWOOD_PER_CAPITA := 0.33  ## 原 0.30 +10%：每人每日取暖（6 冬≈2.0 份/人）
const COLD_SNAP_FIRE_MULT := 1.41  ## 原 1.28 +10%：寒潮日额外柴耗
const COLD_SNAP_WARMTH_MULT := 1.23  ## 原 1.12 +10%：寒潮日失温加重
const CLOTH_FIRE_STRESS := 1.87  ## 原 1.7 +10%：缺衣时取暖消耗倍率
const DAILY_TOOL_WEAR := 0.033  ## 原 0.03 +10%：人均工具日磨损
const DAILY_CLOTHES_WEAR := 0.022  ## 原 0.02 +10%：人均衣物日磨损
const HAPPINESS_BASE := 62.0
const HAPPINESS_TAVERN_DRIFT := 1.44  ## 原 1.6 −10%：酒馆值守日目标上飘
const HAPPINESS_NO_TAVERN_DRIFT := 0.81  ## 原 0.9 −10%：无酒馆日目标下飘
const HAPPINESS_MOVE_SPEED := 0.72  ## 原 0.8 −10%：向目标靠拢速度
const SEASON_WORK_MULTS: Array[float] = [1.0, 1.05, 1.0, 0.81]  ## 冬 0.90→0.81 −10%

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
var happiness := HAPPINESS_BASE
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

## 随机事件（GameEvents）：autotest 等可关闭。
## event_weights：各事件 id → 权重倍率（默认见 GameEvents.WEIGHT_DEFAULTS，1.0=设计基准）。
## 键：fire / plague / food_shortage / cold_snap（负面），good_harvest / traveling_merchant（正面），refugees（春季 try_refugees）。
## >1 更易触发，<1 更 rare；只改数值不改键名。verbose=true 时 try_daily 会 print [EVENT] 诊断行。
var random_events_enabled := true
var event_weights: Dictionary = {}
var cold_snap_days := 0
var _warn_no_firewood := false
var _warn_low_clothes := false
var _warn_winter_crisis := false
var trade_manual_day := -1
var _edge_low_food := false
var _edge_room_full := false
var _edge_low_tools := false
var _edge_low_fire_prep := false

# 调试统计
var stat_meals := 0
var stat_food_in := 0.0
var dead_count := 0

func note_citizen_death() -> void:
	dead_count += 1

func citizen_label(c: Citizen) -> String:
	if c == null or not is_instance_valid(c):
		return "?"
	var i := citizens.find(c)
	if i < 0:
		return "?"
	return "居民#%d" % (i + 1)

func _ready() -> void:
	event_weights = GameEvents.WEIGHT_DEFAULTS.duplicate()
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
		_reset_season_warnings()
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

func cold_snap_active() -> bool:
	return cold_snap_days > 0

## 读档：cold_snap / 随机事件开关与权重；缺键用运行时默认（与 _ready 一致）。
func apply_save_event_fields(data: Dictionary) -> void:
	cold_snap_days = int(data.get("cold_snap_days", 0))
	random_events_enabled = bool(data.get("random_events_enabled", true))
	event_weights = GameEvents.WEIGHT_DEFAULTS.duplicate()
	var ew = data.get("event_weights", null)
	if typeof(ew) == TYPE_DICTIONARY:
		for k in ew:
			if GameEvents.WEIGHT_DEFAULTS.has(k):
				event_weights[k] = float(ew[k])

## 全局季节生产修正（与建筑 seasonal 叠乘）
func season_work_mult() -> float:
	var m: float = SEASON_WORK_MULTS[season()]
	if cold_snap_active():
		m *= 0.88
	return m

func mark_resources_dirty() -> void:
	_res_dirty = true

func _reset_season_warnings() -> void:
	_warn_no_firewood = false
	_warn_low_clothes = false
	_warn_winter_crisis = false

## 供顶栏着色（与 _new_day 预警日志同步）
func ui_winter_crisis() -> bool:
	return _warn_winter_crisis

func ui_no_firewood() -> bool:
	return _warn_no_firewood

func ui_low_clothes() -> bool:
	return _warn_low_clothes

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
	var best: Building = null
	var best_cap := 0.0
	for b in buildings:
		if not is_instance_valid(b) or not b.complete:
			continue
		var cap := float(b.def.get("capacity", 0.0))
		if cap > best_cap:
			best_cap = cap
			best = b
	return best

func food_starving_risk() -> bool:
	var pop := maxi(1, citizens.size())
	return float(stock.get("food", 0.0)) < pop * 2.0

func storage_urgent() -> bool:
	if food_starving_risk():
		return true
	return room_left() < 40.0

## 顶栏简短预警（与 _tick_resource_warnings 阈值一致）
func resource_alert_summary() -> String:
	var tags: Array[String] = []
	if ui_winter_crisis():
		tags.append("寒冬危机")
	elif ui_no_firewood():
		tags.append("缺柴")
	elif ui_low_clothes():
		tags.append("缺衣")
	if cold_snap_active():
		tags.append("寒潮")
	var pop := maxi(1, citizens.size())
	var food := float(stock.get("food", 0.0))
	if food <= 0.0:
		tags.append("缺粮")
	elif food < pop * 2.0:
		tags.append("粮紧")
	if room_left() < 40.0:
		tags.append("仓满")
	if tool_factor() < 0.75:
		tags.append("缺工具")
	var fw := float(stock.get("firewood", 0.0))
	if is_winter() and pop > 0 and fw < pop * WINTER_FIREWOOD_PER_CAPITA * 1.5:
		tags.append("缺柴")
	elif (season() == 2 or is_winter()) and fw < pop * float(DAYS_PER_SEASON) * WINTER_FIREWOOD_PER_CAPITA:
		tags.append("柴紧")
	return " · ".join(tags)

func resource_label_warn(res: String) -> bool:
	var pop := maxi(1, citizens.size())
	match res:
		"food":
			var food := float(stock.get("food", 0.0))
			return food <= 0.0 or food < pop * 2.0
		"firewood":
			var fw := float(stock.get("firewood", 0.0))
			if ui_no_firewood() or ui_winter_crisis():
				return true
			if is_winter() and pop > 0 and fw < pop * WINTER_FIREWOOD_PER_CAPITA * 1.5:
				return true
			return (season() == 2 or is_winter()) and fw < pop * float(DAYS_PER_SEASON) * WINTER_FIREWOOD_PER_CAPITA
		"tools":
			return tool_factor() < 0.75
		_:
			return false

## 有商人值守的贸易站
func staffed_trade() -> Building:
	for b in buildings:
		if is_instance_valid(b) and b.complete and bool(b.def.get("trade", false)) and not b.workers.is_empty():
			return b
	return null

func trade_days_until_auto() -> int:
	if staffed_trade() == null:
		return -1
	var d := total_days() % TRADE_INTERVAL
	return 0 if d == 0 else TRADE_INTERVAL - d

func _trade_pick_sell() -> String:
	var sell := ""
	var best := 60.0
	for r in TRADE_SELL_KEYS:
		var amt := float(stock.get(r, 0.0))
		if amt > best:
			best = amt
			sell = r
	return sell

func trade_buy_label(res_id: String) -> String:
	if res_id == "food":
		return "种子→食物"
	return RES_ZH.get(res_id, res_id)

func trade_buy_catalog() -> Array:
	var pick := _trade_pick_buy()
	var amt := TRADE_SELL_AMOUNT * TRADE_BUY_RATIO
	var rows: Array = []
	for id in TRADE_BUY_KEYS:
		rows.append({
			"id": id,
			"label": trade_buy_label(id),
			"amount": amt,
			"active": id == pick,
		})
	return rows

func trade_need_firewood() -> bool:
	var pop := maxi(1, citizens.size())
	var fw := float(stock.get("firewood", 0.0))
	if ui_no_firewood() or ui_winter_crisis():
		return true
	if is_winter() and pop > 0 and fw < pop * WINTER_FIREWOOD_PER_CAPITA * 1.5:
		return true
	return (season() == 2 or is_winter()) and fw < pop * float(DAYS_PER_SEASON) * WINTER_FIREWOOD_PER_CAPITA

func trade_need_stone() -> bool:
	var pop := maxi(1, citizens.size())
	return float(stock.get("stone", 0.0)) < maxf(50.0, float(pop) * 3.0)

func _trade_pick_buy() -> String:
	if food_starving_risk():
		return "food"
	if trade_need_firewood():
		return "firewood"
	if trade_need_stone():
		return "stone"
	if float(stock.get("tools", 0.0)) > float(stock.get("clothes", 0.0)):
		return "clothes"
	return "tools"

func trade_preview() -> Dictionary:
	var sell := _trade_pick_sell()
	var buy := _trade_pick_buy()
	var staffed := staffed_trade() != null
	var can := staffed and sell != "" and float(stock.get(sell, 0.0)) + 0.001 >= TRADE_SELL_AMOUNT
	return {
		"sell": sell,
		"buy": buy,
		"sell_amount": TRADE_SELL_AMOUNT,
		"buy_amount": TRADE_SELL_AMOUNT * TRADE_BUY_RATIO,
		"can_run": can,
		"buy_catalog": trade_buy_catalog(),
	}

func can_manual_trade() -> bool:
	if trade_manual_day == total_days():
		return false
	var prev: Dictionary = trade_preview()
	return bool(prev.get("can_run", false))

func try_manual_trade() -> bool:
	if not can_manual_trade():
		return false
	if _run_trade(true):
		trade_manual_day = total_days()
		return true
	return false

func tick_trade() -> void:
	if total_days() % TRADE_INTERVAL != 0:
		return
	_run_trade(false)

func _run_trade(manual: bool) -> bool:
	if staffed_trade() == null:
		return false
	var prev: Dictionary = trade_preview()
	if not bool(prev.get("can_run", false)):
		return false
	var sell := str(prev["sell"])
	var buy := str(prev["buy"])
	var amount := TRADE_SELL_AMOUNT
	if not take(sell, amount):
		return false
	add(buy, amount * TRADE_BUY_RATIO)
	var tag := "手动" if manual else "自动"
	log_msg("贸易站（%s）：卖出 %d %s，换回 %.0f %s" % [
		tag, int(amount), RES_ZH.get(sell, sell), amount * TRADE_BUY_RATIO, trade_buy_label(buy)])
	return true

func tick_happiness() -> void:
	var has_tavern := false
	for b in buildings:
		if is_instance_valid(b) and b.complete and b.def_id == "tavern" and not b.workers.is_empty():
			has_tavern = true
			break
	var target := HAPPINESS_BASE
	if has_tavern:
		target = minf(100.0, happiness + HAPPINESS_TAVERN_DRIFT)
	else:
		target = maxf(0.0, happiness - HAPPINESS_NO_TAVERN_DRIFT)
	happiness = move_toward(happiness, target, HAPPINESS_MOVE_SPEED)

func tool_efficiency_pct() -> int:
	return int(round(tool_factor() * 100.0))

func cloth_stress_label() -> String:
	if not is_winter() and cloth_factor() <= 1.001:
		return ""
	if cloth_factor() > 1.001:
		return "衣物偏紧×%.1f" % cloth_factor()
	return "衣物充足"

## 有医生值守的医院
func active_hospital() -> Building:
	for b in buildings:
		if is_instance_valid(b) and b.complete and b.is_hospital() and not b.workers.is_empty():
			return b
	return null

func adult_age_days() -> int:
	return ADULT_AGE_YEARS * DAYS_PER_YEAR

## 建成的教堂：不占工人，缓慢提升全城健康
func has_church() -> bool:
	for b in buildings:
		if is_instance_valid(b) and b.complete and bool(b.def.get("church", false)):
			return true
	return false

## 学童干活系数：半径内开课学堂用 child_work_mult，否则 CHILD_WORK_MULT
func child_work_mult(c) -> float:
	if not is_instance_valid(c) or not c.is_child():
		return CHILD_WORK_MULT
	var b: Building = Building.school_covering(c.global_position)
	if b != null:
		return float(b.def.get("child_work_mult", 0.75))
	return CHILD_WORK_MULT

func tick_school_upkeep() -> void:
	for b in buildings:
		if not is_instance_valid(b) or not b.complete or not b.is_school():
			continue
		b.school_running = false
		var up: Dictionary = b.def.get("upkeep", {})
		if up.is_empty():
			b.school_running = true
			continue
		var ok := true
		for k in up:
			if float(stock.get(k, 0.0)) < float(up[k]):
				ok = false
				break
		if not ok:
			continue
		for k in up:
			take(k, float(up[k]))
		b.school_running = true

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
	return 1.0 if float(stock.get("clothes", 0.0)) >= need else CLOTH_FIRE_STRESS

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

func occupied_home_slots() -> int:
	var n := 0
	for c in citizens:
		if is_instance_valid(c) and not c.dead and c.home != null:
			n += 1
	return n

func free_homes() -> int:
	return maxi(0, home_capacity() - occupied_home_slots())

func log_msg(text: String) -> void:
	if verbose:
		print("[LOG] ", text)
	log_message.emit(text)

# ---------------------------------------------------------------- 每日结算

func _new_day() -> void:
	if cold_snap_days > 0:
		cold_snap_days -= 1

	tick_school_upkeep()

	var pop := citizens.size()
	if pop > 0:
		# 工具与衣物磨损
		stock["tools"] = maxf(0.0, float(stock.get("tools", 0.0)) - pop * DAILY_TOOL_WEAR)
		stock["clothes"] = maxf(0.0, float(stock.get("clothes", 0.0)) - pop * DAILY_CLOTHES_WEAR)
		if float(stock.get("tools", 0.0)) <= 0.0 and total_days() % 6 == 0:
			log_msg("工具耗尽，生产效率下降！")
		# 食物由居民自己回家吃饭消耗（见 Citizen._rest），这里只结算冬季取暖。
		var fire_ratio := 1.0
		if is_winter():
			var need_fire := pop * WINTER_FIREWOOD_PER_CAPITA
			if cold_snap_active():
				need_fire *= COLD_SNAP_FIRE_MULT
			var got_fire := minf(need_fire, float(stock.get("firewood", 0.0)))
			stock["firewood"] = float(stock.get("firewood", 0.0)) - got_fire
			fire_ratio = got_fire / need_fire if need_fire > 0.0 else 1.0
			var low_clothes := float(stock.get("clothes", 0.0)) < pop * 0.5
			var no_fire := got_fire <= 0.0
			if low_clothes and no_fire:
				if not _warn_winter_crisis:
					log_msg("寒冬双重打击：柴火与衣物都不足（取暖×%.1f），健康迅速下滑。" % cloth_factor())
					_warn_winter_crisis = true
			else:
				_warn_winter_crisis = false
				if no_fire:
					if not _warn_no_firewood:
						log_msg("柴火耗尽，居民正在挨冻！")
						_warn_no_firewood = true
				else:
					_warn_no_firewood = false
				if low_clothes:
					if not _warn_low_clothes:
						log_msg("衣物不足，居民这个冬天更难熬（取暖消耗×%.1f）。" % cloth_factor())
						_warn_low_clothes = true
				else:
					_warn_low_clothes = false
		else:
			_warn_no_firewood = false
			_warn_low_clothes = false
			_warn_winter_crisis = false

		for c in citizens.duplicate():
			if is_instance_valid(c) and not c.dead:
				c.age += 1
				c.daily_update(fire_ratio, is_winter())
		var sc := sick_count()
		if sc > 0 and total_days() % 3 == 0:
			var cared := active_hospital() != null
			log_msg("病号 %d 人%s。" % [sc, "，医院在照料" if cared else "，尚无医院值守"])
		_tick_resource_warnings(pop)
		_res_dirty = true

	day_passed.emit(total_days())

func _tick_resource_warnings(pop: int) -> void:
	if pop <= 0:
		return
	var food := float(stock.get("food", 0.0))
	var low_food := food < pop * 2.0
	if low_food and not _edge_low_food:
		if food <= 0.0:
			log_msg("粮库已空，居民正在挨饿！")
		else:
			log_msg("食物储备偏低（%d），注意饿死风险。" % int(food))
		_edge_low_food = true
	elif not low_food:
		_edge_low_food = false

	var left := room_left()
	if left < 30.0 and not _edge_room_full:
		log_msg("仓库几乎满了，剩余空位 %.0f。" % left)
		_edge_room_full = true
	elif left >= 40.0:
		_edge_room_full = false

	var tf := tool_factor()
	if tf < 0.75 and not _edge_low_tools:
		log_msg("工具短缺，生产效率约 %d%%。" % int(round(tf * 100.0)))
		_edge_low_tools = true
	elif tf >= 0.75:
		_edge_low_tools = false

	var fire := float(stock.get("firewood", 0.0))
	var need_winter := pop * float(DAYS_PER_SEASON) * WINTER_FIREWOOD_PER_CAPITA
	var fire_low_prep := (season() == 2 or is_winter()) and fire < need_winter
	if fire_low_prep and not _edge_low_fire_prep:
		log_msg("柴火储备不足（%d），入冬前多囤柴。" % int(fire))
		_edge_low_fire_prep = true
	elif not fire_low_prep:
		_edge_low_fire_prep = false

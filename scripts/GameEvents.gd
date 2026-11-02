class_name GameEvents
extends RefCounted
## 轻量随机事件：权重可配，由 Main 每日调用。每日最多触发 1 条。

const WEIGHT_DEFAULTS := {
	"fire": 1.0,
	"plague": 1.0,
	"food_shortage": 1.0,
	"cold_snap": 1.0,
	"good_harvest": 1.0,
	"traveling_merchant": 1.0,
	"refugees": 1.0,
}

## 基准日概率（× event_weights × 前期负面系数）；建成建筑 <3 时不触发任何事件
const BASE_FIRE_SUMMER := 0.006
const BASE_FIRE_OTHER := 0.0015
const BASE_PLAGUE := 0.006
const BASE_FOOD_SHORTAGE := 0.008
const BASE_COLD_SNAP := 0.005
const BASE_GOOD_HARVEST := 0.014
const BASE_MERCHANT := 0.009
const BASE_REFUGEES := 0.004


static func chance(base: float, key: String, weights: Dictionary) -> float:
	return base * float(weights.get(key, WEIGHT_DEFAULTS.get(key, 1.0)))


## 前期负面事件衰减：建筑少、开局日数短时降低连灾概率（<3 栋已在 try_daily 拦截）
static func _negative_risk_mult() -> float:
	var n := GameState.buildings.size()
	var mult := 1.0
	if n <= 5:
		mult *= 0.55
	elif n <= 8:
		mult *= 0.78
	var day := GameState.total_days()
	if day < 12:
		mult *= 0.65
	elif day < 24:
		mult *= 0.85
	return mult


static func try_daily(rng: RandomNumberGenerator) -> void:
	if not GameState.random_events_enabled:
		return
	if GameState.buildings.size() < 3:
		return
	var w := GameState.event_weights
	var s := GameState.season()
	var risk := _negative_risk_mult()
	if GameState.verbose:
		print("[EVENT] day=%d %s risk_mult=%.2f weights=%s" % [
			GameState.total_days(), GameState.season_name(), risk, str(w)])

	# 正面事件优先判定（不与负面叠在同日链式 roll 里抢顺序）
	if (s == 0 or s == 2) and rng.randf() < chance(BASE_GOOD_HARVEST, "good_harvest", w):
		_good_harvest(rng)
		_log_trigger("good_harvest", chance(BASE_GOOD_HARVEST, "good_harvest", w))
		return
	if rng.randf() < chance(BASE_MERCHANT, "traveling_merchant", w):
		_traveling_merchant(rng)
		_log_trigger("traveling_merchant", chance(BASE_MERCHANT, "traveling_merchant", w))
		return

	var fire_base := BASE_FIRE_SUMMER if (s == 1 or s == 2) else BASE_FIRE_OTHER
	var p_fire := chance(fire_base, "fire", w) * risk
	if rng.randf() < p_fire:
		_try_fire(rng)
		_log_trigger("fire", p_fire)
		return
	var p_plague := chance(BASE_PLAGUE, "plague", w) * risk
	if GameState.citizens.size() <= 4:
		p_plague *= 0.5
	if rng.randf() < p_plague:
		_outbreak(rng)
		_log_trigger("plague", p_plague)
		return
	var food_base := BASE_FOOD_SHORTAGE
	if float(GameState.stock.get("food", 0.0)) < float(GameState.citizens.size()) * 6.0:
		food_base *= 1.6
	var p_food := chance(food_base, "food_shortage", w) * risk
	if rng.randf() < p_food:
		_food_shortage()
		_log_trigger("food_shortage", p_food)
		return
	if s == 3 and GameState.cold_snap_days <= 0:
		var p_cold := chance(BASE_COLD_SNAP, "cold_snap", w) * risk
		if rng.randf() < p_cold:
			_cold_snap()
			_log_trigger("cold_snap", p_cold)


static func _log_trigger(id: String, p: float) -> void:
	if GameState.verbose:
		print("[EVENT] triggered=%s p≈%.4f" % [id, p])


static func _try_fire(rng: RandomNumberGenerator) -> void:
	var candidates: Array = []
	for b in GameState.buildings:
		if is_instance_valid(b) and b.complete and not b.is_road():
			candidates.append(b)
	if candidates.is_empty():
		return
	var b: Building = candidates[rng.randi_range(0, candidates.size() - 1)]
	if Building.covered_by_well(b) and rng.randf() < Building.WELL_IGNITE_BLOCK:
		if GameState.verbose:
			print("[EVENT] fire blocked by well @ ", b.def_id)
		return
	b.ignite()


static func _outbreak(rng: RandomNumberGenerator) -> void:
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


static func _food_shortage() -> void:
	var pop := GameState.citizens.size()
	if pop <= 0:
		return
	var have := float(GameState.stock.get("food", 0.0))
	var spoil := minf(have, float(pop) * 6.0) * 0.12
	if spoil > 0.5:
		GameState.stock["food"] = have - spoil
		GameState.mark_resources_dirty()
	GameState.happiness = maxf(0.0, GameState.happiness - 5.0)
	GameState.log_msg("缺粮危机！部分粮食变质，请尽快补充储备。")


static func _cold_snap() -> void:
	GameState.cold_snap_days = 3
	GameState.log_msg("寒潮来袭！数日内取暖需求上升，野外生产略放缓。")


static func _good_harvest(rng: RandomNumberGenerator) -> void:
	var pop := maxi(1, GameState.citizens.size())
	var bonus := maxf(24.0, float(pop) * 7.0 + rng.randf_range(8.0, 28.0))
	GameState.add("food", bonus)
	GameState.happiness = minf(100.0, GameState.happiness + 3.0)
	GameState.log_msg("丰收喜讯！额外入库约 %d 食物，士气上扬。" % int(bonus))


static func _traveling_merchant(rng: RandomNumberGenerator) -> void:
	var tools := rng.randf_range(4.0, 9.0)
	GameState.add("tools", tools)
	var extra := ""
	if rng.randf() < 0.35:
		var cloth := rng.randf_range(2.0, 5.0)
		GameState.add("clothes", cloth)
		extra = "，顺带补了 %.0f 衣物" % cloth
	GameState.log_msg("行商路过，贱卖 %.0f 工具%s。" % [tools, extra])


## 春季小概率难民；由 Main._spawn_refugees 调用，返回应接纳人数 0~2
static func try_refugees(rng: RandomNumberGenerator) -> int:
	if not GameState.random_events_enabled:
		return 0
	if GameState.season() != 0:
		return 0
	if GameState.free_homes() < 2:
		return 0
	var pop := maxi(1, GameState.citizens.size())
	if float(GameState.stock.get("food", 0.0)) < 80.0 + pop * 2.5:
		return 0
	var w := GameState.event_weights
	if rng.randf() >= chance(BASE_REFUGEES, "refugees", w):
		return 0
	return mini(2, GameState.free_homes())

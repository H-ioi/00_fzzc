# -*- coding: utf-8 -*-
from pathlib import Path

ROOT = Path(r"D:\01_code\00_fzzc")


def patch(path: Path, replacements: list[tuple[str, str]], nl: str) -> None:
    text = path.read_text(encoding="utf-8")
    # normalize to \n for matching, restore later
    original = text
    had_crlf = "\r\n" in text
    text = text.replace("\r\n", "\n")
    for old, new in replacements:
        old_n = old.replace("\r\n", "\n")
        new_n = new.replace("\r\n", "\n")
        count = text.count(old_n)
        if count != 1:
            raise SystemExit(f"{path.name}: expected 1 match, got {count} for:\n---\n{old_n[:180]}\n---")
        text = text.replace(old_n, new_n, 1)
    out = text.replace("\n", "\r\n") if had_crlf else text
    path.write_text(out, encoding="utf-8", newline="")
    print(f"patched {path}")


# ---------------- GameState.gd (CRLF) ----------------
gs = ROOT / "scripts" / "GameState.gd"
patch(gs, [
(
"""const ADULT_AGE_YEARS := 16
const CHILD_WORK_MULT := 0.55
""",
"""const ADULT_AGE_YEARS := 16
const WORK_AGE_YEARS := 4
const FERTILE_END_YEARS := 40
const ELDER_AGE_YEARS := 60
const ELDER_WORK_MULT := 0.75
const OLD_AGE_YEARS := 70
const MAX_AGE_YEARS := 84
const CHILD_WORK_MULT := 0.55
"""
),
(
"""func adult_age_days() -> int:
	return ADULT_AGE_YEARS * DAYS_PER_YEAR

## 建成的教堂：不占工人，缓慢提升全城健康
""",
"""func adult_age_days() -> int:
	return ADULT_AGE_YEARS * DAYS_PER_YEAR

func work_age_days() -> int:
	return WORK_AGE_YEARS * DAYS_PER_YEAR

func fertile_end_days() -> int:
	return FERTILE_END_YEARS * DAYS_PER_YEAR

func elder_age_days() -> int:
	return ELDER_AGE_YEARS * DAYS_PER_YEAR

func old_age_days() -> int:
	return OLD_AGE_YEARS * DAYS_PER_YEAR

func max_age_days() -> int:
	return MAX_AGE_YEARS * DAYS_PER_YEAR

## 70 岁起逐日上升，满 84 岁必然去世。
func old_age_death_chance(age_days: int) -> float:
	if age_days < old_age_days():
		return 0.0
	if age_days >= max_age_days():
		return 1.0
	var span := float(max_age_days() - old_age_days())
	var u := float(age_days - old_age_days()) / span
	return lerpf(0.006, 0.08, u * u)

## 建成的教堂：不占工人，缓慢提升全城健康
"""
),
(
"""		for c in citizens.duplicate():
			if is_instance_valid(c) and not c.dead:
				c.age += 1
				c.daily_update(fire_ratio, is_winter())
""",
"""		for c in citizens.duplicate():
			if is_instance_valid(c) and not c.dead:
				var prev_age := c.age
				c.age += 1
				if prev_age < work_age_days() and c.age >= work_age_days():
					log_msg("一名幼童到了上工的年纪。")
				if prev_age < adult_age_days() and c.age >= adult_age_days():
					log_msg("一名学童成年了。")
				c.apply_age_visual()
				c.daily_update(fire_ratio, is_winter())
"""
),
], "\r\n")

# ---------------- Citizen.gd (LF) ----------------
ct = ROOT / "scripts" / "Citizen.gd"
patch(ct, [
(
"""## 存活天数（每日 +1）；未满 16 岁为儿童，生产效率折减。
var age := 0
""",
"""## 存活天数（每日 +1）。未满 4 岁为幼童，不能上工；未满 16 岁为学童，效率折减。
var age := 0
var death_reason := ""
var _base_height := 1.0
"""
),
(
"""	if health <= 0.0:
		_die()

func infect(days: int) -> void:
""",
"""	if health <= 0.0:
		_die("health")
		return
	var p := GameState.old_age_death_chance(age)
	if p > 0.0 and randf() < p:
		_die("old")

func infect(days: int) -> void:
"""
),
(
"""	if sick > 0 and state in [St.TO_WORK, St.WORK, St.TO_BUILD, St.BUILD]:
		_go_home()
		return
""",
"""	if (sick > 0 or not can_work()) and state in [St.TO_WORK, St.WORK, St.TO_BUILD, St.BUILD]:
		_go_home()
		return
"""
),
(
"""func _go_work() -> void:
	if sick > 0:
		_go_home()
		return
""",
"""func _go_work() -> void:
	if sick > 0 or not can_work():
		_go_home()
		return
"""
),
(
"""func _go_build() -> void:
	if sick > 0:
		_go_home()
		return
""",
"""func _go_build() -> void:
	if sick > 0 or not can_work():
		_go_home()
		return
"""
),
(
"""func is_child() -> bool:
	return age < GameState.adult_age_days()

func work_efficiency() -> float:
	var m := GameState.tool_factor() * GameState.mood_factor()
	if sick > 0:
		m *= 0.55
	if is_child():
		m *= GameState.child_work_mult(self)
	return m
""",
"""func is_infant() -> bool:
	return age < GameState.work_age_days()

func is_child() -> bool:
	return age < GameState.adult_age_days()

func is_elder() -> bool:
	return age >= GameState.elder_age_days()

func is_fertile() -> bool:
	return not dead and age >= GameState.adult_age_days() and age < GameState.fertile_end_days()

func can_work() -> bool:
	return not dead and sick <= 0 and not is_infant()

func work_efficiency() -> float:
	if is_infant():
		return 0.0
	var m := GameState.tool_factor() * GameState.mood_factor()
	if sick > 0:
		m *= 0.55
	if is_child():
		m *= GameState.child_work_mult(self)
	elif is_elder():
		m *= GameState.ELDER_WORK_MULT
	return m

func apply_age_visual() -> void:
	var s := _base_height * _age_body_scale()
	if _model != null and is_instance_valid(_model):
		scale = Vector3.ONE
		_model.scale = Vector3(s, s, s)
	else:
		scale = Vector3(s, s, s)

func _age_body_scale() -> float:
	var work := GameState.work_age_days()
	var adult := GameState.adult_age_days()
	if age < work:
		return lerpf(0.52, 0.72, float(age) / float(maxi(1, work)))
	if age < adult:
		return lerpf(0.72, 1.0, float(age - work) / float(maxi(1, adult - work)))
	if is_elder():
		return 0.96
	return 1.0
"""
),
(
"""func _resume_after_meal() -> void:
	if sick > 0:
		return
""",
"""func _resume_after_meal() -> void:
	if sick > 0 or not can_work():
		_set_state(St.IDLE)
		return
"""
),
(
"""			var height_scale := randf_range(0.93, 1.07)
			_model.scale = Vector3(height_scale, height_scale, height_scale)
""",
"""			var height_scale := randf_range(0.93, 1.07)
			_base_height = height_scale
			_model.scale = Vector3(height_scale, height_scale, height_scale)
"""
),
(
"""func role_text() -> String:
	if workplace == null:
		return "闲置"
	return str(workplace.def.get("name", "工人"))

func _die() -> void:
	if dead:
		return
	dead = true
	died.emit(self)
""",
"""func role_text() -> String:
	if is_infant():
		return "幼童"
	if workplace == null:
		if is_child():
			return "学童"
		if is_elder():
			return "老人"
		return "闲置"
	return str(workplace.def.get("name", "工人"))

func _die(reason: String = "") -> void:
	if dead:
		return
	dead = true
	death_reason = reason
	died.emit(self)
"""
),
], "\n")

print("Citizen and GameState done")

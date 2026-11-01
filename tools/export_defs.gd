extends SceneTree
## 把内置建筑表导出成 data/buildings.json（Mod 数据外置）。
## 用法：godot --headless --path . --script res://tools/export_defs.gd
## 导出后 JSON 就是权威数据，改数值直接改 JSON，不用碰代码。

func _init() -> void:
	# 强制从内置表导出（忽略已有 JSON，避免导出旧数据覆盖新改动）
	BuildingDefs.DEFS = BuildingDefs._BUILTIN.duplicate(true)
	var out: Dictionary = {}
	for id in BuildingDefs.DEFS:
		out[id] = _to_jsonable(BuildingDefs.DEFS[id])

	DirAccess.make_dir_recursive_absolute("res://data")
	var f := FileAccess.open("res://data/buildings.json", FileAccess.WRITE)
	if f == null:
		print("FAILED to open data/buildings.json")
		quit()
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	print("EXPORTED ", out.size(), " building defs -> res://data/buildings.json")
	quit()

func _to_jsonable(d: Dictionary) -> Dictionary:
	var o: Dictionary = {}
	for k in d:
		var v = d[k]
		match str(k):
			"size":
				o[k] = [v.x, v.y]
			"color", "roof":
				o[k] = [v.r, v.g, v.b]
			_:
				o[k] = v
	return o

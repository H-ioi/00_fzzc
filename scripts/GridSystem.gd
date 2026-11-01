class_name GridSystem
extends RefCounted
## 方格地图：建筑占位 + AStarGrid2D 寻路。
## 世界坐标与格子坐标的换算全部集中在这里。

const CELL := 2.0

var map_size: int = 64
var astar: AStarGrid2D
var occupied: Dictionary = {}   # Vector2i -> Building
var road_cells: Dictionary = {}
var border_cells: Dictionary = {}
var water_cells: Dictionary = {}
var heights := PackedFloat32Array()

const ROAD_WEIGHT := 0.55

func _init(n: int = 64) -> void:
	map_size = n
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, map_size, map_size)
	astar.cell_size = Vector2(CELL, CELL)
	astar.offset = Vector2(CELL * 0.5, CELL * 0.5)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	astar.update()

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < map_size and c.y < map_size

func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL)), int(floor(p.z / CELL)))

func cell_center(c: Vector2i) -> Vector3:
	return Vector3((c.x + 0.5) * CELL, height_at_cell(c), (c.y + 0.5) * CELL)

# ---------------------------------------------------------------- 高度场

func build_heights(fn: Callable) -> void:
	heights.resize(map_size * map_size)
	for z in map_size:
		for x in map_size:
			heights[z * map_size + x] = float(fn.call((x + 0.5) * CELL, (z + 0.5) * CELL))

func has_heights() -> bool:
	return heights.size() == map_size * map_size

func height_at_cell(c: Vector2i) -> float:
	if heights.is_empty() or not in_bounds(c):
		return 0.0
	return heights[c.y * map_size + c.x]

func _h_clamped(x: int, z: int) -> float:
	x = clampi(x, 0, map_size - 1)
	z = clampi(z, 0, map_size - 1)
	return heights[z * map_size + x]

func height_at_world(x: float, z: float) -> float:
	if heights.is_empty():
		return 0.0
	var fx := x / CELL - 0.5
	var fz := z / CELL - 0.5
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var tz := clampf(fz - float(z0), 0.0, 1.0)
	var h00 := _h_clamped(x0, z0)
	var h10 := _h_clamped(x0 + 1, z0)
	var h01 := _h_clamped(x0, z0 + 1)
	var h11 := _h_clamped(x0 + 1, z0 + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

## 占地范围内的高差，用来限制陡坡上建造
func slope_in(cell: Vector2i, size: Vector2i) -> float:
	var hi := -9999.0
	var lo := 9999.0
	for x in size.x:
		for y in size.y:
			var c := cell + Vector2i(x, y)
			var h := height_at_cell(c)
			hi = maxf(hi, h)
			lo = minf(lo, h)
	return hi - lo

func set_solid(cell: Vector2i, size: Vector2i, solid: bool) -> void:
	for x in size.x:
		for y in size.y:
			var c := cell + Vector2i(x, y)
			if in_bounds(c):
				astar.set_point_solid(c, solid)

func is_free_cell(c: Vector2i) -> bool:
	return in_bounds(c) and not astar.is_point_solid(c)

func nearest_free_cell(c: Vector2i, radius: int = 8) -> Vector2i:
	if is_free_cell(c):
		return c
	for r in range(1, radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var n := c + Vector2i(dx, dy)
				if is_free_cell(n):
					return n
	return Vector2i(-1, -1)

func nearest_free_point(world: Vector3) -> Vector3:
	var c := world_to_cell(world)
	var n := nearest_free_cell(c)
	if n.x < 0:
		return world
	return cell_center(n)

## 返回世界坐标路径点（不含起点）。空数组表示无法到达。
func find_path(from_world: Vector3, to_world: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var a := world_to_cell(from_world)
	var b := world_to_cell(to_world)
	if not in_bounds(a) or not in_bounds(b):
		return result
	if astar.is_point_solid(a):
		a = nearest_free_cell(a)
	if astar.is_point_solid(b):
		b = nearest_free_cell(b)
	if a.x < 0 or b.x < 0:
		return result
	var ids := astar.get_id_path(a, b)
	for id in ids:
		var p := astar.get_point_position(id)
		result.append(Vector3(p.x, 0.0, p.y))
	if not result.is_empty():
		result.remove_at(0)
	return result

func is_road(c: Vector2i) -> bool:
	return bool(road_cells.get(c, false))

## 地图外圈是沙滩/水岸，不可建造也不可通行
func set_border(width: int) -> void:
	for x in map_size:
		for y in map_size:
			if x < width or y < width or x >= map_size - width or y >= map_size - width:
				var c := Vector2i(x, y)
				border_cells[c] = true
				astar.set_point_solid(c, true)

func is_border(c: Vector2i) -> bool:
	return border_cells.has(c)

## 低于水位的格子不可通行、不可建造
func mark_water(level: float) -> void:
	for z in map_size:
		for x in map_size:
			var c := Vector2i(x, z)
			if height_at_cell(c) < level - 0.12:
				water_cells[c] = true
				astar.set_point_solid(c, true)

func is_water(c: Vector2i) -> bool:
	return water_cells.has(c)

func set_road(c: Vector2i, on: bool) -> void:
	if not in_bounds(c):
		return
	road_cells[c] = on
	astar.set_point_weight_scale(c, ROAD_WEIGHT if on else 1.0)

func footprint_free(cell: Vector2i, size: Vector2i) -> bool:
	for x in size.x:
		for y in size.y:
			var c := cell + Vector2i(x, y)
			if not in_bounds(c):
				return false
			if occupied.has(c):
				return false
			if border_cells.has(c):
				return false
			if water_cells.has(c):
				return false
	return true

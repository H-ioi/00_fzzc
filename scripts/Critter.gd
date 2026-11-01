class_name Critter
extends Node3D
## 村里闲逛的小动物：随机走动、停下、再走。

var target := Vector3.ZERO
var wait := 0.0
var speed := 0.8
var bob_speed := 9.0
var _t := 0.0
var _body: Node3D

func setup(scene: PackedScene, home: Vector3, spd: float) -> void:
	speed = spd
	_body = scene.instantiate()
	add_child(_body)
	ModelPaint.apply(_body)
	position = home
	_t = randf() * 10.0
	_pick_target()

func _pick_target() -> void:
	var a := randf() * TAU
	var r := randf_range(2.0, 7.0)
	var p := position + Vector3(cos(a) * r, 0.0, sin(a) * r)
	if GameState.grid != null:
		p.y = GameState.grid.height_at_world(p.x, p.z)
	target = p

func _process(delta: float) -> void:
	if _body == null or GameState.grid == null:
		return
	_t += delta
	if wait > 0.0:
		wait -= delta
		_body.position.y = 0.0
		# 停着的时候啄食/摇头
		_body.rotation.z = sin(_t * 6.0) * 0.06
		return
	_body.rotation.z = 0.0
	var to := target - position
	to.y = 0.0
	var d := to.length()
	if d < 0.3:
		wait = randf_range(0.9, 3.5)
		_pick_target()
		return
	var dir := to / d
	position += dir * speed * delta
	position.y = GameState.grid.height_at_world(position.x, position.z)
	# 模型正面朝 +Z，所以朝向直接用 atan2(dir.x, dir.z)
	rotation.y = atan2(dir.x, dir.z)
	_body.position.y = absf(sin(_t * bob_speed)) * 0.045

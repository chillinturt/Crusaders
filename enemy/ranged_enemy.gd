class_name RangedEnemy
extends Enemy
## "Spitter": keeps its distance and lobs slow glowing projectiles.
## Startup: it stops, tracks you, and charges a growing orb above its head; when
## the orb is full it fires at where you are *then*. Strafe to dodge, or hit the
## projectile with any melee swing to send it back at double damage.

@export var projectile_scene: PackedScene
## Backs away if you're closer than this...
@export var preferred_min_range := 8.0
## ...and closes in if you're further than this (but shoots from up to attack_range).
@export var preferred_max_range := 15.0
## It only counts you as in sight when the shot's own path (from the orb) is
## clear too, so it repositions instead of firing into window frames. Off for
## lobbed shots.
@export var needs_clear_shot := true

## The charging shot (anywhere under Visual: some models mount it on a turret).
@onready var _orb: Node3D = $Visual.find_child("Orb", true, false)

var _vantage := Vector3.ZERO
var _vantage_until := 0


func _ready() -> void:
	super()
	_orb.scale = Vector3.ONE * 0.01


## With a shot on you already, it stays where it is.
func _takes_portals() -> bool:
	return not _can_see and super()


func _has_line_of_sight() -> bool:
	if not super():
		return false
	if not needs_clear_shot:
		return true
	var query := PhysicsRayQueryParameters3D.create(_orb.global_position, _player.global_position + Vector3.UP * 1.1)
	query.collision_mask = 1
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _chase_move_dir(flat_to_target: Vector3) -> Vector3:
	var dist := flat_to_target.length()
	if not _can_see:
		return super(flat_to_target)  # no shot from here: close in (toward a spot with one)
	if dist < preferred_min_range:
		return -flat_to_target.normalized()
	if dist > preferred_max_range:
		return flat_to_target.normalized()
	return Vector3.ZERO


## No line to you: rather than walking right up to you, it heads for a
## spot at its shooting distance that has a clear line to you.
func _approach_goal(target: Vector3) -> Vector3:
	if _can_see:
		return target
	var now := Time.get_ticks_msec()
	if now >= _vantage_until:
		_vantage_until = now + 1500
		_vantage = _find_vantage(target)
	return _vantage


## The nearest open spot around `target` with line of sight to it (or `target`
## itself if there's none).
func _find_vantage(target: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var aim := target + Vector3.UP * 1.5
	var best := target
	var best_cost := INF
	for radius: float in [preferred_max_range, (preferred_min_range + preferred_max_range) * 0.5, preferred_max_range * 1.5]:
		for step in 12:
			var offset := Vector2.from_angle(step * TAU / 12.0) * radius
			var spot := Vector3(target.x + offset.x, 0.0, target.z + offset.y)
			if not nav.is_open(spot) or (world_bounds.has_area() and not world_bounds.grow(-5.0).has_point(Vector2(spot.x, spot.z))):
				continue
			spot.y = nav.ground_height(spot.x, spot.z)
			var cost := global_position.distance_to(spot)
			if cost >= best_cost:
				continue
			var query := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * eye_height, aim)
			query.collision_mask = 1
			if space.intersect_ray(query).is_empty():
				best = spot
				best_cost = cost
	return best


func _can_start_attack(to_target: Vector3) -> bool:
	return _can_see and to_target.length() < attack_range


func _on_windup_start() -> void:
	if _pose_tween:
		_pose_tween.kill()
	_pose_tween = create_tween()
	_pose_tween.tween_property(_orb, "scale", Vector3.ONE, windup_time)


func _during_windup(_delta: float) -> void:
	# Unlike melee, it keeps aiming while charging; you dodge the shot, not the windup.
	if is_instance_valid(_player):
		var flat := _player.global_position - global_position
		flat.y = 0.0
		_face(flat.normalized())


func _strike() -> void:
	if is_instance_valid(_player) and projectile_scene:
		var shot: Projectile = projectile_scene.instantiate()
		shot.damage = damage  # so the shot scales with this enemy's level
		get_parent().add_child(shot)
		_launch(shot, _orb.global_position)
	_orb.scale = Vector3.ONE * 0.01
	_set_state(State.RECOVER)
	_state_time = recover_time


## Hook: how the shot leaves. Spitters fire straight at you.
func _launch(shot: Projectile, from: Vector3) -> void:
	shot.launch(from, _player.global_position + Vector3.UP * 1.1 - from, self)


func _on_windup_cancelled() -> void:
	if _pose_tween:
		_pose_tween.kill()
	_orb.scale = Vector3.ONE * 0.01

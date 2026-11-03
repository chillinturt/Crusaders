class_name Leaper
extends Enemy
## Fast, low predator that pounces from range: a chimera (lion with a serpent
## for a tail).
##   Startup: it stops and crouches low (haunches coiled, forelegs braced, tail
##   lashing, eyes flaring) for windup_time.
##   Leap: it launches on an arc at where you were when it jumped, and hits you
##   once if it passes close enough. Sidestep or jump the pounce.
##   Landing: it's stuck recovering for land_recover_time: your opening.
##   Climbing: high ground isn't safe from it. If you're above it, it runs
##   straight at the wall or cliff in the way and scales it.
## Melee hits strong enough to stagger it cancel the crouch, like any enemy.

## Won't pounce if you're closer than this (it gets some distance first)...
@export var min_leap_range := 3.0
## ...or if you're above it by more than this.
@export var max_leap_height := 4.0
@export var leap_knockback := 9.0
## Seconds in the air for a full-range pounce (shorter hops are quicker).
@export var max_airtime := 1.0
@export var hit_radius := 1.8
@export var land_recover_time := 1.0
@export var climb_speed := 6.0

## Pivot of the body for pitching it (roughly its middle), in Visual's space.
const BODY_CENTER := Vector3(0.0, 0.75, 0.0)

@onready var _hips: Array[Node3D] = [$Visual/HipFL, $Visual/HipFR, $Visual/HipBL, $Visual/HipBR]
@onready var _tail: Node3D = $Visual/TailRoot
@onready var _jaw: Node3D = $Visual/Jaw

var _climbing := false
# The pose it's easing toward each frame, and where it is now:
# [lift, pitch, forelegs, hind legs, tail, jaw]
var _pose_now := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var _gait := 0.0
var _land_time := 0.0
var _jaw_rest := 0.0
var _climb_normal := Vector3.ZERO
var _leaping := false
var _hit_done := false
var _airtime := 0.0


func _ready() -> void:
	super()
	_jaw_rest = _jaw.rotation.x


func _chase_move_dir(flat_to_target: Vector3) -> Vector3:
	# Too close to pounce: circle out a little instead of running into you.
	if _can_see and flat_to_target.length() < min_leap_range:
		return -flat_to_target.normalized()
	return super(flat_to_target)


## You're above it and not indoors: no stairs, it heads straight for the wall.
## (If its climb took it in through a window, it uses the stairs from there.)
func _uses_routes(to_target: Vector3) -> bool:
	var indoors := nav != null and is_on_floor() and nav.building_containing(global_position) != null
	if nav != null and to_target.y > 1.5 and not indoors:
		var target := global_position + to_target
		var building := nav.building_containing(target)
		if building == null or building.level_at(target) >= building.floors:
			return false
	return super(to_target)


func _chase(delta: float) -> void:
	super(delta)
	if state != State.CHASE:
		_climbing = false
		return
	var target := _player.global_position
	var wall := _climbable_wall()
	var touching := wall != Vector3.ZERO
	if not touching and _climbing and _wall_beside(_climb_normal):
		wall = _climb_normal  # passing a window: keep going up rather than in
	# Starts when you're above it and there's no stairway to take; once on the
	# wall it goes all the way over the top (unless something overhead stops it).
	var wants_climb := _climbing or not _uses_routes(target - global_position)
	if wall != Vector3.ZERO and wants_climb and not is_on_ceiling() \
			and target.y - global_position.y > (-2.5 if _climbing else 1.0):
		_climbing = true
		_climb_normal = wall
		velocity = (-wall * 2.0 if touching else Vector3.ZERO) + Vector3.UP * climb_speed
	elif _climbing:
		_climbing = false
		if not is_on_floor():  # topped the wall: over the lip
			velocity = -_climb_normal * move_speed * 0.6 + Vector3.UP * 4.0


## Whether the wall it's climbing is still there, at its feet or above its head
## (so a window doesn't count as the top).
func _wall_beside(normal: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	for height: float in [0.2, 2.0]:
		var from := global_position + Vector3.UP * height
		var query := PhysicsRayQueryParameters3D.create(from, from - normal * 1.3)
		query.collision_mask = 1
		if not space.intersect_ray(query).is_empty():
			return true
	return false


## Horizontal normal of the wall or cliff it's pressed against (zero if none;
## other creatures don't count).
func _climbable_wall() -> Vector3:
	if not is_on_wall():
		return Vector3.ZERO
	for index in get_slide_collision_count():
		var collision := get_slide_collision(index)
		if collision.get_collider() is CharacterBody3D:
			continue
		var normal := collision.get_normal()
		if absf(normal.y) < 0.7:
			return Vector3(normal.x, 0.0, normal.z).normalized()
	return Vector3.ZERO


func _can_start_attack(to_target: Vector3) -> bool:
	var flat := Vector3(to_target.x, 0.0, to_target.z).length()
	return _can_see and is_on_floor() and flat >= min_leap_range and flat <= attack_range \
			and to_target.y < max_leap_height


func _on_windup_start() -> void:
	pass  # the crouch is part of the animation (see _process)


func _during_windup(_delta: float) -> void:
	if is_instance_valid(_player):
		var flat := _player.global_position - global_position
		flat.y = 0.0
		_face(flat.normalized())


func _strike() -> void:
	_set_state(State.RECOVER)
	if not is_instance_valid(_player):
		_state_time = recover_time
		return
	# Ballistic arc to the player's current position.
	var to_target := _player.global_position - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var t := clampf(flat.length() / attack_range, 0.5, 1.0) * max_airtime
	velocity = flat / t
	velocity.y = (to_target.y + 0.5 * gravity * t * t) / t
	_leaping = true
	_hit_done = false
	_airtime = 0.0
	_state_time = 10.0  # ends on landing


func _holds_still() -> bool:
	return not _leaping


func _during_recover(delta: float) -> void:
	if not _leaping:
		return
	_airtime += delta
	if not _hit_done and is_instance_valid(_player):
		var player_center := _player.global_position + Vector3.UP * 0.9
		if (global_position + Vector3.UP * 0.6).distance_to(player_center) < hit_radius:
			_hit_done = true
			_player.take_damage(damage, global_position)
			var knock := Vector3(velocity.x, 0.0, velocity.z).normalized() * leap_knockback + Vector3.UP * 4.0
			_player.push(knock)
	if _airtime > 0.15 and is_on_floor():
		_leaping = false
		_land_time = 0.3  # absorbs the landing
		_state_time = land_recover_time


func _on_windup_cancelled() -> void:
	pass  # it springs back out of the crouch on its own


# --- Animation ------------------------------------------------------------------

## Poses the body, legs, tail and jaw for what it's doing, easing between poses:
##   running    a bounding gallop, faster with speed
##   crouch     body low and pitched down, hind legs coiled under, forelegs
##              braced forward, tail raised and lashing, jaw open in a snarl
##   pounce     body follows its arc (nose up rising, down falling), forelegs
##              thrown forward claws first, hind legs stretched out behind,
##              tail streaming, jaws wide
##   landing    a brief absorb: low, legs bent
##   climbing   body vertical, legs scrabbling
func _process(delta: float) -> void:
	if _dead:
		return
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	_land_time = maxf(_land_time - delta, 0.0)
	var target := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var rate := 14.0
	if _leaping:
		var rising := velocity.y > 0.0
		target = PackedFloat32Array([0.0, clampf(atan2(velocity.y, maxf(flat_speed, 0.1)) * 0.7, -0.6, 0.55),
				1.25 if rising else 0.9, -1.05, 0.7, 0.6])
		rate = 22.0
	elif state == State.WINDUP:
		var lash := sin(Time.get_ticks_msec() * 0.02) * 0.18
		target = PackedFloat32Array([-0.24, -0.12, 0.55, 0.6, -0.65 + lash, 0.3])
		rate = 12.0
	elif _land_time > 0.0:
		target = PackedFloat32Array([-0.2, -0.1, 0.3, 0.4, 0.25, 0.15])
		rate = 28.0
	elif _climbing:
		_gait += delta * 14.0
		target = PackedFloat32Array([0.0, 1.3, 0.4 + sin(_gait) * 0.7, sin(_gait + PI) * 0.7, 0.5, 0.2])
	else:
		var stride := clampf(flat_speed / move_speed, 0.0, 1.0)
		_gait += delta * (4.0 + flat_speed * 1.6)
		target = PackedFloat32Array([absf(sin(_gait)) * 0.06 * stride, sin(_gait * 2.0) * 0.05 * stride,
				sin(_gait) * 0.7 * stride, sin(_gait + 2.4) * 0.7 * stride, -0.2 + sin(_gait * 0.5) * 0.15, 0.0])
	var blend := 1.0 - exp(-rate * delta)
	for i in _pose_now.size():
		_pose_now[i] = lerpf(_pose_now[i], target[i], blend)

	var tilt := Basis(Vector3.RIGHT, _pose_now[1])
	visual.transform = Transform3D(tilt, Vector3(0.0, _pose_now[0], 0.0) + BODY_CENTER - tilt * BODY_CENTER)
	_hips[0].rotation.x = _pose_now[2]
	_hips[1].rotation.x = _pose_now[2] * 0.85  # a touch out of step, so it isn't stiff
	_hips[2].rotation.x = _pose_now[3]
	_hips[3].rotation.x = _pose_now[3] * 0.85
	_tail.rotation.x = _pose_now[4]
	_jaw.rotation.x = _jaw_rest - _pose_now[5]

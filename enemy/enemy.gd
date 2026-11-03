class_name Enemy
extends CharacterBody3D
## Melee enemy with a small state machine (subclasses like RangedEnemy override
## the _chase_move_dir / _can_start_attack / _on_windup_start / _during_windup / _strike hooks):
##   IDLE    wanders around its home spot until it notices the player
##   CHASE   hunts the player down, whether or not it can see them (around
##           obstacles, through doors, up stairs); only gives up if they get far away
##   WINDUP  telegraphed attack startup (eyes flare red, leans back). Back off or circle
##           behind to dodge, or interrupt it with a heavy hit (>= stagger_threshold).
##   RECOVER brief pause after attacking or being staggered

signal died(killed_by_player: bool)

enum State { IDLE, CHASE, WINDUP, RECOVER }

const REPATH_INTERVAL := 3.0

## Playable area (XZ) set by the world generator. Wander targets stay inside it;
## the map's boundary walls (physics layer 5) physically stop anything else.
static var world_bounds := Rect2()
## Pathfinding for the current region, set by the world generator (null = walk straight).
static var nav: WorldNav

@export var max_health := 75.0
@export var move_speed := 5.5       ## slower than the player's 8, so good movement lets you escape
@export var wander_speed := 1.8
@export var acceleration := 25.0
@export var jump_velocity := 7.0
@export var gravity := 20.3
## Scales knockback and pushes received (giants barely budge).
@export var knockback_scale := 1.0
## Coins the player gets for killing it (at level 1; grows 50% per level).
@export var reward := 5
## Bosses: a grappling hook holds in them (so you can swing around and onto
## them), and the minimap always points to them.
@export var is_boss := false
## Degrees per second it can turn to face something. 0 = instantly. Slow
## turners also only advance in the direction they face, so they pivot first.
@export var turn_speed := 0.0

@export_group("Flight")
## Flyers ignore gravity, hover above the ground (and above you while hunting),
## rise over whatever they bump into, and fly straight instead of taking routes.
## Nodes under Visual named "Wing..." flap.
@export var flying := false
@export var hover_height := 5.0
## While hunting it also stays at least this far above you.
@export var hover_above_target := 3.0
@export var lift_speed := 6.0
## Wing beats (radians per second of the flap cycle).
@export var flap_speed := 14.0

@export_group("Senses")
## Notices you within this range, walls or not (it hears you).
@export var detection_range := 22.0
## Once hunting, it only gives up beyond this distance. Hiding doesn't shake it.
@export var lose_range := 40.0
@export var wander_radius := 8.0
## Height its line-of-sight checks start from.
@export var eye_height := 1.5

@export_group("Attack")
@export var damage := 15.0
@export var attack_range := 1.8     ## starts winding up when you're this close
@export var hit_range := 2.3        ## you must still be this close (and in front) when the windup ends
@export var windup_time := 0.55
@export var recover_time := 0.6
@export var stagger_threshold := 30.0  ## a single hit this strong interrupts a windup
@export var stagger_time := 0.6

@onready var visual: Node3D = $Visual
# Both materials are local-to-scene in enemy.tscn, so each enemy's colors are independent.
@onready var _body_mat: StandardMaterial3D = $Visual/Body.get_surface_override_material(0)
@onready var _eye_mat: StandardMaterial3D = $Visual/Eyes.get_surface_override_material(0)

var health: float
var state := State.IDLE
var _state_time := 0.0
var _player: Node3D
var _home: Vector3
var _wander_target: Vector3
var _wander_wait := 0.0
var _sight_timer := 0.0
var _can_see := false
var _base_color: Color
var _flash_tween: Tween
var _pose_tween: Tween
var _dead := false
var _path := PackedVector3Array()
var _path_index := 0
var _repath_time := 0.0
var _path_goal := Vector3.ZERO
var _wings: Array[Node] = []
var _flap := 0.0
## Off while something else poses the wings (a dragon raising them to dive).
var _flapping := true


## Scales this enemy for a region's level (1 = as authored). Call before adding
## it to the tree. Health and damage compound, so later regions are much harder
## than a straight line would give (the player's chest upgrades keep pace):
##   health x1.35 and damage x1.25 per level (level 5: x3.3 health, x2.4 damage)
##   +5% speed per level (up to +40%)
##   attack windups and recoveries 8% shorter per level (down to 55%)
##   notices you from 10% further per level (up to +60%)
##   coin reward +50% per level
func apply_level(level: int) -> void:
	var extra := maxi(level - 1, 0)
	max_health *= pow(1.35, extra)
	damage *= pow(1.25, extra)
	move_speed *= minf(1.0 + 0.05 * extra, 1.4)
	var tempo := maxf(pow(0.92, extra), 0.55)
	windup_time *= tempo
	recover_time *= tempo
	detection_range *= minf(1.0 + 0.1 * extra, 1.6)
	reward = roundi(reward * (1.0 + 0.5 * extra))


func _ready() -> void:
	health = max_health
	_base_color = _body_mat.albedo_color
	_player = get_tree().get_first_node_in_group("player")
	_home = global_position
	_wander_target = global_position
	_wander_wait = randf_range(0.0, 2.0)
	add_to_group(Portal.TRAVELERS)
	if flying:
		_wings = visual.find_children("Wing*", "Node3D", false, false)
		_flap = randf() * TAU
	_set_state(State.IDLE)


func _physics_process(delta: float) -> void:
	if flying:
		_flap += delta * flap_speed
		if _flapping:
			for wing: Node3D in _wings:
				wing.rotation.z = sin(_flap) * 0.6 * signf(wing.position.x)
	elif not is_on_floor():
		velocity.y -= gravity * delta

	if not _dead:
		_update_senses(delta)
		match state:
			State.IDLE:
				_wander(delta)
			State.CHASE:
				_chase(delta)
			State.WINDUP, State.RECOVER:
				if _holds_still():
					_steer(Vector3.ZERO, delta)  # planted while attacking: no tracking, so you can sidestep
				_state_time -= delta
				if state == State.WINDUP:
					_during_windup(delta)
				else:
					_during_recover(delta)
				if _state_time <= 0.0 and state != State.CHASE:
					if state == State.WINDUP:
						_strike()
					else:
						_on_recover_end()
						_set_state(State.CHASE)

	move_and_slide()

	if global_position.y < -50.0 and not _dead:
		_die(false)


# --- Senses -----------------------------------------------------------------

func _update_senses(delta: float) -> void:
	if not is_instance_valid(_player):
		_can_see = false
		return
	var dist := global_position.distance_to(_player.global_position)

	# Raycasts are cheap but not free; 5 checks a second is plenty, and enemies
	# far outside any relevant range don't check at all.
	_sight_timer -= delta
	if _sight_timer <= 0.0:
		_sight_timer = 0.2
		# Sight only decides whether it can attack (and how it approaches), not
		# whether it hunts you.
		_can_see = dist <= lose_range and _has_line_of_sight()

	match state:
		State.IDLE:
			if dist <= detection_range:
				alert()
		State.CHASE:
			if dist > lose_range:
				_set_state(State.IDLE)  # head back to wandering around home


func _has_line_of_sight() -> bool:
	var eye := global_position + Vector3.UP * eye_height
	var target := _player.global_position + Vector3.UP * 1.5
	var query := PhysicsRayQueryParameters3D.create(eye, target)
	query.collision_mask = 1  # only level geometry blocks sight
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.collider == _player


## Start chasing (also called when damaged, so sniping one from afar wakes it up).
func alert() -> void:
	if _dead or state != State.IDLE:
		return
	_set_state(State.CHASE)


# --- Movement -----------------------------------------------------------------

func _wander(delta: float) -> void:
	if _wander_wait > 0.0:
		_wander_wait -= delta
		_steer(Vector3.ZERO, delta)
		return
	var to_target := _wander_target - global_position
	to_target.y = 0.0
	if to_target.length() < 0.5 or is_on_wall():
		_wander_wait = randf_range(1.0, 3.0)
		var offset := Vector2.from_angle(randf() * TAU) * randf() * wander_radius
		_wander_target = _home + Vector3(offset.x, 0.0, offset.y)
		if world_bounds.has_area():  # never wander toward the map edge
			var inner := world_bounds.grow(-5.0)
			_wander_target.x = clampf(_wander_target.x, inner.position.x, inner.end.x)
			_wander_target.z = clampf(_wander_target.z, inner.position.y, inner.end.y)
		return
	var dir := to_target.normalized()
	_steer(dir * wander_speed, delta)
	_face(dir)


func _chase(delta: float) -> void:
	if not is_instance_valid(_player):
		_steer(Vector3.ZERO, delta)
		return
	var target := _player.global_position
	var to_target := target - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var move_dir := _chase_move_dir(flat)
	var face_dir := flat
	# Directly above or below you still counts as approaching (it needs the stairs).
	var approaching := move_dir.dot(flat) > 0.0 or (flat.length() <= 0.5 and absf(to_target.y) > 1.5)
	var portal := Portal.shortcut(global_position, target) if _takes_portals() else null
	if portal != null:
		# A portal gets it to you sooner than its legs would: it goes through.
		var aim := portal.approach_point(global_position)
		var to_aim := aim - global_position
		to_aim.y = 0.0
		if nav != null and to_aim.length() > 6.0:
			to_aim = _route_toward(aim, delta) - global_position
			to_aim.y = 0.0
		move_dir = to_aim.normalized()
		face_dir = to_aim
	# Approaching: take a route (around obstacles, in through doors, up ramps)
	# instead of the straight line, unless the target is right there in the open.
	elif nav != null and approaching and _uses_routes(to_target):
		var to_waypoint := _route_toward(_approach_goal(target), delta) - global_position
		to_waypoint.y = 0.0
		if to_waypoint.length() > 0.2:
			move_dir = to_waypoint.normalized()
			if not _can_see:
				face_dir = to_waypoint
	else:
		_path = PackedVector3Array()
	var advance := 1.0
	if turn_speed > 0.0 and move_dir != Vector3.ZERO:
		face_dir = move_dir  # a slow turner looks where it's going...
		advance = clampf((-global_basis.z).dot(move_dir), 0.0, 1.0)  # ...and doesn't go until it has turned that way
	_steer(move_dir * move_speed * advance, delta)
	if face_dir.length() > 0.1:
		_face(face_dir.normalized())

	# Bumped into a platform or pillar on the way: hop over it.
	if not flying and is_on_floor() and is_on_wall() and move_dir != Vector3.ZERO and flat.length() > 2.0:
		velocity.y = jump_velocity

	if _can_start_attack(to_target):
		_start_windup()


## Hook: which way to move while chasing (unit vector or zero). Melee: straight at you.

func _chase_move_dir(flat_to_target: Vector3) -> Vector3:
	return flat_to_target.normalized() if flat_to_target.length() > 0.5 else Vector3.ZERO


# --- Pathfinding ----------------------------------------------------------------

## Hook: whether to follow a route rather than walk straight at the target.
## By default: whenever it can't see you, you're on another level, or you're far off.
func _uses_routes(to_target: Vector3) -> bool:
	if flying:
		return false
	return not _can_see or absf(to_target.y) > 1.5 or Vector3(to_target.x, 0.0, to_target.z).length() > 6.0


## Hook: whether it runs through the player's portals when that's a shortcut.
func _takes_portals() -> bool:
	return not flying


func can_use_portal() -> bool:
	return not _dead


## Called by a Portal right after it moved this enemy to its other end.
func on_portal_travel() -> void:
	_path = PackedVector3Array()
	_repath_time = 0.0


## Hook: where an approach should lead. Melee: to you. Ranged enemies return a
## spot they can shoot from instead.
func _approach_goal(target: Vector3) -> Vector3:
	return target


## Hook: huge enemies path on the grid with extra clearance around structures.
func _needs_wide_paths() -> bool:
	return false


## The next point to walk to on the way to `goal`. The route is re-planned when
## the goal moves (at most about twice a second) and every few seconds anyway,
## in case it got knocked off course.
func _route_toward(goal: Vector3, delta: float) -> Vector3:
	_repath_time -= delta
	var moved := _path.is_empty() or goal.distance_to(_path_goal) > 1.5
	if _repath_time <= 0.0 or (moved and _repath_time <= REPATH_INTERVAL - 0.5):
		_repath_time = REPATH_INTERVAL * randf_range(0.9, 1.1)
		_path = nav.route(global_position, goal, _needs_wide_paths())
		_path_goal = goal
		_path_index = 0
		# Already partway along the new route (re-planned halfway up a ramp):
		# carry on from there rather than doubling back to its start.
		for index in mini(_path.size() - 1, 6):
			if _is_between(_path[index], _path[index + 1]):
				_path_index = index + 1
	while _path_index < _path.size() - 1 and _is_at(_path[_path_index]):
		_path_index += 1
	return _path[_path_index] if _path_index < _path.size() else goal


## Whether it's standing on the straight line from `a` to `b`.
func _is_between(a: Vector3, b: Vector3) -> bool:
	var segment := b - a
	var t := (global_position - a).dot(segment) / maxf(segment.length_squared(), 0.01)
	return t > 0.0 and t < 1.0 and (a + segment * t).distance_to(global_position) < 1.2


func _is_at(point: Vector3) -> bool:
	var offset := point - global_position
	return Vector2(offset.x, offset.z).length() < 1.0 and absf(offset.y) < 1.6


## Hook: whether to begin an attack windup this tick.
func _can_start_attack(to_target: Vector3) -> bool:
	return _can_see and to_target.length() < attack_range


## Accelerate toward a horizontal velocity. Much weaker in the air, so
## knockback and explosions actually launch them.
func _steer(target_velocity: Vector3, delta: float) -> void:
	if flying:
		target_velocity.y = _lift()
		velocity = velocity.move_toward(target_velocity, acceleration * delta)
		return
	var accel := acceleration if is_on_floor() else acceleration * 0.15
	var h := Vector3(velocity.x, 0.0, velocity.z).move_toward(target_velocity, accel * delta)
	velocity.x = h.x
	velocity.z = h.z


## Vertical speed that takes a flyer to its hover height.
func _lift() -> float:
	if is_on_wall() or is_on_floor():
		return lift_speed  # up and over whatever it ran into
	var ground := nav.ground_height(global_position.x, global_position.z) if nav != null else _home.y
	var height := ground + hover_height
	if state != State.IDLE and is_instance_valid(_player):
		height = maxf(height, _player.global_position.y + hover_above_target)
	return clampf((height - global_position.y) * 2.0, -lift_speed, lift_speed)


## Turns toward a horizontal direction: at once, or at turn_speed if it has one.
func _face(dir: Vector3) -> void:
	if dir.length_squared() <= 0.01:
		return
	if turn_speed <= 0.0:
		look_at(global_position + dir, Vector3.UP)
		return
	var wanted := atan2(-dir.x, -dir.z)
	var step := deg_to_rad(turn_speed) * get_physics_process_delta_time()
	rotation.y += clampf(angle_difference(rotation.y, wanted), -step, step)


# --- Attacking ----------------------------------------------------------------

func _start_windup() -> void:
	_set_state(State.WINDUP)
	_state_time = windup_time
	_on_windup_start()


## Hook: the telegraph. Melee leans back.
func _on_windup_start() -> void:
	_pose(Vector3(-0.35, 0.0, 0.0), windup_time)


## Hook: runs every tick of the windup. Melee commits to its direction (no tracking).
func _during_windup(_delta: float) -> void:
	pass


## Hook: whether to brake to a stop during WINDUP/RECOVER (leapers keep their momentum).
func _holds_still() -> bool:
	return true


## Hook: runs every tick of RECOVER (after an attack or a stagger).
func _during_recover(_delta: float) -> void:
	pass


## Hook: RECOVER finished; the enemy goes back to chasing right after.
func _on_recover_end() -> void:
	pass


## Hook: the attack itself, when the windup ends. Must leave the enemy in RECOVER.
func _strike() -> void:
	if is_instance_valid(_player):
		var to_player := _player.global_position - global_position
		var flat := Vector3(to_player.x, 0.0, to_player.z)
		var in_front := (-global_basis.z).dot(flat.normalized()) > 0.3
		if to_player.length() <= hit_range and in_front:
			_player.take_damage(damage, global_position)
	_set_state(State.RECOVER)
	_state_time = recover_time
	_pose(Vector3(0.3, 0.0, 0.0), 0.06)  # lunge forward...
	_pose_tween.tween_property(visual, "rotation", Vector3.ZERO, 0.3)  # ...and settle


func _pose(target_rotation: Vector3, duration: float) -> void:
	if _pose_tween:
		_pose_tween.kill()
	_pose_tween = create_tween()
	_pose_tween.tween_property(visual, "rotation", target_rotation, duration)


func _set_state(new_state: State) -> void:
	state = new_state
	# Eye color shows what it's thinking: dim = unaware, orange = hunting, bright red = about to hit.
	match state:
		State.IDLE:
			_eye_mat.emission = Color(1.0, 0.85, 0.2)
			_eye_mat.emission_energy_multiplier = 0.6
		State.CHASE, State.RECOVER:
			_eye_mat.emission = Color(1.0, 0.45, 0.05)
			_eye_mat.emission_energy_multiplier = 2.5
		State.WINDUP:
			_eye_mat.emission = Color(1.0, 0.05, 0.05)
			_eye_mat.emission_energy_multiplier = 8.0


# --- Damage -----------------------------------------------------------------

## hit_position is where the hit landed (Vector3.INF if unknown); subclasses use it
## for damage zones via _damage_multiplier().
func take_damage(amount: float, from_position: Vector3, hit_position := Vector3.INF) -> void:
	if _dead:
		return
	var multiplier := _damage_multiplier(hit_position)
	amount *= multiplier
	health -= amount
	alert()
	_on_damaged(amount, multiplier, hit_position)

	var away := global_position - from_position
	away.y = 0.0
	# Knockback scales with the hit (a 25-damage hit shoves at 3 m/s), so many
	# small hits (shotgun pellets, a laser) don't add up to a launch.
	velocity += away.normalized() * 3.0 * clampf(amount / 25.0, 0.0, 1.5) * knockback_scale

	if _flash_tween:
		_flash_tween.kill()
	_body_mat.albedo_color = Color.WHITE
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_mat, "albedo_color", _base_color, 0.15)

	if health <= 0.0:
		_die(true)
	elif amount >= stagger_threshold and state == State.WINDUP:
		_set_state(State.RECOVER)
		_state_time = stagger_time
		_pose(Vector3.ZERO, 0.1)
		_on_windup_cancelled()


## Hook: a stagger interrupted the windup.
func _on_windup_cancelled() -> void:
	pass


## Hook: damage multiplier for where a hit landed (weak spots / armor).
func _damage_multiplier(_hit_position: Vector3) -> float:
	return 1.0


## Hook: after damage is applied (amount already multiplied). For feedback like damage numbers.
func _on_damaged(_amount: float, _multiplier: float, _hit_position: Vector3) -> void:
	pass


## Instant velocity change from explosions and heavy melee.
func push(impulse: Vector3) -> void:
	velocity += impulse * knockback_scale


func _die(killed_by_player: bool) -> void:
	_dead = true
	died.emit(killed_by_player)
	if killed_by_player and is_instance_valid(_player) and _player.has_method("add_coins"):
		_player.add_coins(reward)
	collision_layer = 0  # stop blocking shots and the player; keep the mask so it doesn't fall through the floor
	if _pose_tween:
		_pose_tween.kill()
	var tween := create_tween()
	tween.tween_property(visual, "scale", Vector3.ONE * 0.01, 0.2)
	tween.tween_callback(queue_free)

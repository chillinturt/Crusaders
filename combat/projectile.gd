class_name Projectile
extends Node3D
## A visible, travelling shot (enemy spit, rockets). Moves by raycasting each tick
## so it can't tunnel through things. Its Area3D (layer 4, "projectiles") is only
## there so melee swings can find it and deflect it.

signal deflected

@export var speed := 16.0
@export var damage := 20.0
@export var lifetime := 6.0
## > 0 makes it explode on impact instead of hitting one target (rockets).
@export var explosion_radius := 0.0
@export var explosion_force := 12.0
@export var self_damage_multiplier := 0.4
## Downward acceleration (m/s^2). 0 = flies straight; more = a lobbed arc.
@export var gravity := 0.0
@export var deflectable := true
## Deflected shots go faster and hit harder.
@export var deflect_speed_multiplier := 1.6
@export var deflect_damage_multiplier := 2.0

var velocity := Vector3.ZERO
## Who fired it (ignored by its collision). After a deflect, it's the deflector.
var shooter: Node


func _enter_tree() -> void:
	add_to_group(Portal.TRAVELERS)


func launch(from: Vector3, direction: Vector3, p_shooter: Node) -> void:
	global_position = from
	velocity = direction.normalized() * speed
	shooter = p_shooter
	_orient()


## Launches with an exact velocity (for lobbed shots that solve their own arc).
func launch_with_velocity(from: Vector3, p_velocity: Vector3, p_shooter: Node) -> void:
	global_position = from
	velocity = p_velocity
	shooter = p_shooter
	_orient()


func _physics_process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()
		return
	if gravity != 0.0:
		velocity.y -= gravity * delta
		_orient()
	var next := global_position + velocity * delta
	var query := PhysicsRayQueryParameters3D.create(global_position, next)
	query.collision_mask = 1 | 2  # world + characters
	if is_instance_valid(shooter) and shooter is CollisionObject3D:
		query.exclude = [shooter.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		_impact(hit.position, hit.collider)
	else:
		global_position = next


func _impact(at: Vector3, collider: Object) -> void:
	if explosion_radius > 0.0:
		# The shooter may have died while this was in the air (a freed object can't
		# be passed on), in which case nobody gets the reduced self-damage.
		var instigator: Node = shooter if is_instance_valid(shooter) else null
		Explosion.explode(self, at - velocity.normalized() * 0.2, explosion_radius, damage, explosion_force,
				instigator, self_damage_multiplier)
	elif collider.has_method("take_damage"):
		collider.take_damage(damage, global_position, at)
	queue_free()


## Called by melee swings. Sends it back along the swing's aim.
func deflect(direction: Vector3, by: Node) -> bool:
	if not deflectable:
		return false
	velocity = direction.normalized() * velocity.length() * deflect_speed_multiplier
	damage *= deflect_damage_multiplier
	shooter = by
	lifetime = maxf(lifetime, 3.0)
	_orient()
	deflected.emit()
	return true


func _orient() -> void:
	if velocity.length_squared() > 0.01 and absf(velocity.normalized().dot(Vector3.UP)) < 0.99:
		look_at(global_position + velocity, Vector3.UP)

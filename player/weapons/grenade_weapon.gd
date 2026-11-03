extends Weapon
## Hand grenades as a weapon: click (or hold) to throw. They bounce, inherit your momentum,
## and explode on a fuse (walls block the blast; one at your feet is a grenade jump).
## The "magazine" is how many you can throw before re-arming.

@export var grenade_scene: PackedScene
@export var throw_speed := 16.0
@export var throw_lift := 3.0       ## extra upward speed so throws arc instead of lining out
@export var throw_interval := 0.6

func _weapon_tick(_delta: float) -> void:
	var trigger := Input.is_action_pressed("attack")
	if trigger and can_attack() and _use_round():  # hold to keep firing
		_cooldown = throw_interval / _upgrades().fire_rate_multiplier()
		_throw()
	# The held grenade model disappears while you have none ready.
	$Model.visible = rounds > 0 and not is_reloading()


func _throw() -> void:
	var thrower := _wielder()
	var camera := _camera()
	var grenade: RigidBody3D = grenade_scene.instantiate()
	grenade.thrower = thrower
	grenade.damage *= _upgrades().damage_multiplier()
	thrower.get_parent().add_child(grenade)
	grenade.global_position = camera.global_position + camera.global_basis * Vector3(0.2, -0.1, -0.5)
	grenade.linear_velocity = -camera.global_basis.z * throw_speed + Vector3.UP * throw_lift + thrower.velocity
	grenade.angular_velocity = Vector3(randf_range(-10, 10), randf_range(-10, 10), randf_range(-10, 10))
	grenade.add_collision_exception_with(thrower)
	position.z -= 0.15  # throw motion

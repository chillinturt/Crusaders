extends Weapon
## Fires rockets (Projectile scenes) toward whatever the crosshair is on.
## Rocket-jump: aim at your feet.

@export var rocket_scene: PackedScene
@export var fire_interval := 0.8
@export var recoil_kick := 0.15

@onready var muzzle: Marker3D = $Muzzle

func _weapon_tick(_delta: float) -> void:
	var trigger := Input.is_action_pressed("attack")
	if trigger and can_attack() and _use_round():  # hold to keep firing
		_cooldown = fire_interval / _upgrades().fire_rate_multiplier()
		_fire()


func _fire() -> void:
	var camera := _camera()
	# Aim the rocket from the muzzle at the point under the crosshair.
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * 500.0)
	query.collision_mask = 1 | 2
	query.exclude = [_wielder().get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var target: Vector3 = hit.position if hit else from - camera.global_basis.z * 500.0
	# Very close targets (rocket jumps): fire from the eye so it can't start past the floor.
	var start := muzzle.global_position if from.distance_to(target) > 2.0 else from

	var rocket: Projectile = rocket_scene.instantiate()
	rocket.damage *= _upgrades().damage_multiplier()
	owner.get_parent().add_child(rocket)
	rocket.launch(start, target - start, _wielder())
	position.z += recoil_kick

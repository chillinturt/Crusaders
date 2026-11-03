class_name MortarEnemy
extends RangedEnemy
## "Mortar": stays far back and lobs shells in a high arc at where you're
## standing. Shells explode on contact, so near misses still hurt, and cover
## between you doesn't help if the arc clears it. You get the charge-up (the orb)
## and the shell's flight time to move. Melee can still swat a shell away.

## Flight time of a shot at max range; closer shots land sooner (min 55% of this).
@export var max_flight_time := 2.6


func _launch(shot: Projectile, from: Vector3) -> void:
	var to_target := _player.global_position - from
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var t := clampf(flat.length() / attack_range, 0.55, 1.0) * max_flight_time
	# Ballistic solve: land on the player's current position after t seconds.
	var launch_velocity := flat / t
	launch_velocity.y = (to_target.y + 0.5 * shot.gravity * t * t) / t
	shot.launch_with_velocity(from, launch_velocity, self)

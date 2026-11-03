extends RigidBody3D
## Bouncy physics grenade. On fuse: damages and launches everything in the blast
## radius that isn't behind cover. Hurts the thrower a bit too (grenade jumps!).

@export var fuse_time := 2.5
@export var blast_radius := 6.0
@export var damage := 90.0          ## at the center; falls off to 20% at the edge
@export var blast_force := 14.0     ## velocity added at the center, also falls off
@export var self_damage_multiplier := 0.35

var thrower: Node3D


func _ready() -> void:
	add_to_group(Portal.TRAVELERS)
	get_tree().create_timer(fuse_time, false).timeout.connect(_explode)


func _explode() -> void:
	if not is_inside_tree():
		return
	var center := global_position + Vector3.UP * 0.2  # lift off the floor so the cover check doesn't hit it
	var exclude: Array[RID] = [get_rid()]
	var instigator: Node = thrower if is_instance_valid(thrower) else null
	Explosion.explode(self, center, blast_radius, damage, blast_force, instigator, self_damage_multiplier, exclude)
	queue_free()

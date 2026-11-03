class_name Structure
extends StaticBody3D
## A piece built with the building gun. Solid level geometry (layer 1): blocks
## movement, shots, enemy sight and blasts like any wall. It has health, so it can
## be shot or blown apart, and the building gun's laser tears it down quickly.

@export var max_health := 250.0

var health: float


func _ready() -> void:
	health = max_health
	add_to_group(&"structures")  # how explosions find built pieces


func take_damage(amount: float, _from_position: Vector3, _hit_position := Vector3.INF) -> void:
	health -= amount
	if health <= 0.0:
		queue_free()

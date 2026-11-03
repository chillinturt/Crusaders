extends Node3D
## Keeps max_alive enemies in the level. Enemies spawn at this node's Marker3D
## children, preferring ones that aren't right next to the player.

## An enemy from this spawner died (killed_by_player = false means it fell out
## of the world, etc.).
signal enemy_died(killed_by_player: bool)

## Picked at random per spawn; list a scene more than once to make it more common.
@export var enemy_scenes: Array[PackedScene] = []
@export var max_alive := 6
@export var respawn_delay := 3.0
@export var min_player_distance := 20.0
## Region level: spawned enemies are scaled with Enemy.apply_level().
@export var level := 1
## Off = enemies the player kills stay dead (bosses). Ones lost any other way
## still come back, so a boss can't be skipped by accident.
@export var respawn_killed := true

var _player: Node3D


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player")
	for i in max_alive:
		_spawn.call_deferred()


func _spawn() -> void:
	var points := get_children().filter(func(n: Node) -> bool: return n is Marker3D)
	if points.is_empty() or enemy_scenes.is_empty():
		return
	var far := points.filter(func(p: Marker3D) -> bool:
		return not _player or p.global_position.distance_to(_player.global_position) >= min_player_distance)
	var point: Marker3D = (far if not far.is_empty() else points).pick_random()

	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	if enemy.has_method("apply_level"):
		enemy.apply_level(level)
	# Position before add_child so the enemy's _ready() records the right home spot.
	# Small random offset so enemies sharing a marker don't spawn inside each other.
	enemy.position = to_local(point.global_position + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2)))
	add_child(enemy)
	enemy.died.connect(_on_enemy_died)


func _on_enemy_died(killed_by_player: bool) -> void:
	if killed_by_player and _player and _player.has_method("add_kill"):
		_player.add_kill()
	enemy_died.emit(killed_by_player)
	if respawn_killed or not killed_by_player:
		get_tree().create_timer(respawn_delay).timeout.connect(_spawn)

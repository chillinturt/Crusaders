class_name Gargoyle
extends Enemy
## Flying brute (a harpy: a woman with wings for arms and a bird's legs): fast and tough, and it attacks by diving into you.
## Its taloned legs hang back in flight and swing forward, claws out, as it
## winds up and dives.
##   Startup: it stops in the air and rears back (nose up, eyes flare) for windup_time.
##   Dive: it shoots in a straight line at where you were when it launched, and
##   hits you once if it passes close enough. Move sideways to dodge.
##   After: it pulls up and hangs there for recover_time: your opening.
## Hits strong enough to stagger it cancel the startup, like any enemy.

@export var dive_speed := 24.0
@export var dive_knockback := 10.0
@export var hit_radius := 2.0

var _diving := false
var _hit_done := false
var _dive_time := 0.0
var _dive_length := 0.0

@onready var _legs: Node3D = $Visual/Legs
@onready var _tail: Node3D = $Visual/TailRoot


func _physics_process(delta: float) -> void:
	super(delta)
	if _dead:
		return
	# Talons: trailing behind in flight, thrust forward to strike.
	var reaching := state == State.WINDUP or _diving
	var wanted := 1.25 if reaching else -0.55
	_legs.rotation.x = lerpf(_legs.rotation.x, wanted, 1.0 - exp(-(14.0 if reaching else 5.0) * delta))
	_flap = _flap + delta * (10.0 if _diving else 0.0)  # frantic beats in the dive
	# Tail: sways with the wingbeat, flattens out to steer the dive.
	var tail := 0.1 if reaching else 0.44 + sin(_flap) * 0.08
	_tail.rotation.x = lerpf(_tail.rotation.x, tail, 1.0 - exp(-8.0 * delta))

func _can_start_attack(to_target: Vector3) -> bool:
	return _can_see and to_target.length() < attack_range


func _on_windup_start() -> void:
	_pose(Vector3(0.6, 0.0, 0.0), windup_time)


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
	var to_target := _player.global_position + Vector3.UP * 0.9 - (global_position + Vector3.UP * 0.7)
	velocity = to_target.normalized() * dive_speed
	_diving = true
	_hit_done = false
	_dive_time = 0.0
	_dive_length = (to_target.length() + 4.0) / dive_speed  # carries on a little past you
	_state_time = 10.0  # ends when the dive does
	_pose(Vector3(-0.7, 0.0, 0.0), 0.1)


func _holds_still() -> bool:
	return not _diving


func _during_recover(delta: float) -> void:
	if not _diving:
		return
	_dive_time += delta
	if not _hit_done and is_instance_valid(_player):
		var player_center := _player.global_position + Vector3.UP * 0.9
		if (global_position + Vector3.UP * 0.7).distance_to(player_center) < hit_radius:
			_hit_done = true
			_player.take_damage(damage, global_position)
			_player.push(Vector3(velocity.x, 0.0, velocity.z).normalized() * dive_knockback + Vector3.UP * 3.0)
	if _dive_time >= _dive_length or (_dive_time > 0.1 and (is_on_wall() or is_on_floor())):
		_diving = false
		_state_time = recover_time
		_pose(Vector3.ZERO, 0.4)


func _on_windup_cancelled() -> void:
	_pose(Vector3.ZERO, 0.2)

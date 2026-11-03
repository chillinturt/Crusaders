extends Structure
## Launches anything that steps on it. Built pads fire straight up, keeping your
## horizontal momentum; pads placed by the world (under floating islands) throw
## you along a set arc instead.

@export var launch_speed := 17.0
## If set, replaces the whole velocity of whatever steps on it (a fixed arc).
@export var launch_velocity := Vector3.ZERO


func _ready() -> void:
	super()
	$LaunchArea.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if not body is CharacterBody3D:
		return
	if launch_velocity != Vector3.ZERO:
		body.velocity = launch_velocity
	else:
		body.velocity.y = maxf(body.velocity.y, launch_speed)

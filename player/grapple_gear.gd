extends Node3D
## Grappling hook: a Utility loadout choice that's always at hand (it doesn't take
## a weapon slot).
##   RMB         fire the hook at whatever you're aiming at (terrain, buildings, titans)
##   hold RMB    stay attached. The rope holds its length, so you swing on it like
##               a pendulum (slack is taken up as you get closer). Let go to detach
##               and keep your momentum.
##   F           reel in: the rope shortens and hauls you toward the hook
##   C           reel out: the rope lengthens, to drop down or widen a swing
##   Shift       gas (everyone has it): while hooked it thrusts toward the hook,
##               steerable with your aim
## Hooks stuck in moving things move with them. In a boss (a titan) the hook
## holds even when you've reeled all the way in, so you can hang on it and
## strike, until it shakes you off after boss_hold_time.

@export var display_name := "Grappling Hook"
@export_multiline var description := "RMB fires a hook: hold to swing on the rope. F reels in, C reels out. Gas (Shift) thrusts toward the hook. Always available alongside your weapons."
@export var owned := false
@export var max_range := 45.0
## Rope taken in / let out per second.
@export var reel_in_speed := 14.0
@export var reel_out_speed := 10.0
## Thrust toward the hook while burning gas.
@export var gas_acceleration := 30.0
## How long a hook stays in a boss before it's shaken loose.
@export var boss_hold_time := 4.0

var hooked := false
var _anchor_body: Node3D
var _anchor_local := Vector3.ZERO
var _rope_length := 0.0
var _hold_left := 0.0
var _rope_mesh := ImmediateMesh.new()
var _rope: MeshInstance3D

@onready var player: CharacterBody3D = get_parent()


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.15, 0.15, 0.15)
	_rope = MeshInstance3D.new()
	_rope.mesh = _rope_mesh
	_rope.material_override = material
	_rope.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rope.top_level = true  # vertices are in world space
	add_child(_rope)


func _unhandled_input(event: InputEvent) -> void:
	if owned and event.is_action_pressed("alt_fire") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and not player.is_grabbed():
		fire()


func fire() -> void:
	var camera: Camera3D = player.camera
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * max_range)
	query.collision_mask = 1 | 2
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit:
		return
	_anchor_body = hit.collider
	_anchor_local = _anchor_body.to_local(hit.position)
	hooked = true
	_hold_left = boss_hold_time
	_rope_length = _origin().distance_to(hit.position)
	if player.is_on_floor():
		player.velocity.y = maxf(player.velocity.y, 4.0)  # pop off the ground so the swing can start


func detach() -> void:
	hooked = false
	_anchor_body = null


## Whether the hook is in a boss.
func on_boss() -> bool:
	return hooked and _anchor_body is Enemy and _anchor_body.is_boss


func anchor() -> Vector3:
	return _anchor_body.to_global(_anchor_local)


func rope_length() -> float:
	return _rope_length


## Called by the player every physics tick, after its own movement and before
## move_and_slide(). `thrusting` is whether the player is burning gas this tick;
## returns true if the hook used that thrust (so the player doesn't also apply it).
func apply(delta: float, thrusting: bool) -> bool:
	if hooked and (not owned or not Input.is_action_pressed("alt_fire") or not is_instance_valid(_anchor_body) or player.is_grabbed()):
		detach()
	if not hooked:
		_draw_rope()
		return false

	var to_anchor := anchor() - _origin()
	var dist := to_anchor.length()
	var dir := to_anchor / maxf(dist, 0.01)
	if thrusting:
		var aim := -(player.camera as Camera3D).global_basis.z
		player.velocity += (dir * 0.7 + aim * 0.3).normalized() * gas_acceleration * delta

	# Rope length: reel in / out on demand; otherwise it only takes up slack.
	var reeling_in := Input.is_action_pressed("reel_in")
	var reeling_out := Input.is_action_pressed("reel_out") and not reeling_in
	if reeling_in:
		_rope_length = maxf(_rope_length - reel_in_speed * delta, 1.5)
	elif reeling_out:
		_rope_length = minf(_rope_length + reel_out_speed * delta, max_range)
	else:
		_rope_length = minf(_rope_length, dist)

	# Taut rope: you can't move away from the anchor, and if the rope is shorter
	# than the gap (reeling in), you're hauled along it at the reel speed.
	if dist >= _rope_length - 0.05:
		var toward := player.velocity.dot(dir)  # speed toward the anchor (negative = away)
		var needed := minf((dist - _rope_length) / delta, reel_in_speed) if dist > _rope_length else 0.0
		if toward < needed:
			player.velocity += dir * (needed - toward)
	if on_boss():
		_hold_left -= delta
		if _hold_left <= 0.0:
			detach()
			player.notify("Shaken off!")
	elif dist < 1.5:
		detach()  # arrived
	_draw_rope()
	return thrusting


## Where the rope leaves the player: a bit below and to the side of the camera.
func _origin() -> Vector3:
	var camera: Camera3D = player.camera
	return camera.global_position + camera.global_basis * Vector3(0.25, -0.5, -0.2)


func _draw_rope() -> void:
	_rope_mesh.clear_surfaces()
	if not hooked:
		return
	_rope_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_rope_mesh.surface_add_vertex(_origin())
	_rope_mesh.surface_add_vertex(anchor())
	_rope_mesh.surface_end()

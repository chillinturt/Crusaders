class_name Brute
extends Enemy
## The basic melee enemy: a soldier in full plate with a sword and a shield.
## Same fight as any melee Enemy; this adds its animation:
##   walking   legs stride and the arms swing in step, faster with speed
##   windup    the tell: sword raised high overhead, leaning back, feet braced
##   strike    the sword chops down as it lunges forward, then it recovers
## Hits strong enough to stagger it cancel the windup, like any enemy.

## Its hips, in Visual's space: it leans about this point.
const HIP := Vector3(0.0, 0.95, 0.0)

@onready var _sword_arm: Node3D = $Visual/ArmR
@onready var _shield_arm: Node3D = $Visual/ArmL
@onready var _leg_l: Node3D = $Visual/LegL
@onready var _leg_r: Node3D = $Visual/LegR

# [lean back, bob, sword arm, shield arm, left leg, right leg]: where it is now.
var _pose_now := PackedFloat32Array([0, 0, 0.7, 0.9, 0, 0])
var _gait := 0.0
var _since_strike := 10.0


func _on_windup_start() -> void:
	pass  # the raised sword is part of the animation (see _process)


func _strike() -> void:
	super()
	if _pose_tween:
		_pose_tween.kill()
	_since_strike = 0.0


func _on_windup_cancelled() -> void:
	pass  # it drops back into its stance on its own


func _process(delta: float) -> void:
	if _dead:
		return
	if _pose_tween and _pose_tween.is_valid():
		_pose_tween.kill()  # (the base class's lean/lunge poses: this replaces them)
	_since_strike += delta
	var speed := Vector2(velocity.x, velocity.z).length()
	var stride := clampf(speed / move_speed, 0.0, 1.0)
	_gait += delta * (2.0 + speed * 1.4)
	var swing := sin(_gait)
	# Walking (and standing): the default.
	var target := PackedFloat32Array([-0.08 * stride, absf(cos(_gait)) * 0.04 * stride,
			0.7 + swing * 0.2 * stride, 0.9 - swing * 0.25 * stride, swing * 0.55 * stride, -swing * 0.55 * stride])
	var rate := 12.0
	if state == State.WINDUP:
		target = PackedFloat32Array([0.14, 0.0, 2.95, 1.3, 0.35, -0.25])  # sword high, leaning back, braced
		rate = 10.0
	elif state == State.RECOVER and _since_strike < 0.35:
		target = PackedFloat32Array([-0.28, -0.05, 0.5, 1.0, 0.55, -0.45])  # the chop: lunging into it
		rate = 40.0
	elif state == State.RECOVER:
		rate = 7.0  # settling back into its stance
	var blend := 1.0 - exp(-rate * delta)
	for i in _pose_now.size():
		_pose_now[i] = lerpf(_pose_now[i], target[i], blend)

	var lean := Basis(Vector3.RIGHT, _pose_now[0])
	visual.transform = Transform3D(lean, Vector3(0.0, _pose_now[1], 0.0) + HIP - lean * HIP)
	_sword_arm.rotation.x = _pose_now[2]
	_shield_arm.rotation.x = _pose_now[3]
	_leg_l.rotation.x = _pose_now[4]
	_leg_r.rotation.x = _pose_now[5]

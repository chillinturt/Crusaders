class_name Dragoon
extends RangedEnemy
## The Spitter's walker body: a gold-armored chassis on four heavy legs, with a
## twin-barrelled gun on top. Same fight as RangedEnemy; this animates it:
##   walking  the legs step in diagonal pairs (front-left with back-right), each
##            foot planted while the body passes over it, then lifted and swung
##            ahead. The knees bend to fit (two-bone IK), and the chassis bobs
##            and sways in step. Faster walking means longer, quicker strides.
##   aiming   the gun pitches up or down to point at you
##   charging it digs in: the chassis sinks low as the shot charges
##   firing   the gun kicks back, the chassis rocks, and the muzzle flashes

## Where the chassis pitches and rolls about (Visual space).
const CENTER := Vector3(0.0, 1.25, 0.0)
## Foot travel per step, meters.
const STRIDE := 0.9
const STEP_HEIGHT := 0.28
const LEGS := ["FL", "FR", "BL", "BR"]

var _chassis: Node3D
var _gun: Node3D
var _flash: OmniLight3D
var _gun_rest := Vector3.ZERO
# Per leg: rest hip (chassis space), rest foot (Visual space), outward direction,
# gait phase offset, thigh length, shin length.
var _legs: Array[Dictionary] = []
var _phase := 0.0
var _stride := 0.0     # 0 standing .. 1 full stride (eased)
var _crouch := 0.0     # how low it's dug in (eased)
var _recoil := 0.0
var _aim_pitch := 0.0


func _ready() -> void:
	super()
	# Group the body parts so the chassis can move over planted feet.
	_chassis = Node3D.new()
	_chassis.name = "Chassis"
	visual.add_child(_chassis)
	for part in ["Body", "Carapace", "Cowl", "Skirt", "PlateL", "PlateR", "Core", "CoreLight", "Eyes"]:
		visual.get_node(part).reparent(_chassis)
	_gun = Node3D.new()
	_gun.name = "Gun"
	_chassis.add_child(_gun)
	_gun_rest = Vector3(0.0, 1.98, -0.05)
	_gun.position = _gun_rest
	for part in ["Turret", "BarrelL", "BarrelR", "Orb"]:
		visual.get_node(part).reparent(_gun)
	_flash = OmniLight3D.new()
	_flash.light_color = Color(0.6, 1.0, 0.4)
	_flash.omni_range = 4.0
	_flash.light_energy = 0.0
	_flash.position = Vector3(0.0, 0.0, -1.15)
	_gun.add_child(_flash)

	for i in LEGS.size():
		var id: String = LEGS[i]
		var hip: Vector3 = visual.get_node("Hip" + id).position
		var knee: Vector3 = visual.get_node("Knee" + id).position
		var foot: Vector3 = visual.get_node("Foot" + id).position + Vector3.UP * 0.05
		_legs.append({
			"id": id,
			"hip": hip,
			"foot": foot,
			"out": Vector3(hip.x, 0.0, hip.z).normalized(),
			"offset": 0.0 if id == "FL" or id == "BR" else 0.5,  # diagonal pairs
			"thigh": hip.distance_to(knee),
			"shin": knee.distance_to(foot),
		})


func _strike() -> void:
	super()
	_recoil = 1.0
	_flash.light_energy = 6.0


# On the physics tick, right after the body moves, so planted feet stay put.
func _physics_process(delta: float) -> void:
	super(delta)
	if _dead or _chassis == null:
		return
	# How fast, and which way, relative to where it faces.
	var local_velocity := global_basis.inverse() * velocity
	local_velocity.y = 0.0
	var speed := local_velocity.length()
	var heading := local_velocity / speed if speed > 0.2 else Vector3.FORWARD
	_stride = lerpf(_stride, clampf(speed / maxf(move_speed, 0.1) * 1.4, 0.0, 1.0), 1.0 - exp(-6.0 * delta))
	_phase = fmod(_phase + speed * delta / (2.0 * STRIDE), 1.0)
	_crouch = lerpf(_crouch, 1.0 if state == State.WINDUP else 0.0, 1.0 - exp(-8.0 * delta))
	_recoil = maxf(_recoil - delta * 4.0, 0.0)
	_flash.light_energy = maxf(_flash.light_energy - delta * 40.0, 0.0)

	# The chassis: bobbing twice per cycle (once per footfall pair), swaying,
	# sinking while it charges, rocking back when it fires.
	var bob := sin(_phase * TAU * 2.0) * 0.045 * _stride
	var sway := sin(_phase * TAU) * 0.04 * _stride
	var pitch := -0.04 * _stride + _recoil * 0.12 - _crouch * 0.05
	var tilt := Basis.from_euler(Vector3(pitch, 0.0, sway))
	_chassis.transform = Transform3D(tilt, Vector3(0.0, bob - _crouch * 0.18, 0.0) + CENTER - tilt * CENTER)

	# The gun: aims at you (pitch), and kicks back when it fires.
	if is_instance_valid(_player):
		var target := _chassis.global_transform.affine_inverse() * (_player.global_position + Vector3.UP * 1.1)
		var to := target - _gun_rest
		var wanted := clampf(atan2(to.y, maxf(-to.z, 0.5)), -0.45, 0.5)
		_aim_pitch = lerpf(_aim_pitch, wanted, 1.0 - exp(-8.0 * delta))
	_gun.position = _gun_rest + Vector3(0.0, 0.0, 0.22 * _recoil)
	_gun.rotation.x = _aim_pitch + _recoil * 0.15

	for leg in _legs:
		_pose_leg(leg, heading)


## Places one leg: the foot where the gait puts it, the hip where the chassis
## carries it, and the knee bent between them.
func _pose_leg(leg: Dictionary, heading: Vector3) -> void:
	var p := fmod(_phase + leg.offset, 1.0)
	var along := 0.0
	var lift := 0.0
	if p < 0.5:
		along = STRIDE * 0.5 - (p / 0.5) * STRIDE  # planted: slides back as the body passes
	else:
		var s := (p - 0.5) / 0.5
		along = -STRIDE * 0.5 + s * STRIDE        # swinging forward, lifted
		lift = sin(s * PI) * STEP_HEIGHT
	var foot: Vector3 = leg.foot + (heading * along + Vector3.UP * lift) * _stride
	var hip: Vector3 = _chassis.transform * leg.hip
	var knee := _solve_knee(hip, foot, leg.thigh, leg.shin, leg.out)

	var id: String = leg.id
	_segment(visual.get_node("Thigh" + id), hip, knee)
	_segment(visual.get_node("ThighArmor" + id), hip.lerp(knee, 0.15), hip.lerp(knee, 0.85))
	_segment(visual.get_node("Shin" + id), knee, foot)
	_segment(visual.get_node("ShinGuard" + id), knee.lerp(foot, 0.08), knee.lerp(foot, 0.62))
	_segment(visual.get_node("Piston" + id), knee.lerp(foot, 0.62), knee.lerp(foot, 0.85))
	(visual.get_node("Hip" + id) as Node3D).position = hip
	(visual.get_node("Knee" + id) as Node3D).position = knee
	(visual.get_node("KneeCap" + id) as Node3D).position = knee + leg.out * 0.11 + Vector3.UP * 0.12
	(visual.get_node("Foot" + id) as Node3D).position = foot - Vector3.UP * 0.05
	(visual.get_node("FootGlow" + id) as Node3D).position = foot + Vector3.UP * 0.03


## Two-bone IK: where the knee goes for a hip, a foot and the two bone lengths,
## bending out and up (toward `out` and the sky), like a spider's.
static func _solve_knee(hip: Vector3, foot: Vector3, thigh: float, shin: float, out: Vector3) -> Vector3:
	var span := foot - hip
	var dist := clampf(span.length(), 0.05, thigh + shin - 0.001)
	var along := span.normalized()
	var x := (thigh * thigh - shin * shin + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(thigh * thigh - x * x, 0.0))
	var pole := out + Vector3.UP * 1.2
	var bend := (pole - along * pole.dot(along)).normalized()
	return hip + along * x + bend * h


## Stretches a unit-tall box between two points.
static func _segment(node: Node3D, from: Vector3, to: Vector3) -> void:
	var span := to - from
	var length := span.length()
	if length < 0.001:
		return
	var y := span / length
	var x := Vector3.UP.cross(y) if absf(y.y) < 0.99 else Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y).normalized()
	node.transform = Transform3D(Basis(x, y * length, z), (from + to) * 0.5)

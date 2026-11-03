class_name ArtilleryGolem
extends MortarEnemy
## The Mortar's body: a hunched stone golem bound in brass, knuckle-walking on
## its fists, with a rune-coiled siege mortar on its back powered by a floating
## arcane crystal. Same fight as MortarEnemy; this animates it:
##   walking   stout legs stomp and the knuckles plant in turn, the body rolling
##             with each step; the crystal floats and turns above its back
##   charging  it braces (fists planted wide, body low), the barrel lifts, the
##             crystal spins fast and flares, the coils glow brighter
##   firing    the barrel kicks back and down, the body rocks, a flash at the
##             muzzle, and the crystal dims as it settles

## Where the body rocks about (Visual space).
const CENTER := Vector3(0.0, 0.9, 0.0)

@onready var _hip_l: Node3D = $Visual/HipL
@onready var _hip_r: Node3D = $Visual/HipR
@onready var _arm_l: Node3D = $Visual/ArmL
@onready var _arm_r: Node3D = $Visual/ArmR
@onready var _gun: Node3D = $Visual/Gun
@onready var _crystal: Node3D = $Visual/Crystal
@onready var _halo: Node3D = $Visual/Crystal/Halo
@onready var _crystal_light: OmniLight3D = $Visual/Crystal/Light
@onready var _crystal_mat: StandardMaterial3D = $Visual/Crystal/Top.get_surface_override_material(0)

# [lean, lift, left leg, right leg, left arm, right arm, gun elevation]
var _pose_now := PackedFloat32Array([0, 0, 0, 0, 0.25, 0.25, 0])
var _gait := 0.0
var _spin := 0.0
var _recoil := 0.0
var _flash: OmniLight3D
var _gun_rest := Vector3.ZERO
var _crystal_rest := Vector3.ZERO


func _ready() -> void:
	super()
	_gun_rest = _gun.position
	_crystal_rest = _crystal.position
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.55, 0.2)
	_flash.omni_range = 5.0
	_flash.light_energy = 0.0
	_flash.position = Vector3(0.0, 0.95, -0.7)
	_gun.add_child(_flash)


func _strike() -> void:
	super()
	_recoil = 1.0
	_flash.light_energy = 7.0


func _physics_process(delta: float) -> void:
	super(delta)
	if _dead:
		return
	_recoil = maxf(_recoil - delta * 3.0, 0.0)
	_flash.light_energy = maxf(_flash.light_energy - delta * 35.0, 0.0)
	var speed := Vector2(velocity.x, velocity.z).length()
	var stride := clampf(speed / maxf(move_speed, 0.1) * 1.3, 0.0, 1.0)
	_gait = fmod(_gait + delta * (1.5 + speed * 2.2), TAU)
	var step := sin(_gait)
	var charging := state == State.WINDUP

	# Walking: legs alternate, the fists plant opposite them, the body rolls.
	var target := PackedFloat32Array([
		-0.06 * stride,
		-absf(step) * 0.06 * stride,
		step * 0.45 * stride,
		-step * 0.45 * stride,
		0.25 - step * 0.35 * stride,
		0.25 + step * 0.35 * stride,
		0.0,
	])
	var rate := 10.0
	if charging:
		target = PackedFloat32Array([0.06, -0.12, 0.3, -0.3, 0.55, 0.55, 0.18])  # braced, barrel up
		rate = 8.0
	var blend := 1.0 - exp(-rate * delta)
	for i in _pose_now.size():
		_pose_now[i] = lerpf(_pose_now[i], target[i], blend)

	var roll := step * 0.05 * stride
	var tilt := Basis.from_euler(Vector3(_pose_now[0] + _recoil * 0.1, 0.0, roll))
	visual.transform = Transform3D(tilt, Vector3(0.0, _pose_now[1], 0.0) + CENTER - tilt * CENTER)
	_hip_l.rotation.x = _pose_now[2]
	_hip_r.rotation.x = _pose_now[3]
	_arm_l.rotation.x = _pose_now[4]
	_arm_r.rotation.x = _pose_now[5]
	# The mortar: lifts while charging, kicks back and down when it fires.
	_gun.rotation.x = _pose_now[6] - _recoil * 0.3
	_gun.position = _gun_rest + Vector3(0.0, -0.08 * _recoil, 0.12 * _recoil)

	# The crystal: floats and turns; spins up and flares while charging.
	_spin += delta * (7.0 if charging else 1.2)
	_crystal.position = _crystal_rest + Vector3(0.0, sin(Time.get_ticks_msec() * 0.003) * 0.08, 0.0)
	_crystal.rotation.y = _spin
	_halo.rotation.z = _spin * 0.7
	var glow := 5.0 if charging else (0.6 if _recoil > 0.0 else 2.0)
	_crystal_mat.emission_energy_multiplier = lerpf(_crystal_mat.emission_energy_multiplier, glow, 1.0 - exp(-6.0 * delta))
	_crystal_light.light_energy = _crystal_mat.emission_energy_multiplier * 0.4

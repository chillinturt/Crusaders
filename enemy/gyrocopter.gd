class_name Gyrocopter
extends RangedEnemy
## The Wasp's body: a little steampunk gyrocopter. A brass boiler hull with a
## glass cockpit dome, a spinning rotor, a tail rotor, a smokestack puffing
## steam and a blunderbuss cannon under the nose. Same fight as RangedEnemy;
## this animates it:
##   flying    the rotors spin, it banks into turns and dips its nose to fly
##             forward, bobbing gently in the air
##   charging  the rotor spins up and the stack belches more smoke
##   firing    the cannon kicks back and the whole craft rocks up

@onready var _rotor: Node3D = $Visual/Rotor
@onready var _tail_rotor: Node3D = $Visual/TailRotor
@onready var _gun: Node3D = $Visual/Gun
@onready var _stack: Node3D = $Visual/Stack

var _recoil := 0.0
var _gun_rest := Vector3.ZERO
var _smoke: CPUParticles3D


func _ready() -> void:
	super()
	_gun_rest = _gun.position
	_smoke = _make_smoke()
	_stack.add_child(_smoke)
	_smoke.position = Vector3(0.0, 0.25, 0.0)


func _strike() -> void:
	super()
	_recoil = 1.0


func _physics_process(delta: float) -> void:
	super(delta)
	var charging := state == State.WINDUP
	_rotor.rotation.y += (40.0 if charging else 28.0) * delta
	_tail_rotor.rotation.x += 45.0 * delta
	if _dead:
		return
	_recoil = maxf(_recoil - delta * 3.0, 0.0)
	# Bank and pitch with how it's moving (in its own frame), and bob.
	var local := global_basis.inverse() * velocity
	var pitch := clampf(local.z * 0.05, -0.35, 0.35) + _recoil * 0.2
	var roll := clampf(-local.x * 0.06, -0.4, 0.4)
	var blend := 1.0 - exp(-5.0 * delta)
	visual.rotation = visual.rotation.lerp(Vector3(pitch, 0.0, roll), blend)
	visual.position.y = sin(Time.get_ticks_msec() * 0.004) * 0.06
	_gun.position = _gun_rest + Vector3(0.0, 0.0, 0.15 * _recoil)
	_smoke.speed_scale = 2.2 if charging else 1.0  # puffs harder while charging


func _make_smoke() -> CPUParticles3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	var puff := SphereMesh.new()
	puff.radius = 0.12
	puff.height = 0.24
	puff.material = material
	var fade := Gradient.new()
	fade.set_color(0, Color(0.85, 0.85, 0.85, 0.7))
	fade.set_color(1, Color(0.6, 0.6, 0.6, 0.0))
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.6))
	grow.add_point(Vector2(1.0, 2.5))
	var smoke := CPUParticles3D.new()
	smoke.mesh = puff
	smoke.amount = 24
	smoke.lifetime = 1.4
	smoke.local_coords = false
	smoke.direction = Vector3.UP
	smoke.spread = 15.0
	smoke.initial_velocity_min = 0.8
	smoke.initial_velocity_max = 1.4
	smoke.gravity = Vector3(0.0, 0.4, 0.0)
	smoke.scale_amount_curve = grow
	smoke.color_ramp = fade
	return smoke
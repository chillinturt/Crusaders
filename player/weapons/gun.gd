extends Weapon
## Hitscan gun: the rifle, shotgun, sniper and revolver are all this script with
## different numbers. Fires `pellets` rays from the center of the screen inside a
## spread cone, damages anything with a take_damage() method, and draws tracers.
## Loses damage at range, and gets less accurate with sustained fire, while
## moving (if moving_spread is set) and while airborne.
## The wielder's Aiming skill raises damage and reload speed and tightens spread;
## hitting enemies trains it.

@export_group("Shot")
@export var damage := 15.0          ## per pellet
@export var pellets := 1
## If set (e.g. 3x3), pellets fly in a fixed grid of this many columns and rows
## spanning the spread cone, instead of scattering randomly. Overrides pellets.
@export var pellet_grid := Vector2i.ZERO
@export var fire_rate := 6.0        ## shots per second
## Hold to keep firing. Off = one shot per click.
## Off = one shot per click. (Every gun in the game fires while held; fire_rate paces it.)
@export var automatic := true
@export var max_range := 300.0
@export var recoil_kick := 0.06     ## how far the gun model jumps back per shot

@export_group("Falloff")
## Full damage up to this distance...
@export var falloff_start := 12.0
## ...dropping linearly to falloff_min x damage at this distance and beyond.
@export var falloff_end := 45.0
@export var falloff_min := 0.4

@export_group("Spread")
## Degrees. Cone half-angle for a first, standing shot.
@export var base_spread := 0.4
## Each shot adds this much (degrees) until max_bloom...
@export var spread_per_shot := 0.35
@export var max_bloom := 3.0
## ...and it recovers at this many degrees per second once you stop firing...
@export var bloom_recovery := 6.0
## ...for at least this long (so sustained fire actually builds up spread).
@export var bloom_recovery_delay := 0.25
## Extra spread while not on the ground.
@export var airborne_spread := 1.5
## Extra spread at full running speed (scales with how fast you're moving).
@export var moving_spread := 0.0

## Aiming XP per 10 damage dealt to enemies.
const XP_PER_10_DAMAGE := 1.0

@onready var muzzle: Marker3D = $Muzzle
@onready var flash: OmniLight3D = $Muzzle/Flash

var _bloom := 0.0
var _since_shot := 0.0
var _trigger_released := true
var _tracer_material: StandardMaterial3D


func _ready() -> void:
	super()
	flash.visible = false
	_tracer_material = StandardMaterial3D.new()
	_tracer_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tracer_material.albedo_color = Color(1.0, 0.85, 0.4)


func unequip() -> void:
	super()
	_bloom = 0.0


func _weapon_tick(delta: float) -> void:
	_since_shot += delta
	if _since_shot > bloom_recovery_delay:
		_bloom = maxf(_bloom - bloom_recovery * delta, 0.0)

	var trigger := Input.is_action_pressed("attack")
	if trigger and can_attack() and (automatic or _trigger_released) and _use_round():
		_cooldown = 1.0 / (fire_rate * _upgrades().fire_rate_multiplier())
		_since_shot = 0.0
		_fire()
	_trigger_released = not trigger


func spread_degrees() -> float:
	var wielder := _wielder()
	var spread := base_spread + _bloom
	if not wielder.is_on_floor():
		spread += airborne_spread
	spread += moving_spread * clampf(Vector2(wielder.velocity.x, wielder.velocity.z).length() / 8.0, 0.0, 1.5)
	return spread * wielder.skills.aim_spread_multiplier()


func _fire() -> void:
	var camera := _camera()
	var skills: Skills = _wielder().skills
	var from := camera.global_position
	var cone := deg_to_rad(spread_degrees())
	var space := get_world_3d().direct_space_state
	var hit_any := false

	for dir: Vector3 in _pellet_directions(camera.global_basis, cone):
		# World + characters, not yourself. Bullets fly through portals.
		var result := Portal.raycast(space, from, from + dir * max_range, 1 | 2, [_wielder().get_rid()])
		var segments: Array = result.segments
		var last: Array = segments[segments.size() - 1]
		var end: Vector3 = last[1]
		if result.has("collider"):
			if result.collider.has_method("take_damage"):
				var falloff := remap(result.length, falloff_start, falloff_end, 1.0, falloff_min)
				var amount := damage * clampf(falloff, falloff_min, 1.0) * skills.aim_damage_multiplier() * _upgrades().damage_multiplier()
				result.collider.take_damage(amount, last[0], end)
				if result.collider is Enemy:
					skills.add_xp(&"aiming", amount / 10.0 * XP_PER_10_DAMAGE)
					hit_any = true
			_spawn_effect(_make_impact(end), 0.08)
		for index in segments.size():
			var start: Vector3 = muzzle.global_position if index == 0 else segments[index][0]
			_spawn_effect(_make_tracer(start, segments[index][1]), 0.05)

	if hit_any:
		hit_target.emit()
	_bloom = minf(_bloom + spread_per_shot, max_bloom)
	position.z += recoil_kick
	flash.visible = true
	get_tree().create_timer(0.04).timeout.connect(func() -> void: flash.visible = false)


## One direction per pellet: a fixed grid across the cone, or random scatter.
func _pellet_directions(aim_basis: Basis, cone: float) -> Array[Vector3]:
	var forward := -aim_basis.z
	var directions: Array[Vector3] = []
	if pellet_grid.x > 0 and pellet_grid.y > 0:
		var reach := tan(cone)
		for row in pellet_grid.y:
			for column in pellet_grid.x:
				# -1..1 across the grid (0 for a single row or column).
				var u := 2.0 * column / maxf(pellet_grid.x - 1, 1) - 1.0 if pellet_grid.x > 1 else 0.0
				var v := 2.0 * row / maxf(pellet_grid.y - 1, 1) - 1.0 if pellet_grid.y > 1 else 0.0
				directions.append((forward + aim_basis.x * u * reach + aim_basis.y * v * reach).normalized())
	else:
		for pellet in pellets:
			directions.append(_random_in_cone(forward, aim_basis, cone))
	return directions


## Uniform random direction within half-angle `angle` of `forward`.
static func _random_in_cone(forward: Vector3, aim_basis: Basis, angle: float) -> Vector3:
	if angle <= 0.0:
		return forward
	var r := tan(angle) * sqrt(randf())
	var theta := randf() * TAU
	return (forward + aim_basis.x * r * cos(theta) + aim_basis.y * r * sin(theta)).normalized()


func _make_tracer(a: Vector3, b: Vector3) -> MeshInstance3D:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _tracer_material)
	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(b)
	mesh.surface_end()
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst


func _make_impact(at: Vector3) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	var inst := MeshInstance3D.new()
	inst.mesh = sphere
	inst.material_override = _tracer_material
	inst.position = at
	return inst

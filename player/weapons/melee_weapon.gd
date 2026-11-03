extends Weapon
## Melee swing. Each weapon sweeps its own arc:
##   windup   the weapon is drawn back to where the arc starts
##   active   it sweeps the arc. A fan of hit rays (ray_count of them, each as
##            thick as `thickness`) follows the weapon across it, cast in order
##            as the weapon passes, so what you see is what hits
##   recovery it comes back to rest
## Everything a ray touches is hit once per swing, so a wide arc hits a whole
## crowd. Walls stop the rays. Projectiles the arc passes are deflected back
## along your aim.
##
## Arcs are given in degrees relative to where you look: yaw (positive = to your
## right) and pitch (positive = up) for the start and the end. A weapon with
## several arcs uses them in turn (the machete slashes back and forth).
##
## Damage and swing speed scale with the wielder's Strength, and damage also
## scales with how fast you're moving. What sets the weapons apart beyond their
## arc and timing:
##   punish_multiplier  extra damage against enemies caught mid-attack or
##                      recovering (the axe)
##   slam_radius        the swing ends in a shockwave where it strikes the
##                      ground: nearby enemies are hurt and launched, and you
##                      are bounced upward (the sledgehammer)

@export_group("Swing")
@export var damage := 40.0
@export var windup := 0.08          ## time from click to the arc starting
@export var active_time := 0.12     ## time the arc takes (the hit window)
@export var recovery := 0.3         ## time after the arc before you can swing again
@export var reach := 2.2
## Width of each hit ray (near misses count, and low or small enemies aren't skipped).
@export var thickness := 0.7
## Extra height of each hit ray, so enemies a little above or below your aim
## (on a slope, crouched low) still count.
@export var height_slack := 0.8
@export_range(2, 64) var ray_count := 16
## (start yaw, start pitch, end yaw, end pitch) in degrees; one entry per swing, used in turn.
@export var arcs: PackedVector4Array = [Vector4(50, 10, -50, -20)]
## How far the weapon rolls over into the swing, in degrees (visual).
@export var swing_roll := 60.0
## Velocity added to whatever you hit, along your aim (plus a bit of lift).
@export var push_force := 3.0
## Extra damage per m/s you're moving above running speed (8 m/s): swing in fast
## off a grapple or a bhop chain for big hits.
@export var speed_damage_bonus := 0.05
## Deflection is more forgiving than hitting (projectiles are small and fast):
## this much is added to the rays' thickness for it.
@export var deflect_bonus := 0.6

@export_group("Special")
## Damage multiplier against enemies that are winding up an attack or recovering.
@export var punish_multiplier := 1.0
## > 0: a shockwave this wide where the swing ends on the ground.
@export var slam_radius := 0.0
## Shockwave damage at its center, as a fraction of the weapon's damage.
@export var slam_damage := 0.5
@export var slam_force := 12.0
## Upward speed the shockwave gives you.
@export var slam_hop := 7.0

const XP_HIT := 3.0
const XP_DEFLECT := 5.0

enum Phase { IDLE, WINDUP, ACTIVE, RECOVER }

var _phase := Phase.IDLE
var _time := 0.0
var _speed := 1.0       # swing speed multiplier, fixed when the swing starts
var _arc := Vector4.ZERO
var _next_arc := 0
var _rays_done := 0
var _hit := {}          # what this swing has already hit
var _grazed := {}       # body -> where a ray's thickness (not its middle) touched it
var _hit_enemy := false


func _process(delta: float) -> void:
	if _phase == Phase.IDLE:
		super(delta)  # mid-swing the swing owns the pose


func unequip() -> void:
	super()
	_phase = Phase.IDLE  # switching mid-swing cancels it
	position = _rest_position
	rotation = _rest_rotation


func is_swinging() -> bool:
	return _phase != Phase.IDLE


func _weapon_tick(delta: float) -> void:
	if _phase == Phase.IDLE:
		if can_attack() and Input.is_action_pressed("attack"):
			_begin_swing()
		return
	_time += delta
	match _phase:
		Phase.WINDUP:
			var t := minf(_time / (windup / _speed), 1.0)
			_pose(_angles(0.0), ease(t, 0.5))
			if t >= 1.0:
				_phase = Phase.ACTIVE
				_time = 0.0
		Phase.ACTIVE:
			var t := minf(_time / (active_time / _speed), 1.0)
			_pose(_angles(t), 1.0)
			# Cast the rays the weapon has passed since last tick.
			while _rays_done < ray_count and float(_rays_done) / (ray_count - 1) <= t:
				_cast_ray(_direction(float(_rays_done) / (ray_count - 1)))
				_rays_done += 1
			if t >= 1.0:
				# Near misses count, once it's clear no ray struck them squarely
				# (a square hit says exactly where, which matters for weak spots).
				for body: Variant in _grazed:
					if is_instance_valid(body):
						_hit_body(body, _grazed[body])
				if slam_radius > 0.0:
					_slam()
				_phase = Phase.RECOVER
				_time = 0.0
		Phase.RECOVER:
			var t := minf(_time / (recovery / _speed), 1.0)
			_pose(_angles(1.0), 1.0 - ease(t, -2.0))
			if t >= 1.0:
				_phase = Phase.IDLE
				position = _rest_position
				rotation = _rest_rotation


func _begin_swing() -> void:
	_speed = _wielder().skills.swing_speed_multiplier()
	_arc = arcs[_next_arc % arcs.size()] if not arcs.is_empty() else Vector4(50, 10, -50, -20)
	_next_arc += 1
	_phase = Phase.WINDUP
	_time = 0.0
	_rays_done = 0
	_hit.clear()
	_grazed.clear()
	_hit_enemy = false
	_cooldown = (windup + active_time + recovery) / _speed


# --- The arc --------------------------------------------------------------------

## (yaw, pitch) in degrees at a point along the current arc (0 = start, 1 = end).
func _angles(along: float) -> Vector2:
	return Vector2(_arc.x, _arc.y).lerp(Vector2(_arc.z, _arc.w), along)


## World direction of the hit ray at that point of the arc.
func _direction(along: float) -> Vector3:
	var angles := _angles(along)
	var local := Basis.from_euler(Vector3(deg_to_rad(angles.y), deg_to_rad(-angles.x), 0.0)) * Vector3.FORWARD
	return (_camera().global_basis * local).normalized()


## Holds the weapon along the arc (weight 1) or somewhere between that and rest.
func _pose(angles: Vector2, weight: float) -> void:
	var yaw := deg_to_rad(angles.x)
	var pitch := deg_to_rad(angles.y)
	var hand := Vector3(sin(yaw) * 0.45, -0.2 + sin(pitch) * 0.35, -0.42)
	var roll := deg_to_rad(swing_roll) * signf(_arc.z - _arc.x)  # leaning into a sideways swing
	var turn := Vector3(pitch * 0.9 + 0.15, -yaw, roll)
	position = _rest_position.lerp(hand, weight)
	rotation = _rest_rotation.lerp(turn, weight)


# --- Hitting --------------------------------------------------------------------

func _cast_ray(direction: Vector3) -> void:
	var wielder := _wielder()
	var camera := _camera()
	var space := get_world_3d().direct_space_state
	var from := camera.global_position

	# Walls stop the swing (and built structures take the hit).
	var length := reach
	var wall_query := PhysicsRayQueryParameters3D.create(from, from + direction * reach)
	wall_query.collision_mask = 1
	var wall := space.intersect_ray(wall_query)
	if wall:
		length = from.distance_to(wall.position)
		_hit_body(wall.collider, wall.position)
	if length < 0.05:
		return
	var to := from + direction * length

	# Where the middle of the ray strikes a character, exactly (for weak spots).
	var exact_query := PhysicsRayQueryParameters3D.create(from, to)
	exact_query.collision_mask = 2
	exact_query.exclude = [wielder.get_rid()]
	var exact := space.intersect_ray(exact_query)
	if exact:
		_hit_body(exact.collider, exact.position)
	# Everyone else the thick ray touches: remembered, with the point on the
	# ray nearest to them (taking them as an upright line, feet to head).
	for result in space.intersect_shape(_ray_shape(from, direction, length, thickness, 2, false), 8):
		var body: Node3D = result.collider
		if _hit.has(body) or _grazed.has(body):
			continue
		var tall: float = body.get("eye_height") + 0.5 if body.get("eye_height") != null else 1.8
		_grazed[body] = Geometry3D.get_closest_points_between_segments(from, to, body.global_position, body.global_position + Vector3.UP * tall)[0]

	for result in space.intersect_shape(_ray_shape(from, direction, length, thickness + deflect_bonus, 8, true), 8):
		var projectile := (result.collider as Node).get_parent() as Projectile
		if projectile and projectile.shooter != wielder and projectile.deflect(-camera.global_basis.z, wielder):
			wielder.skills.add_xp(&"strength", XP_DEFLECT)
			wielder.notify("Deflected!")
			hit_target.emit()


func _hit_body(body: Object, at: Vector3) -> void:
	if _hit.has(body) or not body.has_method("take_damage"):
		return
	_hit[body] = true
	var wielder := _wielder()
	var skills: Skills = wielder.skills
	var forward := -_camera().global_basis.z
	var amount: float = damage * skills.melee_damage_multiplier() * _upgrades().damage_multiplier()
	amount *= 1.0 + speed_damage_bonus * maxf(wielder.velocity.length() - 8.0, 0.0)
	if body is Enemy and (body.state == Enemy.State.WINDUP or body.state == Enemy.State.RECOVER):
		amount *= punish_multiplier
	if body.has_method("take_melee_damage"):
		body.take_melee_damage(amount, _camera().global_position, at)  # some things are weak to blades
	else:
		body.take_damage(amount, _camera().global_position, at)
	if body.has_method("push"):
		body.push(Vector3(forward.x, 0.0, forward.z).normalized() * push_force + Vector3.UP * push_force * 0.4)
	if body is Enemy:
		skills.add_xp(&"strength", XP_HIT)
		if not _hit_enemy:
			_hit_enemy = true
			hit_target.emit()


## A box along a hit ray: the ray, with thickness.
func _ray_shape(from: Vector3, direction: Vector3, length: float, width: float, mask: int, areas: bool) -> PhysicsShapeQueryParameters3D:
	var box := BoxShape3D.new()
	box.size = Vector3(width, width + height_slack, length)
	var up := Vector3.UP if absf(direction.y) < 0.95 else Vector3.RIGHT
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = box
	params.transform = Transform3D(Basis.looking_at(direction, up), from + direction * length * 0.5)
	params.collision_mask = mask
	params.collide_with_areas = areas
	params.collide_with_bodies = not areas
	params.exclude = [_wielder().get_rid()]
	return params


# --- Shockwave --------------------------------------------------------------------

## Where the swing ends on the ground: hurts and launches enemies around that
## spot (ones the swing itself hit are only launched), and bounces you upward.
func _slam() -> void:
	var wielder := _wielder()
	var from := _camera().global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + _direction(1.0) * (reach + 0.6))
	query.collision_mask = 1
	var ground := get_world_3d().direct_space_state.intersect_ray(query)
	if not ground:
		return
	var center: Vector3 = ground.position
	var power: float = damage * slam_damage * wielder.skills.melee_damage_multiplier() * _upgrades().damage_multiplier()
	for enemy: Enemy in get_tree().get_nodes_in_group(&"enemies"):
		var offset := enemy.global_position + Vector3.UP * 0.5 - center
		if offset.length() > slam_radius:
			continue
		var falloff := 1.0 - 0.6 * offset.length() / slam_radius
		if not _hit.has(enemy):
			_hit[enemy] = true
			enemy.take_damage(power * falloff, center)
			wielder.skills.add_xp(&"strength", XP_HIT)
			if not _hit_enemy:
				_hit_enemy = true
				hit_target.emit()
		var away := Vector3(offset.x, 0.0, offset.z).normalized()
		enemy.push((away * 0.6 + Vector3.UP) * slam_force * falloff)
	wielder.velocity.y = maxf(wielder.velocity.y, slam_hop)
	_spawn_ring(center)


func _spawn_ring(at: Vector3) -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.9, 0.7, 0.6)
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.08
	var ring := MeshInstance3D.new()
	ring.mesh = disc
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spawn_effect(ring, 0.3)
	ring.global_position = at + Vector3.UP * 0.1
	ring.scale = Vector3(0.3, 1.0, 0.3)
	var tween := ring.create_tween().set_parallel()
	tween.tween_property(ring, "scale", Vector3(slam_radius, 1.0, slam_radius), 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(material, "albedo_color:a", 0.0, 0.25)

class_name Dragon
extends Enemy
## A flying boss. It takes turns between three attacks, always in the same
## order, flying in close for the close ones and circling at range for the long
## one. Each has its own tell, and it holds still for a moment after every one:
##   Scorch   close range: rears its head (mouth glows) and sweeps a wide, short
##            cone of fire across you. Get out of the cone or behind cover.
##   Torch    long range: a longer glow, then a narrow jet of fire that reaches
##            far but turns slowly, so keep moving sideways.
##   Claw     wings flare up, then it dives straight at where you were and rakes
##            you once if it passes close. Sidestep it.
## Its scales shrug off most damage; the head takes full damage, and blades to
## the head (grapple on: the hook holds in a boss) do triple.
##
## Escaping the fire: once it starts breathing, its body is rooted and only the
## neck moves, and the neck can't bend back under the belly or round behind it.
## Get beneath it or behind its head and the flame can't touch you. Cover
## (walls, rock, a built wall) also blocks it.
##
## Its weakness: while it inhales for a fire attack, a glowing ember swells in
## its mouth. Hit the mouth hard enough then (a sniper shot, a burst of rifle
## fire, a rocket in the face) and it chokes: the fire bursts in its throat, it
## takes a big chunk of damage and crashes to the ground, wings limp, head on
## the ground. While it's down its scales don't protect it, and its head is in
## easy reach of a blade.

enum Attack { NONE, SCORCH, TORCH, CLAW }

@export_group("Damage zones")
@export var body_damage_multiplier := 0.4
@export var head_damage_multiplier := 1.0
@export var melee_head_multiplier := 3.0
## Hits this close to the middle of the head count as head hits.
@export var head_radius := 1.6

@export_group("Scorch (close fire)")
@export var scorch_range := 12.0
@export var scorch_angle := 32.0        ## half-angle of the cone, degrees
@export var scorch_dps := 34.0
@export var scorch_windup := 0.8
@export var scorch_time := 1.3
@export var scorch_track := 45.0        ## degrees per second it can swing the flame

@export_group("Torch (long fire)")
@export var torch_min_range := 12.0
@export var torch_range := 40.0
@export var torch_angle := 7.0
@export var torch_dps := 42.0
@export var torch_windup := 1.0
@export var torch_time := 1.8
## Slower than you can run across its view (beyond ~6 m), so strafing escapes it.
@export var torch_track := 14.0

@export_group("Claw (dive)")
@export var claw_range := 18.0
@export var claw_windup := 0.7
@export var dive_speed := 22.0
@export var dive_knockback := 14.0
@export var claw_hit_radius := 3.5

@export_group("Choking")
## Head damage during a fire attack's inhale that makes it choke (grows with
## its health at higher levels).
@export var choke_threshold := 80.0
## Share of its max health the backfire takes.
@export var choke_damage := 0.12
## How long it lies on the ground afterward.
@export var downed_time := 5.0

@export_group("Pacing")
## Where it circles while lining up the long-range attack.
@export var torch_band := Vector2(14.0, 30.0)
## If it can't get in range for its next attack for this long, it uses the
## long-range one instead (and tries the close one again after).
@export var patience := 5.0
@export var min_recover_time := 1.0

const SEQUENCE: Array[Attack] = [Attack.SCORCH, Attack.CLAW, Attack.TORCH]

@onready var _neck: Node3D = $Visual/NeckPivot
@onready var _head: Node3D = $Visual/NeckPivot/Head
@onready var _mouth: Node3D = $Visual/NeckPivot/Mouth
@onready var _glow: OmniLight3D = $Visual/NeckPivot/Mouth/Glow

var _attack := Attack.NONE
var _next := 0
var _aim := Vector3.FORWARD
var _breath_left := 0.0
var _diving := false
var _dive_hit := false
var _dive_time := 0.0
var _dive_length := 0.0
var _orbit := 1.0
var _melee_hit := false
var _waiting := 0.0
var _choke_taken := 0.0
var _downed := false
var _ember: MeshInstance3D

## The first fire attack the player sees comes with a hint (once per game).
static var _hinted := false
var _fire: CPUParticles3D
var _wing_tween: Tween


func apply_level(level: int) -> void:
	var windup_before := windup_time
	var damage_before := damage
	var health_before := max_health
	super(level)
	choke_threshold *= max_health / health_before
	var tempo := windup_time / windup_before
	var harder := damage / damage_before
	scorch_windup *= tempo
	torch_windup *= tempo
	claw_windup *= tempo
	scorch_dps *= harder
	torch_dps *= harder
	recover_time = maxf(recover_time, min_recover_time)


func _ready() -> void:
	super()
	$Visual/Eyes.reparent(_neck)  # the eyes follow the head
	_orbit = 1.0 if randf() < 0.5 else -1.0
	_fire = _make_fire()
	_mouth.add_child(_fire)
	_glow.light_energy = 0.0
	_ember = _make_ember()
	_mouth.add_child(_ember)
	_sync_head_shape()


func _physics_process(delta: float) -> void:
	super(delta)
	if state == State.CHASE:
		_waiting += delta


# --- Moving -------------------------------------------------------------------

## Gets into range for the next attack in its rotation: right in for the close
## ones, circling at a distance for the long one.
func _chase_move_dir(flat_to_target: Vector3) -> Vector3:
	var dist := flat_to_target.length()
	if dist < 0.1:
		return Vector3.ZERO
	var toward := flat_to_target / dist
	var band := torch_band
	match SEQUENCE[_next]:
		Attack.SCORCH: band = Vector2(5.0, 9.0)  # close, but not overhead
		Attack.CLAW: band = Vector2(4.0, claw_range * 0.6)
	if dist > band.y:
		return toward
	if dist < band.x:
		return -toward
	if randf() < 0.004:
		_orbit = -_orbit  # now and then, circle the other way
	return toward.cross(Vector3.UP) * _orbit


# --- Choosing an attack -------------------------------------------------------

## The next attack in its rotation once you're in range for it. If that takes
## too long, the long-range one fills in (the rotation waits).
func _pick(distance: float) -> Attack:
	var planned: Attack = SEQUENCE[_next]
	if _fits(planned, distance):
		_next = (_next + 1) % SEQUENCE.size()
		return planned
	if _waiting > patience and planned != Attack.TORCH and _fits(Attack.TORCH, distance):
		return Attack.TORCH
	return Attack.NONE


func _fits(attack: Attack, distance: float) -> bool:
	match attack:
		Attack.SCORCH: return distance <= scorch_range
		Attack.TORCH: return distance >= torch_min_range and distance <= torch_range
		Attack.CLAW: return distance <= claw_range
	return false


func _can_start_attack(to_target: Vector3) -> bool:
	if not _can_see:
		return false
	_attack = _pick(to_target.length())
	if _attack != Attack.NONE:
		_waiting = 0.0
	return _attack != Attack.NONE


func _on_windup_start() -> void:
	_aim = (_target_point() - _neck.global_position).normalized()
	_choke_taken = 0.0
	match _attack:
		Attack.SCORCH:
			_state_time = scorch_windup
			_glow_to(3.0, scorch_windup)
			_ember_to(1.0, scorch_windup)
		Attack.TORCH:
			_state_time = torch_windup
			_glow_to(6.0, torch_windup)
			_ember_to(1.4, torch_windup)
		Attack.CLAW:
			_state_time = claw_windup
			_wings_to(0.9, claw_windup)  # wings flare up
	if _attack != Attack.CLAW and not _hinted and is_instance_valid(_player) and _player.has_method("notify"):
		_hinted = true
		_player.notify("Dragon fire can't reach under its belly or behind its head.")
		_player.notify("Hit the ember in its mouth as it inhales to make it choke!")


func _during_windup(delta: float) -> void:
	_track(_target_point(), 140.0, delta)


func _strike() -> void:
	_set_state(State.RECOVER)
	_ember_to(0.0, 0.1)
	match _attack:
		Attack.SCORCH, Attack.TORCH:
			var scorch := _attack == Attack.SCORCH
			_breath_left = scorch_time if scorch else torch_time
			_state_time = _breath_left + recover_time
			var speed := 16.0 if scorch else 42.0
			var reach := scorch_range if scorch else torch_range
			_fire.spread = scorch_angle if scorch else torch_angle
			_fire.initial_velocity_min = speed * 0.85
			_fire.initial_velocity_max = speed
			_fire.lifetime = reach / speed
			_fire.emitting = true
		Attack.CLAW:
			_wings_to(-0.5, 0.15)  # swept back into the dive
			if not is_instance_valid(_player):
				_state_time = recover_time
				return
			var to_target := _target_point() - (global_position + Vector3.UP * 1.6)
			velocity = to_target.normalized() * dive_speed
			_diving = true
			_dive_hit = false
			_dive_time = 0.0
			_dive_length = (to_target.length() + 5.0) / dive_speed
			_state_time = 10.0  # ends when the dive does


func _holds_still() -> bool:
	return not _diving


func _steer(target_velocity: Vector3, delta: float) -> void:
	if not _downed:
		super(target_velocity, delta)
		return
	# Choked: no lift, it just drops and lies there.
	var flat := Vector3(velocity.x, 0.0, velocity.z).move_toward(Vector3.ZERO, acceleration * delta)
	velocity.x = flat.x
	velocity.z = flat.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - gravity * delta


func _on_recover_end() -> void:
	if _downed:
		_downed = false  # back up into the air
		_neck.rotation = Vector3.ZERO
		_sync_head_shape()
		_wings_to(0.0, 0.6)
		_set_state(State.CHASE)


func _during_recover(delta: float) -> void:
	if _breath_left > 0.0:
		_breath_left -= delta
		_track(_target_point(), scorch_track if _attack == Attack.SCORCH else torch_track, delta)
		_burn(delta)
		if _breath_left <= 0.0:
			_stop_fire()
	elif _diving:
		_dive_time += delta
		if not _dive_hit and is_instance_valid(_player):
			if (global_position + Vector3.UP * 1.6).distance_to(_target_point()) < claw_hit_radius:
				_dive_hit = true
				_player.take_damage(damage, global_position)
				_player.push(Vector3(velocity.x, 0.0, velocity.z).normalized() * dive_knockback + Vector3.UP * 4.0)
		if _dive_time >= _dive_length or (_dive_time > 0.15 and (is_on_floor() or is_on_wall())):
			_diving = false
			_state_time = recover_time
			_wings_to(0.0, 0.5)


func _on_windup_cancelled() -> void:
	_stop_fire()
	_ember_to(0.0, 0.1)
	_diving = false
	_wings_to(0.0, 0.3)


func _die(killed_by_player: bool) -> void:
	_stop_fire()
	super(killed_by_player)


# --- Fire ---------------------------------------------------------------------

## Burns you if you're inside the flame's cone and nothing solid is in the way.
func _burn(delta: float) -> void:
	if not is_instance_valid(_player):
		return
	var scorch := _attack == Attack.SCORCH
	var reach := scorch_range if scorch else torch_range
	var angle := scorch_angle if scorch else torch_angle
	var from := _mouth.global_position
	var to_player := _target_point() - from
	var dist := to_player.length()
	if dist > reach:
		return
	var direction := -_mouth.global_basis.z
	var slack := rad_to_deg(atan2(0.6, maxf(dist, 0.1)))  # you're not a point
	if rad_to_deg(direction.angle_to(to_player)) > angle + slack:
		return
	var query := PhysicsRayQueryParameters3D.create(from, _target_point())
	query.collision_mask = 1
	if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
		return  # behind cover
	var amount := (scorch_dps if scorch else torch_dps) * delta
	if _player.has_method("burn"):
		_player.burn(amount)
	else:
		_player.hurt(amount)


func _stop_fire() -> void:
	_breath_left = 0.0
	if _fire:
		_fire.emitting = false
	_glow_to(0.0, 0.3)


## Turns the head (and body) toward a point at no more than `degrees` per second.
func _track(point: Vector3, degrees: float, delta: float) -> void:
	var wanted := (point - _neck.global_position).normalized()
	var angle := _aim.angle_to(wanted)
	if angle > 0.001:
		_aim = _aim.slerp(wanted, minf(1.0, deg_to_rad(degrees) * delta / angle)).normalized()
	if _breath_left <= 0.0:
		_face(Vector3(_aim.x, 0.0, _aim.z).normalized())  # while breathing the body stays put
	# The neck covers what the slow-turning body hasn't yet.
	var local := global_basis.inverse() * _aim
	_neck.rotation = Vector3(clampf(asin(clampf(local.y, -1.0, 1.0)), -1.45, 0.6), clampf(atan2(-local.x, -local.z), -0.9, 0.9), 0.0)
	_sync_head_shape()


## The head's collision follows the neck, so shots and blades find it where it is.
func _sync_head_shape() -> void:
	$HeadShape.global_position = _head.global_position


# --- Choking ------------------------------------------------------------------

func _is_inhaling() -> bool:
	return state == State.WINDUP and (_attack == Attack.SCORCH or _attack == Attack.TORCH)


## The fire bursts in its throat: it takes a chunk of damage and crashes down.
func _choke() -> void:
	_stop_fire()
	_ember_to(0.0, 0.05)
	_burst()
	_downed = true
	_set_state(State.RECOVER)
	_state_time = downed_time
	_neck.rotation = Vector3(-0.55, 0.0, 0.0)  # head down to the ground
	_sync_head_shape()
	_wings_to(-0.5, 0.4)  # wings hang limp
	var backfire := max_health * choke_damage
	health -= backfire
	_spawn_label("CHOKED %d" % roundi(backfire), Color(1.0, 0.55, 0.1), _mouth.global_position)
	if is_instance_valid(_player) and _player.has_method("notify"):
		_player.notify("The dragon chokes on its own fire!")
	# (Only ever called from _on_damaged: take_damage() handles it dying.)


func _burst() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.6, 0.1, 0.85)
	var ball := SphereMesh.new()
	ball.radius = 1.0
	ball.height = 2.0
	var flash := MeshInstance3D.new()
	flash.mesh = ball
	flash.material_override = material
	get_parent().add_child(flash)
	flash.global_position = _mouth.global_position
	var tween := flash.create_tween().set_parallel()
	tween.tween_property(flash, "scale", Vector3.ONE * 3.0, 0.35)
	tween.tween_property(material, "albedo_color:a", 0.0, 0.35)
	tween.chain().tween_callback(flash.queue_free)


func _make_ember() -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.75, 0.25)
	var ball := SphereMesh.new()
	ball.radius = 0.4
	ball.height = 0.8
	var ember := MeshInstance3D.new()
	ember.mesh = ball
	ember.material_override = material
	ember.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ember.scale = Vector3.ONE * 0.01
	ember.visible = false
	return ember


func _ember_to(size: float, duration: float) -> void:
	_ember.visible = true
	var tween := _ember.create_tween()
	tween.tween_property(_ember, "scale", Vector3.ONE * maxf(size, 0.01), duration)
	if size <= 0.0:
		tween.tween_callback(func() -> void: _ember.visible = false)


func _target_point() -> Vector3:
	return _player.global_position + Vector3.UP * 0.9 if is_instance_valid(_player) else global_position - global_basis.z * 10.0


func _make_fire() -> CPUParticles3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	# Soft round puffs rather than squares.
	var puff := Gradient.new()
	puff.set_color(0, Color(1, 1, 1, 1))
	puff.set_color(1, Color(1, 1, 1, 0))
	var puff_texture := GradientTexture2D.new()
	puff_texture.gradient = puff
	puff_texture.fill = GradientTexture2D.FILL_RADIAL
	puff_texture.fill_from = Vector2(0.5, 0.5)
	puff_texture.fill_to = Vector2(1.0, 0.5)
	puff_texture.width = 64
	puff_texture.height = 64
	material.albedo_texture = puff_texture
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = material
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.35, 0.95))
	ramp.set_color(1, Color(0.25, 0.05, 0.02, 0.0))
	ramp.add_point(0.3, Color(1.0, 0.45, 0.05, 0.85))
	ramp.add_point(0.7, Color(0.75, 0.15, 0.02, 0.5))
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.4))
	grow.add_point(Vector2(1.0, 3.0))
	var fire := CPUParticles3D.new()
	fire.mesh = quad
	fire.amount = 260
	fire.emitting = false
	fire.local_coords = false
	fire.direction = Vector3(0, 0, -1)
	fire.gravity = Vector3(0, 1.5, 0)
	fire.scale_amount_min = 1.1
	fire.scale_amount_max = 2.0
	fire.scale_amount_curve = grow
	fire.color_ramp = ramp
	return fire


# --- Tells --------------------------------------------------------------------

func _glow_to(energy: float, duration: float) -> void:
	_glow.create_tween().tween_property(_glow, "light_energy", energy, duration)


func _wings_to(angle: float, duration: float) -> void:
	# Raised wings hold still (the flap pauses while a tween owns them).
	if _wing_tween:
		_wing_tween.kill()
	_flapping = false
	_wing_tween = create_tween().set_parallel()
	for wing: Node3D in _wings:
		_wing_tween.tween_property(wing, "rotation:z", angle * signf(wing.position.x), duration)
	if is_zero_approx(angle):
		_wing_tween.chain().tween_callback(func() -> void: _flapping = true)  # back to flapping


# --- Damage -------------------------------------------------------------------

func _is_head(hit_position: Vector3) -> bool:
	return hit_position.is_finite() and hit_position.distance_to(_head.global_position) <= head_radius


## Called by melee weapons instead of take_damage(): blades to the head do triple.
func take_melee_damage(amount: float, from_position: Vector3, hit_position := Vector3.INF) -> void:
	_melee_hit = true
	take_damage(amount, from_position, hit_position)
	_melee_hit = false


func _damage_multiplier(hit_position: Vector3) -> float:
	if _is_head(hit_position):
		return melee_head_multiplier if _melee_hit else head_damage_multiplier
	return 1.0 if _downed else body_damage_multiplier  # down, its scales don't help


func _on_damaged(amount: float, multiplier: float, hit_position: Vector3) -> void:
	_spawn_label(("HEAD %d" if multiplier >= head_damage_multiplier else "%d") % roundi(amount),
			Color(1.0, 0.25, 0.2) if multiplier > head_damage_multiplier else (Color(1.0, 0.9, 0.3) if multiplier >= head_damage_multiplier else Color(0.75, 0.75, 0.75)),
			hit_position if hit_position.is_finite() else _head.global_position)
	if _is_inhaling() and _is_head(hit_position):
		_choke_taken += amount
		if _choke_taken >= choke_threshold:
			_choke()


func _spawn_label(text: String, color: Color, at: Vector3) -> void:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 72
	label.outline_size = 14
	label.pixel_size = 0.01
	label.text = text
	label.modulate = color
	get_parent().add_child(label)
	label.global_position = at + Vector3.UP * 0.5
	var tween := label.create_tween().set_parallel()
	tween.tween_property(label, "global_position:y", label.global_position.y + 1.5, 0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.8).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)

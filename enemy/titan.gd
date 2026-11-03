class_name Titan
extends Enemy
## A giant. Fast, tough, and hits hard from far away, but:
##  - it only takes reduced damage to the body; the head takes full damage and
##    the back of the head (the nape, marked dark red) takes triple
##  - it can't reach you while something solid is above your head (inside a
##    building, under your own floors), but it waits outside for you
##  - things it can't reach (a tall roof) are safe to attack from
##  - it turns slowly and only attacks what's in front of it, and after every
##    attack it stands still for a moment: get behind it. A grappling hook holds
##    in it, so you can swing round to the nape, where melee hits hardest of all
##
## Two attacks, picked at random when you're in range:
##  - Swipe: fast windup (arm raised overhead), huge reach and knockback
##  - Grab: slower windup (arm reaching forward, eyes turn purple). It holds you
##    and squeezes, then dashes you to the ground at its feet and follows up
##    with a Stomp: it lifts its foot (eyes flare red, a red circle marks where
##    you landed) and brings it down there, hurting and launching anyone on the
##    ground inside the circle. Get out of the circle or be in the air when it
##    lands. Mash Jump to struggle free before the throw (no stomp then), or
##    land a head/nape hit (or a stagger) to make it let go. It stands still
##    for its usual recovery after the stomp.

@export_group("Damage zones")
@export var body_damage_multiplier := 0.15
@export var head_damage_multiplier := 1.0
@export var nape_damage_multiplier := 3.0
## Melee to the nape does this instead (blades are what it's weak to).
@export var melee_nape_multiplier := 5.0
## A melee swing from behind the head and within this distance of the nape
## counts as a nape hit, wherever on the titan the swing first touched.
@export var melee_nape_reach := 4.0
@export var head_radius := 1.1
## Slack around the head sphere so near-misses with melee still count as head hits.
@export var head_hit_tolerance := 0.6

@export_group("Titan attacks")
## Highest point above its feet it can hit (tall roofs are out of reach).
@export var reach_height := 9.0
@export var swipe_knockback := 16.0
@export_range(0.0, 1.0) var grab_chance := 0.35
@export var grab_windup_time := 0.5
@export var grab_range := 7.0
@export var grab_hold_time := 3.0
@export var grab_damage_per_second := 12.0
@export var throw_speed := 16.0
@export var throw_damage := 15.0
## It never recovers from an attack faster than this, however high its level.
@export var min_recover_time := 1.0

@export_group("Stomp (after a grab)")
## From dropping you to the foot coming down.
@export var stomp_time := 1.25
## When it settles on where to stomp (you've landed by then).
@export var stomp_lock_time := 0.8
@export var stomp_radius := 4.0
@export var stomp_damage := 40.0
@export var stomp_knockback := 14.0

@onready var _head: Node3D = $Visual/Head
@onready var _arm: Node3D = $Visual/ArmPivotR
@onready var _hand: Node3D = $Visual/ArmPivotR/Elbow/Hand
@onready var _elbow_r: Node3D = $Visual/ArmPivotR/Elbow
@onready var _arm_l: Node3D = $Visual/ArmPivotL
@onready var _elbow_l: Node3D = $Visual/ArmPivotL/Elbow
@onready var _hip_l: Node3D = $Visual/HipL
@onready var _hip_r: Node3D = $Visual/HipR
@onready var _knee_l: Node3D = $Visual/HipL/Knee
@onready var _knee_r: Node3D = $Visual/HipR/Knee

## Its hips (Visual space): it leans about this point.
const HIPS := Vector3(0.0, 3.05, 0.0)

var _grab_attack := false
var _holding := false
var _arm_tween: Tween
var _melee_nape := false
# Animation: [lean back, lift, right elbow, left arm, left elbow, left hip,
# left knee, right hip, right knee], eased toward a target pose each tick.
var _pose_now := PackedFloat32Array([0, 0, 0.35, 0, 0.35, 0, 0, 0, 0])
var _gait := 0.0
var _since_strike := 10.0
var _stomping := false
var _stomp_clock := 0.0
var _stomp_target := Vector3.ZERO
var _stomp_marker: MeshInstance3D


func apply_level(level: int) -> void:
	var damage_before := damage
	super(level)
	recover_time = maxf(recover_time, min_recover_time)  # the opening stays
	stomp_damage *= damage / damage_before


## 0 = body, 1 = head, 2 = nape (back of the head).
func hit_zone(hit_position: Vector3) -> int:
	if not hit_position.is_finite():
		return 0
	var offset := hit_position - _head.global_position
	if offset.length() > head_radius + head_hit_tolerance:
		return 0
	return 2 if offset.normalized().dot(global_basis.z) > 0.35 else 1  # +Z is its back


## Called by melee weapons instead of take_damage().
func take_melee_damage(amount: float, from_position: Vector3, hit_position := Vector3.INF) -> void:
	var nape := _head.global_position + global_basis.z * head_radius
	_melee_nape = hit_zone(hit_position) == 2 \
			or ((from_position - _head.global_position).dot(global_basis.z) > 0.0 and from_position.distance_to(nape) <= melee_nape_reach)
	take_damage(amount, from_position, nape if _melee_nape else hit_position)
	_melee_nape = false


func _damage_multiplier(hit_position: Vector3) -> float:
	if _melee_nape:
		return melee_nape_multiplier
	match hit_zone(hit_position):
		1: return head_damage_multiplier
		2: return nape_damage_multiplier
	return body_damage_multiplier


func _on_damaged(amount: float, multiplier: float, hit_position: Vector3) -> void:
	_spawn_damage_number(amount, multiplier, hit_position)
	if _holding and multiplier >= head_damage_multiplier:
		release_grab()


# --- Senses: you're hidden while under cover ----------------------------------

func _has_line_of_sight() -> bool:
	return super() and not _player.is_under_cover()


func _reachable() -> bool:
	if not is_instance_valid(_player) or _player.is_under_cover():
		return false
	var height: float = _player.global_position.y - global_position.y
	return height > -2.0 and height < reach_height


# --- Pathfinding: needs room ----------------------------------------------------

func _needs_wide_paths() -> bool:
	return true


## Far too big for a doorway.
func _takes_portals() -> bool:
	return false


func can_use_portal() -> bool:
	return false


## Goes around structures with room to spare, only cutting straight in once you're within reach.
func _uses_routes(to_target: Vector3) -> bool:
	return not _can_see or Vector3(to_target.x, 0.0, to_target.z).length() > attack_range


## It won't squeeze into the tight space around a building you're hiding in:
## it stops where the open ground ends and waits for you to come out.
func _chase_move_dir(flat_to_target: Vector3) -> Vector3:
	if nav != null and not _can_see and nav.building_containing(_player.global_position) != null \
			and not nav.is_open(global_position + flat_to_target.normalized() * 2.0, true):
		return Vector3.ZERO
	return super(flat_to_target)


func _can_start_attack(to_target: Vector3) -> bool:
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var facing := (-global_basis.z).dot(flat.normalized()) > 0.5  # it has to turn to you first
	return _can_see and flat.length() < attack_range and facing and _reachable()


# --- Attacks ------------------------------------------------------------------

func _on_windup_start() -> void:
	_grab_attack = randf() < grab_chance
	if _grab_attack:
		_state_time = grab_windup_time
		_eye_mat.emission = Color(0.7, 0.2, 1.0)  # different tell for the grab
		_pose_arm(1.5, grab_windup_time)           # reaching forward
	else:
		_pose_arm(-2.5, windup_time)               # raised overhead


func _during_windup(_delta: float) -> void:
	if is_instance_valid(_player):
		var flat := _player.global_position - global_position
		flat.y = 0.0
		_face(flat.normalized())


func _strike() -> void:
	var to_player := _player.global_position - global_position if is_instance_valid(_player) else Vector3.INF
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	var in_front := (-global_basis.z).dot(flat.normalized()) > 0.0
	var reachable := to_player.is_finite() and in_front and _reachable()

	if _grab_attack:
		if reachable and flat.length() <= grab_range and not _player.is_grabbed():
			_holding = true
			_player.grab(self, _hand)
			_set_state(State.RECOVER)
			_state_time = grab_hold_time
			_pose_arm(1.9, 0.35)  # lift you up in front of its face
			return
	elif reachable and flat.length() <= hit_range:
		_player.take_damage(damage, global_position)
		_player.push(flat.normalized() * swipe_knockback + Vector3.UP * 6.0)

	_set_state(State.RECOVER)
	_state_time = recover_time
	_since_strike = 0.0
	_pose_arm(1.2, 0.1)
	_arm_tween.tween_property(_arm, "rotation:x", 0.0, 0.5)


func _during_recover(delta: float) -> void:
	if _stomping:
		_stomp_tick(delta)
		return
	if _holding and _state_time <= delta:
		_drop_and_stomp()  # the squeeze is over: down you go
		return
	if not _holding:
		return
	if not is_instance_valid(_player) or not _player.is_grabbed_by(self):
		_holding = false
		return
	_player.hurt(grab_damage_per_second * delta)


func _on_recover_end() -> void:
	if _holding:
		# Throw.
		_holding = false
		var dir := -global_basis.z
		_player.release(dir * throw_speed + Vector3.UP * 8.0)
		_player.take_damage(throw_damage, _hand.global_position)
	_pose_arm(0.0, 0.3)


# --- Stomp: the grab's follow-up -------------------------------------------------

## Dashes the held player to the ground in front of it and starts the stomp.
func _drop_and_stomp() -> void:
	_holding = false
	if is_instance_valid(_player) and _player.is_grabbed_by(self):
		_player.release(-global_basis.z * 3.0 + Vector3.DOWN * 6.0)
		_player.take_damage(throw_damage, _hand.global_position)
	_stomping = true
	_stomp_clock = 0.0
	_stomp_target = global_position - global_basis.z * 3.0
	_state_time = stomp_time + recover_time
	_eye_mat.emission = Color(1.0, 0.15, 0.05)  # the tell: eyes flare red
	_eye_mat.emission_energy_multiplier = 8.0
	_pose_arm(0.5, 0.3)  # arms out for balance as the foot comes up


func _stomp_tick(delta: float) -> void:
	_stomp_clock += delta
	if _stomp_clock < stomp_lock_time and is_instance_valid(_player):
		_stomp_target = _ground_below(_player.global_position)  # follows you as you fall...
		_face(Vector3(_stomp_target.x - global_position.x, 0.0, _stomp_target.z - global_position.z).normalized())
	elif _stomp_marker == null and _stomp_clock < stomp_time:
		_show_stomp_marker()  # ...then commits: here it comes
	if _stomp_clock >= stomp_time:
		_stomp_land()


## The ground under a point (or the point itself if there's none close below).
func _ground_below(point: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.5, point + Vector3.DOWN * 20.0)
	query.collision_mask = 1
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if hit else point


func _stomp_land() -> void:
	_stomping = false
	_since_strike = 0.0
	_state_time = recover_time
	_set_state(State.RECOVER)  # (back to the normal eye color)
	_clear_stomp_marker()
	_ring(_stomp_target)
	if is_instance_valid(_player) and not _player.is_grabbed():
		var offset: Vector3 = _player.global_position - _stomp_target
		var on_ground := offset.y < 0.5 and offset.y > -2.0  # a jump timed with the stomp clears it
		if on_ground and Vector2(offset.x, offset.z).length() <= stomp_radius:
			_player.take_damage(stomp_damage, _stomp_target)
			var away := Vector3(offset.x, 0.0, offset.z).normalized() if Vector2(offset.x, offset.z).length() > 0.1 else -global_basis.z
			_player.push(away * stomp_knockback + Vector3.UP * 7.0)
	_pose_arm(0.0, 0.4)


func _show_stomp_marker() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.1, 0.05, 0.35)
	material.no_depth_test = false
	var disc := CylinderMesh.new()
	disc.top_radius = stomp_radius
	disc.bottom_radius = stomp_radius
	disc.height = 0.06
	_stomp_marker = MeshInstance3D.new()
	_stomp_marker.mesh = disc
	_stomp_marker.material_override = material
	_stomp_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_parent().add_child(_stomp_marker)
	_stomp_marker.global_position = _stomp_target + Vector3.UP * 0.08
	var tween := _stomp_marker.create_tween().set_loops()
	tween.tween_property(material, "albedo_color:a", 0.6, 0.12)
	tween.tween_property(material, "albedo_color:a", 0.3, 0.12)


func _clear_stomp_marker() -> void:
	if is_instance_valid(_stomp_marker):
		_stomp_marker.queue_free()
	_stomp_marker = null


## The shockwave where the foot lands.
func _ring(at: Vector3) -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.85, 0.75, 0.6, 0.7)
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.1
	var ring := MeshInstance3D.new()
	ring.mesh = disc
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_parent().add_child(ring)
	ring.global_position = at + Vector3.UP * 0.1
	ring.scale = Vector3(0.5, 1.0, 0.5)
	var tween := ring.create_tween().set_parallel()
	tween.tween_property(ring, "scale", Vector3(stomp_radius * 1.3, 1.0, stomp_radius * 1.3), 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_property(material, "albedo_color:a", 0.0, 0.35)
	tween.chain().tween_callback(ring.queue_free)


## Called by the player breaking free, or by taking a head/nape hit while holding.
func release_grab() -> void:
	if not _holding:
		return
	_holding = false
	if is_instance_valid(_player) and _player.is_grabbed_by(self):
		_player.release(Vector3.UP * 5.0 - global_basis.z * 4.0)
	# Flinch: a short opening to counterattack.
	_state_time = minf(_state_time, 1.0)
	_pose_arm(-0.4, 0.15)


func _on_windup_cancelled() -> void:
	_pose_arm(0.0, 0.2)


func _die(killed_by_player: bool) -> void:
	release_grab()
	_clear_stomp_marker()
	super(killed_by_player)


func _pose_arm(angle: float, duration: float) -> void:
	if _arm_tween:
		_arm_tween.kill()
	_arm_tween = create_tween()
	_arm_tween.tween_property(_arm, "rotation:x", angle, duration)


# --- Animation ----------------------------------------------------------------

## The body around the right arm (which the attack code swings itself):
##   walking   long, heavy strides with knees bending on the swing, arms
##             swinging opposite the legs, the body dipping each step
##   swipe     windup: leans back, elbow cocked behind its head; strike: lunges
##             forward into the swing and follows through
##   grab      leans in, arm straight out reaching for you; holding: hauls you
##             up to its face
##   attacks   it plants its feet in a wide stance
func _physics_process(delta: float) -> void:
	super(delta)
	if _dead:
		return
	if _pose_tween and _pose_tween.is_valid():
		_pose_tween.kill()  # (the base class's lean poses: this replaces them)
	_since_strike += delta
	var speed := Vector2(velocity.x, velocity.z).length()
	var stride := clampf(speed / move_speed * 1.3, 0.0, 1.0)
	_gait = fmod(_gait + delta * speed * 0.9, TAU)
	var swing := sin(_gait)
	var lift := cos(_gait)
	var target := PackedFloat32Array([
		-0.05 * stride,                         # lean (into the run)
		-absf(swing) * 0.18 * stride,           # dip as the legs pass
		0.35,                                   # right elbow
		-swing * 0.5 * stride,                  # left arm, opposite the left leg
		0.35 + 0.3 * stride,                    # left elbow
		swing * 0.6 * stride,                   # left hip
		-maxf(lift, 0.0) * 1.0 * stride,        # left knee bends as it swings forward
		-swing * 0.6 * stride,                  # right hip
		-maxf(-lift, 0.0) * 1.0 * stride,       # right knee
	])
	var rate := 8.0
	var stance := false
	if state == State.WINDUP and _grab_attack:
		target[0] = -0.14     # leaning in
		target[2] = 0.15      # arm straight out
		target[3] = 0.6
		stance = true
	elif state == State.WINDUP:
		target[0] = 0.12      # leaning back
		target[2] = 1.4       # elbow cocked behind the head
		target[3] = 0.5       # other arm out for balance
		target[4] = 0.6
		stance = true
		rate = 12.0
	elif _stomping and _stomp_clock < stomp_time - 0.12:
		# Foot up, weight back...
		target[0] = 0.1
		target[3] = 0.6
		target[7] = 1.15      # right thigh raised
		target[8] = -1.5      # knee bent: foot lifted high
		target[5] = -0.15
		target[6] = -0.3
		rate = 6.0
	elif _stomping:
		# ...and down it comes.
		target[0] = -0.15
		target[1] = -0.25
		target[7] = 0.45
		target[8] = -0.05
		target[5] = -0.25
		target[6] = -0.4
		rate = 30.0
	elif _holding:
		target[0] = 0.04
		target[2] = 0.6       # (with the arm raised) holding you up to its face
		target[3] = 0.4
		stance = true
	elif state == State.RECOVER and _since_strike < 0.6:
		target[0] = -0.2      # lunging into the swing
		target[2] = 0.1
		target[3] = -0.5
		stance = true
		rate = 18.0
	if stance:
		target[1] = -0.25     # knees bent, low
		target[5] = 0.35      # left foot forward
		target[6] = -0.45
		target[7] = -0.3      # right foot back
		target[8] = -0.35
	var blend := 1.0 - exp(-rate * delta)
	for i in _pose_now.size():
		_pose_now[i] = lerpf(_pose_now[i], target[i], blend)

	var lean := Basis(Vector3.RIGHT, _pose_now[0])
	visual.transform = Transform3D(lean, Vector3(0.0, _pose_now[1], 0.0) + HIPS - lean * HIPS)
	_elbow_r.rotation.x = _pose_now[2]
	_arm_l.rotation.x = _pose_now[3]
	_elbow_l.rotation.x = _pose_now[4]
	_hip_l.rotation.x = _pose_now[5]
	_knee_l.rotation.x = _pose_now[6]
	_hip_r.rotation.x = _pose_now[7]
	_knee_r.rotation.x = _pose_now[8]
	# The right arm swings with the stride too, when it isn't attacking.
	if (state == State.CHASE or state == State.IDLE) and not _holding and (_arm_tween == null or not _arm_tween.is_running()):
		_arm.rotation.x = lerpf(_arm.rotation.x, swing * 0.5 * stride, blend)


# --- Feedback -----------------------------------------------------------------

func _spawn_damage_number(amount: float, multiplier: float, hit_position: Vector3) -> void:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 72
	label.outline_size = 14
	label.pixel_size = 0.01
	if multiplier >= nape_damage_multiplier:
		label.text = "NAPE %d" % roundi(amount)
		label.modulate = Color(1.0, 0.25, 0.2)
	elif multiplier >= head_damage_multiplier:
		label.text = "HEAD %d" % roundi(amount)
		label.modulate = Color(1.0, 0.9, 0.3)
	else:
		label.text = "%d" % roundi(amount)
		label.modulate = Color(0.75, 0.75, 0.75)
	get_parent().add_child(label)
	label.global_position = (hit_position if hit_position.is_finite() else _head.global_position) + Vector3.UP * 0.5
	var tween := label.create_tween().set_parallel()
	tween.tween_property(label, "global_position:y", label.global_position.y + 1.5, 0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.8).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)

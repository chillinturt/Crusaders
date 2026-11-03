extends CharacterBody3D
## The player: Source/Quake-style movement (ground friction + acceleration, air
## strafing, bunny hopping; defaults are Source engine values converted from Hammer
## units, 1 unit = 0.0254 m), health, a four-slot weapon loadout chosen at the
## start of the game, and the HUD.

@export_group("Ground")
@export var max_speed := 8.0        ## sv_maxspeed 320
@export var ground_accel := 10.0    ## sv_accelerate 10
@export var friction := 4.0         ## sv_friction 4
@export var stop_speed := 2.5       ## sv_stopspeed 100

@export_group("Air")
@export var air_accel := 10.0       ## sv_airaccelerate 10
## The "30 units" cap. Air accel can only add speed up to this value along
## your wish direction, but because that's measured *along* the wish direction,
## strafing perpendicular to your velocity keeps adding speed. That's air strafing.
@export var air_speed_cap := 0.76
@export var gravity := 20.3         ## sv_gravity 800
@export var jump_velocity := 7.3    ## 289 units/s
## Hold jump to hop the instant you land (no friction tick).
@export var auto_bhop := true

@export_group("Gas")
## Acceleration along your aim while burning gas (Shift) without a hook.
## Less than gravity, so it's a boost and a glide, not flight.
@export var gas_thrust := 14.0

@export_group("Stamina")
@export var jump_stamina_cost := 12.0
## Ground speed multiplier while exhausted (stamina emptied, not yet recovered).
@export var exhausted_speed_multiplier := 0.65

@export_group("Look")
@export var mouse_sensitivity := 0.002

@export_group("Health")
## Max health at Fitness 1 / Strength 1; each level of either adds 5.
@export var base_health := 100.0
## Getting hit shoves you away from the attacker (and a little up, so
## it isn't instantly eaten by ground friction).
@export var knockback := 6.0
@export var knockback_up := 4.0
## Fraction of your coins lost when you die.
@export_range(0.0, 1.0) var death_coin_loss := 0.2

@export_group("Loadout")
## Show the loadout screen (and pause) when the game starts. Off = start
## immediately with default_loadout.
@export var show_loadout_screen := true
## Node names of the default pick per slot: primary, secondary, utility, melee.
@export var default_loadout: PackedStringArray = ["AutoRifle", "Revolver", "GrappleGear", "Machete"]
@export var interact_range := 2.5

const XP_PER_JUMP := 1.0
const XP_PER_METER := 0.02

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var speed_label: Label = $HUD/SpeedLabel
@onready var health_label: Label = $HUD/HealthLabel
@onready var stamina_bar: ProgressBar = $HUD/StaminaBar
@onready var gas_bar: ProgressBar = $HUD/GasBar
@onready var stats_label: Label = $HUD/StatsLabel
@onready var weapon_label: Label = $HUD/WeaponLabel
@onready var prompt_label: Label = $HUD/PromptLabel
@onready var feed_label: Label = $HUD/FeedLabel
@onready var region_label: Label = $HUD/RegionLabel
@onready var damage_flash: ColorRect = $HUD/DamageFlash
@onready var crosshair: ColorRect = $HUD/Crosshair
@onready var menu: Control = $HUD/GameMenu
@onready var loadout_screen: Control = $HUD/LoadoutScreen
@onready var weapons: Node3D = $Head/Camera3D/Weapons
@onready var vitals: Node = $Vitals
@onready var skills: Skills = $Skills
@onready var grapple: Node3D = $GrappleGear
@onready var upgrades: Upgrades = $Upgrades
@onready var coins_label: Label = $HUD/CoinsLabel
@onready var objective_label: Label = $HUD/ObjectiveLabel

var health: float
var max_health: float
var kills := 0
var deaths := 0
## Currency from kills, spent on treasure chests.
var coins := 0
## While a titan holds you: who, and the hand you're stuck to.
var _grabbed_by: Node = null
var _grab_hand: Node3D
var _struggle := 0
var _spawn_transform: Transform3D
var _damage_tween: Tween
var _hitmarker_tween: Tween
var _interact_target: Object = null
var _spread_ring: Control
var _spread_px := 0.0
var _feed: Array[Array] = []  # [text, seconds left]


func _ready() -> void:
	add_to_group(Portal.TRAVELERS)
	_setup_input()
	_spawn_transform = global_transform
	max_health = base_health + skills.bonus_health() + upgrades.bonus_health()
	health = max_health
	weapons.hit_target.connect(_on_hit_target)
	skills.leveled_up.connect(_on_level_up)
	upgrades.changed.connect(func(_id: StringName) -> void: _refresh_max_health())
	menu.setup(self)
	menu.visible = false
	_spread_ring = Control.new()
	_spread_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	_spread_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spread_ring.draw.connect(func() -> void:
		if _spread_px > 3.0:
			_spread_ring.draw_arc(_spread_ring.size * 0.5, _spread_px, 0.0, TAU, 40, Color(1, 1, 1, 0.45), 1.5))
	crosshair.add_sibling(_spread_ring)

	loadout_screen.setup(_loadout_options())
	loadout_screen.confirmed.connect(_on_loadout_confirmed)
	if show_loadout_screen:
		# Choose before anything moves: the whole game waits behind the screen.
		get_tree().paused = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_on_loadout_confirmed(_default_choices())


## Mouse look runs in _input (not _unhandled_input) so HUD controls under the
## captured cursor at screen center can never swallow the motion.
## Yaw turns the whole body (so WASD follows where you face); pitch only tilts the head.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		# Handled here, before the GUI, so the open menu can't eat Tab.
		_set_menu_open(not menu.visible)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if menu.visible:
			_set_menu_open(false)
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif menu.visible:
		return
	elif _grabbed_by and event.is_action_pressed("jump"):
		_struggle_once()
	elif event.is_action_pressed("interact") and _interact_target:
		_interact_target.interact(self)
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _set_menu_open(open: bool) -> void:
	menu.visible = open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if _grabbed_by:
		_held_tick()
		return

	var wish_dir := _get_wish_dir()

	if is_on_floor():
		if _wants_jump() and vitals.try_spend_stamina(jump_stamina_cost):
			# Jumping skips this tick's friction, so landing and jumping on the
			# same tick keeps all your momentum. That's what makes bhopping work.
			velocity.y = jump_velocity
			_air_accelerate(wish_dir, delta)
			skills.add_xp(&"fitness", XP_PER_JUMP)
		else:
			_apply_friction(delta)
			var speed := _run_speed() * (exhausted_speed_multiplier if vitals.exhausted else 1.0)
			_accelerate(wish_dir, speed, ground_accel, delta)
	else:
		velocity.y -= gravity * delta
		_air_accelerate(wish_dir, delta)

	# Gas (Shift): everyone has it. Hooked, it thrusts toward the hook (the grapple
	# applies that); otherwise it pushes you along your aim.
	var thrusting: bool = Input.is_action_pressed("gas") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and vitals.burn_gas(delta)
	if not grapple.apply(delta, thrusting) and thrusting:
		velocity += -camera.global_basis.z * gas_thrust * delta

	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	skills.add_xp(&"fitness", minf(moved, 2.0) * XP_PER_METER)  # min(): ignore teleports

	if global_position.y < -50.0:
		_die()
	elif Input.is_action_just_pressed("respawn"):
		_teleport_to_spawn()  # "unstuck" key: no heal, no penalty

	_update_interact_target()


func _process(delta: float) -> void:
	for entry in _feed:
		entry[1] -= delta
	_feed = _feed.filter(func(entry: Array) -> bool: return entry[1] > 0.0)
	_update_hud()


# --- Loadout ------------------------------------------------------------------

## Choices per slot for the loadout screen: weapons by slot, plus the grapple
## (a utility that isn't a held weapon).
func _loadout_options() -> Array:
	var options := []
	for slot in 4:
		var choices: Array[Node] = []
		if slot == Weapon.Slot.UTILITY:
			choices.append(grapple)
		choices.append_array(weapons.options_for_slot(slot))
		options.append(choices)
	return options


func _default_choices() -> Array[Node]:
	var choices: Array[Node] = []
	for options: Array in _loadout_options():
		var pick: Node = options[0]
		for option: Node in options:
			if String(option.name) in default_loadout:
				pick = option
		choices.append(pick)
	return choices


func _on_loadout_confirmed(choices: Array[Node]) -> void:
	apply_loadout(choices)
	loadout_screen.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Equips exactly these (weapons and/or the grapple), one per slot.
func apply_loadout(choices: Array[Node]) -> void:
	var chosen_weapons: Array[Weapon] = []
	for choice in choices:
		if choice is Weapon:
			chosen_weapons.append(choice)
	grapple.owned = grapple in choices
	if not grapple.owned:
		grapple.detach()
	weapons.set_loadout(chosen_weapons)


## One line per slot, for the Tab menu.
func loadout_summary() -> PackedStringArray:
	var lines := PackedStringArray()
	for slot in 4:
		var weapon: Weapon = weapons.weapon_in_slot(slot)
		var title: String = loadout_screen.SLOT_TITLES[slot]
		if weapon:
			lines.append("%d  %s: %s" % [slot + 1, title, weapon.display_name])
		elif slot == Weapon.Slot.UTILITY and grapple.owned:
			lines.append("RMB, F / C  %s: %s" % [title, grapple.display_name])
	return lines


# --- Health -------------------------------------------------------------------

## Called by enemies and explosions. from_position is used for knockback direction.
func take_damage(amount: float, from_position: Vector3, _hit_position := Vector3.INF) -> void:
	var away := global_position - from_position
	away.y = 0.0
	velocity += away.normalized() * knockback
	velocity.y = maxf(velocity.y, knockback_up)

	if _damage_tween:
		_damage_tween.kill()
	damage_flash.color.a = 0.35
	_damage_tween = create_tween()
	_damage_tween.tween_property(damage_flash, "color:a", 0.0, 0.3)

	hurt(amount)


## Plain health loss with no knockback or flash (a titan's squeeze, etc.).
## Toughness upgrades reduce it.
func hurt(amount: float) -> void:
	health -= amount * upgrades.damage_taken_multiplier()
	vitals.on_damaged()
	if health <= 0.0:
		_die()


## Fire: health loss with a light flash, no knockback (so you can run out of it).
func burn(amount: float) -> void:
	if _damage_tween:
		_damage_tween.kill()
	damage_flash.color = Color(1.0, 0.45, 0.0, 0.25)
	_damage_tween = create_tween()
	_damage_tween.tween_property(damage_flash, "color", Color(1.0, 0.0, 0.0, 0.0), 0.3)
	hurt(amount)


func heal(amount: float) -> void:
	health = minf(health + amount, max_health)


## Instant velocity change from explosions and heavy hits.
func push(impulse: Vector3) -> void:
	velocity += impulse


## True if there's solid level geometry above your head (a roof, a floor you built):
## titans can't reach or see you there.
func is_under_cover() -> bool:
	var from := global_position + Vector3.UP * 1.7
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * 25.0)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


# --- Being grabbed (titans) ---------------------------------------------------

func grab(by: Node, hand: Node3D) -> void:
	_grabbed_by = by
	_grab_hand = hand
	_struggle = 0
	grapple.detach()
	notify("GRABBED! Mash JUMP to break free (or hit its head)")


func release(throw_velocity := Vector3.ZERO) -> void:
	_grabbed_by = null
	_grab_hand = null
	velocity = throw_velocity


func is_grabbed() -> bool:
	return _grabbed_by != null


func is_grabbed_by(node: Node) -> bool:
	return _grabbed_by == node


## Jump presses needed to break free: 8 at Strength 1, down to 4.
func struggles_needed() -> int:
	return maxi(8 - floori(skills.bonus_levels(&"strength") / 2.0), 4)


func _struggle_once() -> void:
	if not vitals.try_spend_stamina(5.0):
		return
	_struggle += 1
	if _struggle >= struggles_needed():
		var titan := _grabbed_by
		notify("Broke free!")
		titan.release_grab()
		if _grabbed_by:  # in case the titan didn't let go
			release(Vector3.UP * 5.0)


func _held_tick() -> void:
	if not is_instance_valid(_grabbed_by) or not is_instance_valid(_grab_hand):
		release()
		return
	global_position = _grab_hand.global_position + Vector3.DOWN * 0.9
	velocity = Vector3.ZERO
	_update_interact_target()


func add_kill() -> void:
	kills += 1


func add_coins(amount: int) -> void:
	coins += amount
	notify("+%d coins" % amount)


## Pays for something if you can afford it.
func spend_coins(amount: int) -> bool:
	if coins < amount:
		return false
	coins -= amount
	return true


func _die() -> void:
	grapple.detach()
	if _grabbed_by:
		var titan := _grabbed_by
		release()
		titan.release_grab()
	deaths += 1
	kills = 0
	var lost := floori(coins * death_coin_loss)
	coins -= lost
	health = max_health
	vitals.reset()
	_teleport_to_spawn()
	notify("You died and lost %d coins." % lost if lost > 0 else "You died.")


func _teleport_to_spawn() -> void:
	global_transform = _spawn_transform
	head.rotation = Vector3.ZERO
	velocity = Vector3.ZERO


# --- Portals ------------------------------------------------------------------

func can_use_portal() -> bool:
	return _grabbed_by == null


## Called by a Portal right after it moved you to its other end.
func on_portal_travel() -> void:
	grapple.detach()


# --- Regions ------------------------------------------------------------------

## Called by the world generator before it tears down the current region.
func prepare_for_travel() -> void:
	grapple.detach()
	if _grabbed_by:
		release()
	_interact_target = null
	if menu.visible:
		_set_menu_open(false)
	# Put away and re-draw the current weapon so it drops anything tied to the old
	# region (the building gun's preview, a laser beam).
	var weapon: Weapon = weapons.get_current()
	if weapon:
		weapon.unequip()
		weapon.equip()


## Called by the world generator on arrival: moves you there and makes it your respawn point.
func arrive(at: Transform3D, region_name: String) -> void:
	_spawn_transform = at
	_teleport_to_spawn()
	region_label.text = region_name
	notify("Entered %s" % region_name)


# --- Progression & interaction ------------------------------------------------

func _on_level_up(skill: StringName, level: int) -> void:
	notify("%s reached level %d!" % [Skills.SKILLS[skill], level])
	_refresh_max_health()


## Max health = base + skill levels + Vitality upgrades. Any increase arrives filled.
func _refresh_max_health() -> void:
	var new_max := base_health + skills.bonus_health() + upgrades.bonus_health()
	if new_max > max_health:
		health += new_max - max_health
	max_health = new_max


## Shown under the region name (e.g. the titan that guards the way onward).
func set_objective(text: String) -> void:
	objective_label.text = text


func _update_interact_target() -> void:
	_interact_target = null
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * interact_range)
	query.collision_mask = 1 | 4  # world (blocks) + interactables
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit and hit.collider.has_method("interact") and hit.collider.get_interact_prompt(self) != "":
		_interact_target = hit.collider


# --- HUD ----------------------------------------------------------------------

## Short message in the event feed (right side of the screen).
func notify(text: String) -> void:
	_feed.append([text, 3.0])
	if _feed.size() > 5:
		_feed.pop_front()


func _update_hud() -> void:
	var hspeed := Vector2(velocity.x, velocity.z).length()
	speed_label.text = "%.1f m/s  (%d u/s)" % [hspeed, roundi(hspeed / 0.0254)]

	health_label.text = "+ %d / %d" % [ceili(maxf(health, 0.0)), roundi(max_health)]
	health_label.modulate = Color(0.5, 1.0, 0.5) if vitals.is_healing() else Color.WHITE

	stamina_bar.max_value = vitals.max_stamina()
	stamina_bar.value = vitals.stamina
	stamina_bar.modulate = Color(1.0, 0.4, 0.3) if vitals.exhausted else Color(0.5, 0.9, 1.0)
	gas_bar.max_value = vitals.max_gas
	gas_bar.value = vitals.gas

	stats_label.text = "Kills: %d   Deaths: %d" % [kills, deaths]
	coins_label.text = "%d coins" % coins
	var weapon: Weapon = weapons.get_current()
	var weapon_text := ""
	if weapon:
		weapon_text = "%d  %s" % [weapon.slot + 1, weapon.display_name]
		if weapon.ammo_text():
			weapon_text += "\n" + weapon.ammo_text()
	weapon_label.text = weapon_text

	# Spread ring around the crosshair, sized to the actual cone on screen.
	var spread := weapon.spread_degrees() if weapon else 0.0
	_spread_px = tan(deg_to_rad(spread)) / tan(deg_to_rad(camera.fov * 0.5)) * get_viewport().get_visible_rect().size.y * 0.5
	_spread_ring.queue_redraw()

	prompt_label.text = "[E] " + _interact_target.get_interact_prompt(self) if _interact_target else ""
	feed_label.text = "\n".join(_feed.map(func(entry: Array) -> String: return entry[0]))


## Hit marker: crosshair briefly turns red when an attack lands on an enemy.
func _on_hit_target() -> void:
	if _hitmarker_tween:
		_hitmarker_tween.kill()
	crosshair.color = Color.RED
	_hitmarker_tween = create_tween()
	_hitmarker_tween.tween_property(crosshair, "color", Color.WHITE, 0.15)


# --- Movement helpers ---------------------------------------------------------

## Running speed including Swiftness upgrades.
func _run_speed() -> float:
	return max_speed * upgrades.move_speed_multiplier()


func _get_wish_dir() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	return (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()


func _wants_jump() -> bool:
	if auto_bhop:
		return Input.is_action_pressed("jump")
	return Input.is_action_just_pressed("jump")


## Quake/Source Accelerate(): only adds speed if your velocity projected onto
## wish_dir is below wish_speed. Doesn't cap total speed.
func _accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var current_speed := velocity.dot(wish_dir)
	var add_speed := wish_speed - current_speed
	if add_speed <= 0.0:
		return
	velocity += wish_dir * minf(accel * wish_speed * delta, add_speed)


## Source AirAccelerate(): same as above, but the projected-speed target is
## capped at air_speed_cap while the accel rate still uses the full max_speed.
func _air_accelerate(wish_dir: Vector3, delta: float) -> void:
	if wish_dir == Vector3.ZERO:
		return
	var current_speed := velocity.dot(wish_dir)
	var add_speed := minf(max_speed, air_speed_cap) - current_speed
	if add_speed <= 0.0:
		return
	velocity += wish_dir * minf(air_accel * _run_speed() * delta, add_speed)


func _apply_friction(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < 0.01:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	# Below stop_speed, friction acts as if you were going stop_speed,
	# so you come to a crisp stop instead of creeping.
	var drop := maxf(speed, stop_speed) * friction * delta
	var factor := maxf(speed - drop, 0.0) / speed
	velocity.x *= factor
	velocity.z *= factor


## Registers default key bindings at runtime so the game works without
## touching the Input Map. Rebinding in Project Settings still takes priority.
func _setup_input() -> void:
	var bindings := {
		"move_forward": _key(KEY_W),
		"move_back": _key(KEY_S),
		"move_left": _key(KEY_A),
		"move_right": _key(KEY_D),
		"jump": _key(KEY_SPACE),
		"respawn": _key(KEY_T),
		"reload": _key(KEY_R),
		"attack": _mouse(MOUSE_BUTTON_LEFT),
		"alt_fire": _mouse(MOUSE_BUTTON_RIGHT),
		"gas": _key(KEY_SHIFT),
		"reel_in": _key(KEY_F),
		"reel_out": _key(KEY_C),
		"weapon_1": _key(KEY_1),
		"weapon_2": _key(KEY_2),
		"weapon_3": _key(KEY_3),
		"weapon_4": _key(KEY_4),
		"weapon_last": _key(KEY_Q),
		"weapon_next": _mouse(MOUSE_BUTTON_WHEEL_DOWN),
		"weapon_prev": _mouse(MOUSE_BUTTON_WHEEL_UP),
		"interact": _key(KEY_E),
		"menu": _key(KEY_TAB),
		"map_zoom": _key(KEY_M),
	}
	for action: String in bindings:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		InputMap.action_add_event(action, bindings[action])


func _key(keycode: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	return ev


func _mouse(button: MouseButton) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	return ev

class_name Weapon
extends Node3D
## Base for everything in the weapon slots. WeaponHolder calls equip()/unequip();
## subclasses put their per-tick logic in _weapon_tick(), which only runs while equipped.
##
## Ammo is unlimited, but weapons with a magazine must reload: R, or automatically
## when you try to fire on empty. Subclasses call _use_round() per shot.

signal hit_target

enum Slot { PRIMARY, SECONDARY, UTILITY, MELEE }

@export var display_name := "Weapon"
## Shown on the loadout screen.
@export_multiline var description := ""
@export var slot := Slot.PRIMARY
@export var deploy_time := 0.3      ## delay after switching to this weapon before it can attack
## Set by the loadout: only owned weapons can be equipped.
@export var owned := false

@export_group("Magazine")
## 0 = no magazine (melee, tools).
@export var magazine_size := 0
@export var reload_time := 1.8

var active := false
## Rounds currently loaded (starts full).
var rounds := 0
var _cooldown := 0.0
var _reload_left := 0.0
var _rest_position: Vector3
var _rest_rotation: Vector3


func _ready() -> void:
	_rest_position = position
	_rest_rotation = rotation
	rounds = magazine_size
	visible = false


func equip() -> void:
	active = true
	visible = true
	position = _rest_position + Vector3(0.0, -0.35, 0.0)  # starts low, eases up into view
	_cooldown = maxf(_cooldown, deploy_time)
	if magazine_size > 0 and rounds <= 0:
		start_reload()  # drawn empty (a reload was interrupted earlier)


func unequip() -> void:
	active = false
	visible = false
	_reload_left = 0.0  # switching away cancels a reload


func _process(delta: float) -> void:
	# Ease back to rest after recoil / deploy.
	position = position.lerp(_rest_position, 1.0 - exp(-15.0 * delta))


func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if not active:
		return
	if _reload_left > 0.0:
		_reload_left -= delta
		position.y = _rest_position.y - 0.12  # held low while reloading
		if _reload_left <= 0.0:
			rounds = capacity()
	elif magazine_size > 0 and (rounds <= 0 or (rounds < capacity() and Input.is_action_pressed("reload"))):
		start_reload()  # empty always reloads; R tops up early
	_weapon_tick(delta)


## Override in subclasses. Runs on the physics tick so raycasts/shape queries are safe.
func _weapon_tick(_delta: float) -> void:
	pass


func can_attack() -> bool:
	return active and _cooldown <= 0.0 and _reload_left <= 0.0 and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func is_reloading() -> bool:
	return _reload_left > 0.0


## Magazine size including Extended Magazines upgrades.
func capacity() -> int:
	return ceili(magazine_size * _upgrades().magazine_multiplier()) if magazine_size > 0 else 0


func start_reload() -> void:
	if magazine_size > 0 and _reload_left <= 0.0 and rounds < capacity():
		_reload_left = reload_time / (_wielder().skills.reload_speed_multiplier() * _upgrades().reload_speed_multiplier())


## Takes one round for a shot. Firing the last round starts the reload right away;
## on an (interrupted) empty magazine it starts one and returns false.
func _use_round() -> bool:
	if magazine_size <= 0:
		return true
	if rounds <= 0:
		start_reload()
		return false
	rounds -= 1
	if rounds == 0:
		start_reload()
	return true


## What the HUD shows next to the weapon name.
func ammo_text() -> String:
	if magazine_size <= 0:
		return ""
	return "reloading..." if is_reloading() else "%d / %d" % [rounds, capacity()]


## Current inaccuracy cone (degrees), used to size the crosshair. 0 = no spread.
func spread_degrees() -> float:
	return 0.0


func _camera() -> Camera3D:
	return get_viewport().get_camera_3d()


## The wielder's permanent chest upgrades (damage, fire rate, magazines, reloads).
func _upgrades() -> Upgrades:
	return _wielder().upgrades


## The body holding this weapon (the Player), excluded from our own hit checks.
func _wielder() -> CharacterBody3D:
	return owner as CharacterBody3D


## Effects live in the level (not under the weapon) so they stay put in world space.
func _spawn_effect(node: Node3D, lifetime: float) -> void:
	owner.get_parent().add_child(node)
	get_tree().create_timer(lifetime).timeout.connect(node.queue_free)

extends Node3D
## Holds every weapon in the game as a child; the loadout decides which are
## owned. Keys 1-4 equip the owned weapon in that slot (primary, secondary,
## utility, melee), the mouse wheel cycles through owned weapons, Q swaps to the
## last one.

signal weapon_changed(weapon: Weapon)
signal hit_target

var weapons: Array[Weapon] = []
var current: Weapon
var _last: Weapon


func _ready() -> void:
	for child in get_children():
		if child is Weapon:
			weapons.append(child)
			child.hit_target.connect(hit_target.emit)
	_draw_on_top(self)


## The held weapon is always drawn over the world (it never pokes into a wall,
## and isn't cut off as you step through a portal), and only the main camera
## sees it.
func _draw_on_top(node: Node) -> void:
	if node is MeshInstance3D:
		node.layers = Portal.VIEWMODEL_LAYER
		# Without depth testing, draw order decides what covers what: lower parts
		# first, since you look down on the weapon (a body hides its grip).
		var height: float = (global_transform.affine_inverse() * node.global_position).y
		for surface in node.get_surface_override_material_count():
			var material := node.get_surface_override_material(surface) as BaseMaterial3D
			if material:
				material = material.duplicate()
				material.no_depth_test = true
				material.render_priority = clampi(roundi(height * 200.0), -100, 100)
				node.set_surface_override_material(surface, material)
	for child in node.get_children():
		_draw_on_top(child)


func _unhandled_input(event: InputEvent) -> void:
	for slot in 4:
		if event.is_action_pressed("weapon_%d" % (slot + 1)):
			equip(weapon_in_slot(slot))
			return
	if event.is_action_pressed("weapon_next"):
		equip(_cycle(1))
	elif event.is_action_pressed("weapon_prev"):
		equip(_cycle(-1))
	elif event.is_action_pressed("weapon_last"):
		equip(_last)


## Every weapon that fits a slot (for the loadout screen).
func options_for_slot(slot: int) -> Array[Weapon]:
	var options: Array[Weapon] = []
	for weapon in weapons:
		if weapon.slot == slot:
			options.append(weapon)
	return options


## The owned weapon in a slot, or null.
func weapon_in_slot(slot: int) -> Weapon:
	for weapon in weapons:
		if weapon.owned and weapon.slot == slot:
			return weapon
	return null


func owned_weapons() -> Array[Weapon]:
	var owned: Array[Weapon] = []
	for weapon in weapons:
		if weapon.owned:
			owned.append(weapon)
	owned.sort_custom(func(a: Weapon, b: Weapon) -> bool: return a.slot < b.slot)
	return owned


## Owns exactly these weapons and equips the first (lowest slot) one.
func set_loadout(chosen: Array[Weapon]) -> void:
	if current:
		current.unequip()
	current = null
	_last = null
	for weapon in weapons:
		weapon.owned = weapon in chosen
	var owned := owned_weapons()
	if not owned.is_empty():
		equip(owned[0])


func equip(weapon: Weapon) -> void:
	if weapon == null or weapon == current or not weapon.owned:
		return
	if current:
		current.unequip()
		_last = current
	current = weapon
	current.equip()
	weapon_changed.emit(current)


func get_current() -> Weapon:
	return current


func _cycle(step: int) -> Weapon:
	var owned := owned_weapons()
	if owned.is_empty():
		return null
	return owned[wrapi(owned.find(current) + step, 0, owned.size())]

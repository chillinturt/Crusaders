extends Weapon
## Utility weapon that opens a wormhole between two doorways (see Portal).
##
##  1. Equip it: a see-through doorway shows where it would stand. It always
##     stands upright on the ground, facing you. To put it on top of something
##     above you (a roof, a cliff), aim at the wall near its top or just over
##     its edge.
##  2. LMB places the entrance (blue).
##  3. LMB again places the exit (orange), the same way. The two link at once:
##     you, enemies and shots can go through either one and come out the other.
##  LMB after that starts a new pair (the old one closes). RMB closes the pair.

## How far away a doorway can be placed at Aiming 1 (+5% per aiming level).
@export var place_range := 40.0
@export var place_cooldown := 0.35
## Entrance and exit must be at least this far apart.
@export var min_separation := 3.0
## Aiming at a wall within this height of its top puts the doorway on top...
@export var ledge_reach := 6.0
## ...this far in from the edge.
@export var ledge_inset := 1.5
## Aiming over an edge counts if the top is within this angle (degrees) below
## your aim.
@export var skim_angle := 8.0
@export var entrance_color := Color(0.2, 0.6, 1.0)
@export var exit_color := Color(1.0, 0.55, 0.1)

var entrance: Portal
var exit: Portal
var _ghost: Node3D
var _ghost_is_exit := false
var _valid := false
var _trigger_released := true
var _close_released := true


func unequip() -> void:
	super()
	_clear_ghost()


func _weapon_tick(_delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var close := Input.is_action_pressed("alt_fire")
	if close and _close_released and captured and (_has(entrance) or _has(exit)):
		close_portals()
		_wielder().notify("Portals closed")
	_close_released = not close

	_update_ghost()
	var trigger := Input.is_action_pressed("attack")
	if trigger and _trigger_released and can_attack():
		_place()
	_trigger_released = not trigger


func ammo_text() -> String:
	if _placing_exit():
		return "LMB: place exit"
	if _has(entrance) and _has(exit):
		return "Linked  ·  LMB: new entrance  ·  RMB: close"
	return "LMB: place entrance"


## Placement distance, with the wielder's aiming skill.
func max_range() -> float:
	return place_range * _wielder().skills.portal_range_multiplier()


func close_portals() -> void:
	if _has(entrance):
		entrance.queue_free()
	if _has(exit):
		exit.queue_free()
	entrance = null
	exit = null
	_clear_ghost()


# The world generator frees portals when you leave a region, so check before use.
# (Untyped: a freed object can't be passed as a Portal.)
func _has(portal: Variant) -> bool:
	return is_instance_valid(portal) and not portal.is_queued_for_deletion()


func _placing_exit() -> bool:
	return _has(entrance) and not _has(exit)


## Where the doorway would stand: on the ground under the spot your aim picks
## out (see _aim_spot), upright, facing you.
func _update_ghost() -> void:
	var placing_exit := _placing_exit()
	if _ghost == null or _ghost_is_exit != placing_exit:
		_clear_ghost()
		_ghost_is_exit = placing_exit
		_ghost = Portal.make_frame(exit_color if placing_exit else entrance_color, true)
		owner.get_parent().add_child(_ghost)

	var wielder := _wielder()
	var camera := _camera()
	var spot := _aim_spot(camera.global_position, -camera.global_basis.z)
	var ground := _ray(spot + Vector3.UP * 0.5, spot + Vector3.DOWN * 40.0)
	var toward := wielder.global_position - spot
	toward.y = 0.0
	if not ground or toward.length() < 1.0:
		_ghost.visible = false
		_valid = false
		return
	_ghost.global_transform = Transform3D(Basis(Vector3.UP, atan2(toward.x, toward.z)), ground.position)
	_ghost.visible = true
	_valid = not placing_exit or ground.position.distance_to(entrance.global_position) >= min_separation


## The spot your aim picks out, before it's dropped onto the ground. Besides
## the surface you're looking at, this finds high ground you can't see the top
## of from below:
##   - aim just over an edge (a roof, a ledge): it lands on top, past the edge
##   - aim at a wall near its top: it lands on top of the wall, in from the edge
##   - aim at a wall lower down: it stands on the ground in front of it
func _aim_spot(from: Vector3, direction: Vector3) -> Vector3:
	var max_reach := max_range()
	var end := from + direction * max_reach
	var hit := _ray(from, end)
	var reach: float = from.distance_to(hit.position) if hit else max_reach

	# Skimming over the top of something higher than you.
	var feet := _wielder().global_position.y
	var distance := 3.0
	while distance < reach:
		var point := from + direction * distance
		var below := _ray(point, point + Vector3.DOWN * distance * tan(deg_to_rad(skim_angle)))
		if below and below.normal.y >= 0.7 and below.position.y > feet + 1.0:
			# Stand it a little in from the edge (and off the top of a parapet).
			# The top has to carry on that far: a rock or a post doesn't count.
			var inward: Vector3 = below.position + Vector3(direction.x, 0.0, direction.z).normalized() * ledge_inset
			var top := _ray(inward + Vector3.UP * 1.5, inward + Vector3.DOWN * 1.5)
			if top and top.normal.y >= 0.7 and absf(top.position.y - below.position.y) < 1.2 and _has_headroom(top.position):
				return top.position
		distance += 1.0

	if not hit:
		return end
	if hit.normal.y >= 0.7:
		return hit.position
	# A wall or cliff. Its top, if that's close above where you're aiming...
	var into := -Vector3(hit.normal.x, 0.0, hit.normal.z).normalized()
	var inside: Vector3 = hit.position + into * ledge_inset
	var top := _ray(inside + Vector3.UP * ledge_reach, inside)
	if top and top.normal.y >= 0.7 and _has_headroom(top.position):
		return top.position
	return hit.position + hit.normal * 0.5  # ...otherwise the ground in front of it


## Open air above a spot, enough for the doorway (so "the top" is never a floor
## inside a building).
func _has_headroom(at: Vector3) -> bool:
	return _ray(at + Vector3.UP * 0.3, at + Vector3.UP * (Portal.HEIGHT + 0.5)).is_empty()


## A ray against the world that looks past things you interact with (a chest
## on a roof isn't the roof).
func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(query)
	while hit and hit.collider.has_method("interact"):
		query.exclude = query.exclude + [hit.rid]
		hit = space.intersect_ray(query)
	return hit


func _place() -> void:
	if _ghost == null or not _ghost.visible:
		return
	if not _valid:
		_wielder().notify("Too close to the entrance")
		return
	_cooldown = place_cooldown
	var at := _ghost.global_transform
	if _placing_exit():
		exit = _spawn(exit_color, at)
		entrance.link(exit)
		exit.link(entrance)
		_wielder().notify("Portal open")
	else:
		close_portals()  # a third click starts a new pair
		entrance = _spawn(entrance_color, at)
		_wielder().notify("Entrance placed: now place the exit")
	_clear_ghost()


func _spawn(color: Color, at: Transform3D) -> Portal:
	var portal := Portal.new()
	portal.color = color
	owner.get_parent().add_child(portal)
	portal.global_transform = at
	return portal


func _clear_ghost() -> void:
	if _ghost:
		_ghost.queue_free()
		_ghost = null
	_valid = false

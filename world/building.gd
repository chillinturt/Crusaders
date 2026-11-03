@tool
class_name Building
extends Node3D
## Procedural home / apartment block. Each floor has exterior walls with windows,
## a front door on the ground floor, and an interior wall splitting it into a
## front and back room. With more than one floor, a switchback ramp stairwell
## runs up the back-left corner (ramps, since characters can't climb steps).
##
## The building has its own enemy spawner, so going in means close-quarters
## fights. Enemies inside only see out through doors and windows.
##
## The geometry is generated when the scene loads (and live in the editor), so
## change the exports rather than editing children. Local +Z is the front door side.

const WALL := 0.3
const SLAB := 0.3
const DOOR_WIDTH := 1.8
const DOOR_HEIGHT := 2.4
const WINDOW_WIDTH := 1.6
const WINDOW_SILL := 1.0
const WINDOW_TOP := 2.2
const STAIR_LANE := 1.5
const LANDING := 1.3
const GRID_SHADER := preload("res://level/grid.gdshader")
const ENEMY_SPAWNER := preload("res://enemy/enemy_spawner.gd")

@export var width := 12.0:
	set(value):
		width = value
		_queue_rebuild()
@export var depth := 10.0:
	set(value):
		depth = value
		_queue_rebuild()
@export_range(1, 6) var floors := 1:
	set(value):
		floors = value
		_queue_rebuild()
@export var floor_height := 3.2:
	set(value):
		floor_height = value
		_queue_rebuild()
@export var wall_color := Color(0.62, 0.56, 0.5):
	set(value):
		wall_color = value
		_queue_rebuild()
@export var floor_color := Color(0.42, 0.33, 0.26):
	set(value):
		floor_color = value
		_queue_rebuild()
## Extends the stairwell up through a hatch onto a walled roof.
@export var roof_access := false:
	set(value):
		roof_access = value
		_queue_rebuild()
## Off = solid walls with only the front door (bunkers).
@export var windows := true:
	set(value):
		windows = value
		_queue_rebuild()

@export_group("Contents")
## Picked at random per spawn, like EnemySpawner.
@export var enemy_scenes: Array[PackedScene] = []
@export var enemies_per_floor := 1
@export var enemy_respawn_delay := 90.0
## Region level, passed on to the building's enemy spawner.
@export var enemy_level := 1

var _body: StaticBody3D
var _wall_material: ShaderMaterial
var _floor_material: ShaderMaterial
var _rebuild_queued := false


func _ready() -> void:
	_rebuild()


func _queue_rebuild() -> void:
	if is_inside_tree() and not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	for child in get_children():
		if child.has_meta(&"generated"):
			remove_child(child)
			child.queue_free()

	_wall_material = _grid_material(wall_color)
	_floor_material = _grid_material(floor_color)
	_body = StaticBody3D.new()
	_body.name = "Shell"
	_body.set_meta(&"generated", true)
	add_child(_body)

	var hw := width * 0.5
	var hd := depth * 0.5
	for k in floors:
		_build_floor(k, hw, hd)
	for j in range(1, floors + 1):
		_build_slab(j, hw, hd)
	for k in _ramp_count():
		_build_ramp(k, hw, hd)
	if roof_access:
		# Waist-high parapet around the roof.
		var roof_y := floors * floor_height
		_wall(true, hd - WALL * 0.5, -hw, hw, roof_y, 1.0, [])
		_wall(true, -hd + WALL * 0.5, -hw, hw, roof_y, 1.0, [])
		_wall(false, -hw + WALL * 0.5, -hd + WALL, hd - WALL, roof_y, 1.0, [])
		_wall(false, hw - WALL * 0.5, -hd + WALL, hd - WALL, roof_y, 1.0, [])
	if not Engine.is_editor_hint():
		_add_contents(hw, hd)


# --- Layout -------------------------------------------------------------------

func _stair_run() -> float:
	return floor_height * 1.25  # ~39 degrees: under the 45 degree walkable limit


func _stair_x0(hw: float) -> float:
	return -hw + WALL


func _stair_z_back(hd: float) -> float:
	return -hd + WALL + LANDING


## Ramps between floors, plus one up to the roof with roof_access.
func _ramp_count() -> int:
	return floors - 1 + (1 if roof_access else 0)


## Left edge of the rooms; the stairwell (two lanes) sits to the left of it.
func _rooms_x0(hw: float) -> float:
	return _stair_x0(hw) + 2.0 * STAIR_LANE if _ramp_count() > 0 else -hw + WALL


# --- Routes (for enemy pathfinding) ---------------------------------------------
# Floors are numbered 0 (ground) upward; the roof is `floors`.

## Highest level the ramps reach: the top floor, or the roof with roof_access.
func top_level() -> int:
	return _ramp_count()


## Whether a world position is inside this building's footprint (any floor or the roof).
func contains(world: Vector3) -> bool:
	var p := to_local(world)
	return absf(p.x) <= width * 0.5 + 0.3 and absf(p.z) <= depth * 0.5 + 0.3 \
			and p.y > -1.0 and p.y < floors * floor_height + 4.0


func level_at(world: Vector3) -> int:
	return clampi(floori((to_local(world).y + 0.8) / floor_height), 0, floors)


## Just outside the front door, on the ground.
func door_outside() -> Vector3:
	return to_global(Vector3(width * 0.2, 0.0, depth * 0.5 + 2.2))


func _door_inside() -> Vector3:
	return Vector3(width * 0.2, 0.0, depth * 0.5 - 1.5)


## A point just in front of (side = 1) or behind (side = -1) the doorway in the
## wall between the two rooms, on a level.
func _room_door(level: int, side: float) -> Vector3:
	return Vector3((_rooms_x0(width * 0.5) + width * 0.5) * 0.5, level * floor_height, 1.2 * side)


## Bottom (top = false) or top end of ramp k, which climbs from level k to k + 1.
func _ramp_end(k: int, top: bool) -> Vector3:
	var lane := k % 2
	var z_back := _stair_z_back(depth * 0.5)
	var back := Vector3(0.0, 0.0, z_back - 0.6)
	var front := Vector3(0.0, 0.0, z_back + _stair_run() + 0.6)
	# Left-lane ramps rise from the back landing to the front; right-lane the reverse.
	var end := (front if top else back) if lane == 0 else (back if top else front)
	end.x = _stair_x0(width * 0.5) + STAIR_LANE * (lane + 0.5)
	end.y = (k + 1 if top else k) * floor_height
	return end


## Waypoints (world space) for crossing one floor from `from` to `to`: through
## the doorway in the wall between the front and back rooms if they're on
## opposite sides of it. Empty if the straight line is clear.
func floor_route(level: int, from: Vector3, to: Vector3) -> PackedVector3Array:
	var a := to_local(from)
	var b := to_local(to)
	var route := PackedVector3Array()
	if level >= floors or (a.z >= 0.0) == (b.z >= 0.0):
		return route  # the roof has no rooms; same room otherwise
	route.append(to_global(_room_door(level, 1.0 if a.z >= 0.0 else -1.0)))
	route.append(to_global(_room_door(level, 1.0 if b.z >= 0.0 else -1.0)))
	return route


## Waypoints (world space) up or down the ramps from `from_level` to `to_level`:
## the two ends of each ramp, in order. Stops at the highest reachable level if
## `to_level` has no ramp to it (a roof without roof_access). Empty if no
## climbing is needed. Getting to the first ramp is floor_route()'s job.
func stair_route(from_level: int, to_level: int) -> PackedVector3Array:
	var local := PackedVector3Array()
	to_level = mini(to_level, top_level())
	from_level = mini(from_level, top_level())
	if to_level > from_level:
		for k in range(from_level, to_level):
			local.append(_ramp_end(k, false))
			local.append(_ramp_end(k, true))
	elif to_level < from_level:
		for k in range(from_level - 1, to_level - 1, -1):
			local.append(_ramp_end(k, true))
			local.append(_ramp_end(k, false))
	var world := PackedVector3Array()
	for point in local:
		world.append(to_global(point))
	return world


## From just outside the door to `level`.
func route_in(level: int) -> PackedVector3Array:
	var route := PackedVector3Array([door_outside(), to_global(_door_inside())])
	if mini(level, top_level()) > 0:
		route.append(to_global(_room_door(0, 1.0)))  # through to the back room, where the first ramp starts
		route.append(to_global(_room_door(0, -1.0)))
		route.append_array(stair_route(0, level))
	return route


## From `level` to just outside the door.
func route_out(level: int) -> PackedVector3Array:
	var route := stair_route(level, 0)
	if not route.is_empty():
		route.append(to_global(_room_door(0, -1.0)))  # ramps end in the back room
		route.append(to_global(_room_door(0, 1.0)))
	route.append(to_global(_door_inside()))
	route.append(door_outside())
	return route


func _build_floor(k: int, hw: float, hd: float) -> void:
	var y0 := k * floor_height
	var h := floor_height - SLAB
	var door_x := hw * 0.4

	var front: Array = [_window(-hw * 0.45)]
	front.append(Vector4(door_x, DOOR_WIDTH, 0.0, DOOR_HEIGHT) if k == 0 else _window(door_x))
	_wall(true, hd - WALL * 0.5, -hw, hw, y0, h, front)
	_wall(true, -hd + WALL * 0.5, -hw, hw, y0, h, [_window(hw * 0.45)])
	_wall(false, -hw + WALL * 0.5, -hd + WALL, hd - WALL, y0, h, [_window(hd * 0.55)])
	_wall(false, hw - WALL * 0.5, -hd + WALL, hd - WALL, y0, h, [_window(-hd * 0.45), _window(hd * 0.45)])

	# Interior wall between the front and back rooms. The stairwell stays open to both.
	var x0 := _rooms_x0(hw)
	_wall(true, 0.0, x0, hw - WALL, y0, h, [Vector4((x0 + hw) * 0.5, DOOR_WIDTH, 0.0, DOOR_HEIGHT)])

	# Dim lights so interiors under the roof aren't pitch black.
	for z in [hd * 0.5, -hd * 0.5]:
		var light := OmniLight3D.new()
		light.position = Vector3((x0 + hw) * 0.5, y0 + h - 0.4, z)
		light.light_color = Color(1.0, 0.85, 0.65)
		light.light_energy = 0.6
		light.omni_range = maxf(width, depth) * 0.5
		_body.add_child(light)


## Floor slab at the top of floor j-1 (j = floors is the roof), with a hole over
## the ramp that climbs to it.
func _build_slab(j: int, hw: float, hd: float) -> void:
	var y_top := j * floor_height
	var y_bot := y_top - SLAB
	var material := _wall_material if j == floors else _floor_material
	if j > _ramp_count():  # nothing climbs up through this one
		_slab_piece(-hw, hw, -hd, hd, y_bot, y_top, material)
		return
	var lane := (j - 1) % 2
	var hx0 := _stair_x0(hw) + STAIR_LANE * lane
	var hx1 := hx0 + STAIR_LANE
	var hz0 := _stair_z_back(hd)
	var hz1 := hz0 + _stair_run()
	_slab_piece(-hw, hx0, -hd, hd, y_bot, y_top, material)
	_slab_piece(hx1, hw, -hd, hd, y_bot, y_top, material)
	_slab_piece(hx0, hx1, -hd, hz0, y_bot, y_top, material)
	_slab_piece(hx0, hx1, hz1, hd, y_bot, y_top, material)


## Ramp from floor k to k+1. Even floors use the left lane rising toward the
## front; odd floors use the right lane rising toward the back (switchback).
func _build_ramp(k: int, hw: float, hd: float) -> void:
	var lane := k % 2
	var run := _stair_run()
	var rise := floor_height
	var angle := atan2(rise, run)
	var thickness := 0.25
	var z_back := _stair_z_back(hd)
	var center := Vector3(
		_stair_x0(hw) + STAIR_LANE * (lane + 0.5),
		k * rise + rise * 0.5 - thickness * 0.5 / cos(angle),  # top surface through the midpoint
		z_back + run * 0.5)
	var tilt := Basis(Vector3.RIGHT, -angle if lane == 0 else angle)
	_box(Vector3(STAIR_LANE - 0.05, thickness, sqrt(rise * rise + run * run)), center, _floor_material, tilt)


func _add_contents(hw: float, hd: float) -> void:
	var room_x := (_rooms_x0(hw) + hw) * 0.5
	if not enemy_scenes.is_empty() and enemies_per_floor > 0:
		var spawner := Node3D.new()
		spawner.name = "Enemies"
		spawner.set_script(ENEMY_SPAWNER)
		spawner.enemy_scenes = enemy_scenes
		spawner.max_alive = floors * enemies_per_floor
		spawner.respawn_delay = enemy_respawn_delay
		spawner.min_player_distance = 0.0
		spawner.level = enemy_level
		for k in floors:
			var y := k * floor_height + 0.1
			spawner.add_child(_marker(Vector3(room_x, y, hd * 0.5)))
			spawner.add_child(_marker(Vector3(room_x, y, -hd * 0.5)))
		_add_generated(spawner)


# --- Geometry helpers ---------------------------------------------------------

func _window(center: float) -> Vector4:
	if not windows:
		return Vector4(center, 0.0, 0.0, 0.0)  # zero-width opening: a solid wall
	return Vector4(center, WINDOW_WIDTH, WINDOW_SILL, WINDOW_TOP)


## A wall running along X (at z = fixed) or along Z (at x = fixed) from a0 to a1,
## with openings given as Vector4(center, width, bottom, top) relative to y0.
func _wall(along_x: bool, fixed: float, a0: float, a1: float, y0: float, h: float, openings: Array) -> void:
	openings.sort_custom(func(a: Vector4, b: Vector4) -> bool: return a.x < b.x)
	var cursor := a0
	for o: Vector4 in openings:
		var s := o.x - o.y * 0.5
		var e := o.x + o.y * 0.5
		_wall_piece(along_x, fixed, cursor, s, y0, y0 + h)
		_wall_piece(along_x, fixed, s, e, y0, y0 + o.z)        # below the opening
		_wall_piece(along_x, fixed, s, e, y0 + o.w, y0 + h)    # above it
		cursor = e
	_wall_piece(along_x, fixed, cursor, a1, y0, y0 + h)


func _wall_piece(along_x: bool, fixed: float, s: float, e: float, y_bot: float, y_top: float) -> void:
	if e - s < 0.01 or y_top - y_bot < 0.01:
		return
	var mid := Vector2((s + e) * 0.5, (y_bot + y_top) * 0.5)
	if along_x:
		_box(Vector3(e - s, y_top - y_bot, WALL), Vector3(mid.x, mid.y, fixed), _wall_material)
	else:
		_box(Vector3(WALL, y_top - y_bot, e - s), Vector3(fixed, mid.y, mid.x), _wall_material)


func _slab_piece(x0: float, x1: float, z0: float, z1: float, y0: float, y1: float, material: Material) -> void:
	if x1 - x0 < 0.01 or z1 - z0 < 0.01:
		return
	_box(Vector3(x1 - x0, y1 - y0, z1 - z0), Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5), material)


func _box(size: Vector3, center: Vector3, material: Material, tilt := Basis()) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.transform = Transform3D(tilt, center)
	_body.add_child(collision)

	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.transform = Transform3D(tilt, center)
	_body.add_child(instance)


func _marker(at: Vector3) -> Marker3D:
	var marker := Marker3D.new()
	marker.position = at
	return marker


func _add_generated(node: Node) -> void:
	node.set_meta(&"generated", true)
	add_child(node)


func _grid_material(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GRID_SHADER
	material.set_shader_parameter(&"color_a", color)
	material.set_shader_parameter(&"color_b", color.darkened(0.05))  # subtle tiling, not a test checkerboard
	material.set_shader_parameter(&"cell_size", 1.0)
	return material

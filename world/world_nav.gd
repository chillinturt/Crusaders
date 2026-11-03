class_name WorldNav
extends RefCounted
## Pathfinding for a generated region. Two layers:
##   - the ground: an A* grid over the heightmap (same cells as the terrain).
##     Cells are blocked where the slope is too steep to walk or a structure
##     stands. A second "wide" grid blocks extra space around structures, for
##     huge enemies (titans) that need room and stay out of tight places.
##   - buildings: each Building knows its own route from its door up its ramps
##     (see Building.route_in / route_out / stair_route).
## route() joins them: around obstacles to a door, then up to the right floor.
## The world generator builds one per region and hands it to Enemy.nav.

var size := 0.0
var cell := 2.0
var n := 0
var buildings: Array[Building] = []

var _heights: PackedFloat32Array
var _grid := AStarGrid2D.new()
var _wide := AStarGrid2D.new()


func setup(p_size: float, p_cell: float, p_n: int, heights: PackedFloat32Array) -> void:
	size = p_size
	cell = p_cell
	n = p_n
	_heights = heights
	for grid: AStarGrid2D in [_grid, _wide]:
		grid.region = Rect2i(0, 0, n, n)
		grid.cell_size = Vector2(cell, cell)
		grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		grid.update()


# --- Building the grids (called by the world generator) -----------------------

func block_cell(c: Vector2i, wide_only := false) -> void:
	if c.x < 0 or c.y < 0 or c.x >= n or c.y >= n:
		return
	_wide.set_point_solid(c, true)
	if not wide_only:
		_grid.set_point_solid(c, true)


## Blocks a rectangle (given by a transform and half-extents on its local X/Z).
## The wide grid gets `clearance` meters more on every side.
func block_rect(xform: Transform3D, half_x: float, half_z: float, clearance := 4.0) -> void:
	var reach := Vector2(half_x, half_z).length() + clearance
	var center := cell_of(xform.origin)
	var span := ceili(reach / cell) + 1
	var inverse := xform.affine_inverse()
	for j in range(center.y - span, center.y + span + 1):
		for i in range(center.x - span, center.x + span + 1):
			var local := inverse * Vector3(-size * 0.5 + i * cell, xform.origin.y, -size * 0.5 + j * cell)
			var dx := absf(local.x) - half_x
			var dz := absf(local.z) - half_z
			if dx <= 0.0 and dz <= 0.0:
				block_cell(Vector2i(i, j))
			elif dx <= clearance and dz <= clearance:
				block_cell(Vector2i(i, j), true)


func block_circle(center: Vector3, radius: float, clearance := 4.0) -> void:
	var c := cell_of(center)
	var span := ceili((radius + clearance) / cell) + 1
	for j in range(c.y - span, c.y + span + 1):
		for i in range(c.x - span, c.x + span + 1):
			var d := Vector2(-size * 0.5 + i * cell - center.x, -size * 0.5 + j * cell - center.z).length()
			if d <= radius:
				block_cell(Vector2i(i, j))
			elif d <= radius + clearance:
				block_cell(Vector2i(i, j), true)


# --- Queries ------------------------------------------------------------------

func cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(clampi(roundi((pos.x + size * 0.5) / cell), 0, n - 1), clampi(roundi((pos.z + size * 0.5) / cell), 0, n - 1))


func point_of(c: Vector2i) -> Vector3:
	return Vector3(-size * 0.5 + c.x * cell, _heights[c.y * n + c.x], -size * 0.5 + c.y * cell)


func ground_height(x: float, z: float) -> float:
	var c := cell_of(Vector3(x, 0.0, z))
	return _heights[c.y * n + c.x]


func is_open(pos: Vector3, wide := false) -> bool:
	return not (_wide if wide else _grid).is_point_solid(cell_of(pos))


func building_containing(pos: Vector3) -> Building:
	for building in buildings:
		if is_instance_valid(building) and building.contains(pos):
			return building
	return null


## Waypoints along the ground from `from` to `to`, around steep slopes and
## structures. Ends as close as it can get if `to` can't be reached.
func ground_path(from: Vector3, to: Vector3, wide := false) -> PackedVector3Array:
	var grid := _wide if wide else _grid
	var start := _nearest_open(grid, cell_of(from))
	var goal := _nearest_open(grid, cell_of(to))
	var points := PackedVector3Array()
	var ids := grid.get_id_path(start, goal, true)
	for index in range(1, ids.size()):  # skip the cell we're standing in
		points.append(point_of(ids[index]))
	return points


## The full route for a walking enemy: off its building if it's in one, across
## the ground, and into and up the target's building if there is one. Always
## ends at `to`. Wide (titan) routes stop outside buildings.
func route(from: Vector3, to: Vector3, wide := false) -> PackedVector3Array:
	var from_building := building_containing(from)
	var to_building := building_containing(to)
	var points := PackedVector3Array()
	if wide:
		points = ground_path(from, to, true)
		if to_building == null:
			points.append(to)
		return points
	if from_building != null and from_building == to_building:
		var level := from_building.level_at(from)
		var stairs := from_building.stair_route(level, from_building.level_at(to))
		if stairs.is_empty():
			points.append_array(from_building.floor_route(level, from, to))
		else:
			points.append_array(from_building.floor_route(level, from, stairs[0]))
			points.append_array(stairs)
			var last := stairs[stairs.size() - 1]
			points.append_array(from_building.floor_route(from_building.level_at(last), last, to))
		points.append(to)
		return points

	var start := from
	if from_building:
		var level := from_building.level_at(from)
		var out := from_building.route_out(level)
		points.append_array(from_building.floor_route(level, from, out[0]))
		points.append_array(out)
		start = from_building.door_outside()
	var end := to_building.door_outside() if to_building else to
	points.append_array(ground_path(start, end))
	if to_building:
		var into := to_building.route_in(to_building.level_at(to))
		var last := into[into.size() - 1]
		points.append_array(into)
		points.append_array(to_building.floor_route(to_building.level_at(last), last, to))
	points.append(to)
	return points


func _nearest_open(grid: AStarGrid2D, c: Vector2i) -> Vector2i:
	if not grid.is_point_solid(c):
		return c
	for ring in range(1, 10):
		for j in range(-ring, ring + 1):
			for i in range(-ring, ring + 1):
				if maxi(absi(i), absi(j)) != ring:
					continue
				var candidate := c + Vector2i(i, j)
				if candidate.x >= 0 and candidate.y >= 0 and candidate.x < n and candidate.y < n \
						and not grid.is_point_solid(candidate):
					return candidate
	return c

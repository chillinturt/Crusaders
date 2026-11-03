extends Control
## Minimap in the corner of the HUD: the region from above, centered on you and
## turned so that the way you face is up.
##   terrain    shaded picture made by the world generator for each region
##   buildings  grey blocks
##   you        white arrow in the middle
##   enemies    red dots (titans: big, and pinned to the edge when off the map)
##   chests     yellow squares (purple = grand), until opened
##   tunnels    green = open, grey = sealed; pinned to the edge when off the map
##   portals    short lines in their own colors
## M cycles the zoom.

## Meters from the middle to the edge, per zoom level.
@export var ranges: PackedFloat32Array = [50.0, 100.0, 220.0]
@export var background := Color(0.05, 0.06, 0.08, 0.85)

var _zoom := 0
var _player: Node3D
var _generator: Node


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player = owner as Node3D


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("map_zoom"):
		_zoom = (_zoom + 1) % ranges.size()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(_generator):
		_generator = get_tree().get_first_node_in_group(&"world_generator")
	var half := size * 0.5
	draw_rect(Rect2(Vector2.ZERO, size), background)
	if not is_instance_valid(_generator) or not is_instance_valid(_player):
		return
	var scale_px := half.x / ranges[_zoom]  # pixels per meter
	var here := Vector2(_player.global_position.x, _player.global_position.z)
	var yaw := _player.rotation.y

	# World-space layer: x/z in meters around the player, turned to face up.
	draw_set_transform(half, yaw, Vector2(scale_px, scale_px))
	var map: Texture2D = _generator.map_texture
	if map:
		var span: float = (map.get_width() - 1) * _generator.cell
		var corner := Vector2(-_generator.size * 0.5, -_generator.size * 0.5) - Vector2(_generator.cell, _generator.cell) * 0.5
		draw_texture_rect(map, Rect2(corner - here, Vector2(span, span) + Vector2(_generator.cell, _generator.cell)), false)
	var nav: WorldNav = _generator.nav
	if nav:
		for building in nav.buildings:
			if is_instance_valid(building):
				_draw_block(building.global_transform, building.width * 0.5, building.depth * 0.5, here, Color(0.78, 0.78, 0.8))
	for portal in Portal.all:
		var a := portal.to_global(Vector3(-Portal.WIDTH * 0.5, 0, 0))
		var b := portal.to_global(Vector3(Portal.WIDTH * 0.5, 0, 0))
		draw_line(Vector2(a.x, a.z) - here, Vector2(b.x, b.z) - here, portal.color, 3.0 / scale_px)

	# Screen-space layer: markers keep their size and stay upright.
	draw_set_transform(Vector2.ZERO)
	var dot := clampf(scale_px * 0.8, 0.6, 1.0)  # smaller when zoomed out, so they don't pile up
	for tunnel: Node3D in get_tree().get_nodes_in_group(&"tunnels"):
		var open: bool = _generator.can_travel(tunnel.step)
		var at := _place(tunnel.global_position, here, yaw, scale_px, true)
		draw_rect(Rect2(at - Vector2(5, 5), Vector2(10, 10)), Color(0.3, 1.0, 0.45) if open else Color(0.55, 0.55, 0.6))
		draw_rect(Rect2(at - Vector2(5, 5), Vector2(10, 10)), Color.BLACK, false, 1.0)
	for chest: Chest in get_tree().get_nodes_in_group(&"chests"):
		if chest.is_open or not _on_map(chest.global_position, here):
			continue
		var at := _place(chest.global_position, here, yaw, scale_px, false)
		draw_rect(Rect2(at - Vector2(3, 3) * dot, Vector2(6, 6) * dot), Color(0.75, 0.45, 1.0) if chest.rolls > 1 else Color(1.0, 0.85, 0.25))
	for enemy: Node3D in get_tree().get_nodes_in_group(&"enemies"):
		var boss: bool = enemy.is_boss
		if not boss and not _on_map(enemy.global_position, here):
			continue
		var at := _place(enemy.global_position, here, yaw, scale_px, boss)
		if boss:
			draw_circle(at, 6.5, Color.BLACK)
			draw_circle(at, 5.0, Color(1.0, 0.2, 0.15))
		else:
			draw_circle(at, 2.5 * dot, Color(1.0, 0.3, 0.25))

	# You, north, frame.
	draw_colored_polygon([half + Vector2(0, -8), half + Vector2(5.5, 6), half + Vector2(0, 3), half + Vector2(-5.5, 6)], Color.WHITE)
	var north := half + Vector2(0, -1).rotated(yaw) * (half.x - 10.0)
	draw_string(get_theme_default_font(), north + Vector2(-5, 5), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.85))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.5), false, 2.0)


func _on_map(world: Vector3, here: Vector2) -> bool:
	var offset := Vector2(world.x, world.z) - here
	return maxf(absf(offset.x), absf(offset.y)) < ranges[_zoom] * 1.5  # the corners reach further


## Where a world position lands on the map, in pixels. `pin` keeps things that
## are off the map on its edge, as a pointer toward them.
func _place(world: Vector3, here: Vector2, yaw: float, scale_px: float, pin: bool) -> Vector2:
	var half := size * 0.5
	var offset := (Vector2(world.x, world.z) - here).rotated(yaw) * scale_px
	if pin:
		var limit := half - Vector2(8, 8)
		var over := maxf(absf(offset.x) / limit.x, absf(offset.y) / limit.y)
		if over > 1.0:
			offset /= over
	return half + offset


func _draw_block(xform: Transform3D, half_x: float, half_z: float, here: Vector2, color: Color) -> void:
	var points := PackedVector2Array()
	for corner: Vector3 in [Vector3(-half_x, 0, -half_z), Vector3(half_x, 0, -half_z), Vector3(half_x, 0, half_z), Vector3(-half_x, 0, half_z)]:
		var world := xform * corner
		points.append(Vector2(world.x, world.z) - here)
	draw_colored_polygon(points, color)

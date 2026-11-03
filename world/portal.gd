class_name Portal
extends Node3D
## One end of a wormhole: an upright doorway standing on the ground. Two linked
## portals behave as one hole in space, from either side:
##   - you see through it (a camera at the other end renders what you'd see)
##   - the player, enemies, projectiles and grenades that cross the opening come
##     out of the other portal, keeping their speed and heading
##   - bullets pass through (see raycast())
## Going in the front of one comes out the back of the other, so walking straight
## through keeps you walking straight.
##
## Local space: the origin is the middle of the doorway's base; the opening spans
## x = -WIDTH/2..WIDTH/2 and y = 0..HEIGHT on the plane z = 0.
##
## Anything in the "portal_travelers" group can pass. The view isn't recursive: a
## portal seen through a portal shows only its frame.

const WIDTH := 2.4
const HEIGHT := 3.2
const POST := 0.16
## Portal surfaces render on this layer only, so the cameras looking through
## portals can leave them out.
const SURFACE_LAYER := 1 << 19
## Portal frames, and the player's held weapon: also left out of those cameras.
const FRAME_LAYER := 1 << 18
const VIEWMODEL_LAYER := 1 << 17
const TRAVELERS := &"portal_travelers"
const SHADER := preload("res://world/portal.gdshader")

## Every portal in the world.
static var all: Array[Portal] = []

@export var color := Color(0.2, 0.6, 1.0)

## The other end (null = not open yet: shows a swirl).
var linked: Portal

var _surface: MeshInstance3D
var _box := BoxMesh.new()
var _material := ShaderMaterial.new()
var _viewport: SubViewport
var _camera: Camera3D
## Travelers' positions last tick (instance id -> local position), to see who crossed.
var _previous := {}


func _enter_tree() -> void:
	all.append(self)


func _exit_tree() -> void:
	all.erase(self)
	if is_instance_valid(linked) and linked.linked == self:
		linked.link(null)


func _ready() -> void:
	process_physics_priority = 100  # after everything has moved this tick
	process_priority = 100          # after the player's camera is where it will be drawn
	add_child(make_frame(color, false))

	_material.shader = SHADER
	_material.set_shader_parameter("tint", color)
	_surface = MeshInstance3D.new()
	_surface.mesh = _box
	_surface.material_override = _material
	_surface.layers = SURFACE_LAYER
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_surface)
	_shape_surface(1.0, false)

	_viewport = SubViewport.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.use_hdr_2d = true  # keeps the image linear, so it isn't tonemapped twice
	_viewport.msaa_3d = get_viewport().msaa_3d
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.cull_mask = 0xFFFFF & ~(SURFACE_LAYER | FRAME_LAYER | VIEWMODEL_LAYER)
	_viewport.add_child(_camera)
	_camera.current = true
	_match_viewport()
	get_viewport().size_changed.connect(_match_viewport)
	link(linked)


## Opens the wormhole to `other` (or closes it with null). Call on both ends.
func link(other: Portal) -> void:
	linked = other
	_previous.clear()
	if _material == null or _viewport == null:
		return
	var open := is_instance_valid(linked)
	_material.set_shader_parameter("open", open)
	if open:
		_material.set_shader_parameter("view", _viewport.get_texture())
		# Same world as the main view, but the tonemapping is left to the main view.
		var environment := get_world_3d().environment
		if environment:
			environment = environment.duplicate()
			environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			environment.tonemap_exposure = 1.0
			_camera.environment = environment


## Maps a transform at this portal to the matching one at the other end.
func to_linked() -> Transform3D:
	return linked.global_transform * global_transform.affine_inverse()


func center() -> Vector3:
	return to_global(Vector3(0.0, HEIGHT * 0.5, 0.0))


## Whether a point (local space) on the portal's plane is inside the opening.
static func in_opening(local: Vector3, margin := 0.0) -> bool:
	return absf(local.x) <= WIDTH * 0.5 - margin and local.y >= -0.3 and local.y <= HEIGHT - margin


# --- Seeing through -------------------------------------------------------------

func _process(_delta: float) -> void:
	var viewer := get_viewport().get_camera_3d()
	if viewer == null:
		return
	var eye := to_local(viewer.global_position)
	# Right up against the doorway the flat surface would be cut off by the
	# camera's near plane, so it becomes a box reaching away from the viewer.
	var close := absf(eye.z) < 1.5 and absf(eye.x) < WIDTH * 0.5 + 0.4 and eye.y > -1.0 and eye.y < HEIGHT + 1.0
	_shape_surface(1.0 if eye.z >= 0.0 else -1.0, close)

	var open := is_instance_valid(linked)
	var watching := open and (close or _on_screen(viewer))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if watching else SubViewport.UPDATE_DISABLED
	if not watching:
		return
	_camera.global_transform = to_linked() * viewer.global_transform
	_camera.fov = viewer.fov
	_camera.far = viewer.far
	# Leave out whatever stands between that camera and the other doorway.
	var depth := INF
	for corner: Vector3 in [Vector3(-WIDTH * 0.5, 0, 0), Vector3(WIDTH * 0.5, 0, 0), Vector3(-WIDTH * 0.5, HEIGHT, 0), Vector3(WIDTH * 0.5, HEIGHT, 0)]:
		depth = minf(depth, -_camera.to_local(linked.to_global(corner)).z)
	_camera.near = clampf(depth - 0.1, viewer.near, viewer.far * 0.5)


func _shape_surface(side: float, deep: bool) -> void:
	var depth := 0.8 if deep else 0.01
	_box.size = Vector3(WIDTH, HEIGHT, depth)
	_surface.position = Vector3(0.0, HEIGHT * 0.5, -side * depth * 0.5)


func _on_screen(viewer: Camera3D) -> bool:
	if viewer.global_position.distance_to(center()) > 150.0:
		return false
	for point: Vector3 in [Vector3(0, HEIGHT * 0.5, 0), Vector3(-WIDTH * 0.5, 0, 0), Vector3(WIDTH * 0.5, 0, 0), Vector3(-WIDTH * 0.5, HEIGHT, 0), Vector3(WIDTH * 0.5, HEIGHT, 0)]:
		if viewer.is_position_in_frustum(to_global(point)):
			return true
	return false


func _match_viewport() -> void:
	_viewport.size = get_window().size


# --- Passing through --------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(linked):
		_previous.clear()
		return
	var seen := {}
	for node: Node3D in get_tree().get_nodes_in_group(TRAVELERS):
		var now := to_local(_track_point(node))
		if now.length() > 40.0:
			continue
		var id := node.get_instance_id()
		var before: Variant = _previous.get(id)
		seen[id] = now
		if before == null or (before.z > 0.0) == (now.z > 0.0) or (now - before).length() > 6.0:
			continue  # didn't cross the plane this tick (or teleported some other way)
		if node.has_method("can_use_portal") and not node.can_use_portal():
			continue
		var crossing: Vector3 = before.lerp(now, before.z / (before.z - now.z))
		if in_opening(crossing):
			_send(node)
			seen.erase(id)
	_previous = seen


## The point whose crossing counts: the player's eyes (so the view never
## jumps), a creature's middle, a projectile's position.
static func _track_point(node: Node3D) -> Vector3:
	var eyes: Variant = node.get("camera")
	if eyes is Camera3D:
		return eyes.global_position
	if node is CharacterBody3D:
		return node.global_position + Vector3.UP * 0.9
	return node.global_position


func _send(node: Node3D) -> void:
	var through := to_linked()
	node.global_transform = through * node.global_transform
	if node is RigidBody3D:
		node.linear_velocity = through.basis * node.linear_velocity
		node.angular_velocity = through.basis * node.angular_velocity
	elif "velocity" in node:
		node.velocity = through.basis * node.velocity
	if node is Node3D and node.has_method("reset_physics_interpolation"):
		node.reset_physics_interpolation()
	# It arrives already through the other doorway: no bouncing straight back.
	linked._previous[node.get_instance_id()] = linked.to_local(_track_point(node))
	if node.has_method("on_portal_travel"):
		node.on_portal_travel()


# --- For bullets and enemies --------------------------------------------------------

## A ray that passes through open portals. Returns intersect_ray()'s result for
## whatever it finally hits (no "collider" key = nothing), plus:
##   "segments"  the straight pieces it travelled, as [from, to] pairs
##   "length"    the total distance
static func raycast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, mask: int, exclude: Array[RID] = [], hops := 3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = mask
	query.exclude = exclude
	var result := space.intersect_ray(query)
	var end: Vector3 = result.position if result else to

	# The first doorway the ray enters before reaching that point.
	var entered: Portal = null
	var entry := Vector3.ZERO
	var nearest := INF
	if hops > 0:
		for portal in all:
			if not is_instance_valid(portal.linked):
				continue
			var a := portal.to_local(from)
			var b := portal.to_local(end)
			if (a.z > 0.0) == (b.z > 0.0):
				continue
			var crossing := a.lerp(b, a.z / (a.z - b.z))
			var distance := a.distance_to(crossing)
			if in_opening(crossing) and distance < nearest:
				nearest = distance
				entered = portal
				entry = portal.to_global(crossing)
	if entered == null:
		result["segments"] = [[from, end]]
		result["length"] = from.distance_to(end)
		return result

	var through := entered.to_linked()
	var exit := through * entry
	var rest := through * to
	result = raycast(space, exit + (rest - exit).normalized() * 0.02, rest, mask, exclude, hops - 1)
	result["segments"].push_front([from, entry])
	result["length"] += from.distance_to(entry)
	return result


## The portal an enemy at `from` should run into to reach `to` clearly sooner
## than on foot (null if there's none).
static func shortcut(from: Vector3, to: Vector3) -> Portal:
	var direct := from.distance_to(to)
	if direct < 12.0:
		return null
	var best: Portal = null
	var best_cost := direct * 0.65
	for portal in all:
		if not is_instance_valid(portal.linked):
			continue
		var cost := from.distance_to(portal.center()) + portal.linked.center().distance_to(to)
		if cost < best_cost:
			best_cost = cost
			best = portal
	return best


## Where to walk to go through from `from`: first to a spot squarely in front of
## the doorway, then on to a spot beyond it.
func approach_point(from: Vector3) -> Vector3:
	var local := to_local(from)
	var side := 1.0 if local.z >= 0.0 else -1.0
	var lined_up := absf(local.x) < absf(local.z) * 0.5 + 0.6
	return to_global(Vector3(0.0, 0.0, -side * 1.5 if lined_up else side * 2.0))


# --- Looks ------------------------------------------------------------------------

## The doorway's frame (also used, see-through, as the portal gun's preview).
static func make_frame(frame_color: Color, ghost: bool) -> Node3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(frame_color, 0.45 if ghost else 1.0)
	if ghost:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var frame := Node3D.new()
	var half := WIDTH * 0.5 + POST * 0.5
	var pieces := [
		[Vector3(POST, HEIGHT + POST, POST), Vector3(-half, (HEIGHT + POST) * 0.5, 0.0)],
		[Vector3(POST, HEIGHT + POST, POST), Vector3(half, (HEIGHT + POST) * 0.5, 0.0)],
		[Vector3(WIDTH, POST, POST), Vector3(0.0, HEIGHT + POST * 0.5, 0.0)],
	]
	if ghost:  # show the whole doorway while aiming
		pieces.append([Vector3(WIDTH, HEIGHT, 0.02), Vector3(0.0, HEIGHT * 0.5, 0.0)])
	for piece: Array in pieces:
		var mesh := BoxMesh.new()
		mesh.size = piece[0]
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.position = piece[1]
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.layers = FRAME_LAYER
		frame.add_child(instance)
	return frame

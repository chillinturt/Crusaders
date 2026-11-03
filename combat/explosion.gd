class_name Explosion
extends RefCounted
## Shared blast logic for grenades, rockets and shells: damages and launches
## characters (and damages built structures) in the radius that aren't behind
## level geometry. If the instigator has skills (the player), their Explosives
## skill scales the blast, and damage dealt to enemies trains it.

## Explosives XP per 10 damage dealt to enemies.
const XP_PER_10_DAMAGE := 1.0


## instigator takes self_damage_multiplier x damage (grenade/rocket jumps).
## exclude: physics RIDs to ignore (e.g. the grenade body itself).
static func explode(world_node: Node3D, center: Vector3, radius: float, damage: float, force: float,
		instigator: Node = null, self_damage_multiplier := 0.35, exclude: Array[RID] = []) -> void:
	var space := world_node.get_world_3d().direct_space_state
	var skills: Skills = instigator.get("skills") if instigator else null
	if skills:
		damage *= skills.blast_damage_multiplier()
		radius *= skills.blast_radius_multiplier()
		force *= skills.blast_force_multiplier()
		self_damage_multiplier *= skills.blast_self_damage_multiplier()

	var shape := SphereShape3D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), center)
	# Characters only: including the world layer would let terrain triangles fill
	# the result cap. Built structures are found through their group instead.
	params.collision_mask = 2
	params.exclude = exclude

	var targets: Array = []
	for result in space.intersect_shape(params, 32):
		targets.append(result.collider)
	for structure: Node3D in world_node.get_tree().get_nodes_in_group(&"structures"):
		if structure.global_position.distance_to(center) < radius + 2.0:
			targets.append(structure)

	var already_hit := {}
	for body: Object in targets:
		if already_hit.has(body) or not body.has_method("take_damage"):
			continue
		already_hit[body] = true

		# Bosses are measured to their nearest part, so a blast at a titan's head or
		# a dragon's mouth counts as close (not as far as its feet). Everything else
		# is about person-sized: its middle.
		var target: Vector3 = nearest_point(body, center) if body is Enemy and body.is_boss \
				else body.global_position + Vector3.UP * 0.9
		var cover_check := PhysicsRayQueryParameters3D.create(center, target)
		cover_check.collision_mask = 1  # only level geometry is cover
		var cover_exclude := exclude.duplicate()
		cover_exclude.append(body.get_rid())
		cover_check.exclude = cover_exclude
		if space.intersect_ray(cover_check):
			continue

		var falloff := clampf(1.0 - center.distance_to(target) / radius, 0.0, 1.0)
		var amount := damage * lerpf(0.2, 1.0, falloff)
		if body == instigator:
			amount *= self_damage_multiplier
		body.take_damage(amount, center, center)
		if skills and body is Enemy:
			skills.add_xp(&"explosives", amount / 10.0 * XP_PER_10_DAMAGE)
		if body.has_method("push"):
			body.push((target - center).normalized() * force * falloff)

	spawn_fx(world_node.get_parent(), center, radius)


## The point of a body's collision shapes nearest to `point` (spheres, capsules
## and boxes exactly; other shapes by their position). Bodies without shapes:
## their middle.
static func nearest_point(body: Object, point: Vector3) -> Vector3:
	var best: Vector3 = body.global_position + Vector3.UP * 0.9
	var best_distance := INF
	for child: Node in body.get_children():
		var holder := child as CollisionShape3D
		if holder == null or holder.disabled or holder.shape == null:
			continue
		var xform := holder.global_transform
		var candidate := xform.origin
		if holder.shape is SphereShape3D:
			candidate = xform.origin + (point - xform.origin).limit_length(holder.shape.radius)
		elif holder.shape is CapsuleShape3D:
			var capsule: CapsuleShape3D = holder.shape
			var half := xform.basis.y.normalized() * maxf(capsule.height * 0.5 - capsule.radius, 0.0)
			var on_axis := Geometry3D.get_closest_point_to_segment(point, xform.origin - half, xform.origin + half)
			candidate = on_axis + (point - on_axis).limit_length(capsule.radius)
		elif holder.shape is BoxShape3D:
			var extents: Vector3 = holder.shape.size * 0.5
			var local := xform.affine_inverse() * point
			candidate = xform * local.clamp(-extents, extents)
		var distance := candidate.distance_to(point)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


static func spawn_fx(parent: Node, at: Vector3, radius: float) -> void:
	var fx := Node3D.new()
	parent.add_child(fx)
	fx.global_position = at

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.6, 0.2, 0.8)
	var sphere := SphereMesh.new()
	sphere.material = material
	var ball := MeshInstance3D.new()
	ball.mesh = sphere
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ball.scale = Vector3.ONE * 0.5
	fx.add_child(ball)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.3)
	light.light_energy = 8.0
	light.omni_range = radius * 2.0
	fx.add_child(light)

	var tween := fx.create_tween().set_parallel()
	tween.tween_property(ball, "scale", Vector3.ONE * radius * 2.0, 0.25)
	tween.tween_property(material, "albedo_color:a", 0.0, 0.25)
	tween.tween_property(light, "light_energy", 0.0, 0.3)
	tween.chain().tween_callback(fx.queue_free)

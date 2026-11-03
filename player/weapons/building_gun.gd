extends Weapon
## Utility weapon with two modes (RMB switches):
##
##  BUILD  shows a see-through preview of the selected structure where you aim
##         (snapped to a half-meter grid, facing away from you). LMB places it for
##         its cost in build points; R cycles the structure; points recharge over time.
##  LASER  hold LMB for a continuous beam that burns enemies and tears down
##         built structures quickly. It runs on a charge that refills when you stop.

enum Mode { BUILD, LASER }

@export_group("Build")
@export var max_points := 100.0
@export var points_per_second := 6.0
@export var place_range := 9.0
## Parallel arrays: what can be built, and what each costs.
@export var structure_scenes: Array[PackedScene] = []
@export var structure_names: PackedStringArray = []
@export var structure_costs: PackedFloat32Array = []

@export_group("Laser")
@export var laser_dps := 45.0
## Damage multiplier against built structures.
@export var laser_structure_multiplier := 12.0
@export var laser_range := 40.0
@export var max_charge := 100.0
@export var charge_drain := 30.0        ## per second while firing
@export var charge_regen := 20.0        ## per second while not firing
## An emptied laser must recharge to this before it fires again.
@export var charge_restart := 25.0

const GRID := 0.5
const XP_PER_10_DAMAGE := 1.0

var mode := Mode.BUILD
var points: float
var charge: float
var selected := 0
var _ghost: Node3D
var _valid := false
var _overheated := false
var _trigger_released := true
var _mode_released := true
var _cycle_released := true
var _beam_mesh := ImmediateMesh.new()
var _beam: MeshInstance3D
var _ok_material := _flat_material(Color(0.3, 1.0, 0.4, 0.35))
var _blocked_material := _flat_material(Color(1.0, 0.25, 0.2, 0.35))

@onready var muzzle: Marker3D = $Muzzle


func _ready() -> void:
	super()
	points = max_points
	charge = max_charge
	_beam = MeshInstance3D.new()
	_beam.mesh = _beam_mesh
	_beam.material_override = _flat_material(Color(1.0, 0.25, 0.2, 1.0))
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.top_level = true  # vertices are in world space
	add_child(_beam)


func _physics_process(delta: float) -> void:
	# Points and charge refill even while the gun is holstered.
	points = minf(points + points_per_second * delta, max_points)
	super(delta)


func unequip() -> void:
	super()
	_clear_ghost()
	_beam_mesh.clear_surfaces()


func _weapon_tick(delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var mode_pressed := Input.is_action_pressed("alt_fire")
	if mode_pressed and _mode_released and captured:
		mode = Mode.LASER if mode == Mode.BUILD else Mode.BUILD
		_wielder().notify("Building gun: %s mode" % ("LASER" if mode == Mode.LASER else "BUILD"))
	_mode_released = not mode_pressed

	var trigger := Input.is_action_pressed("attack")
	var firing_laser := false
	if mode == Mode.BUILD:
		var cycle := Input.is_action_pressed("reload")
		if cycle and _cycle_released and not structure_scenes.is_empty():
			selected = (selected + 1) % structure_scenes.size()
			_clear_ghost()
		_cycle_released = not cycle
		_update_ghost()
		if trigger and _trigger_released and can_attack():
			_place()
	else:
		_clear_ghost()
		if trigger and can_attack() and not _overheated and charge > 0.0:
			firing_laser = true
			_fire_laser(delta)
	_trigger_released = not trigger

	if firing_laser:
		charge = maxf(charge - charge_drain * delta, 0.0)
		if charge <= 0.0:
			_overheated = true
	else:
		_beam_mesh.clear_surfaces()
		charge = minf(charge + charge_regen * delta, max_charge)
		if charge >= charge_restart:
			_overheated = false


func ammo_text() -> String:
	if mode == Mode.LASER:
		return "LASER %d%%%s" % [roundi(charge / max_charge * 100.0), "  (recharging)" if _overheated else ""]
	if structure_scenes.is_empty():
		return ""
	return "%s (%d)  ·  %d pts" % [structure_names[selected], roundi(structure_costs[selected]), floori(points)]


# --- Build mode ---------------------------------------------------------------

func _update_ghost() -> void:
	if structure_scenes.is_empty():
		return
	if _ghost == null:
		_ghost = structure_scenes[selected].instantiate()
		_ghost.process_mode = Node.PROCESS_MODE_DISABLED  # removes its collision from the world
		owner.get_parent().add_child(_ghost)

	var wielder := _wielder()
	var camera := _camera()
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * place_range)
	query.collision_mask = 1
	query.exclude = [wielder.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# Only on reasonably flat surfaces: ground, floors, tops of walls.
	if not hit or hit.normal.y < 0.7:
		_ghost.visible = false
		_valid = false
		return

	var pos: Vector3 = hit.position
	pos.x = snappedf(pos.x, GRID)
	pos.z = snappedf(pos.z, GRID)
	_ghost.global_transform = Transform3D(Basis(Vector3.UP, snappedf(wielder.rotation.y, PI / 4.0)), pos)
	_ghost.visible = true
	_valid = points >= structure_costs[selected] and not _overlaps_characters()
	_tint(_ghost, _ok_material if _valid else _blocked_material)


## Structures may overlap level geometry (so you can sink a wall into a slope),
## but never a character.
func _overlaps_characters() -> bool:
	var space := get_world_3d().direct_space_state
	for child in _ghost.get_children():
		if child is CollisionShape3D:
			var params := PhysicsShapeQueryParameters3D.new()
			params.shape = child.shape
			params.transform = child.global_transform
			params.collision_mask = 2
			if not space.intersect_shape(params, 1).is_empty():
				return true
	return false


func _place() -> void:
	if _ghost == null or not _ghost.visible:
		return
	var cost := structure_costs[selected]
	if points < cost:
		_wielder().notify("Not enough build points (%d needed)" % roundi(cost))
		return
	if not _valid:
		_wielder().notify("Can't build there")
		return
	points -= cost
	_cooldown = 0.2
	var structure: Node3D = structure_scenes[selected].instantiate()
	owner.get_parent().add_child(structure)
	structure.global_transform = _ghost.global_transform


func _clear_ghost() -> void:
	if _ghost:
		_ghost.queue_free()
		_ghost = null
	_valid = false


func _tint(node: Node, material: Material) -> void:
	if node is GeometryInstance3D:
		node.material_override = material
	for child in node.get_children():
		_tint(child, material)


# --- Laser mode ---------------------------------------------------------------

func _fire_laser(delta: float) -> void:
	var camera := _camera()
	var wielder := _wielder()
	var from := camera.global_position
	var to := from - camera.global_basis.z * laser_range
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1 | 2
	query.exclude = [wielder.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var end := to
	if hit:
		end = hit.position
		var target: Object = hit.collider
		if target.has_method("take_damage"):
			var amount := laser_dps * delta * _upgrades().damage_multiplier()
			if target is Structure:
				amount *= laser_structure_multiplier
			target.take_damage(amount, from, end)
			if target is Enemy:
				wielder.skills.add_xp(&"aiming", amount / 10.0 * XP_PER_10_DAMAGE)
				hit_target.emit()

	_beam_mesh.clear_surfaces()
	_beam_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_beam_mesh.surface_add_vertex(muzzle.global_position)
	_beam_mesh.surface_add_vertex(end)
	_beam_mesh.surface_end()


static func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

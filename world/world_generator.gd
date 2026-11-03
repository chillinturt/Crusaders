extends Node3D
## Builds the world from a chain of regions. Each region has its own seed, biome
## and level, and is generated in place around the player:
##   1. size and "wildness" from the level: later regions are bigger and stranger
##   2. tunnels into the surrounding mountains (forward, and back after the first)
##   3. a heightmap: biome hills plus a random pick of terrain features (ridges,
##      mesas, canyons, craters, terraces), rising into mountains at the edge
##   4. sites, with the ground flattened under each: towns (houses, bunkers, an
##      apartment block or warehouse or stone circle in the middle), watchtowers
##      and twin towers, ruins, forts, bridges, and floating islands
##   5. the terrain mesh + collision, colored by the biome
##   6. the structures themselves, then rock spires, arches and trees
##   7. treasure chests, then enemy and titan spawn points scaled by the level
##   8. an invisible boundary at the foot of the mountains
## Entering a tunnel tears the region down and generates the next one, so skills,
## upgrades and loadout carry over. Revisiting a region rebuilds the same layout
## from its seed (with fresh enemies). Generation must stay deterministic for a
## given region seed, whichever tunnel the player arrives through.
## The Player node must come after this node in the scene.

const ENEMY_SPAWNER := preload("res://enemy/enemy_spawner.gd")
const TUNNEL := preload("res://world/tunnel.gd")
const MELEE_ENEMY := preload("res://enemy/enemy.tscn")
const SPITTER := preload("res://enemy/ranged_enemy.tscn")
const LEAPER := preload("res://enemy/leaper.tscn")
const MORTAR := preload("res://enemy/mortar_enemy.tscn")
const TITAN := preload("res://enemy/titan.tscn")
const DRAGON := preload("res://enemy/dragon.tscn")
const WASP := preload("res://enemy/wasp.tscn")
const GARGOYLE := preload("res://enemy/gargoyle.tscn")
const CHEST := preload("res://world/chest.tscn")
const JUMP_PAD := preload("res://world/structures/jump_pad.tscn")
const GRID_SHADER := preload("res://level/grid.gdshader")
## The first region is always this; later ones pick from the rest.
const START_BIOME := preload("res://world/biomes/grasslands.tres")
const BIOMES: Array[Biome] = [
	preload("res://world/biomes/snowy_forest.tres"),
	preload("res://world/biomes/desert.tres"),
	preload("res://world/biomes/autumn_woods.tres"),
	preload("res://world/biomes/grasslands.tres"),
]

## Physics layer 5: blocks characters at the map edge, nothing else.
const BOUNDARY_LAYER := 16
const SIDES: Array[Vector2] = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
const GRAVITY := 20.3  # the player's, for sizing launch pads

## 0 = a new world every run. The seed is printed so a good one can be kept.
@export var world_seed := 0
## Map width at level 1...
@export var base_size := 320.0
## ...growing by this much per level...
@export var size_per_level := 50.0
## ...up to this.
@export var max_size := 520.0
@export var cell := 2.0
@export var mountain_height := 35.0
## Level at which terrain and structures are at their wildest.
@export var wildest_level := 6

@export_group("Counts at level 1 (scaled up with map area)")
@export var town_count := 2
@export var tower_count := 3
@export var ruin_count := 3
@export var tree_attempts := 700
@export var enemy_spawn_points := 12
## Plus 3 per level.
@export var max_roaming_enemies := 8
## Chests out in the open (structures have their own).
@export var wild_chest_count := 4
## Coins to open a chest at level 1; +50% per level. Grand chests cost 2.2x.
@export var chest_cost := 40

## Current region (0 = the starting one). Level = region_index + 1.
var region_index := 0
## Regions whose titans are dead: their tunnel onward stays open. {index: true}
var cleared_regions := {}
## Chests already opened, so they stay open on a return visit. {index: {chest_id: true}}
var opened_chests := {}
## Width of the current region's map, and the half-width of its playable square
## (mountains rise beyond it; the boundary sits just past it).
var size := 320.0
var play_radius := 120.0

## Pathfinding for the current region (also handed to Enemy.nav).
var nav: WorldNav
## Picture of the current region's terrain from above (one pixel per terrain
## cell), for the minimap.
var map_texture: ImageTexture

var rng := RandomNumberGenerator.new()
var _base_seed := 0
var _region_biomes: Array[Biome] = []
var _biome: Biome
var _level := 1
## Playable area relative to level 1 (scales counts).
var _area := 1.0
## 0 at level 1, 1 at wildest_level and beyond.
var _wild := 0.0
## Bosses still to kill before the tunnel onward opens: kind -> how many.
var _bosses_left := {}
var _chest_count := 0

# Terrain recipe for this region (0 = feature absent).
var _hill_scale := 1.0
var _ridge_height := 0.0
var _mesa_height := 0.0
var _canyon_depth := 0.0
var _terrace := 0.0
## [center: Vector2, radius: float, depth: float]
var _craters: Array = []
var _hills := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _forest := FastNoiseLite.new()
var _ridges := FastNoiseLite.new()
var _mesas := FastNoiseLite.new()
var _canyons := FastNoiseLite.new()

var _n := 0
var _heights := PackedFloat32Array()
var _dirt := PackedFloat32Array()  # 0..1 per vertex, for bare ground around sites
## Flattened areas: [center: Vector2, radius: float, height: float]
var _pads: Array = []
## Raised mountain shoulders the tunnels are cut into: [center: Vector2, radius, height]
var _bumps: Array = []
## Space taken by anything placed so far: [center: Vector2, radius: float]
var _occupied: Array = []
## Planned sites: {kind, pos: Vector2, yaw: float, ...per-kind settings}
var _sites: Array = []
## Tunnels: {side: Vector2, mouth: Vector2, step: int}
var _tunnels: Array = []
## Where chests go, collected while structures are built: [Transform3D, grand: bool]
var _chest_spots: Array = []
## Central spawn point: used for layout spacing, and as the start position.
var _spawn := Vector2.ZERO
## Where (and facing which way) the player appears this time.
var _arrival := Vector2.ZERO
var _arrival_facing := Vector2(0, -1)


func _ready() -> void:
	add_to_group(&"world_generator")
	_base_seed = world_seed if world_seed != 0 else randi()
	print("World seed: %d" % _base_seed)
	_generate(0)


## Called by the tunnel onward (step = +1). Regions can't be revisited.
func travel(step: int) -> void:
	if step > 0:
		_travel.call_deferred(step)


func _travel(step: int) -> void:
	var player := _player()
	if player:
		player.prepare_for_travel()
	_clear_region()
	_generate(region_index + step, -step)


## Biome of any region (deterministic: region 0 is the start biome, then a
## seeded pick that never repeats the previous region's biome).
func region_biome(index: int) -> Biome:
	while _region_biomes.size() <= index:
		var i := _region_biomes.size()
		if i == 0:
			_region_biomes.append(START_BIOME)
			continue
		var pick := RandomNumberGenerator.new()
		pick.seed = _region_seed(i)
		var options := BIOMES.filter(func(b: Biome) -> bool: return b != _region_biomes[i - 1])
		_region_biomes.append(options[pick.randi() % options.size()])
	return _region_biomes[index]


func region_title(index: int) -> String:
	return "Region %d: %s (Level %d)" % [index + 1, region_biome(index).display_name, index + 1]


## Ground height at a world XZ position (after flattening).
func height_at(x: float, z: float) -> float:
	var fx := clampf((x + size * 0.5) / cell, 0.0, _n - 1.001)
	var fz := clampf((z + size * 0.5) / cell, 0.0, _n - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var h00 := _heights[j * _n + i]
	var h10 := _heights[j * _n + i + 1]
	var h01 := _heights[(j + 1) * _n + i]
	var h11 := _heights[(j + 1) * _n + i + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Steepness at a point: 0 flat, 1 = 45 degrees.
func slope_at(x: float, z: float) -> float:
	var dx := height_at(x + 1.0, z) - height_at(x - 1.0, z)
	var dz := height_at(x, z + 1.0) - height_at(x, z - 1.0)
	return Vector2(dx, dz).length() * 0.5


# --- Region lifecycle ---------------------------------------------------------

func _region_seed(index: int) -> int:
	return hash([_base_seed, index])


## arrive_via: 0 = fresh start (spawn near the middle), -1 = came in through the
## tunnel from the previous region (which is caved in behind you).
func _generate(index: int, arrive_via := 0) -> void:
	region_index = index
	_level = index + 1
	_biome = region_biome(index)
	rng.seed = _region_seed(index)
	_pads.clear()
	_bumps.clear()
	_occupied.clear()
	_sites.clear()
	_tunnels.clear()
	_chest_spots.clear()

	size = minf(base_size + size_per_level * index, max_size)
	play_radius = size * 0.5 - 40.0
	_area = pow(play_radius / (base_size * 0.5 - 40.0), 2.0)
	_wild = clampf(float(index) / maxf(wildest_level - 1, 1), 0.0, 1.0)

	_apply_atmosphere()
	_roll_terrain()
	_plan_tunnels(arrive_via)
	_build_heights()
	_plan_sites()
	_apply_pads()
	_build_terrain()
	_build_boundary()
	_build_nav()
	_place_sites()
	_place_tunnels()
	_scatter_scenery()
	_place_chests()
	_scatter_trees()
	_place_spawners()
	Enemy.world_bounds = Rect2(-play_radius, -play_radius, play_radius * 2.0, play_radius * 2.0)
	Enemy.nav = nav

	var player := _player()
	if player:
		var at := Vector3(_arrival.x, height_at(_arrival.x, _arrival.y) + 0.2, _arrival.y)
		var yaw := atan2(-_arrival_facing.x, -_arrival_facing.y)  # the player looks down -Z
		var xform := Transform3D(Basis(Vector3.UP, yaw), at)
		if player.is_node_ready():
			player.arrive(xform, region_title(index))
			player.set_objective(_objective_text())
		else:
			player.global_transform = xform  # first region: before the player records its spawn
			player.arrive.call_deferred(xform, region_title(index))
			player.set_objective.call_deferred(_objective_text())


## Removes everything from the current region: generated content, plus anything
## left in the level by gameplay (built structures, projectiles, grenades).
func _clear_region() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var keep := ["WorldEnvironment", "Sun", name, "Player"]
	for child in get_parent().get_children():
		if not child.name in keep:
			get_parent().remove_child(child)
			child.queue_free()


func _player() -> Node3D:
	return get_parent().get_node_or_null("Player") as Node3D


func _apply_atmosphere() -> void:
	var world_env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env and world_env.environment:
		var env := world_env.environment
		env.fog_light_color = _biome.fog_color
		env.fog_density = _biome.fog_density
		var sky_material := env.sky.sky_material as ProceduralSkyMaterial if env.sky else null
		if sky_material:
			sky_material.sky_top_color = _biome.sky_top
			sky_material.sky_horizon_color = _biome.sky_horizon
			sky_material.ground_horizon_color = _biome.sky_horizon
	var sun := get_parent().get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.light_color = _biome.sun_color


# --- Heightmap ----------------------------------------------------------------

## Picks this region's terrain recipe. Level 1 is mostly gentle hills with the odd
## mild feature; by wildest_level, regions stack several strong ones.
func _roll_terrain() -> void:
	for noise: FastNoiseLite in [_hills, _detail, _forest, _ridges, _mesas, _canyons]:
		noise.seed = rng.randi()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hills.frequency = 0.008
	_hills.fractal_octaves = 4
	_detail.frequency = 0.05
	_forest.frequency = 0.012
	_forest.fractal_octaves = 3
	_ridges.frequency = 0.006
	_ridges.fractal_octaves = 2
	_mesas.frequency = 0.005
	_mesas.fractal_octaves = 1
	_canyons.frequency = 0.0035
	_canyons.fractal_octaves = 1

	var strength := 0.4 + 0.6 * _wild
	_hill_scale = 1.0 + 0.7 * _wild * rng.randf_range(0.5, 1.0)
	_ridge_height = rng.randf_range(7.0, 15.0) * strength if rng.randf() < 0.2 + 0.6 * _wild else 0.0
	_mesa_height = rng.randf_range(7.0, 12.0) * (0.6 + 0.4 * _wild) if rng.randf() < 0.2 + 0.5 * _wild else 0.0
	_canyon_depth = rng.randf_range(6.0, 11.0) * strength if rng.randf() < 0.3 + 0.4 * _wild else 0.0
	_terrace = rng.randf_range(0.25, 0.5) if rng.randf() < 0.1 + 0.5 * _wild else 0.0

	_craters.clear()
	if rng.randf() < 0.3 + 0.5 * _wild:
		for i in rng.randi_range(1, 2 + int(6.0 * _wild * _area)):
			var radius := rng.randf_range(10.0, 24.0)
			var center := Vector2(rng.randf_range(-play_radius, play_radius), rng.randf_range(-play_radius, play_radius))
			_craters.append([center, radius, radius * rng.randf_range(0.2, 0.35)])


## What this region's terrain is made of (for the console and tests).
func terrain_summary() -> String:
	var parts := ["hills x%.2f" % _hill_scale]
	if _ridge_height > 0.0: parts.append("ridges %.0f m" % _ridge_height)
	if _mesa_height > 0.0: parts.append("mesas %.0f m" % _mesa_height)
	if _canyon_depth > 0.0: parts.append("canyons %.0f m" % _canyon_depth)
	if _terrace > 0.0: parts.append("terraces %.0f%%" % (_terrace * 100.0))
	if not _craters.is_empty(): parts.append("%d craters" % _craters.size())
	return ", ".join(parts)


func _base_height(x: float, z: float) -> float:
	var h := _hills.get_noise_2d(x, z) * _biome.hill_height * _hill_scale + _detail.get_noise_2d(x, z) * 0.8
	if _ridge_height > 0.0:
		var ridge := 1.0 - absf(_ridges.get_noise_2d(x, z))
		h += (ridge * ridge * ridge - 0.3) * _ridge_height
	if _mesa_height > 0.0:
		h += smoothstep(0.15, 0.4, _mesas.get_noise_2d(x, z)) * _mesa_height
	if _canyon_depth > 0.0:
		h -= (1.0 - smoothstep(0.0, 0.09, absf(_canyons.get_noise_2d(x, z)))) * _canyon_depth
	for crater in _craters:
		var d: float = Vector2(x, z).distance_to(crater[0])
		var r: float = crater[1]
		if d < r * 1.7:
			h -= crater[2] * (1.0 - smoothstep(0.0, r, d))
			h += crater[2] * 0.35 * exp(-pow((d - r) / (r * 0.22), 2.0))  # raised rim
	if _terrace > 0.0:
		# Pull heights toward 4 m steps, with a ramp between steps so it stays walkable.
		var q := h / 4.0
		var step := floorf(q)
		h = lerpf(h, (step + smoothstep(0.3, 0.7, q - step)) * 4.0, _terrace)

	var edge := maxf(absf(x), absf(z))
	var mountains := smoothstep(play_radius + 2.0, size * 0.5 - 10.0, edge)
	h += mountains * mountain_height * (0.75 + 0.25 * _detail.get_noise_2d(x * 0.3, z * 0.3))
	for bump in _bumps:
		var d: float = Vector2(x, z).distance_to(bump[0])
		h += bump[2] * (1.0 - smoothstep(0.0, bump[1], d))
	return h


func _build_heights() -> void:
	_n = int(size / cell) + 1
	_heights.resize(_n * _n)
	_dirt.resize(_n * _n)
	for j in _n:
		for i in _n:
			_heights[j * _n + i] = _base_height(-size * 0.5 + i * cell, -size * 0.5 + j * cell)
			_dirt[j * _n + i] = 0.0


## Flattens the ground under each site, blending back into the terrain over 8 m.
## Each vertex follows only its most influential pad, so one site's blend ring
## can never tilt another site's flat core (cores have full influence).
## Only the vertices near each pad are visited, so this stays fast on big maps.
func _apply_pads() -> void:
	var best_weight := PackedFloat32Array()
	var best_height := PackedFloat32Array()
	best_weight.resize(_n * _n)
	best_height.resize(_n * _n)
	best_weight.fill(0.0)
	for pad in _pads:
		var center: Vector2 = pad[0]
		var r: float = pad[1]
		var reach := r + 8.0
		var i0 := maxi(int((center.x - reach + size * 0.5) / cell), 0)
		var i1 := mini(int((center.x + reach + size * 0.5) / cell) + 1, _n - 1)
		var j0 := maxi(int((center.y - reach + size * 0.5) / cell), 0)
		var j1 := mini(int((center.y + reach + size * 0.5) / cell) + 1, _n - 1)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var d := Vector2(-size * 0.5 + i * cell, -size * 0.5 + j * cell).distance_to(center)
				if d >= reach:
					continue
				var k := j * _n + i
				var weight := 1.0 - smoothstep(r, reach, d)  # 1 on the pad, 0 outside the ring
				if weight > best_weight[k]:
					best_weight[k] = weight
					best_height[k] = pad[2]
				_dirt[k] = maxf(_dirt[k], 1.0 - smoothstep(r - 2.0, r + 4.0, d))
	for k in _n * _n:
		if best_weight[k] > 0.0:
			_heights[k] = lerpf(_heights[k], best_height[k], best_weight[k])


# --- Site planning --------------------------------------------------------------

## Tunnels go on opposite sides: forward on a random side, and opposite it (after
## the first region) the one you arrived through, which has caved in behind you.
## Called before the heightmap, since each tunnel raises a mountain shoulder.
func _plan_tunnels(arrive_via: int) -> void:
	var forward_side: Vector2 = SIDES[rng.randi() % SIDES.size()]
	var specs := [[forward_side, 1]]
	if region_index > 0:
		specs.append([-forward_side, -1])
	for spec in specs:
		var side: Vector2 = spec[0]
		var offset := Vector2(side.y, side.x).abs() * rng.randf_range(-0.33, 0.33) * play_radius
		var mouth := side * (play_radius + 7.0) + offset
		_tunnels.append({"side": side, "mouth": mouth, "step": spec[1]})
		_bumps.append([mouth + side * 11.0, 16.0, 14.0])

	# The central spawn shapes the layout (sites keep their distance from it) no
	# matter how the player arrives, so a region always generates identically.
	_spawn = Vector2(rng.randf_range(-15, 15), rng.randf_range(-15, 15))
	_reserve(_spawn, 12.0)
	for t in _tunnels:
		_reserve(t.mouth - t.side * 6.0, 12.0)

	# Where the player appears: near the middle at the start, else in front of the
	# tunnel they came through (forward tunnel if they came back, back tunnel if onward).
	if arrive_via == 0:
		_arrival = _spawn
		_arrival_facing = -_spawn.normalized() if _spawn.length() > 1.0 else Vector2(0, -1)
	else:
		var through: Dictionary = _tunnels[0] if arrive_via == 1 or _tunnels.size() == 1 else _tunnels[1]
		var side: Vector2 = through.side
		_arrival = through.mouth - side * 9.0
		_arrival_facing = -side


func _plan_sites() -> void:
	_pads.append([_spawn, 4.0, _base_height(_spawn.x, _spawn.y)])
	for t in _tunnels:
		var approach: Vector2 = t.mouth - t.side * 3.0
		_pads.append([approach, 6.0, _base_height(approach.x, approach.y)])

	# Towns: a centerpiece ringed by houses (and the odd bunker) facing it.
	for t in clampi(roundi(town_count * _area), 1, 5):
		var houses := rng.randi_range(3, 5) + (1 if _level >= 3 else 0)
		var centerpiece: String = "apartment" if t == 0 else ["warehouse", "stone_circle", "plaza", "apartment"][rng.randi() % 4]
		var ring := 16.0 + 2.0 * houses + (4.0 if centerpiece == "warehouse" else 0.0)
		var center := _find_spot(play_radius - ring - 16.0, ring + 12.0, 45.0)
		if not center.is_finite():
			continue
		_reserve(center, ring + 12.0)
		var yaw := rng.randf() * TAU
		match centerpiece:
			"apartment":
				var w := float(rng.randi_range(7, 9) * 2)
				var d := float(rng.randi_range(6, 7) * 2)
				_add_site("apartment", center, yaw, {"width": w, "depth": d, "floors": rng.randi_range(3, mini(2 + _level, 6))})
			"warehouse":
				_add_site("warehouse", center, yaw, {"width": 22.0, "depth": 16.0})
			"stone_circle":
				_add_site("stone_circle", center, yaw, {"radius": 7.0})
			_:
				_pads.append([center, 6.0, _base_height(center.x, center.y)])  # an open square
		var start := rng.randf() * TAU
		for h in houses:
			var angle := start + h * TAU / houses + rng.randf_range(-0.15, 0.15)
			var pos := center + Vector2.from_angle(angle) * (ring + rng.randf_range(-1.0, 1.0))
			var to_center := (center - pos).normalized()
			var facing := atan2(to_center.x, to_center.y)  # door (+Z) faces the middle
			if _level >= 2 and rng.randf() < 0.2:
				_add_site("bunker", pos, facing, {"width": 14.0, "depth": 11.0, "floors": 1 + (1 if rng.randf() < 0.4 else 0)})
			else:
				_add_site("house", pos, facing, {
					"width": float(rng.randi_range(5, 7) * 2), "depth": float(rng.randi_range(4, 5) * 2),
					"floors": 2 if rng.randf() < 0.15 + 0.1 * _level else 1})

	# Out in the wilds.
	for t in roundi(tower_count * _area):
		var floors := rng.randi_range(4, mini(4 + _level, 8))
		if _level >= 2 and rng.randf() < 0.3:
			_plan_lone("twin_towers", 15.0, {"floors": floors})
		else:
			_plan_lone("tower", 7.5, {"floors": floors})
	for t in roundi(ruin_count * _area):
		_plan_lone("ruin", 9.0)
	for t in rng.randi_range(0, 1) + (1 if _level >= 2 else 0) + (1 if _level >= 4 else 0):
		_plan_lone("fort", 25.0)
	for t in rng.randi_range(0, 1 + int(2.0 * _wild)):
		_plan_bridge()
	for t in rng.randi_range(0, 1 + int(_area)):
		_plan_lone("stone_circle", 9.0, {"radius": 7.0})
	if rng.randf() < 0.4:
		_plan_lone("warehouse", 15.5, {"width": 22.0, "depth": 16.0})
	# Floating islands: a rarity at level 2, a fixture of the later regions.
	var islands := 0
	if _level == 2 and rng.randf() < 0.4:
		islands = 1
	elif _level >= 3:
		islands = rng.randi_range(2, 2 + int(5.0 * _wild * _area))
	for t in islands:
		_plan_island()


## A standalone site with `radius` of flat ground, facing the middle of the map.
func _plan_lone(kind: String, radius: float, settings := {}) -> void:
	var pos := _find_spot(play_radius - radius - 6.0, radius + 3.0, 30.0)
	if not pos.is_finite():
		return
	_reserve(pos, radius + 3.0)
	var to_spawn := (_spawn - pos).normalized()
	_sites.append(settings.merged({"kind": kind, "pos": pos, "yaw": atan2(to_spawn.x, to_spawn.y)}))
	_pads.append([pos, radius, _base_height(pos.x, pos.y)])


## A site inside a town (space already reserved); pad sized from its footprint.
func _add_site(kind: String, pos: Vector2, yaw: float, settings := {}) -> void:
	_sites.append(settings.merged({"kind": kind, "pos": pos, "yaw": yaw}))
	var radius: float = settings.get("radius", 0.0) + 2.0
	if settings.has("width"):
		radius = Vector2(settings.width, settings.depth).length() * 0.5 + 1.5
	_pads.append([pos, radius, _base_height(pos.x, pos.y)])


## A long raised walkway. Flat ground under the middle and both ramp feet.
func _plan_bridge() -> void:
	var length := float(rng.randi_range(9, 15) * 2)
	var pos := _find_spot(play_radius - length - 14.0, length * 0.5 + 14.0, 30.0)
	if not pos.is_finite():
		return
	_reserve(pos, length * 0.5 + 14.0)
	var yaw := rng.randf() * TAU
	var along := Vector2(cos(yaw), -sin(yaw))  # local +X in world XZ
	var base := _base_height(pos.x, pos.y)
	_sites.append({"kind": "bridge", "pos": pos, "yaw": yaw, "length": length, "height": rng.randf_range(5.0, 8.0)})
	_pads.append([pos, 5.0, base])
	for end in [-1.0, 1.0]:
		_pads.append([pos + along * end * (length * 0.5 + 9.0), 6.0, base])


## A floating rock with a chest on top, and a launch pad on the ground beside it.
func _plan_island() -> void:
	var radius := rng.randf_range(5.0, 9.0)
	var pos := _find_spot(play_radius - 20.0, radius + 5.0, 25.0)
	if not pos.is_finite():
		return
	_reserve(pos, radius + 5.0)
	var pad_pos := pos + Vector2.from_angle(rng.randf() * TAU) * (radius + 7.0)
	_reserve(pad_pos, 2.5)
	_sites.append({"kind": "island", "pos": pos, "yaw": rng.randf() * TAU, "radius": radius,
		"altitude": rng.randf_range(14.0, 18.0 + 14.0 * _wild), "pad": pad_pos})
	_pads.append([pad_pos, 2.5, _base_height(pad_pos.x, pad_pos.y)])


## A random point within `limit` that has `radius` of free space and is at least
## `min_spawn_distance` from the player spawn. Vector2.INF if none found.
func _find_spot(limit: float, radius: float, min_spawn_distance: float) -> Vector2:
	if limit <= 0.0:
		return Vector2.INF
	for attempt in 300:
		var p := Vector2(rng.randf_range(-limit, limit), rng.randf_range(-limit, limit))
		if p.distance_to(_spawn) >= min_spawn_distance and _is_free(p, radius):
			return p
	return Vector2.INF


func _is_free(p: Vector2, radius: float) -> bool:
	for o in _occupied:
		if p.distance_to(o[0]) < radius + o[1]:
			return false
	return true


func _reserve(p: Vector2, radius: float) -> void:
	_occupied.append([p, radius])


# --- Terrain ------------------------------------------------------------------

func _build_terrain() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(_n * _n)
	normals.resize(_n * _n)
	colors.resize(_n * _n)
	var map_pixels := PackedByteArray()
	map_pixels.resize(_n * _n * 3)
	var map_light := Vector3(-0.5, 0.75, -0.45).normalized()

	for j in _n:
		for i in _n:
			var k := j * _n + i
			var x := -size * 0.5 + i * cell
			var z := -size * 0.5 + j * cell
			var h := _heights[k]
			verts[k] = Vector3(x, h, z)
			var hl := _heights[j * _n + maxi(i - 1, 0)]
			var hr := _heights[j * _n + mini(i + 1, _n - 1)]
			var hd := _heights[maxi(j - 1, 0) * _n + i]
			var hu := _heights[mini(j + 1, _n - 1) * _n + i]
			var normal := Vector3((hl - hr) / (2.0 * cell), 1.0, (hd - hu) / (2.0 * cell)).normalized()
			normals[k] = normal

			var c := _biome.ground_a.lerp(_biome.ground_b, clampf(_detail.get_noise_2d(x * 0.4, z * 0.4) * 0.8 + 0.5, 0.0, 1.0))
			c = c.lerp(_biome.dirt, _dirt[k] * 0.85)
			c = c.lerp(_biome.rock, clampf((1.0 - normal.y) * 4.0 - 0.4, 0.0, 1.0))
			colors[k] = c.lerp(_biome.peak, smoothstep(16.0, 26.0, h))
			# Minimap: the same color, shaded by slope so hills and cliffs read from
			# above, and dimmed outside the playable area.
			var shade := clampf(0.3 + 0.9 * normal.dot(map_light), 0.25, 1.15)
			if maxf(absf(x), absf(z)) > play_radius:
				shade *= 0.55
			map_pixels[k * 3] = clampi(roundi(colors[k].r * shade * 255.0), 0, 255)
			map_pixels[k * 3 + 1] = clampi(roundi(colors[k].g * shade * 255.0), 0, 255)
			map_pixels[k * 3 + 2] = clampi(roundi(colors[k].b * shade * 255.0), 0, 255)
	map_texture = ImageTexture.create_from_image(Image.create_from_data(_n, _n, false, Image.FORMAT_RGB8, map_pixels))

	for j in _n - 1:
		for i in _n - 1:
			var a := j * _n + i
			var b := a + 1
			var c := a + _n
			var d := c + 1
			indices.append_array([a, b, c, b, d, c])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true  # biome colors are authored in sRGB
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var body := StaticBody3D.new()
	body.name = "Terrain"
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	body.add_child(instance)
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)


## Invisible walls at the foot of the mountains, on their own physics layer, so
## characters (player and enemies) can't leave the map but shots and hooks pass.
func _build_boundary() -> void:
	var body := StaticBody3D.new()
	body.name = "Boundary"
	body.collision_layer = BOUNDARY_LAYER
	body.collision_mask = 0
	var edge := play_radius + 10.0
	for side in [Vector3(edge + 2.0, 0, 0), Vector3(-edge - 2.0, 0, 0), Vector3(0, 0, edge + 2.0), Vector3(0, 0, -edge - 2.0)]:
		var box := BoxShape3D.new()
		box.size = Vector3(4.0, 400.0, size) if side.x != 0.0 else Vector3(size, 400.0, 4.0)
		var shape := CollisionShape3D.new()
		shape.shape = box
		shape.position = side
		body.add_child(shape)
	add_child(body)


## Starts this region's pathfinding grid: ground too steep to walk and everything
## outside the playable square is blocked. Structures block their own footprints
## as they're built.
func _build_nav() -> void:
	nav = WorldNav.new()
	nav.setup(size, cell, _n, _heights)
	var limit := play_radius + 6.0
	for j in _n:
		var z := -size * 0.5 + j * cell
		for i in _n:
			var x := -size * 0.5 + i * cell
			if absf(x) > limit or absf(z) > limit:
				nav.block_cell(Vector2i(i, j))
				continue
			var dx := (_heights[j * _n + mini(i + 1, _n - 1)] - _heights[j * _n + maxi(i - 1, 0)]) / (2.0 * cell)
			var dz := (_heights[mini(j + 1, _n - 1) * _n + i] - _heights[maxi(j - 1, 0) * _n + i]) / (2.0 * cell)
			if dx * dx + dz * dz > 0.81:  # steeper than ~42 degrees
				nav.block_cell(Vector2i(i, j))


# --- Sites --------------------------------------------------------------------

## Enemy mix for the current level (each entry equally likely). Flyers only
## spawn outdoors.
func _enemy_mix(outdoors := false) -> Array[PackedScene]:
	var mix: Array[PackedScene] = [MELEE_ENEMY, MELEE_ENEMY, SPITTER]
	if _level >= 3:
		mix = [MELEE_ENEMY, SPITTER, SPITTER, LEAPER, LEAPER, MORTAR, MORTAR]
	elif _level == 2:
		mix = [MELEE_ENEMY, MELEE_ENEMY, SPITTER, LEAPER, LEAPER, MORTAR]
	if outdoors and _level >= 2:
		mix.append_array([WASP, GARGOYLE] if _level == 2 else [WASP, WASP, GARGOYLE, GARGOYLE])
	return mix


func _place_sites() -> void:
	var crowd := 1 if _level >= 3 else 0  # extra enemies per floor in later regions
	for site in _sites:
		var pos: Vector2 = site.pos
		var xform := Transform3D(Basis(Vector3.UP, site.yaw), Vector3(pos.x, height_at(pos.x, pos.y), pos.y))
		match site.kind:
			"house":
				var b := _building(xform, site.width, site.depth, site.floors)
				b.wall_color = _wall_color()
				b.enemies_per_floor = 2 + crowd if site.floors == 1 else 1 + crowd
				add_child(b)
				_chest_in(b, 0, false)
			"bunker":
				var b := _building(xform, site.width, site.depth, site.floors)
				b.floor_height = 3.0
				b.windows = false
				b.wall_color = Color(0.36, 0.38, 0.36)
				b.floor_color = Color(0.28, 0.28, 0.28)
				b.enemies_per_floor = 2 + crowd
				add_child(b)
				_chest_in(b, site.floors - 1, false)
			"warehouse":
				var b := _building(xform, site.width, site.depth, 1)
				b.floor_height = 6.0
				b.wall_color = Color(0.45, 0.42, 0.38)
				b.floor_color = Color(0.3, 0.3, 0.3)
				b.enemies_per_floor = 4 + crowd
				b.enemy_respawn_delay = 120.0
				add_child(b)
				_chest_in(b, 0, false)
				_chest_spots.append([b.global_transform * Transform3D(Basis(), Vector3(-b.width * 0.5 + 1.5, 0.0, b.depth * 0.5 - 1.5)), false])
			"apartment":
				var b := _building(xform, site.width, site.depth, site.floors)
				b.roof_access = true
				b.wall_color = Color(0.5, 0.52, 0.58).lerp(_wall_color(), 0.3)
				b.floor_color = Color(0.35, 0.33, 0.32)
				b.enemies_per_floor = 2 + crowd
				b.enemy_respawn_delay = 120.0
				add_child(b)
				for k in range(1, site.floors):
					_chest_in(b, k, false)
				_chest_spots.append([b.global_transform * Transform3D(Basis(), Vector3(b.width * 0.5 - 1.6, site.floors * b.floor_height, 0.0)), true])
			"tower":
				var b := _tower(xform, site.floors)
				_chest_spots.append([b.global_transform * Transform3D(Basis(), Vector3(2.2, site.floors * b.floor_height, 1.5)), true])
			"twin_towers":
				_build_twin_towers(xform, site.floors)
			"ruin":
				_build_ruin(xform)
			"fort":
				_build_fort(xform, crowd)
			"bridge":
				_build_bridge(xform, site.length, site.height)
			"stone_circle":
				_build_stone_circle(xform, site.radius)
			"island":
				_build_island(site)


## A Building with the shared settings; the caller tweaks it, then adds it.
func _building(xform: Transform3D, width: float, depth: float, floors: int) -> Building:
	var b := Building.new()
	b.name = "Building_%d" % get_child_count()
	b.transform = xform
	b.width = width
	b.depth = depth
	b.floors = floors
	b.enemy_scenes = _enemy_mix()
	b.enemy_level = _level
	nav.block_rect(xform, width * 0.5 + 0.5, depth * 0.5 + 0.5)
	nav.buildings.append(b)
	return b


func _wall_color() -> Color:
	return Color.from_hsv(rng.randf_range(_biome.wall_hue.x, _biome.wall_hue.y),
			_biome.wall_saturation * rng.randf_range(0.7, 1.3), _biome.wall_value * rng.randf_range(0.9, 1.1))


## A chest in the far corner of a building's back room, on floor k.
func _chest_in(b: Building, k: int, grand: bool) -> void:
	var corner := Vector3(b.width * 0.5 - 1.3, k * b.floor_height, -b.depth * 0.5 + 1.3)
	_chest_spots.append([b.global_transform * Transform3D(Basis(), corner), grand])


## Watchtower: narrow, tall, empty of enemies, with a walled roof.
func _tower(xform: Transform3D, floors: int) -> Building:
	var b := _building(xform, 7.0, 9.0, floors)
	b.roof_access = true
	b.wall_color = Color(0.45, 0.47, 0.5)
	b.floor_color = Color(0.32, 0.32, 0.34)
	b.enemies_per_floor = 0
	add_child(b)
	return b


## Two watchtowers joined by a walkway across their roofs.
func _build_twin_towers(xform: Transform3D, floors: int) -> void:
	var left := _tower(xform * Transform3D(Basis(), Vector3(-8.5, 0, 0)), floors)
	_tower(xform * Transform3D(Basis(), Vector3(8.5, 0, 0)), floors)
	var body := _new_body("SkyBridge", xform)
	var deck_y := floors * left.floor_height + 1.0  # level with the top of the roof walls
	_add_box(body, Vector3(13.0, 0.3, 3.0), Transform3D(Basis(), Vector3(0, deck_y + 0.15, 0)), _stone_material(Color(0.4, 0.4, 0.43)))
	add_child(body)
	_chest_spots.append([xform * Transform3D(Basis(), Vector3(0, deck_y + 0.3, 0)), true])


## Crumbling stone walls around an old foundation, with a chest in the middle.
func _build_ruin(xform: Transform3D) -> void:
	var body := _new_body("Ruin", xform)
	var material := _stone_material(Color(0.5, 0.48, 0.44))
	var half := 6.0
	for side in 4:
		var side_basis := Basis(Vector3.UP, side * PI * 0.5)
		# Each side is a run of wall chunks with random heights and gaps.
		var x := -half
		while x < half - 0.1:
			var length := minf(rng.randf_range(1.0, 3.0), half - x)
			if rng.randf() > 0.25:  # 25% gaps
				var height := rng.randf_range(0.8, 3.8)
				var center := side_basis * Vector3(x + length * 0.5, height * 0.5 - 0.3, half)
				_add_box(body, Vector3(length, height, 0.6), Transform3D(side_basis, center), material)
			x += length
	for i in 5:  # rubble
		var s := rng.randf_range(0.4, 1.0)
		var p := Vector3(rng.randf_range(-half, half), s * 0.3, rng.randf_range(-half, half))
		_add_box(body, Vector3(s, s * 0.6, s * 1.2), Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p), material)
	add_child(body)
	_chest_spots.append([xform, false])


## A walled compound with corner blocks, a gate facing the middle of the map, a
## keep (tower) in the center, and guards in the yard.
func _build_fort(xform: Transform3D, crowd: int) -> void:
	var body := _new_body("Fort", xform)
	var stone := _stone_material(_biome.rock.lerp(Color(0.45, 0.44, 0.42), 0.5))
	var half := 16.0
	var wall_h := 4.5
	for side in 4:
		var side_basis := Basis(Vector3.UP, side * PI * 0.5)
		if side == 0:  # +Z: the gate
			for x in [-half * 0.5 - 1.25, half * 0.5 + 1.25]:
				_add_box(body, Vector3(half - 2.5, wall_h, 1.0), Transform3D(side_basis, side_basis * Vector3(x, wall_h * 0.5 - 0.3, half)), stone)
			_add_box(body, Vector3(5.0, 1.2, 1.0), Transform3D(side_basis, side_basis * Vector3(0, wall_h - 0.9, half)), stone)  # lintel
		else:
			_add_box(body, Vector3(half * 2.0, wall_h, 1.0), Transform3D(side_basis, side_basis * Vector3(0, wall_h * 0.5 - 0.3, half)), stone)
		_add_box(body, Vector3(3.0, wall_h + 1.5, 3.0), Transform3D(side_basis, side_basis * Vector3(half, (wall_h + 1.5) * 0.5 - 0.3, half)), stone)
		# Pathfinding: the walls block (leaving the gate), with little extra clearance
		# so the yard stays reachable; titans are kept out by the gate's width.
		var wall_xform := xform * Transform3D(side_basis, side_basis * Vector3(0, 0, half))
		if side == 0:
			for x in [-half * 0.5 - 1.25, half * 0.5 + 1.25]:
				nav.block_rect(wall_xform * Transform3D(Basis(), Vector3(x, 0, 0)), (half - 2.5) * 0.5, 0.8, 2.0)
		else:
			nav.block_rect(wall_xform, half + 1.5, 0.8, 2.0)
	add_child(body)

	var keep := _tower(xform, rng.randi_range(3, 4))
	_chest_spots.append([keep.global_transform * Transform3D(Basis(), Vector3(2.2, keep.floors * keep.floor_height, 1.5)), true])

	var guards := Node3D.new()
	guards.name = "FortGuards"
	guards.set_script(ENEMY_SPAWNER)
	guards.enemy_scenes = _enemy_mix(true)
	guards.max_alive = 3 + crowd
	guards.respawn_delay = 90.0
	guards.min_player_distance = 0.0
	guards.level = _level
	for corner in [Vector3(-9, 0.2, -9), Vector3(9, 0.2, -9), Vector3(-9, 0.2, 9), Vector3(9, 0.2, 9)]:
		guards.add_child(_marker(xform * corner))
	add_child(guards)


## A raised walkway with a ramp at each end and a chest in the middle.
func _build_bridge(xform: Transform3D, length: float, height: float) -> void:
	var body := _new_body("Bridge", xform)
	var stone := _stone_material(Color(0.42, 0.4, 0.38))
	_add_box(body, Vector3(length, 0.4, 4.0), Transform3D(Basis(), Vector3(0, height - 0.2, 0)), stone)
	for z in [-1.9, 1.9]:  # low rails
		_add_box(body, Vector3(length, 0.7, 0.2), Transform3D(Basis(), Vector3(0, height + 0.35, z)), stone)
	for x in [-length * 0.5 + 1.0, 0.0, length * 0.5 - 1.0]:  # pillars
		_add_box(body, Vector3(1.0, height + 1.0, 1.0), Transform3D(Basis(), Vector3(x, height * 0.5 - 0.7, 0)), stone)
	var run := 9.0
	var angle := atan2(height, run)
	var ramp := Vector3(sqrt(height * height + run * run), 0.3, 4.0)
	for end in [-1.0, 1.0]:
		# Rotated about Z so the ramp runs from the deck's end down to the ground.
		var tilt := Basis(Vector3.BACK, -angle * end)
		var center := Vector3(end * (length * 0.5 + run * 0.5), height * 0.5 - 0.15 / cos(angle), 0)
		_add_box(body, ramp, Transform3D(tilt, center), stone)
	add_child(body)
	_chest_spots.append([xform * Transform3D(Basis(), Vector3(0, height, 0)), false])


## Standing stones in a ring around a chest.
func _build_stone_circle(xform: Transform3D, radius: float) -> void:
	var body := _new_body("StoneCircle", xform)
	var stone := _stone_material(_biome.rock.darkened(0.1))
	var count := rng.randi_range(7, 11)
	for i in count:
		var angle := i * TAU / count
		var height := rng.randf_range(2.8, 5.0)
		var at := Vector3(cos(angle) * radius, height * 0.5 - 0.4, sin(angle) * radius)
		_add_box(body, Vector3(1.3, height, 0.8), Transform3D(Basis(Vector3.UP, -angle + PI * 0.5), at), stone)
	add_child(body)
	_chest_spots.append([xform, rng.randf() < 0.3])


## A floating rock (an upside-down cone with a ground-colored cap), a chest on
## top, and a launch pad on the ground beside it strong enough to reach it.
func _build_island(site: Dictionary) -> void:
	var pos: Vector2 = site.pos
	var radius: float = site.radius
	var top := height_at(pos.x, pos.y) + float(site.altitude)
	var body := _new_body("Island", Transform3D(Basis(Vector3.UP, site.yaw), Vector3(pos.x, top, pos.y)))

	var rock := StandardMaterial3D.new()
	rock.albedo_color = _biome.rock
	rock.roughness = 1.0
	var cone := CylinderMesh.new()
	cone.top_radius = radius
	cone.bottom_radius = radius * 0.2
	cone.height = radius * 1.2
	cone.radial_segments = 10
	_add_mesh(body, cone, Transform3D(Basis(), Vector3(0, -cone.height * 0.5, 0)), rock, true)

	var cap_material := StandardMaterial3D.new()
	cap_material.albedo_color = _biome.ground_a
	cap_material.roughness = 1.0
	var cap := CylinderMesh.new()
	cap.top_radius = radius * 0.98
	cap.bottom_radius = radius * 0.98
	cap.height = 0.2
	cap.radial_segments = 10
	_add_mesh(body, cap, Transform3D(Basis(), Vector3(0, -0.08, 0)), cap_material, false)
	add_child(body)
	_chest_spots.append([Transform3D(Basis(Vector3.UP, site.yaw), Vector3(pos.x, top + 0.02, pos.y)), radius > 7.0])

	var pad_pos: Vector2 = site.pad
	var pad: Node3D = JUMP_PAD.instantiate()
	pad.name = "LaunchPad_%d" % get_child_count()
	pad.position = Vector3(pad_pos.x, height_at(pad_pos.x, pad_pos.y), pad_pos.y)
	# A fixed arc that lands in the middle of the island: long enough in the air
	# to rise well above the rim before coming down on top.
	var rise: float = top + 0.5 - pad.position.y
	var flight := sqrt(2.0 * rise / GRAVITY) * 1.9
	var arc := Vector3(pos.x - pad_pos.x, 0.0, pos.y - pad_pos.y) / flight
	arc.y = (rise + 0.5 * GRAVITY * flight * flight) / flight
	pad.launch_velocity = arc
	pad.max_health = 100000.0  # part of the world, not something to shoot down
	add_child(pad)


## Stone arches cut into the mountain shoulders. Walk up to the one onward and
## press E to travel; the one you came through is blocked with rubble.
func _place_tunnels() -> void:
	for t in _tunnels:
		var mouth: Vector2 = t.mouth
		var side: Vector2 = t.side
		var at := Vector3(mouth.x, height_at(mouth.x - side.x * 3.0, mouth.y - side.y * 3.0), mouth.y)
		var tunnel := Node3D.new()
		tunnel.name = "Tunnel_%s" % ("Forward" if t.step > 0 else "Back")
		# Local +Z faces the middle of the map; the tunnel runs off toward -Z.
		tunnel.transform = Transform3D(Basis(Vector3.UP, atan2(-side.x, -side.y)), at)
		var body := StaticBody3D.new()
		tunnel.add_child(body)
		var stone := _stone_material(_biome.rock.darkened(0.15))
		_add_box(body, Vector3(1.6, 7.0, 5.0), Transform3D(Basis(), Vector3(-2.6, 3.0, -1.0)), stone)
		_add_box(body, Vector3(1.6, 7.0, 5.0), Transform3D(Basis(), Vector3(2.6, 3.0, -1.0)), stone)
		_add_box(body, Vector3(6.8, 1.6, 5.0), Transform3D(Basis(), Vector3(0.0, 6.3, -1.0)), stone)
		_add_box(body, Vector3(6.0, 7.0, 0.6), Transform3D(Basis(), Vector3(0.0, 3.0, -3.6)), stone)  # back wall
		for x in [-6.5, 6.5]:  # rock shoulders blending into the slope
			_add_box(body, Vector3(6.0, 9.0, 7.0), Transform3D(Basis(Vector3.UP, rng.randf_range(-0.3, 0.3)), Vector3(x, 3.0, -2.5)), stone)

		var dark := StandardMaterial3D.new()
		dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dark.albedo_color = Color(0.02, 0.02, 0.025)
		var void_mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(3.6, 5.4, 0.1)
		void_mesh.mesh = box
		void_mesh.material_override = dark
		void_mesh.position = Vector3(0.0, 2.7, -3.2)
		tunnel.add_child(void_mesh)

		if t.step < 0:
			# Caved in: boulders fill the mouth, and there's nothing to interact with.
			var rubble := _stone_material(_biome.rock.darkened(0.3))
			for boulder: Array in [[Vector3(-1.0, 0.9, -2.2), 2.2], [Vector3(1.0, 0.8, -2.4), 2.0], [Vector3(0.1, 2.3, -2.6), 2.3],
					[Vector3(-0.9, 3.7, -2.9), 1.9], [Vector3(1.0, 3.6, -2.8), 2.0], [Vector3(0.0, 4.9, -3.0), 1.7], [Vector3(0.3, 0.5, -1.2), 1.2]]:
				var tilt := Basis.from_euler(Vector3(rng.randf_range(-0.5, 0.5), rng.randf() * TAU, rng.randf_range(-0.5, 0.5)))
				_add_box(body, Vector3.ONE * boulder[1], Transform3D(tilt, boulder[0]), rubble)
			add_child(tunnel)
			continue

		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.7, 0.4)
		lamp.light_energy = 1.5
		lamp.omni_range = 7.0
		lamp.position = Vector3(0.0, 4.5, 0.8)
		tunnel.add_child(lamp)

		var mouth_area: StaticBody3D = TUNNEL.new()
		mouth_area.collision_layer = 4  # interactable, not solid
		mouth_area.collision_mask = 0
		mouth_area.generator = self
		mouth_area.step = t.step
		var shape := CollisionShape3D.new()
		var mouth_box := BoxShape3D.new()
		mouth_box.size = Vector3(3.6, 5.0, 1.5)
		shape.shape = mouth_box
		shape.position = Vector3(0.0, 2.5, -1.5)
		mouth_area.add_child(shape)
		tunnel.add_child(mouth_area)
		add_child(tunnel)


# --- Scenery ------------------------------------------------------------------

## Rock spires and giant arches: more, taller and stranger with the level.
## Some spires hide a chest on top (bring a grapple, rockets, or a building gun).
func _scatter_scenery() -> void:
	var scenery := _new_body("Scenery", Transform3D())
	var rock := StandardMaterial3D.new()
	rock.albedo_color = _biome.rock.darkened(0.08)
	rock.roughness = 1.0

	var spires := roundi((1.0 + 16.0 * _wild) * _area * rng.randf_range(0.5, 1.2))
	for i in spires:
		var p := _find_spot(play_radius - 10.0, 5.0, 20.0)
		if not p.is_finite():
			continue
		_reserve(p, 4.0)
		var height := rng.randf_range(8.0, 14.0 + 22.0 * _wild)
		var top_radius := rng.randf_range(1.4, 3.0)
		var spire := CylinderMesh.new()
		spire.top_radius = top_radius
		spire.bottom_radius = top_radius * rng.randf_range(1.3, 2.0)
		spire.height = height + 3.0  # sunk 3 m so slopes don't expose its base
		spire.radial_segments = 7
		var ground := height_at(p.x, p.y)
		var tilt := Basis(Vector3.UP, rng.randf() * TAU)
		_add_mesh(scenery, spire, Transform3D(tilt, Vector3(p.x, ground + height * 0.5 - 1.5, p.y)), rock, true)
		nav.block_circle(Vector3(p.x, ground, p.y), spire.bottom_radius)
		if _level >= 2 and rng.randf() < 0.2:
			_chest_spots.append([Transform3D(tilt, Vector3(p.x, ground + height, p.y)), false])

	if _level >= 2:
		var stone := _stone_material(_biome.rock.darkened(0.12))
		for i in rng.randi_range(0, 1 + int(3.0 * _wild)):
			var p := _find_spot(play_radius - 20.0, 13.0, 25.0)
			if not p.is_finite():
				continue
			_reserve(p, 4.0)  # only the legs block things; you can walk under it
			var span := rng.randf_range(12.0, 20.0)
			var height := rng.randf_range(9.0, 16.0)
			var xform := Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(p.x, height_at(p.x, p.y), p.y))
			for x in [-span * 0.5, span * 0.5]:
				_add_box(scenery, Vector3(3.0, height + 4.0, 3.5), xform * Transform3D(Basis(), Vector3(x, height * 0.5 - 2.0, 0)), stone)
				nav.block_rect(xform * Transform3D(Basis(), Vector3(x, 0, 0)), 1.5, 1.75, 2.0)
			_add_box(scenery, Vector3(span + 5.0, 2.5, 4.0), xform * Transform3D(Basis(), Vector3(0, height + 1.25, 0)), stone)
	add_child(scenery)


func _scatter_trees() -> void:
	var nature := Node3D.new()
	nature.name = "Nature"
	add_child(nature)
	var limit := play_radius - 4.0
	var leaves := StandardMaterial3D.new()
	leaves.albedo_color = _biome.leaf_color
	leaves.roughness = 0.9

	# Dense where the forest noise is high, the odd lone one elsewhere.
	for attempt in mini(roundi(tree_attempts * _area), 1800):
		var p := Vector2(rng.randf_range(-limit, limit), rng.randf_range(-limit, limit))
		var density := _forest.get_noise_2d(p.x, p.y)
		if density < _biome.forest_threshold and rng.randf() > 0.04:
			continue
		if slope_at(p.x, p.y) > 0.6 or not _is_free(p, 2.5):
			continue
		_reserve(p, 1.2)
		var tree: Node3D = _biome.tree_scene.instantiate()
		tree.transform = Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(p.x, height_at(p.x, p.y) - 0.1, p.y))
		nature.add_child(tree)
		var leaf_mesh := tree.get_node_or_null("Visual/Leaves") as MeshInstance3D
		if leaf_mesh:
			leaf_mesh.material_override = leaves


# --- Spawn points -------------------------------------------------------------

func _place_spawners() -> void:
	var limit := play_radius - 8.0

	var roamers := Node3D.new()
	roamers.name = "RoamingEnemies"
	roamers.set_script(ENEMY_SPAWNER)
	roamers.enemy_scenes = _enemy_mix(true)
	roamers.max_alive = roundi(max_roaming_enemies * _area) + 3 * (_level - 1)
	roamers.min_player_distance = 40.0
	roamers.level = _level
	for i in roundi(enemy_spawn_points * _area):
		var p := _find_spot(limit, 3.0, 50.0)
		if p.is_finite() and slope_at(p.x, p.y) < 0.6:
			roamers.add_child(_marker(Vector3(p.x, height_at(p.x, p.y) + 0.2, p.y)))
	add_child(roamers)

	# The region's bosses: they stay dead once killed, and killing them all opens
	# the tunnel onward. A cleared region has none. Titans every region (more as
	# you go); a dragon from level 2, two from level 6.
	_bosses_left.clear()
	if not cleared_regions.has(region_index):
		_bosses_left["Titan"] = 1 + floori((_level - 1) / 2.0)
		if _level >= 2:
			_bosses_left["Dragon"] = 2 if _level >= 6 else 1

	# Titans can turn up anywhere in the region: spawn points scattered across it,
	# on open ground with room for them (the spawner picks ones away from you).
	var titans := _boss_spawner("Titan", TITAN)
	var tries := 0
	while titans.get_child_count() < 10 and tries < 200:
		tries += 1
		var p := _find_spot(limit, 4.0, 30.0)
		if p.is_finite() and slope_at(p.x, p.y) < 0.5 and nav.is_open(Vector3(p.x, 0.0, p.y), true):
			titans.add_child(_marker(Vector3(p.x, height_at(p.x, p.y) + 0.5, p.y)))
	if titans.get_child_count() == 0:  # nowhere roomy: fall back to the corners
		for corner in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var p: Vector2 = corner * (play_radius - 8.0)
			titans.add_child(_marker(Vector3(p.x, height_at(p.x, p.y) + 0.5, p.y)))
	add_child(titans)

	# Dragons fly, so anywhere at all will do.
	if _bosses_left.has("Dragon"):
		var dragons := _boss_spawner("Dragon", DRAGON)
		for i in 6:
			var p := _find_spot(limit, 3.0, 40.0)
			if p.is_finite():
				dragons.add_child(_marker(Vector3(p.x, height_at(p.x, p.y) + 1.0, p.y)))
		if dragons.get_child_count() == 0:
			dragons.add_child(_marker(Vector3(0.0, height_at(0.0, 0.0) + 1.0, 0.0)))
		add_child(dragons)


## A spawner for one kind of boss: as many as the region needs, never respawned
## once killed (ones lost some other way, like falling out of the world, return).
func _boss_spawner(kind: String, scene: PackedScene) -> Node3D:
	var spawner := Node3D.new()
	spawner.name = kind + "s"
	spawner.set_script(ENEMY_SPAWNER)
	var scenes: Array[PackedScene] = [scene]
	spawner.enemy_scenes = scenes
	spawner.max_alive = _bosses_left.get(kind, 0)
	spawner.respawn_killed = false
	spawner.enemy_died.connect(_on_boss_died.bind(kind))
	spawner.respawn_delay = 20.0
	spawner.min_player_distance = 50.0
	spawner.level = _level
	return spawner


# --- Boss gate ----------------------------------------------------------------

## There's no going back: only onward, once the region's bosses are dead.
func can_travel(step: int) -> bool:
	return step > 0 and cleared_regions.has(region_index)


## What a tunnel mouth says when you look at it.
func tunnel_prompt(step: int) -> String:
	if not can_travel(step):
		return "Sealed: defeat %s first" % _bosses_text()
	return "Travel onward to " + region_title(region_index + step)


func _objective_text() -> String:
	if cleared_regions.has(region_index):
		return "The tunnel onward is open"
	return "Objective: defeat %s to open the tunnel onward" % _bosses_text()


## "the Titan", "2 Titans and the Dragon", ...
func _bosses_text() -> String:
	var parts := PackedStringArray()
	for kind: String in _bosses_left:
		var count: int = _bosses_left[kind]
		if count == 1:
			parts.append("the " + kind)
		elif count > 1:
			parts.append("%d %ss" % [count, kind])
	return " and ".join(parts)


func _on_boss_died(killed_by_player: bool, kind: String) -> void:
	if not killed_by_player:
		return  # it will respawn; the fight still has to be won
	_bosses_left[kind] = maxi(_bosses_left.get(kind, 0) - 1, 0)
	var left := 0
	for count: int in _bosses_left.values():
		left += count
	var player := _player()
	if left <= 0:
		cleared_regions[region_index] = true
		if player:
			player.notify("%s defeated! The tunnel onward is open." % kind)
	elif player:
		player.notify("%s defeated! %d boss%s left." % [kind, left, "" if left == 1 else "es"])
	if player:
		player.set_objective(_objective_text())


# --- Treasure chests ----------------------------------------------------------

## One chest per spot the structures registered, plus a few out in the open.
## Ids are assigned in placement order, which is the same every time a region
## generates, so opened ones can be remembered.
func _place_chests() -> void:
	_chest_count = 0
	for spot in _chest_spots:
		_add_chest(spot[0], spot[1])
	for i in roundi(wild_chest_count * _area):
		var p := _find_spot(play_radius - 10.0, 3.0, 25.0)
		if p.is_finite():
			_reserve(p, 2.0)
			_add_chest(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(p.x, height_at(p.x, p.y), p.y)), false)


func _add_chest(xform: Transform3D, grand: bool) -> void:
	var id := _chest_count
	_chest_count += 1
	var chest: Chest = CHEST.instantiate()
	chest.name = "Chest_%d" % id
	chest.transform = xform
	# Cost and reward grow together (+50% per level), and a grand chest is simply
	# two upgrades for twice the price: every coin buys the same anywhere.
	chest.rolls = 2 if grand else 1
	chest.power = 1.0 + 0.5 * (_level - 1)
	chest.cost = roundi(chest_cost * chest.power * chest.rolls)
	chest.is_open = opened_chests.get(region_index, {}).has(id)
	chest.opened.connect(func() -> void:
		if not opened_chests.has(region_index):
			opened_chests[region_index] = {}
		opened_chests[region_index][id] = true)
	add_child(chest)


# --- Geometry helpers ---------------------------------------------------------

func _new_body(base_name: String, xform: Transform3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "%s_%d" % [base_name, get_child_count()]
	body.transform = xform
	return body


func _add_box(body: StaticBody3D, box_size: Vector3, xform: Transform3D, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = box_size
	var shape := BoxShape3D.new()
	shape.size = box_size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.transform = xform
	body.add_child(collision)
	_add_mesh(body, mesh, xform, material, false)


## Adds a mesh to a body, optionally with a convex collision hull made from it.
func _add_mesh(body: StaticBody3D, mesh: Mesh, xform: Transform3D, material: Material, solid: bool) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.transform = xform
	body.add_child(instance)
	if solid:
		var collision := CollisionShape3D.new()
		collision.shape = mesh.create_convex_shape()
		collision.transform = xform
		body.add_child(collision)


func _stone_material(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GRID_SHADER
	material.set_shader_parameter(&"color_a", color)
	material.set_shader_parameter(&"color_b", color.darkened(0.04))
	material.set_shader_parameter(&"cell_size", 0.75)
	return material


func _marker(at: Vector3) -> Marker3D:
	var marker := Marker3D.new()
	marker.position = at
	return marker

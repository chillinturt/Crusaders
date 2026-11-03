class_name Biome
extends Resource
## Look and feel of a region: ground colors, vegetation, sky and fog, and how
## hilly it is. One .tres per biome in world/biomes/; the world generator picks one
## per region.

@export var display_name := "Grasslands"

@export_group("Ground")
@export var ground_a := Color(0.29, 0.41, 0.19)
@export var ground_b := Color(0.42, 0.45, 0.24)
## Bare ground around buildings and ruins.
@export var dirt := Color(0.43, 0.35, 0.25)
## Steep slopes.
@export var rock := Color(0.44, 0.42, 0.4)
## High ground and mountains (rock, or snow).
@export var peak := Color(0.44, 0.42, 0.4)
@export var hill_height := 9.0

@export_group("Vegetation")
## Scenery "tree" for this biome (pines, cacti...).
@export var tree_scene: PackedScene
## Leaf color applied to tree scenes that have a Visual/Leaves mesh.
@export var leaf_color := Color(0.16, 0.38, 0.17)
## Higher = sparser forests (forest noise must exceed this). Grasslands ~0.12.
@export var forest_threshold := 0.12

@export_group("Atmosphere")
@export var sky_top := Color(0.32, 0.47, 0.68)
@export var sky_horizon := Color(0.68, 0.72, 0.76)
@export var fog_color := Color(0.66, 0.71, 0.76)
@export var fog_density := 0.0025
@export var sun_color := Color(1.0, 0.96, 0.88)

@export_group("Buildings")
## Wall colors are random within this hue range (0..1) at this saturation/value.
@export var wall_hue := Vector2(0.03, 0.12)
@export var wall_saturation := 0.22
@export var wall_value := 0.58

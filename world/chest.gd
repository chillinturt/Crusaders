class_name Chest
extends StaticBody3D
## A treasure chest: press E and pay its cost in coins for random permanent
## upgrades (see player/upgrades.gd). Stays open once opened.

signal opened

@export var cost := 40
## Upgrades granted. Grand chests (2+) are bigger and glow purple.
@export var rolls := 1
## How strong each upgrade is (in stacks). The world generator raises this in
## step with the cost, so later regions' chests are the same value per coin.
@export var power := 1.0

var is_open := false

@onready var _visual: Node3D = $Visual
@onready var _lid: Node3D = $Visual/LidPivot
@onready var _glow: OmniLight3D = $Visual/Glow
@onready var _band: MeshInstance3D = $Visual/Band


func _ready() -> void:
	add_to_group(&"chests")  # for the minimap
	if rolls > 1:
		_visual.scale = Vector3.ONE * 1.3
		_glow.light_color = Color(0.75, 0.4, 1.0)
		var material := (_band.get_surface_override_material(0) as StandardMaterial3D).duplicate()
		material.albedo_color = Color(0.7, 0.4, 1.0)
		material.emission = Color(0.7, 0.4, 1.0)
		_band.set_surface_override_material(0, material)
	if is_open:
		_show_open()


func get_interact_prompt(_by: Node) -> String:
	if is_open:
		return ""
	var reward := "%d upgrades" % rolls if rolls > 1 else "1 upgrade"
	if not is_equal_approx(power, 1.0):
		reward += ", x%s strength" % String.num(power, 1)
	return "Open %s (%d coins: %s)" % ["grand chest" if rolls > 1 else "chest", cost, reward]


func interact(by: Node) -> void:
	if is_open:
		return
	if not by.spend_coins(cost):
		by.notify("Need %d coins (you have %d)" % [cost, by.coins])
		return
	for i in rolls:
		var id: StringName = by.upgrades.grant_random(power)
		by.notify("Upgrade! " + by.upgrades.describe_gain(id, power))
	is_open = true
	var tween := create_tween()
	tween.tween_property(_lid, "rotation:x", -1.9, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_show_open)
	opened.emit()


func _show_open() -> void:
	_lid.rotation.x = -1.9
	_glow.visible = false

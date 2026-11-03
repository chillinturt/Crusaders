extends Control
## The Tab menu: your skills (levels, progress and what they currently give you)
## and your loadout. Built in code.

var player: Node
var _list: VBoxContainer


func setup(p_player: Node) -> void:
	player = p_player
	_build()
	player.skills.leveled_up.connect(func(_skill: StringName, _level: int) -> void: _refresh())
	visibility_changed.connect(func() -> void: if visible: _refresh())


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	margin.add_child(_list)


func _refresh() -> void:
	if not visible:
		return
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var skills: Skills = player.skills
	_list.add_child(_label("Skills", 28))
	for id: StringName in Skills.SKILLS:
		var lvl := skills.level(id)
		if lvl >= Skills.MAX_LEVEL:
			_list.add_child(_label("%s  level %d (max)" % [Skills.SKILLS[id], lvl], 22))
		else:
			_list.add_child(_label("%s  level %d   (%d / %d XP)" % [Skills.SKILLS[id], lvl, skills.xp(id), Skills.xp_for_level(lvl + 1)], 22))
		var bar := ProgressBar.new()
		bar.max_value = 1.0
		bar.value = skills.progress(id)
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 10)
		_list.add_child(bar)
		_list.add_child(_label(Skills.DESCRIPTIONS[id], 16, 0.55))

	_list.add_child(_label("Max health %d  ·  Max stamina %d  ·  Stamina regen %.0f/s  ·  Melee damage +%d%%  ·  Swing speed +%d%%  ·  Gun damage +%d%%  ·  Spread -%d%%  ·  Reload speed +%d%%" % [
		player.max_health, player.vitals.max_stamina(), player.vitals.stamina_regen(),
		roundi((skills.melee_damage_multiplier() - 1.0) * 100.0), roundi((skills.swing_speed_multiplier() - 1.0) * 100.0),
		roundi((skills.aim_damage_multiplier() - 1.0) * 100.0), roundi((1.0 - skills.aim_spread_multiplier()) * 100.0),
		roundi((skills.reload_speed_multiplier() - 1.0) * 100.0)], 16))
	_list.add_child(_label("Blast damage +%d%%  ·  Blast radius +%d%%  ·  Blast knockback +%d%%  ·  Own-blast damage -%d%%  ·  Portal range +%d%%" % [
		roundi((skills.blast_damage_multiplier() - 1.0) * 100.0), roundi((skills.blast_radius_multiplier() - 1.0) * 100.0),
		roundi((skills.blast_force_multiplier() - 1.0) * 100.0), roundi((1.0 - skills.blast_self_damage_multiplier()) * 100.0),
		roundi((skills.portal_range_multiplier() - 1.0) * 100.0)], 16))

	_list.add_child(_label("Upgrades  (%d coins)" % player.coins, 28))
	var any_upgrade := false
	for id: StringName in Upgrades.DEFS:
		if player.upgrades.count(id) > 0:
			_list.add_child(_label(player.upgrades.describe(id), 18))
			any_upgrade = true
	if not any_upgrade:
		_list.add_child(_label("None yet. Spend coins from kills on treasure chests.", 16, 0.55))

	_list.add_child(_label("Loadout", 28))
	for line: String in player.loadout_summary():
		_list.add_child(_label(line, 18))
	_list.add_child(_label("Tab: close", 16, 0.5))


func _label(text: String, font_size: int, alpha := 1.0) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.modulate = Color(1, 1, 1, alpha)
	return label

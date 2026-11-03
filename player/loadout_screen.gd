extends Control
## The loadout screen shown at the start of the game (the game is paused behind
## it): pick one Primary, Secondary, Utility and Melee, then Start.
## Options are any nodes with display_name and description (weapons, the grapple).

signal confirmed(choices: Array[Node])

const SLOT_TITLES: PackedStringArray = ["Primary", "Secondary", "Utility", "Melee"]

var _options: Array = []            # per slot: Array of option nodes
var _choices: Array[Node] = []
var _descriptions: Array[Label] = []


## options[slot] is the list of choices for that slot; the first is preselected.
func setup(options: Array) -> void:
	_options = options
	process_mode = Node.PROCESS_MODE_ALWAYS  # must work while the game is paused
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.07, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 18)
	center.add_child(root)

	var title := Label.new()
	title.text = "Choose your loadout"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	root.add_child(title)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20)
	root.add_child(columns)
	for slot in options.size():
		columns.add_child(_build_column(slot))

	var start := Button.new()
	start.text = "Start"
	start.custom_minimum_size = Vector2(220, 52)
	start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	start.add_theme_font_size_override("font_size", 24)
	start.pressed.connect(confirm)
	root.add_child(start)

	var hint := Label.new()
	hint.text = "Unlimited ammo, but guns must reload (R). Keys 1-4 switch weapons in play."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.55)
	root.add_child(hint)


func choose(slot: int, option: Node) -> void:
	_choices[slot] = option
	_descriptions[slot].text = option.description


func confirm() -> void:
	confirmed.emit(_choices)


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_accept"):
		confirm()


func _build_column(slot: int) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(250, 0)
	column.add_theme_constant_override("separation", 6)

	var heading := Label.new()
	heading.text = SLOT_TITLES[slot]
	heading.add_theme_font_size_override("font_size", 24)
	column.add_child(heading)

	var description := Label.new()
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.custom_minimum_size = Vector2(250, 110)
	description.modulate = Color(1, 1, 1, 0.75)
	_descriptions.append(description)
	_choices.append(null)

	var group := ButtonGroup.new()
	for option: Node in _options[slot]:
		var button := Button.new()
		button.text = option.display_name
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(0, 40)
		button.pressed.connect(choose.bind(slot, option))
		column.add_child(button)
		if _choices[slot] == null:
			button.button_pressed = true
			choose(slot, option)
	column.add_child(description)
	return column

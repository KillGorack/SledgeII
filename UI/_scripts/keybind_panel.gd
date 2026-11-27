extends MarginContainer

# Settings > Inputs: every key the game and the builder answer to, from Keybinds.REGISTRY. Click a key, then press
# the new one - with Ctrl / Alt / Shift held for a combination, or tap a modifier on its own to bind it by itself
# (fine aim is Shift). Esc cancels. Edits go straight into the InputMap through Keybinds, so they are live in the
# match and the builder as soon as you play.

const KEY_COLOR := Color(1.0, 0.8, 0.3)
const WARN_COLOR := Color(0.85, 0.47, 0.51)

var _rows: Dictionary = {} # action -> {"button": Button, "note": Label, "reset": Button}
var _listening: String = ""
var _held_modifier: Key = KEY_NONE # a modifier pressed with nothing else yet: it may turn out to be the binding


func _ready() -> void:
	for child in get_children():
		child.queue_free()
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	scroll.add_child(column)

	var top := HBoxContainer.new()
	var hint := Label.new()
	hint.text = "Click a key, then press the new one. Hold Ctrl / Alt / Shift for a combination; tap a modifier alone to use it by itself. Esc cancels."
	hint.theme_type_variation = &"DimLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(hint)
	var reset_all := Button.new()
	reset_all.text = "RESET ALL"
	reset_all.focus_mode = Control.FOCUS_NONE
	reset_all.pressed.connect(func() -> void:
		_stop_listening()
		Keybinds.reset_all())
	top.add_child(reset_all)
	column.add_child(top)

	for group in Keybinds.REGISTRY:
		var heading := Label.new()
		heading.text = group[0].to_upper()
		heading.add_theme_color_override("font_color", KEY_COLOR)
		column.add_child(heading)
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 4)
		column.add_child(grid)
		for row in group[2]:
			_add_row(grid, row[0], row[1])

	Keybinds.bindings_changed.connect(_refresh)
	_refresh()
	set_process_input(false)


func _add_row(grid: GridContainer, action: String, label_text: String) -> void:
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(300, 0)
	grid.add_child(label)
	var button := Button.new()
	button.custom_minimum_size = Vector2(200, 0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_start_listening.bind(action))
	grid.add_child(button)
	var buttons := HBoxContainer.new()
	var clear := Button.new()
	clear.text = "CLEAR"
	clear.focus_mode = Control.FOCUS_NONE
	clear.pressed.connect(func() -> void:
		_stop_listening()
		Keybinds.unbind(action))
	buttons.add_child(clear)
	var reset := Button.new()
	reset.text = "RESET"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(func() -> void:
		_stop_listening()
		Keybinds.reset(action))
	buttons.add_child(reset)
	grid.add_child(buttons)
	var note := Label.new()
	note.add_theme_color_override("font_color", WARN_COLOR)
	grid.add_child(note)
	_rows[action] = {"button": button, "note": note, "reset": reset}


func _refresh() -> void:
	for action in _rows:
		var row: Dictionary = _rows[action]
		var button: Button = row.button
		button.text = "Press a key..." if action == _listening else Keybinds.key_text(action)
		button.add_theme_color_override("font_color", KEY_COLOR if action == _listening else Color.WHITE)
		(row.reset as Button).disabled = Keybinds.is_default(action)
		var clashes := Keybinds.conflicts(action)
		var names: PackedStringArray = []
		for other in clashes:
			names.append(_label_of(other))
		(row.note as Label).text = "Also used by: " + ", ".join(names) if not clashes.is_empty() else ""


func _label_of(action: String) -> String:
	for group in Keybinds.REGISTRY:
		for row in group[2]:
			if row[0] == action:
				return row[1]
	return action


func _start_listening(action: String) -> void:
	_listening = action
	_held_modifier = KEY_NONE
	set_process_input(true)
	_refresh()


func _stop_listening() -> void:
	_listening = ""
	_held_modifier = KEY_NONE
	set_process_input(false)
	_refresh()


func _exit_tree() -> void:
	if Keybinds.bindings_changed.is_connected(_refresh):
		Keybinds.bindings_changed.disconnect(_refresh)


func _input(event: InputEvent) -> void:
	if _listening == "" or not event is InputEventKey:
		return
	var key := event as InputEventKey
	if key.echo:
		return
	get_viewport().set_input_as_handled()
	var code: Key = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	var is_modifier: bool = code in Keybinds.MODIFIER_KEYS
	if key.pressed:
		if code == KEY_ESCAPE:
			_stop_listening()
		elif is_modifier:
			_held_modifier = code
			(_rows[_listening].button as Button).text = Keybinds.event_text(key) + "+..."
		else:
			_finish(key)
	elif is_modifier and code == _held_modifier:
		# Released without another key arriving: the modifier itself is the binding.
		_finish(key)


func _finish(key: InputEventKey) -> void:
	var action := _listening
	_stop_listening()
	Keybinds.rebind(action, key)

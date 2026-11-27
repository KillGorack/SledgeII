extends MarginContainer

# Settings > Sound: overall volume and mute-in-background, from AudioSettings. Applies at once, so drag the
# slider while the menu music plays to hear it.

const KEY_COLOR := Color(1.0, 0.8, 0.3)

var _slider: HSlider
var _value_label: Label
var _mute_check: CheckBox


func _ready() -> void:
	for child in get_children():
		child.queue_free()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)

	var heading := Label.new()
	heading.text = "VOLUME"
	heading.add_theme_color_override("font_color", KEY_COLOR)
	column.add_child(heading)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	column.add_child(row)
	var name_label := Label.new()
	name_label.text = "Master volume"
	name_label.custom_minimum_size = Vector2(260, 0)
	row.add_child(name_label)
	_slider = HSlider.new()
	_slider.max_value = 1.0
	_slider.step = 0.05
	_slider.custom_minimum_size = Vector2(260, 0)
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.value_changed.connect(func(v: float) -> void: AudioSettings.set_value("master", v))
	row.add_child(_slider)
	_value_label = Label.new()
	_value_label.custom_minimum_size = Vector2(60, 0)
	row.add_child(_value_label)

	_mute_check = CheckBox.new()
	_mute_check.text = "Mute when the game is in the background"
	_mute_check.focus_mode = Control.FOCUS_NONE
	_mute_check.toggled.connect(func(on: bool) -> void: AudioSettings.set_value("mute_in_background", on))
	column.add_child(_mute_check)

	var reset := Button.new()
	reset.text = "RESET ALL"
	reset.focus_mode = Control.FOCUS_NONE
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(AudioSettings.reset_all)
	column.add_child(reset)

	AudioSettings.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	_slider.set_value_no_signal(float(AudioSettings.values.master))
	_value_label.text = "%d%%" % roundi(float(AudioSettings.values.master) * 100.0)
	_mute_check.set_pressed_no_signal(bool(AudioSettings.values.mute_in_background))


func _exit_tree() -> void:
	if AudioSettings.changed.is_connected(_refresh):
		AudioSettings.changed.disconnect(_refresh)

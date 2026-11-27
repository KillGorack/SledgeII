extends MarginContainer

# Settings > Video: a drop-down per choice from VideoSettings, plus the 3D render scale. Each change applies at
# once (the menu has no 3D, so watch the window mode and frame limit; the rest shows in a match) and is saved.

const KEY_COLOR := Color(1.0, 0.8, 0.3)

var _pickers: Dictionary = {} # key -> OptionButton
var _scale_slider: HSlider
var _scale_label: Label


func _ready() -> void:
	for child in get_children():
		child.queue_free()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)

	_heading(column, "DISPLAY")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 6)
	column.add_child(grid)
	_picker(grid, "window_mode", "Window mode", VideoSettings.WINDOW_MODES)
	_picker(grid, "vsync", "Vertical sync", VideoSettings.VSYNC_MODES)
	_picker(grid, "fps_limit", "Frame rate limit", VideoSettings.FPS_LIMITS)

	_heading(column, "QUALITY")
	var quality := GridContainer.new()
	quality.columns = 2
	quality.add_theme_constant_override("h_separation", 20)
	quality.add_theme_constant_override("v_separation", 6)
	column.add_child(quality)
	_picker(quality, "msaa", "Anti-aliasing (MSAA)", VideoSettings.MSAA_MODES)
	_picker(quality, "screen_aa", "Anti-aliasing (screen space)", VideoSettings.SCREEN_AA_MODES)
	_picker(quality, "shadow_size", "Shadow resolution", VideoSettings.SHADOW_SIZES)
	_picker(quality, "shadow_softness", "Shadow edges", VideoSettings.SHADOW_SOFTNESS)
	var scale_name := Label.new()
	scale_name.text = "3D render scale"
	quality.add_child(scale_name)
	var scale_row := HBoxContainer.new()
	_scale_slider = HSlider.new()
	_scale_slider.min_value = 0.5
	_scale_slider.max_value = 1.0
	_scale_slider.step = 0.05
	_scale_slider.custom_minimum_size = Vector2(220, 0)
	_scale_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scale_slider.value_changed.connect(func(v: float) -> void: VideoSettings.set_value("render_scale", v))
	scale_row.add_child(_scale_slider)
	_scale_label = Label.new()
	_scale_label.custom_minimum_size = Vector2(60, 0)
	scale_row.add_child(_scale_label)
	quality.add_child(scale_row)

	var reset := Button.new()
	reset.text = "RESET ALL"
	reset.focus_mode = Control.FOCUS_NONE
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(VideoSettings.reset_all)
	column.add_child(reset)

	VideoSettings.changed.connect(_refresh)
	_refresh()


func _heading(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", KEY_COLOR)
	parent.add_child(label)


func _picker(grid: GridContainer, key: String, label_text: String, options: Array) -> void:
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(260, 0)
	grid.add_child(label)
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(220, 0)
	picker.focus_mode = Control.FOCUS_NONE
	for option in options:
		picker.add_item(option[0])
	picker.item_selected.connect(func(index: int) -> void: VideoSettings.set_value(key, index))
	grid.add_child(picker)
	_pickers[key] = picker


func _refresh() -> void:
	for key in _pickers:
		(_pickers[key] as OptionButton).select(int(VideoSettings.values[key]))
	_scale_slider.set_value_no_signal(float(VideoSettings.values.render_scale))
	_scale_label.text = "%d%%" % roundi(float(VideoSettings.values.render_scale) * 100.0)


func _exit_tree() -> void:
	if VideoSettings.changed.is_connected(_refresh):
		VideoSettings.changed.disconnect(_refresh)

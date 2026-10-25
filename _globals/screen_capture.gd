extends Node

# F12 (the screen_capture action) saves the whole window as a PNG to
# Documents/My Games/<game name>/Screen Captures. It is an autoload, so it works the same in
# the menus and in a match. A short on-screen note confirms each capture.

const TOAST_SECONDS := 2.5

var _toast_layer: CanvasLayer
var _toast_label: Label
var _toast_tween: Tween


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if Input.is_action_pressed("screen_capture"):
			take_screen_capture()


func take_screen_capture() -> void:
	var documents_dir := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var game_name: String = ProjectSettings.get_setting("application/config/name", "Game")
	var screenies_dir := "%s/My Games/%s/Screen Captures" % [documents_dir, game_name]
	# Creates every missing folder along the way (nothing happens if they exist). The older version
	# treated a successful folder creation as a failure and gave up, so a first capture did nothing.
	if DirAccess.make_dir_recursive_absolute(screenies_dir) != OK:
		_show_toast("Could not create the screenshot folder")
		return
	var now := Time.get_datetime_dict_from_system()
	var datetime_string := "%04d%02d%02d%02d%02d%02d" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	var file_path := "%s/%s Screen Capture %s.png" % [screenies_dir, game_name, datetime_string]
	var image := get_viewport().get_texture().get_image()
	if image == null or image.save_png(file_path) != OK:
		_show_toast("Screen capture failed")
		return
	print("Screen capture saved: ", file_path)
	_show_toast("Screen capture saved")


# A note in the corner, outside the captured image (it appears after the grab).
func _show_toast(text: String) -> void:
	if _toast_layer == null:
		_toast_layer = CanvasLayer.new()
		_toast_layer.layer = 200
		add_child(_toast_layer)
		_toast_label = Label.new()
		_toast_label.add_theme_font_size_override("font_size", 18)
		_toast_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		_toast_label.add_theme_constant_override("shadow_offset_x", 1)
		_toast_label.add_theme_constant_override("shadow_offset_y", 1)
		_toast_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 20)
		_toast_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_toast_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_toast_layer.add_child(_toast_label)
	_toast_label.text = text
	_toast_label.modulate = Color.WHITE
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(TOAST_SECONDS - 0.7)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.7)

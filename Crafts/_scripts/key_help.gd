extends CenterContainer

# F1 key reference for a match: every key the game answers to. Added to the owning peer's Hud_InGame by
# hud_controller.gd, like the player list. Never takes the mouse, so it can stay up while you play.
# The builder has its own F1 card (Creative/creative_editor.gd::_build_help).

const KEY_COLOR := Color(1.0, 0.8, 0.3)
const KEY_WIDTH := 150.0

const SECTIONS := [
	["Driving", [
		["Up / Down", "Drive forward / back"],
		["Left / Right", "Turn"],
		["R", "Rockets: thrust (when the host allows them)"],
		["", "An upside-down craft rights itself"]]],
	["Aiming and firing", [
		["W A S D", "Turn the turret / tilt the barrel"],
		["Shift", "Hold while aiming for fine aim"],
		["X", "Recentre the turret"],
		["Space", "Fire"],
		["Shift + Space", "Fire reversed: pulls where it would push"],
		["Tab", "Next weapon"]]],
	["Specials", [
		["Shift + Tab", "Next special (mines, Controller)"],
		["M", "Use it: lay a mine / call a base gun to you"],
		["Shift + M", "Blow your mines / send your base guns home"]]],
	["Match", [
		["F5", "Capture the recon station you are on"],
		["Z", "Radar zoom"],
		["/", "Chat"],
		["F4", "Player list"],
		["F12", "Screenshot"],
		["Alt + Q", "Leave to the main menu"],
		["F1", "Show / hide this help"]]],
]


func _ready() -> void:
	# Registered here rather than in project.godot's Input Map, same as the player list's F4.
	if not InputMap.has_action("show_help"):
		InputMap.add_action("show_help")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_F1
		InputMap.action_add_event("show_help", key)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.86)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(1.0, 0.8, 0.3, 0.35)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)
	for section in SECTIONS:
		var heading := Label.new()
		heading.text = section[0]
		heading.add_theme_font_size_override("font_size", 18)
		column.add_child(heading)
		for row in section[1]:
			var line := HBoxContainer.new()
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			line.add_theme_constant_override("separation", 16)
			var key_label := Label.new()
			key_label.text = row[0]
			key_label.custom_minimum_size = Vector2(KEY_WIDTH, 0)
			key_label.add_theme_color_override("font_color", KEY_COLOR)
			line.add_child(key_label)
			var what := Label.new()
			what.text = row[1]
			line.add_child(what)
			column.add_child(line)
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, 6)
		gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(gap)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("show_help"):
		visible = not visible
		get_viewport().set_input_as_handled()

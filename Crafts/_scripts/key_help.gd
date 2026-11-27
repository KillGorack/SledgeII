extends CenterContainer

# F1 key reference for a match: every key the game answers to. Added to the owning peer's Hud_InGame by
# hud_controller.gd, like the player list. Never takes the mouse, so it can stay up while you play.
# The builder has its own F1 card (Creative/creative_editor.gd::_build_help).

const KEY_COLOR := Color(1.0, 0.8, 0.3)
const KEY_WIDTH := 150.0

# A row's key is either text, or an array of actions whose current keys are shown (Keybinds, rebindable in
# Settings > Inputs).
const SECTIONS := [
	["Driving", [
		[["ui_up", "ui_down"], "Drive forward / back"],
		[["ui_left", "ui_right"], "Turn"],
		[["rockets"], "Rockets: thrust (when the host allows them)"],
		["", "An upside-down craft rights itself"]]],
	["Aiming and firing", [
		[["camera_left", "camera_up", "camera_right", "camera_down"], "Turn the turret / tilt the barrel"],
		[["ui_shift"], "Hold while aiming for fine aim"],
		[["ui_recenter"], "Recentre the turret"],
		[["fire_weapon"], "Fire"],
		[["reverso", "fire_weapon"], "Fire reversed: pulls where it would push", " + "],
		[["weapon_change"], "Next weapon"]]],
	["Specials", [
		[["change_specials"], "Next special (mines, Controller)"],
		[["lay_mine"], "Use it: lay a mine / call a base gun to you"],
		[["blow_mines"], "Blow your mines / send your base guns home"]]],
	["Match", [
		[["capture_recon"], "Capture the recon station you are on"],
		[["zoom_radar"], "Radar zoom"],
		[["cycle_teamies"], "Highlight next teammate on the radar"],
		[["cycle_enemies"], "Highlight next enemy on the radar"],
		[["start_chat"], "Chat"],
		[["player_list"], "Player list"],
		[["screen_capture"], "Screenshot"],
		[["exit_main"], "Leave to the main menu"],
		[["show_help"], "Show / hide this help"]]],
]

func _ready() -> void:
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
			key_label.text = _row_text(row)
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


# A row's third entry, when it has one, is what goes between the keys (default " / ").
func _row_text(row: Array) -> String:
	var key = row[0]
	if key is Array:
		return (row[2] if row.size() > 2 else " / ").join(key.map(Keybinds.key_text))
	return key


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("show_help"):
		visible = not visible
		get_viewport().set_input_as_handled()

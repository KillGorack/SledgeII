extends CenterContainer

# F4 (player_list) player list - one column per team, names in team color.
# Added to the owning peer's Hud_InGame by hud_controller.gd, so only your own
# HUD ever has one. Names come from NetworkManager.peer_names (pushed by the
# server, see match.gd::_sync_roster), teams from NetworkManager.peer_teams.

const COLUMN_WIDTH := 190.0
# Scores are shown as "takedowns / wrecks" next to each name - unlabelled
# on screen until the names are settled.

var _columns: Dictionary = {}


func _ready() -> void:
	# Registered here rather than in project.godot's Input Map; a binding added
	# there later wins, since this only fills it in when it's missing.
	if not InputMap.has_action("player_list"):
		InputMap.add_action("player_list")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_F4
		InputMap.action_add_event("player_list", key)
	visible = false
	# Full-screen, centering the panel in the middle of the screen.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.7)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var layout := VBoxContainer.new()
	panel.add_child(layout)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	layout.add_child(row)
	for team in NetworkManager.TEAM_NAMES:
		var column := VBoxContainer.new()
		column.custom_minimum_size.x = COLUMN_WIDTH
		row.add_child(column)
		var header := Label.new()
		header.text = team.trim_prefix("team_").capitalize()
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_theme_color_override("font_color", ReconStation.render_color_for_team(team))
		header.add_theme_font_size_override("font_size", 20)
		column.add_child(header)
		column.add_child(HSeparator.new())
		_columns[team] = column

	NetworkManager.roster_changed.connect(_refresh)
	NetworkManager.player_registered.connect(func(_id, _team): _refresh())
	NetworkManager.player_unregistered.connect(func(_id): _refresh())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("player_list"):
		visible = not visible
		if visible:
			_refresh()
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	if not visible:
		return
	for team in _columns:
		var column: VBoxContainer = _columns[team]
		# Keep the header and separator, rebuild the names.
		for i in range(column.get_child_count() - 1, 1, -1):
			var old := column.get_child(i)
			column.remove_child(old)
			old.queue_free()
	var my_id := multiplayer.get_unique_id()
	var ids := NetworkManager.peer_names.keys()
	ids.sort_custom(func(a, b): return str(NetworkManager.peer_names[a]).nocasecmp_to(str(NetworkManager.peer_names[b])) < 0)
	for peer_id in ids:
		var team: String = NetworkManager.peer_teams.get(peer_id, "")
		if not _columns.has(team):
			continue
		var color := ReconStation.render_color_for_team(team)
		var entry := HBoxContainer.new()
		var label := Label.new()
		label.text = NetworkManager.peer_names[peer_id]
		if peer_id == my_id:
			label.text = "[%s]" % label.text
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.add_theme_color_override("font_color", color)
		entry.add_child(label)
		var score: Array = NetworkManager.peer_scores.get(peer_id, [0, 0])
		var score_label := Label.new()
		score_label.text = "%d / %d" % [score[0], score[1]]
		score_label.add_theme_color_override("font_color", color)
		entry.add_child(score_label)
		_columns[team].add_child(entry)

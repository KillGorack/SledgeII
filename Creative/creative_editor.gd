class_name CreativeEditor
extends Node

# In-game level builder, ported from the old game's creative mode: you drive
# your craft around the level and build where the camera points. A tool is
# picked from the library (surface, ramp, paint, remove), a material from the
# list, and a piece snaps to whole metres where you aim. It edits the
# CreativeLevel data directly and keeps the built nodes in step, so what you
# save is exactly what gets built again later. B switches between building and
# normal driving/shooting for testing.
#
# Everything is on screen; the keys are shortcuts for the same actions:
# B build/test, Tab / Shift+Tab next/prev tool, Space use tool, F remove,
# I / J / K rotate 90 degrees around X / Y / Z (as the old game), [ ] width,
# - = height, F5 save locally.

const REACH := 80.0
const AUTOSAVE_SECONDS := 30.0
const ICON_SURFACE := preload("res://Creative/icons/quad.png")
const ICON_PAINT := preload("res://Creative/icons/paint.png")
const ICON_REMOVE := preload("res://Creative/icons/kibash.png")
const MATERIAL_ICON_PX := 96
const ICON_ENVIRONMENT := preload("res://Creative/icons/environment.png")

var _data: Dictionary
var _root: Node3D
var _camera: Camera3D
var _tools: Array[Dictionary] = []
var _tool := 0
var _material_ids: Array[StringName] = []
var _material := 0
var _size := Vector2(4.0, 4.0)
var _rotation := Vector3.ZERO
var _team: StringName = &"red"
var _team_buttons: Dictionary = {}
var _team_group: Control
var _environment_sliders: Dictionary = {}
var _ghost: MeshInstance3D
var _ghost_material: StandardMaterial3D
var _ui: Control
var _hud: Control
var _crosshair: Label
var _tool_buttons: Array[Button] = []
var _material_buttons: Array[Button] = []
var _width_edit: LineEdit
var _height_edit: LineEdit
var _rotate_group: Control
var _size_group: Control
var _mode_button: Button
var _status: Label
var _held_icon: TextureRect
var _held_label: Label
var _help: Control
var _undo := Callable()
var _undo_what := ""
var _flash := "Ready  -  F1 for help"
var _dirty := false
var _level_id := ""
var _autosave_left := AUTOSAVE_SECONDS


# Starts a single-player build session on a stored level: `local_id`, else the
# most recently changed one, else a new starter level. Callers that aren't the
# main menu must change to match.tscn themselves; the menu does it from
# NetworkManager.host_started.
static func start_session(local_id: String = "") -> Error:
	if not CreativeStore.has_level(local_id):
		var levels := CreativeStore.list()
		local_id = levels[0].local_id if not levels.is_empty() else CreativeStore.create("My first level")
	return NetworkManager.start_creative_session(CreativeStore.get_level(local_id).content, true, "team_red", local_id)


func setup(data: Dictionary, root: Node3D, camera: Camera3D) -> void:
	_data = data
	_root = root
	_camera = camera
	_level_id = NetworkManager.creative_level_id
	# The genre decides how tall the boundary is (a Force level's reaches 128 m), so the data carries it.
	var record := CreativeStore.get_level(_level_id)
	if not str(record.get("genre", "")).is_empty():
		_data["genre"] = record.genre
	if not _data.get("environment") is Dictionary:
		_data["environment"] = {}


func _ready() -> void:
	_tools.append({"kind": "surface", "id": &"surface", "name": "Surface", "icon": ICON_SURFACE})
	for piece_id in CreativeCatalog.PIECES:
		_tools.append({"kind": "piece", "id": piece_id, "name": CreativeCatalog.PIECES[piece_id].name, "icon": CreativeCatalog.PIECES[piece_id].icon})
	_tools.append({"kind": "paint", "id": &"paint", "name": "Paint", "icon": ICON_PAINT})
	_tools.append({"kind": "remove", "id": &"remove", "name": "Remove", "icon": ICON_REMOVE})
	_tools.append({"kind": "environment", "id": &"environment", "name": "Environment", "icon": ICON_ENVIRONMENT})
	for object_id in CreativeCatalog.OBJECTS:
		if CreativeCatalog.OBJECTS[object_id].get("hidden", false):
			continue
		_tools.append({"kind": "object", "id": object_id, "name": CreativeCatalog.OBJECTS[object_id].name, "icon": CreativeCatalog.OBJECTS[object_id].get("icon", _object_swatch(object_id))})
	for material_id in CreativeCatalog.MATERIALS:
		_material_ids.append(material_id)
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.albedo_color = Color(0.4, 0.9, 1.0, 0.45)
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost = MeshInstance3D.new()
	_ghost.top_level = true
	_ghost.material_override = _ghost_material
	add_child(_ghost)
	_build_ui()
	_render_material_icons.call_deferred()
	_sync_boundary(NetworkManager.creative_building)
	_select_tool(0)
	_select_material(_material_ids.find(CreativeCatalog.DEFAULT_MATERIAL_ID))


func _exit_tree() -> void:
	if _dirty:
		_save()
	NetworkManager.creative_building = false
	if is_instance_valid(_hud):
		_hud.visible = true


func _process(delta: float) -> void:
	if _dirty:
		_autosave_left -= delta
		if _autosave_left <= 0.0:
			_save()
	var building := NetworkManager.creative_building
	_update_hud(building)
	_update_ghost(building)
	_refresh_ui(building)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key: Key = event.physical_keycode
	if key == KEY_B:
		_toggle_building()
	elif key == KEY_F1:
		_help.visible = not _help.visible
	elif key == KEY_F5:
		_save()
	elif not NetworkManager.creative_building:
		return
	elif key == KEY_Z and event.ctrl_pressed:
		_undo_last()
	elif key == KEY_TAB:
		_select_tool(posmod(_tool + (-1 if event.shift_pressed else 1), _tools.size()))
	elif key == KEY_SPACE:
		_use_tool()
	elif key == KEY_F:
		_remove()
	elif key == KEY_I:
		_rotate(Vector3.RIGHT)
	elif key == KEY_J:
		_rotate(Vector3.UP)
	elif key == KEY_K:
		_rotate(Vector3.BACK)
	elif key == KEY_BRACKETLEFT:
		_resize(-1.0, 0.0)
	elif key == KEY_BRACKETRIGHT:
		_resize(1.0, 0.0)
	elif key == KEY_MINUS:
		_resize(0.0, -1.0)
	elif key == KEY_EQUAL:
		_resize(0.0, 1.0)
	else:
		return
	get_viewport().set_input_as_handled()


# --- actions ---------------------------------------------------------------

func _select_tool(index: int) -> void:
	_tool = index
	if index < _tool_buttons.size():
		_tool_buttons[index].button_pressed = true


func _select_material(index: int) -> void:
	_material = maxi(index, 0)
	if _material < _material_buttons.size():
		_material_buttons[_material].button_pressed = true


# Only the colours the object in hand can have are offered; the pick moves to its default when it can't keep it.
func _offer_teams(id: StringName) -> void:
	var allowed: Array = CreativeCatalog.OBJECTS[id].teams
	for team in _team_buttons:
		_team_buttons[team].visible = team in allowed
	if not _team in allowed:
		_team = CreativeCatalog.object_team(id, "")
		_team_buttons[_team].button_pressed = true


# "Name  [slider]  1.00": one setting of the level's look, previewed live as it is dragged.
func _environment_row(key: String) -> Control:
	var limits: Dictionary = CreativeLevel.ENVIRONMENT[key]
	var row := VBoxContainer.new()
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = limits.name
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var value_label := Label.new()
	head.add_child(value_label)
	row.add_child(head)
	var slider := HSlider.new()
	slider.min_value = limits.min
	slider.max_value = limits.max
	slider.step = 0.01
	slider.focus_mode = Control.FOCUS_NONE
	slider.custom_minimum_size = Vector2(0, 22)
	slider.value = float(_data.environment.get(key, 1.0))
	value_label.text = "%.2f" % slider.value
	slider.value_changed.connect(func(value: float) -> void:
		value_label.text = "%.2f" % value
		_set_environment(key, value))
	row.add_child(slider)
	_environment_sliders[key] = slider
	return row


func _set_environment(key: String, value: float) -> void:
	if is_equal_approx(value, 1.0):
		_data.environment.erase(key)
	else:
		_data.environment[key] = snappedf(value, 0.01)
	_dirty = true
	_preview_environment()


func _reset_environment() -> void:
	_data.environment.clear()
	for key in _environment_sliders:
		_environment_sliders[key].value = 1.0   # each one also reports itself through value_changed
	_dirty = true
	_preview_environment()


func _preview_environment() -> void:
	if get_parent().has_method("apply_level_environment"):
		get_parent().apply_level_environment(_data.environment)


func _select_team(team: StringName) -> void:
	_team = team


func _toggle_building() -> void:
	NetworkManager.creative_building = not NetworkManager.creative_building
	_sync_boundary(NetworkManager.creative_building)


# Building happens on the big ground; testing is on what a player gets: the floor trimmed to what you built and
# clear walls round it, measured fresh each time you press Test.
func _sync_boundary(building: bool) -> void:
	var old := _root.get_node_or_null("Boundary")
	if old:
		_root.remove_child(old)
		old.free()
	var ground := _root.get_node_or_null("Ground") as StaticBody3D
	if ground:
		ground.visible = building
		ground.collision_layer = CreativeLevelBuilder.WORLD_LAYER if building else 0
	if not building:
		_root.add_child(CreativeLevelBuilder.make_boundary(_data, _root))


func _rotate(axis: Vector3) -> void:
	_rotation = (_rotation + axis * 90.0)
	_rotation = Vector3(fposmod(_rotation.x, 360.0), fposmod(_rotation.y, 360.0), fposmod(_rotation.z, 360.0))


func _resize(width_step: float, height_step: float) -> void:
	_size.x = clampf(_size.x + width_step, CreativeLevel.MIN_SURFACE_SIZE, CreativeLevel.MAX_SURFACE_SIZE)
	_size.y = clampf(_size.y + height_step, CreativeLevel.MIN_SURFACE_SIZE, CreativeLevel.MAX_SURFACE_SIZE)


func _use_tool() -> void:
	match _tools[_tool].kind:
		"surface", "piece", "object":
			_place()
		"paint":
			_paint()
		"remove":
			_remove()


func _raycast() -> Dictionary:
	if not _camera or not _camera.is_inside_tree():
		return {}
	var from := _camera.global_position
	var to := from + -_camera.global_basis.z * REACH
	var query := PhysicsRayQueryParameters3D.create(from, to, CreativeLevelBuilder.WORLD_LAYER | CreativeLevelBuilder.PICK_LAYER)
	return _camera.get_world_3d().direct_space_state.intersect_ray(query)


# Where the current piece would go, or {} if nothing is aimed at (or the tool
# doesn't place). Pieces snap to whole metres, the old game's rule.
func _placement() -> Dictionary:
	var tool := _tools[_tool]
	if not tool.kind in ["surface", "piece", "object"]:
		return {}
	var hit := _raycast()
	if hit.is_empty():
		return {}
	var position: Vector3 = (hit.position as Vector3).round()
	var entry := {"p": [position.x, position.y, position.z], "r": [_rotation.x, _rotation.y, _rotation.z]}
	if tool.kind == "object":
		if CreativeCatalog.OBJECTS[tool.id].get("snap", "") == "cell":
			# The cell under the aim, not the nearest grid line: round() would pick a neighbour half the time.
			position = Vector3(floorf(hit.position.x) + 0.5, position.y, floorf(hit.position.z) + 0.5)
		position += CreativeCatalog.object_offset(tool.id)
		entry["p"] = [position.x, position.y, position.z]
		entry["id"] = String(tool.id)
		if CreativeCatalog.has_teams(tool.id):
			entry["t"] = String(_team)
		return {"entry": entry, "position": position}
	entry["m"] = String(_material_ids[_material])
	if tool.kind == "surface":
		entry["s"] = [_size.x, _size.y]
	else:
		entry["id"] = String(tool.id)
	return {"entry": entry, "position": position}


func _place() -> void:
	var placement := _placement()
	if placement.is_empty():
		return
	var tool := _tools[_tool]
	var key: String = {"surface": "surfaces", "piece": "pieces", "object": "objects"}[tool.kind]
	var limit: int = {"surface": CreativeLevel.MAX_SURFACES, "piece": CreativeLevel.MAX_PIECES, "object": CreativeLevel.MAX_OBJECTS}[tool.kind]
	if _data[key].size() >= limit:
		_say("Limit reached (%d)" % limit)
		return
	var clean: Array = CreativeLevel.sanitize({key: [placement.entry]})[key]
	if clean.is_empty():
		return
	_data[key].append(clean[0])
	_dirty = true
	var node := _spawn(key, clean[0])
	_remember_undo("placed " + String(tool.name), func() -> void:
		_forget(key, clean[0])
		if is_instance_valid(node):
			node.queue_free())
	_say("Placed %s" % tool.name)


# Builds the node for one entry of the level and adds it; returns the node that has to be freed to take it away
# again (for a recon, the anchor the station hangs on).
func _spawn(key: String, entry: Dictionary) -> Node:
	if key == "surfaces":
		var surface := CreativeLevelBuilder.make_surface(entry)
		_root.add_child(surface)
		return surface
	if key == "pieces":
		var piece := CreativeLevelBuilder.make_piece(entry)
		_root.add_child(piece)
		return piece
	var node := CreativeLevelBuilder.make_object(entry, _root.get_node("recon_locations"), true)
	if node:
		_root.add_child(node)
		return node
	if entry.id == "recon":
		# make_object put an anchor under recon_locations; the match fills it with a station as it does at load.
		var anchors := _root.get_node("recon_locations").get_children()
		if anchors.is_empty():
			return null
		if get_parent().has_method("spawn_recon_station"):
			get_parent().spawn_recon_station(anchors[-1])
		return anchors[-1]
	return null


# Takes an entry out of the level's data by identity (two identical entries can both exist).
func _forget(key: String, entry: Dictionary) -> void:
	for i in _data[key].size():
		if is_same(_data[key][i], entry):
			_data[key].remove_at(i)
			return


func _paint() -> void:
	var hit := _raycast()
	if hit.is_empty() or not hit.collider.has_meta("entry"):
		return
	var entry: Dictionary = hit.collider.get_meta("entry")
	if not entry.has("m"):
		return
	var previous: String = entry["m"]
	var body: Node = hit.collider
	entry["m"] = String(_material_ids[_material])
	_dirty = true
	CreativeLevelBuilder.paint(body, _material_ids[_material])
	_remember_undo("painted", func() -> void:
		entry["m"] = previous
		if is_instance_valid(body):
			CreativeLevelBuilder.paint(body, StringName(previous)))
	_say("Painted %s" % String(_material_ids[_material]).replace("_", " "))


func _remove() -> void:
	var hit := _raycast()
	if hit.is_empty() or not hit.collider.has_meta("entry"):
		return
	var entry: Dictionary = hit.collider.get_meta("entry")
	var key := "surfaces"
	if entry.has("id"):
		key = "objects" if CreativeCatalog.has_object(StringName(entry.id)) else "pieces"
	_forget(key, entry)
	_dirty = true
	hit.collider.get_meta("root").queue_free()
	_remember_undo("removed", func() -> void:
		_data[key].append(entry)
		_spawn(key, entry))
	_say("Removed")


# One step back: whatever the last place, paint or remove did. Taking it back is itself not undoable.
func _remember_undo(what: String, undo: Callable) -> void:
	_undo_what = what
	_undo = undo


func _undo_last() -> void:
	if not _undo.is_valid():
		_say("Nothing to undo")
		return
	_undo.call()
	_dirty = true
	_say("Undid: " + _undo_what)
	_undo = Callable()


func _save() -> void:
	_autosave_left = AUTOSAVE_SECONDS
	# `_data` is the stored record's own content, so saving is just stamping it.
	if CreativeStore.update_content(_level_id):
		_dirty = false
		_say("Saved")
	else:
		_say("Save failed")


func _say(text: String) -> void:
	_flash = text


# While building, the craft's own HUD (bezel, radar, meters, chat...) is hidden
# so only the build tools show; a crosshair stands in for the reticle.
func _update_hud(building: bool) -> void:
	if not is_instance_valid(_hud) and _camera:
		var craft: Node = _camera
		while craft and not craft.is_in_group("Craft"):
			craft = craft.get_parent()
		if craft:
			_hud = craft.get_node_or_null("Hud_InGame")
	if is_instance_valid(_hud):
		_hud.visible = not building
	_crosshair.visible = building


# --- ghost -----------------------------------------------------------------

func _update_ghost(building: bool) -> void:
	_ghost.visible = false
	if not building:
		return
	var placement := _placement()
	if placement.is_empty():
		return
	var tool := _tools[_tool]
	var basis := Basis.from_euler(_rotation * (PI / 180.0), EULER_ORDER_YXZ)
	var origin := Transform3D(basis, placement.position)
	if tool.kind == "surface":
		var quad := _ghost.mesh as QuadMesh
		if not quad:
			quad = QuadMesh.new()
			_ghost.mesh = quad
		quad.size = _size
		_ghost.global_transform = origin * Transform3D(Basis.IDENTITY, Vector3(_size.x * 0.5, _size.y * 0.5, 0.0))
	elif tool.kind == "object":
		var cube := _ghost.mesh as BoxMesh
		if not cube:
			cube = BoxMesh.new()
			_ghost.mesh = cube
		if CreativeCatalog.OBJECTS[tool.id].kind == "pad":
			# The real pad's footprint, from the corner it will be placed at, so it can be lined up exactly.
			cube.size = Vector3(CreativeLevelBuilder.PAD_SIZE.x, CreativeLevelBuilder.PAD_THICKNESS, CreativeLevelBuilder.PAD_SIZE.y)
			_ghost.global_transform = origin * Transform3D(Basis.IDENTITY, cube.size * 0.5)
		else:
			cube.size = Vector3.ONE
			_ghost.global_transform = origin * Transform3D(Basis.IDENTITY, Vector3(0.0, CreativeCatalog.object_lift(tool.id), 0.0))
	else:
		_ghost.mesh = CreativeLevelBuilder.piece_mesh(tool.id)
		_ghost.global_transform = origin
	_ghost_material.albedo_color = Color(0.4, 0.9, 1.0, 0.45)
	if tool.kind == "object" and CreativeCatalog.has_teams(tool.id):
		var tint: Color = CreativeCatalog.TEAMS[_team]
		_ghost_material.albedo_color = Color(tint.r, tint.g, tint.b, 0.5)
	_ghost.visible = true


# --- ui --------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Only the panels take the mouse; the rest of the screen stays the game's.
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)

	# Left: what to build with (tools, pieces) and, below, objects to place.
	# Right: the textures. Tools and objects share one button group because
	# only one thing is "in hand" at a time.
	var left := VBoxContainer.new()
	left.name = "Library"
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.offset_top = 12.0
	left.offset_bottom = -12.0
	left.offset_left = 12.0
	left.offset_right = 232.0
	left.add_theme_constant_override("separation", 8)
	_ui.add_child(left)
	var tool_group := ButtonGroup.new()
	var tools_grid := _panel(left, "", 1)
	for i in _tools.size():
		var button := _library_button(tool_group, _tools[i].name, _tools[i].icon, true)
		button.pressed.connect(_select_tool.bind(i))
		tools_grid.add_child(button)
		_tool_buttons.append(button)

	var right := VBoxContainer.new()
	right.name = "Textures"
	right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right.offset_top = 70.0
	right.offset_bottom = -90.0
	right.offset_left = -176.0
	right.offset_right = -12.0
	_ui.add_child(right)
	var material_grid := _panel(right, "", 2)
	var material_group := ButtonGroup.new()
	for i in _material_ids.size():
		var material_id := _material_ids[i]
		var button := _library_button(material_group, String(material_id).replace("_", " ").capitalize(), _swatch(material_id), false, true)
		button.pressed.connect(_select_material.bind(i))
		material_grid.add_child(button)
		_material_buttons.append(button)

	# Bottom centre: only what the tool in hand can use (rotation; size for a surface).
	# Right: the look of the level, in place of the textures while the Environment tool is in hand.
	var environment_box := VBoxContainer.new()
	environment_box.name = "Environment"
	environment_box.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	environment_box.offset_top = 70.0
	environment_box.offset_bottom = -90.0
	environment_box.offset_left = -292.0
	environment_box.offset_right = -12.0
	_ui.add_child(environment_box)
	var environment_panel := PanelContainer.new()
	environment_box.add_child(environment_panel)
	var environment_margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		environment_margin.add_theme_constant_override("margin_" + side, 14)
	environment_panel.add_child(environment_margin)
	var environment_column := VBoxContainer.new()
	environment_column.add_theme_constant_override("separation", 10)
	environment_margin.add_child(environment_column)
	environment_column.add_child(_heading("Environment"))
	for key in CreativeLevel.ENVIRONMENT:
		environment_column.add_child(_environment_row(key))
	var reset_button := _tool_button("Reset", _reset_environment, "Back to the normal look")
	reset_button.custom_minimum_size = Vector2(0, 40)
	environment_column.add_child(reset_button)

	var bar_panel := PanelContainer.new()
	bar_panel.name = "Toolbar"
	_dock(bar_panel, Control.PRESET_CENTER_BOTTOM)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 14)
	bar_panel.add_child(bar)

	var rotate_row := HBoxContainer.new()
	rotate_row.add_theme_constant_override("separation", 6)
	rotate_row.add_child(_caption("Rotate"))
	for entry in [["X", Vector3.RIGHT, "I"], ["Y", Vector3.UP, "J"], ["Z", Vector3.BACK, "K"]]:
		var axis_button := _tool_button(entry[0], _rotate.bind(entry[1]), "Rotate 90 degrees around %s (%s)" % [entry[0], entry[2]])
		axis_button.custom_minimum_size = Vector2(52, 0)
		rotate_row.add_child(axis_button)
	_rotate_group = rotate_row
	bar.add_child(rotate_row)


	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 6)
	size_row.add_child(VSeparator.new())
	_width_edit = _size_box(size_row, "W", "Width in metres ([ ] keys)", true)
	_height_edit = _size_box(size_row, "H", "Height in metres (- = keys)", false)
	_size_group = size_row
	bar.add_child(size_row)

	var team_row := HBoxContainer.new()
	team_row.add_theme_constant_override("separation", 6)
	team_row.add_child(VSeparator.new())
	team_row.add_child(_caption("Team"))
	var team_buttons := ButtonGroup.new()
	for team in CreativeCatalog.TEAMS:
		var swatch := Button.new()
		swatch.toggle_mode = true
		swatch.button_group = team_buttons
		swatch.focus_mode = Control.FOCUS_NONE
		swatch.custom_minimum_size = Vector2(44, 44)
		swatch.icon = _flat_icon(CreativeCatalog.TEAMS[team])
		swatch.expand_icon = true
		swatch.tooltip_text = String(team).capitalize()
		swatch.pressed.connect(_select_team.bind(team))
		team_row.add_child(swatch)
		_team_buttons[team] = swatch
	_team_buttons[_team].button_pressed = true
	_team_group = team_row
	bar.add_child(team_row)

	# Bottom right: always there, so test mode can get back to building.
	var actions := PanelContainer.new()
	actions.name = "Actions"
	_dock(actions, Control.PRESET_BOTTOM_RIGHT)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	actions.add_child(action_row)
	var save_button := _tool_button("Save", _save, "Save (F5)")
	save_button.custom_minimum_size = Vector2(90, 0)
	action_row.add_child(save_button)
	_mode_button = _tool_button("Test", _toggle_building, "Switch between building and testing (B)")
	_mode_button.custom_minimum_size = Vector2(90, 0)
	action_row.add_child(_mode_button)

	# What is in hand, big, above the toolbar (as the old game showed it).
	var held := VBoxContainer.new()
	held.name = "Held"
	held.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	held.grow_horizontal = Control.GROW_DIRECTION_BOTH
	held.grow_vertical = Control.GROW_DIRECTION_BEGIN
	held.offset_bottom = -96.0
	held.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(held)
	_held_label = Label.new()
	_held_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_held_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_held_label.add_theme_constant_override("outline_size", 6)
	held.add_child(_held_label)
	_held_icon = TextureRect.new()
	_held_icon.custom_minimum_size = Vector2(110, 110)
	_held_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_held_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_held_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	held.add_child(_held_icon)

	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	_crosshair.add_theme_color_override("font_outline_color", Color.BLACK)
	_crosshair.add_theme_constant_override("outline_size", 6)
	_ui.add_child(_crosshair)

	_help = _build_help()
	_ui.add_child(_help)

	# Top right: the last thing that happened (placed, saved...).
	var status_panel := PanelContainer.new()
	status_panel.name = "Status"
	status_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	status_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	status_panel.offset_top = 12.0
	status_panel.offset_right = -12.0
	status_panel.add_theme_stylebox_override("panel", _panel_style())
	_ui.add_child(status_panel)
	_status = Label.new()
	_status.custom_minimum_size = Vector2(200, 0)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_panel.add_child(_status)


# The F1 card: every key the editor answers to. Never takes the mouse, so it can stay up while you build.
func _build_help() -> Control:
	var panel := PanelContainer.new()
	panel.name = "Help"
	panel.visible = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.add_theme_stylebox_override("panel", _panel_style())
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 4)
	margin.add_child(column)
	var sections := [
		["Anywhere", [
			["B", "Switch between building and testing"],
			["F5", "Save (it also saves itself every 30 seconds)"],
			["F1", "Show / hide this help"]]],
		["Building", [
			["Tab / Shift+Tab", "Next / previous tool (or click one on the left)"],
			["Space", "Use the tool: place, paint or remove what you are aiming at"],
			["F", "Remove what you are aiming at, whatever tool you hold"],
			["Ctrl+Z", "Undo the last place, paint or remove (one step)"],
			["I   J   K", "Turn 90 degrees about X, Y or Z"],
			["[   ]", "Surface: narrower / wider"],
			["-   =", "Surface: shorter / taller"]]],
		["Notes", [
			["Paint", "Pick a texture on the right (also shown for surfaces and ramps), then aim and press Space"],
			["Team", "Pads, turrets and recons take the team colour you pick"],
			["Environment", "Sliders for the look of the level; nothing is placed"]]],
	]
	for section in sections:
		var heading := _heading(section[0])
		column.add_child(heading)
		for row in section[1]:
			var line := HBoxContainer.new()
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			line.add_theme_constant_override("separation", 16)
			var key := Label.new()
			key.text = row[0]
			key.custom_minimum_size = Vector2(150, 0)
			key.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
			line.add_child(key)
			var what := Label.new()
			what.text = row[1]
			line.add_child(what)
			column.add_child(line)
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, 6)
		gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(gap)
	return panel


# A floating panel pinned to a bottom edge/corner, growing inwards from it.
func _dock(panel: PanelContainer, preset: Control.LayoutPreset) -> void:
	panel.set_anchors_preset(preset)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH if preset == Control.PRESET_CENTER_BOTTOM else Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_bottom = -12.0
	if preset == Control.PRESET_BOTTOM_RIGHT:
		panel.offset_right = -12.0
	panel.add_theme_stylebox_override("panel", _panel_style())
	_ui.add_child(panel)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.86)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(1.0, 0.8, 0.3, 0.35)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label


# A titled, scrolling panel; returns the grid to put its buttons in.
func _panel(parent: Control, title: String, columns: int = 2) -> GridContainer:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	if not title.is_empty():
		column.add_child(_heading(title))
	var grid := GridContainer.new()
	grid.columns = columns
	column.add_child(grid)
	return grid


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	return label


# `wide` is one button per row, icon on the left; otherwise a square tile with the icon on top.
func _library_button(group: ButtonGroup, text: String, icon: Texture2D, wide: bool = false, icon_only: bool = false) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_group = group
	button.focus_mode = Control.FOCUS_NONE
	button.icon = icon
	button.expand_icon = true
	if wide:
		button.custom_minimum_size = Vector2(0, 56)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	else:
		button.custom_minimum_size = Vector2(98, 84)
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	button.tooltip_text = text
	if icon_only:
		# The picture alone; the name stays as the tooltip.
		button.custom_minimum_size = Vector2(68, 68)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
		return button
	button.text = text
	button.clip_text = true
	return button


func _step_button(text: String, action: Callable, hint: String) -> Button:
	var button := _tool_button(text, action)
	button.custom_minimum_size = Vector2(46, 0)
	button.tooltip_text = hint
	return button


func _tool_button(text: String, action: Callable, shortcut_hint: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 52)
	button.pressed.connect(action)
	if not shortcut_hint.is_empty():
		button.tooltip_text = "Shortcut: %s" % shortcut_hint
	return button


# "W [ 4 ]": a whole-number box. Anything that isn't a digit is thrown out and
# the box flashes red; the value is kept within the allowed size range.
func _size_box(row: Control, title: String, hint: String, is_width: bool) -> LineEdit:
	var caption := Label.new()
	caption.text = title
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(caption)
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(64, 0)
	edit.max_length = 3
	edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit.tooltip_text = hint
	edit.text_changed.connect(_size_text_changed.bind(edit, is_width))
	edit.text_submitted.connect(func(_t): edit.release_focus())
	edit.focus_exited.connect(_sync_size_boxes)
	row.add_child(edit)
	return edit


func _size_text_changed(text: String, edit: LineEdit, is_width: bool) -> void:
	var digits := ""
	for character in text:
		if character >= "0" and character <= "9":
			digits += character
	var angry := digits != text
	if not digits.is_empty():
		var value := float(digits.to_int())
		var clamped := clampf(value, CreativeLevel.MIN_SURFACE_SIZE, CreativeLevel.MAX_SURFACE_SIZE)
		# Too big is also a mistake worth flagging; too small waits for Enter/blur
		# so typing "12" isn't fought at the "1".
		if value > clamped:
			angry = true
			digits = str(int(clamped))
		if is_width:
			_size.x = clamped
		else:
			_size.y = clamped
	if angry:
		_flash_angry(edit)
	if digits != text:
		edit.text = digits
		edit.caret_column = digits.length()


func _flash_angry(edit: Control) -> void:
	edit.modulate = Color(1.0, 0.25, 0.25)
	create_tween().tween_property(edit, "modulate", Color.WHITE, 0.45)


# Show the real sizes, except in a box that's being typed in.
func _sync_size_boxes() -> void:
	if not _width_edit.has_focus():
		_width_edit.text = str(int(_size.x))
	if not _height_edit.has_focus():
		_height_edit.text = str(int(_size.y))


# Clicking out in the world should end typing, since the world isn't a control.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		for edit in [_width_edit, _height_edit]:
			if edit and edit.has_focus() and not edit.get_global_rect().has_point(event.position):
				edit.release_focus()


# Replaces each texture's flat albedo picture with the material as it looks in the level: lit by a sun and sky,
# with its tint, shine, normal map and a two metre patch of its tiling. Drawn once, off screen, in a world of
# its own; the albedo swatch stays until each one is ready (and for good when nothing can draw, e.g. headless).
func _render_material_icons() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(MATERIAL_ICON_PX, MATERIAL_ICON_PX)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.16, 0.17, 0.2)
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40.0, -35.0, 0.0)
	sun.light_energy = 1.2
	viewport.add_child(sun)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position = Vector3(0.0, 0.0, 3.0)
	viewport.add_child(camera)
	var patch := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	patch.mesh = quad
	viewport.add_child(patch)
	for i in _material_ids.size():
		var material := CreativeCatalog.get_material(_material_ids[i]).duplicate()
		if material is BaseMaterial3D:
			material.uv1_scale = Vector3(2.0, 2.0, 1.0)
		patch.material_override = material
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		if not is_instance_valid(self):
			return
		var image := viewport.get_texture().get_image()
		if image and i < _material_buttons.size():
			_material_buttons[i].icon = ImageTexture.create_from_image(image)
	viewport.queue_free()


# Library icon for a material: its own albedo texture, else a flat colour.
func _swatch(material_id: StringName) -> Texture2D:
	var material := CreativeCatalog.get_material(material_id) as BaseMaterial3D
	if material and material.albedo_texture:
		return material.albedo_texture
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(material.albedo_color if material else Color.GRAY)
	return ImageTexture.create_from_image(image)


# Object icon: a flat swatch in the object's colour.
func _object_swatch(object_id: StringName) -> Texture2D:
	var def: Dictionary = CreativeCatalog.OBJECTS[object_id]
	var color := Color(0.7, 0.7, 0.7)
	if def.has("color"):
		color = def.color
	elif def.kind == "recon":
		color = Color(0.3, 0.8, 1.0)
	elif def.kind == "spawn":
		color = Color(1.0, 0.8, 0.2)
	return _flat_icon(color)


func _flat_icon(color: Color) -> Texture2D:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


# The picture of what is in hand; a pad shows in the team colour picked.
func _held_texture() -> Texture2D:
	var tool := _tools[_tool]
	if tool.kind == "object" and tool.id == &"base_pad":
		return load("res://Creative/icons/base_pad_%s.png" % _team)
	return tool.icon


func _refresh_ui(building: bool) -> void:
	_ui.get_node("Library").visible = building
	# Textures are for whatever takes one: Paint, and the pieces that are placed with a texture (surfaces, ramps).
	_ui.get_node("Textures").visible = building and _tools[_tool].kind in ["paint", "surface", "piece"]
	_ui.get_node("Environment").visible = building and _tools[_tool].kind == "environment"
	_ui.get_node("Held").visible = building
	_held_label.text = _tools[_tool].name
	_held_icon.texture = _held_texture()
	var tool := _tools[_tool]
	_sync_size_boxes()
	var rotates: bool = tool.kind in ["surface", "piece", "object"]
	var has_team: bool = tool.kind == "object" and CreativeCatalog.has_teams(tool.id)
	if has_team:
		_offer_teams(tool.id)
	_rotate_group.visible = rotates
	_size_group.visible = tool.kind == "surface"
	_team_group.visible = has_team
	_ui.get_node("Toolbar").visible = building and rotates
	_ui.get_node("Held").offset_bottom = -96.0 if rotates else -24.0
	_mode_button.text = "Test" if building else "Build"
	_status.text = _flash
	_ui.get_node("Status").visible = building

extends MarginContainer

# The "My Creations" screen: the player's own levels from CreativeStore, with
# New, Edit, Rename, Duplicate and Delete, plus Publish / Update and Remove from
# server through CreativeApi. A published level is Pending until an
# administrator approves it on the site; approved levels are found and hosted
# from the Create Game list (Origin filter), not here.
# Built in code so the tab in index.tscn is just this one node.

var _list: ItemList
var _ids: Array[String] = []
var _title: Label
var _details: RichTextLabel
var _buttons: Dictionary = {}
var _name_dialog: ConfirmationDialog
var _name_edit: LineEdit
var _description_edit: TextEdit
var _name_mode := ""
var _delete_dialog: ConfirmationDialog
var _unpublish_dialog: ConfirmationDialog
var _publish_dialog: ConfirmationDialog
var _genre_pick: OptionButton
var _feedback: Label
var _busy := false
# What the server says about a level (waiting, rejected, published) is only shown once this visit has asked it.
# Until then, or when it can't be reached, the screen says so instead of repeating what was true last time.
var _checking := false
var _verified := false
# The check on arrival is tried again if it fails or the login was not ready yet: up to this many tries a visit,
# a few seconds apart. The Check server button always works on its own.
const AUTO_CHECK_TRIES := 4
const AUTO_CHECK_GAP := 2.5
var _auto_tries := 0
var _verified_at := -100000   # ticks (ms) of the last answer, so coming back to the tab soon after doesn't ask again
const FRESH_MSEC := 30000
var _auto_wait := 0.0
var _thumb_frame: PanelContainer
var _thumb: TextureRect
var _thumb_request: HTTPRequest
var _thumb_for := 0

# The picture a published level got (see CreativeThumbnail), from the same place the Create Game list reads it.
# Kept for the session so selecting a level again doesn't download it again.
const THUMBNAIL_URL := "https://www.killgorack.com/PX4/downloader.php?ap=tanarusmaps&id=%d&type=game_thumb&cn=fls"
static var _thumb_cache: Dictionary = {}

const BUTTON_HEIGHT := 46
# The menu's card (a panel with corner brackets) and the pink it uses for the second card on a screen.
const HUD_CARD := preload("res://UI/_scripts/hud_card.gd")
const CARD_PINK := Color(1.0, 0.24, 0.65)


func _ready() -> void:
	# Two cards, like the other menu screens: the player's levels on the left, the selected one on the right.
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 16)
	add_child(columns)

	var list_body := _card(columns, "MY LEVELS", 1.2)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(func(_i): _refresh_details())
	_list.item_activated.connect(func(_i): _edit())
	list_body.add_child(_list)

	var card := _card(columns, "SELECTED LEVEL", 1.0, CARD_PINK)
	card.add_child(HSeparator.new())
	_title = Label.new()
	_title.theme_type_variation = &"TitleLabel"
	_title.add_theme_font_size_override("font_size", 24)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	card.add_child(_title)
	_thumb_frame = PanelContainer.new()
	_thumb_frame.visible = false
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.008, 0.016, 0.035)
	frame_style.set_border_width_all(1)
	frame_style.border_color = Color(0.27, 0.88, 1.0, 0.55)
	frame_style.set_content_margin_all(1)
	_thumb_frame.add_theme_stylebox_override("panel", frame_style)
	# 16:9 like the picture itself, at a fixed size, so it never stretches or sits in bars.
	_thumb_frame.custom_minimum_size = Vector2(448, 256)
	_thumb_frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_thumb = TextureRect.new()
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_thumb_frame.add_child(_thumb)
	card.add_child(_thumb_frame)
	_thumb_request = HTTPRequest.new()
	_thumb_request.request_completed.connect(_thumb_received)
	add_child(_thumb_request)
	_details = RichTextLabel.new()
	_details.bbcode_enabled = true
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(_details)
	_feedback = Label.new()
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(_feedback)
	# Two rows, each filling the width: what you do to the level, then what you do with it online. The main action of each
	# is coloured.
	var level_row := _button_row(card)
	_add_button(level_row, "new", "NEW", _new)
	_add_button(level_row, "edit", "EDIT", _edit, "primary")
	_add_button(level_row, "rename", "RENAME", _rename)
	_add_button(level_row, "copy", "DUPLICATE", _copy)
	_add_button(level_row, "delete", "DELETE", _confirm_delete, "danger")
	var online_row := _button_row(card)
	_add_button(online_row, "publish", "PUBLISH", _publish, "go")
	_add_button(online_row, "unpublish", "REMOVE FROM SERVER", _confirm_unpublish)
	_add_button(online_row, "refresh", "CHECK SERVER", _sync_with_server)

	_name_dialog = ConfirmationDialog.new()
	_name_dialog.min_size = Vector2(420, 0)
	var form := VBoxContainer.new()
	_name_edit = LineEdit.new()
	_name_edit.max_length = CreativeLevel.MAX_NAME_LENGTH
	_name_edit.placeholder_text = "Level name"
	form.add_child(_name_edit)
	_description_edit = TextEdit.new()
	_description_edit.placeholder_text = "Description (optional)"
	_description_edit.custom_minimum_size = Vector2(0, 90)
	form.add_child(_description_edit)
	_name_dialog.add_child(form)
	_name_dialog.confirmed.connect(_name_confirmed)
	_name_edit.text_submitted.connect(func(_t): _name_dialog.hide(); _name_confirmed())
	add_child(_name_dialog)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.confirmed.connect(_delete)
	add_child(_delete_dialog)

	_publish_dialog = ConfirmationDialog.new()
	_publish_dialog.min_size = Vector2(380, 0)
	var publish_form := VBoxContainer.new()
	var genre_label := Label.new()
	genre_label.text = "Genre (required)"
	publish_form.add_child(genre_label)
	_genre_pick = OptionButton.new()
	_genre_pick.add_item("Choose a genre...")
	_genre_pick.set_item_disabled(0, true)
	for genre in CreativeApi.GENRES:
		_genre_pick.add_item(genre)
	_genre_pick.item_selected.connect(func(index: int): _publish_dialog.get_ok_button().disabled = index == 0)
	publish_form.add_child(_genre_pick)
	var publish_note := Label.new()
	publish_note.text = "An administrator approves new levels before they are listed."
	# A wrapping label with no width to wrap against makes the whole dialog enormous.
	publish_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	publish_note.custom_minimum_size = Vector2(360, 0)
	publish_form.add_child(publish_note)
	_publish_dialog.add_child(publish_form)
	_publish_dialog.confirmed.connect(_send_publish)
	add_child(_publish_dialog)

	_unpublish_dialog = ConfirmationDialog.new()
	_unpublish_dialog.confirmed.connect(_unpublish)
	add_child(_unpublish_dialog)

	# Re-read whenever the tab comes back into view (levels change while building).
	visibility_changed.connect(func(): if is_visible_in_tree(): _on_shown())
	_reload()
	if is_visible_in_tree():
		_on_shown()


# Called by the menu as soon as the player is logged in, so the answer is already there by the time they open this tab.
func check_server() -> void:
	_verified = false
	_auto_tries = 1
	_auto_wait = AUTO_CHECK_GAP
	_sync_with_server()


func _on_shown() -> void:
	if _verified and Time.get_ticks_msec() - _verified_at < FRESH_MSEC:
		_reload()
		return
	_verified = false
	_auto_tries = 1
	_auto_wait = AUTO_CHECK_GAP
	_reload()
	_sync_with_server()


# Keeps asking until the server has answered once this visit: covers a login that finished after the tab opened and
# a first request that failed (the reason stays in the line above the buttons).
func _process(delta: float) -> void:
	if _verified or _checking or _busy or not is_visible_in_tree() or not CreativeApi.logged_in():
		return
	_auto_wait -= delta
	if _auto_wait <= 0.0 and _auto_tries < AUTO_CHECK_TRIES:
		_auto_tries += 1
		_auto_wait = AUTO_CHECK_GAP
		_sync_with_server()


func _selected_id() -> String:
	var picked := _list.get_selected_items()
	return _ids[picked[0]] if not picked.is_empty() else ""


func _reload(select_id: String = "") -> void:
	if select_id.is_empty():
		select_id = _selected_id()
	_list.clear()
	_ids.clear()
	for header in CreativeStore.list():
		_ids.append(header.local_id)
		var published := "   [%s]" % _status_word(header) if header.published_id > 0 else ""
		# The two leading spaces keep the name clear of the bar that marks the selected row.
		_list.add_item("  %s   (%d pieces)%s" % [header.name, header.surfaces + header.pieces + header.objects, published])
		if header.local_id == select_id:
			_list.select(_ids.size() - 1)
	if _list.get_selected_items().is_empty() and not _ids.is_empty():
		_list.select(0)
	_refresh_details()


func _refresh_details() -> void:
	var id := _selected_id()
	var level := CreativeStore.get_level(id)
	for key in ["edit", "rename", "copy", "delete"]:
		_buttons[key].disabled = level.is_empty() or _busy
	_buttons.publish.disabled = level.is_empty() or _busy
	_buttons.publish.text = "UPDATE" if not level.is_empty() and level.published_id > 0 else "PUBLISH"
	_buttons.unpublish.visible = not level.is_empty() and level.published_id > 0
	_buttons.unpublish.disabled = _busy
	_show_thumbnail(level)
	if level.is_empty():
		_title.text = "No levels yet"
		_details.text = "Press New to start building."
		return
	var content: Dictionary = level.content
	_title.text = level.name
	var status := "Not published"
	if level.published_id > 0:
		status = _status_word(level)
		if _verified and level.get("server_state", "") == "Rejected" and not str(level.get("reject_note", "")).is_empty():
			status += " - %s" % level.reject_note
		if level.dirty:
			status += " (changed since, press Update to send it)"
	var lines: Array[String] = []
	if not str(level.description).is_empty():
		lines.append(str(level.description) + "\n")
	lines.append("[b]%d[/b] surfaces, [b]%d[/b] ramps and pieces, [b]%d[/b] objects" % [content.surfaces.size(), content.pieces.size(), content.objects.size()])
	lines.append("Status: %s" % status)
	lines.append("Last changed: %s" % Time.get_datetime_string_from_unix_time(int(level.updated), true))
	lines.append("Created: %s" % Time.get_datetime_string_from_unix_time(int(level.created), true))
	if not str(level.imported_from).is_empty():
		lines.append("Imported from the old game (%s)" % level.imported_from)
	_details.text = "\n".join(lines)


# One of the screen's two cards, with its heading. Returns the column to put the card's contents in.
func _card(parent: Control, heading: String, share: float, accent: Color = Color(0.27, 0.88, 1.0)) -> VBoxContainer:
	var panel: PanelContainer = HUD_CARD.new()
	panel.accent = accent
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = share
	parent.add_child(panel)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	panel.add_child(body)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	body.add_child(head)
	var mark := Label.new()
	mark.theme_type_variation = &"IndexLabel"
	mark.text = "//"
	head.add_child(mark)
	var title := Label.new()
	title.theme_type_variation = &"HeaderLabel"
	title.text = heading
	head.add_child(title)
	return body


# A row of buttons that share the full width equally, however many there are.
func _button_row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row


# A button in the menu theme's look. kind: "" plain, "primary" (the main thing to do), "go" (send it online),
# "danger" (cannot be undone).
func _add_button(row: Control, key: String, text: String, action: Callable, kind: String = "") -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, BUTTON_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.clip_text = true
	button.pressed.connect(action)
	button.theme_type_variation = {"primary": &"AccentButton", "go": &"GoButton", "danger": &"DangerButton"}.get(kind, &"")
	row.add_child(button)
	_buttons[key] = button


# The picture of the selected level: the one on the server for a level that has been published, else none.
func _show_thumbnail(level: Dictionary) -> void:
	var tan_id: int = int(level.get("published_id", 0)) if not level.is_empty() else 0
	_thumb_for = tan_id
	_thumb_request.cancel_request()
	if tan_id <= 0:
		_thumb_frame.visible = false
		return
	if _thumb_cache.has(tan_id):
		_thumb.texture = _thumb_cache[tan_id]
		_thumb_frame.visible = true
		return
	_thumb_frame.visible = false
	_thumb_request.request(THUMBNAIL_URL % tan_id)


func _thumb_received(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.size() < 8 or _thumb_for <= 0:
		return
	var image := Image.new()
	var error := image.load_png_from_buffer(body) if body.slice(0, 4) == PackedByteArray([0x89, 0x50, 0x4E, 0x47]) else image.load_jpg_from_buffer(body)
	if error != OK:
		return
	var texture := ImageTexture.create_from_image(image)
	_thumb_cache[_thumb_for] = texture
	_thumb.texture = texture
	_thumb_frame.visible = true


func _new() -> void:
	_name_mode = "new"
	_name_dialog.title = "New level"
	_name_edit.text = ""
	_description_edit.text = ""
	_name_dialog.popup_centered()
	_name_edit.grab_focus()


func _rename() -> void:
	var level := CreativeStore.get_level(_selected_id())
	if level.is_empty():
		return
	_name_mode = "rename"
	_name_dialog.title = "Rename level"
	_name_edit.text = level.name
	_description_edit.text = level.description
	_name_dialog.popup_centered()
	_name_edit.grab_focus()
	_name_edit.select_all()


func _name_confirmed() -> void:
	var level_name := _name_edit.text.strip_edges()
	if level_name.is_empty():
		return
	if _name_mode == "new":
		var id := CreativeStore.create(level_name)
		CreativeStore.rename(id, level_name, _description_edit.text.strip_edges())
		_reload(id)
	elif _name_mode == "rename":
		var id := _selected_id()
		CreativeStore.rename(id, level_name, _description_edit.text.strip_edges())
		_reload(id)
	_name_mode = ""


func _copy() -> void:
	var id := CreativeStore.copy_level(_selected_id())
	if not id.is_empty():
		_reload(id)


func _confirm_delete() -> void:
	var level := CreativeStore.get_level(_selected_id())
	if level.is_empty():
		return
	_delete_dialog.title = "Delete level"
	_delete_dialog.dialog_text = "Delete \"%s\"? This can't be undone." % level.name
	_delete_dialog.popup_centered()


func _delete() -> void:
	var id := _selected_id()
	var index := _list.get_selected_items()[0] if not _list.get_selected_items().is_empty() else 0
	CreativeStore.delete(id)
	# Land on a neighbour instead of jumping back to the top.
	var remaining := CreativeStore.list()
	_reload(remaining[clampi(index, 0, remaining.size() - 1)].local_id if not remaining.is_empty() else "")


# The menu's host_started handler carries on into match.tscn, same as Build.
func _edit() -> void:
	var id := _selected_id()
	if not id.is_empty():
		CreativeEditor.start_session(id)


# What to call a level that has a server record. Only a state the server itself reported is shown as fact;
# anything else says it hasn't been checked, so a stale label can't pass for the truth.
func _status_word(level: Dictionary) -> String:
	var published_by := int(level.get("published_by", 0))
	if published_by != 0 and published_by != UserData.user_id:
		return "Published from another login"
	if _checking:
		return "Checking the server..."
	if not _verified:
		return "Not checked yet - press Check server"
	match str(level.get("server_state", "")):
		"Pending":
			return "Waiting for approval"
		"Rejected":
			return "Rejected"
		"Published":
			return "Published"
		_:
			return "Not checked yet - press Check server"


func _say(message: String) -> void:
	_feedback.text = message


func _set_busy(busy: bool, message: String = "") -> void:
	_busy = busy
	if not message.is_empty():
		_say(message)
	_refresh_details()


# Publish / Update: checks what can be checked here, then asks for the genre.
func _publish() -> void:
	var level := CreativeStore.get_level(_selected_id())
	if level.is_empty() or _busy:
		return
	if not CreativeApi.logged_in():
		_say("Log in to publish levels.")
		return
	var content: Dictionary = level.content
	if content.surfaces.is_empty() and content.pieces.is_empty():
		_say("Add something to build on before publishing.")
		return
	_genre_pick.select(maxi(0, CreativeApi.GENRES.find(str(level.get("genre", ""))) + 1))
	_publish_dialog.title = "Update on the server" if level.published_id > 0 else "Publish level"
	_publish_dialog.get_ok_button().disabled = _genre_pick.selected <= 0
	_publish_dialog.reset_size()
	_publish_dialog.popup_centered()


func _send_publish() -> void:
	var id := _selected_id()
	var level := CreativeStore.get_level(id)
	if level.is_empty() or _busy or _genre_pick.selected <= 0:
		return
	var genre: String = CreativeApi.GENRES[_genre_pick.selected - 1]
	CreativeStore.set_genre(id, genre)
	var content: Dictionary = level.content
	content["genre"] = genre   # the boundary's height depends on it
	# Published from another login on this machine: not this player's record, so it goes up as their own (the
	# server updates their existing level of the same name rather than making a copy).
	var published_by := int(level.get("published_by", 0))
	var server_id: int = level.published_id if published_by == 0 or published_by == UserData.user_id else 0
	_set_busy(true, "Drawing the picture...")
	var fields := {
		"level_name": level.name,
		"description": level.description,
		"genre": genre,
		"tan_id": server_id,
		"local_id": id,
		"content": JSON.stringify(content),
	}
	# The level's picture for the Create Game list. Nothing hangs on it: no picture just means a blank frame there.
	var picture: Image = await CreativeThumbnail.render(self, content)
	if picture:
		fields["thumbnail"] = Marshalls.raw_to_base64(picture.save_png_to_buffer())
	_set_busy(true, "Publishing...")
	var result := await CreativeApi.request(self, "publishLevel", fields)
	if result.ok and CreativeStore.has_level(id):
		CreativeStore.set_published(id, int(result.body.get("tan_id", 0)), UserData.user_id)
		_thumb_cache.erase(int(result.body.get("tan_id", 0)))   # the picture was replaced
	_busy = false
	_reload(id)
	_say(result.message)


func _confirm_unpublish() -> void:
	var level := CreativeStore.get_level(_selected_id())
	if level.is_empty():
		return
	_unpublish_dialog.title = "Remove from server"
	_unpublish_dialog.dialog_text = "Remove \"%s\" from the server? Your copy here stays." % level.name
	_unpublish_dialog.popup_centered()


func _unpublish() -> void:
	var id := _selected_id()
	var level := CreativeStore.get_level(id)
	if level.is_empty() or _busy:
		return
	_set_busy(true, "Removing...")
	var result := await CreativeApi.request(self, "deleteLevel", {"tan_id": level.published_id})
	if result.ok and CreativeStore.has_level(id):
		CreativeStore.clear_published(id)
	_busy = false
	_reload(id)
	_say(result.message)


# The server is the one truth about what is published (tanarusmaps.ID, kept here as published_id). This brings its
# verdict (approved, rejected and why) into the local records. The server also keeps each level's own id here
# (tan_local), so a level whose link was lost, say after a login switch or a reset, is found again instead of
# being published twice. A level the server no longer has goes back to unpublished. A level published from
# another login can't be seen from this one, so it is left alone but labelled as such. Anything that stops the
# check (not logged in, no connection) is said out loud rather than leaving an old label to pass for current.
func _sync_with_server() -> void:
	if _busy or _checking:
		return
	var any_published := false
	for header in CreativeStore.list():
		any_published = any_published or header.published_id > 0
	_verified = false
	if not CreativeApi.logged_in():
		if any_published:
			_say("Log in to check the status of your published levels.")
		_reload()
		return
	_checking = true
	_say("Checking the server...")
	_reload()
	var result := await CreativeApi.request(self, "getMyLevels")
	_checking = false
	if not result.ok:
		_say("Could not check the server: %s" % result.message)
		_reload()
		return
	var on_server := {}
	var by_local := {}
	for row in result.body.get("data", []):
		on_server[int(row.tan_id)] = row
		if row.get("tan_local") != null and not str(row.tan_local).is_empty():
			by_local[str(row.tan_local)] = row
	var gone := 0
	var relinked := 0
	for header in CreativeStore.list():
		# The server holds this very level under another id: that record is the truth.
		if by_local.has(header.local_id) and int(by_local[header.local_id].tan_id) != int(header.published_id):
			var found: Dictionary = by_local[header.local_id]
			CreativeStore.set_published(header.local_id, int(found.tan_id), UserData.user_id)
			_apply_server_row(header.local_id, found)
			relinked += 1
			continue
		var published_by := int(header.get("published_by", 0))
		if int(header.published_id) <= 0 or (published_by != 0 and published_by != UserData.user_id):
			continue
		if on_server.has(int(header.published_id)):
			_apply_server_row(header.local_id, on_server[int(header.published_id)])
		else:
			CreativeStore.clear_published(header.local_id)
			gone += 1
	var notes: Array[String] = []
	if gone > 0:
		notes.append("%d level(s) are no longer on the server and are unpublished here." % gone)
	if relinked > 0:
		notes.append("%d level(s) were re-linked to their copy on the server." % relinked)
	_verified = true
	_verified_at = Time.get_ticks_msec()
	_say("\n".join(notes))
	_reload()


func _apply_server_row(local_id: String, row: Dictionary) -> void:
	var note: Variant = row.get("tan_reject_note")
	CreativeStore.set_server_state(local_id, str(row.state), "" if note == null else str(note))

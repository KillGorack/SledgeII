class_name CreativeStore

# The local database of levels a player has made: one file holding a record per
# level. Everything that lists, opens, renames, copies or deletes a level goes
# through here, so the storage can change (a real database, a file per level)
# without the UI knowing.
#
# A record:
#   local_id            made here, never changes, never leaves this machine
#   name, description   what the player calls it
#   genre               one of CreativeApi.GENRES, "" until chosen (required to publish)
#   created, updated    unix seconds
#   published_id        the server's game_creative_levels.ID, 0 = never published
#   published_revision  the revision last sent, 0 = never
#   published_by        the user id that published it (levels are only synced for that user)
#   server_state        what the server says: Pending, Published or Rejected ("" = never published)
#   reject_note         the reason, when the server says Rejected
#   dirty               changed since it was last published
#   imported_from       where it came from, e.g. "gcl:4" (old server level)
#   content             the CreativeLevel data
#
# Records handed out by get_level() are the live ones: edit `content` in place
# and call update_content() to stamp and save it.

const PATH := "user://creative_levels.json"
const FORMAT := 1

static var _levels: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if parsed is Dictionary and parsed.get("levels") is Dictionary:
		_levels = parsed.levels
		# Levels saved before objects had a team colour use one id per colour (base_pad_red...).
		# The editor and the builder work on this content as it is, so bring it up to date here.
		for level in _levels.values():
			# JSON reads every number back as a float (291.0). Ids and times are whole numbers, and a float id is
			# a different Dictionary key from the int one the server's rows are filed under, so a published level
			# looked missing from the server on the first check after every start. Keep them ints.
			for key in ["published_id", "published_by", "published_revision", "created", "updated"]:
				if level.has(key) and (level[key] is float or level[key] is int):
					level[key] = int(level[key])
			var content: Variant = level.get("content")
			if content is Dictionary and content.get("objects") is Array:
				content["objects"] = CreativeLevel.sanitize({"objects": content.objects}).objects


# Headers only (no content), most recently changed first.
static func list() -> Array[Dictionary]:
	_ensure_loaded()
	var headers: Array[Dictionary] = []
	for id in _levels:
		var header: Dictionary = (_levels[id] as Dictionary).duplicate()
		var content: Dictionary = header.get("content", {})
		header.erase("content")
		header["surfaces"] = content.get("surfaces", []).size()
		header["pieces"] = content.get("pieces", []).size()
		header["objects"] = content.get("objects", []).size()
		headers.append(header)
	headers.sort_custom(func(a, b): return a.updated > b.updated)
	return headers


static func get_level(local_id: String) -> Dictionary:
	_ensure_loaded()
	return _levels.get(local_id, {})


static func has_level(local_id: String) -> bool:
	_ensure_loaded()
	return _levels.has(local_id)


# Returns the new record's local_id. `content` is sanitized; empty = the starter level.
static func create(level_name: String, content: Dictionary = {}, imported_from: String = "") -> String:
	_ensure_loaded()
	var id := Crypto.new().generate_random_bytes(8).hex_encode()
	level_name = level_name.strip_edges().left(CreativeLevel.MAX_NAME_LENGTH)
	if level_name.is_empty():
		level_name = "Untitled"
	var level := CreativeLevel.starter(level_name) if content.is_empty() else CreativeLevel.sanitize(content)
	level["name"] = level_name
	var now := int(Time.get_unix_time_from_system())
	_levels[id] = {
		"local_id": id,
		"name": level_name,
		"description": "",
		"genre": "",
		"created": now,
		"updated": now,
		"published_id": 0,
		"published_revision": 0,
		"dirty": false,
		"imported_from": imported_from,
		"content": level,
	}
	_save()
	return id


static func update_content(local_id: String) -> bool:
	var level := get_level(local_id)
	if level.is_empty():
		return false
	level["updated"] = int(Time.get_unix_time_from_system())
	level["dirty"] = level.published_id > 0
	return _save()


static func rename(local_id: String, new_name: String, description: String = "") -> bool:
	var level := get_level(local_id)
	new_name = new_name.strip_edges().left(CreativeLevel.MAX_NAME_LENGTH)
	if level.is_empty() or new_name.is_empty():
		return false
	level["name"] = new_name
	level["content"]["name"] = new_name
	level["description"] = description
	level["updated"] = int(Time.get_unix_time_from_system())
	level["dirty"] = level.published_id > 0
	return _save()


# The server accepted it (publishLevel). The server now holds this version, and a new publish is always Pending.
static func set_published(local_id: String, server_id: int, user_id: int) -> bool:
	var level := get_level(local_id)
	if level.is_empty():
		return false
	level["published_id"] = server_id
	level["published_revision"] = int(level.get("published_revision", 0)) + 1
	level["published_by"] = user_id
	level["server_state"] = "Pending"
	level["reject_note"] = ""
	level["dirty"] = false
	return _save()


# What the server last said about this level. Leaves `updated` and `dirty` alone: nothing here was edited.
static func set_server_state(local_id: String, state: String, note: String) -> bool:
	var level := get_level(local_id)
	if level.is_empty() or (level.get("server_state", "") == state and level.get("reject_note", "") == note):
		return false
	level["server_state"] = state
	level["reject_note"] = note
	return _save()


# Forget the server copy (removed there, by the player or by an administrator). The level itself stays.
static func clear_published(local_id: String) -> bool:
	var level := get_level(local_id)
	if level.is_empty():
		return false
	level["published_id"] = 0
	level["published_by"] = 0
	level["server_state"] = ""
	level["reject_note"] = ""
	level["dirty"] = false
	return _save()


static func set_genre(local_id: String, genre: String) -> bool:
	var level := get_level(local_id)
	if level.is_empty() or level.get("genre", "") == genre:
		return false
	level["genre"] = genre
	return _save()


# A copy is a new, unpublished level of its own.
static func copy_level(local_id: String) -> String:
	var level := get_level(local_id)
	if level.is_empty():
		return ""
	var copy_id := create("%s copy" % level.name, level.content.duplicate(true))
	_levels[copy_id]["description"] = level.description
	_levels[copy_id]["genre"] = level.get("genre", "")
	_save()
	return copy_id


static func delete(local_id: String) -> bool:
	_ensure_loaded()
	if not _levels.erase(local_id):
		return false
	return _save()


# The record that was imported from `source`, or "" (stops an import running twice).
static func find_imported(source: String) -> String:
	_ensure_loaded()
	for id in _levels:
		if _levels[id].get("imported_from", "") == source:
			return id
	return ""


# Written next to the real file then renamed over it, so a crash mid-write
# can't leave a half-written database.
static func _save() -> bool:
	var temp_path := PATH + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if not file:
		push_warning("CreativeStore: could not write %s" % temp_path)
		return false
	file.store_string(JSON.stringify({"format": FORMAT, "levels": _levels}))
	file.close()
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(PATH))
	if err != OK:
		push_warning("CreativeStore: could not replace %s (%s)" % [PATH, error_string(err)])
	return err == OK

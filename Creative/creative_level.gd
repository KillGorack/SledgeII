class_name CreativeLevel

# The data format for a community level, shared by the editor (writes it) and
# CreativeLevelBuilder (reads it). Plain JSON-able Dictionaries so it can be
# stored as the level's file on the server. Vectors are arrays, rotations are
# degrees.
#
#   {
#     "version": 1,
#     "name": "My level",
#     "ground": {"m": "turf", "size": 500},      (optional; omit for no ground)
#     "surfaces": [ {"m": "stones", "p": [x,y,z], "r": [x,y,z], "s": [w,h]} ],
#     "pieces":   [ {"id": "ramp_1x3", "m": "stones", "p": [x,y,z], "r": [x,y,z]} ],
#     "environment": {"sun": 0.8, "saturation": 1.1},   (optional multipliers, see ENVIRONMENT)
#     "objects":  [ {"id": "spawn", "p": [x,y,z], "r": [x,y,z]} ]   (+ "t": team on pads, turrets, recons)
#   }
#
# As in the old game, a surface is a flat w x h quad standing upright with its
# origin at the bottom-left corner (it extends along +X and +Y), and "p" is
# that corner. Rotate it to make floors, ceilings and walls (a floor facing up
# is r = [-90, 0, 0]).
#
# Levels come from other players, so sanitize() is the gate: whatever it
# returns is safe to build, and anything it can't make sense of is dropped
# rather than erroring. The server is meant to run the same limits.

const VERSION := 1
const MAX_SURFACES := 40000
const MAX_PIECES := 40000
const MAX_OBJECTS := 2000
const MAX_NAME_LENGTH := 40
const MIN_SURFACE_SIZE := 1.0
const MAX_SURFACE_SIZE := 256.0
const MAX_COORD := 20000.0

# The genre a level was published under (the site's tan_genre). A Force level gets a tall boundary; the game
# stamps it into the data when you test or publish, and the server stamps the one it validated.
const FORCE_GENRE := "Force"
# The site's tan_genre options, by name. A level must have one to be published (the server checks the name).
const GENRES: Array[String] = ["10vs10", "Duel", "Force", "League", "Other", "Phoenix", "Regular"]

# The look of the level, edited with the Environment tool. Every value is a multiplier on the shared
# environment (Materials/Environments/env.tscn), so 1.0 is exactly the look every map has today. Time of
# day is not here: whoever hosts picks that. Only values other than 1.0 are stored.
const ENVIRONMENT := {
	"sun": {"name": "Sun strength", "min": 0.0, "max": 2.5},
	"ambient": {"name": "Ambient light", "min": 0.0, "max": 3.0},
	"brightness": {"name": "Brightness", "min": 0.5, "max": 1.5},
	"contrast": {"name": "Contrast", "min": 0.5, "max": 1.5},
	"saturation": {"name": "Saturation", "min": 0.0, "max": 2.0},
	"fog": {"name": "Fog", "min": 0.0, "max": 4.0},
	"glow": {"name": "Glow", "min": 0.0, "max": 3.0},
}


static func empty(level_name: String = "") -> Dictionary:
	return {"version": VERSION, "name": level_name, "ground": {}, "surfaces": [], "pieces": [], "objects": [], "environment": {}}


# What a brand new level starts as: a floor and a base pad per side, so there
# is somewhere to stand and the editor has something to build from.
static func starter(level_name: String) -> Dictionary:
	var data := empty(level_name)
	data.ground = default_ground()
	data.objects.append({"id": "spawn", "p": [0.0, 0.0, 0.0], "r": [0.0, 0.0, 0.0]})
	return data


static func default_ground() -> Dictionary:
	return {"m": String(CreativeCatalog.GROUND_MATERIAL_ID), "size": 500.0}


static func parse(json_text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(json_text)
	if not data is Dictionary:
		return {}
	return sanitize(data)


static func sanitize(data: Dictionary) -> Dictionary:
	var clean := empty(str(data.get("name", "")).left(MAX_NAME_LENGTH))
	var ground: Variant = data.get("ground", {})
	if ground is Dictionary and not ground.is_empty():
		var size: Variant = ground.get("size", 500.0)
		clean.ground = {
			"m": String(CreativeCatalog.GROUND_MATERIAL_ID) if not CreativeCatalog.has_material(StringName(str(ground.get("m", "")))) else str(ground.m),
			"size": clampf(float(size) if size is float or size is int else 500.0, 16.0, 2000.0),
		}
	var genre := str(data.get("genre", ""))
	if genre in GENRES:
		clean["genre"] = genre
	var environment: Variant = data.get("environment", {})
	if environment is Dictionary:
		for key in ENVIRONMENT:
			var value: Variant = environment.get(key)
			if (value is float or value is int) and is_finite(value):
				value = snappedf(clampf(value, ENVIRONMENT[key].min, ENVIRONMENT[key].max), 0.01)
				if not is_equal_approx(value, 1.0):
					clean.environment[key] = value
	var surfaces: Variant = data.get("surfaces", [])
	if surfaces is Array:
		for entry in surfaces:
			if clean.surfaces.size() >= MAX_SURFACES:
				break
			var surface := _clean_surface(entry)
			if not surface.is_empty():
				clean.surfaces.append(surface)
	var pieces: Variant = data.get("pieces", [])
	if pieces is Array:
		for entry in pieces:
			if clean.pieces.size() >= MAX_PIECES:
				break
			var piece := _clean_piece(entry)
			if not piece.is_empty():
				clean.pieces.append(piece)
	var objects: Variant = data.get("objects", [])
	if objects is Array:
		for entry in objects:
			if clean.objects.size() >= MAX_OBJECTS:
				break
			var object := _clean_object(entry)
			if not object.is_empty():
				clean.objects.append(object)
	return clean


static func _clean_surface(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {}
	var size := _vec(entry.get("s"), 2)
	var pos := _vec(entry.get("p"), 3)
	if size.is_empty() or pos.is_empty():
		return {}
	var material := StringName(str(entry.get("m", "")))
	if not CreativeCatalog.has_material(material):
		material = CreativeCatalog.DEFAULT_MATERIAL_ID
	var rot := _vec(entry.get("r"), 3)
	return {
		"m": String(material),
		"p": _clamp_all(pos, -MAX_COORD, MAX_COORD),
		"r": _wrap_degrees(rot if not rot.is_empty() else [0.0, 0.0, 0.0]),
		"s": _clamp_all(size, MIN_SURFACE_SIZE, MAX_SURFACE_SIZE).map(func(v): return roundf(v)),
	}


static func _clean_piece(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {}
	var id := StringName(str(entry.get("id", "")))
	var pos := _vec(entry.get("p"), 3)
	if not CreativeCatalog.has_piece(id) or pos.is_empty():
		return {}
	var material := StringName(str(entry.get("m", "")))
	if not CreativeCatalog.has_material(material):
		material = CreativeCatalog.DEFAULT_MATERIAL_ID
	var rot := _vec(entry.get("r"), 3)
	return {
		"id": String(id),
		"m": String(material),
		"p": _clamp_all(pos, -MAX_COORD, MAX_COORD),
		"r": _wrap_degrees(rot if not rot.is_empty() else [0.0, 0.0, 0.0]),
	}


static func _clean_object(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {}
	var id := StringName(str(entry.get("id", "")))
	var team: Variant = entry.get("t")
	if CreativeCatalog.LEGACY_OBJECTS.has(id):
		team = CreativeCatalog.LEGACY_OBJECTS[id][1]
		id = CreativeCatalog.LEGACY_OBJECTS[id][0]
	var pos := _vec(entry.get("p"), 3)
	if not CreativeCatalog.has_object(id) or pos.is_empty():
		return {}
	var rot := _vec(entry.get("r"), 3)
	var clean := {
		"id": String(id),
		"p": _clamp_all(pos, -MAX_COORD, MAX_COORD),
		"r": _wrap_degrees(rot if not rot.is_empty() else [0.0, 0.0, 0.0]),
	}
	if CreativeCatalog.has_teams(id):
		clean["t"] = String(CreativeCatalog.object_team(id, team))
	return clean


# A number array of exactly `count` finite values, or [] if it isn't one.
static func _vec(value: Variant, count: int) -> Array:
	if not value is Array or value.size() != count:
		return []
	var out := []
	for component in value:
		if not (component is float or component is int) or is_nan(component) or is_inf(component):
			return []
		out.append(float(component))
	return out


static func _clamp_all(values: Array, low: float, high: float) -> Array:
	return values.map(func(v): return clampf(v, low, high))


static func _wrap_degrees(values: Array) -> Array:
	return values.map(func(v): return fposmod(v + 180.0, 360.0) - 180.0)

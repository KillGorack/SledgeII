class_name CreativeImport

# Converts levels saved by the old game (a "creative_items" list of resource
# paths, game_creative_levels.gcl_content on the server) into CreativeLevel
# data. The two share geometry and conventions (corner origin, degree Euler
# rotations, whole-metre sizes), so positions and rotations carry over as is;
# only the way things are named changes.

# Old creative setting file (basename) -> a building piece, or an object id.
const PIECE_IDS := {
	"builder_ramp_three": &"ramp_1x3",
	"builder_ramp_three_sides": &"ramp_1x3_side",
}
const OBJECT_IDS := {
	"player_spawn": &"spawn",
	"recon_station": &"recon",
	"Spawner": &"spawner_enemy",
	"Friendly_Turret": &"turret_friendly",
	"Enemy_Turret": &"turret_enemy",
	"Fire_Pot": &"fire_pot",
	"Tornado": &"tornado",
	"Tree_Oak": &"tree_oak",
	"Tree_Poplar": &"tree_poplar",
	"Wall_Light": &"wall_light",
	"Wall_Art": &"wall_art",
	"Wall_Art2": &"wall_art",
}


# `raw` is the stored text, which may be HTML-escaped (the server stores it
# that way). Returns {level, skipped} where skipped counts unknown items.
static func from_old_text(raw: String, level_name: String) -> Dictionary:
	var text := raw.strip_edges()
	if text.begins_with("{&quot;"):
		text = text.replace("&quot;", "\"").replace("&#039;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
	var old: Variant = JSON.parse_string(text)
	if not old is Dictionary or not old.get("creative_items") is Array:
		return {}
	var level := CreativeLevel.empty(level_name)
	# The old game's creative space always had this ground under everything.
	level.ground = CreativeLevel.default_ground()
	var skipped := 0
	for item in old.creative_items:
		if not _convert_item(item, level):
			skipped += 1
	return {"level": CreativeLevel.sanitize(level), "skipped": skipped}


static func _convert_item(item: Variant, level: Dictionary) -> bool:
	if not item is Dictionary or not item.get("position") is Dictionary:
		return false
	var setting: String = str(item.get("setting_file", "")).get_file().get_basename()
	var pos: Dictionary = item.position
	var rot: Dictionary = item.get("rotation", {})
	var entry := {
		"p": [pos.get("x", 0.0), pos.get("y", 0.0), pos.get("z", 0.0)],
		"r": [rot.get("x", 0.0), rot.get("y", 0.0), rot.get("z", 0.0)],
	}
	if setting == "builder_surface":
		var dims: Dictionary = item.get("surface_dimensions", {})
		entry["s"] = [dims.get("width", 1.0), dims.get("height", 1.0)]
		entry["m"] = _material_id(item)
		level.surfaces.append(entry)
	elif PIECE_IDS.has(setting):
		entry["id"] = String(PIECE_IDS[setting])
		entry["m"] = _material_id(item)
		level.pieces.append(entry)
	elif OBJECT_IDS.has(setting):
		entry["id"] = String(OBJECT_IDS[setting])
		level.objects.append(entry)
	else:
		return false
	return true


# "res://materials/walls/Deco Block.tres" -> deco_block; "texture:...Standard.png"
# -> standard; no material at all means the old default, standard.
static func _material_id(item: Dictionary) -> String:
	var path: String = str(item.get("applied_materials", {}).get("material", ""))
	var id := path.get_file().get_basename().to_lower().replace(" ", "_")
	return id if CreativeCatalog.has_material(StringName(id)) else String(CreativeCatalog.DEFAULT_MATERIAL_ID)

class_name CraftCatalog

const DEFAULT_ID := &"lightning"
const DEFS: Array[CraftDef] = [
	preload("res://Crafts/Defs/lightning.tres"),
	preload("res://Crafts/Defs/vanguard.tres"),
	preload("res://Crafts/Defs/chameleon.tres"),
	preload("res://Crafts/Defs/devastator.tres"),
]


# Unknown ids (a stale or tampered request) fall back to the default rather than
# failing - the server is the one that decides what actually spawns.
static func get_def(id: StringName) -> CraftDef:
	for def in DEFS:
		if def.id == id:
			return def
	return get_def(DEFAULT_ID) if id != DEFAULT_ID else DEFS[0]


static func has_id(id: StringName) -> bool:
	for def in DEFS:
		if def.id == id:
			return true
	return false

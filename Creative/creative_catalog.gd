class_name CreativeCatalog

# Everything a community level can reference. Level data stores these string
# ids and never a resource path, so a level survives files being moved and a
# tampered level can't make a client load an arbitrary resource.
#
# Ids are permanent once a level has been published with them: add new ones,
# don't rename or remove.

const DEFAULT_MATERIAL_ID := &"standard"
# Order here is the order of the editor's material list (same as the old game).
const MATERIALS := {
	&"standard": preload("res://Materials/Creative/standard/standard.tres"),
	&"sandwich_block": preload("res://Materials/Creative/walls/sandwich_block.tres"),
	&"brick_house": preload("res://Materials/Creative/walls/brick_house.tres"),
	&"brick_house_muted": preload("res://Materials/Creative/walls/brick_house_muted.tres"),
	&"mosaic": preload("res://Materials/Creative/walls/mosaic.tres"),
	&"deco_block": preload("res://Materials/Creative/walls/deco_block.tres"),
	&"terracotta": preload("res://Materials/Creative/roof/terracotta.tres"),
	&"hex_pavers": preload("res://Materials/Creative/floors/hex_pavers.tres"),
	&"marble_tile_dark": preload("res://Materials/Creative/floors/marble_tile_dark.tres"),
	&"marble_tile_light": preload("res://Materials/Creative/floors/marble_tile_light.tres"),
	&"sand_dark": preload("res://Materials/Creative/floors/sand_dark.tres"),
	&"sand_light": preload("res://Materials/Creative/floors/sand_light.tres"),
	&"stones": preload("res://Materials/Creative/floors/stones.tres"),
	&"ceiling": preload("res://Materials/Creative/ceilings/ceiling.tres"),
	&"ceiling_lighted": preload("res://Materials/Creative/ceilings/ceiling_lighted.tres"),
	&"glitz_blue": preload("res://Materials/Creative/base_colors/glitz_blue.tres"),
	&"glitz_green": preload("res://Materials/Creative/base_colors/glitz_green.tres"),
	&"glitz_red": preload("res://Materials/Creative/base_colors/glitz_red.tres"),
	&"glitz_white": preload("res://Materials/Creative/base_colors/glitz_white.tres"),
	&"glass_white": preload("res://Materials/Creative/base_colors/glass_white.tres"),
	&"chrome": preload("res://Materials/Creative/base_colors/chrome.tres"),
	&"turf": preload("res://Materials/Creative/floors/turf.tres"),
	&"cartoon_brick": preload("res://Materials/Creative/walls/cartoon_brick.tres"),
	&"steel_plate": preload("res://Materials/Creative/walls/steel_plate.tres"),
	&"stone_deco_tile": preload("res://Materials/Creative/walls/stone_deco_tile.tres"),
	&"stone_deco_tile_b": preload("res://Materials/Creative/walls/stone_deco_tile_b.tres"),
	&"sandwich_old_school": preload("res://Materials/Creative/walls/sandwich_old_school.tres"),
	&"sandwich_v4": preload("res://Materials/Creative/walls/sandwich_v4.tres"),
	&"sandwich_v3": preload("res://Materials/Creative/walls/sandwich_v3.tres"),
	&"ofsz": preload("res://Materials/Creative/walls/ofsz.tres"),
	&"ofsz_2": preload("res://Materials/Creative/walls/ofsz_2.tres"),
	&"block_wall": preload("res://Materials/Creative/walls/block_wall.tres"),
	&"block_wall_b": preload("res://Materials/Creative/walls/block_wall_b.tres"),
	&"perblock": preload("res://Materials/Creative/walls/perblock.tres"),
	&"perblock_red": preload("res://Materials/Creative/walls/perblock_red.tres"),
	&"lattice": preload("res://Materials/Creative/walls/lattice.tres"),
	&"ott": preload("res://Materials/Creative/walls/ott.tres"),
	&"eddie_blanket": preload("res://Materials/Creative/walls/eddie_blanket.tres"),
	&"mosaic_a": preload("res://Materials/Creative/walls/mosaic_a.tres"),
	&"mosaic_b": preload("res://Materials/Creative/walls/mosaic_b.tres"),
	&"hex_paver_b": preload("res://Materials/Creative/floors/hex_paver_b.tres"),
	&"dirt": preload("res://Materials/Creative/floors/dirt.tres"),
	&"grass_02": preload("res://Materials/Creative/floors/grass_02.tres"),
	&"water": preload("res://Materials/Creative/floors/water.tres"),
}

# The ground every level can have under it, as in the old game's creative space.
const GROUND_MATERIAL_ID := &"turf"
const GROUND_SIZES := [250.0, 500.0, 1000.0]

# Fixed-shape building pieces, besides the resizable surface. "points" are the
# corners of one flat face in the piece's own space (origin at a corner, and
# offset exactly as the old game's scenes had them, so old levels line up), "faces" index into them as triangles. Each piece is built
# double-sided and gets a thin solid collider behind it.
const PIECES := {
	&"ramp_1x3": {
		"name": "Ramp 1x3",
		"icon": preload("res://Creative/icons/ramp3.png"),
		"points": [Vector3(0, -1, -3), Vector3(1, -1, -3), Vector3(1, 0, 0), Vector3(0, 0, 0)],
		"faces": [0, 1, 2, 2, 3, 0],
	},
	# Just the triangular side wall of a ramp; rotate it to close either side.
	&"ramp_1x3_side": {
		"name": "Ramp side",
		"icon": preload("res://Creative/icons/ramp3.png"),
		"points": [Vector3(0, 0, -3), Vector3(0, 1, 0), Vector3(0, 0, 0)],
		"faces": [0, 1, 2],
		# Texture straight (along the ground, top of the texture up), not along the
		# sloped edge. Texture v runs downward, hence the -Y.
		"uv_axes": [Vector3(0, 0, 1), Vector3(0, -1, 0)],
	},
}

# Placeable objects other than building pieces. "kind" picks how
# CreativeLevelBuilder makes the node; "group" is the group match.gd looks the
# node up by (see match.gd BASE_PAD_GROUPS / "recon_locations" / "PlayerSpawn").
# "anchor": where the object's origin is, as in the old game: "base" (the
# default) = on the ground, "center" = middle of a one-metre cell, e.g. turrets.
# "offset": added to the aimed spot when placing (the old settings'
# instantiation_translation); default half a cell in X and Z, to the cell centre.
# A "pad" is flat and visual only (no collision), with its origin at a corner:
# it extends 7 m along +X and +Z from where it is placed. "color" is its shiny
# paint and the colour of its icon.
# "decor" objects are the real thing, visual only (no collision): "scene" is
# built where the object is placed, with its origin on the ground. "color" is
# the colour of its icon.
# "hidden" objects are not offered in the editor (they still load, and can be removed).
# "teams": the team colours (TEAMS) the object can have, set when placing and stored as "t" on the entry;
# "team_default" is used when it is missing. A pad's "group" is a prefix: base_pad_ + the team.
# A "turret" is a real Sentry (Game_Objects/_scripts/sentry.gd) on its team: it shoots that team's enemies.
# A "tornado" (Game_Objects/_scripts/tornado.gd) roams the level while it is played and stays where it was placed while building.
# "snap": "cell" puts the object in the middle of the one-metre cell aimed at (X and Z), not on a grid line.
# "icon" is the toolbox picture (the old game's round-bezel icons).
# "placeholder" objects are only a coloured cube in the editor so a level can
# mark where a thing goes; they build to nothing when played, until the real
# thing is made.
const TEAMS := {
	&"red": Color(0.9, 0.08, 0.08),
	&"green": Color(0.1, 0.8, 0.2),
	&"blue": Color(0.12, 0.3, 0.95),
	&"gray": Color(0.62, 0.63, 0.66),
	&"neutral": Color(0.3, 0.8, 1.0),   # only a recon has it: not held by anyone, so it can be captured
}

# Objects that used to be one id per colour; old levels still load through this.
const LEGACY_OBJECTS := {
	&"base_pad_red": [&"base_pad", &"red"],
	&"base_pad_green": [&"base_pad", &"green"],
	&"base_pad_blue": [&"base_pad", &"blue"],
	&"base_pad_gray": [&"base_pad", &"gray"],
	&"turret_enemy": [&"turret", &"red"],
	&"turret_friendly": [&"turret", &"green"],
}

# The boulder tool's shapes ("Low Poly Rocks" by para, CC0 - credited in credits.gd), in the order the editor cycles them.
# "normal" is the pack's normal map for that mesh, shrunk to 1024 px (the originals were 4096 px, 50+ MB each).
const BOULDERS := [
	{"name": "Rock C1", "mesh": "res://Models/Decor/Rocks/rock_c_01.obj", "normal": "res://Models/Decor/Rocks/rock_c_01_normal.png"},
	{"name": "Rock D1", "mesh": "res://Models/Decor/Rocks/rock_d_01.obj", "normal": "res://Models/Decor/Rocks/rock_d_01_normal.png"},
	{"name": "Rock D2", "mesh": "res://Models/Decor/Rocks/rock_d_02.obj", "normal": "res://Models/Decor/Rocks/rock_d_02_normal.png"},
	{"name": "Rock D3", "mesh": "res://Models/Decor/Rocks/rock_d_03.obj", "normal": "res://Models/Decor/Rocks/rock_d_03_normal.png"},
	{"name": "Rock D5", "mesh": "res://Models/Decor/Rocks/rock_d_05.obj", "normal": "res://Models/Decor/Rocks/rock_d_05_normal.png"},
	{"name": "Rock D6", "mesh": "res://Models/Decor/Rocks/rock_d_06.obj", "normal": "res://Models/Decor/Rocks/rock_d_06_normal.png"},
]
const MIN_BOULDER_SCALE := 0.5
const MAX_BOULDER_SCALE := 4.0
# How much of a rock's height is buried in the surface it was placed on.
const DEFAULT_BOULDER_SINK := 0.5
const MAX_BOULDER_SINK := 0.9

const OBJECTS := {
	&"base_pad": {"name": "Base pad", "icon": preload("res://Creative/icons/base_pad_gray.png"), "kind": "pad", "teams": [&"red", &"green", &"blue", &"gray"], "team_default": "red", "group": "base_pad_", "offset": Vector3.ZERO},
	&"recon": {"name": "Recon station", "teams": [&"neutral", &"red", &"green", &"blue", &"gray"], "team_default": "neutral", "snap": "cell", "offset": Vector3.ZERO, "icon": preload("res://Creative/icons/recon_station_creative.png"), "kind": "recon"},
	&"spawn": {"hidden": true, "name": "Spawn point", "icon": preload("res://Creative/icons/playerspawn.png"), "kind": "spawn", "group": "PlayerSpawn"},
	&"spawner_enemy": {"hidden": true, "name": "Enemy spawner", "icon": preload("res://Creative/icons/spawner.png"), "kind": "placeholder", "color": Color(0.8, 0.3, 0.6)},
	&"wall_art": {"hidden": true, "name": "Wall art", "icon": preload("res://Creative/icons/wall_art.png"), "kind": "placeholder", "color": Color(0.7, 0.5, 0.9), "anchor": "center", "offset": Vector3.ZERO},
	&"turret": {"name": "Turret", "icon": preload("res://Creative/icons/sentry_enemy.png"), "kind": "turret", "teams": [&"red", &"green", &"blue", &"gray"], "team_default": "red", "anchor": "center", "snap": "cell", "offset": Vector3(0.0, 0.5, 0.0)},
	&"fire_pot": {"name": "Fire pot", "icon": preload("res://Creative/icons/fire_pot.png"), "kind": "decor", "color": Color(1.0, 0.5, 0.1), "scene": preload("res://Creative/Decor/fire_pot.tscn")},
	&"boulder": {"name": "Boulder", "kind": "boulder", "color": Color(0.5, 0.48, 0.45), "offset": Vector3.ZERO, "variants": BOULDERS},
	&"tornado": {"name": "Tornado", "icon": preload("res://Creative/icons/tornado.png"), "kind": "tornado", "color": Color(0.6, 0.6, 0.7), "offset": Vector3.ZERO},
	&"tree_oak": {"name": "Tree", "icon": preload("res://Creative/icons/oak.png"), "kind": "decor", "color": Color(0.2, 0.55, 0.2), "scene": preload("res://Creative/Decor/tree_oak.tscn")},
	&"tree_poplar": {"name": "Evergreen tree", "icon": preload("res://Creative/icons/poplar.png"), "kind": "decor", "color": Color(0.5, 0.7, 0.2), "scene": preload("res://Creative/Decor/tree_poplar.tscn")},
	&"wall_light": {"hidden": true, "name": "Wall light", "icon": preload("res://Creative/icons/wall_light.png"), "kind": "placeholder", "color": Color(1.0, 0.95, 0.6), "anchor": "center", "offset": Vector3.ZERO},
}


static func has_material(id: StringName) -> bool:
	return MATERIALS.has(id)


static func get_material(id: StringName) -> Material:
	return MATERIALS.get(id, MATERIALS[DEFAULT_MATERIAL_ID])


static func has_piece(id: StringName) -> bool:
	return PIECES.has(id)


# The team colour of an object entry (or the default for its kind).
static func object_team(id: StringName, team: Variant) -> StringName:
	var wanted := StringName(str(team))
	return wanted if wanted in OBJECTS[id].get("teams", []) else StringName(OBJECTS[id].get("team_default", "gray"))


static func has_teams(id: StringName) -> bool:
	return OBJECTS[id].has("teams")


static func has_variants(id: StringName) -> bool:
	return OBJECTS[id].has("variants")


# A boulder entry's shape index and size, kept in range whatever the file says.
static func boulder_variant(value: Variant) -> int:
	return clampi(int(value) if (value is float or value is int) else 0, 0, BOULDERS.size() - 1)


static func boulder_sink(value: Variant) -> float:
	return clampf(float(value) if (value is float or value is int) else DEFAULT_BOULDER_SINK, 0.0, MAX_BOULDER_SINK)


static func boulder_scale(value: Variant) -> float:
	return clampf(float(value) if (value is float or value is int) else 1.0, MIN_BOULDER_SCALE, MAX_BOULDER_SCALE)


static func has_object(id: StringName) -> bool:
	return OBJECTS.has(id)


static func object_offset(id: StringName) -> Vector3:
	return OBJECTS[id].get("offset", Vector3(0.5, 0.0, 0.5))


# How far up the editor's marker cube sits so it rests where the real thing will.
static func object_lift(id: StringName) -> float:
	return 0.0 if OBJECTS[id].get("anchor", "base") == "center" else 0.5

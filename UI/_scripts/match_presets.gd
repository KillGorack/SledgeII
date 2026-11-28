extends RefCounted
class_name MatchPresets

# Saved game designs for the host screen: everything on the MATCH SETUP card's three tabs (Rules, Loadout, Drops),
# under a name, kept on this computer only (USER_PATH). The game starts the player off with BUILT_IN below; from then
# on they are the player's to edit and delete. Your team is never part of a preset - it's about you, not the game.
#
# A preset is a "setup" dictionary, the same shape index.gd::_capture_setup writes and _apply_setup reads (and the
# same keys the last-used host settings are saved under):
#   public_game, rockets, recon_capture, day_night,  bool
#   shields, armor                                   (shields/armor missing = on)
#   bots_per_team (a count), bot_skill, drops_level   int - picker indexes (bot_skill: BotBrain.SKILLS,
#                                                     drops_level: LootManager.LOOT_LEVELS)
#   <list>_checked   the ticked ones, for weapons (paths), mines (paths), specials (ids), crafts (ids), loot (paths)
#   <list>_listed    every one the screen showed when it was saved. With it, anything NOT listed (added to the game
#                    since) gets its default. Without it, _checked is exact and everything else is off - that's how
#                    the starting presets say "only these".
#   A list with neither key: every item at its own default.
# A rule key that's missing leaves that control as it is.

const USER_PATH := "user://match_presets.cfg"
const BUILT_IN_ORDER := ["Standard", "Repulsor Wars"]
# The two designs the game ships, exactly as the author saved them (with the *_listed keys, so anything added to the
# game later gets its own default instead of being switched off).
const BUILT_IN := {
	"Standard": {
		"public_game": true,
		"rockets": true,
		"recon_capture": true,
		"day_night": false,
		"shields": true,
		"armor": true,
		"bots_per_team": 5,
		"bot_skill": 1,
		"drops_level": 4,
		"weapons_listed": [
			"res://Weapons/settings/MKI_CEB.tres",
			"res://Weapons/settings/MKII_CEB.tres",
			"res://Weapons/settings/MKIII_CEB.tres",
			"res://Weapons/settings/MKIV_CEB.tres",
			"res://Weapons/settings/basic_cannon.tres",
			"res://Weapons/settings/Detno.tres",
			"res://Weapons/settings/Repulsor.tres",
			"res://Weapons/settings/plasma.tres",
			"res://Weapons/settings/Cleric.tres",
		],
		"weapons_checked": [
			"res://Weapons/settings/MKIII_CEB.tres",
			"res://Weapons/settings/Detno.tres",
			"res://Weapons/settings/Cleric.tres",
		],
		"mines_listed": ["res://Weapons/settings_mines/mine_detno.tres", "res://Weapons/settings_mines/mine_force.tres"],
		"mines_checked": ["res://Weapons/settings_mines/mine_detno.tres"],
		"specials_listed": [&"controller"],
		"specials_checked": [&"controller"],
		"crafts_listed": ["paladin", "aegis"],
		"crafts_checked": ["paladin", "aegis"],
		"loot_listed": [
			"res://Game_Objects/Loot/items/consumables/health_pack.tres",
			"res://Game_Objects/Loot/items/consumables/energy_pack.tres",
			"res://Game_Objects/Loot/items/consumables/juice_pack.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/crit_ball.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/haste.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/ricochet.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/seeker.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/freeze.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/shockwave.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/perfect_shot.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/defence_drain.tres",
			"res://Game_Objects/Loot/items/powerups/craft/fortitude.tres",
			"res://Game_Objects/Loot/items/powerups/craft/bulwark.tres",
			"res://Game_Objects/Loot/items/powerups/craft/power_boost.tres",
			"res://Game_Objects/Loot/items/powerups/craft/agility.tres",
		],
		"loot_checked": [
			"res://Game_Objects/Loot/items/consumables/health_pack.tres",
			"res://Game_Objects/Loot/items/consumables/energy_pack.tres",
			"res://Game_Objects/Loot/items/consumables/juice_pack.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/crit_ball.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/haste.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/ricochet.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/seeker.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/freeze.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/shockwave.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/perfect_shot.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/defence_drain.tres",
			"res://Game_Objects/Loot/items/powerups/craft/fortitude.tres",
			"res://Game_Objects/Loot/items/powerups/craft/bulwark.tres",
			"res://Game_Objects/Loot/items/powerups/craft/power_boost.tres",
			"res://Game_Objects/Loot/items/powerups/craft/agility.tres",
		],
	},
	"Repulsor Wars": {
		"public_game": true,
		"rockets": false,
		"recon_capture": false,
		"day_night": false,
		"shields": false,
		"armor": true,
		"bots_per_team": 5,
		"bot_skill": 1,
		"drops_level": 4,
		"weapons_listed": [
			"res://Weapons/settings/MKI_CEB.tres",
			"res://Weapons/settings/MKII_CEB.tres",
			"res://Weapons/settings/MKIII_CEB.tres",
			"res://Weapons/settings/MKIV_CEB.tres",
			"res://Weapons/settings/basic_cannon.tres",
			"res://Weapons/settings/Detno.tres",
			"res://Weapons/settings/Repulsor.tres",
			"res://Weapons/settings/plasma.tres",
			"res://Weapons/settings/Cleric.tres",
		],
		"weapons_checked": ["res://Weapons/settings/Repulsor.tres"],
		"mines_listed": ["res://Weapons/settings_mines/mine_detno.tres", "res://Weapons/settings_mines/mine_force.tres"],
		"mines_checked": ["res://Weapons/settings_mines/mine_force.tres"],
		"specials_listed": [&"controller"],
		"specials_checked": [],
		"crafts_listed": ["paladin", "aegis"],
		"crafts_checked": ["paladin"],
		"loot_listed": [
			"res://Game_Objects/Loot/items/consumables/health_pack.tres",
			"res://Game_Objects/Loot/items/consumables/energy_pack.tres",
			"res://Game_Objects/Loot/items/consumables/juice_pack.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/crit_ball.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/haste.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/ricochet.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/seeker.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/freeze.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/shockwave.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/perfect_shot.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/defence_drain.tres",
			"res://Game_Objects/Loot/items/powerups/craft/fortitude.tres",
			"res://Game_Objects/Loot/items/powerups/craft/bulwark.tres",
			"res://Game_Objects/Loot/items/powerups/craft/power_boost.tres",
			"res://Game_Objects/Loot/items/powerups/craft/agility.tres",
		],
		"loot_checked": [
			"res://Game_Objects/Loot/items/consumables/health_pack.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/haste.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/ricochet.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/seeker.tres",
			"res://Game_Objects/Loot/items/powerups/weapon/shockwave.tres",
			"res://Game_Objects/Loot/items/powerups/craft/agility.tres",
		],
	},
}


# Every preset, alphabetically. All of them are the player's own: the starting ones (BUILT_IN) are copied into
# USER_PATH the first time - and again whenever the player has deleted them all - so they can be edited and deleted
# like any other.
static func names() -> Array[String]:
	var cfg := _load()
	var out: Array[String] = []
	out.assign(cfg.get_sections())
	out.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	return out


static func exists(preset_name: String) -> bool:
	return _load().has_section(preset_name)


# {} if there is no such preset.
static func get_setup(preset_name: String) -> Dictionary:
	var cfg := _load()
	if not cfg.has_section(preset_name):
		return {}
	var setup := {}
	for key in cfg.get_section_keys(preset_name):
		setup[key] = cfg.get_value(preset_name, key)
	return setup


# Saves, or overwrites, a preset.
static func save(preset_name: String, setup: Dictionary) -> Error:
	if preset_name.strip_edges() == "":
		return ERR_INVALID_PARAMETER
	var cfg := _load()
	if cfg.has_section(preset_name):
		cfg.erase_section(preset_name)
	for key in setup:
		if key != "team":
			cfg.set_value(preset_name, key, setup[key])
	return cfg.save(USER_PATH)


static func delete(preset_name: String) -> Error:
	var cfg := _load()
	if not cfg.has_section(preset_name):
		return ERR_DOES_NOT_EXIST
	cfg.erase_section(preset_name)
	return cfg.save(USER_PATH)


# The player's presets, with the starting ones put in when there are none.
static func _load() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(USER_PATH) # missing is fine: seeded below
	if cfg.get_sections().is_empty():
		for preset_name in BUILT_IN_ORDER:
			var setup: Dictionary = BUILT_IN[preset_name]
			for key in setup:
				cfg.set_value(preset_name, key, setup[key])
		cfg.save(USER_PATH)
	return cfg

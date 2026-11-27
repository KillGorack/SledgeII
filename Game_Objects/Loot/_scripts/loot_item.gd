extends Resource
class_name LootItem

# The base of everything that can drop: what it looks like, how often it drops and when it is allowed to.
# NEVER mutated at runtime - anything that changes while playing lives on the craft or the pickup.
#
# Three kinds, one per way an item behaves (each overrides apply_to):
#   Consumable    - instant, used up on pickup (health, energy, juice)
#   Powerup       - timed, a list of stat changes for `duration` seconds
#   WeaponPickup  - kept until the craft is destroyed
#
# Items are identified over the network by their resource_path, so every item is its own .tres file.

const SHEET := preload("res://Game_Objects/Powerups/Spritesheets/POWERUPS.png")
const FRAME_SIZE := 256
const FRAME_COUNT := 16
const SPIN_FPS := 17.0

# What the match must have for an item to be worth dropping (see is_available).
#   POWER   a weapon in the loadout uses power
#   RECONS  recons can be captured (the host's Recon Capture rule)
#   DAMAGE  a weapon in the loadout does damage
#   MISSILE a missile weapon is in the loadout
#   SHIELDS the host's Shields rule is on (crafts have shields at all)
enum Requires { ALWAYS, POWER, RECONS, DAMAGE, MISSILE, SHIELDS }

@export var item_name: String = "Loot"
# Short player-facing text: what it does, in a line.
@export_multiline var description: String = ""

@export_group("Look")
# Which row of the sheet (16 frames of 256 px, row N is y = N * 256) is this item's spinning coin.
# This one row is the item's whole look: the spinning pickup on the ground, its HUD icon, the orbit coins and the
# host screen's icon. -1 = no sheet art: a plain glowing orb in `color`.
@export var sheet_row: int = -1
# Leave empty to use POWERUPS.png. A separate image (e.g. a single-row placeholder, row 0) goes here.
@export var sheet: Texture2D
# How fast the coin spins: frames per second through its row.
@export var spin_fps: float = SPIN_FPS
# Overrides the sheet's first frame as the HUD icon.
@export var icon: Texture2D
# Pickup light, projectile tint (powerups) and the orb fallback.
@export_color_no_alpha var color: Color = Color(0.2, 1.0, 0.3)
@export var pickup_sound: AudioStream
# Size of the pickup relative to the art as drawn at scale 1 (a 256 px frame is 2.56 m there), so 0.125 is a
# 0.32 m coin. It is kept resting on the floor at any size.
@export var visual_scale: float = 0.125
# Trigger sphere around the coin's centre. The craft is about 0.74 m wide and 1.62 m long, so it has to roll right
# up to the coin.
@export var pickup_radius: float = 0.25

@export_group("Drop")
# Relative weight inside its table - only meaningful next to the others.
@export var drop_weight: float = 10.0
@export var requires: Requires = Requires.ALWAYS
# Easter egg: hidden from the host's Drops list and exempt from its picks - always in the table, whatever the host chose.
@export var easter_egg: bool = false
# Seconds it sits on the floor before vanishing (blinks for the last few).
@export var lifetime: float = 25.0

static var _icon_cache: Dictionary = {} # sheet + row -> AtlasTexture
static var _frames_cache: Dictionary = {} # sheet + row + speed -> SpriteFrames


# Server only. Try to give this item to `craft`. false = it could not be used (full health, already
# has that weapon...) and the pickup stays on the floor for someone else.
func apply_to(_craft: Node) -> bool:
	return false


# The HUD icon: the explicit one, else the first frame of the sheet row.
func get_icon() -> Texture2D:
	if icon != null:
		return icon
	if sheet_row < 0:
		return null
	var key := _cache_key()
	if not _icon_cache.has(key):
		_icon_cache[key] = _frame(0)
	return _icon_cache[key]


# The spinning coin: the whole sheet row as one looping animation. Null without a sheet_row.
func sprite_frames() -> SpriteFrames:
	if sheet_row < 0:
		return null
	var key := "%s@%s" % [_cache_key(), spin_fps]
	if not _frames_cache.has(key):
		var frames := SpriteFrames.new()
		frames.set_animation_speed(&"default", spin_fps)
		frames.set_animation_loop(&"default", true)
		for i in FRAME_COUNT:
			frames.add_frame(&"default", _frame(i))
		_frames_cache[key] = frames
	return _frames_cache[key]


func _cache_key() -> String:
	return "%s:%d" % [sheet.resource_path if sheet != null else "", sheet_row]


func _frame(index: int) -> AtlasTexture:
	var tex := AtlasTexture.new()
	tex.atlas = sheet if sheet != null else SHEET
	tex.region = Rect2(index * FRAME_SIZE, sheet_row * FRAME_SIZE, FRAME_SIZE, FRAME_SIZE)
	return tex


# --- match rules -------------------------------------------------------------

# The facts about a match that `requires` is checked against. `weapons` is the loadout everyone shares
# (WeaponSettings); mines are deliberately not part of it.
static func match_facts(weapons: Array, recon_capture: bool, shields: bool = true) -> Dictionary:
	var facts := {"power": false, "recons": recon_capture, "damage": false, "missile": false, "shields": shields}
	for entry in weapons:
		var w := entry as WeaponSettings
		if w == null:
			continue
		facts["power"] = facts["power"] or w.power_consumption > 0.0
		facts["damage"] = facts["damage"] or w.hit_points > 0.0
		facts["missile"] = facts["missile"] or w.weapon_kind == WeaponSettings.WeaponKind.MISSILE
	return facts


func is_available(facts: Dictionary) -> bool:
	match requires:
		Requires.POWER:
			return facts.get("power", true)
		Requires.RECONS:
			return facts.get("recons", true)
		Requires.DAMAGE:
			return facts.get("damage", true)
		Requires.MISSILE:
			return facts.get("missile", true)
		Requires.SHIELDS:
			return facts.get("shields", true)
	return true

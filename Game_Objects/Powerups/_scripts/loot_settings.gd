extends Resource
class_name LootSettings

# Plain data for one kind of drop. NEVER mutated at runtime - same rule as
# WeaponSettings: anything that changes while playing lives on the craft
# (or the pickup), this only says what the pickup is and does.

enum LootType { HEALTH, POWER, JUICE, WEAPON, BOOST }

@export var loot_name: String = "Loot"
@export var loot_type: LootType = LootType.HEALTH
# Meaning depends on the type: HEALTH restores shields, then armor, then life; POWER adds to
# the craft's power, JUICE adds to the craft's TEAM juice.
@export var amount: float = 25.0
# WEAPON: the weapon to equip (kept until the craft is destroyed).
@export var weapon: WeaponSettings
# BOOST: the timed weapon boost to apply (a BoostSettings; refreshes if active).
@export var boost: BoostSettings
# Relative weight when a drop is rolled - see match.gd::_roll_loot. A weight is
# only meaningful next to the others: 10 / 10 / 10 / 0.3 means the last one
# turns up roughly 1 drop in 100.
@export var drop_weight: float = 10.0
# What the match must have for this to be worth dropping. Anything else is left out of the roll, and
# the remaining entries share its weight (so kills drop about as often as before). ALWAYS = no condition.
#   POWER   a weapon in the loadout uses power
#   RECONS  recons can be captured (the host's Recon Capture rule)
#   DAMAGE  a weapon in the loadout does damage
#   MISSILE a missile weapon is in the loadout
enum Requires { ALWAYS, POWER, RECONS, DAMAGE, MISSILE }
@export var requires: Requires = Requires.ALWAYS
# Seconds it sits on the floor before vanishing (blinks for the last few).
@export var lifetime: float = 25.0
# The pickup's look: its root should be a Node3D with the sprite/light/etc.
# (any Area3D inside is ignored - the pickup scene has its own trigger).
@export var visual_scene: PackedScene
# Fallback trigger, used only when the visual scene has no Area3D of its own
# (that one wins - its shape radius is in real meters, it does NOT follow
# visual_scale). A sphere at the coin's centre. The craft is about 0.74 m wide
# and 1.62 m long, so it has to roll right up to the coin.
@export var pickup_radius: float = 0.25
# Size of the pickup's look relative to the art as drawn at scale 1 (a 256 px
# medallion is 2.56 m wide there), so 0.125 is a 0.32 m coin. The coin is kept
# resting on the floor at any size.
@export var visual_scale: float = 0.125
# Fallback look when visual_scene is empty: a glowing orb in this color, plus an optional billboard
# icon over it. Swap in real art by setting icon.
@export_color_no_alpha var color: Color = Color(0.2, 1.0, 0.3)
@export var icon: Texture2D
@export var pickup_sound: AudioStream


# --- match rules -------------------------------------------------------------

# The facts about a match that `requires` is checked against. `weapons` is the
# loadout everyone shares (WeaponSettings); mines are deliberately not part of it.
static func match_facts(weapons: Array, recon_capture: bool) -> Dictionary:
	var facts := {"power": false, "recons": recon_capture, "damage": false, "missile": false}
	for weapon in weapons:
		var w := weapon as WeaponSettings
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
	return true

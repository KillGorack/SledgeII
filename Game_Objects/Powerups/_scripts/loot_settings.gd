extends Resource
class_name LootSettings

# Plain data for one kind of drop. NEVER mutated at runtime - same rule as
# WeaponSettings: anything that changes while playing lives on the craft
# (or the pickup), this only says what the pickup is and does.

enum LootType { HEALTH, POWER, JUICE, WEAPON, BOOST }

@export var loot_name: String = "Loot"
@export var loot_type: LootType = LootType.HEALTH
# Meaning depends on the type: HEALTH restores armor then life, POWER adds to
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
# Seconds it sits on the floor before vanishing (blinks for the last few).
@export var lifetime: float = 25.0
# The pickup's look: its root should be a Node3D with the sprite/light/etc.
# (any Area3D inside is ignored - the pickup scene has its own trigger).
@export var visual_scene: PackedScene
# Fallback trigger, used only when the visual scene has no Area3D of its own
# (that one wins, and scales with visual_scale). A sphere on the floor point. The craft is
# about 0.74 m wide and 1.62 m long, so ~0.8 means it has to roll up to the
# coin; 1.5 triggered a full tank-length early.
@export var pickup_radius: float = 0.8
# Size of the pickup's look (1.0 = as drawn, a 0.64 m wide coin). The coin is
# kept sitting on the floor at any size.
@export var visual_scale: float = 0.75
# Fallback look when visual_scene is empty: a glowing orb in this color, plus an optional billboard
# icon over it. Swap in real art by setting icon.
@export_color_no_alpha var color: Color = Color(0.2, 1.0, 0.3)
@export var icon: Texture2D
@export var pickup_sound: AudioStream

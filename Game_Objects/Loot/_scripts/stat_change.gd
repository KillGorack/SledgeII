extends Resource
class_name StatChange

# One change a powerup makes while it runs: "this stat, on these things, is set to / multiplied by this".
# Pure data, never mutated. Stat names are WeaponSettings properties for Laser / Missile / Object, and
# craft stats (CraftStats names, e.g. regeneration_rate) for Craft. Two powerups should not change the
# same stat on the same target - then merging is just "later wins" (the design rule from boosts).

enum Mode { SET, MULTIPLY }

# Which things it applies to. Laser / Missile / Object are weapon kinds (WeaponSettings.WeaponKind),
# the bit for a kind is 1 << kind. Craft is the craft itself.
const CRAFT_BIT := 8
const WEAPON_BITS := 7

@export_flags("Laser", "Missile", "Object", "Craft") var targets: int = 3
@export var stat: String = ""
@export var mode: Mode = Mode.SET
# A number, a bool, or a Color - whatever the stat holds. A multiply is always a number.
# The default is null ON PURPOSE: Godot leaves a value out of the saved file when it equals the default, and
# it treats false (and 1.0 vs true) as equal to a default of 1.0 - so a real `false` used to be dropped on
# an editor save and quietly came back as 1.0. Nothing legitimate is null, so nothing can be lost.
@export var value: Variant = null

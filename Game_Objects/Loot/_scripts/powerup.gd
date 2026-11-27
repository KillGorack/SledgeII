extends LootItem
class_name Powerup

# Timed: a list of stat changes for `duration` seconds. Pure data, never mutated: nothing here touches a
# WeaponSettings .tres. While a powerup is active the craft's PowerupState merges the active ones into one
# small "ops" dictionary per weapon kind, and every shot applies that to a duplicate of the base weapon
# (apply_ops below) - on the server for the real shot, on the owner for prediction/cooldown, and on every
# other peer via the spawn event (match.gd::_create_volley), so everyone simulates the same weapon.
#
# Keep powerups from sharing stats (that's the design rule): then merging is just "later wins" and there is
# no stacking math to get wrong.

@export_group("Powerup")
# Flat time in seconds. Picking the same powerup up again adds to what is left (see PowerupState).
@export var duration: float = 60.0
# Paint this powerup's shots in `color` so everyone can read the threat.
@export var tint_projectiles: bool = true
# One-time, on pickup: shields (and only shields) jump to full, skipping regeneration.
@export var refill_shields: bool = false
@export var changes: Array[StatChange] = []

# Craft stats something actually reads (through PowerupState.factor). A Craft change naming anything else does
# nothing, so check() warns about it. Add the name here when a new system starts reading one.
const CRAFT_STATS := ["regeneration_rate", "regeneration_delay", "knockback", "power_gain_rate",
		"max_speed", "acceleration", "deceleration", "turn_speed", "turn_acceleration", "turn_deceleration"]

static var _checked: Dictionary = {} # resource_path -> true, so each powerup is only checked once per run


func apply_to(craft: Node) -> bool:
	var weapon_node := craft.get_node_or_null("weapon_node")
	return weapon_node != null and weapon_node.powerups.server_grant(self)


# Warn (once per run) about changes that would silently do nothing: no value, a weapon stat WeaponSettings doesn't
# have, a craft stat nothing reads, or a "set" on a craft stat (only multiply is supported there).
func check() -> void:
	if _checked.has(resource_path):
		return
	_checked[resource_path] = true
	var weapon_stats: Dictionary = {}
	for prop in WeaponSettings.new().get_property_list():
		weapon_stats[prop.name] = true
	for change in changes:
		if change == null:
			continue
		var where := "Powerup '%s', stat '%s'" % [item_name, change.stat]
		if change.value == null:
			push_warning(where + ": no value, it is skipped")
		if (change.targets & StatChange.WEAPON_BITS) != 0 and not weapon_stats.has(change.stat):
			push_warning(where + ": not a weapon stat (WeaponSettings has no such property)")
		if (change.targets & StatChange.CRAFT_BIT) != 0:
			if not CRAFT_STATS.has(change.stat):
				push_warning(where + ": no craft system reads this stat (see Powerup.CRAFT_STATS)")
			if change.mode != StatChange.Mode.MULTIPLY:
				push_warning(where + ": craft stats only support multiply, this 'set' does nothing")


# Does this change anything about a weapon of this kind (a WeaponSettings.WeaponKind)?
func affects_kind(kind: int) -> bool:
	for change in changes:
		if change != null and (change.targets & (1 << kind)) != 0:
			return true
	return false


# Does it touch any weapon at all? A craft-only powerup (Fortitude) does not.
func has_weapon_changes() -> bool:
	for change in changes:
		if change != null and (change.targets & StatChange.WEAPON_BITS) != 0:
			return true
	return false


# For the HUD dimming: a powerup is "live" for the held weapon if it changes that kind, or if it is not a
# weapon powerup at all.
func applies_to_kind(kind: int) -> bool:
	return not has_weapon_changes() or affects_kind(kind)


# Merge any number of powerups into one ops dictionary: {"set": {...}, "mul": {...}}.
# Only changes that target `kind` (a WeaponSettings.WeaponKind) are included; {} if nothing applies.
static func resolve(powerups: Array, kind: int) -> Dictionary:
	var ops := {"set": {}, "mul": {}}
	var bit := 1 << kind
	for powerup in powerups:
		if powerup == null:
			continue
		var touched := false
		for change in powerup.changes:
			if change == null or (change.targets & bit) == 0:
				continue
			if change.value == null:
				push_warning("Powerup '%s': change to '%s' has no value" % [powerup.item_name, change.stat])
				continue
			touched = true
			if change.mode == StatChange.Mode.MULTIPLY:
				ops["mul"][change.stat] = change.value
			else:
				ops["set"][change.stat] = change.value
		if touched and powerup.tint_projectiles:
			ops["set"]["projectile_color"] = powerup.color
	if ops["set"].is_empty() and ops["mul"].is_empty():
		return {}
	return ops


# The factor active powerups apply to one craft stat (1.0 if none). Only MULTIPLY changes on Craft count.
static func craft_factor(powerups: Array, stat: String) -> float:
	var factor := 1.0
	for powerup in powerups:
		if powerup == null:
			continue
		for change in powerup.changes:
			if change != null and change.value != null and (change.targets & StatChange.CRAFT_BIT) != 0 and change.stat == stat and change.mode == StatChange.Mode.MULTIPLY:
				factor = float(change.value)
	return factor


# `base` with the ops applied, as a duplicate (the .tres itself is never written). An unknown stat name is
# skipped with a warning, so a typo in a powerup file is visible instead of silently doing nothing.
static func apply_ops(base: WeaponSettings, ops: Dictionary) -> WeaponSettings:
	if base == null or ops.is_empty():
		return base
	var out := base.duplicate() as WeaponSettings
	var set_ops: Dictionary = ops.get("set", {})
	for key in set_ops:
		if key in out:
			out.set(key, set_ops[key])
		else:
			push_warning("Powerup sets unknown weapon stat '%s'" % key)
	var mul_ops: Dictionary = ops.get("mul", {})
	for key in mul_ops:
		if key in out:
			var current = out.get(key)
			out.set(key, type_convert(current * mul_ops[key], typeof(current)))
		else:
			push_warning("Powerup multiplies unknown weapon stat '%s'" % key)
	return out

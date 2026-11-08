extends Resource
class_name BoostSettings

# A timed weapon powerup. Pure data, never mutated: nothing here touches a
# WeaponSettings .tres. While a boost is active the craft's weapon_node merges
# the active boosts into one small "ops" dictionary, and every shot applies
# that to a duplicate of the base weapon (apply_ops below) - on the server for
# the real shot, on the owner for prediction/cooldown, and on every other peer
# via the spawn event (match.gd::_create_volley), so everyone simulates the
# same boosted weapon.
#
# Keep boosts from sharing attributes (that's the design rule): then merging is
# just "later wins" and there's no stacking math to get wrong.

@export var boost_name: String = "Boost"
# HUD icon. Placeholder: frame 1 of the pickup's animation (an AtlasTexture).
@export var icon: Texture2D
# Flat time in seconds. Picking the same boost up again refreshes it.
@export var duration: float = 20.0
# Paint this boost's shots in projectile_color so everyone can read the threat.
@export var tint_projectiles: bool = true
@export_color_no_alpha var projectile_color: Color = Color.WHITE
# WeaponSettings property name -> value, replacing the weapon's own.
@export var set_values: Dictionary = {}
# WeaponSettings property name -> factor, multiplying the weapon's own.
@export var multiply_values: Dictionary = {}


# Merge any number of boosts into one ops dictionary: {"set": {...}, "mul": {...}}.
static func resolve(boosts: Array) -> Dictionary:
	var ops := {"set": {}, "mul": {}}
	for boost in boosts:
		if boost == null:
			continue
		for key in boost.set_values:
			ops["set"][key] = boost.set_values[key]
		for key in boost.multiply_values:
			ops["mul"][key] = boost.multiply_values[key]
		if boost.tint_projectiles:
			ops["set"]["projectile_color"] = boost.projectile_color
	return ops


# `base` with the ops applied, as a duplicate (the .tres itself is never
# written). Unknown property names are ignored.
static func apply_ops(base: WeaponSettings, ops: Dictionary) -> WeaponSettings:
	if base == null or ops.is_empty():
		return base
	var out := base.duplicate() as WeaponSettings
	var set_ops: Dictionary = ops.get("set", {})
	for key in set_ops:
		if key in out:
			out.set(key, set_ops[key])
	var mul_ops: Dictionary = ops.get("mul", {})
	for key in mul_ops:
		if key in out:
			var current = out.get(key)
			out.set(key, type_convert(current * mul_ops[key], typeof(current)))
	return out

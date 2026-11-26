extends RefCounted
class_name DamageRouting

# How a hit's damage reaches a craft's three pools (shields, armor, life). Shared by everything that deals
# damage from a settings resource: weapons (WeaponSettings), thrown objects and mines (MineSettings) all
# carry the same four fields - damage_routing, shields_factor, armor_factor, life_factor.
#
#   SEQUENTIAL  the original rule: shields first, what they can't absorb spills into armor, then life.
#   SPLIT       each pool takes hit_points x its own factor, independently. Nothing spills: a pool that is
#               already empty (or a factor of 0) simply takes nothing, and that share of the damage is lost.
#               Factors above 1 make a weapon extra effective against that pool; 0 leaves it untouched.
#
# Examples: plasma = SPLIT 2.0 / 0 / 0 (strips shields, can't touch anything else); a third-each blast =
# SPLIT 0.33 / 0.33 / 0.33; a bypass weapon = SPLIT 0 / 0 / 1.
enum Mode { SEQUENTIAL, SPLIT }


# Whether a weapon's (or mine's) damage can land on anything when the host has switched pools off. Sequential always
# finds a pool (life is always there); Split only lands on the pools it has a factor for. Something that does no
# damage at all (a pure shove like the Repulsor) is still useful.
static func lands(mode: Mode, factors: Vector3, hit_points: float, shields_on: bool, armor_on: bool) -> bool:
	if hit_points <= 0.0 or mode == Mode.SEQUENTIAL:
		return true
	return (factors.x > 0.0 and shields_on) or (factors.y > 0.0 and armor_on) or factors.z > 0.0


# Hand `damage` to `target` (a craft's health_node, or a base gun's / sentry's stand-in, which only has one
# pool and so always takes it as plain damage). Server only, like every damage call.
static func deal(target: Node, damage: float, mode: Mode, factors: Vector3, attacker_id: int, cause: int) -> void:
	if mode == Mode.SPLIT and target.has_method("apply_split_damage"):
		target.apply_split_damage(damage, factors, attacker_id, cause)
	else:
		target.apply_damage(damage, attacker_id, cause)

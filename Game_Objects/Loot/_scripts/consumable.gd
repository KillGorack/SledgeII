extends LootItem
class_name Consumable

# Instant: used up on pickup. A craft that can't use it (full health) leaves it for someone else.

enum Target { HEALTH, POWER, JUICE }

# HEALTH restores shields, then armor, then life. POWER adds to the craft's power. JUICE adds to the
# craft's TEAM juice.
@export_group("Consumable")
@export var target: Target = Target.HEALTH
@export var amount: float = 25.0


func apply_to(craft: Node) -> bool:
	match target:
		Target.HEALTH:
			var health := craft.get_node_or_null("health_node")
			return health != null and health.heal(amount)
		Target.POWER:
			var power := craft.get_node_or_null("power_node")
			return power != null and power.add_power(amount)
		Target.JUICE:
			var weapon := craft.get_node_or_null("weapon_node")
			var match_node := craft.get_tree().get_first_node_in_group("match")
			return weapon != null and match_node != null and match_node.add_team_juice(weapon.team, amount)
	return false

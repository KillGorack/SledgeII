extends LootItem
class_name WeaponPickup

# Until destroyed: the weapon is added to the craft and kept until the craft is destroyed.

@export_group("Weapon")
@export var weapon: WeaponSettings


func apply_to(craft: Node) -> bool:
	var weapon_node := craft.get_node_or_null("weapon_node")
	return weapon_node != null and weapon_node.server_grant_weapon(weapon)

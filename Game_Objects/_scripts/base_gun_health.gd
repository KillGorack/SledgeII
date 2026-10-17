extends Node

# Stand-in for a craft's health_node on a base gun's hit body. The projectile
# code (collision_handler.gd::_apply_damage_to) finds "health_node" on whatever
# it struck and calls apply_damage()/note_attacker() - this answers those and
# hands the damage to the owning BaseGun. HP and the destroy/respawn cycle
# live in base_gun.gd.
const DeathCause := HealthNode.DeathCause

@onready var _gun: BaseGun = get_parent().get_parent()


func apply_damage(damage: float, attacker_id: int = 0, _cause: int = DeathCause.WEAPON) -> void:
	_gun.take_damage(damage, attacker_id)


func note_attacker(_attacker_id: int) -> void:
	pass

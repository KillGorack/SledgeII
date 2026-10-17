extends Area3D
class_name Mine

# One laid mine (Weapons/Scenes/mines/land_mine.tscn). Every peer has a copy
# for the visuals, but only the server's copy ever decides to detonate - see
# Networking/mine_manager.gd for lay/blow/replication. id, owner_peer and team
# are set by the manager before add_child.
const ARM_TIME := 1.5
# Layers 3-6: the four team craft layers (utilities.gd::GROUP_LAYER_SCOPE).
const CRAFT_MASK := 0b111100

# Per-team look, from the same folder as the scene's placeholder material.
const TEAM_MATERIALS := {
	"team_red": preload("res://Materials/PBR/digi_red.tres"),
	"team_green": preload("res://Materials/PBR/digi_green.tres"),
	"team_blue": preload("res://Materials/PBR/digi_blue.tres"),
	"team_gray": preload("res://Materials/PBR/digi_gray.tres"),
}

var id: int = -1
var owner_peer: int = 0
var team: String = ""
var manager: MineManager

var _arm_left: float = ARM_TIME
var _enemy_groups: Array = []


func _ready() -> void:
	if TEAM_MATERIALS.has(team):
		$HexMine.material_override = TEAM_MATERIALS[team]
	collision_layer = 0
	collision_mask = CRAFT_MASK
	_enemy_groups = Utilities.GROUP_LAYER_SCOPE.get(team, {}).get("target_groups", [])
	if not multiplayer.is_server():
		monitoring = false
		set_physics_process(false)


# Server only. Armed after ARM_TIME so the layer can walk away, then polls
# rather than using body_entered so a craft already sitting on the mine when
# it arms still sets it off. Own team's crafts (the layer included) never do.
func _physics_process(delta: float) -> void:
	if _arm_left > 0.0:
		_arm_left -= delta
		return
	for body in get_overlapping_bodies():
		for group_name in _enemy_groups:
			if body.is_in_group(group_name):
				manager.detonate(id)
				return

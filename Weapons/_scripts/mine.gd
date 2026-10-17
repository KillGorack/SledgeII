extends Area3D
class_name Mine

# One laid mine (the scene named by MineSettings.mine_prefab). Every peer has a
# copy for the visuals, but only the server's copy ever decides to detonate -
# see Networking/mine_manager.gd for lay/blow/replicate. id, owner_peer, team
# and settings are set by the manager before add_child.

# Per-team look, from the same folder as the scene's placeholder material.
const TEAM_MATERIALS := {
	"team_red": preload("res://Materials/PBR/digi_red.tres"),
	"team_green": preload("res://Materials/PBR/digi_green.tres"),
	"team_blue": preload("res://Materials/PBR/digi_blue.tres"),
	"team_gray": preload("res://Materials/PBR/digi_gray.tres"),
}
# Layers 3-6: the four team craft layers (utilities.gd::GROUP_LAYER_SCOPE).
const CRAFT_MASK := 0b111100

var id: int = -1
var owner_peer: int = 0
var team: String = ""
var settings: MineSettings
var manager: MineManager

var _arm_left: float = 0.0
var _life_left: float = 0.0
var _enemy_groups: Array = []


func _ready() -> void:
	# Tint every mesh the mine scene has, whatever its nodes are called - each mine type has its own model.
	if TEAM_MATERIALS.has(team):
		for mesh in find_children("*", "MeshInstance3D", true, false):
			mesh.material_override = TEAM_MATERIALS[team]
	collision_layer = 0
	collision_mask = CRAFT_MASK
	# The scene's shape is shared between instances - size this one's own.
	var shape_node: CollisionShape3D = $CollisionShape3D
	if shape_node.shape is SphereShape3D:
		shape_node.shape = shape_node.shape.duplicate()
		shape_node.shape.radius = settings.activation_range
	_arm_left = settings.arm_time
	_life_left = settings.life_span
	_enemy_groups = Utilities.GROUP_LAYER_SCOPE.get(team, {}).get("target_groups", [])
	if not multiplayer.is_server():
		monitoring = false
		set_physics_process(false)
	elif not settings.proximity_trigger:
		monitoring = false


# Server only. Armed after arm_time so the layer can walk away, then polls
# rather than using body_entered so a craft already sitting on the mine when
# it arms still sets it off. The owner's own team never does.
func _physics_process(delta: float) -> void:
	if settings.life_span > 0.0:
		_life_left -= delta
		if _life_left <= 0.0:
			manager.expire(id)
			return
	if _arm_left > 0.0:
		_arm_left -= delta
		return
	if not settings.proximity_trigger:
		return
	for body in get_overlapping_bodies():
		for group_name in _enemy_groups:
			if body.is_in_group(group_name):
				manager.detonate(id)
				return

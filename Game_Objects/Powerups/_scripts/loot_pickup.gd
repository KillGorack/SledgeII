extends Area3D
class_name LootPickup

# One drop on the floor. Every peer has its own copy (spawned from the
# server's one event - match.gd::_spawn_loot_event); only the SERVER's copy
# detects pickups and applies the effect, then tells everyone it's gone.

const BLINK_SECONDS := 4.0
# Half the width of the 256 px medallion sprite at the 0.25 scale in its scene.
const COIN_RADIUS := 0.31
# Crafts live on layers 3-6.
const CRAFT_MASK := (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)
const SPIN_SPEED := 1.5

var loot_id: int = -1
var settings: LootSettings
var _age := 0.0
var _taken := false
# The pickup scene's own Area3D, if it has one - see _ready.
var _scene_trigger: Area3D = null

@onready var _visual: Node3D = $Visual
@onready var _orb: MeshInstance3D = $Visual/Orb
@onready var _icon: Sprite3D = $Visual/Icon


func _ready() -> void:
	if settings:
		# Sits ON the floor at any scale: its centre is one coin-radius up.
		_visual.scale = Vector3.ONE * settings.visual_scale
		_visual.position.y = COIN_RADIUS * settings.visual_scale
	if settings and settings.visual_scene:
		_orb.visible = false
		_icon.visible = false
		var look := settings.visual_scene.instantiate()
		_visual.add_child(look)
		look.position = Vector3(0, 0.0, 0)
		# The scene's own Area3D is the trigger (it scales with the visual, and
		# is tuned next to the art). Without one, the pickup's own sphere is used.
		var areas := look.find_children("*", "Area3D", true, false)
		if not areas.is_empty():
			_scene_trigger = areas[0]
	elif settings:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = settings.color
		mat.emission_enabled = true
		mat.emission = settings.color
		mat.emission_energy_multiplier = 1.5
		_orb.material_override = mat
		_icon.texture = settings.icon
		_icon.visible = settings.icon != null
	if settings and _scene_trigger == null:
		var shape := $CollisionShape3D.shape.duplicate() as SphereShape3D
		shape.radius = settings.pickup_radius
		$CollisionShape3D.shape = shape
	# Crafts live on layers 3-6 (see Utilities.GROUP_LAYER_SCOPE).
	collision_layer = 0
	collision_mask = CRAFT_MASK
	var trigger: Area3D = _scene_trigger if _scene_trigger != null else self
	if _scene_trigger != null:
		$CollisionShape3D.disabled = true # ours isn't needed
		monitoring = false
		_scene_trigger.collision_layer = 0
		_scene_trigger.collision_mask = CRAFT_MASK
	if multiplayer.is_server():
		trigger.body_entered.connect(_on_body_entered)
	else:
		trigger.monitoring = false


func _process(delta: float) -> void:
	_age += delta
	_visual.rotation.y += SPIN_SPEED * delta
	if settings:
		var left := settings.lifetime - _age
		_visual.visible = left > BLINK_SECONDS or int(_age * 6.0) % 2 == 0
		# Fallback only: the server's removal event normally arrives first.
		if left < -3.0:
			queue_free()


# Server only.
func _on_body_entered(body: Node) -> void:
	if _taken or settings == null:
		return
	var health_node := body.get_node_or_null("health_node")
	if health_node == null:
		return
	var used := false
	match settings.loot_type:
		LootSettings.LootType.HEALTH:
			used = health_node.heal(settings.amount)
		LootSettings.LootType.POWER:
			var power_node := body.get_node_or_null("power_node")
			used = power_node != null and power_node.add_power(settings.amount)
		LootSettings.LootType.JUICE:
			var weapon_node := body.get_node_or_null("weapon_node")
			var match_node := get_tree().get_first_node_in_group("match")
			used = weapon_node != null and match_node != null and match_node.add_team_juice(weapon_node.team, settings.amount)
		LootSettings.LootType.BOOST:
			var weapon_node := body.get_node_or_null("weapon_node")
			used = weapon_node != null and weapon_node.server_grant_boost(settings.boost)
		LootSettings.LootType.WEAPON:
			var weapon_node := body.get_node_or_null("weapon_node")
			used = weapon_node != null and weapon_node.server_grant_weapon(settings.weapon)
	# A craft that can't use it (full health) leaves it for someone else.
	if not used:
		return
	_taken = true
	var match_node := get_tree().get_first_node_in_group("match")
	if match_node:
		match_node.collect_loot(loot_id, body.get_multiplayer_authority())

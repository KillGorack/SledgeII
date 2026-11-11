extends Area3D
class_name LootPickup

# One drop on the floor. Every peer has its own copy (spawned from the
# server's one event - match.gd::_spawn_loot_event); only the SERVER's copy
# detects pickups and applies the effect, then tells everyone it's gone.

const BLINK_SECONDS := 4.0
# Half the width of a 256 px medallion frame as drawn at scale 1 (Sprite3D's
# default pixel_size is 0.01 m per pixel). The scenes keep their sprites at scale
# 1; LootSettings.visual_scale is the one place that sizes the coin.
const COIN_RADIUS := 1.28
# Crafts live on layers 3-6.
const CRAFT_MASK := (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)
const SPIN_SPEED := 1.5

var loot_id: int = -1
# The peer whose death left this behind (server's copy only). It never picks it
# up: otherwise destroying yourself would be a way to keep the loot.
var dropped_by: int = 0
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
		_visual.position.y = _center_height()
	if settings and settings.visual_scene:
		_orb.visible = false
		_icon.visible = false
		var look := settings.visual_scene.instantiate()
		_visual.add_child(look)
		look.position = Vector3(0, 0.0, 0)
		# The scene's own Area3D is the trigger, tuned next to the art. Without
		# one, the pickup's own sphere is used. It is lifted OUT of the scaled
		# visual: collision shapes don't follow node scale, so under it the shape
		# would keep its size while sitting at a scaled position. Moved to the
		# pickup root, its radius is in real meters and it stays at the coin's centre.
		var areas := look.find_children("*", "Area3D", true, false)
		if not areas.is_empty():
			_scene_trigger = areas[0]
			_scene_trigger.get_parent().remove_child(_scene_trigger)
			add_child(_scene_trigger)
			_scene_trigger.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, _center_height(), 0.0))
			for shape_node in _scene_trigger.find_children("*", "CollisionShape3D", true, false):
				shape_node.basis = Basis.IDENTITY # a scale on the shape node is ignored by physics anyway
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


# How far above a drop spot the floor search starts, how far down it looks, and how far
# short of a wall a pulled-back spot stops.
const PROBE_UP := 0.4
const SEARCH_DEPTH := 80.0
const WALL_MARGIN := 0.3


# Where a drop at `point` should rest: on the floor directly BELOW it. The search starts
# just above the spot, never from high up - from 2 m above, a ceiling lower than that
# (a tunnel, an overhang, a bridge deck) was mistaken for the floor and the loot ended up
# on top of it, out of reach. `anchor` is the wreck itself when `point` is a spot fanned
# out to the side of it: if a wall is in between, the spot is pulled back to the wall instead
# of landing inside it or behind it. Returns Vector3.INF when there is no floor below at all.
static func floor_point(space: PhysicsDirectSpaceState3D, world_mask: int, point: Vector3, anchor: Vector3 = Vector3.INF) -> Vector3:
	var spot := point
	if anchor != Vector3.INF:
		var from := anchor + Vector3.UP * PROBE_UP
		var to := Vector3(spot.x, from.y, spot.z)
		var side := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, world_mask))
		if not side.is_empty():
			var back := (from - to).normalized()
			spot = Vector3(side.position.x, anchor.y, side.position.z) + back * WALL_MARGIN
	var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(spot + Vector3.UP * PROBE_UP, spot + Vector3.DOWN * SEARCH_DEPTH, world_mask))
	if down.is_empty():
		return Vector3.INF
	return down.position


# Height of the coin's centre above the floor point: one coin-radius, so the
# coin appears to rest on the ground at any visual_scale.
func _center_height() -> float:
	return COIN_RADIUS * (settings.visual_scale if settings else 1.0)


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
	if dropped_by != 0 and body.get_multiplayer_authority() == dropped_by:
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
			var juice_match := get_tree().get_first_node_in_group("match")
			used = weapon_node != null and juice_match != null and juice_match.add_team_juice(weapon_node.team, settings.amount)
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

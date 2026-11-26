extends Area3D
class_name LootPickup

# One drop on the floor. Every peer has its own copy (spawned from the
# server's one event - LootManager._spawn_event); only the SERVER's copy
# detects pickups and applies the effect, then tells everyone it's gone.

const BLINK_SECONDS := 4.0
# Half the width of a 256 px medallion frame as drawn at scale 1 (Sprite3D's
# default pixel_size is 0.01 m per pixel). LootItem.visual_scale is the one place
# that sizes the coin.
const COIN_RADIUS := 1.28
# Crafts live on layers 3-6.
const CRAFT_MASK := (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)
const SPIN_SPEED := 1.5

var loot_id: int = -1
# The peer whose death left this behind (server's copy only). It never picks it
# up: otherwise destroying yourself would be a way to keep the loot.
var dropped_by: int = 0
var item: LootItem
var _age := 0.0
var _taken := false

@onready var _visual: Node3D = $Visual
@onready var _orb: MeshInstance3D = $Visual/Orb
@onready var _icon: Sprite3D = $Visual/Icon


# Every item looks the same way: its spritesheet row as a spinning coin with a light in its color (LootItem.sheet_row,
# spin_fps, color), or a plain glowing orb when it has no sheet art.
func _ready() -> void:
	if item:
		# Sits ON the floor at any scale: its centre is one coin-radius up.
		_visual.scale = Vector3.ONE * item.visual_scale
		_visual.position.y = _center_height()
		if item.sheet_row >= 0:
			_orb.visible = false
			_icon.visible = false
			var coin := AnimatedSprite3D.new()
			coin.sprite_frames = item.sprite_frames()
			coin.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
			coin.autoplay = "default"
			_visual.add_child(coin)
			var light := OmniLight3D.new()
			light.light_color = item.color
			_visual.add_child(light)
		else:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = item.color
			mat.emission_enabled = true
			mat.emission = item.color
			mat.emission_energy_multiplier = 1.5
			_orb.material_override = mat
			_icon.texture = item.icon
			_icon.visible = item.icon != null
		var shape := $CollisionShape3D.shape.duplicate() as SphereShape3D
		shape.radius = item.pickup_radius
		$CollisionShape3D.shape = shape
		$CollisionShape3D.position.y = _center_height()
	# Crafts live on layers 3-6 (see Utilities.GROUP_LAYER_SCOPE).
	collision_layer = 0
	collision_mask = CRAFT_MASK
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)
	else:
		monitoring = false


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
	return COIN_RADIUS * (item.visual_scale if item else 1.0)


func _process(delta: float) -> void:
	_age += delta
	_visual.rotation.y += SPIN_SPEED * delta
	if item:
		var left := item.lifetime - _age
		_visual.visible = left > BLINK_SECONDS or int(_age * 6.0) % 2 == 0
		# Fallback only: the server's removal event normally arrives first.
		if left < -3.0:
			queue_free()


# Server only.
func _on_body_entered(body: Node) -> void:
	if _taken or item == null:
		return
	if dropped_by != 0 and Utilities.craft_owner_id(body) == dropped_by:
		return
	if body.get_node_or_null("health_node") == null:
		return
	# A craft that can't use it (full health) leaves it for someone else.
	if not item.apply_to(body):
		return
	_taken = true
	(get_parent() as LootManager).collect(loot_id, Utilities.craft_owner_id(body))

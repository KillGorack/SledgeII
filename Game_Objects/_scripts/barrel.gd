extends Node3D
class_name BreakableBarrel

# A barrel the Creative builder can place. Solid like a wall until it is shot or blown up; then it breaks,
# maybe leaves loot (the same roll a destroyed craft gets), and comes back whole after a few minutes.
#
# Built identically on every peer (from the level data, named by where it stands - see
# creative_level_builder.gd), so the server's destroyed/restored calls travel by node path, the way a sentry's
# do. Only the server keeps the hit points. Hits arrive the usual way: collision_handler.gd finds a
# "health_node" on whatever it struck, and the same stand-in a base gun uses (base_gun_health.gd) hands the
# damage to take_damage() here. The "Breakable" group tells the projectile code any team may hurt it.
#
# Placeholder model: Models/Decor/barrel.glb (decimated and scaled to 1 m in Blender; origin at the base).

const MODEL := preload("res://Models/Decor/barrel.glb")
const WALL_PHYSICS := preload("res://Physics/physics_walls.tres")
const DESTROY_EXPLOSION := preload("res://Weapons/Scenes/explosions/explosion_main.tscn")

const MAX_HP := 100.0
const RESPAWN_SECONDS := 180.0
const EXPLOSION_SCALE := 0.6
# The model as exported is 1.0 m wide and 1.09 m tall. SCALE sizes the model, its collider and its blast
# effect together (0.8 = 0.8 m wide, 0.87 m tall; the craft is 0.74 m wide).
const SCALE := 0.8
const RADIUS := 0.5 * SCALE
const HEIGHT := 1.09 * SCALE
# Physics layers: it is a wall to craft and shots (world, bit 2), and also on layer 16 so a blast's sphere
# query can find it (see Utilities.collect_bodies).
const WORLD_LAYER := 2
const BREAKABLE_LAYER := 1 << 15

var is_dead := false
# Seconds until it is back; a variable only so a test can shorten it.
var respawn_seconds := RESPAWN_SECONDS

var _hp := MAX_HP
var _body: StaticBody3D
var _visual: Node3D


# The model is loaded when the barrel is made, not when it enters the tree: the builder sizes the editor's
# pick box (so Remove can find it) from the meshes right after creating it.
func _init() -> void:
	_visual = MODEL.instantiate()
	_visual.scale = Vector3.ONE * SCALE
	add_child(_visual)


func _ready() -> void:
	_build_body()
	add_to_group("Barrels")


func _build_body() -> void:
	_body = StaticBody3D.new()
	_body.name = "Body"
	_body.collision_layer = WORLD_LAYER | BREAKABLE_LAYER
	_body.collision_mask = 0
	_body.physics_material_override = WALL_PHYSICS
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = RADIUS
	cylinder.height = HEIGHT
	shape.shape = cylinder
	shape.position = Vector3(0.0, HEIGHT * 0.5, 0.0)
	_body.add_child(shape)
	# collision_handler.gd looks for this exact child name on whatever it hit.
	var health := Node.new()
	health.name = "health_node"
	health.set_script(preload("res://Game_Objects/_scripts/base_gun_health.gd"))
	_body.add_child(health)
	_body.add_to_group("Breakable")
	add_child(_body)


# Server only (collision_handler.gd resolves hits there, through base_gun_health.gd).
func take_damage(damage: float, _attacker_id: int = 0) -> void:
	if not multiplayer.is_server() or is_dead:
		return
	# Nothing breaks while a creator is building (Creative/creative_editor.gd); testing is the real thing.
	if NetworkManager.creative_building:
		return
	_hp -= damage
	if _hp > 0.0:
		return
	_destroyed.rpc()
	# After its collider is gone, so the loot settles on the floor and not on top of the barrel.
	await get_tree().create_timer(0.1).timeout
	var match_node := get_tree().get_first_node_in_group("match")
	if match_node and is_instance_valid(self):
		match_node.drop_loot_for_structure(global_position)
	await get_tree().create_timer(respawn_seconds).timeout
	if is_instance_valid(self) and is_dead:
		_restored.rpc()


@rpc("authority", "call_local", "reliable")
func _destroyed() -> void:
	if is_dead:
		return
	var explosion := DESTROY_EXPLOSION.instantiate()
	get_parent().add_child(explosion)
	explosion.global_position = global_position + Vector3(0.0, HEIGHT * 0.5, 0.0)
	explosion.scale = Vector3.ONE * EXPLOSION_SCALE
	Utilities.GarbageCollection(explosion, 5.0)
	is_dead = true
	_refresh_state()


# Late joiners: the same state without replaying the explosion.
@rpc("authority", "reliable")
func _sync_dead() -> void:
	is_dead = true
	_refresh_state()


@rpc("authority", "call_local", "reliable")
func _restored() -> void:
	is_dead = false
	_hp = MAX_HP
	_refresh_state()


func _refresh_state() -> void:
	_visual.visible = not is_dead
	# Deferred: the hit that breaks it arrives from inside a projectile's physics callback, and the physics
	# server refuses changes made during its own callbacks.
	_body.set_deferred("collision_layer", 0 if is_dead else (WORLD_LAYER | BREAKABLE_LAYER))

extends Node3D

signal craft_defeated(peer_id: int)

const VEHICLE_EXPLOSION := preload("res://Weapons/Scenes/explosions/explosion_main.tscn")
const VEHICLE_EXPLOSION_SCALE := 3.0
# Falling off the map counts as a kill, same explosion/respawn path as dying
# to weapons fire - see the fall-death check in _process below.
const FALL_DEATH_Y := -50.0

@export var stats: CraftStats

var shields: float
var armor: float
var life: float

var _shields_max: float
var _armor_max: float
var _life_max: float

var _regeneration_timer: Timer
var _is_regenerating: bool = false

# Death-window bookkeeping. A destroyed craft keeps its node alive (see
# destroy_self below), so its collider has to be explicitly taken out of the
# world for the respawn delay and put back afterwards. The real layer/mask
# values are assigned at runtime from the craft's team (see
# Utilities.set_allegiance), so they get saved rather than hardcoded here.
var _is_destroyed: bool = false
var _collision_stored: bool = false
var _stored_collision_layer: int = 0
var _stored_collision_mask: int = 0

@onready var body: Node3D = get_parent()


func _ready() -> void:
	if stats == null:
		return
	# stats is a shared template resource (same values for every Lightning) -
	# current HP has to be per-instance mutable state, so it starts as a copy
	# of the template rather than mutating the shared resource directly.
	shields = stats.shields
	armor = stats.armor
	life = stats.life
	_shields_max = stats.shields
	_armor_max = stats.armor
	_life_max = stats.life

	_regeneration_timer = Timer.new()
	_regeneration_timer.wait_time = stats.regeneration_delay
	_regeneration_timer.one_shot = true
	_regeneration_timer.timeout.connect(_on_regeneration_timeout)
	add_child(_regeneration_timer)


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if _is_regenerating and shields < _shields_max:
		shields = min(_shields_max, shields + stats.regeneration_rate * delta)
	# _is_destroyed guard matters here specifically: destroy_self() itself is
	# already safe to call more than once (see its own guard), but without
	# this the craft sits below FALL_DEATH_Y for the entire respawn delay -
	# it doesn't get teleported back up until respawn_at() actually fires -
	# so this would otherwise re-fire every frame for the whole 4 seconds.
	if not _is_destroyed and body.global_position.y < FALL_DEATH_Y:
		destroy_self()


# Only the server should ever decide damage - the collision handler that
# calls this only runs its hit-resolution logic on the server (see
# Weapons/collision_handler.gd), and this RPC shape ("authority", call_local)
# means only the server is allowed to invoke it, while the resulting HP
# values still get pushed out and applied identically on every client.
@rpc("authority", "call_local", "reliable")
func apply_damage(damage: float) -> void:
	_regeneration_timer.start()
	_is_regenerating = false
	if shields > 0:
		shields -= damage
		if shields <= 0:
			damage = -shields
			shields = 0
		else:
			return
	if armor > 0 and damage > 0:
		armor -= damage
		if armor < 0:
			damage = -armor
			armor = 0
		else:
			return
	if damage > 0:
		life -= damage
	if life <= 0:
		destroy_self()


# apply_damage() above is already broadcast to every peer (rpc + call_local),
# so this runs identically everywhere without needing its own separate RPC -
# that's what makes it actually visible to everyone, not just the host.
func destroy_self() -> void:
	# Two projectiles landing in the same frame both push life below zero and
	# both arrive here. Without this guard that is two explosions and, worse,
	# two craft_defeated emissions - so a second respawn fires four seconds
	# after the first one and teleports an already-alive player back to spawn.
	if _is_destroyed:
		return
	_is_destroyed = true

	var explosion := VEHICLE_EXPLOSION.instantiate()
	body.get_parent().add_child(explosion)
	explosion.global_position = body.global_position
	explosion.scale = Vector3.ONE * VEHICLE_EXPLOSION_SCALE
	Utilities.GarbageCollection(explosion, 5.0)

	# Freeze/hide for the respawn-delay window. The craft node itself is
	# never destroyed - match.gd just repositions and resets this same node
	# after a delay (see respawn_at below) - so there's no wreck cleanup, no
	# despawn/respawn replication timing, and the camera (if this is your
	# own craft) never needs detaching at all: it just stays exactly where
	# it's always been and rides along naturally.
	body.visible = false
	if body is RigidBody3D:
		body.freeze = true
	# Freezing only stops the wreck moving - it stays exactly as solid as it
	# ever was, just invisible, for the whole respawn delay. Take its collider
	# out of the simulation too, so nobody drives into a tank that is no
	# longer there.
	_set_collision_enabled(false)
	# The owner's movement_node keeps running _physics_process while dead and
	# writes angular/linear velocity straight onto the body every tick. Park it,
	# or the first tick after the respawn teleport immediately fights it.
	_set_movement_frozen(true)
	if multiplayer.is_server():
		craft_defeated.emit(body.get_multiplayer_authority())


# Called by match.gd once per respawn. Broadcast (not server-only) so every
# peer - including whichever one actually owns this craft - applies the
# transform locally themselves; that's what lets it replicate out correctly
# afterward via the craft's own MultiplayerSynchronizer, same reasoning as
# apply_damage() above.
@rpc("authority", "call_local", "reliable")
func respawn_at(spawn_position: Vector3, spawn_basis: Basis) -> void:
	shields = _shields_max
	armor = _armor_max
	life = _life_max
	_is_destroyed = false
	var new_transform := Transform3D(spawn_basis, spawn_position)
	if body is RigidBody3D:
		# Unfreeze BEFORE moving. freeze puts the body into the physics server
		# as a STATIC body, and static bodies never report their state back to
		# the node - so pushing a transform through PhysicsServer3D while the
		# body was still frozen moved the simulation but left the NODE's own
		# transform parked at the death position until a physics tick after the
		# unfreeze.
		body.freeze = false
		# That stale node transform is what everything else actually reads: the
		# collision shapes hang off it, the MultiplayerSynchronizer replicates
		# .:position and .:rotation (both node properties, so remote peers were
		# being handed the death position), and reset_physics_interpolation()
		# below pins the render to it. Setting it here is what stops the collider
		# trailing a tick behind the visibly-correct respawn.
		body.global_transform = new_transform
		# Belt and braces: the assignment above reaches the physics server via a
		# transform notification, this writes the simulation state outright, so
		# node and simulation agree within this frame instead of the next one.
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, new_transform)
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	else:
		body.global_transform = new_transform
	# Physics interpolation (project setting, on for jitter) would otherwise
	# smoothly blend the render from the old to the new position instead of
	# snapping - this explicitly tells it a teleport happened.
	body.reset_physics_interpolation()
	body.visible = true
	# Collision only comes back now, once the body is already standing at the
	# spawn point, so it is never solid at the old location.
	_set_collision_enabled(true)
	_set_movement_frozen(false)


# Knockback has to land on the craft's OWN authority, not on the server. This
# craft's MultiplayerSynchronizer replicates .:position/.:rotation outward FROM
# its owning client, so an impulse applied to the server's copy of a
# client-owned craft is overwritten by that client's very next sync before it
# moves anything anyone can see. That is why the repulsor shoved the host's own
# tank around fine and did nothing whatsoever to anybody else's. Only the
# server may call this - health_node's authority is pinned to the server in
# match.gd::_spawn_craft - and it only does real work on the one peer that
# actually simulates this craft.
@rpc("authority", "call_local", "reliable")
func apply_impulse(impulse: Vector3) -> void:
	if _is_destroyed or not (body is RigidBody3D) or body.freeze:
		return
	if not body.is_multiplayer_authority():
		return
	body.apply_central_impulse(impulse)
	# movement.gd hard-sets linear velocity to max_speed every tick while
	# grounded, which erases the shove on the very next tick. Ask it to stand
	# off briefly so the knockback actually plays out.
	var movement_node = body.get_node_or_null("movement_node")
	if movement_node and movement_node.has_method("apply_knockback_grace"):
		movement_node.apply_knockback_grace()


func _set_collision_enabled(enabled: bool) -> void:
	if not (body is CollisionObject3D):
		return
	var floor_detection = body.get_node_or_null("FloorDetection")
	if enabled:
		# Only ever restore what was actually saved. A respawn on a peer that
		# never ran destroy_self() would otherwise write 0/0 over live layers
		# and kill that craft's collision for good.
		if _collision_stored:
			body.collision_layer = _stored_collision_layer
			body.collision_mask = _stored_collision_mask
			_collision_stored = false
		if floor_detection is Area3D:
			floor_detection.monitoring = true
		return
	if not _collision_stored:
		_stored_collision_layer = body.collision_layer
		_stored_collision_mask = body.collision_mask
		_collision_stored = true
	# This path can run from inside _integrate_forces - collision_handler.gd
	# resolves a hit there, which calls apply_damage and so destroy_self - and
	# the physics server refuses layer/monitoring changes made during its own
	# callback. Deferring costs at most the remainder of the current frame.
	body.set_deferred("collision_layer", 0)
	body.set_deferred("collision_mask", 0)
	if floor_detection is Area3D:
		floor_detection.set_deferred("monitoring", false)


func _set_movement_frozen(frozen: bool) -> void:
	var movement_node = body.get_node_or_null("movement_node")
	if movement_node and movement_node.has_method("setFreezeState"):
		movement_node.setFreezeState(frozen)


func _on_regeneration_timeout() -> void:
	_is_regenerating = true

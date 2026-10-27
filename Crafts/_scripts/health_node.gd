class_name HealthNode
extends Node3D

# attacker_id is the player credited with the takedown, 0 if nobody. cause is
# a DeathCause - what dealt the final blow, for the chat announcement.
signal craft_defeated(peer_id: int, attacker_id: int, cause: int)

enum DeathCause { WEAPON, BASE_GUN, FALL, VOID, MINE }

# A hit or shove this recent still gets the credit for a death that follows -
# knocked off the map, or finished by fall damage.
const TAKEDOWN_CREDIT_MSEC := 5000

# The craft smokes while its hull (life) is below this fraction of its maximum.
const SMOKE_LIFE_RATIO := 0.2

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
# Weapon freeze (freeze_timer / unfreeze weapons). Runs on the craft's owner -
# see apply_weapon_freeze below.
var _weapon_freeze_timer: Timer
# Server-only. Who last hit or shoved this craft, and when - see note_attacker.
var _last_attacker: int = 0
var _last_attacker_msec: int = 0
# Server-only. What dealt the blow that destroyed this craft.
var _death_cause: int = DeathCause.WEAPON

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
# Lives on the craft (lightning.tscn). life reaches every peer through the
# synchronizer, so each one drives its own copy - no RPC needed.
@onready var _smoke: GPUParticles3D = get_parent().get_node_or_null("DamageSmoke/GPUParticles3D")




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

	_weapon_freeze_timer = Timer.new()
	_weapon_freeze_timer.one_shot = true
	_weapon_freeze_timer.timeout.connect(_on_weapon_freeze_timeout)
	add_child(_weapon_freeze_timer)


func _process(delta: float) -> void:
	_update_smoke()
	# See NetworkManager.is_live_server() for why not plain is_server().
	if not NetworkManager.is_live_server():
		return
	# apply_damage()/respawn_at() below broadcast shields/armor/life correctly
	# on their own (RPCs, so every peer computes the same result whenever a
	# discrete event happens) - but this passive regen is a continuous
	# per-frame increment with no RPC of its own. That's fine for the
	# server's own craft (is_server() is true there, so its own shields
	# visibly climb) but for every other craft, this was silently updating
	# only the server's internal copy - the owning client (and everyone
	# else) never found out, so shields just sat wherever they were after
	# the last hit, everywhere except the host's own screen. The fix is the
	# health_node/MultiplayerSynchronizer node in lightning.tscn, replicating
	# just .:shields continuously - the one value here that changes on its
	# own instead of only in response to a discrete, already-broadcast event.
	if _is_regenerating and shields < _shields_max:
		shields = min(_shields_max, shields + stats.regeneration_rate * delta)
	_process_station_healing(delta)
	# _is_destroyed guard matters here specifically: without it, the craft
	# sits below FALL_DEATH_Y for the entire respawn delay - it doesn't get
	# teleported back up until respawn_at() actually fires - so this would
	# otherwise re-fire every tick for the whole 4 seconds.
	#
	# Routed through apply_damage(), not a direct destroy_self() call -
	# destroy_self() is a plain local function, and apply_damage() is what
	# broadcasts the death (_broadcast_destroyed) to every peer. Calling
	# destroy_self() directly here skipped that broadcast entirely:
	# the host (the server, in any host-and-play session) would correctly
	# see itself explode, but no other peer was ever told, leaving that
	# craft alive and healthy on every other screen forever - stuck, since
	# a respawn nobody else witnessed never arrives for them either.
	# shields + armor + life guarantees lethality through all three layers
	# regardless of current HP, same as a real overkill hit would.
	if not _is_destroyed and body.global_position.y < FALL_DEATH_Y:
		apply_damage(shields + armor + life, 0, DeathCause.VOID)


func _update_smoke() -> void:
	if _smoke == null or _life_max <= 0.0:
		return
	_smoke.emitting = not _is_destroyed and life < _life_max * SMOKE_LIFE_RATIO


# Server-only, plain function - not an RPC. HP lives on the server alone and
# reaches the owning client's HUD through health_node/MultiplayerSynchronizer
# (on-change, rate-limited - see match.gd::_grant_visibility for why it's
# still visible to everyone); nobody else ever reads another craft's HP. Every peer used to re-run this same
# math on its own copy and decide the death locally, which only stayed in
# step because HP was streamed to everyone every frame - the death is now an
# explicit broadcast (_broadcast_destroyed) instead, so no peer can ever
# disagree with the server about whether a craft died.
func apply_damage(damage: float, attacker_id: int = 0, cause: int = DeathCause.WEAPON) -> void:
	if not multiplayer.is_server() or _is_destroyed:
		return
	note_attacker(attacker_id)
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
		_death_cause = cause
		_broadcast_destroyed.rpc(NetworkManager.server_time())


# Server-only. 0 (base guns, falls) and the craft's own owner never count.
func note_attacker(attacker_id: int) -> void:
	if attacker_id == 0 or attacker_id == body.get_multiplayer_authority():
		return
	_last_attacker = attacker_id
	_last_attacker_msec = Time.get_ticks_msec()


func _credited_attacker() -> int:
	if _last_attacker != 0 and Time.get_ticks_msec() - _last_attacker_msec <= TAKEDOWN_CREDIT_MSEC:
		return _last_attacker
	return 0


@rpc("authority", "call_local", "reliable")
func _broadcast_destroyed(death_time: float = 0.0) -> void:
	destroy_self(death_time)


# Client-requested, same shape as weapon_node.gd's request_fire(): movement.gd
# is the one that actually detects a landing and measures impact speed
# (that craft's physics are simulated locally by whoever owns it, not the
# server), but only the server gets to decide what that does to HP - this
# just turns an impact speed into real damage through the normal apply_damage
# path above, so fall damage drains shields/armor/life in the same order any
# other hit does.
#
# call_local matters here specifically: rpc_id(1, ...) is a complete no-op,
# not just "runs remotely," when the calling peer's own id IS 1 - i.e.
# whenever the HOST owns the craft that's landing, since the host is always
# peer 1. Without call_local, the host's own hard landings silently never
# dealt fall damage at all; only a client's landings ever reached here.
@rpc("any_peer", "call_local", "reliable")
func request_fall_damage(impact_speed: float) -> void:
	if not multiplayer.is_server():
		return
	# any_peer, so anyone could otherwise call this on ANY craft with any
	# impact_speed - only the peer actually simulating this craft may report
	# its own landings.
	if multiplayer.get_remote_sender_id() != body.get_multiplayer_authority():
		return
	if stats == null or impact_speed <= stats.fall_damage_safe_speed:
		return
	var excess = impact_speed - stats.fall_damage_safe_speed
	apply_damage(stats.fall_damage_coefficient * excess * excess, 0, DeathCause.FALL)


# Armor-then-life heal while parked inside a recon station captured by this
# craft's own team - shields already regen on their own via
# _regeneration_timer above, so this never touches shields. Same fall-through
# shape as apply_damage() above, just reversed: fill armor first, then
# whatever's left over this frame spills into life.
func _process_station_healing(delta: float) -> void:
	if _is_destroyed:
		return
	var at_own_station := _at_own_captured_station()
	if (armor >= _armor_max and life >= _life_max) or not at_own_station:
		return
	var heal := stats.station_heal_rate * delta
	if armor < _armor_max:
		var to_armor = min(heal, _armor_max - armor)
		armor += to_armor
		heal -= to_armor
	if heal > 0.0 and life < _life_max:
		life = min(_life_max, life + heal)
# team lives on weapon_node (see recon_station.gd::color_for_team for the
# string<->enum translation, and power_node.gd for the same lookup pattern) -
# is_body_inside is the same boolean containment check match.gd's capture
# input already relies on, so "healing" and "capturable" always agree.
func _at_own_captured_station() -> bool:
	var weapon_node = body.get_node_or_null("weapon_node")
	if weapon_node == null:
		return false
	var my_color = ReconStation.color_for_team(weapon_node.team)
	if my_color == ReconStation.StationColor.NONE:
		return false
	for recon in get_tree().get_nodes_in_group("Recon"):
		if recon.captured_color == my_color and recon.is_body_inside(body):
			return true
	return false


# Runs on every peer via _broadcast_destroyed above - that's what makes it
# visible to everyone, not just the host.
func destroy_self(death_time: float = 0.0) -> void:
	# Two projectiles landing in the same frame both push life below zero and
	# both arrive here. Without this guard that is two explosions and, worse,
	# two craft_defeated emissions - so a second respawn fires four seconds
	# after the first one and teleports an already-alive player back to spawn.
	if _is_destroyed:
		return
	_is_destroyed = true

	# Other peers draw this craft INTERP_DELAY in the past (movement.gd::
	# _interpolate_remote), so on arrival of the death the wreck is still
	# visibly in the air - the explosion and the vanish wait for the drawn
	# craft to reach the moment it actually died.
	var visual_wait := _remote_visual_delay(death_time)
	if visual_wait > 0.0:
		await get_tree().create_timer(visual_wait).timeout
		# A respawn can't arrive this fast, but never blow up a live craft.
		if not _is_destroyed:
			return
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
		craft_defeated.emit(body.get_multiplayer_authority(), _credited_attacker(), _death_cause)
		_last_attacker = 0


# How long a peer that only watches this craft should hold the explosion, so
# it lands where the interpolated craft is drawn rather than where it already is.
func _remote_visual_delay(death_time: float) -> float:
	if death_time <= 0.0 or body.is_multiplayer_authority() or not NetworkManager.is_clock_synced():
		return 0.0
	var movement_node = body.get_node_or_null("movement_node")
	if movement_node == null:
		return 0.0
	var drawn_time: float = NetworkManager.server_time() - movement_node.INTERP_DELAY
	return clampf(death_time - drawn_time, 0.0, movement_node.MAX_EXTRAPOLATION)


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
		# Only the owner's copy is ever a live dynamic body - every other peer
		# keeps it frozen kinematic and just follows the replicated transform
		# (see movement.gd::_ready), so unfreezing it there would hand a
		# remote craft back to local gravity/collisions.
		if body.is_multiplayer_authority():
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
	# Remote copies smooth toward the last replicated transform - point that
	# at the spawn too, or they'd glide back toward the death spot until the
	# owner's first post-respawn update arrives.
	var movement_node = body.get_node_or_null("movement_node")
	if movement_node and movement_node.has_method("snap_net_target"):
		movement_node.snap_net_target(new_transform)
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
	var movement_node = body.get_node_or_null("movement_node")
	# A grounded craft has nowhere to go but down through the floor if the
	# blast has a downward component - raising the knockback force (see
	# Repulsor/Detno) makes that a bigger single-tick shove than Godot's CCD
	# reliably sweeps against. The floor never needs to push craft further
	# into itself, so while grounded the downward part of the impulse is
	# dropped; the sideways/upward part - the part that actually reads as a
	# "hit" - is untouched.
	if movement_node and movement_node.isGrounded and impulse.y < 0.0:
		impulse.y = 0.0
	body.apply_central_impulse(impulse)
	# movement.gd hard-sets linear velocity to max_speed every tick while
	# grounded, which erases the shove on the very next tick. Ask it to stand
	# off briefly so the knockback actually plays out.
	if movement_node and movement_node.has_method("apply_knockback_grace"):
		movement_node.apply_knockback_grace()


# Weapon freeze, routed to the owner for the same reason as apply_impulse:
# setFreezeState only stops the movement_node that actually simulates the
# craft, and on the server that is only ever the host's own tank. duration > 0
# freezes (extending, never shortening, a freeze already running); 0 unfreezes.
# The timer lives here on the owner too, so overlapping freezes can't have an
# earlier one's timeout thaw a later one early.
@rpc("authority", "call_local", "reliable")
func apply_weapon_freeze(duration: float) -> void:
	if _is_destroyed or _weapon_freeze_timer == null or not body.is_multiplayer_authority():
		return
	if duration <= 0.0:
		_weapon_freeze_timer.stop()
		_set_movement_frozen(false)
		return
	if _weapon_freeze_timer.is_stopped() or _weapon_freeze_timer.time_left < duration:
		_weapon_freeze_timer.start(duration)
	_set_movement_frozen(true)


func _on_weapon_freeze_timeout() -> void:
	# A craft that died mid-freeze stays parked until respawn_at thaws it.
	if not _is_destroyed:
		_set_movement_frozen(false)


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

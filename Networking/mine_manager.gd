extends Node
class_name MineManager

# Lay / blow / replicate mines. Child of the match node (see match.gd::_ready).
#
# Same split as projectiles: the server is the only one that decides anything
# (laying is validated here, detonation is decided by mine.gd on the server),
# and every peer just mirrors the result - one reliable spawn event per mine,
# one reliable explode event, so mines are never streamed. Mines are children
# of this node, named by id, so every peer holds the same set.

const MINE_SCENE := preload("res://Weapons/Scenes/mines/land_mine.tscn")
const EXPLOSION := preload("res://Weapons/Scenes/explosions/shockwave.tscn")
const EXPLOSION_SOUND := preload("res://Weapons/Sounds/HitHard.wav")
const EXPLOSION_SCALE := 1.5

const MAX_MINES_PER_PLAYER := 6
const LAY_COOLDOWN_MSEC := 1000
# A mine can only be laid with ground this close underneath the craft.
const GROUND_RAY_LENGTH := 4.0

const BLAST_RADIUS := 8.0
const BLAST_DAMAGE := 60.0 # at the centre, falls off linearly to 0 at the edge
const BLAST_FORCE := 40.0 # knockback impulse, same falloff
const BLAST_MAX_BODIES := 16

# id -> Mine, on every peer.
var _mines: Dictionary = {}
# Server only.
var _next_id: int = 1
var _last_lay_msec: Dictionary = {}

@onready var _match: Node = get_parent()


# --- Input side (called by the owning peer's weapon_node.gd) ----------------

@rpc("any_peer", "call_local", "reliable")
func request_lay_mine() -> void:
	if not multiplayer.is_server() or not NetworkManager.mines_enabled:
		return
	var sender := _sender()
	var craft = _match.craft_container.get_node_or_null("Craft_%d" % sender)
	var team: String = NetworkManager.peer_teams.get(sender, "")
	# Not visible = destroyed and waiting to respawn (health_node.destroy_self).
	if craft == null or team == "" or not craft.visible:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_lay_msec.get(sender, -LAY_COOLDOWN_MSEC)) < LAY_COOLDOWN_MSEC:
		return
	if _mines_of(sender).size() >= MAX_MINES_PER_PLAYER:
		return
	var query := PhysicsRayQueryParameters3D.create(
		craft.global_position,
		craft.global_position + Vector3.DOWN * GROUND_RAY_LENGTH,
		1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1))
	var hit: Dictionary = craft.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	_last_lay_msec[sender] = now
	var id := _next_id
	_next_id += 1
	# Lie flat on the surface: up = ground normal, facing = the craft's
	# heading flattened onto that surface.
	var up: Vector3 = hit.normal
	var heading: Vector3 = craft.global_basis.z
	heading = (heading - up * heading.dot(up)).normalized()
	if heading.is_zero_approx():
		heading = up.cross(Vector3.RIGHT).normalized()
	var placement := Transform3D(Basis(up.cross(heading), up, heading), hit.position)
	_create_mine(id, sender, team, placement)
	for peer_id in _match._ready_peers:
		if peer_id != 1:
			_spawn_mine_event.rpc_id(peer_id, id, sender, team, placement)


@rpc("any_peer", "call_local", "reliable")
func request_blow_mines() -> void:
	if not multiplayer.is_server():
		return
	for mine in _mines_of(_sender()):
		detonate(mine.id)


# --- Server: detonation ------------------------------------------------------

# Server only. Damage first, then tell everyone to show it and drop the mine.
func detonate(id: int) -> void:
	if not multiplayer.is_server() or not _mines.has(id):
		return
	var mine: Mine = _mines[id]
	_apply_blast(mine)
	_explode.rpc(id, true)


func _apply_blast(mine: Mine) -> void:
	var targets: Array = Utilities.GROUP_LAYER_SCOPE.get(mine.team, {}).get("target_groups", [])
	var centre := mine.global_position
	var hits := Utilities.collect_bodies(
		mine.get_world_3d().direct_space_state, centre + Vector3.UP * 0.5,
		BLAST_MAX_BODIES, BLAST_RADIUS, targets)
	var done: Dictionary = {}
	for item in hits:
		var body = item.collider
		if done.has(body) or not is_instance_valid(body):
			continue
		done[body] = true
		var distance := centre.distance_to(body.global_position)
		if distance >= BLAST_RADIUS:
			continue
		var falloff := 1.0 - distance / BLAST_RADIUS
		var health_node = body.get_node_or_null("health_node")
		if health_node == null:
			continue
		if health_node.has_method("apply_impulse"):
			# Always some lift, so a mine under a grounded craft shoves it
			# rather than pushing it into the floor.
			var direction: Vector3 = body.global_position - centre
			direction.y = maxf(direction.y, 0.5)
			health_node.note_attacker(mine.owner_peer)
			health_node.apply_impulse.rpc(direction.normalized() * BLAST_FORCE * falloff)
		health_node.apply_damage(BLAST_DAMAGE * falloff, mine.owner_peer, HealthNode.DeathCause.MINE)


# --- Replication ---------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _spawn_mine_event(id: int, owner_peer: int, team: String, placement: Transform3D) -> void:
	_create_mine(id, owner_peer, team, placement)


@rpc("authority", "call_local", "reliable")
func _explode(id: int, with_effect: bool) -> void:
	var mine: Mine = _mines.get(id)
	if mine == null:
		return
	_mines.erase(id)
	if with_effect:
		var explosion := EXPLOSION.instantiate()
		add_child(explosion)
		explosion.global_position = mine.global_position
		explosion.scale = Vector3.ONE * EXPLOSION_SCALE
		Utilities.GarbageCollection(explosion, 5.0)
		Utilities.play_sound(EXPLOSION_SOUND, mine.global_position)
	mine.queue_free()


func _create_mine(id: int, owner_peer: int, team: String, placement: Transform3D) -> void:
	var mine: Mine = MINE_SCENE.instantiate()
	mine.name = "Mine_%d" % id
	mine.id = id
	mine.owner_peer = owner_peer
	mine.team = team
	mine.manager = self
	mine.transform = placement
	add_child(mine)
	_mines[id] = mine


# Server only. A late joiner never saw the spawn events.
func sync_to(peer_id: int) -> void:
	for mine in _mines.values():
		_spawn_mine_event.rpc_id(peer_id, mine.id, mine.owner_peer, mine.team, mine.transform)


# Server only. A player leaving takes their mines with them, quietly.
func remove_player_mines(peer_id: int) -> void:
	for mine in _mines_of(peer_id):
		_explode.rpc(mine.id, false)
	_last_lay_msec.erase(peer_id)


func _mines_of(peer_id: int) -> Array:
	var result: Array = []
	for mine in _mines.values():
		if mine.owner_peer == peer_id:
			result.append(mine)
	return result


# 0 when the host calls an any_peer RPC on itself.
func _sender() -> int:
	var sender := multiplayer.get_remote_sender_id()
	return 1 if sender == 0 else sender

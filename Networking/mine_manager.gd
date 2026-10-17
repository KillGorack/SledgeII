extends Node
class_name MineManager

# Lay / blow / replicate mines. Child of the match node (see match.gd::_ready).
# What a mine IS comes from its MineSettings (Weapons/settings_mines/*.tres),
# taken from the laying craft's weapon_node.mine_settings (the server's own
# filtered copy, indexed by the client's choice - bounds-checked).
#
# Same split as projectiles: the server is the only one that decides anything
# (laying is validated here, detonation is decided by mine.gd on the server),
# and every peer just mirrors the result - one reliable spawn event per mine,
# one reliable explode event, so mines are never streamed. Mines are children
# of this node, named by id, so every peer holds the same set.

# A mine can only be laid with ground this close underneath the craft.
const GROUND_RAY_LENGTH := 4.0
const BLAST_MAX_BODIES := 16

# id -> Mine, on every peer.
var _mines: Dictionary = {}
# Server only.
var _next_id: int = 1
var _last_lay_msec: Dictionary = {}

@onready var _match: Node = get_parent()


# --- Input side (called by the owning peer's weapon_node.gd) ----------------

@rpc("any_peer", "call_local", "reliable")
func request_lay_mine(mine_index: int = 0) -> void:
	if not multiplayer.is_server() or not NetworkManager.mines_enabled:
		return
	var sender := _sender()
	var craft = _match.craft_container.get_node_or_null("Craft_%d" % sender)
	var team: String = NetworkManager.peer_teams.get(sender, "")
	# Not visible = destroyed and waiting to respawn (health_node.destroy_self).
	if craft == null or team == "" or not craft.visible:
		return
	# The server's own view of which mine this craft carries, never the client's.
	var settings := _settings_of(craft, mine_index)
	if settings == null or settings.resource_path.is_empty() or settings.mine_prefab == null:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_lay_msec.get(sender, -1000000)) < int(settings.cool_down * 1000.0):
		return
	if _mines_of(sender).size() >= settings.max_count:
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
	_create_mine(id, sender, team, settings.resource_path, placement, true)
	for peer_id in _match._ready_peers:
		if peer_id != 1:
			_spawn_mine_event.rpc_id(peer_id, id, sender, team, settings.resource_path, placement, true)


@rpc("any_peer", "call_local", "reliable")
func request_blow_mines() -> void:
	if not multiplayer.is_server():
		return
	for mine in _mines_of(_sender()):
		if mine.settings.remote_detonate:
			detonate(mine.id)


# --- Server: detonation ------------------------------------------------------

# Server only. Damage and force first, then tell everyone to show it and drop
# the mine.
func detonate(id: int) -> void:
	if not multiplayer.is_server() or not _mines.has(id):
		return
	_apply_blast(_mines[id])
	_explode.rpc(id, true)


# Server only. Life span ran out: the mine just goes away, quietly.
func expire(id: int) -> void:
	if multiplayer.is_server() and _mines.has(id):
		_explode.rpc(id, false)


func _apply_blast(mine: Mine) -> void:
	var s := mine.settings
	if s.hit_points <= 0.0 and s.explosive_force <= 0.0 and s.freeze_timer <= 0.0:
		return
	var targets: Array = Utilities.GROUP_LAYER_SCOPE.get(mine.team, {}).get("target_groups", []).duplicate()
	if s.friendly_fire:
		targets.append(mine.team)
	var centre := mine.global_position
	var hits := Utilities.collect_bodies(
		mine.get_world_3d().direct_space_state, centre + Vector3.UP * 0.5,
		BLAST_MAX_BODIES, s.explosive_force_distance, targets)
	var done: Dictionary = {}
	for item in hits:
		var body = item.collider
		if done.has(body) or not is_instance_valid(body):
			continue
		done[body] = true
		var distance := centre.distance_to(body.global_position)
		if distance >= s.explosive_force_distance:
			continue
		var falloff := 1.0 - distance / s.explosive_force_distance
		var health_node = body.get_node_or_null("health_node")
		if health_node == null:
			continue
		# Each effect on its own terms: a force-only mine never damages, a
		# damage-only mine never pushes.
		if s.freeze_timer > 0.0 and health_node.has_method("apply_weapon_freeze"):
			health_node.apply_weapon_freeze.rpc(s.freeze_timer)
		if s.explosive_force > 0.0 and health_node.has_method("apply_impulse"):
			# Always some lift, so a mine under a grounded craft shoves it
			# rather than pushing it into the floor.
			var direction: Vector3 = body.global_position - centre
			direction.y = maxf(direction.y, 0.5)
			# A shove that ends in a fall or a death is the owner's doing.
			health_node.note_attacker(mine.owner_peer)
			health_node.apply_impulse.rpc(direction.normalized() * s.explosive_force * falloff)
		if s.hit_points > 0.0:
			health_node.apply_damage(s.hit_points * falloff, mine.owner_peer, HealthNode.DeathCause.MINE)


# --- Replication ---------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _spawn_mine_event(id: int, owner_peer: int, team: String, settings_path: String, placement: Transform3D, fresh: bool) -> void:
	_create_mine(id, owner_peer, team, settings_path, placement, fresh)


@rpc("authority", "call_local", "reliable")
func _explode(id: int, with_effect: bool) -> void:
	var mine: Mine = _mines.get(id)
	if mine == null:
		return
	_mines.erase(id)
	if with_effect:
		var s := mine.settings
		if s.explosion_prefab:
			var explosion := s.explosion_prefab.instantiate()
			add_child(explosion)
			explosion.global_position = mine.global_position
			explosion.scale = Vector3.ONE * s.explosion_scale
			Utilities.GarbageCollection(explosion, 5.0)
		if s.explosion_sound:
			Utilities.play_sound(s.explosion_sound, mine.global_position)
	mine.queue_free()


# fresh = just laid (plays the lay sound); false for a late joiner catching up.
func _create_mine(id: int, owner_peer: int, team: String, settings_path: String, placement: Transform3D, fresh: bool) -> void:
	var settings: MineSettings = load(settings_path)
	if settings == null or settings.mine_prefab == null:
		return
	var mine: Mine = settings.mine_prefab.instantiate()
	mine.name = "Mine_%d" % id
	mine.id = id
	mine.owner_peer = owner_peer
	mine.team = team
	mine.settings = settings
	mine.manager = self
	mine.transform = placement
	add_child(mine)
	_mines[id] = mine
	if fresh and settings.lay_sound:
		Utilities.play_sound(settings.lay_sound, placement.origin)


# Server only. A late joiner never saw the spawn events.
func sync_to(peer_id: int) -> void:
	for mine in _mines.values():
		_spawn_mine_event.rpc_id(peer_id, mine.id, mine.owner_peer, mine.team, mine.settings.resource_path, mine.transform, false)


# Server only. A player leaving takes their mines with them, quietly.
func remove_player_mines(peer_id: int) -> void:
	for mine in _mines_of(peer_id):
		_explode.rpc(mine.id, false)
	_last_lay_msec.erase(peer_id)


# Any peer: every peer holds the full mine set, so the HUD can count its own.
func mines_left(peer_id: int, max_count: int) -> int:
	return maxi(0, max_count - _mines_of(peer_id).size())


func _mines_of(peer_id: int) -> Array:
	var result: Array = []
	for mine in _mines.values():
		if mine.owner_peer == peer_id:
			result.append(mine)
	return result


func _settings_of(craft: Node, mine_index: int) -> MineSettings:
	var weapon_node = craft.get_node_or_null("weapon_node")
	if weapon_node == null or mine_index < 0 or mine_index >= weapon_node.mine_settings.size():
		return null
	return weapon_node.mine_settings[mine_index]


# 0 when the host calls an any_peer RPC on itself.
func _sender() -> int:
	var sender := multiplayer.get_remote_sender_id()
	return 1 if sender == 0 else sender

extends Node
class_name GunController

# The Controller special (SpecialCatalog.CONTROLLER). Child of the match node,
# like MineManager. A player calls their team's base guns out to where their
# craft is (M) and sends the ones they called home again (Shift+M).
#
# Called guns land on a CELL_SIZE grid, one gun per cell: the caller's own cell
# first, then the free cell nearest to them, ring by ring, so spamming M builds
# a tight cluster instead of a stack. A deployed gun stays where it is until
# it's sent home, shot down (it respawns at base as always, base_gun.gd), or
# taken for a recon capture, which outranks a call (match.gd::_find_available_gun).
# With every gun gone from base, a call takes a teammate's deployed gun, the
# longest-deployed first.
#
# Same split as mines: the server decides which gun and where, then every peer
# flies that same gun to that same point. The state lives on the guns
# themselves (base_gun.gd's deployed_owner / deploy_cell / deploy_order), so
# a gun that dies or is taken for a capture frees its cell with no bookkeeping
# here.

const CELL_SIZE := 2.0
# How many rings out from the caller's own cell to look for a free one.
const MAX_RING := 4
# Height of a deployed gun above the ground under its cell.
const HOVER_HEIGHT := 3.0
# The ground ray starts this far above the craft (low enough to stay under a
# bridge or overhang the craft is under) and reaches this far below it.
const GROUND_RAY_UP := 1.5
const GROUND_RAY_DOWN := 20.0
# A cell whose hover point is inside the level, or that the craft can't see, is skipped.
const CLEARANCE_RADIUS := 0.8
const CALL_COOLDOWN_MSEC := 200

# Server only.
var _next_order: int = 1
var _last_call_msec: Dictionary = {}

@onready var _match: Node = get_parent()


static func is_enabled() -> bool:
	return NetworkManager.allowed_specials.has(SpecialCatalog.CONTROLLER)


# --- Input side (called by the owning peer's weapon_node.gd) ----------------

@rpc("any_peer", "call_local", "reliable")
func request_call() -> void:
	if not multiplayer.is_server() or not is_enabled():
		return
	var sender := _sender()
	var craft = _match.craft_container.get_node_or_null("Craft_%d" % sender)
	var team: String = NetworkManager.peer_teams.get(sender, "")
	# Not visible = destroyed and waiting to respawn (health_node.destroy_self).
	if craft == null or team == "" or not craft.visible:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_call_msec.get(sender, -1000000)) < CALL_COOLDOWN_MSEC:
		return
	var gun: BaseGun = _pick_gun(team, sender)
	if gun == null:
		return
	var spot := _pick_spot(craft, gun)
	if spot.is_empty():
		return
	_last_call_msec[sender] = now
	var order := _next_order
	_next_order += 1
	var gun_path: NodePath = _match.get_path_to(gun)
	_deploy(gun_path, sender, spot.cell, order, spot.position, true)
	for peer_id in _match._ready_peers:
		if peer_id != 1:
			_deploy.rpc_id(peer_id, gun_path, sender, spot.cell, order, spot.position, true)


@rpc("any_peer", "call_local", "reliable")
func request_recall() -> void:
	if not multiplayer.is_server():
		return
	_recall_guns_of(_sender())


# --- Server: choosing ------------------------------------------------------------

# A gun at base first; with none left, a teammate's deployed gun (never your
# own - that would only shuffle it), longest-deployed first. A gun on a recon
# capture (is_busy) is never taken.
func _pick_gun(team: String, sender: int) -> BaseGun:
	var guns: Array = _match._base_guns_by_team.get(team, [])
	for gun in guns:
		if not gun.is_dead and not gun.is_busy and gun.deployed_owner == 0:
			return gun
	var oldest: BaseGun = null
	for gun in guns:
		if gun.is_dead or gun.is_busy or gun.deployed_owner == 0 or gun.deployed_owner == sender:
			continue
		if oldest == null or gun.deploy_order < oldest.deploy_order:
			oldest = gun
	return oldest


# {cell, position} of the free cell nearest the craft, or {} when every cell in
# reach is taken or unusable. Cells are shared by every team: guns never stack.
func _pick_spot(craft: Node3D, gun: BaseGun) -> Dictionary:
	var taken: Dictionary = {}
	for other in get_tree().get_nodes_in_group("BaseGunAll"):
		if other != gun and other.deployed_owner != 0:
			taken[other.deploy_cell] = true
	var origin := craft.global_position
	var flat_origin := Vector2(origin.x, origin.z)
	var home := Vector2i(floori(origin.x / CELL_SIZE), floori(origin.z / CELL_SIZE))
	var space := craft.get_world_3d().direct_space_state
	for ring in MAX_RING + 1:
		var cells: Array[Vector2i] = []
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) == ring:
					cells.append(home + Vector2i(dx, dz))
		cells.sort_custom(func(a: Vector2i, b: Vector2i):
			return _cell_centre(a).distance_squared_to(flat_origin) < _cell_centre(b).distance_squared_to(flat_origin))
		for cell in cells:
			if taken.has(cell):
				continue
			var hover = _hover_point(space, cell, origin)
			if hover != null:
				return {"cell": cell, "position": hover}
	return {}


# Where a gun would hover over this cell, or null if there's no ground under
# it, the point is inside the level, or the craft can't see it (no guns
# dropped on the far side of a wall).
func _hover_point(space: PhysicsDirectSpaceState3D, cell: Vector2i, origin: Vector3) -> Variant:
	var world_mask := 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)
	var centre := _cell_centre(cell)
	var ground := PhysicsRayQueryParameters3D.create(
		Vector3(centre.x, origin.y + GROUND_RAY_UP, centre.y),
		Vector3(centre.x, origin.y - GROUND_RAY_DOWN, centre.y), world_mask)
	var hit := space.intersect_ray(ground)
	if hit.is_empty():
		return null
	var hover: Vector3 = hit.position + Vector3.UP * HOVER_HEIGHT
	var sphere := SphereShape3D.new()
	sphere.radius = CLEARANCE_RADIUS
	var clearance := PhysicsShapeQueryParameters3D.new()
	clearance.shape = sphere
	clearance.transform = Transform3D(Basis.IDENTITY, hover)
	clearance.collision_mask = world_mask
	if not space.intersect_shape(clearance, 1).is_empty():
		return null
	var sight := PhysicsRayQueryParameters3D.create(origin + Vector3.UP, hover, world_mask)
	if not space.intersect_ray(sight).is_empty():
		return null
	return hover


func _cell_centre(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_SIZE


func _recall_guns_of(peer_id: int) -> void:
	for gun in get_tree().get_nodes_in_group("BaseGunAll"):
		if gun.deployed_owner != peer_id:
			continue
		var gun_path: NodePath = _match.get_path_to(gun)
		_recall(gun_path)
		for ready_peer in _match._ready_peers:
			if ready_peer != 1:
				_recall.rpc_id(ready_peer, gun_path)


# --- Replication ---------------------------------------------------------------

# fly = false for a late joiner catching up: the gun is just put there.
@rpc("authority", "call_remote", "reliable")
func _deploy(gun_path: NodePath, owner_peer: int, cell: Vector2i, order: int, target: Vector3, fly: bool) -> void:
	var gun = _match.get_node_or_null(gun_path)
	if gun is BaseGun:
		gun.deploy(owner_peer, cell, order, target, fly)


@rpc("authority", "call_remote", "reliable")
func _recall(gun_path: NodePath) -> void:
	var gun = _match.get_node_or_null(gun_path)
	if gun is BaseGun:
		gun.send_home()


# Server only. A late joiner never saw the calls.
func sync_to(peer_id: int) -> void:
	for gun in get_tree().get_nodes_in_group("BaseGunAll"):
		if gun.deployed_owner != 0 and not gun.is_dead:
			_deploy.rpc_id(peer_id, _match.get_path_to(gun), gun.deployed_owner, gun.deploy_cell, gun.deploy_order, gun.deploy_target, false)


# Server only. A player leaving sends the guns they called back to base.
func remove_player(peer_id: int) -> void:
	_recall_guns_of(peer_id)
	_last_call_msec.erase(peer_id)


# Any peer, for the HUD: this team's guns that are at (or heading back to) base and free.
func guns_at_base(team: String) -> int:
	var count := 0
	for gun in _match._base_guns_by_team.get(team, []):
		if not gun.is_dead and not gun.is_busy and gun.deployed_owner == 0:
			count += 1
	return count


func gun_count(team: String) -> int:
	return _match._base_guns_by_team.get(team, []).size()


# 0 when the host calls an any_peer RPC on itself.
func _sender() -> int:
	var sender := multiplayer.get_remote_sender_id()
	return 1 if sender == 0 else sender

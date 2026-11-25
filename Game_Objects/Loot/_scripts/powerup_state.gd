extends Node
class_name PowerupState

# The craft's active powerups. They live HERE, never on the weapon .tres files. Every peer that cares (server
# for the real shot, owner for prediction + HUD, others for the look) holds the same list, sent by the server
# whenever it changes. Expiry is the server's call; each peer also keeps a local end time purely to draw the
# HUD countdown. A child of the craft's weapon_node (made in weapon_node.gd::_init, so it exists before any
# other node's _ready) - reach it as weapon_node.powerups.

signal changed

# How many active powerups the HUD bar and the orbit coins have room to show - more than there are powerups,
# so nothing running is ever hidden. Raise it if the powerup list outgrows it.
const MAX_SHOWN := 12

# Longest a powerup can be stacked up to, so repeated pickups can't bank an hour of it.
const MAX_STACK_SECONDS := 300.0

var _active: Array[Powerup] = []
var _end_msec: Dictionary = {} # powerup resource_path -> local end time
var _ops_cache: Dictionary = {} # base WeaponSettings -> merged ops for ITS kind
var _effective_cache: Dictionary = {} # base WeaponSettings -> powered-up duplicate
var _factor_cache: Dictionary = {} # craft stat -> factor


# The weapon as this craft currently fires it: base, plus active powerups.
func effective(base: WeaponSettings) -> WeaponSettings:
	var ops := ops_for(base)
	if ops.is_empty():
		return base
	if not _effective_cache.has(base):
		_effective_cache[base] = Powerup.apply_ops(base, ops)
	return _effective_cache[base]


# What the active powerups do to THIS weapon (only changes that target its kind).
# Sent with every shot so other peers build the same weapon.
func ops_for(base: WeaponSettings) -> Dictionary:
	if _active.is_empty() or base == null:
		return {}
	if not _ops_cache.has(base):
		_ops_cache[base] = Powerup.resolve(_active, base.weapon_kind)
	return _ops_cache[base]


# The factor active powerups apply to a craft stat (1.0 if none).
func factor(stat: String) -> float:
	if _active.is_empty():
		return 1.0
	if not _factor_cache.has(stat):
		_factor_cache[stat] = Powerup.craft_factor(_active, stat)
	return _factor_cache[stat]


# For the radar: is anything running? (No allocation.)
func has_any() -> bool:
	return not _active.is_empty()


# For the HUD and the orbit coins: [{powerup: Powerup, left: seconds}]
func status() -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	for powerup in _active:
		out.append({"powerup": powerup, "left": maxf(0.0, (_end_msec.get(powerup.resource_path, now) - now) / 1000.0)})
	return out


# When a powerup ends after another pickup of it: the time it still has PLUS the new duration (picking one up
# while it runs adds to it, it doesn't restart it), or just the new duration if it wasn't running. Capped at
# MAX_STACK_SECONDS from now.
static func end_after_pickup(now_msec: int, current_end_msec: int, duration: float) -> int:
	var start := maxi(now_msec, current_end_msec)
	return mini(start + int(duration * 1000.0), now_msec + int(MAX_STACK_SECONDS * 1000.0))


# Server only. A pickup is always "used".
func server_grant(powerup: Powerup) -> bool:
	if not multiplayer.is_server() or powerup == null or powerup.resource_path.is_empty():
		return false
	var now := Time.get_ticks_msec()
	var end := end_after_pickup(now, int(_end_msec.get(powerup.resource_path, 0)), powerup.duration)
	_end_msec[powerup.resource_path] = end
	_changed_on_server()
	if powerup.refill_shields:
		var health := _craft().get_node_or_null("health_node") if _craft() != null else null
		if health != null:
			health.powerup_granted(powerup)
	# An earlier pickup's timer may fire first - _expire only removes what has really run out.
	get_tree().create_timer((end - now) / 1000.0 + 0.05).timeout.connect(_expire)
	return true


func _craft() -> Node:
	var weapon_node := get_parent()
	return weapon_node.get_parent() if weapon_node != null else null


func _expire() -> void:
	var now := Time.get_ticks_msec()
	var any := false
	for path in _end_msec.keys():
		if _end_msec[path] <= now:
			_end_msec.erase(path)
			any = true
	if any:
		_changed_on_server()


# Rebuild from the end-time table, tell every ready peer.
func _changed_on_server() -> void:
	var paths := PackedStringArray()
	var left := PackedFloat32Array()
	var now := Time.get_ticks_msec()
	for path in _end_msec:
		paths.append(path)
		left.append(maxf(0.0, (_end_msec[path] - now) / 1000.0))
	_apply(paths, left)
	var match_node = get_tree().get_first_node_in_group("match")
	if match_node == null:
		return
	for peer_id in match_node._ready_peers:
		if peer_id != 1:
			_sync.rpc_id(peer_id, paths, left)


# Server only. Catch a late joiner up on every craft's running powerups - called from match.gd::_notify_ready.
static func sync_all_to(tree: SceneTree, peer_id: int) -> void:
	for craft in tree.get_nodes_in_group("Craft"):
		var weapon_node := craft.get_node_or_null("weapon_node")
		if weapon_node != null and weapon_node.get("powerups") != null:
			weapon_node.powerups.sync_to(peer_id)


# Server only. A late joiner is told what this craft already has running (otherwise they'd only find out at the next
# change - no orbit coins or radar ring until then). Shots were never affected: each one carries its own ops.
func sync_to(peer_id: int) -> void:
	if not multiplayer.is_server() or _end_msec.is_empty() or peer_id == 1:
		return
	var paths := PackedStringArray()
	var left := PackedFloat32Array()
	var now := Time.get_ticks_msec()
	for path in _end_msec:
		paths.append(path)
		left.append(maxf(0.0, (_end_msec[path] - now) / 1000.0))
	_sync.rpc_id(peer_id, paths, left)


@rpc("any_peer", "call_remote", "reliable")
func _sync(paths: PackedStringArray, left: PackedFloat32Array) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	_apply(paths, left)


func _apply(paths: PackedStringArray, left: PackedFloat32Array) -> void:
	_active.clear()
	_end_msec.clear()
	var now := Time.get_ticks_msec()
	for i in paths.size():
		var powerup := load(paths[i]) as Powerup
		if powerup == null:
			continue
		powerup.check()
		_active.append(powerup)
		_end_msec[paths[i]] = now + int(left[i] * 1000.0)
	_reset_caches()
	changed.emit()


# Destruction: every peer drops its powerups locally (see weapon_node.gd::revoke_granted).
func clear() -> void:
	if _active.is_empty() and _end_msec.is_empty():
		return
	_active.clear()
	_end_msec.clear()
	_reset_caches()
	changed.emit()


func _reset_caches() -> void:
	_ops_cache.clear()
	_effective_cache.clear()
	_factor_cache.clear()

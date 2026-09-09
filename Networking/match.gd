extends Node3D

const LIGHTNING_SCENE := preload("res://Crafts/Scenes/lightning.tscn")
const MAP_SCENE_PATH := "res://secret_level.tscn"
# Each downloaded map gets its own file, named by file_id, rather than one
# shared filename every download used to overwrite - see _load_map/_download_map.
# Safe to keep forever: file_id is assigned fresh per upload (confirmed with
# the user), so a given id's content never changes after the fact - there is
# no staleness case to invalidate against.
const MAP_CACHE_DIR := "user://secret_levels/"
const LOCAL_TEST_PACK := "res://map.pck"
const DOWNLOAD_URL := "https://www.killgorack.com/PX4/downloader.php?ap=tanarusmaps&fileid=%s&type=file&cn=fls"
# A self-contained WorldEnvironment scene that replaces whatever sky/env
# each downloaded map ships with its own - no need to touch or re-export any
# map file for this.
const CUSTOM_ENVIRONMENT_SCENE := preload("res://Materials/Environments/env.tscn")
const RESPAWN_DELAY := 4.0
# Must match movement.gd's SELF_RENDER_LAYER - whichever craft is currently
# locally-owned puts its own body meshes on this layer (see
# movement.gd::_hide_own_body), and the one persistent camera below
# permanently excludes it, regardless of which craft currently owns the
# camera across spawns/respawns.
const SELF_RENDER_LAYER := 20

@onready var craft_container: Node3D = $Crafts
@onready var spawner: MultiplayerSpawner = $CraftSpawner
@onready var projectile_spawner: MultiplayerSpawner = $ProjectileSpawner
@onready var loading_screen: CanvasLayer = $LoadingScreen
# The one Camera3D that exists for this client, for the whole match. It is
# never created/destroyed alongside a craft - only ever reparented onto
# whichever craft you currently own (see _attach_local_camera) - so there is
# never a window with zero or ambiguous cameras during spawn/respawn, and
# nothing else in the scene ever competes with it for "current".
@onready var local_camera: Camera3D = $LocalCamera

var _spawned_peers: Dictionary = {}
var _spawn_points: Array = []
var _map_ready: bool = false
var _pending_unfreeze: Array = []


func _ready() -> void:
	print("[JOIN] t=%dms match.tscn _ready() started" % NetworkManager._debug_join_elapsed_ms())
	add_to_group("match")
	local_camera.current = true
	local_camera.cull_mask = ((1 << 20) - 1) & ~(1 << (SELF_RENDER_LAYER - 1))
	spawner.spawn_function = _spawn_craft
	projectile_spawner.spawn_function = _spawn_projectile
	await _load_map()
	print("[JOIN] t=%dms _load_map() finished" % NetworkManager._debug_join_elapsed_ms())
	_map_ready = true
	for craft in _pending_unfreeze:
		if is_instance_valid(craft):
			craft.freeze = false
	_pending_unfreeze.clear()
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_unregistered.connect(_on_player_unregistered)
	# Backfill: peers may already be registered (e.g. the host itself) by the
	# time this scene loads, since NetworkManager persists across the scene
	# change and its signal can fire before match.tscn finishes loading.
	for peer_id in NetworkManager.peer_teams.keys():
		_on_player_registered(peer_id, NetworkManager.peer_teams[peer_id])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("exit_main"):
		_exit_to_main_menu()


func _exit_to_main_menu() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://UI/index.tscn")


func _load_map() -> void:
	var target_file_id = NetworkManager.current_map_file_id
	if target_file_id > 0:
		# Every map's .pck exports the same virtual path, so "does
		# res://secret_level.tscn already exist" can't tell maps apart - the
		# mounted_map_file_id check is just a same-session fast path (skip all
		# of this if we're already using this exact map right now); the real
		# cache is the per-file_id path on disk below, which survives an app
		# restart too.
		if NetworkManager.mounted_map_file_id != target_file_id:
			var pck_path = _cached_map_path(target_file_id)
			var was_cached = FileAccess.file_exists(pck_path)
			if not was_cached:
				await _download_map(target_file_id, pck_path)
			if not FileAccess.file_exists(pck_path):
				push_warning("Match: map %d unavailable, download failed" % target_file_id)
				return
			print("[JOIN] t=%dms map file ready (was_cached=%s)" % [NetworkManager._debug_join_elapsed_ms(), was_cached])
			ProjectSettings.load_resource_pack(pck_path)
			NetworkManager.mounted_map_file_id = target_file_id
			print("[JOIN] t=%dms load_resource_pack() done" % NetworkManager._debug_join_elapsed_ms())
	elif not ResourceLoader.exists(MAP_SCENE_PATH):
		# No map selected (e.g. match.tscn opened directly for testing) -
		# fall back to whatever local test pack is sitting in the project.
		ProjectSettings.load_resource_pack(LOCAL_TEST_PACK)
	if not ResourceLoader.exists(MAP_SCENE_PATH):
		push_warning("Match: could not load map scene at %s" % MAP_SCENE_PATH)
		return
	# Bypass Godot's default load() caching-by-path - without this, a second
	# map mounted over the same virtual path would still return the first
	# map's already-cached scene instead of the new one. Note: this forces a
	# full re-parse from the .pck every time regardless of file-level
	# caching above - if the [JOIN] prints show this specific step as the
	# slow one, that's the next thing worth optimizing (skip CACHE_MODE_REPLACE
	# entirely when mounted_map_file_id didn't actually change).
	var map_scene: PackedScene = ResourceLoader.load(MAP_SCENE_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	print("[JOIN] t=%dms ResourceLoader.load() (parse) done" % NetworkManager._debug_join_elapsed_ms())
	var map_instance := map_scene.instantiate()
	print("[JOIN] t=%dms map_scene.instantiate() done" % NetworkManager._debug_join_elapsed_ms())
	add_child(map_instance)
	_apply_custom_environment(map_instance)
	print("[JOIN] t=%dms _apply_custom_environment() done" % NetworkManager._debug_join_elapsed_ms())
	var overrides = get_tree().get_nodes_in_group("PlayerSpawnOverride")
	_spawn_points = overrides if overrides.size() > 0 else get_tree().get_nodes_in_group("PlayerSpawn")


# These are auto-generated/community maps - neither their baked environment
# nor their sun's direction/color is deliberate art direction worth keeping,
# just whatever the map editor defaulted to. Rather than swap the environment
# and separately patch shadow properties onto the map's own light in place,
# strip both of the map's nodes and drop in one self-contained env.tscn that
# owns sky, fog, and the sun together - one thing to tune, applied uniformly.
func _apply_custom_environment(map_instance: Node) -> void:
	var map_world_env := _find_world_environment(map_instance)
	if map_world_env:
		map_world_env.queue_free()
	var map_sun := _find_directional_light(map_instance)
	if map_sun:
		map_sun.queue_free()
	add_child(CUSTOM_ENVIRONMENT_SCENE.instantiate())


func _find_world_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node
	for child in node.get_children():
		var found := _find_world_environment(child)
		if found:
			return found
	return null


func _find_directional_light(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		return node
	for child in node.get_children():
		var found := _find_directional_light(child)
		if found:
			return found
	return null


func _cached_map_path(file_id: int) -> String:
	return MAP_CACHE_DIR.path_join("%d.pck" % file_id)


# Writes the file only - _load_map decides whether/when to mount it, and
# checking FileAccess.file_exists() again there after this returns is what
# actually tells it whether this succeeded, rather than a separate return
# value here.
func _download_map(map_file_id: int, pck_path: String) -> void:
	var dir_access = DirAccess.open("user://")
	dir_access.make_dir_recursive(MAP_CACHE_DIR)
	var http_request := HTTPRequest.new()
	add_child(http_request)
	http_request.request(DOWNLOAD_URL % str(map_file_id))
	var result = await http_request.request_completed
	http_request.queue_free()
	var response_code = result[1]
	var body = result[3]
	if response_code != 200:
		push_warning("Match: map download failed with code %d" % response_code)
		return
	var file = FileAccess.open(pck_path, FileAccess.WRITE)
	if not file:
		push_warning("Match: could not write map pack to %s" % pck_path)
		return
	file.store_buffer(body)
	file.close()


func _on_player_registered(peer_id: int, team: String) -> void:
	if not multiplayer.is_server():
		return
	if _spawned_peers.has(peer_id):
		return
	_spawned_peers[peer_id] = true
	var spawn_transform := _pick_spawn_transform(peer_id)
	spawner.spawn({
		"peer_id": peer_id,
		"team": team,
		"position": spawn_transform.origin,
		"basis": spawn_transform.basis
	})


# The roster entry was dropped on disconnect but the craft node never was, so
# a player who logged out left a permanent husk standing in the level - and
# _spawned_peers kept their old id forever, so if ENet handed that same id back
# on rejoin, _on_player_registered above early-returned and the returning
# player got no craft at all.
func _on_player_unregistered(peer_id: int) -> void:
	_spawned_peers.erase(peer_id)
	if not multiplayer.is_server():
		return
	# Only the server frees it. MultiplayerSpawner replicates the despawn out
	# to every client by itself, so doing it on clients too would double-free.
	var craft = craft_container.get_node_or_null("Craft_%d" % peer_id)
	if is_instance_valid(craft):
		craft.queue_free()


func _pick_spawn_transform(peer_id: int) -> Transform3D:
	if _spawn_points.is_empty():
		return Transform3D.IDENTITY
	var index = peer_id % _spawn_points.size()
	return _spawn_points[index].global_transform


func spawn_projectile(weapon_settings_path: String, team: String, muzzle_transform: Transform3D) -> void:
	projectile_spawner.spawn({
		"weapon_settings_path": weapon_settings_path,
		"team": team,
		"position": muzzle_transform.origin,
		"basis": muzzle_transform.basis
	})


func _spawn_projectile(data: Dictionary) -> Node:
	# weapon_settings_path is a string, not the Resource itself - Godot's RPC/
	# spawn replication doesn't safely support arbitrary Object decoding by
	# default. Every peer has the same .tres file locally, so each side just
	# loads it independently instead of sending the Resource over the wire.
	var settings: WeaponSettings = load(data["weapon_settings_path"])
	var projectile := settings.projectile_prefab.instantiate()
	projectile.weapon_settings = settings
	projectile.team = data["team"]
	projectile.transform = Transform3D(data["basis"], data["position"])
	return projectile


# Called exactly once, the first time YOUR craft spawns. It never needs to
# run again on respawn - the craft node itself is never destroyed (see
# respawn_at() in health_node.gd), so the camera just stays exactly where
# it's always been, riding along with the barrel via normal scene-tree
# parenting for the whole match.
func _attach_local_camera(craft: Node) -> void:
	var barrel = craft.get_node("Turret/Barrel")
	if local_camera.get_parent():
		local_camera.get_parent().remove_child(local_camera)
	barrel.add_child(local_camera)
	local_camera.transform = Transform3D.IDENTITY


func _spawn_craft(data: Dictionary) -> Node:
	var craft := LIGHTNING_SCENE.instantiate()
	craft.name = "Craft_%d" % data["peer_id"]
	craft.get_node("movement_node").team = data["team"]
	var weapon_node = craft.get_node("weapon_node")
	weapon_node.team = data["team"]
	# lightning.tscn bakes in the full weapon catalog - filter it down to this
	# match's ruleset here so it's identical on every peer (this function runs
	# locally on all of them, same as team above). Empty means unrestricted -
	# see the comment on NetworkManager.allowed_weapon_paths for why. This is
	# also the anti-cheat boundary: request_fire()'s existing weapon_index
	# bounds check already validates against the SERVER's own filtered copy of
	# this same array, so a disallowed weapon can't be fired by index even if
	# a modified client never actually filters its own local list.
	if not NetworkManager.allowed_weapon_paths.is_empty():
		weapon_node.weapon_settings = weapon_node.weapon_settings.filter(
			func(w: WeaponSettings): return NetworkManager.allowed_weapon_paths.has(w.resource_path)
		)
	craft.set_multiplayer_authority(data["peer_id"])
	# set_multiplayer_authority() above is recursive by default, so it just
	# silently reassigned health_node's authority to the owning client too.
	# health_node's apply_damage/respawn_at RPCs are deliberately
	# @rpc("authority", ...) so ONLY the server can ever push HP or a
	# respawn transform (see the comments on those functions) - but Godot's
	# "authority" RPC mode is enforced against the target node's OWN
	# multiplayer authority, not its owner craft's. With health_node's
	# authority wrongly set to the client, the server's calls to those RPCs
	# were rejected on every remote peer (only running locally on the
	# server via call_local), while the client's own MultiplayerSynchronizer
	# kept broadcasting its stale, never-corrected transform right back out
	# to everyone - which is what made a destroyed client appear to "respawn"
	# exactly where it died instead of at the spawn point. Re-pin it to the
	# server explicitly so those RPCs actually replicate.
	craft.get_node("health_node").set_multiplayer_authority(1)
	craft.transform = Transform3D(data["basis"], data["position"])
	# A craft's spawn instruction travels over the fast game connection and
	# can arrive (and materialize this node) before this peer's own slow
	# HTTP map download has finished - gravity would then pull it through a
	# floor that doesn't exist locally yet. Freeze it until _load_map() is
	# actually done here.
	if not _map_ready:
		craft.freeze = true
		_pending_unfreeze.append(craft)
	# This runs locally on every peer - both when the server spawns a craft
	# for itself, and when a client receives the replicated spawn for its
	# own craft. Either way, once YOUR craft exists you can actually see
	# something, so that's the right moment to drop the loading screen -
	# not just "the map finished loading", which for a joining client can
	# happen well before their own craft has replicated in.
	if data["peer_id"] == multiplayer.get_unique_id():
		print("[JOIN] t=%dms own craft spawned, loading screen hidden" % NetworkManager._debug_join_elapsed_ms())
		loading_screen.hide()
		_attach_local_camera(craft)
	# The signal only actually fires on the server's own execution of
	# destroy_self() (it's guarded there), so connecting here unconditionally
	# on every peer is harmless - it simply never fires on client copies.
	craft.get_node("health_node").craft_defeated.connect(_on_craft_defeated)
	return craft


func _on_craft_defeated(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	if not NetworkManager.peer_teams.has(peer_id):
		return # player left during the respawn delay
	var craft = craft_container.get_node_or_null("Craft_%d" % peer_id)
	if not is_instance_valid(craft):
		return
	var spawn_transform := _pick_spawn_transform(peer_id)
	craft.get_node("health_node").respawn_at.rpc(spawn_transform.origin, spawn_transform.basis)

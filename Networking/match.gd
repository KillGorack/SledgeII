extends Node3D

const LIGHTNING_SCENE := preload("res://Crafts/lightning.tscn")
const MAP_SCENE_PATH := "res://secret_level.tscn"
const MAP_PCK_PATH := "user://secret_levels/level.pck"
const LOCAL_TEST_PACK := "res://map.pck"
const DOWNLOAD_URL := "https://www.killgorack.com/PX4/downloader.php?ap=tanarusmaps&fileid=%s&type=file&cn=fls"

@onready var craft_container: Node3D = $Crafts
@onready var spawner: MultiplayerSpawner = $CraftSpawner
@onready var projectile_spawner: MultiplayerSpawner = $ProjectileSpawner
@onready var loading_screen: CanvasLayer = $LoadingScreen

var _spawned_peers: Dictionary = {}
var _spawn_points: Array = []
var _map_ready: bool = false
var _pending_unfreeze: Array = []


func _ready() -> void:
	add_to_group("match")
	spawner.spawn_function = _spawn_craft
	projectile_spawner.spawn_function = _spawn_projectile
	await _load_map()
	_map_ready = true
	for craft in _pending_unfreeze:
		if is_instance_valid(craft):
			craft.freeze = false
	_pending_unfreeze.clear()
	NetworkManager.player_registered.connect(_on_player_registered)
	# Backfill: peers may already be registered (e.g. the host itself) by the
	# time this scene loads, since NetworkManager persists across the scene
	# change and its signal can fire before match.tscn finishes loading.
	for peer_id in NetworkManager.peer_teams.keys():
		_on_player_registered(peer_id, NetworkManager.peer_teams[peer_id])


func _load_map() -> void:
	if not ResourceLoader.exists(MAP_SCENE_PATH):
		if NetworkManager.current_map_file_id > 0:
			await _download_and_mount_map(NetworkManager.current_map_file_id)
		else:
			# No map selected (e.g. match.tscn opened directly for testing) -
			# fall back to whatever local test pack is sitting in the project.
			ProjectSettings.load_resource_pack(LOCAL_TEST_PACK)
	if not ResourceLoader.exists(MAP_SCENE_PATH):
		push_warning("Match: could not load map scene at %s" % MAP_SCENE_PATH)
		return
	var map_scene: PackedScene = load(MAP_SCENE_PATH)
	add_child(map_scene.instantiate())
	var overrides = get_tree().get_nodes_in_group("PlayerSpawnOverride")
	_spawn_points = overrides if overrides.size() > 0 else get_tree().get_nodes_in_group("PlayerSpawn")


func _download_and_mount_map(map_file_id: int) -> void:
	var dir_access = DirAccess.open("user://")
	dir_access.make_dir_recursive("user://secret_levels/")
	if FileAccess.file_exists(MAP_PCK_PATH):
		DirAccess.remove_absolute(MAP_PCK_PATH)
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
	var file = FileAccess.open(MAP_PCK_PATH, FileAccess.WRITE)
	if not file:
		push_warning("Match: could not write map pack to %s" % MAP_PCK_PATH)
		return
	file.store_buffer(body)
	file.close()
	ProjectSettings.load_resource_pack(MAP_PCK_PATH)


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


func _spawn_craft(data: Dictionary) -> Node:
	var craft := LIGHTNING_SCENE.instantiate()
	craft.name = "Craft_%d" % data["peer_id"]
	craft.get_node("movement_node").team = data["team"]
	craft.get_node("weapon_node").team = data["team"]
	craft.set_multiplayer_authority(data["peer_id"])
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
		loading_screen.hide()
	return craft

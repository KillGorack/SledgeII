extends Node3D

const LIGHTNING_SCENE := preload("res://Crafts/lightning.tscn")
const MAP_SCENE_PATH := "res://secret_level.tscn"
const MAP_PCK_PATH := "user://secret_levels/level.pck"
const LOCAL_TEST_PACK := "res://map.pck"
const DOWNLOAD_URL := "https://www.killgorack.com/PX4/downloader.php?ap=tanarusmaps&fileid=%s&type=file&cn=fls"

# DEBUG: drops a couple of stationary, uncontrolled crafts next to the spawn
# point so scale/positioning can be eyeballed against the map. Not networked,
# safe to flip off once scale is sorted.
@export var DEBUG_spawn_reference_crafts: bool = true

@onready var craft_container: Node3D = $Crafts
@onready var spawner: MultiplayerSpawner = $CraftSpawner

var _spawned_peers: Dictionary = {}
var _spawn_points: Array = []


func _ready() -> void:
	spawner.spawn_function = _spawn_craft
	await _load_map()
	if DEBUG_spawn_reference_crafts:
		_spawn_debug_reference_crafts()
	NetworkManager.player_registered.connect(_on_player_registered)
	# Backfill: peers may already be registered (e.g. the host itself) by the
	# time this scene loads, since NetworkManager persists across the scene
	# change and its signal can fire before match.tscn finishes loading.
	for peer_id in NetworkManager.peer_teams.keys():
		_on_player_registered(peer_id, NetworkManager.peer_teams[peer_id])


func _spawn_debug_reference_crafts() -> void:
	var origin := _pick_spawn_transform(0)
	var right := origin.basis.x
	for i in range(1, 3):
		var reference := LIGHTNING_SCENE.instantiate()
		reference.name = "DEBUG_Reference_%d" % i
		# Authority must be set BEFORE add_child(), since add_child() runs
		# _ready() immediately - by default these would inherit authority 1
		# (same as the host), making is_multiplayer_authority() true and
		# triggering the self-hide-own-body logic, which would put THEIR
		# meshes on the same shared "hide from own camera" layer as yours,
		# making them invisible to your camera too. Authority 0 matches no
		# real peer, so that logic never runs for these at all.
		reference.set_multiplayer_authority(0)
		add_child(reference)
		reference.transform = Transform3D(origin.basis, origin.origin + right * (i * 8.0))
		reference.freeze = true
		reference.get_node("movement_node").set_physics_process(false)


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


func _spawn_craft(data: Dictionary) -> Node:
	var craft := LIGHTNING_SCENE.instantiate()
	craft.name = "Craft_%d" % data["peer_id"]
	craft.get_node("movement_node").team = data["team"]
	craft.set_multiplayer_authority(data["peer_id"])
	craft.transform = Transform3D(data["basis"], data["position"])
	return craft

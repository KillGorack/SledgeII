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
# Maps mark recon station spots with bare Marker3D placeholders (grouped under
# a "recon_locations" folder node) rather than shipping the actual station
# scene in every map pck - see _spawn_recon_stations.
const RECON_STATION_SCENE := preload("res://Game_Objects/recon_station.tscn")
const RECON_LOCATIONS_NODE_NAME := "recon_locations"
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
# Server-only: which peers have confirmed THEIR OWN match.tscn actually
# exists yet (see _notify_ready below) - used purely to decide who to grant
# visibility to and when. Every craft's synchronizers default to
# public_visibility=false (see lightning.tscn) specifically so
# MultiplayerSpawner/Synchronizer never attempt to replicate anything to a
# peer before we know they're ready to receive it - Godot tries this
# unconditionally the instant a peer's raw ENet connection completes
# (long before their own scene loads), which is what caused the original
# "stuck at Loading map... forever" bug: a spawn/sync packet aimed at a path
# that doesn't exist yet is just silently dropped, permanently, no retry.
var _ready_peers: Dictionary = {}
# A team's base pad markers are tagged in the map source with these group
# names, same convention as recon_red/green/blue/gray on recon markers (see
# recon_station.gd) - no script needed in whatever separate project builds
# the map .pck, map authors just tag Marker3D nodes in the editor's Groups
# tab. Maps that don't have any of these tagged yet fall back to the
# older flat "PlayerSpawn" pool (see _load_map) rather than nobody spawning.
const BASE_PAD_GROUPS := {
	"team_red": "base_pad_red",
	"team_green": "base_pad_green",
	"team_blue": "base_pad_blue",
	"team_gray": "base_pad_gray",
}
# Base pads are small (~7x7) - a candidate spawn point within this distance
# of an existing craft is "occupied" for picking purposes; see
# _pick_spawn_transform.
const SPAWN_CLEAR_RADIUS := 4.0
# The craft's own origin sits at the turret's center, not its bottom - Y
# range on its main collider (Crafts/Scenes/lightning.tscn) runs -0.29 to
# +0.08, and FloorDetection's own collider bottoms out around -0.30, so
# spawning/respawning AT a marker's exact position buries about a third of
# the hull in the pad. Lifting here, once, centrally, means spawn markers
# can just sit naturally at ground level in the map editor - no per-marker
# manual offset for every map author to get right (or re-do if the craft's
# own dimensions ever change).
const SPAWN_HEIGHT_OFFSET := 0.3
# 9 of these hover in a 3x3 grid above each team's base (centered on the
# average position of that team's own base_pad markers), waiting to fly out
# and capture a recon on that team's behalf - see _spawn_base_guns and
# base_gun.gd's own flight logic.
const BASE_GUN_SCENE := preload("res://Game_Objects/base_gun.tscn")
const BASE_GUN_GRID_SPACING := 3.0
const BASE_GUN_HEIGHT_ABOVE_PAD := 4.0

@onready var base_guns_container: Node3D = $BaseGuns

# "Universe juice" (name's a placeholder) - a team-wide resource that gates
# how fast an overly motivated team can churn through captures, generated by
# whatever recons that team already holds. Server-only source of truth,
# broadcast out via NetworkManager (see _broadcast_team_juice) since a HUD
# needs to display it regardless of which craft it's attached to - this
# isn't per-craft state the way power/ammo are.
const JUICE_CAPACITY := 100.0
const JUICE_CAPTURE_COST := 50.0
# Deliberately per-recon and additive (2 recons = 2x the rate, not some
# diminishing-returns curve) - "the more cons you have the more juice you
# get" was explicit, and a flat per-recon rate is the simplest thing that's
# actually true to that.
const JUICE_PER_RECON_PER_SEC := 0.05
const JUICE_SYNC_INTERVAL := 0.5

var _team_juice: Dictionary = {}
var _juice_sync_elapsed := 0.0

var _spawn_points_by_team: Dictionary = {}
var _fallback_spawn_points: Array = []
var _base_guns_by_team: Dictionary = {}
# Server-only: recons currently mid-capture, so a second request for the
# same one (another player, or the same one mashing the button) doesn't
# start a redundant flight or double-book the gun already flying it.
var _capturing_recons: Dictionary = {}
# The local player's own craft, for the capture_recon input below - set once,
# when it spawns (see _spawn_craft's own-craft branch), same moment
# _attach_local_camera runs.
var _my_craft: Node3D = null
# This peer's own copy of env.tscn (see _apply_custom_environment) - kept so
# _notify_ready can immediately hand a freshly-ready peer the server's
# current time_of_day, rather than making them wait for env.gd's own
# periodic sync (see env.gd::SYNC_INTERVAL) and sit at the wrong lighting
# until then.
var _env: Node3D = null
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
	# Tell the server our own scene (and CraftSpawner) genuinely exists now -
	# see _ready_peers above and _notify_ready/_on_player_registered below.
	# The host doesn't need the round trip; it already knows its own state.
	if multiplayer.is_server():
		_ready_peers[1] = true
	else:
		_notify_ready.rpc_id(1)
	# Backfill: peers may already be registered (e.g. the host itself) by the
	# time this scene loads, since NetworkManager persists across the scene
	# change and its signal can fire before match.tscn finishes loading.
	for peer_id in NetworkManager.peer_teams.keys():
		_on_player_registered(peer_id, NetworkManager.peer_teams[peer_id])
	if multiplayer.is_server():
		for team in NetworkManager.TEAM_NAMES:
			_team_juice[team] = JUICE_CAPACITY
			NetworkManager._update_team_juice.rpc(team, JUICE_CAPACITY)


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	_generate_juice(delta)
	_juice_sync_elapsed += delta
	if _juice_sync_elapsed >= JUICE_SYNC_INTERVAL:
		_juice_sync_elapsed = 0.0
		for team in _team_juice:
			NetworkManager._update_team_juice.rpc(team, _team_juice[team])


# Additive per-recon, per team - "the more cons you have the more juice you
# get". O(teams * recons) every frame, which is fine at this scale (a
# handful of teams, rarely more than a couple dozen recons on a map); not
# worth caching until that's actually not true.
func _generate_juice(delta: float) -> void:
	for team in NetworkManager.TEAM_NAMES:
		var color = ReconStation.color_for_team(team)
		var count := 0
		for recon in get_tree().get_nodes_in_group("Recon"):
			if recon.captured_color == color:
				count += 1
		if count == 0:
			continue
		var current: float = _team_juice.get(team, 0.0)
		_team_juice[team] = min(JUICE_CAPACITY, current + JUICE_PER_RECON_PER_SEC * count * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("exit_main"):
		_exit_to_main_menu()
	elif event.is_action_pressed("capture_recon"):
		_try_start_capture()


func _exit_to_main_menu() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://UI/index.tscn")


# Client-side only - just finds a plausible target and asks the server,
# which re-validates everything for real (see _request_capture). Cheap early
# exits here just avoid a doomed RPC round trip for an obviously bad attempt
# (not standing in a capturable pad, or it's already your own color).
func _try_start_capture() -> void:
	if _my_craft == null or not NetworkManager.peer_teams.has(multiplayer.get_unique_id()):
		return
	var my_team: String = NetworkManager.peer_teams[multiplayer.get_unique_id()]
	for recon in get_tree().get_nodes_in_group("Recon"):
		if not recon.changeable or not recon.is_body_inside(_my_craft):
			continue
		if recon.captured_color == ReconStation.color_for_team(my_team):
			continue
		# The host can't rpc_id(1, ...) to itself - Godot rejects a
		# self-targeted "any_peer" RPC with no call_local outright ("RPC on
		# yourself is not allowed by selected mode"), so the host's own
		# attempts go straight to the same validation logic as a plain local
		# call instead of through the RPC at all - see _start_capture_request.
		if multiplayer.is_server():
			_start_capture_request(multiplayer.get_unique_id(), get_path_to(recon))
		else:
			_request_capture.rpc_id(1, get_path_to(recon))
		return


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
	_spawn_recon_stations(map_instance)
	print("[JOIN] t=%dms _spawn_recon_stations() done" % NetworkManager._debug_join_elapsed_ms())
	for team in BASE_PAD_GROUPS:
		_spawn_points_by_team[team] = get_tree().get_nodes_in_group(BASE_PAD_GROUPS[team])
		_spawn_base_guns(team, _spawn_points_by_team[team])
	var overrides = get_tree().get_nodes_in_group("PlayerSpawnOverride")
	_fallback_spawn_points = overrides if overrides.size() > 0 else get_tree().get_nodes_in_group("PlayerSpawn")


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
	_env = CUSTOM_ENVIRONMENT_SCENE.instantiate()
	add_child(_env)


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


# Replaces each Marker3D placeholder under the map's "recon_locations" folder
# with a real recon station, parented to the marker so it inherits the
# marker's transform with no manual math. Maps aren't required to have the
# folder (e.g. older test packs) - just skip silently if it's absent.
func _spawn_recon_stations(map_instance: Node) -> void:
	var recon_locations := _find_named_node(map_instance, RECON_LOCATIONS_NODE_NAME)
	if not recon_locations:
		return
	for marker in recon_locations.get_children():
		if marker is Marker3D:
			var station := RECON_STATION_SCENE.instantiate()
			# power_node.gd charges craft near any node in this group - see
			# Crafts/_scripts/power_node.gd.
			station.add_to_group("Recon")
			marker.add_child(station)


func _find_named_node(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found := _find_named_node(child, target_name)
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
	var spawn_transform := _pick_spawn_transform(team)
	var craft: Node = spawner.spawn({
		"peer_id": peer_id,
		"team": team,
		"position": spawn_transform.origin,
		"basis": spawn_transform.basis
	})
	# Starts invisible to everyone (see lightning.tscn's synchronizers, all
	# public_visibility=false) - grant it to every peer already fully caught
	# up. The owning peer usually isn't one of these yet (their own scene is
	# rarely ready the instant they're assigned a team) - they get this same
	# craft, along with everything else, from _notify_ready once they are.
	for ready_peer_id in _ready_peers.keys():
		_grant_visibility(craft, ready_peer_id)


# Called by a peer's own match.gd once ITS _load_map() has actually finished -
# see _ready() above. Granting visibility only now, rather than the moment
# they're assigned a team, is what keeps MultiplayerSpawner/Synchronizer from
# ever attempting to replicate anything toward a peer before their own scene
# can receive it - see _ready_peers' comment for the bug that caused.
@rpc("any_peer", "reliable")
func _notify_ready() -> void:
	if not multiplayer.is_server():
		return
	var requester_id := multiplayer.get_remote_sender_id()
	if requester_id == 0:
		return
	_ready_peers[requester_id] = true
	for other_peer_id in _spawned_peers.keys():
		var craft = craft_container.get_node_or_null("Craft_%d" % other_peer_id)
		if is_instance_valid(craft):
			_grant_visibility(craft, requester_id)
	if is_instance_valid(_env):
		_env.sync_time_to.rpc_id(requester_id, _env.time_of_day)


# MultiplayerSpawner defers to a spawned node's own MultiplayerSynchronizer to
# decide whether a given peer even learns it was spawned at all - granting
# visibility here is what actually makes the spawn, and every future
# position/health/power update, reach viewer_peer_id, once (and only once)
# we know it's safe to.
#
# set_visibility_for() only has any effect when called BY the peer that's
# actually authoritative for the synchronizer in question - calling it from
# the wrong peer doesn't error, it just silently does nothing. health_node's
# and power_node's synchronizers are server-authoritative (see _spawn_craft),
# so the server calling it directly here is correct for those. The craft's
# OWN root synchronizer (position/rotation) is authored by the OWNING peer
# instead - the server granting that one itself would have no effect, which
# is exactly why health/power synced but position never did. That one has to
# be granted by the owning peer itself instead (see _grant_own_craft_visibility).
func _grant_visibility(craft: Node, viewer_peer_id: int) -> void:
	for sync_path in ["health_node/MultiplayerSynchronizer", "power_node/MultiplayerSynchronizer"]:
		var sync = craft.get_node_or_null(sync_path)
		if sync:
			sync.set_visibility_for(viewer_peer_id, true)
	var owner_peer_id: int = craft.get_multiplayer_authority()
	if owner_peer_id == multiplayer.get_unique_id():
		# The owning peer IS the server (this is the host's own craft) - no
		# RPC round trip needed, just do it directly.
		var root_sync = craft.get_node_or_null("MultiplayerSynchronizer")
		if root_sync:
			root_sync.set_visibility_for(viewer_peer_id, true)
	else:
		_grant_own_craft_visibility.rpc_id(owner_peer_id, viewer_peer_id)


# Runs on whichever peer owns a given craft (see _grant_visibility above) -
# looks up their OWN craft by their OWN id, since that's the only one this
# peer is ever authoritative for, and grants viewer_peer_id visibility into
# its root transform sync themselves, since only they actually can.
@rpc("authority", "reliable")
func _grant_own_craft_visibility(viewer_peer_id: int) -> void:
	var my_craft = craft_container.get_node_or_null("Craft_%d" % multiplayer.get_unique_id())
	if my_craft:
		var root_sync = my_craft.get_node_or_null("MultiplayerSynchronizer")
		if root_sync:
			root_sync.set_visibility_for(viewer_peer_id, true)


# The roster entry was dropped on disconnect but the craft node never was, so
# a player who logged out left a permanent husk standing in the level - and
# _spawned_peers kept their old id forever, so if ENet handed that same id back
# on rejoin, _on_player_registered above early-returned and the returning
# player got no craft at all.
func _on_player_unregistered(peer_id: int) -> void:
	_spawned_peers.erase(peer_id)
	_ready_peers.erase(peer_id)
	if not multiplayer.is_server():
		return
	# Only the server frees it. Every craft now always goes through the real
	# spawner (see _on_player_registered/_notify_ready) - MultiplayerSpawner
	# replicates this despawn out, by itself, to every peer who currently has
	# visibility into it. Doing it on clients too would double-free.
	var craft = craft_container.get_node_or_null("Craft_%d" % peer_id)
	if is_instance_valid(craft):
		craft.queue_free()


# Prefers whichever of this team's own base pad markers currently has the
# most room around it, so spawning/respawning doesn't drop a player on top
# of a teammate already there (pads are small, ~7x7) - only falls back to
# the roomiest-available pick (letting spawns overlap) if every pad on the
# team is currently crowded, since spawning imperfectly still beats not
# spawning at all.
func _pick_spawn_transform(team: String) -> Transform3D:
	var candidates: Array = _spawn_points_by_team.get(team, [])
	if candidates.is_empty():
		candidates = _fallback_spawn_points
	if candidates.is_empty():
		return Transform3D.IDENTITY
	var roomiest = candidates[0]
	var roomiest_distance := -1.0
	for candidate in candidates:
		var distance := _distance_to_nearest_craft(candidate.global_position)
		if distance >= SPAWN_CLEAR_RADIUS:
			return _lift_spawn_transform(candidate.global_transform)
		if distance > roomiest_distance:
			roomiest = candidate
			roomiest_distance = distance
	return _lift_spawn_transform(roomiest.global_transform)


func _lift_spawn_transform(spawn_transform: Transform3D) -> Transform3D:
	spawn_transform.origin.y += SPAWN_HEIGHT_OFFSET
	return spawn_transform


func _distance_to_nearest_craft(spawn_position: Vector3) -> float:
	var nearest := INF
	for craft in craft_container.get_children():
		if craft is Node3D:
			nearest = min(nearest, spawn_position.distance_to(craft.global_position))
	return nearest


# 9 guns in a 3x3 grid, centered on the average position of this team's own
# base_pad markers (not hand-placed per map - one less thing for a map author
# to get right, and it automatically follows wherever those markers are).
# Runs identically on every peer - these are purely local visual actors until
# a capture actually starts, driven at that point by a broadcast RPC (see
# _run_capture), so there's nothing server-specific about creating them.
func _spawn_base_guns(team: String, pads: Array) -> void:
	if pads.is_empty():
		return
	var center := Vector3.ZERO
	for pad in pads:
		center += pad.global_position
	center /= pads.size()
	center.y += BASE_GUN_HEIGHT_ABOVE_PAD
	var guns: Array = []
	for row in range(3):
		for col in range(3):
			var offset := Vector3((col - 1) * BASE_GUN_GRID_SPACING, 0, (row - 1) * BASE_GUN_GRID_SPACING)
			var gun := BASE_GUN_SCENE.instantiate()
			# Explicit, deterministic name (team + grid index) rather than
			# letting every instance default to "BaseGun" and relying on
			# Godot's auto-dedup suffixing (BaseGun, BaseGun2, BaseGun3, ...)
			# to land in the same order on every peer. _run_capture resolves
			# a gun by a NodePath the SERVER computed, on each peer's own
			# separately-loaded copy of this same map - if the auto-naming
			# order isn't guaranteed bit-identical across peers, that path
			# can silently resolve to null (or a different gun entirely) for
			# anyone who didn't compute it themselves, which reads exactly
			# like "works when I start my own capture, does nothing when
			# capturing from elsewhere" - a name that's a pure function of
			# (team, index) can never diverge like that.
			gun.name = "BaseGun_%s_%d" % [team, row * 3 + col]
			# Position set BEFORE add_child, deliberately - base_gun.gd's
			# _ready() (which fires the instant it enters the tree) reads its
			# starting position as "rest", so setting it after would have
			# every gun think its rest position is wherever add_child left it
			# (the origin), not its actual grid slot.
			gun.position = center + offset
			base_guns_container.add_child(gun)
			guns.append(gun)
	_base_guns_by_team[team] = guns


# Thin RPC wrapper - only ever reached for a REMOTE client's request (the
# host's own attempts go straight to _start_capture_request instead, see
# _try_start_capture, since a self-targeted rpc_id is illegal here). All this
# does is turn "who sent this" into an explicit id before handing off to the
# actual validation, which doesn't care how it was invoked.
@rpc("any_peer", "reliable")
func _request_capture(recon_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var requester_id := multiplayer.get_remote_sender_id()
	if requester_id == 0:
		return
	_start_capture_request(requester_id, recon_path)


# Server-side validation for a capture attempt - re-checks everything
# _try_start_capture already screened client-side (never trust that alone),
# plus the two things only the server can know: whether this recon already
# has a capture in flight, and which of the team's 9 guns (if any) is free.
func _start_capture_request(requester_id: int, recon_path: NodePath) -> void:
	if not NetworkManager.peer_teams.has(requester_id):
		return
	var team: String = NetworkManager.peer_teams[requester_id]
	var recon = get_node_or_null(recon_path)
	if not (recon is ReconStation) or not recon.changeable:
		return
	if recon.captured_color == ReconStation.color_for_team(team):
		return
	if _capturing_recons.has(recon):
		return
	if _team_juice.get(team, 0.0) < JUICE_CAPTURE_COST:
		return
	var gun := _find_available_gun(team)
	if gun == null:
		return
	# Spent up front, when the gun actually launches - not refunded if the
	# capture is somehow interrupted later, same "spend on attempt, not on
	# success" rule power/ammo already follow.
	_team_juice[team] -= JUICE_CAPTURE_COST
	NetworkManager._update_team_juice.rpc(team, _team_juice[team])
	_capturing_recons[recon] = true
	_run_capture.rpc(get_path_to(gun), recon_path, team)


func _find_available_gun(team: String) -> Node:
	for gun in _base_guns_by_team.get(team, []):
		if not gun.is_busy:
			return gun
	return null


# Broadcast (call_local so the host's own gun/recon play it too) - every peer
# runs the exact same flight off the exact same gun/recon paths, so the
# animation and the eventual color change land identically everywhere with
# no separate sync needed for either. See base_gun.gd::begin_capture for the
# actual flight, and recon_station.gd::capture for what runs at the hold's
# end - only the server actually clears _capturing_recons, since that dict
# doesn't exist as meaningful state anywhere else.
@rpc("authority", "call_local", "reliable")
func _run_capture(gun_path: NodePath, recon_path: NodePath, team: String) -> void:
	var gun = get_node_or_null(gun_path)
	var recon = get_node_or_null(recon_path)
	if gun == null or recon == null:
		push_warning("match.gd: _run_capture couldn't resolve gun=%s (path %s) or recon=%s (path %s) on this peer" % [gun, gun_path, recon, recon_path])
		return
	gun.begin_capture(recon, func():
		recon.capture(team)
		if multiplayer.is_server():
			_capturing_recons.erase(recon)
	)


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
	# power_node needs the same fix, for the same reason: request_fire() below
	# has to trust its power total enough to gate whether a shot is even allowed
	# to fire, so the server has to be the one computing/holding it, not the
	# owning client - see power_node.gd's own _process gating.
	craft.get_node("power_node").set_multiplayer_authority(1)
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
		_my_craft = craft
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
	var spawn_transform := _pick_spawn_transform(NetworkManager.peer_teams[peer_id])
	craft.get_node("health_node").respawn_at.rpc(spawn_transform.origin, spawn_transform.basis)

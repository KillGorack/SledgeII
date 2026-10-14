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
# Maps mark recon station spots with anchor placeholders (bare Marker3D or a
# lit recon_placeholder.tscn instance, grouped under a "recon_locations"
# folder node) rather than shipping the actual station scene in every map
# pck - see _spawn_recon_stations.
const RECON_STATION_SCENE := preload("res://Game_Objects/recon_station.tscn")
const RECON_LOCATIONS_NODE_NAME := "recon_locations"
# Every weapon's explosion_prefab, deduplicated - see _prewarm_effect_shaders.
# sparks.tscn covers the bulk of weapons (Detno, MKIV_CEB, plasma, Repulsor,
# plasma_base); shockwave.tscn is basic_cannon's own. This is a separate,
# hand-kept list rather than scanned from WEAPON_CATALOG_DIRS (index.gd) -
# that list is about which weapons a host can pick, this is about which
# distinct shaders actually need warming, and a prefab five weapons share
# only needs warming once regardless of how many weapons use it.
const PREWARM_EFFECT_SCENES: Array[PackedScene] = [
	preload("res://Weapons/Scenes/explosions/sparks.tscn"),
	preload("res://Weapons/Scenes/explosions/shockwave.tscn"),
]
const RESPAWN_DELAY := 4.0
# Must match movement.gd's SELF_RENDER_LAYER - whichever craft is currently
# locally-owned puts its own body meshes on this layer (see
# movement.gd::_hide_own_body), and the one persistent camera below
# permanently excludes it, regardless of which craft currently owns the
# camera across spawns/respawns.
const SELF_RENDER_LAYER := 20

@onready var craft_container: Node3D = $Crafts
@onready var spawner: MultiplayerSpawner = $CraftSpawner
@onready var projectiles_container: Node3D = $Projectiles
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
# Keep spawned craft centers at least this far from each pad edge. The
# resulting grid gives a 7x7 pad nine separated spawn spots.
const SPAWN_SLOT_EDGE_MARGIN := 1.0
const SPAWN_SLOT_SPACING := 2.25
const DEFAULT_BASE_PAD_SIZE := Vector2(7.0, 7.0)
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

# Per-team hull/turret material for lightning.tscn's Hull and Turret meshes
# (see _spawn_craft) - deliberately separate resources rather than one shared
# material tinted per team at spawn (contrast base_gun.gd/colorable_mesh.gd's
# duplicate-then-tint pattern elsewhere), since these are expected to grow
# into genuinely different per-team designs later, not just different colors
# of the same texture.
const TEAM_CRAFT_MATERIALS := {
	"team_red": preload("res://Materials/PBR/digi_red.tres"),
	"team_green": preload("res://Materials/PBR/digi_green.tres"),
	"team_blue": preload("res://Materials/PBR/digi_blue.tres"),
	"team_gray": preload("res://Materials/PBR/digi_gray.tres"),
}

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
# Last juice values actually broadcast, in TEAM_NAMES order - lets the
# periodic sync skip sending when nothing moved (see _broadcast_juice).
var _last_sent_juice := PackedFloat32Array()

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
	add_to_group("match")
	local_camera.current = true
	local_camera.cull_mask = ((1 << 20) - 1) & ~(1 << (SELF_RENDER_LAYER - 1))
	spawner.spawn_function = _spawn_craft
	await _load_map()
	_map_ready = true
	for craft in _pending_unfreeze:
		# Remote copies stay frozen kinematic for good - see movement.gd::_ready.
		if is_instance_valid(craft) and craft.is_multiplayer_authority():
			craft.freeze = false
	_pending_unfreeze.clear()
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_unregistered.connect(_on_player_unregistered)
	# Godot only ever fires this on clients (never on the host about its own
	# connection), so no is_host check needed - this can't fire for the one
	# player it wouldn't make sense for.
	multiplayer.server_disconnected.connect(_on_server_disconnected)
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
		_broadcast_juice(true)


func _process(delta: float) -> void:
	# has_multiplayer_peer() first - see power_node.gd's _process() for why.
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	_generate_juice(delta)
	_juice_sync_elapsed += delta
	if _juice_sync_elapsed >= JUICE_SYNC_INTERVAL:
		_juice_sync_elapsed = 0.0
		_broadcast_juice()


# One packed message for all four teams (instead of one RPC per team), and
# only when a value actually changed - juice sits at capacity for long
# stretches, and this used to resend all four reliably every half second
# regardless. force skips the change check (match start, a capture spend).
func _broadcast_juice(force: bool = false) -> void:
	var values := _juice_values()
	if not force and values == _last_sent_juice:
		return
	_last_sent_juice = values
	NetworkManager._update_all_team_juice.rpc(values)


func _juice_values() -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for team in NetworkManager.TEAM_NAMES:
		values.append(_team_juice.get(team, 0.0))
	return values


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


# Client -> server -> broadcast, same shape as _request_capture/_assign_team.
# any_peer + call_local: a client's call routes to the server as normal; the
# host calling this on itself (rpc_id(1, ...) targeting its own id) only
# actually runs anything locally because of call_local, and is_server() is
# true there too, so both cases fall through to the same broadcast below -
# one path, not two.  Trusting the client-supplied sender name here since
# chat is display-only, not worth a server-side peer_id->username registry
# for - the same reasoning as this file no longer validating team requests
# on this being cosmetic (see e.g. base_gun.gd for what IS trusted).
@rpc("any_peer", "call_local", "reliable")
func _send_chat_message(sender: String, text: String) -> void:
	if not multiplayer.is_server():
		return
	_broadcast_chat_message.rpc(sender, text)


@rpc("authority", "call_local", "reliable")
func _broadcast_chat_message(sender: String, text: String) -> void:
	# Each peer only has its OWN craft's Chat visible (see hud_controller.gd
	# hiding the whole HUD for every non-owning copy) - find and deliver to
	# just that one rather than every craft's (mostly invisible) chat log.
	var my_craft := craft_container.get_node_or_null("Craft_%d" % multiplayer.get_unique_id())
	if not my_craft:
		return
	var chat := my_craft.get_node_or_null("Hud_InGame/Chat")
	if chat:
		chat.receive_message(sender, text)


func _exit_to_main_menu() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://UI/index.tscn")


# Host rage-quit/crash - built plainly with code instead of a scene, this is
# a one-shot message with nothing else going on. Held for a few seconds
# (instead of exiting immediately, same reasoning as index.gd's host-start
# feedback hold) so it's actually readable before the scene changes out from
# under it.
func _on_server_disconnected() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var background := ColorRect.new()
	background.color = Color(0, 0, 0, 0.85)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(background)
	var label := Label.new()
	label.text = "Host has left the game..."
	label.add_theme_font_size_override("font_size", 32)
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	background.add_child(label)
	await get_tree().create_timer(3.0).timeout
	_exit_to_main_menu()


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
			ProjectSettings.load_resource_pack(pck_path)
			NetworkManager.mounted_map_file_id = target_file_id
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
	# caching above - worth optimizing (skip CACHE_MODE_REPLACE entirely when
	# mounted_map_file_id didn't actually change) if this step ever turns out
	# to be the slow one.
	var map_scene: PackedScene = ResourceLoader.load(MAP_SCENE_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	var map_instance := map_scene.instantiate()
	add_child(map_instance)
	await _prewarm_effect_shaders()
	_apply_custom_environment(map_instance)
	_spawn_recon_stations(map_instance)
	for team in BASE_PAD_GROUPS:
		_spawn_points_by_team[team] = get_tree().get_nodes_in_group(BASE_PAD_GROUPS[team])
		_spawn_base_guns(team, _spawn_points_by_team[team])
	var overrides = get_tree().get_nodes_in_group("PlayerSpawnOverride")
	_fallback_spawn_points = overrides if overrides.size() > 0 else get_tree().get_nodes_in_group("PlayerSpawn")


# A fresh machine has no shader cache, so the GPU driver has to actually
# compile a material's shader the first time it's rendered - that compile is
# what caused the visible hitch on someone's first explosion. Godot 4.4+
# precompiles a pipeline as soon as its scene is instantiated anywhere in the
# tree, even off-screen, so spawning one hidden copy of each effect here -
# while LoadingScreen is still covering the screen (see _spawn_craft, the
# only place it gets hidden) - pays that one-time cost during a moment a
# hitch is already invisible, instead of during a player's first real hit.
# Placed far outside the map rather than just visible=false - the pipeline
# still needs to actually be eligible for rendering, not skipped entirely.
# Runs once per peer per match (every peer's own GPU needs its own warm-up,
# this isn't something the host can do on anyone else's behalf).
func _prewarm_effect_shaders() -> void:
	var far_away := Vector3(0.0, -100000.0, 0.0)
	var instances: Array[Node] = []
	for scene in PREWARM_EFFECT_SCENES:
		var instance := scene.instantiate()
		add_child(instance)
		if instance is Node3D:
			instance.global_position = far_away
		instances.append(instance)
	for i in 3:
		await get_tree().process_frame
	for instance in instances:
		instance.queue_free()


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


# Replaces each anchor under the map's "recon_locations" folder with a real
# recon station, parented to the anchor so it inherits its transform with no
# manual math. An anchor is either a bare Marker3D (older test packs) or a
# recon_placeholder.tscn instance (its own transform matches where the
# Marker3D it replaced used to sit - see MaulGrounds' _replace_recon_markers.gd)
# - either way, everything directly under recon_locations is a spot to fill,
# so no type check needed. Maps aren't required to have the folder at all -
# just skip silently if it's absent.
func _spawn_recon_stations(map_instance: Node) -> void:
	var recon_locations := _find_named_node(map_instance, RECON_LOCATIONS_NODE_NAME)
	if not recon_locations:
		return
	for anchor in recon_locations.get_children():
		var station := RECON_STATION_SCENE.instantiate()
		# power_node.gd charges craft near any node in this group - see
		# Crafts/_scripts/power_node.gd.
		station.add_to_group("Recon")
		anchor.add_child(station)


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
	# Juice is only broadcast on change now (see _broadcast_juice), so a late
	# joiner could otherwise sit on an empty bar until the next capture.
	NetworkManager._update_all_team_juice.rpc_id(requester_id, _juice_values())
	# Catch up on every recon someone else already captured before this peer
	# connected - see _sync_recon_capture. Fixed map-authored stations are
	# skipped: recon.changeable is false for those, and they already came out
	# of this peer's own _spawn_recon_stations with the right color for free,
	# no network round trip needed.
	for recon in get_tree().get_nodes_in_group("Recon"):
		if recon.changeable and recon.captured_color != ReconStation.StationColor.NONE:
			var team := ReconStation.team_for_color(recon.captured_color)
			_sync_recon_capture.rpc_id(requester_id, get_path_to(recon), team)


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
	var owner_peer_id: int = craft.get_multiplayer_authority()
	# HP has to stay visible to EVERY peer, even though only the owner's HUD
	# reads it: Godot only delivers RPCs on a node to peers its synchronizer
	# is visible to, and health_node carries the death/respawn/knockback RPCs
	# - owner-only visibility silently swallowed other tanks' explosions and
	# respawns. It's on-change and rate-limited (lightning.tscn), so this is
	# cheap. power_node has no RPCs and only the owner reads it (HUD, local
	# fire prediction), so that one stays owner-only.
	var health_sync = craft.get_node_or_null("health_node/MultiplayerSynchronizer")
	if health_sync:
		health_sync.set_visibility_for(viewer_peer_id, true)
	if viewer_peer_id == owner_peer_id:
		var power_sync = craft.get_node_or_null("power_node/MultiplayerSynchronizer")
		if power_sync:
			power_sync.set_visibility_for(viewer_peer_id, true)
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


# Spreads craft across the available space on this team's pads, choosing the
# spawn spot whose nearest craft is farthest away. Legacy PlayerSpawn points
# remain single-position candidates.
func _pick_spawn_transform(team: String) -> Transform3D:
	var candidates: Array = _spawn_points_by_team.get(team, [])
	var is_base_pad := not candidates.is_empty()
	if candidates.is_empty():
		candidates = _fallback_spawn_points
	if candidates.is_empty():
		return Transform3D.IDENTITY
	var spawn_transforms: Array[Transform3D] = []
	for candidate in candidates:
		if is_base_pad:
			spawn_transforms.append_array(_spawn_transforms_for_pad(candidate))
		else:
			spawn_transforms.append(_lift_spawn_transform(candidate.global_transform))
	var roomiest := spawn_transforms[0]
	var roomiest_distance := -1.0
	for spawn_transform in spawn_transforms:
		var distance := _distance_to_nearest_craft(spawn_transform.origin)
		if distance > roomiest_distance:
			roomiest = spawn_transform
			roomiest_distance = distance
	_recent_spawns.append([roomiest.origin, Time.get_ticks_msec()])
	return roomiest


func _spawn_transforms_for_pad(pad: Node3D) -> Array[Transform3D]:
	var pad_size := DEFAULT_BASE_PAD_SIZE
	var local_center := Vector3.ZERO
	if pad is MeshInstance3D and pad.mesh:
		var bounds: AABB = pad.mesh.get_aabb()
		if bounds.size.x > 0.0 and bounds.size.z > 0.0:
			pad_size = Vector2(bounds.size.x, bounds.size.z)
			local_center = Vector3(bounds.get_center().x, 0.0, bounds.get_center().z)

	var x_offsets := _spawn_axis_offsets(pad_size.x)
	var z_offsets := _spawn_axis_offsets(pad_size.y)
	var pad_basis := pad.global_basis.orthonormalized()
	var spawn_transforms: Array[Transform3D] = []
	for x_offset in x_offsets:
		for z_offset in z_offsets:
			var local_position := local_center + Vector3(x_offset, 0.0, z_offset)
			var pad_position := pad.global_transform * local_position
			spawn_transforms.append(_lift_spawn_transform(Transform3D(pad_basis, pad_position)))
	return spawn_transforms


func _spawn_axis_offsets(axis_size: float) -> Array[float]:
	var available_extent := maxf(0.0, axis_size * 0.5 - SPAWN_SLOT_EDGE_MARGIN)
	if available_extent == 0.0:
		return [0.0]
	var offset := minf(SPAWN_SLOT_SPACING, available_extent)
	return [-offset, 0.0, offset]


func _lift_spawn_transform(spawn_transform: Transform3D) -> Transform3D:
	spawn_transform.origin.y += SPAWN_HEIGHT_OFFSET
	return spawn_transform


# Spots handed out in the last SPAWN_RESERVE_MSEC count as occupied too. A
# dead craft still sits at its death position until respawn_at() moves it,
# so two players respawning in the same instant both used to see the same
# "empty" slot and land inside each other - and since every peer only ever
# sees other craft as immovable kinematic bodies, the overlap launches the
# simulated one out hard enough to kill it again.
const SPAWN_RESERVE_MSEC := 3000
var _recent_spawns: Array = [] # [position, ticks_msec]


func _distance_to_nearest_craft(spawn_position: Vector3) -> float:
	var nearest := INF
	for craft in craft_container.get_children():
		if craft is Node3D:
			nearest = min(nearest, spawn_position.distance_to(craft.global_position))
	var now := Time.get_ticks_msec()
	_recent_spawns = _recent_spawns.filter(func(entry): return now - entry[1] < SPAWN_RESERVE_MSEC)
	for entry in _recent_spawns:
		nearest = min(nearest, spawn_position.distance_to(entry[0]))
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
			gun.team = team
			gun.set_team_color(ReconStation.render_color_for_team(team))
			# radar_controller.gd finds these the same generic group-based way
			# it finds crafts/recon stations.
			gun.add_to_group("BaseGun")
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
	_broadcast_juice(true)
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


# _run_capture's "no separate sync needed" only holds for peers who were
# actually connected to receive that broadcast. A peer who joins afterward
# never ran it, so their own recon_station instance sits at StationColor.NONE
# forever regardless of what the rest of the match already captured - this is
# the catch-up path for exactly that case, called once per already-captured
# station from _notify_ready below. Runs recon.capture() directly rather than
# gun.begin_capture()'s flight - a late joiner should just see the pad already
# owned, not watch a capture animation replay for something that finished
# before they connected.
@rpc("authority", "reliable")
func _sync_recon_capture(recon_path: NodePath, team: String) -> void:
	var recon = get_node_or_null(recon_path)
	if recon is ReconStation:
		recon.capture(team)


# --- Projectiles -----------------------------------------------------------
# No projectile is ever streamed per frame (they used to each carry a
# MultiplayerSynchronizer sending position+rotation every rendered frame to
# every peer - by far the biggest bandwidth cost in the game). Instead:
#   spawn  - one reliable event per volley; every peer creates its own copy
#            and flies it locally (collision_handler.gd::_cosmetic_step).
#   correct- only for what clients can't predict: guided course (unreliable
#            stream) and ricochets/pierces/bounces (reliable, one-off).
#   end    - one reliable event; explosion/bullet hole ride _play_impact_fx.
# The server's own copy stays the only one that resolves hits.
#
# Latency compensation: the server advances its copy by the shooter's
# one-way latency (the shot left their barrel that long ago), and every
# other peer by that plus its own one-way latency. The shooter themselves
# never waits at all - see predict_shot.
const PROJECTILE_MAX_FAST_FORWARD := 0.15
const _VOLLEY_START_ANGLES := [0, 0, -30, 45, 18, 0]

# Server-only id counter. Every peer's copy of one projectile shares its id.
var _next_projectile_id := 1
# net_id -> projectile, on every peer.
var _projectiles: Dictionary = {}
# Shooter-only: shot_seq -> Array of locally predicted projectiles, waiting
# for the server to confirm (adopt) or reject them.
var _predicted_shots: Dictionary = {}


# Server-only. shooter_peer 0 = not a player (base guns), which also means
# no launch sound (same as before - only crafts ever played one).
func spawn_projectile(weapon_settings_path: String, team: String, muzzle_transform: Transform3D, use_team_color: bool = false, shooter_peer: int = 0, shot_seq: int = -1, fast_forward: float = 0.0) -> void:
	if not multiplayer.is_server():
		return
	var settings: WeaponSettings = load(weapon_settings_path)
	if settings == null or settings.projectile_prefab == null:
		return
	var first_id := _next_projectile_id
	_next_projectile_id += maxi(settings.projectile_count, 1)
	_create_volley(first_id, weapon_settings_path, team, muzzle_transform, use_team_color, fast_forward, shooter_peer != 0)
	var team_index := NetworkManager.TEAM_NAMES.find(team)
	# Only to peers whose match scene actually exists - see _ready_peers.
	for peer_id in _ready_peers:
		if peer_id != 1:
			_spawn_projectile_event.rpc_id(peer_id, first_id, weapon_settings_path, team_index, muzzle_transform, use_team_color, fast_forward, shooter_peer, shot_seq)


@rpc("authority", "call_remote", "reliable", 2)
func _spawn_projectile_event(first_id: int, weapon_settings_path: String, team_index: int, muzzle_transform: Transform3D, use_team_color: bool, fast_forward: float, shooter_peer: int, shot_seq: int) -> void:
	if shooter_peer == multiplayer.get_unique_id() and _predicted_shots.has(shot_seq):
		# Our own shot - already flying since the moment we fired. Adopt the
		# server's ids instead of spawning a duplicate.
		var predicted: Array = _predicted_shots[shot_seq]
		_predicted_shots.erase(shot_seq)
		for i in predicted.size():
			if is_instance_valid(predicted[i]):
				predicted[i].net_id = first_id + i
				_projectiles[first_id + i] = predicted[i]
		return
	var team: String = NetworkManager.TEAM_NAMES[team_index] if team_index >= 0 and team_index < NetworkManager.TEAM_NAMES.size() else ""
	_create_volley(first_id, weapon_settings_path, team, muzzle_transform, use_team_color, fast_forward + _one_way_latency(), shooter_peer != 0)


# Shooter-only (never the host - its shots are the real ones already). Spawns
# the volley locally the instant the trigger is pulled; the server's spawn
# event later adopts it (see _spawn_projectile_event) or reject_predicted_shot
# removes it.
func predict_shot(shot_seq: int, weapon_settings_path: String, team: String, muzzle_transform: Transform3D) -> void:
	_predicted_shots[shot_seq] = _create_volley(-1, weapon_settings_path, team, muzzle_transform, false, 0.0, true)


func reject_predicted_shot(shot_seq: int) -> void:
	for projectile in _predicted_shots.get(shot_seq, []):
		if is_instance_valid(projectile):
			projectile.queue_free()
	_predicted_shots.erase(shot_seq)


# Server-only, from collision_handler.gd::destroy_self.
func notify_projectile_ended(net_id: int) -> void:
	_projectiles.erase(net_id)
	for peer_id in _ready_peers:
		if peer_id != 1:
			_end_projectile_event.rpc_id(peer_id, net_id)


@rpc("authority", "call_remote", "reliable", 2)
func _end_projectile_event(net_id: int) -> void:
	var projectile = _projectiles.get(net_id)
	_projectiles.erase(net_id)
	if is_instance_valid(projectile):
		projectile.end_cosmetic()


# Server-only, from collision_handler.gd::_send_correction.
func send_projectile_correction(net_id: int, server_transform: Transform3D, velocity: Vector3, snap: bool) -> void:
	for peer_id in _ready_peers:
		if peer_id == 1:
			continue
		if snap:
			_correct_projectile_reliable.rpc_id(peer_id, net_id, server_transform, velocity)
		else:
			_correct_projectile.rpc_id(peer_id, net_id, server_transform, velocity)


# Periodic guided-missile stream - a lost one is superseded 50ms later, so
# unreliable (and on its own channel, so it never queues behind anything).
@rpc("authority", "call_remote", "unreliable_ordered", 3)
func _correct_projectile(net_id: int, server_transform: Transform3D, velocity: Vector3) -> void:
	_apply_projectile_correction(net_id, server_transform, velocity, false)


# One-off course changes (ricochet etc.) - same channel as spawn/end so it
# can never arrive before the spawn it refers to.
@rpc("authority", "call_remote", "reliable", 2)
func _correct_projectile_reliable(net_id: int, server_transform: Transform3D, velocity: Vector3) -> void:
	_apply_projectile_correction(net_id, server_transform, velocity, true)


func _apply_projectile_correction(net_id: int, server_transform: Transform3D, velocity: Vector3, snap: bool) -> void:
	var projectile = _projectiles.get(net_id)
	if is_instance_valid(projectile):
		projectile.apply_correction(server_transform, velocity, _one_way_latency(), snap)


# Half the ENet-measured round trip to the server, capped. 0 on the server.
func _one_way_latency() -> float:
	if multiplayer.is_server():
		return 0.0
	return minf(peer_one_way_latency(1), PROJECTILE_MAX_FAST_FORWARD)


# Half the ENet-measured round trip to peer_id (as seen from this machine).
func peer_one_way_latency(peer_id: int) -> float:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return 0.0
	var packet_peer := enet.get_peer(peer_id)
	if packet_peer == null:
		return 0.0
	return packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) / 2000.0


# Builds one volley locally - identical on every peer, which is what lets
# a single spawn event stand in for every projectile in it. net ids are
# first_id, first_id+1, ... (first_id -1 = predicted, ids assigned later).
func _create_volley(first_id: int, weapon_settings_path: String, team: String, muzzle_transform: Transform3D, use_team_color: bool, fast_forward: float, play_launch_sound: bool) -> Array:
	# weapon_settings_path is a string, not the Resource itself - every peer
	# has the same .tres locally, so each side just loads it by path.
	var settings: WeaponSettings = load(weapon_settings_path)
	if settings == null or settings.projectile_prefab == null:
		return []
	if use_team_color:
		# load() caches and shares this exact Resource across every shot of
		# this weapon by every player, so mutating projectile_color directly
		# would repaint every other shot using the same .tres. Duplicating
		# scopes it to just this volley - and since it happens before the
		# projectile ever sees weapon_settings, everything that reads
		# projectile_color for this shot's life (projectile tint, impact
		# sparks) picks up the team color automatically.
		settings = settings.duplicate()
		settings.projectile_color = ReconStation.render_color_for_team(team)
	var created: Array = []
	var transforms := _volley_transforms(settings, muzzle_transform)
	for i in transforms.size():
		var projectile := settings.projectile_prefab.instantiate()
		projectile.weapon_settings = settings
		projectile.weapon_settings_path = weapon_settings_path
		projectile.team = team
		projectile.transform = transforms[i]
		if first_id >= 0:
			projectile.net_id = first_id + i
			_projectiles[first_id + i] = projectile
		projectiles_container.add_child(projectile)
		projectile.fast_forward(fast_forward)
		created.append(projectile)
	if play_launch_sound and settings.launch_sound:
		Utilities.play_sound(settings.launch_sound, muzzle_transform.origin + Vector3.UP * 2.0, 0.1)
	return created


# Ported from the predecessor's shoot.gd::fire_weapon: a multi-shot weapon
# fires dead straight from several points on a small ring
# (projectile_spacing) rather than diverging, with a per-count start angle so
# each pattern sits symmetrically. Each shot is its own collision_handler
# instance, so each guided missile in a volley locks its own target.
func _volley_transforms(settings: WeaponSettings, muzzle: Transform3D) -> Array[Transform3D]:
	var count := maxi(settings.projectile_count, 1)
	var right := muzzle.basis.x.normalized()
	var up := muzzle.basis.y.normalized()
	var angle_step := 360.0 / count
	var start_angle: float = _VOLLEY_START_ANGLES[count - 1] if count - 1 < _VOLLEY_START_ANGLES.size() else 0
	var transforms: Array[Transform3D] = []
	for i in range(count):
		var angle := deg_to_rad(start_angle + i * angle_step)
		var offset := (right * cos(angle) + up * sin(angle)) * settings.projectile_spacing
		transforms.append(Transform3D(muzzle.basis, muzzle.origin + offset))
	return transforms


# Cosmetic only - explosion + bullet hole for one projectile impact, sent by
# collision_handler.gd::set_hit_scene on the server. Unreliable on its own
# channel: a dropped packet just means one missing spark, and it can never
# hold up gameplay-critical reliable traffic (spawns, damage, chat) queued
# behind it. Lives here on the persistent match node, not the projectile, so
# it still plays if the projectile's despawn wins the race to this peer.
@rpc("authority", "call_local", "unreliable", 1)
func _play_impact_fx(settings_path: String, color: Color, impact_transform: Transform3D, show_hit: bool, show_hole: bool, hole_point: Vector3, hole_normal: Vector3) -> void:
	if settings_path.is_empty():
		return
	var settings: WeaponSettings = load(settings_path)
	if settings == null:
		return
	if show_hit:
		if settings.hit_sound:
			Utilities.play_sound(settings.hit_sound, impact_transform.origin, 0.1)
		if settings.explosion_prefab:
			var explosion_instance := settings.explosion_prefab.instantiate()
			add_child(explosion_instance)
			explosion_instance.transform = impact_transform
			Utilities.apply_projectile_color_recursive(explosion_instance, color)
	if show_hole and settings.bullet_hole_prefab:
		var bullet_hole_instance := settings.bullet_hole_prefab.instantiate()
		add_child(bullet_hole_instance)
		var offset_position := hole_point + hole_normal * 0.01
		bullet_hole_instance.global_transform.origin = offset_position
		if not hole_normal.is_zero_approx():
			var normal := hole_normal.normalized()
			var up_vector := Vector3.UP
			if normal.dot(up_vector) > 0.999:
				up_vector = Vector3.RIGHT
			up_vector = up_vector.rotated(normal, randf() * TAU)
			if not up_vector.cross(normal).is_zero_approx():
				bullet_hole_instance.look_at_from_position(offset_position, offset_position + normal, up_vector)


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
	# radar_controller.gd finds other crafts the same generic group-based way
	# it finds anything else in its target_defs table.
	craft.add_to_group("Craft")
	craft.get_node("movement_node").team = data["team"]
	var weapon_node = craft.get_node("weapon_node")
	weapon_node.team = data["team"]
	# Runs identically on every peer, same as the team assignments above -
	# purely a local visual, no authority/RPC involved.
	var team_material: Material = TEAM_CRAFT_MATERIALS.get(data["team"])
	if team_material:
		craft.get_node("Hull").material_override = team_material
		craft.get_node("Turret").material_override = team_material
	# Hover Pad and Lights share one material (emitting_stuff.tres) across
	# every team - unlike Hull/Turret above, this one isn't expected to grow
	# into different per-team designs, just different colors, so it gets
	# duplicated-then-tinted per craft instead of swapped for a separate
	# resource (same pattern as base_gun.gd/colorable_mesh.gd elsewhere).
	var team_color := ReconStation.render_color_for_team(data["team"])
	_tint_emissive(craft.get_node("Hover Pad"), team_color)
	_tint_emissive(craft.get_node("Lights"), team_color)
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
	# health_node's _broadcast_destroyed/respawn_at RPCs are deliberately
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
	# Godot refuses to send an RPC on a synchronizer-tracked node to a peer
	# that synchronizer isn't visible to - and that check runs on the SENDING
	# peer, against its own local copy. health_node's request_fall_damage is
	# client -> server, so every peer's copy has to count the server as a
	# viewer, or the call never leaves the client ("Attempt to call an RPC to
	# a peer that cannot see this node") - client fall damage never worked.
	craft.get_node("health_node/MultiplayerSynchronizer").set_visibility_for(1, true)
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
		loading_screen.hide()
		_attach_local_camera(craft)
		_my_craft = craft
	# The signal only actually fires on the server's own execution of
	# destroy_self() (it's guarded there), so connecting here unconditionally
	# on every peer is harmless - it simply never fires on client copies.
	craft.get_node("health_node").craft_defeated.connect(_on_craft_defeated)
	return craft


func _tint_emissive(mesh_instance: MeshInstance3D, color: Color) -> void:
	var mat := mesh_instance.material_override
	if not (mat is StandardMaterial3D):
		return
	mat = mat.duplicate()
	mat.albedo_color = color
	mat.emission = color
	mesh_instance.material_override = mat


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

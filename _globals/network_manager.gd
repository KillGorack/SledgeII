extends Node

signal player_registered(peer_id: int, team: String)
signal player_unregistered(peer_id: int)
signal host_started(address: String)
signal host_failed(reason: String)
signal join_failed(reason: String)
signal games_listed(games: Array)
signal api_error(message: String)

const API_URL := "https://www.killgorack.com/PX4/api.php"
const DEFAULT_PORT := 7777
const HEARTBEAT_INTERVAL := 15.0

var peer: ENetMultiplayerPeer
var is_host: bool = false
var peer_teams: Dictionary = {}
var current_map_file_id: int = -1
# Every map .pck exports under the same virtual path (res://secret_level.tscn),
# so "does that path already resolve" can't tell two different maps apart -
# this is the actual bookkeeping for which map_file_id is currently mounted.
var mounted_map_file_id: int = -1

# The host's per-match ruleset. Empty allowed_weapon_paths means unrestricted
# (every weapon allowed) rather than "nothing allowed" - that's what a plain
# new/untouched game (or a client that briefly hasn't received the ruleset
# yet) should default to, not an accidentally weaponless craft. Peer-to-peer
# only, not part of the public lobby listing - see _assign_ruleset below and
# match.gd's use of these two fields.
var allowed_weapon_paths: Array[String] = []
var day_night_enabled: bool = true

var _heartbeat_timer: Timer

# Temporary instrumentation for the "connecting/loading takes forever, no
# errors" investigation - gives every later [JOIN] print a shared t=0 so the
# console output shows one clean timeline (connect -> scene ready -> map
# mount -> parse -> instantiate -> own craft spawned) instead of guessing
# again which stage is actually slow. Remove once this is root-caused.
var _debug_join_start_ms: int = 0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func host_game(game_name: String, map_file_id: int, weapon_paths: Array[String] = [], day_night: bool = true, host_address_override: String = "", port: int = DEFAULT_PORT, max_players: int = 20) -> Error:
	_debug_join_start_ms = Time.get_ticks_msec()
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(port, max_players)
	if err != OK:
		host_failed.emit("Could not open port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	current_map_file_id = map_file_id
	peer_teams = {1: "team_a"}
	allowed_weapon_paths = weapon_paths
	day_night_enabled = day_night
	# _get_local_ip() just takes whatever address the OS happens to list
	# first, which isn't stable if there's more than one active adapter (a
	# VPN, a virtual bridge, Wi-Fi and Ethernet both up) - that's picked a
	# slow/roundabout route before with nothing showing it happened. Resolved
	# once here, reused for both registration and the feedback message below,
	# so what actually got used is visible instead of a silent guess, and a
	# host can override it directly if it ever picks wrong.
	var host_address = host_address_override.strip_edges()
	if host_address.is_empty():
		host_address = _get_local_ip()
	_register_host(game_name, map_file_id, port, max_players, host_address)
	_start_heartbeat()
	host_started.emit(host_address)
	player_registered.emit(1, "team_a")
	return OK


func join_game(address: String, port: int, map_file_id: int) -> Error:
	_debug_join_start_ms = Time.get_ticks_msec()
	print("[JOIN] t=0ms connecting to %s:%d" % [address, port])
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(address, port)
	if err != OK:
		join_failed.emit("Could not connect to %s:%d (%s)" % [address, port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = false
	current_map_file_id = map_file_id
	return OK


func _debug_join_elapsed_ms() -> int:
	return Time.get_ticks_msec() - _debug_join_start_ms


func stop_hosting() -> void:
	if not is_host:
		return
	_stop_heartbeat()
	_unregister_host()
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_host = false
	peer_teams.clear()


# Covers both sides of leaving a match: unhosts (unregisters from the lobby,
# stops the heartbeat) if we're the host, or just tears down the connection
# if we're a joined client.
func leave_game() -> void:
	if is_host:
		stop_hosting()
	elif multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peer_teams.clear()
	current_map_file_id = -1


func list_open_games() -> void:
	_api_request("list_hosts", {}, func(data): games_listed.emit(data.get("data", [])))


func _on_peer_connected(peer_id: int) -> void:
	if not is_host:
		return
	# One match-wide ruleset, not per-peer, so this is a single targeted send
	# rather than the backfill loop below - there's nothing to backfill, the
	# host is the only one who ever sets it.
	_assign_ruleset.rpc_id(peer_id, allowed_weapon_paths, day_night_enabled)
	# Backfill the roster so the newly joined peer learns everyone already assigned.
	for existing_id in peer_teams.keys():
		_assign_team.rpc_id(peer_id, existing_id, peer_teams[existing_id])
	var team = _pick_balanced_team()
	peer_teams[peer_id] = team
	_assign_team.rpc(peer_id, team)


@rpc("authority", "call_local", "reliable")
func _assign_ruleset(weapon_paths: Array, day_night: bool) -> void:
	allowed_weapon_paths.assign(weapon_paths)
	day_night_enabled = day_night


# Teams come from who is actually on the roster right now, not from a running
# alternating flag. The flag drifted permanently the moment anybody left: it
# kept alternating regardless of which team the leaver had been on, so after a
# single leave/rejoin cycle the returning player was handed the HOST'S OWN
# team. Same-team players cannot shoot each other at all here - a team_a
# projectile masks only world and team_b (see Utilities.GROUP_LAYER_SCOPE) -
# while craft-vs-craft masks still overlap, which is exactly the "my shots
# pass straight through him but I can still bump into him" symptom.
func _pick_balanced_team() -> String:
	var count_a := 0
	var count_b := 0
	for assigned_team in peer_teams.values():
		if assigned_team == "team_a":
			count_a += 1
		else:
			count_b += 1
	return "team_a" if count_a <= count_b else "team_b"


func _on_peer_disconnected(peer_id: int) -> void:
	peer_teams.erase(peer_id)
	player_unregistered.emit(peer_id)


@rpc("authority", "call_local", "reliable")
func _assign_team(peer_id: int, team: String) -> void:
	peer_teams[peer_id] = team
	player_registered.emit(peer_id, team)


func _start_heartbeat() -> void:
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.wait_time = HEARTBEAT_INTERVAL
	_heartbeat_timer.autostart = true
	_heartbeat_timer.timeout.connect(_send_heartbeat)
	add_child(_heartbeat_timer)


func _stop_heartbeat() -> void:
	if _heartbeat_timer:
		_heartbeat_timer.queue_free()
		_heartbeat_timer = null


# Best-effort only, not a fix by itself - the OS can report more than one
# active adapter (VPN, virtual bridge, Wi-Fi and Ethernet both up at once)
# and there's no reliable way to know from here which one another machine on
# the LAN can actually reach fastest. Preferring the conventional private LAN
# ranges, in the order most home/office networks actually use them, at least
# beats picking whatever the OS happens to enumerate first. Overriding this
# entirely (see host_game's host_address_override) is the real fix when it
# still picks wrong.
const _PRIVATE_RANGE_PREFIXES := ["192.168.", "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.2", "172.30.", "172.31."]

func _get_local_ip() -> String:
	var candidates: Array[String] = []
	for addr in IP.get_local_addresses():
		if addr.begins_with("127.") or addr.contains(":"):
			continue
		candidates.append(addr)
	for prefix in _PRIVATE_RANGE_PREFIXES:
		for addr in candidates:
			if addr.begins_with(prefix):
				return addr
	if not candidates.is_empty():
		return candidates[0]
	return "127.0.0.1"


func _register_host(game_name: String, map_file_id: int, port: int, max_players: int, host_address: String) -> void:
	_api_request("register_host", {
		"hst_game_name": game_name,
		"hst_map_file_id": map_file_id,
		"hst_ip_address": host_address,
		"hst_port": port,
		"hst_max_players": max_players,
		"hst_password_protected": 0
	}, func(_data): pass)


func _send_heartbeat() -> void:
	_api_request("heartbeat", {}, func(_data): pass)


func _unregister_host() -> void:
	_api_request("unregister_host", {}, func(_data): pass)


func _api_request(function_name: String, extra_data: Dictionary, on_success: Callable) -> void:
	var http_request := HTTPRequest.new()
	add_child(http_request)
	var post_data := {
		"user_id": UserData.user_id,
		"username": UserData.username,
		"user_key": UserData.user_key,
		"freshness": UserData.freshness,
		"function": function_name,
		"formidentifier": "alacarte\\game\\lobbyAPI"
	}
	for key in extra_data.keys():
		post_data[key] = extra_data[key]
	var post_data_encoded = Utilities.encode_dict_string(post_data)
	var api_params = {
		"ap": "game",
		"cn": "hme",
		"apikeyid": Creds.apiID,
		"api": "json",
		"vc": Creds.apiKEY
	}
	var full_url = API_URL + "?" + Utilities.encode_dict_string(api_params)
	var headers = ["Content-Type: application/x-www-form-urlencoded"]
	http_request.request_completed.connect(func(_result, response_code, _headers, body):
		http_request.queue_free()
		if response_code != 200:
			api_error.emit("%s failed: server returned %d" % [function_name, response_code])
			return
		var json := JSON.new()
		if json.parse(body.get_string_from_utf8()) != OK:
			api_error.emit("%s failed: bad response from server" % function_name)
			return
		var data = json.get_data()
		# The backend now answers an invalid/expired session with an
		# explicit {"status":"error",...} instead of silently returning
		# nothing (see lobbyAPI.php/gameAPI.php) - this used to call
		# on_success regardless of what was actually in the body, so a
		# heartbeat or register_host rejection was swallowed with zero
		# trace: the hosted_games row would just quietly vanish a few
		# seconds later with nothing anywhere saying why.
		if typeof(data) == TYPE_DICTIONARY and data.get("status") != "success":
			api_error.emit("%s failed: %s" % [function_name, data.get("message", "server rejected the request")])
			return
		on_success.call(data)
	)
	http_request.request(full_url, headers, HTTPClient.METHOD_POST, post_data_encoded)

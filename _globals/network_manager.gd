extends Node

signal player_registered(peer_id: int, team: String)
signal player_unregistered(peer_id: int)
signal host_started(address: String)
signal host_failed(reason: String)
signal join_failed(reason: String)
signal games_listed(games: Array)
signal api_error(message: String)
# Sent back to just the peer whose request_team() got turned down (e.g. team
# already at MAX_PLAYERS_PER_TEAM) - player_registered never fires for them,
# so the UI needs its own signal to know to let the player pick again instead
# of just silently not proceeding.
signal team_request_rejected(reason: String)
# "Universe juice" - a team-wide resource (not per-player) that gates how
# fast a team can churn through recon captures. Generated/spent server-side
# in match.gd (the actual mechanic), broadcast here purely so any HUD element
# can read "my team's current juice" the same way it already reads
# peer_teams - this isn't tied to any one craft, so it doesn't belong on a
# per-craft MultiplayerSynchronizer the way power/health are.
signal team_juice_changed(team: String, amount: float)

const API_URL := "https://www.killgorack.com/PX4/api.php"
const DEFAULT_PORT := 7777
const HEARTBEAT_INTERVAL := 15.0

# The 4 real team identities, matching ReconStation.StationColor's vocabulary
# (see recon_station.gd::color_for_team) - a future 2-team variant would just
# restrict a match to two of these four rather than needing separate names.
const TEAM_NAMES: Array[String] = ["team_red", "team_green", "team_blue", "team_gray"]
# Base pads are ~7x7 - capped low for now purely so there's room to spawn
# without stacking players on top of each other, not a balance number.
const MAX_PLAYERS_PER_TEAM := 5

var peer: ENetMultiplayerPeer
var is_host: bool = false
var peer_teams: Dictionary = {}
var team_juice: Dictionary = {}
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


func host_game(game_name: String, map_file_id: int, weapon_paths: Array[String] = [], day_night: bool = true, host_address_override: String = "", host_team: String = "team_red", port: int = DEFAULT_PORT, max_players: int = 20) -> Error:
	_debug_join_start_ms = Time.get_ticks_msec()
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(port, max_players)
	if err != OK:
		host_failed.emit("Could not open port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	current_map_file_id = map_file_id
	peer_teams = {1: host_team}
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
	player_registered.emit(1, host_team)
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
	# Backfill the roster so the newly joined peer sees everyone already
	# assigned before picking their own - no auto-assignment anymore, the new
	# peer isn't in peer_teams at all until request_team() below succeeds, so
	# match.gd never spawns a craft for them until they've actually chosen.
	for existing_id in peer_teams.keys():
		_assign_team.rpc_id(peer_id, existing_id, peer_teams[existing_id])


# Called by a client's own UI once they've picked a color. Not authoritative
# by itself - just forwards the request to the host, which is the only one
# allowed to actually decide (see _request_team below).
func request_team(team: String) -> void:
	_request_team.rpc_id(1, team)


@rpc("any_peer", "call_local", "reliable")
func _request_team(team: String) -> void:
	if not multiplayer.is_server():
		return
	var requester_id := multiplayer.get_remote_sender_id()
	if requester_id == 0:
		return
	if not TEAM_NAMES.has(team):
		_reject_team_request.rpc_id(requester_id, "Not a real team.")
		return
	if _team_count(team) >= MAX_PLAYERS_PER_TEAM:
		_reject_team_request.rpc_id(requester_id, "%s is full." % team.trim_prefix("team_").capitalize())
		return
	peer_teams[requester_id] = team
	_assign_team.rpc(requester_id, team)


# player_registered never fires for a rejected request (peer_teams never
# gets touched), so the UI needs its own signal to know to let the player
# pick again instead of just silently doing nothing.
@rpc("authority", "reliable")
func _reject_team_request(reason: String) -> void:
	team_request_rejected.emit(reason)


@rpc("authority", "call_local", "reliable")
func _assign_ruleset(weapon_paths: Array, day_night: bool) -> void:
	allowed_weapon_paths.assign(weapon_paths)
	day_night_enabled = day_night


func _team_count(team: String) -> int:
	var count := 0
	for assigned_team in peer_teams.values():
		if assigned_team == team:
			count += 1
	return count


# A sensible default for the UI to preselect, nothing more - actual
# assignment always goes through request_team()/_request_team(), the only
# thing that ever writes a non-host entry into peer_teams.
func suggest_team() -> String:
	var best_team := TEAM_NAMES[0]
	var best_count := _team_count(best_team)
	for team in TEAM_NAMES:
		var count := _team_count(team)
		if count < best_count:
			best_team = team
			best_count = count
	return best_team


func _on_peer_disconnected(peer_id: int) -> void:
	peer_teams.erase(peer_id)
	player_unregistered.emit(peer_id)


@rpc("authority", "call_local", "reliable")
func _assign_team(peer_id: int, team: String) -> void:
	peer_teams[peer_id] = team
	player_registered.emit(peer_id, team)


@rpc("authority", "call_local", "reliable")
func _update_team_juice(team: String, amount: float) -> void:
	team_juice[team] = amount
	team_juice_changed.emit(team, amount)


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

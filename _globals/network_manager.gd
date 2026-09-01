extends Node

signal player_registered(peer_id: int, team: String)
signal host_started()
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

var _next_team_is_a: bool = false
var _heartbeat_timer: Timer


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func host_game(game_name: String, map_file_id: int, port: int = DEFAULT_PORT, max_players: int = 20) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(port, max_players)
	if err != OK:
		host_failed.emit("Could not open port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	current_map_file_id = map_file_id
	peer_teams = {1: "team_a"}
	_next_team_is_a = false
	_register_host(game_name, map_file_id, port, max_players)
	_start_heartbeat()
	host_started.emit()
	player_registered.emit(1, "team_a")
	return OK


func join_game(address: String, port: int, map_file_id: int) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(address, port)
	if err != OK:
		join_failed.emit("Could not connect to %s:%d (%s)" % [address, port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = false
	current_map_file_id = map_file_id
	return OK


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


func list_open_games() -> void:
	_api_request("list_hosts", {}, func(data): games_listed.emit(data.get("data", [])))


func _on_peer_connected(peer_id: int) -> void:
	if not is_host:
		return
	# Backfill the roster so the newly joined peer learns everyone already assigned.
	for existing_id in peer_teams.keys():
		_assign_team.rpc_id(peer_id, existing_id, peer_teams[existing_id])
	var team = "team_a" if _next_team_is_a else "team_b"
	_next_team_is_a = not _next_team_is_a
	peer_teams[peer_id] = team
	_assign_team.rpc(peer_id, team)


func _on_peer_disconnected(peer_id: int) -> void:
	peer_teams.erase(peer_id)


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


func _get_local_ip() -> String:
	for addr in IP.get_local_addresses():
		if addr.begins_with("127.") or addr.contains(":"):
			continue
		return addr
	return "127.0.0.1"


func _register_host(game_name: String, map_file_id: int, port: int, max_players: int) -> void:
	_api_request("register_host", {
		"hst_game_name": game_name,
		"hst_map_file_id": map_file_id,
		"hst_ip_address": _get_local_ip(),
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
		on_success.call(json.get_data())
	)
	http_request.request(full_url, headers, HTTPClient.METHOD_POST, post_data_encoded)

extends Control

const FEEDBACK_COLORS := {
	"OK": Color.GREEN,
	"COK": Color.YELLOW,
	"NOK": Color.RED,
	"INFO": Color.WHITE,
}
var feedback_base_x: float

@onready var btn_quit: TextureButton = $Screen_layout/Buttons_Section/Menu/VBox/btn_quit
@onready var btn_register: TextureButton = $"Screen_layout/VBoxContainer/MarginContainer/Login Group/TextureRect/MarginContainer/TextureRect/MarginContainer/MarginContainer/VBoxContainer/HBoxContainer/btn_register"
@onready var ui_feedback: Label = $Screen_layout/VBoxContainer/StatusBar/ui_feedback_node/lbl_ui_feedback
@onready var btn_play: TextureButton = $Screen_layout/Buttons_Section/Menu/VBox/btn_play
@onready var http_request = $HTTPRequest
@onready var login_timer = Timer.new()
@onready var load_group: Control = $"Screen_layout/VBoxContainer/MarginContainer/Load Game"
@onready var login_group: Control = $"Screen_layout/VBoxContainer/MarginContainer/Login Group"
@onready var txt_login: LineEdit = $"Screen_layout/VBoxContainer/MarginContainer/Login Group/TextureRect/MarginContainer/TextureRect/MarginContainer/MarginContainer/VBoxContainer/hb_username/txt_username"
@onready var txt_password: LineEdit = $"Screen_layout/VBoxContainer/MarginContainer/Login Group/TextureRect/MarginContainer/TextureRect/MarginContainer/MarginContainer/VBoxContainer/hb_password/txt_password"
@onready var btn_login: TextureButton = $"Screen_layout/VBoxContainer/MarginContainer/Login Group/TextureRect/MarginContainer/TextureRect/MarginContainer/MarginContainer/VBoxContainer/HBoxContainer/btn_submit_login"
@onready var world_list: Tree = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/HBoxContainer/LeftColumn/WorldList"
@onready var btn_host: Button = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/btn_host"
@onready var game_list: Tree = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Join Game/MarginContainer/VBoxContainer/GameList"
@onready var btn_refresh: Button = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Join Game/MarginContainer/VBoxContainer/btn_refresh"
@onready var btn_join: Button = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Join Game/MarginContainer/VBoxContainer/btn_join"
@onready var load_game_tabs: TabContainer = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer"
@onready var game_list_poll_timer := Timer.new()
@onready var day_night_check: CheckBox = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/HBoxContainer/RightColumn/DayNightCheck"
@onready var host_address_override: LineEdit = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/HBoxContainer/RightColumn/HostAddressOverride"
@onready var weapon_checklist: VBoxContainer = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/HBoxContainer/RightColumn/WeaponChecklistScroll/WeaponChecklist"

# "Create Game" is tab 0, "Join Game" is tab 1 (see index.tscn) - only poll
# the lobby API while the player is actually looking at the Join Game list,
# not in the background while they're picking a map to host.
const JOIN_GAME_TAB_INDEX := 1

# A list of folders rather than one hardcoded path, so mines (or anything
# else equippable added later) can slot into the same checklist/ruleset by
# adding a directory here - see the mines reference note from the design
# discussion for why they won't live in this same folder.
const WEAPON_CATALOG_DIRS: Array[String] = ["res://Weapons/settings/"]



var login_attempts: int = 0
var max_attempts: int = 5
var cooldown_seconds: int = 30
var is_cooldown: bool = false
var LOGGED_IN: bool = false
var is_http_busy: bool = false
var api_url: String = "https://www.killgorack.com/PX4/api.php"
var register_url: String = "https://www.killgorack.com/PX4/index.php?ap=hme&ala=register"
var function_complete = ""
var api_params = []

var selected_map_title: String = ""
var selected_map_file_id: int = -1
var selected_game_row = null




func _ready() -> void:
	add_child(login_timer)
	add_child(game_list_poll_timer)
	# Same cadence NetworkManager already uses to keep a hosted game's own
	# listing alive - one interval to remember instead of a second invented
	# number for "how fresh does this list need to be".
	game_list_poll_timer.wait_time = NetworkManager.HEARTBEAT_INTERVAL
	game_list_poll_timer.timeout.connect(func(): NetworkManager.list_open_games())
	load_game_tabs.tab_changed.connect(_on_load_game_tab_changed)
	_build_weapon_checklist()
	feedback_base_x = ui_feedback.position.x + 25
	login_timer.connect("timeout", Callable(self, "_on_cooldown_finished"))
	http_request.connect("request_completed", Callable(self, "_on_request_completed"))
	world_list.connect("item_selected", Callable(self, "_on_level_selected"))
	game_list.connect("item_selected", Callable(self, "_on_game_selected"))
	login_timer.one_shot = true
	btn_quit.pressed.connect(func(): _on_quit())
	btn_register.pressed.connect(func(): _on_register())
	btn_login.pressed.connect(func(): _on_login())
	btn_host.pressed.connect(func(): _on_host_pressed())
	btn_refresh.pressed.connect(func(): NetworkManager.list_open_games())
	btn_join.pressed.connect(func(): _on_join_pressed())
	NetworkManager.games_listed.connect(_on_games_listed)
	NetworkManager.host_started.connect(_on_host_started)
	NetworkManager.host_failed.connect(func(reason): set_ui_feedback(reason, "NOK"))
	NetworkManager.join_failed.connect(func(reason): set_ui_feedback(reason, "NOK"))
	NetworkManager.api_error.connect(func(reason): set_ui_feedback(reason, "NOK"))
	multiplayer.connected_to_server.connect(_on_joined_match)
	multiplayer.connection_failed.connect(func(): set_ui_feedback("Could not reach host - connection failed.", "NOK"))
	api_params = {
		"ap": "game",
		"cn": "hme",
		"apikeyid": Creds.apiID,
		"api": "json",
		"vc": Creds.apiKEY
	}
	# UserData is an autoload and survives scene changes (e.g. leaving a
	# match back to this menu), so an existing session shouldn't force a
	# fresh login on a brand new instance of this scene.
	if UserData.user_id > 0:
		_enter_load_screen("Welcome back, %s!" % UserData.username)
	else:
		login_group.visible = true
		load_group.visible = false
		set_ui_feedback("Please login to continue...", "INFO")
		btn_play.disabled = true


func _enter_load_screen(feedback_message: String) -> void:
	login_group.visible = false
	load_group.visible = true
	btn_play.disabled = false
	load_game_tabs.current_tab = 0
	set_ui_feedback(feedback_message, "OK")
	getLevels()
	# Refresh the Join Game list at the same moment, not just the Create Game
	# one - previously this stayed empty until the player manually hit the
	# refresh button, even though a login is exactly when it's stalest.
	NetworkManager.list_open_games()


# Keeps the Join Game list current for as long as it's actually on screen,
# without polling the lobby API in the background the rest of the time (e.g.
# while the player is just picking a map to host).
func _on_load_game_tab_changed(tab: int) -> void:
	if tab == JOIN_GAME_TAB_INDEX:
		NetworkManager.list_open_games() # don't make them wait a full interval for the first refresh
		game_list_poll_timer.start()
	else:
		game_list_poll_timer.stop()





func _input(event):
	if event.is_action_pressed("ui_accept"):
		_on_login()



func _on_level_selected():
	var selected = world_list.get_selected()
	if selected:
		selected_map_title = selected.get_text(0)
		selected_map_file_id = int(selected.get_meta("fil_id", -1))


func _on_game_selected():
	selected_game_row = game_list.get_selected()


# Built once from disk, not maintained by hand - drop a new .tres in any of
# WEAPON_CATALOG_DIRS and it shows up here with no other changes needed.
# default_available (see weapon_settings.gd) seeds each checkbox's starting
# state; the host can still check it back on or off from there.
func _build_weapon_checklist() -> void:
	for child in weapon_checklist.get_children():
		child.queue_free()
	for dir_path in WEAPON_CATALOG_DIRS:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".tres"):
				var weapon_path := dir_path.path_join(file_name)
				var settings: WeaponSettings = load(weapon_path)
				if settings:
					var check := CheckBox.new()
					check.text = settings.weapon_name
					check.button_pressed = settings.default_available
					check.set_meta("weapon_path", weapon_path)
					weapon_checklist.add_child(check)
			file_name = dir.get_next()
		dir.list_dir_end()


func _get_checked_weapon_paths() -> Array[String]:
	var paths: Array[String] = []
	for child in weapon_checklist.get_children():
		if child is CheckBox and child.button_pressed:
			paths.append(child.get_meta("weapon_path"))
	return paths


func _on_host_pressed():
	if selected_map_title == "":
		set_ui_feedback("Select a map to host first.", "COK")
		return
	NetworkManager.host_game(
		selected_map_title,
		selected_map_file_id,
		_get_checked_weapon_paths(),
		day_night_check.button_pressed,
		host_address_override.text
	)
	set_ui_feedback("Hosting \"%s\"..." % selected_map_title, "INFO")


func _on_host_started(address: String):
	# Surfacing the actual address, not just "hosted" - auto-detection can
	# pick a slow/wrong adapter silently when more than one is active (see
	# NetworkManager._get_local_ip); this at least makes it visible instead
	# of a guess nobody can check.
	set_ui_feedback("Hosting on %s, waiting for players..." % address, "OK")
	get_tree().change_scene_to_file("res://Networking/match.tscn")


func _on_join_pressed():
	if not selected_game_row:
		set_ui_feedback("Select a game to join first.", "COK")
		return
	var address = selected_game_row.get_meta("hst_ip_address", "")
	var port = int(selected_game_row.get_meta("hst_port", 0))
	var map_file_id = int(selected_game_row.get_meta("hst_map_file_id", 0))
	set_ui_feedback("Connecting...", "INFO")
	NetworkManager.join_game(address, port, map_file_id)


func _on_joined_match():
	print("[JOIN] t=%dms ENet connected_to_server fired" % NetworkManager._debug_join_elapsed_ms())
	set_ui_feedback("Connected!", "OK")
	get_tree().change_scene_to_file("res://Networking/match.tscn")


func _on_games_listed(games: Array):
	game_list.clear()
	if games.is_empty():
		set_ui_feedback("No open games found.", "COK")
		return
	var root = game_list.create_item()
	root.set_text(0, "")
	var header = game_list.create_item()
	header.set_text(0, "Game")
	header.set_text(1, "Host")
	header.set_text(2, "Players")
	header.set_selectable(0, false)
	header.set_selectable(1, false)
	header.set_selectable(2, false)
	for game in games:
		var row = game_list.create_item()
		row.set_text(0, game.get("hst_game_name", ""))
		# hst_user is just the numeric account id (see lobbyAPI.php) - the
		# actual display name is the joined hst_username field.
		row.set_text(1, str(game.get("hst_username", "")))
		row.set_text(2, "%s/%s" % [game.get("hst_current_players", "?"), game.get("hst_max_players", "?")])
		row.set_meta("hst_ip_address", game.get("hst_ip_address", ""))
		row.set_meta("hst_port", game.get("hst_port", 0))
		row.set_meta("hst_map_file_id", game.get("hst_map_file_id", 0))




func _on_login():
	if LOGGED_IN:
		return
	if is_http_busy:
		set_ui_feedback("Please wait, processing your previous request.", "COK")
		return
	var username = txt_login.text
	var password = txt_password.text
	if username == "" or password == "":
		set_ui_feedback("Please enter both username and password.", "COK")
		return
	ui_feedback.text = ""
	login_attempts += 1
	if login_attempts > max_attempts:
		is_cooldown = true
		resetForm()
		txt_login.editable = false
		txt_password.editable = false
		btn_login.disabled = true
		set_ui_feedback("Too many attempts. Please wait 30 seconds before trying again.", "NOK")
		login_timer.start(cooldown_seconds)
		return
	function_complete = "on_login"
	set_ui_feedback("Contacting server please wait a sec..", "INFO")
	var post_data = {
		"function": "authenticate",
		"userName": username,
		"password": password,
		"formidentifier": "alacarte\\game\\gameAPI"
	}
	var post_data_encoded = encode_dict_string(post_data)
	var full_url = api_url + "?" + encode_dict_string(api_params)
	var headers = ["Content-Type: application/x-www-form-urlencoded"]
	is_http_busy = true
	http_request.request(full_url, headers, HTTPClient.METHOD_POST, post_data_encoded)


func getLevels():
	function_complete = "getSecretLevelList";
	var post_data = {
		"user_id": UserData.user_id,
		"username": UserData.username,
		"user_key": UserData.user_key,
		"freshness": UserData.freshness,
		"function": "getSecretLevelList",
		"formidentifier": "alacarte\\game\\gameAPI"
	}
	var post_data_encoded = encode_dict_string(post_data)
	var full_url = api_url + "?" + encode_dict_string(api_params)
	var headers = ["Content-Type: application/x-www-form-urlencoded"]
	http_request.request(full_url, headers, HTTPClient.METHOD_POST, post_data_encoded)


func _on_request_completed(_result, response_code, _headers, body):
	if response_code == 200:
		var json_parser = JSON.new()
		var parse_result = json_parser.parse(body.get_string_from_utf8())
		if parse_result == OK:
			var response_data = json_parser.get_data()
			if function_complete == "on_login":
				if response_data.data.access == "granted":
					login_attempts = 0
					is_cooldown = false
					UserData.populate_user_data(response_data.data)
					_enter_load_screen("Welcome %s, login successful!" % UserData.username)
				else:
					set_ui_feedback("Login NOT successful, please try again!", "NOK")
					resetForm()
			elif function_complete == "getSecretLevelList":
				populate_levels_tree(response_data)
		else:
			set_ui_feedback("A server error occured", "NOK")
			resetForm()
	else:
			set_ui_feedback("Server returned error code: %d" % response_code, "NOK")
			resetForm()
	is_http_busy = false




func populate_levels_tree(response_data):
	var rootrow = world_list.create_item()
	rootrow.set_text(0, "")
	var firstrow = world_list.create_item()
	firstrow.set_text(0, "Title")
	firstrow.set_text(1, "Author")
	firstrow.set_text(2, "Genre")
	firstrow.set_selectable(0, false)
	firstrow.set_selectable(1, false)
	firstrow.set_selectable(2, false)
	for map_item in response_data.data:
		var row = world_list.create_item()
		row.set_text(0, map_item.tan_title)
		row.set_text(1, map_item.tan_author)
		row.set_text(2, map_item.tan_genre)
		row.set_meta("description", map_item.tan_description)
		row.set_meta("fil_id", map_item.file_id)
		row.set_meta("tan_id", map_item.tan_id)
		row.set_meta("thm_id", map_item.thm_id)




func resetForm():
	txt_login.text = ""
	txt_password.text = ""
	txt_login.grab_focus()





func _on_cooldown_finished():
	is_cooldown = false
	txt_login.editable = true
	txt_password.editable = true
	btn_login.disabled = false
	login_attempts = 4
	set_ui_feedback("Cooldown finished. You may try again.", "COK")
	resetForm()





func _on_register():
	OS.shell_open(register_url)





func _on_quit():
	get_tree().quit()





func encode_dict_string(data: Dictionary) -> String:
	var query_string = []
	for key in data.keys():
		var encoded_key = String(key).uri_encode()
		var encoded_value = str(data[key]).uri_encode()
		query_string.append(encoded_key + "=" + encoded_value)
	return String(",").join(query_string).replace(",", "&")





func set_ui_feedback(err_msg: String, err_lvl: String) -> void:
	var clr: Color = FEEDBACK_COLORS.get(err_lvl, Color.WHITE)
	ui_feedback.add_theme_color_override("font_color", clr)
	ui_feedback.text = err_msg
	wiggle(ui_feedback)
	
	
	
func wiggle(node: Control, amount := 6.0, duration := 0.12):
	var tween := create_tween()
	tween.tween_property(node, "position:x", feedback_base_x - amount, duration / 3)
	tween.tween_property(node, "position:x", feedback_base_x + amount, duration / 3)
	tween.tween_property(node, "position:x", feedback_base_x, duration / 3)

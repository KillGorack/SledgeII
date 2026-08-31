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
@onready var world_list: Tree = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/WorldList"
@onready var btn_create: Button = $"Screen_layout/VBoxContainer/MarginContainer/Load Game/TabContainer/Create Game/MarginContainer/VBoxContainer/btn_create"



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




func _ready() -> void:
	add_child(login_timer)
	feedback_base_x = ui_feedback.position.x + 25
	login_timer.connect("timeout", Callable(self, "_on_cooldown_finished"))
	http_request.connect("request_completed", Callable(self, "_on_request_completed"))
	world_list.connect("item_selected", Callable(self, "_on_level_selected"))
	btn_create.connect("pressed", Callable(self, "_on_create_button_pressed"))
	login_timer.one_shot = true
	btn_quit.pressed.connect(func(): _on_quit())
	btn_register.pressed.connect(func(): _on_register())
	btn_login.pressed.connect(func(): _on_login())
	login_group.visible = true
	load_group.visible = false
	set_ui_feedback("Please login to continue...", "INFO")
	btn_play.disabled = true
	api_params = {
		"ap": "game",
		"cn": "hme",
		"apikeyid": Creds.apiID,
		"api": "json",
		"vc": Creds.apiKEY
	}





func _input(event):
	if event.is_action_pressed("ui_accept"):
		_on_login()



func _on_level_selected():
	pass

func _on_create_button_pressed():
	var selected_world = world_list.get_selected()
	if selected_world:
		function_complete = "create_new_game";
		







	else:
		return



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
					set_ui_feedback("Welcome %s, login successful!" % UserData.username, "OK")
					login_group.visible = false
					load_group.visible = true
					btn_play.disabled = false
					getLevels()
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

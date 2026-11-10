extends Control

# The line at the bottom of the screen: its colour, and the colour of the light beside it.
const FEEDBACK_COLORS := {
	"OK": Color(0.3, 1.0, 0.69),
	"COK": Color(1.0, 0.82, 0.3),
	"NOK": Color(1.0, 0.33, 0.44),
	"INFO": Color(0.85, 0.93, 1.0),
}
const ACCENT := Color(0.27, 0.88, 1.0)
# Each team's colour on the team select cards, in NetworkManager.TEAM_NAMES order.
const TEAM_COLORS := {
	"team_red": Color(1.0, 0.3, 0.36),
	"team_green": Color(0.3, 0.95, 0.5),
	"team_blue": Color(0.3, 0.6, 1.0),
	"team_gray": Color(0.72, 0.76, 0.82),
}

# The scene (index.tscn) marks every node this script needs with a unique name, so the layout can be moved
# around in the editor without breaking the paths here.
@onready var backdrop: ColorRect = %Backdrop
@onready var stage: MarginContainer = %Stage
@onready var nav: HBoxContainer = %Nav
@onready var nav_line: Panel = %NavLine
@onready var pilot_box: Control = %PilotBox
@onready var pilot_name: Label = %PilotName
@onready var status_led: ColorRect = %StatusLed
@onready var btn_quit: Button = %btn_quit
@onready var btn_register: Button = %btn_register
@onready var ui_feedback: Label = %lbl_ui_feedback
@onready var btn_settings: Button = %btn_settings
@onready var btn_credits: Button = %btn_credits
@onready var settings_group: Control = %Settings
@onready var credits_group: Control = %Credits
@onready var http_request = $HTTPRequest
@onready var login_timer = Timer.new()
@onready var login_group: Control = $"Layout/Stage/Login Group"
@onready var txt_login: LineEdit = %txt_username
@onready var txt_password: LineEdit = %txt_password
@onready var btn_login: Button = %btn_submit_login
@onready var world_list: Tree = %WorldList
@onready var map_thumbnail: TextureRect = %MapThumbnail
@onready var thumb_frame: AspectRatioContainer = %ThumbFrame
@onready var map_description: RichTextLabel = %MapDescription
@onready var map_title: Label = %MapTitle
@onready var map_byline: Label = %MapByline
@onready var host_summary: RichTextLabel = %HostSummary
@onready var btn_host: Button = %btn_host
@onready var game_list: Tree = %GameList
@onready var game_count: Label = %GameCount
@onready var no_games: Control = %NoGames
@onready var join_title: Label = %JoinTitle
@onready var join_details: RichTextLabel = %JoinDetails
@onready var btn_refresh: Button = %btn_refresh
@onready var btn_join: Button = %btn_join
# The three main screens (Create Game / Join Game / Community Levels). Its own tab strip is hidden; the buttons
# in the top bar switch it.
@onready var load_game_tabs: TabContainer = $"Layout/Stage/Load Game"
@onready var game_list_poll_timer := Timer.new()
@onready var mine_checklist: Container = %MineChecklist
@onready var rockets_check: BaseButton = %RocketsCheck
@onready var recon_capture_check: BaseButton = %ReconCaptureCheck
@onready var day_night_check: BaseButton = %DayNightCheck
@onready var public_game_check: BaseButton = %PublicGameCheck

# Set by NetworkManager.port_forward_failed, read by _on_host_started - see
# _on_host_pressed's comment for why this can't just be a set_ui_feedback()
# call at the point it fires.
var _pending_port_forward_warning: String = ""
@onready var weapon_checklist: Container = %WeaponChecklist
@onready var host_team_picker: OptionButton = %HostTeamPicker
@onready var team_select_group: Control = $"Layout/Stage/Team Select"
@onready var host_vehicle_row: Control = %HostVehicleRow
@onready var join_vehicle_row: Control = %JoinVehicleRow
@onready var team_roster: Container = %TeamRoster
@onready var team_select_feedback: Label = %TeamSelectFeedback

# "Create Game" is tab 0, "Join Game" is tab 1 (see index.tscn) - only poll
# the lobby API while the player is actually looking at the Join Game list,
# not in the background while they're picking a map to host.
const JOIN_GAME_TAB_INDEX := 1

# A list of folders rather than one hardcoded path, so mines (or anything
# else equippable added later) can slot into the same checklist/ruleset by
# adding a directory here - see the mines reference note from the design
# discussion for why they won't live in this same folder.
const MINE_CATALOG_DIR := "res://Weapons/settings_mines/"
const WEAPON_CATALOG_DIRS: Array[String] = ["res://Weapons/settings/"]
const CRAFT_SCENE_PATH := "res://Crafts/Scenes/craft.tscn"
# The menu's card (a panel with corner brackets), for the cards this script builds itself.
const HUD_CARD := preload("res://UI/_scripts/hud_card.gd")



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
# static so it outlives this scene - index.tscn is rebuilt from scratch every
# time a match exits back here, and populate_levels_tree reselects it.
static var _last_selected_map_file_id: int = -1
# Same for the tab (Create Game / Join Game / Community Levels) the player was on.
static var _last_load_tab: int = 0

# The map list as the server sent it, and the two filters over it (built in
# code above the list). "" means no filter.
const ORIGIN_NAMES: Array[String] = ["Tanarus Original", "Submitted CAD model", "Creative level"]
var _level_rows: Array = []
var _origin_filter: OptionButton
var _genre_filter: OptionButton
# The host screen's choices, saved when Host is pressed and restored on the
# next visit - even after a restart. See _save_host_settings.
const HOST_SETTINGS_PATH := "user://host_settings.cfg"
var selected_game_row = null
@onready var _host_picker: OptionButton = %HostVehiclePicker
@onready var _join_picker: OptionButton = %JoinVehiclePicker
@onready var _craft_checklist: Container = %CraftChecklist
@onready var _craft_section: Control = %CraftSection




# The Settings screen is built but left out of the menu for now; set this to true to bring its button back.
const SHOW_SETTINGS := false

# Menu music: "Break The Line" by Abbynoise (Uppbeat, credited in credits.gd). It lives on this scene, so it
# stops by itself when a match loads and starts again when the player comes back to the menu.
const MENU_MUSIC := preload("res://UI/music/break_the_line.mp3")
# The player's music slider (in the bar along the bottom of the menu), 0 = off. Remembered between sessions.
const MENU_MUSIC_DEFAULT := 0.3
const MENU_MUSIC_TOP_DB := -6.0 # slider all the way up
const MUSIC_FADE_SECONDS := 1.5
const SETTINGS_PATH := "user://settings.cfg"
var _music_player: AudioStreamPlayer


func _ready() -> void:
	btn_settings.visible = SHOW_SETTINGS
	_start_menu_music()
	_build_credits()
	_add_version_label()
	_build_nav()
	_setup_lists()
	add_child(login_timer)
	add_child(game_list_poll_timer)
	# Same cadence NetworkManager already uses to keep a hosted game's own
	# listing alive - one interval to remember instead of a second invented
	# number for "how fresh does this list need to be".
	game_list_poll_timer.wait_time = NetworkManager.HEARTBEAT_INTERVAL
	game_list_poll_timer.timeout.connect(func(): NetworkManager.list_open_games())
	load_game_tabs.tab_changed.connect(_on_load_game_tab_changed)
	_build_weapon_checklist()
	_build_mine_checklist()
	for team in NetworkManager.TEAM_NAMES:
		host_team_picker.add_item(team.trim_prefix("team_").capitalize())
	_setup_vehicle_pickers()
	_build_craft_checklist()
	NetworkManager.ruleset_received.connect(_refresh_join_picker)
	_load_host_settings()
	_refresh_host_picker()
	login_timer.connect("timeout", Callable(self, "_on_cooldown_finished"))
	http_request.connect("request_completed", Callable(self, "_on_request_completed"))
	world_list.connect("item_selected", Callable(self, "_on_level_selected"))
	_build_level_filters()
	game_list.connect("item_selected", Callable(self, "_on_game_selected"))
	login_timer.one_shot = true
	btn_quit.pressed.connect(func(): _on_quit())
	thumb_frame.resized.connect(_fit_thumb_frame)
	btn_settings.pressed.connect(func(): _toggle_info_panel(settings_group))
	btn_credits.pressed.connect(func(): _toggle_info_panel(credits_group))
	%btn_settings_back.pressed.connect(_leave_info_panel)
	%btn_credits_back.pressed.connect(_leave_info_panel)
	host_team_picker.item_selected.connect(func(_index): _refresh_host_summary())
	public_game_check.toggled.connect(func(_on): _refresh_host_summary())
	# host_started (see _on_host_started) takes it from there into match.tscn.
	btn_register.pressed.connect(func(): _on_register())
	btn_login.pressed.connect(func(): _on_login())
	btn_host.pressed.connect(func(): _on_host_pressed())
	btn_refresh.pressed.connect(func(): NetworkManager.list_open_games())
	btn_join.pressed.connect(func(): _on_join_pressed())
	NetworkManager.games_listed.connect(_on_games_listed)
	NetworkManager.host_started.connect(_on_host_started)
	NetworkManager.host_failed.connect(func(reason): set_ui_feedback(reason, "NOK"))
	# Hosting still succeeds when this fires - fires synchronously inside
	# host_game(), before host_started, before this scene gets replaced - see
	# _on_host_started for where this actually gets shown.
	NetworkManager.port_forward_failed.connect(func(reason): _pending_port_forward_warning = "Couldn't auto-forward your port: %s. Forward UDP %d manually for internet players." % [reason, NetworkManager.DEFAULT_PORT])
	NetworkManager.join_failed.connect(_on_join_failed)
	NetworkManager.api_error.connect(func(reason): set_ui_feedback(reason, "NOK"))
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_unregistered.connect(func(_peer_id): _build_team_roster())
	NetworkManager.team_request_rejected.connect(_on_team_request_rejected)
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
		_show_screen(login_group)
		set_ui_feedback("Please login to continue...", "INFO")
		txt_login.grab_focus.call_deferred()

	# A join that failed while a match scene was up (see NetworkManager._version_failed) sends us here.
	if NetworkManager.menu_notice != "":
		_show_menu_notice()


# Held back a moment: opening the menu writes its own feedback line a second in.
func _show_menu_notice() -> void:
	await get_tree().create_timer(1.4).timeout
	if NetworkManager.menu_notice != "":
		set_ui_feedback(NetworkManager.menu_notice, "NOK")
		NetworkManager.menu_notice = ""


# --- Screens ----------------------------------------------------------------------------------------------------
# One of these fills the stage at a time: login, the three main screens (one TabContainer, switched from the top
# bar), team select, and the Settings / Credits panels. Those two remember what they covered and give it back.
const STAGE_MARGIN_TOP := 22
const SCREEN_SLIDE := 26
var _return_panel: Control = null
var _screen_tween: Tween
var _screen_animated: Control
var _backdrop_tween: Tween
var _nav_tween: Tween


func _screens() -> Array[Control]:
	return [login_group, load_game_tabs, team_select_group, settings_group, credits_group]


func _current_screen() -> Control:
	for screen in _screens():
		if screen.visible:
			return screen
	return null


func _show_screen(screen: Control) -> void:
	for other in _screens():
		other.visible = other == screen
	_animate_in(screen)
	var logged_in: bool = UserData.user_id > 0
	nav.visible = logged_in
	pilot_box.visible = logged_in
	pilot_name.text = str(UserData.username)
	%Logo.visible = screen != login_group # the login screen shows the title large, above its card
	_refresh_nav(false)
	# The grid runs at full strength behind the login card and the team cards, and is turned down behind the
	# screens that are mostly text.
	var level := 1.0 if screen == login_group or screen == team_select_group else 0.4
	if _backdrop_tween:
		_backdrop_tween.kill()
	_backdrop_tween = create_tween()
	_backdrop_tween.tween_property(backdrop.material, "shader_parameter/intensity", level, 0.9).set_trans(Tween.TRANS_SINE)


# A screen arrives by fading in while sliding up a little. The slide is the stage's top margin, since the
# screens sit in a container and can't be moved directly.
func _animate_in(screen: Control) -> void:
	if _screen_tween and _screen_tween.is_valid():
		_screen_tween.kill()
		if is_instance_valid(_screen_animated):
			_screen_animated.modulate.a = 1.0
	_screen_animated = screen
	screen.modulate.a = 0.0
	stage.add_theme_constant_override("margin_top", STAGE_MARGIN_TOP + SCREEN_SLIDE)
	_screen_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_screen_tween.tween_property(screen, "modulate:a", 1.0, 0.3)
	_screen_tween.tween_method(func(margin: int) -> void: stage.add_theme_constant_override("margin_top", margin), STAGE_MARGIN_TOP + SCREEN_SLIDE, STAGE_MARGIN_TOP, 0.34)


# The Settings and Credits buttons open their panel, and close it again if it is the one showing.
func _toggle_info_panel(panel: Control) -> void:
	if panel.visible:
		_leave_info_panel()
		return
	var current := _current_screen()
	if current != settings_group and current != credits_group:
		_return_panel = current
	_show_screen(panel)


func _leave_info_panel() -> void:
	var back: Control = _return_panel if _return_panel else (load_game_tabs if UserData.user_id > 0 else login_group)
	_return_panel = null
	_show_screen(back)


# --- Top bar ----------------------------------------------------------------------------------------------------
# Create Game / Join Game / Community Levels. They switch load_game_tabs, whose own tab strip is hidden. The
# bright line under the chosen one is a separate node (NavLine) so it can slide from button to button.

func _build_nav() -> void:
	for i in nav.get_child_count():
		var button := nav.get_child(i) as Button
		button.pressed.connect(_on_nav_pressed.bind(i))
		# Follows the button when the window is resized or the bar lays itself out again.
		button.item_rect_changed.connect(func() -> void: _place_nav_line(false))


func _on_nav_pressed(tab: int) -> void:
	if not load_game_tabs.visible:
		_return_panel = null
		_show_screen(load_game_tabs)
	load_game_tabs.current_tab = tab
	_refresh_nav()


func _refresh_nav(animate: bool = true) -> void:
	for i in nav.get_child_count():
		(nav.get_child(i) as Button).set_pressed_no_signal(load_game_tabs.visible and i == load_game_tabs.current_tab)
	_place_nav_line(animate)


func _place_nav_line(animate: bool) -> void:
	if _nav_tween:
		_nav_tween.kill()
	if not (nav.visible and load_game_tabs.visible):
		nav_line.visible = false
		return
	var button := nav.get_child(load_game_tabs.current_tab) as Control
	var bar: Control = %TopBar
	var target := Vector2(button.global_position.x - global_position.x, bar.global_position.y - global_position.y + bar.size.y - 3.0)
	if not nav_line.visible or not animate:
		nav_line.visible = true
		nav_line.position = target
		nav_line.size = Vector2(button.size.x, 3.0)
		return
	_nav_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_nav_tween.tween_property(nav_line, "position", target, 0.28)
	_nav_tween.tween_property(nav_line, "size", Vector2(button.size.x, 3.0), 0.28)


# The two lists use real column headings, sized by share so a long name can't push the others off.
func _setup_lists() -> void:
	var world_titles := ["ARENA", "AUTHOR", "GENRE"]
	var world_shares := [5, 3, 2]
	for i in world_titles.size():
		world_list.set_column_title(i, world_titles[i])
		world_list.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
		world_list.set_column_expand_ratio(i, world_shares[i])
		world_list.set_column_clip_content(i, true)
	var game_titles := ["ARENA", "HOSTED BY", "PILOTS", "DAY / NIGHT"]
	var game_shares := [4, 3, 2, 2]
	for i in game_titles.size():
		game_list.set_column_title(i, game_titles[i])
		game_list.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
		game_list.set_column_expand_ratio(i, game_shares[i])
		game_list.set_column_clip_content(i, true)
	_show_game_details(null)


func _enter_load_screen(feedback_message: String) -> void:
	_return_panel = null
	_show_screen(load_game_tabs)
	load_game_tabs.current_tab = clampi(_last_load_tab, 0, load_game_tabs.get_tab_count() - 1)
	_refresh_nav(false)
	set_ui_feedback(feedback_message, "OK")
	# Ask the server about the player's own levels now, whichever tab is showing, so My Creations is right when opened.
	var my_creations := load_game_tabs.get_node_or_null("Community Levels/My Creations")
	if my_creations and my_creations.has_method("check_server"):
		my_creations.check_server()
	getLevels()
	await get_tree().create_timer(1).timeout
	NetworkManager.list_open_games()


# Keeps the Join Game list current for as long as it's actually on screen,
# without polling the lobby API in the background the rest of the time (e.g.
# while the player is just picking a map to host).
# The Credits screen's text, and a Licenses button that shows the engine's notices.
func _build_credits() -> void:
	var text_label: RichTextLabel = %CreditsText
	text_label.text = Credits.text()
	text_label.meta_clicked.connect(func(meta): OS.shell_open(str(meta)))
	var dialog := AcceptDialog.new()
	dialog.title = "Licenses"
	dialog.exclusive = false
	dialog.min_size = Vector2i(900, 640)
	var box := TextEdit.new()
	box.editable = false
	box.custom_minimum_size = Vector2(860, 560)
	box.text = Credits.licenses_text()
	dialog.add_child(box)
	add_child(dialog)
	%btn_licenses.pressed.connect(func() -> void: dialog.popup_centered())


# Both ways into a match (hosting, and joining once a team is confirmed) end here. The music moves out of this
# scene, which is about to be freed, and fades out over the load.
func _enter_arena() -> void:
	if _music_player and _music_player.playing:
		var player := _music_player
		_music_player = null
		player.reparent(get_tree().root)
		var tween := player.create_tween()
		tween.tween_property(player, "volume_db", -60.0, MUSIC_FADE_SECONDS)
		tween.tween_callback(player.queue_free)
	get_tree().change_scene_to_file("res://Networking/match.tscn")


# Slider position (0..1) to loudness: a straight volume scale, so the low end is gentle; 0 stops the track.
func _apply_music_volume(value: float) -> void:
	if _music_player == null:
		return
	if value <= 0.001:
		_music_player.stop()
		return
	_music_player.volume_db = linear_to_db(value) + MENU_MUSIC_TOP_DB
	if not _music_player.playing:
		_music_player.play()


func _start_menu_music() -> void:
	var stream := MENU_MUSIC.duplicate() as AudioStreamMP3
	stream.loop = true
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "MenuMusic"
	_music_player.stream = stream
	add_child(_music_player)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # missing file is fine: defaults
	var value := clampf(float(cfg.get_value("audio", "menu_music", MENU_MUSIC_DEFAULT)), 0.0, 1.0)
	_apply_music_volume(value)
	var slider: HSlider = %MusicSlider
	slider.set_value_no_signal(value)
	slider.value_changed.connect(func(v: float) -> void:
		_apply_music_volume(v)
		var out := ConfigFile.new()
		out.load(SETTINGS_PATH) # keep any other saved settings
		out.set_value("audio", "menu_music", v)
		out.save(SETTINGS_PATH))


# The build's version (Project Settings > Application > Config > Version), at the right end of the bottom bar, so a
# bug report can say which build it came from.
func _add_version_label() -> void:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var label: Label = %VersionLabel
	label.text = "V" + version
	label.visible = not version.is_empty()


func _on_load_game_tab_changed(tab: int) -> void:
	_last_load_tab = tab
	_refresh_nav()
	_animate_in(load_game_tabs.get_current_tab_control())
	if tab == JOIN_GAME_TAB_INDEX:
		NetworkManager.list_open_games() # don't make them wait a full interval for the first refresh
		game_list_poll_timer.start()
	else:
		game_list_poll_timer.stop()





func _input(event):
	# Enter logs in, but only while the login card is the screen showing.
	if event.is_action_pressed("ui_accept") and login_group.visible:
		_on_login()



func _on_level_selected():
	var selected = world_list.get_selected()
	if selected:
		selected_map_title = selected.get_text(0)
		selected_map_file_id = int(selected.get_meta("fil_id", -1))
		_last_selected_map_file_id = selected_map_file_id
		_show_map_details(selected)
		_refresh_host_summary()


# The line beside the Host button: what is about to be hosted.
func _refresh_host_summary() -> void:
	if selected_map_title == "":
		host_summary.text = "[color=#8099b8]Pick an arena to host.[/color]"
		return
	var parts: Array[String] = []
	for pair in [
		["ARENA", selected_map_title],
		["TEAM", host_team_picker.get_item_text(host_team_picker.selected) if host_team_picker.selected >= 0 else "-"],
		["GAME", "Public" if public_game_check.button_pressed else "LAN only"],
	]:
		parts.append("[color=#8099b8][font_size=14]%s[/font_size][/color]  [b]%s[/b]" % [pair[0], str(pair[1]).replace("[", "[lb]")])
	host_summary.text = "        ".join(parts)


# Same source the original Sledge uses for secret level thumbnails
# (secret_levels.gd): the map's tan_id against the game_thumb download type.
# Fetched on selection and cached, since flicking back through the list
# shouldn't re-download. A map with no thumbnail just shows an empty frame.
const THUMBNAIL_URL := "https://www.killgorack.com/PX4/downloader.php?ap=tanarusmaps&id=%s&type=game_thumb&cn=fls"
var _thumb_request: HTTPRequest
var _thumb_cache: Dictionary = {}


# An AspectRatioContainer sizes its child from its width but reports no minimum height of its own,
# so the column above would draw over it. Reserve the 16:9 height explicitly.
func _fit_thumb_frame() -> void:
	thumb_frame.custom_minimum_size.y = thumb_frame.size.x / thumb_frame.ratio


func _show_map_details(row: TreeItem) -> void:
	var description := str(row.get_meta("description", ""))
	map_description.text = description if description != "" else "No description available."
	map_title.text = row.get_text(0)
	map_byline.text = "by %s   //   %s" % [row.get_text(1), row.get_text(2)]
	if row.get_meta("origin", "") == "Creative level":
		map_byline.text += "   //   Community level"
	var tan_id := int(row.get_meta("tan_id", -1))
	if _thumb_cache.has(tan_id):
		_set_thumbnail(_thumb_cache[tan_id])
		return
	map_thumbnail.texture = null
	if tan_id < 0:
		return
	if _thumb_request == null:
		_thumb_request = HTTPRequest.new()
		add_child(_thumb_request)
		_thumb_request.request_completed.connect(_on_thumbnail_loaded)
	# Drops any request still in flight for a map that's no longer selected.
	_thumb_request.cancel_request()
	_thumb_request_id = tan_id
	_thumb_request.request(THUMBNAIL_URL % str(tan_id))


var _thumb_request_id: int = -1


func _on_thumbnail_loaded(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		return
	var image := Image.new()
	if image.load_png_from_buffer(body) != OK and image.load_jpg_from_buffer(body) != OK and image.load_webp_from_buffer(body) != OK:
		return
	var texture := ImageTexture.create_from_image(image)
	_thumb_cache[_thumb_request_id] = texture
	_set_thumbnail(texture)


var _thumb_tween: Tween


# The picture fades in rather than popping.
func _set_thumbnail(texture: Texture2D) -> void:
	map_thumbnail.texture = texture
	if _thumb_tween:
		_thumb_tween.kill()
	map_thumbnail.modulate.a = 0.0
	_thumb_tween = create_tween()
	_thumb_tween.tween_property(map_thumbnail, "modulate:a", 1.0, 0.25)


func _on_game_selected():
	selected_game_row = game_list.get_selected()
	_show_game_details(selected_game_row)


# The card beside the Join Game list: what the selected row's host has set up.
func _show_game_details(row: TreeItem) -> void:
	btn_join.disabled = row == null
	if row == null:
		join_title.text = "Select a game"
		join_details.text = "[color=#8099b8]Pick a game from the list to see who is hosting and what is allowed.[/color]"
		return
	join_title.text = row.get_text(0)
	var manifest: Dictionary = row.get_meta("manifest", {})
	var lines: Array[String] = []
	for pair in [["HOSTED BY", row.get_text(1)], ["PILOTS", row.get_text(2)], ["DAY / NIGHT", "On" if manifest.get("day_night", true) else "Off"]]:
		lines.append("[color=#8099b8][font_size=14]%s[/font_size][/color]\n[b]%s[/b]\n" % [pair[0], str(pair[1]).replace("[", "[lb]")])
	var weapons: Array = manifest.get("weapons", [])
	if not weapons.is_empty():
		lines.append("[color=#8099b8][font_size=14]WEAPONS[/font_size][/color]\n%s" % ", ".join(weapons).replace("[", "[lb]"))
	join_details.text = "\n".join(lines)


# One entry of the weapon / special / vehicle lists: a tick box drawn as a tag (ChipCheck in the theme).
func _make_chip(text: String, tooltip: String = "") -> CheckBox:
	var chip := CheckBox.new()
	chip.theme_type_variation = &"ChipCheck"
	chip.focus_mode = Control.FOCUS_NONE
	chip.text = text
	chip.tooltip_text = tooltip
	return chip


# Built once from disk, not maintained by hand - drop a new .tres in any of
# WEAPON_CATALOG_DIRS and it shows up here with no other changes needed.
# default_available (see weapon_settings.gd) seeds each checkbox's starting
# state; the host can still check it back on or off from there.
#
# ResourceLoader.list_directory(), not DirAccess - Godot converts .tres files
# to binary .res on export by default (editor/export/convert_text_resources_
# to_binary, on by default, not overridden in this project), so a DirAccess
# scan filtering on ".tres" found every weapon in the editor and NONE of them
# in an exported build, silently. ResourceLoader.list_directory() reports
# each file's original pre-export extension regardless of how it's actually
# stored, so this filter works identically in both.
#
# Listed in the craft's own weapon order (weapon_node.weapon_settings in
# craft.tscn, the order weapons cycle in a match); anything on disk the craft
# doesn't carry goes after, in folder order.
func _build_weapon_checklist() -> void:
	for child in weapon_checklist.get_children():
		child.queue_free()
	var weapon_paths := _craft_weapon_order()
	for dir_path in WEAPON_CATALOG_DIRS:
		for file_name in ResourceLoader.list_directory(dir_path):
			if file_name.ends_with("/") or not file_name.ends_with(".tres"):
				continue
			var weapon_path := dir_path.path_join(file_name)
			if not weapon_paths.has(weapon_path):
				weapon_paths.append(weapon_path)
	for weapon_path in weapon_paths:
		var settings: WeaponSettings = load(weapon_path)
		if settings:
			var check := _make_chip(settings.weapon_name)
			check.button_pressed = settings.default_available
			check.set_meta("weapon_path", weapon_path)
			weapon_checklist.add_child(check)


# Read off craft.tscn's saved state rather than instantiating a whole craft in the menu.
func _craft_weapon_order() -> Array[String]:
	var paths: Array[String] = []
	var state := (load(CRAFT_SCENE_PATH) as PackedScene).get_state()
	for node in state.get_node_count():
		if state.get_node_name(node) != "weapon_node":
			continue
		for prop in state.get_node_property_count(node):
			if state.get_node_property_name(node, prop) == "weapon_settings":
				for settings in state.get_node_property_value(node, prop):
					if settings and not paths.has(settings.resource_path):
						paths.append(settings.resource_path)
	return paths


# Same idea as the weapon list, for the specials (mines). There is no master switch:
# mines exist in a match exactly when at least one of them is ticked. The
# built-in specials (SpecialCatalog) follow the mines in the same list, tagged
# "special_id" instead of "mine_path", and start unticked.
func _build_mine_checklist() -> void:
	for child in mine_checklist.get_children():
		child.queue_free()
	for file_name in ResourceLoader.list_directory(MINE_CATALOG_DIR):
		if file_name.ends_with("/") or not file_name.ends_with(".tres"):
			continue
		var mine_path := MINE_CATALOG_DIR.path_join(file_name)
		var settings: MineSettings = load(mine_path)
		if settings:
			var check := _make_chip(settings.mine_name, settings.mine_lore)
			check.button_pressed = settings.default_available
			check.set_meta("mine_path", mine_path)
			mine_checklist.add_child(check)
	for id in SpecialCatalog.ids():
		var check := _make_chip(SpecialCatalog.display_name(id), SpecialCatalog.description(id))
		check.set_meta("special_id", id)
		mine_checklist.add_child(check)


func _get_checked_mine_paths() -> Array[String]:
	var paths: Array[String] = []
	for child in mine_checklist.get_children():
		if child is CheckBox and child.button_pressed and child.has_meta("mine_path"):
			paths.append(child.get_meta("mine_path"))
	return paths


func _get_checked_specials() -> Array[StringName]:
	var ids: Array[StringName] = []
	for child in mine_checklist.get_children():
		if child is CheckBox and child.button_pressed and child.has_meta("special_id"):
			ids.append(child.get_meta("special_id"))
	return ids


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
	# host_game() is synchronous (UPnP's discover()/add_port_mapping() block
	# until they finish) - by the time it returns, port_forward_failed has
	# already fired (if it was going to) and _on_host_started has already run
	# and changed the scene. Nothing useful is left to say here afterward -
	# see _pending_port_forward_warning for where that message actually goes.
	_pending_port_forward_warning = ""
	_save_host_settings()
	NetworkManager.host_game(
		selected_map_title,
		selected_map_file_id,
		_get_checked_weapon_paths(),
		day_night_check.button_pressed,
		"",
		NetworkManager.TEAM_NAMES[host_team_picker.selected],
		NetworkManager.DEFAULT_PORT,
		20,
		public_game_check.button_pressed,
		NetworkManager.BASE_GUN_RESPAWN_SECONDS,
		not _get_checked_mine_paths().is_empty(),
		_get_checked_mine_paths(),
		rockets_check.button_pressed,
		recon_capture_check.button_pressed,
		_get_checked_specials(),
		_checked_craft_ids()
	)


# Weapons and mines are saved as "every one the screen listed" plus "the ticked
# ones", so one added to the game later still starts at its own default instead
# of reading as unticked.
func _save_host_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("host", "map_file_id", selected_map_file_id)
	cfg.set_value("host", "team", host_team_picker.selected)
	cfg.set_value("host", "public_game", public_game_check.button_pressed)
	cfg.set_value("host", "rockets", rockets_check.button_pressed)
	cfg.set_value("host", "recon_capture", recon_capture_check.button_pressed)
	cfg.set_value("host", "day_night", day_night_check.button_pressed)
	cfg.set_value("host", "weapons_listed", _listed_paths(weapon_checklist, "weapon_path"))
	cfg.set_value("host", "weapons_checked", _get_checked_weapon_paths())
	cfg.set_value("host", "mines_listed", _listed_paths(mine_checklist, "mine_path"))
	cfg.set_value("host", "mines_checked", _get_checked_mine_paths())
	cfg.set_value("host", "specials_listed", _listed_paths(mine_checklist, "special_id"))
	cfg.set_value("host", "specials_checked", _get_checked_specials())
	cfg.set_value("host", "crafts_listed", _listed_paths(_craft_checklist, "craft_id"))
	cfg.set_value("host", "crafts_checked", _checked_craft_ids())
	var err := cfg.save(HOST_SETTINGS_PATH)
	if err != OK:
		push_warning("Couldn't save host settings (%s)" % error_string(err))


# Nothing saved yet (first run) just leaves the scene's defaults.
func _load_host_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(HOST_SETTINGS_PATH) != OK:
		return
	if _last_selected_map_file_id == -1:
		_last_selected_map_file_id = cfg.get_value("host", "map_file_id", -1)
	var team: int = cfg.get_value("host", "team", host_team_picker.selected)
	if team >= 0 and team < host_team_picker.item_count:
		host_team_picker.select(team)
	public_game_check.button_pressed = cfg.get_value("host", "public_game", public_game_check.button_pressed)
	rockets_check.button_pressed = cfg.get_value("host", "rockets", rockets_check.button_pressed)
	recon_capture_check.button_pressed = cfg.get_value("host", "recon_capture", recon_capture_check.button_pressed)
	day_night_check.button_pressed = cfg.get_value("host", "day_night", day_night_check.button_pressed)
	_restore_checklist(weapon_checklist, "weapon_path", cfg.get_value("host", "weapons_listed", []), cfg.get_value("host", "weapons_checked", []))
	_restore_checklist(mine_checklist, "mine_path", cfg.get_value("host", "mines_listed", []), cfg.get_value("host", "mines_checked", []))
	_restore_checklist(mine_checklist, "special_id", cfg.get_value("host", "specials_listed", []), cfg.get_value("host", "specials_checked", []))
	_restore_checklist(_craft_checklist, "craft_id", cfg.get_value("host", "crafts_listed", []), cfg.get_value("host", "crafts_checked", []))
	if _checked_craft_ids().is_empty(): # a hand-edited or stale file: never start with no vehicle
		for child in _craft_checklist.get_children():
			if child is CheckBox:
				child.button_pressed = true


# Only the checkboxes carrying `meta` - the specials list mixes mines and built-ins.
func _listed_paths(checklist: Container, meta: String) -> Array:
	var paths: Array = []
	for child in checklist.get_children():
		if child is CheckBox and child.has_meta(meta):
			paths.append(child.get_meta(meta))
	return paths


func _restore_checklist(checklist: Container, meta: String, listed: Array, checked: Array) -> void:
	for child in checklist.get_children():
		if child is CheckBox and child.has_meta(meta) and listed.has(child.get_meta(meta)):
			child.button_pressed = checked.has(child.get_meta(meta))


func _on_host_started(address: String) -> void:
	# Surfacing the actual address, not just "hosted" - auto-detection can
	# pick a slow/wrong adapter silently when more than one is active (see
	# NetworkManager._get_local_ip); this at least makes it visible instead
	# of a guess nobody can check. Note: match.tscn replaces this whole scene
	# (ui_feedback included) right after, so this message is only ever
	# visible for an instant - see git history if that needs revisiting.
	if _pending_port_forward_warning != "":
		set_ui_feedback("Hosting on %s (LAN only). %s" % [address, _pending_port_forward_warning], "NOK")
	else:
		set_ui_feedback("Hosting on %s, waiting for players..." % address, "OK")
	_enter_arena()


func _on_join_pressed():
	if not selected_game_row:
		set_ui_feedback("Select a game to join first.", "COK")
		return
	var address = selected_game_row.get_meta("hst_ip_address", "")
	var port = int(selected_game_row.get_meta("hst_port", 0))
	var map_file_id = int(selected_game_row.get_meta("hst_map_file_id", 0))
	set_ui_feedback("Connecting...", "INFO")
	NetworkManager.join_game(address, port, map_file_id, selected_game_row.get_text(0))


# A failed join. If it failed AFTER connecting (a version mismatch is only found out then), the team
# select screen is up - put the player back on the screen they came from.
func _on_join_failed(reason: String) -> void:
	set_ui_feedback(reason, "NOK")
	NetworkManager.menu_notice = ""
	if _return_panel == team_select_group: # Credits is open over the team cards: don't go back to them
		_return_panel = null
	if team_select_group.visible:
		_show_screen(load_game_tabs if UserData.user_id > 0 else login_group)


func _on_joined_match():
	set_ui_feedback("Connected! Choose your team.", "OK")
	# Hold here instead of jumping straight to match.tscn (like this used to)
	# until the host actually confirms a team - see _on_player_registered,
	# which is what does the real transition once that happens.
	_return_panel = null
	_show_screen(team_select_group)
	_build_team_roster()


# Fires for EVERY peer's assignment, not just ours (match.gd listens too, for
# spawning) - that's what keeps the roster live while this screen is up.
# Only actually transitions the scene when the confirmed assignment is our
# own AND we're still sitting on the team-select screen waiting for it (the
# host never sees this screen at all - see _on_host_started for that path).
func _on_player_registered(peer_id: int, _team: String) -> void:
	_build_team_roster()
	if team_select_group.visible and peer_id == NetworkManager.multiplayer.get_unique_id():
		_enter_arena()


func _on_team_request_rejected(reason: String) -> void:
	set_ui_feedback(reason, "NOK")
	team_select_feedback.text = reason


# Rebuilt from scratch on every roster change rather than patched in place -
# same reasoning as _build_weapon_checklist: the whole list is cheap to
# regenerate and this is only ever a handful of rows (4 teams), so there's no
# real cost to not tracking a diff.
# Vehicle pickers. Two of them, each an OptionButton bound to NetworkManager.local_craft_id: one on the
# create-game screen (in the Match rules card) and one above the team cards, so joiners
# can choose too. Each lists only the crafts its game allows, and hides itself when there is nothing to choose.
func _setup_vehicle_pickers() -> void:
	for picker: OptionButton in [_host_picker, _join_picker]:
		picker.item_selected.connect(func(index: int): NetworkManager.local_craft_id = StringName(picker.get_item_metadata(index)))
	_fill_vehicle_picker(_join_picker, join_vehicle_row, NetworkManager.allowed_crafts())


# Lists `defs`, keeps the player's current craft if it is among them (else the first), and hides the picker and its
# row (the caption beside it) when there is only one craft to be.
func _fill_vehicle_picker(picker: OptionButton, caption: Control, defs: Array) -> void:
	picker.clear()
	var selected := 0
	for i in defs.size():
		var def: CraftDef = defs[i]
		picker.add_item(def.display_name)
		picker.set_item_metadata(i, String(def.id))
		picker.set_item_tooltip(i, def.description)
		if def.id == NetworkManager.local_craft_id:
			selected = i
	if defs.is_empty():
		return
	picker.select(selected)
	NetworkManager.local_craft_id = StringName(picker.get_item_metadata(selected))
	picker.visible = defs.size() > 1
	caption.visible = defs.size() > 1


# Joiners: the host's ruleset (with its craft list) has arrived.
func _refresh_join_picker() -> void:
	_fill_vehicle_picker(_join_picker, join_vehicle_row, NetworkManager.allowed_crafts())


# --- Which crafts this game allows (create-game screen) ---------------------------------------------------------
# One tick per craft. The host chooses freely; the list is fixed once the game is created. At least one stays
# ticked: unticking the last one puts the tick straight back.

func _build_craft_checklist() -> void:
	for def in CraftCatalog.DEFS:
		var check := _make_chip(def.display_name, def.description)
		check.button_pressed = true
		check.set_meta("craft_id", String(def.id))
		check.toggled.connect(func(on: bool) -> void:
			if not on and _checked_craft_ids().is_empty():
				check.set_pressed_no_signal(true)
			_refresh_host_picker())
		_craft_checklist.add_child(check)
	# Nothing to choose between with a single craft in the game.
	_craft_section.visible = CraftCatalog.DEFS.size() > 1


func _checked_craft_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for child in _craft_checklist.get_children():
		if child is CheckBox and child.button_pressed:
			ids.append(StringName(child.get_meta("craft_id")))
	return ids


# The host's own picker offers only the crafts ticked for the game.
func _refresh_host_picker() -> void:
	var defs: Array = []
	for def in CraftCatalog.DEFS:
		if _checked_craft_ids().has(def.id):
			defs.append(def)
	_fill_vehicle_picker(_host_picker, host_vehicle_row, defs)


func _build_team_roster() -> void:
	for child in team_roster.get_children():
		child.queue_free()
	var my_id := NetworkManager.multiplayer.get_unique_id()
	for team in NetworkManager.TEAM_NAMES:
		var members: Array[String] = []
		for peer_id in NetworkManager.peer_teams.keys():
			if NetworkManager.peer_teams[peer_id] == team:
				members.append("You" if peer_id == my_id else "Peer %d" % peer_id)
		var color: Color = TEAM_COLORS.get(team, ACCENT)
		var full := members.size() >= NetworkManager.MAX_PLAYERS_PER_TEAM
		# One card a team, in the team's colour: its name, how full it is, who is on it, and the way in.
		var card: PanelContainer = HUD_CARD.new()
		card.accent = color
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", 8)
		card.add_child(body)
		var name_label := Label.new()
		name_label.theme_type_variation = &"TitleLabel"
		name_label.add_theme_font_size_override("font_size", 24)
		name_label.add_theme_color_override("font_color", color)
		name_label.text = team.trim_prefix("team_").to_upper()
		body.add_child(name_label)
		var count := Label.new()
		count.theme_type_variation = &"CapsLabel"
		count.text = "%d / %d PILOTS" % [members.size(), NetworkManager.MAX_PLAYERS_PER_TEAM]
		body.add_child(count)
		var fill := ProgressBar.new()
		fill.show_percentage = false
		fill.custom_minimum_size = Vector2(0, 5)
		fill.max_value = NetworkManager.MAX_PLAYERS_PER_TEAM
		fill.value = members.size()
		var fill_style := StyleBoxFlat.new()
		fill_style.bg_color = color
		fill.add_theme_stylebox_override("fill", fill_style)
		body.add_child(fill)
		var list := Label.new()
		list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		list.text = "\n".join(members) if not members.is_empty() else "Nobody yet"
		if members.is_empty():
			list.theme_type_variation = &"DimLabel"
		body.add_child(list)
		var join_button := Button.new()
		join_button.text = "FULL" if full else "JOIN"
		join_button.focus_mode = Control.FOCUS_NONE
		join_button.custom_minimum_size = Vector2(0, 46)
		join_button.disabled = full
		join_button.pressed.connect(_on_team_join_pressed.bind(team))
		body.add_child(join_button)
		team_roster.add_child(card)


func _on_team_join_pressed(team: String) -> void:
	team_select_feedback.text = ""
	set_ui_feedback("Requesting %s..." % team.trim_prefix("team_").capitalize(), "INFO")
	NetworkManager.request_team(team)


func _on_games_listed(games: Array):
	# The list is rebuilt on every poll, so the player's pick is put back if that game is still there.
	var picked := _game_key(selected_game_row)
	game_list.clear()
	selected_game_row = null
	no_games.visible = games.is_empty()
	game_count.text = "" if games.is_empty() else ("1 game" if games.size() == 1 else "%d games" % games.size())
	if games.is_empty():
		set_ui_feedback("No open games found.", "COK")
		_show_game_details(null)
		return
	game_list.create_item() # the hidden root
	for game in games:
		var row = game_list.create_item()
		row.set_text(0, game.get("hst_game_name", ""))
		# hst_user is just the numeric account id (see lobbyAPI.php) - the
		# actual display name is the joined hst_username field.
		row.set_text(1, str(game.get("hst_username", "")))
		# int() regardless of whether the API handed back "3" or "3.0" -
		# player counts should never read as a decimal either way.
		row.set_text(2, "%d/%d" % [int(game.get("hst_current_players", 0)), int(game.get("hst_max_players", 0))])
		# hst_manifest is an opaque JSON blob (see NetworkManager._build_manifest) -
		# add more fields to it later without ever touching the API/DB again,
		# just what's read out of it here.
		var parsed: Variant = JSON.parse_string(game.get("hst_manifest", "")) if game.get("hst_manifest", "") else {}
		var manifest: Dictionary = parsed if parsed is Dictionary else {}
		row.set_meta("manifest", manifest)
		row.set_text(3, "On" if manifest.get("day_night", true) else "Off")
		var weapons: Array = manifest.get("weapons", [])
		if not weapons.is_empty():
			row.set_tooltip_text(0, "Weapons: %s" % ", ".join(weapons))
		row.set_meta("hst_ip_address", game.get("hst_ip_address", ""))
		row.set_meta("hst_port", game.get("hst_port", 0))
		row.set_meta("hst_map_file_id", game.get("hst_map_file_id", 0))
		if picked != "" and _game_key(row) == picked:
			row.select(0)
			selected_game_row = row
	_show_game_details(selected_game_row)


# Which game a row is, for finding it again after the list is rebuilt.
func _game_key(row: Variant) -> String:
	if row == null or not is_instance_valid(row):
		return ""
	return "%s:%s" % [row.get_meta("hst_ip_address", ""), row.get_meta("hst_port", 0)]




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
				# A refused session comes back as a bare message string, not {status, data}
				# - e.g. this account logged in again elsewhere, which replaces its key.
				if response_data is Dictionary and response_data.get("status", "") == "success":
					populate_levels_tree(response_data)
				else:
					set_ui_feedback("Your session expired (logged in somewhere else?) - log in again to load maps.", "NOK")
		else:
			set_ui_feedback("A server error occured", "NOK")
			resetForm()
	else:
			set_ui_feedback("Server returned error code: %d" % response_code, "NOK")
			resetForm()
	is_http_busy = false




# Origin and genre filters above the map list, put in the row the scene keeps for them.
func _build_level_filters() -> void:
	var bar: HBoxContainer = %LevelFilterBar
	_origin_filter = OptionButton.new()
	_origin_filter.add_item("All origins")
	for origin in ORIGIN_NAMES:
		_origin_filter.add_item(origin)
	_genre_filter = OptionButton.new()
	_genre_filter.add_item("All genres")
	for filter in [_origin_filter, _genre_filter]:
		filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		filter.item_selected.connect(func(_i): _fill_levels_tree())
		bar.add_child(filter)
	# The list is fetched at login; levels approved since then show up on a refresh.
	var refresh := Button.new()
	refresh.text = "REFRESH"
	refresh.theme_type_variation = &"GhostButton"
	refresh.focus_mode = Control.FOCUS_NONE
	refresh.pressed.connect(func(): getLevels())
	bar.add_child(refresh)


func populate_levels_tree(response_data):
	_level_rows = response_data.data
	# Genres come from what the server actually lists, keeping the current pick if it is still there.
	var picked := _genre_filter.get_item_text(_genre_filter.selected) if _genre_filter.selected > 0 else ""
	var genres: Array[String] = []
	for map_item in _level_rows:
		var genre := str(map_item.tan_genre)
		if not genre.is_empty() and not genres.has(genre):
			genres.append(genre)
	genres.sort()
	_genre_filter.clear()
	_genre_filter.add_item("All genres")
	for genre in genres:
		_genre_filter.add_item(genre)
		if genre == picked:
			_genre_filter.select(_genre_filter.item_count - 1)
	_fill_levels_tree()


func _fill_levels_tree() -> void:
	world_list.clear()
	var origin := _origin_filter.get_item_text(_origin_filter.selected) if _origin_filter.selected > 0 else ""
	var genre_pick := _genre_filter.get_item_text(_genre_filter.selected) if _genre_filter.selected > 0 else ""
	var rootrow = world_list.create_item()
	rootrow.set_text(0, "")
	var first_row: TreeItem = null
	var selected_any := false
	for map_item in _level_rows:
		if map_item.tan_prepared == 1:
			if not origin.is_empty() and str(map_item.get("tan_origin", "Tanarus Original")) != origin:
				continue
			if not genre_pick.is_empty() and str(map_item.tan_genre) != genre_pick:
				continue
			var row = world_list.create_item()
			if first_row == null:
				first_row = row
			row.set_text(0, map_item.tan_title)
			row.set_text(1, map_item.tan_author)
			row.set_text(2, map_item.tan_genre)
			row.set_meta("description", map_item.tan_description)
			row.set_meta("fil_id", map_item.file_id)
			row.set_meta("tan_id", map_item.tan_id)
			row.set_meta("thm_id", map_item.thm_id)
			row.set_meta("origin", str(map_item.get("tan_origin", "Tanarus Original")))
			if int(map_item.file_id) == _last_selected_map_file_id:
				row.select(0)
				# Deferred - the Tree hasn't laid out its new rows yet this frame.
				world_list.scroll_to_item.call_deferred(row, true)
				_on_level_selected()
				selected_any = true
	# Nothing remembered from a previous visit: start on the first map.
	if not selected_any and first_row != null:
		first_row.select(0)
		_on_level_selected()
	elif first_row == null:
		# The filters left nothing: Host must not carry on with the map picked before.
		selected_map_title = ""
		selected_map_file_id = -1
		_refresh_host_summary()




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





var _feedback_tween: Tween


# The line in the bottom bar. A new message types itself out and the light beside it blinks in the message's
# colour; the same message again (a poll repeating itself) is left alone.
func set_ui_feedback(err_msg: String, err_lvl: String) -> void:
	var clr: Color = FEEDBACK_COLORS.get(err_lvl, Color.WHITE)
	var repeated := err_msg == ui_feedback.text and status_led.color == clr
	ui_feedback.add_theme_color_override("font_color", clr)
	ui_feedback.text = err_msg
	status_led.color = clr
	if repeated:
		return
	if _feedback_tween:
		_feedback_tween.kill()
	ui_feedback.visible_ratio = 0.0
	status_led.modulate.a = 0.1
	_feedback_tween = create_tween().set_parallel()
	_feedback_tween.tween_property(ui_feedback, "visible_ratio", 1.0, clampf(err_msg.length() * 0.012, 0.15, 0.6))
	_feedback_tween.tween_property(status_led, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_BOUNCE)

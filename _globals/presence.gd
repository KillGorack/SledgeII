extends Node

# Discord Rich Presence ("Playing Sledge" with a couple of status lines). The wire protocol is the addon's job
# (addons/discord_rich_presence, MIT); this decides what to say. It reads the game's state once a second instead of
# being told about every change, so no menu or match code has to know Discord exists, and it only talks to Discord
# when the wording changes (Discord throttles presence updates, hence MIN_SEND_SECONDS).
#
# Discord not running, a dedicated/headless run, or an unsupported platform is all fine: the addon just does nothing.
# `enabled` is the switch for the settings screen; turning it off clears the presence.

const DISCORD := preload("res://addons/discord_rich_presence/discord_rich_presence.gd")
# The "Sledge" application in the Discord Developer Portal (its Rich Presence art assets are where "icon" lives).
const APP_ID := "1399885336154210429"
const LARGE_IMAGE := "icon"
const LARGE_TEXT := "Sledge"
const CHECK_SECONDS := 1.0
const MIN_SEND_SECONDS := 15.0

enum Mode { MENU, MATCH, CREATIVE }

# Whether presence is shown at all. Wire a settings toggle to set_enabled().
var enabled: bool = true

var _discord: Node
var _check_left: float = 0.0
var _mode: int = -1
# Unix time the current mode started: Discord shows it as "elapsed".
var _mode_start: int = 0
var _sent: Dictionary = {}
var _pending: Dictionary = {}
var _last_send_msec: int = -100000
var _cleared: bool = false


func _ready() -> void:
	_discord = DISCORD.new()
	_discord.app_id = APP_ID
	add_child(_discord)


func set_enabled(value: bool) -> void:
	enabled = value
	_check_left = 0.0


func _process(delta: float) -> void:
	_check_left -= delta
	if _check_left > 0.0:
		_flush_pending()
		return
	_check_left = CHECK_SECONDS
	if not enabled:
		if not _cleared:
			_discord.clear_activity()
			_cleared = true
			_sent = {}
			_pending = {}
		return
	_cleared = false
	var mode := _current_mode()
	if mode != _mode:
		_mode = mode
		_mode_start = int(Time.get_unix_time_from_system())
	var activity := _activity_for(mode)
	if activity != _sent:
		_pending = activity
	_flush_pending()


func _current_mode() -> int:
	if get_tree().get_first_node_in_group("match") != null:
		return Mode.CREATIVE if NetworkManager.creative_building or NetworkManager.creative_editing else Mode.MATCH
	return Mode.MENU


func _activity_for(mode: int) -> Dictionary:
	var details := "In the menus"
	var state := "Getting ready"
	match mode:
		Mode.MATCH:
			var map_title: String = NetworkManager.current_map_title
			details = "Playing %s" % map_title if map_title != "" else "In a match"
			var players := NetworkManager.peer_names.size()
			var role := "Hosting" if NetworkManager.is_host else "Playing"
			state = "%s - %d %s" % [role, players, "player" if players == 1 else "players"] if players > 0 else role
		Mode.CREATIVE:
			details = "Building a level"
			state = "In the level editor"
	return {
		"details": details,
		"state": state,
		"timestamps": {"start": _mode_start},
		"assets": {"large_image": LARGE_IMAGE, "large_text": LARGE_TEXT},
	}


# Sends the latest wanted activity, no more often than MIN_SEND_SECONDS apart (the wording catches up on the next
# send; only the newest one is ever sent).
func _flush_pending() -> void:
	if _pending.is_empty():
		return
	if Time.get_ticks_msec() - _last_send_msec < int(MIN_SEND_SECONDS * 1000.0) and not _sent.is_empty():
		return
	_discord.set_activity(_pending)
	_sent = _pending
	_pending = {}
	_last_send_msec = Time.get_ticks_msec()

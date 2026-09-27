extends Control

# Hud_InGame/Chat. "/" (start_chat) opens it, Enter sends+closes, Esc
# (ui_cancel, a Godot default, not overridden in this project) cancels+closes.
# is_open is the single thing movement.gd/weapon_node.gd/radar_controller.gd
# check to stop reading gameplay input while typing - a focused LineEdit only
# blocks _unhandled_input, it does NOT stop Input.get_action_strength()/
# is_action_pressed() polling reads, which is how all three of those read
# input every physics frame. One shared flag beats every gameplay script
# re-deriving "is some Control focused" itself.
#
# Sends via match.gd's _send_chat_message/_broadcast_chat_message RPCs -
# this script never talks to other peers directly, same reasoning as
# hud_controller.gd/radar_controller.gd going through the "match" group
# node rather than each other.
@onready var line_edit: LineEdit = $Margin/VBox/LineEdit
@onready var text_log: TextEdit = $Margin/VBox/TextEdit
@onready var _match_node: Node = get_tree().get_first_node_in_group("match")

var is_open: bool = false


func _ready() -> void:
	# Same trick as hud_controller.gd/radar_controller.gd - only the locally-
	# owned craft's chat should be interactive at all. Not hiding self here -
	# Hud_InGame (hud_controller.gd) already hides the whole HUD, this Chat
	# node included, for every non-owning peer's copy.
	if not get_parent().get_parent().is_multiplayer_authority():
		set_process_unhandled_input(false)
		return
	# The log (text_log) stays visible at all times - only the input line
	# toggles with is_open, so recent chat is readable without having to be
	# actively typing.
	line_edit.visible = false
	line_edit.text_submitted.connect(_on_submitted)


func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		if event.is_action_pressed("start_chat"):
			_open()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _open() -> void:
	is_open = true
	line_edit.visible = true
	line_edit.grab_focus()


func _close() -> void:
	is_open = false
	line_edit.visible = false
	line_edit.text = ""
	line_edit.release_focus()


func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed != "" and _match_node:
		_match_node._send_chat_message.rpc_id(1, UserData.username, trimmed)
	_close()


# Called by match.gd::_broadcast_chat_message - public since that's a
# different script driving this one, same shape as radar_controller.gd's
# _color_for reading recon.captured_color from outside its own class.
func receive_message(sender: String, text: String) -> void:
	text_log.text += "%s: %s\n" % [sender, text]

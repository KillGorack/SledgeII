extends Node

# The one place that knows which keys do what. Every key the game answers to is an InputMap action; this
# autoload lists the ones a player may rebind (REGISTRY), puts the player's saved choices into the InputMap at
# startup, and saves them again when they change. The Settings > Inputs screen edits the same InputMap the match
# and the builder read, so a rebind made in the menu is live the moment you play - nothing is copied anywhere.
#
# Defaults: the match actions keep their defaults in project.godot's Input Map (snapshotted here before any
# override is applied); actions that project.godot doesn't have (the builder's, F1, F4) are created below.
# A binding is one key plus any of Ctrl / Alt / Shift / Meta. A modifier key on its own is a valid key
# (fine aim is Shift, reverso is Shift).

signal bindings_changed

const SAVE_PATH := "user://keybinds.cfg"

# Two actions in the same context can't share a binding; the match and the builder can.
const CONTEXT_MATCH := "match"
const CONTEXT_BUILDER := "builder"

# Each group is [title, context, [[action, label], ...]].
const REGISTRY := [
	["Driving", CONTEXT_MATCH, [
		["ui_up", "Drive forward"], ["ui_down", "Drive back"],
		["ui_left", "Turn left"], ["ui_right", "Turn right"],
		["rockets", "Rockets (thrust)"]]],
	["Aiming and firing", CONTEXT_MATCH, [
		["camera_up", "Tilt barrel up"], ["camera_down", "Tilt barrel down"],
		["camera_left", "Turn turret left"], ["camera_right", "Turn turret right"],
		["ui_shift", "Fine aim (hold)"], ["ui_recenter", "Recentre the turret"],
		["fire_weapon", "Fire"], ["reverso", "Fire reversed (hold)"],
		["weapon_change", "Next weapon"]]],
	["Specials", CONTEXT_MATCH, [
		["change_specials", "Next special"],
		["lay_mine", "Use special (mine / call base gun)"],
		["blow_mines", "Blow mines / send base guns home"]]],
	["Match", CONTEXT_MATCH, [
		["capture_recon", "Capture the recon station"],
		["zoom_radar", "Radar zoom"],
		["cycle_teamies", "Highlight next teammate"],
		["cycle_enemies", "Highlight next enemy"],
		["start_chat", "Chat"],
		["player_list", "Player list"],
		["show_help", "Show / hide help"],
		["exit_main", "Leave to the main menu"]]],
	["Anywhere", CONTEXT_MATCH, [
		["screen_capture", "Screenshot"]]],
	["Builder: anywhere", CONTEXT_BUILDER, [
		["build_toggle", "Switch between building and testing"],
		["build_save", "Save"],
		["build_help", "Show / hide the builder help"]]],
	["Builder: building", CONTEXT_BUILDER, [
		["build_tool_next", "Next tool"], ["build_tool_prev", "Previous tool"],
		["build_use", "Use the tool"], ["build_remove", "Remove what you aim at"],
		["build_undo", "Undo"],
		["build_rotate_x", "Turn 90 degrees about X"],
		["build_rotate_y", "Turn 90 degrees about Y"],
		["build_rotate_z", "Turn 90 degrees about Z"],
		["build_narrower", "Surface narrower"], ["build_wider", "Surface wider"],
		["build_shorter", "Surface shorter"], ["build_taller", "Surface taller"]]],
]

# Defaults for the actions project.godot doesn't define: [physical keycode, modifier flags (see _flags)].
const CODE_DEFAULTS := {
	"show_help": [KEY_F1, 0], "player_list": [KEY_F4, 0],
	"build_toggle": [KEY_B, 0], "build_save": [KEY_F5, 0], "build_help": [KEY_F1, 0],
	"build_tool_next": [KEY_TAB, 0], "build_tool_prev": [KEY_TAB, 1],
	"build_use": [KEY_SPACE, 0], "build_remove": [KEY_F, 0], "build_undo": [KEY_Z, 2],
	"build_rotate_x": [KEY_I, 0], "build_rotate_y": [KEY_J, 0], "build_rotate_z": [KEY_K, 0],
	"build_narrower": [KEY_BRACKETLEFT, 0], "build_wider": [KEY_BRACKETRIGHT, 0],
	"build_shorter": [KEY_MINUS, 0], "build_taller": [KEY_EQUAL, 0],
}

const MODIFIER_KEYS := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

# action -> its default events, taken before the player's overrides go in.
var _defaults: Dictionary = {}


func _ready() -> void:
	for action in CODE_DEFAULTS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			InputMap.action_add_event(action, _make_event(CODE_DEFAULTS[action][0], CODE_DEFAULTS[action][1]))
	for action in all_actions():
		_defaults[action] = InputMap.action_get_events(action).duplicate()
	_load()


func all_actions() -> Array[String]:
	var out: Array[String] = []
	for group in REGISTRY:
		for row in group[2]:
			out.append(row[0])
	return out


func context_of(action: String) -> String:
	for group in REGISTRY:
		for row in group[2]:
			if row[0] == action:
				return group[1]
	return ""


# --- reading ---------------------------------------------------------------

# "Ctrl+Shift+Z", "Space", "Shift" (a modifier on its own), or "Unbound".
func key_text(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "Unbound"
	return event_text(events[0])


# The text for several actions together: "Up / Down".
func keys_text(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action in actions:
		parts.append(key_text(action))
	return " / ".join(parts)


func event_text(event: InputEvent) -> String:
	if not event is InputEventKey:
		return event.as_text()
	var key := event as InputEventKey
	var code: Key = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	var parts: PackedStringArray = []
	if key.ctrl_pressed and code != KEY_CTRL:
		parts.append("Ctrl")
	if key.alt_pressed and code != KEY_ALT:
		parts.append("Alt")
	if key.shift_pressed and code != KEY_SHIFT:
		parts.append("Shift")
	if key.meta_pressed and code != KEY_META:
		parts.append("Meta")
	parts.append(OS.get_keycode_string(code))
	return "+".join(parts)


func is_default(action: String) -> bool:
	return _same_events(InputMap.action_get_events(action), _defaults.get(action, []))


# The other actions in this action's context that already use the same key and modifiers.
func conflicts(action: String) -> Array[String]:
	var out: Array[String] = []
	var mine := InputMap.action_get_events(action)
	if mine.is_empty():
		return out
	var context := context_of(action)
	for other in all_actions():
		if other == action or context_of(other) != context:
			continue
		for event in InputMap.action_get_events(other):
			if _same_binding(event, mine[0]):
				out.append(other)
				break
	return out


# --- changing --------------------------------------------------------------

func rebind(action: String, event: InputEventKey) -> void:
	var key := _clean(event)
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, key)
	_changed()


func unbind(action: String) -> void:
	InputMap.action_erase_events(action)
	_changed()


func reset(action: String) -> void:
	_restore(action)
	_changed()


func reset_all() -> void:
	for action in all_actions():
		_restore(action)
	_changed()


# A key event with only what identifies a binding (the physical key and the modifiers), not the press itself.
func _clean(event: InputEventKey) -> InputEventKey:
	var code: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
	var key := InputEventKey.new()
	key.physical_keycode = code
	key.shift_pressed = event.shift_pressed and code != KEY_SHIFT
	key.ctrl_pressed = event.ctrl_pressed and code != KEY_CTRL
	key.alt_pressed = event.alt_pressed and code != KEY_ALT
	key.meta_pressed = event.meta_pressed and code != KEY_META
	return key


func _make_event(code: int, flags: int) -> InputEventKey:
	var key := InputEventKey.new()
	key.physical_keycode = code as Key
	key.shift_pressed = flags & 1 != 0
	key.ctrl_pressed = flags & 2 != 0
	key.alt_pressed = flags & 4 != 0
	key.meta_pressed = flags & 8 != 0
	return key


func _flags(key: InputEventKey) -> int:
	return (1 if key.shift_pressed else 0) | (2 if key.ctrl_pressed else 0) | (4 if key.alt_pressed else 0) | (8 if key.meta_pressed else 0)


func _restore(action: String) -> void:
	InputMap.action_erase_events(action)
	for event in _defaults.get(action, []):
		InputMap.action_add_event(action, event.duplicate())


func _same_binding(a: InputEvent, b: InputEvent) -> bool:
	if not (a is InputEventKey and b is InputEventKey):
		return false
	var ka := a as InputEventKey
	var kb := b as InputEventKey
	var ca: Key = ka.physical_keycode if ka.physical_keycode != KEY_NONE else ka.keycode
	var cb: Key = kb.physical_keycode if kb.physical_keycode != KEY_NONE else kb.keycode
	return ca == cb and _flags(ka) == _flags(kb)


func _same_events(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not _same_binding(a[i], b[i]):
			return false
	return true


# --- saving ----------------------------------------------------------------

# Only the actions that differ from their defaults are written, so a new default shows up for everyone who
# never touched that action. An unbound action is saved as an empty list.
func _changed() -> void:
	var cfg := ConfigFile.new()
	for action in all_actions():
		if is_default(action):
			continue
		var rows: Array = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				var key := event as InputEventKey
				rows.append([int(key.physical_keycode), _flags(key)])
		cfg.set_value("keys", action, rows)
	if cfg.save(SAVE_PATH) != OK:
		push_warning("Couldn't save key bindings")
	bindings_changed.emit()


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK or not cfg.has_section("keys"):
		return
	for action in cfg.get_section_keys("keys"):
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		for row in cfg.get_value("keys", action, []):
			if row is Array and row.size() == 2:
				InputMap.action_add_event(action, _make_event(int(row[0]), int(row[1])))

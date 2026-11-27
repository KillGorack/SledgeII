extends Node

# The player's sound choices (Settings > Sound): overall volume, and whether to go quiet when the window loses
# focus. Applied at startup and on every change; saved in the [audio] section of user://settings.cfg, next to
# the menu music slider's own value. Everything the game plays is on the Master bus, so the volume covers all of it.

signal changed

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULTS := {"master": 1.0, "mute_in_background": false}

var values: Dictionary = DEFAULTS.duplicate()
var _unfocused := false


func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # a missing file is fine: defaults
	for key in DEFAULTS:
		values[key] = cfg.get_value("audio", key, DEFAULTS[key])
	apply()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_unfocused = true
		apply()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_unfocused = false
		apply()


func set_value(key: String, value) -> void:
	values[key] = value
	apply()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep the other saved settings (menu music)
	for k in values:
		cfg.set_value("audio", k, values[k])
	cfg.save(SETTINGS_PATH)
	changed.emit()


func reset_all() -> void:
	values = DEFAULTS.duplicate()
	apply()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	for key in DEFAULTS:
		if cfg.has_section_key("audio", key):
			cfg.erase_section_key("audio", key)
	cfg.save(SETTINGS_PATH)
	changed.emit()


func apply() -> void:
	var volume := clampf(float(values.master), 0.0, 1.0)
	var quiet: bool = volume <= 0.001 or (bool(values.mute_in_background) and _unfocused)
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(bus, quiet)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.001)))

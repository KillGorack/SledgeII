extends Node

# The player's video choices (Settings > Video). Applied at startup and again whenever one changes, and saved in
# the [video] section of user://settings.cfg (the menu music volume lives in the same file). Defaults match what
# project.godot already asks for, so a player who never opens the screen sees no change.

signal changed

const SETTINGS_PATH := "user://settings.cfg"

const WINDOW_MODES := [
	["Windowed", DisplayServer.WINDOW_MODE_WINDOWED],
	["Fullscreen", DisplayServer.WINDOW_MODE_FULLSCREEN],
	["Exclusive fullscreen", DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN],
]
const VSYNC_MODES := [
	["Off", DisplayServer.VSYNC_DISABLED],
	["On", DisplayServer.VSYNC_ENABLED],
	["Adaptive", DisplayServer.VSYNC_ADAPTIVE],
	["Mailbox", DisplayServer.VSYNC_MAILBOX],
]
const FPS_LIMITS := [["Unlimited", 0], ["30", 30], ["60", 60], ["120", 120], ["144", 144], ["240", 240]]
const MSAA_MODES := [["Off", Viewport.MSAA_DISABLED], ["2x", Viewport.MSAA_2X], ["4x", Viewport.MSAA_4X], ["8x", Viewport.MSAA_8X]]
const SCREEN_AA_MODES := [["Off", Viewport.SCREEN_SPACE_AA_DISABLED], ["FXAA", Viewport.SCREEN_SPACE_AA_FXAA], ["SMAA", Viewport.SCREEN_SPACE_AA_SMAA]]
const SHADOW_SIZES := [["Low", 2048], ["Medium", 4096], ["High", 8192]]
const SHADOW_SOFTNESS := [["Hard", RenderingServer.SHADOW_QUALITY_HARD], ["Soft: low", RenderingServer.SHADOW_QUALITY_SOFT_LOW],
		["Soft: medium", RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM], ["Soft: high", RenderingServer.SHADOW_QUALITY_SOFT_HIGH],
		["Soft: ultra", RenderingServer.SHADOW_QUALITY_SOFT_ULTRA]]

# key -> default. Each is an index into its list above, except render_scale (a fraction).
const DEFAULTS := {
	"window_mode": 1, "vsync": 1, "fps_limit": 0, "msaa": 3, "screen_aa": 2,
	"shadow_size": 2, "shadow_softness": 3, "render_scale": 1.0,
}

var values: Dictionary = DEFAULTS.duplicate()


func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # a missing file is fine: defaults
	for key in DEFAULTS:
		values[key] = cfg.get_value("video", key, DEFAULTS[key])
	apply()


func set_value(key: String, value) -> void:
	values[key] = value
	apply()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep the other saved settings
	for k in values:
		cfg.set_value("video", k, values[k])
	cfg.save(SETTINGS_PATH)
	changed.emit()


func reset_all() -> void:
	values = DEFAULTS.duplicate()
	apply()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	if cfg.has_section("video"):
		cfg.erase_section("video")
		cfg.save(SETTINGS_PATH)
	changed.emit()


func apply() -> void:
	var window := get_window()
	var mode: int = WINDOW_MODES[clampi(int(values.window_mode), 0, WINDOW_MODES.size() - 1)][1]
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
		if mode == DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_size(Vector2i(1600, 900))
			DisplayServer.window_set_position(DisplayServer.screen_get_position() + (DisplayServer.screen_get_size() - Vector2i(1600, 900)) / 2)
	DisplayServer.window_set_vsync_mode(VSYNC_MODES[clampi(int(values.vsync), 0, VSYNC_MODES.size() - 1)][1])
	Engine.max_fps = FPS_LIMITS[clampi(int(values.fps_limit), 0, FPS_LIMITS.size() - 1)][1]
	window.msaa_3d = MSAA_MODES[clampi(int(values.msaa), 0, MSAA_MODES.size() - 1)][1]
	window.screen_space_aa = SCREEN_AA_MODES[clampi(int(values.screen_aa), 0, SCREEN_AA_MODES.size() - 1)][1]
	window.scaling_3d_scale = clampf(float(values.render_scale), 0.5, 1.0)
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_SIZES[clampi(int(values.shadow_size), 0, SHADOW_SIZES.size() - 1)][1], true)
	var softness: int = SHADOW_SOFTNESS[clampi(int(values.shadow_softness), 0, SHADOW_SOFTNESS.size() - 1)][1]
	RenderingServer.directional_soft_shadow_filter_set_quality(softness)
	RenderingServer.positional_soft_shadow_filter_set_quality(softness)

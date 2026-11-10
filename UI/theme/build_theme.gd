extends SceneTree

# Writes res://UI/theme/sledge_theme.tres, the menu's theme, from the palette and shapes below. The theme file
# is generated: change a colour or a size here and run this again rather than editing the .tres by hand.
#
#   godot --headless --path . -s res://UI/theme/build_theme.gd
#
# The look: dark glass panels with two cut corners, thin cyan lines, pink for the one thing to press. Shapes are
# StyleBoxFlat throughout (a corner radius with corner_detail = 1 is a straight cut), so there are no panel
# textures; the small icons (ticks, switches, arrows) are drawn here pixel by pixel and stored in the theme.

const OUT_PATH := "res://UI/theme/sledge_theme.tres"
const OUT_UID := "uid://dmlpyqe111b7r"
const FONT_DIR := "res://UI/fonts/"

const CYAN := Color(0.27, 0.88, 1.0)
const PINK := Color(1.0, 0.24, 0.65)
const VIOLET := Color(0.54, 0.36, 1.0)
const GREEN := Color(0.3, 1.0, 0.69)
const RED := Color(1.0, 0.33, 0.44)
const TEXT := Color(0.85, 0.93, 1.0)
const TEXT_BRIGHT := Color(1.0, 1.0, 1.0)
const TEXT_DIM := Color(0.5, 0.6, 0.72)
const TEXT_OFF := Color(0.32, 0.38, 0.47)
const PANEL := Color(0.03, 0.055, 0.105, 0.84)
const PANEL_SOLID := Color(0.035, 0.06, 0.11, 0.985)
const INSET := Color(0.012, 0.024, 0.05, 0.72)
const FIELD := Color(0.06, 0.11, 0.18, 0.9)
const LINE := Color(0.36, 0.72, 1.0, 0.24)
const LINE_STRONG := Color(0.36, 0.8, 1.0, 0.5)
const CLEAR := Color(0, 0, 0, 0)

var theme := Theme.new()
var body: Font
var body_semi: Font
var body_bold: Font
var display: Font


func _init() -> void:
	_fonts()
	_labels()
	_buttons()
	_toggles()
	_fields()
	_lists()
	_panels()
	_bars()
	_popups()
	var err := ResourceSaver.save(theme, OUT_PATH)
	# Scenes refer to the theme by this id; a fresh save from a script would otherwise drop it.
	if err == OK:
		ResourceSaver.set_uid(OUT_PATH, ResourceUID.text_to_id(OUT_UID))
	print("Theme saved to %s (%s)" % [OUT_PATH, error_string(err)])
	quit(0 if err == OK else 1)


# --- Fonts ------------------------------------------------------------------------------------------------------

func _fonts() -> void:
	body = load(FONT_DIR + "Rajdhani-Medium.ttf")
	body_semi = load(FONT_DIR + "Rajdhani-SemiBold.ttf")
	body_bold = load(FONT_DIR + "Rajdhani-Bold.ttf")
	display = load(FONT_DIR + "Orbitron.ttf")
	theme.default_font = body
	theme.default_font_size = 18


# Orbitron is one file holding every weight; this picks one, and spreads the letters by `spacing` pixels.
func _display(weight: int, spacing: int = 0) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = display
	font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	font.spacing_glyph = spacing
	return font


func _spaced(base: Font, spacing: int) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = base
	font.spacing_glyph = spacing
	return font


# --- Style boxes ------------------------------------------------------------------------------------------------

# cut: the size of the straight cut on each corner, [top-left, top-right, bottom-right, bottom-left].
# border: one width for all sides, or [left, top, right, bottom]. margin: [left, top, right, bottom].
func _box(bg: Color, border_color: Color = CLEAR, border: Variant = 1, cut: Array = [0, 0, 0, 0], margin: Array = [12, 7, 12, 7], glow: Color = CLEAR, glow_size: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.draw_center = bg.a > 0.0
	style.border_color = border_color
	var widths: Array = border if border is Array else [border, border, border, border]
	style.border_width_left = widths[0]
	style.border_width_top = widths[1]
	style.border_width_right = widths[2]
	style.border_width_bottom = widths[3]
	style.corner_detail = 1
	style.corner_radius_top_left = cut[0]
	style.corner_radius_top_right = cut[1]
	style.corner_radius_bottom_right = cut[2]
	style.corner_radius_bottom_left = cut[3]
	style.content_margin_left = margin[0]
	style.content_margin_top = margin[1]
	style.content_margin_right = margin[2]
	style.content_margin_bottom = margin[3]
	if glow_size > 0:
		style.shadow_color = glow
		style.shadow_size = glow_size
	return style


func _empty(margin: Array = [0, 0, 0, 0]) -> StyleBoxEmpty:
	var style := StyleBoxEmpty.new()
	style.content_margin_left = margin[0]
	style.content_margin_top = margin[1]
	style.content_margin_right = margin[2]
	style.content_margin_bottom = margin[3]
	return style


func _styles(type: StringName, styles: Dictionary) -> void:
	for key in styles:
		theme.set_stylebox(key, type, styles[key])


func _colors(type: StringName, colors: Dictionary) -> void:
	for key in colors:
		theme.set_color(key, type, colors[key])


func _constants(type: StringName, constants: Dictionary) -> void:
	for key in constants:
		theme.set_constant(key, type, constants[key])


# --- Icons ------------------------------------------------------------------------------------------------------

# Draws an icon by asking `shade` for the colour at each point, sixteen samples a pixel so edges come out smooth.
func _icon(width: int, height: int, shade: Callable) -> ImageTexture:
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	const SAMPLES := 4
	for y in height:
		for x in width:
			var rgb := Vector3.ZERO
			var alpha := 0.0
			for sy in SAMPLES:
				for sx in SAMPLES:
					var c: Color = shade.call(Vector2(x + (sx + 0.5) / SAMPLES, y + (sy + 0.5) / SAMPLES))
					rgb += Vector3(c.r, c.g, c.b) * c.a
					alpha += c.a
			if alpha > 0.0:
				image.set_pixel(x, y, Color(rgb.x / alpha, rgb.y / alpha, rgb.z / alpha, alpha / (SAMPLES * SAMPLES)))
	return ImageTexture.create_from_image(image)


static func _in_rect(p: Vector2, x0: float, y0: float, x1: float, y1: float) -> bool:
	return p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1


# A square frame with its top-right corner cut, optionally with a solid block inside.
func _tick_icon(size: int, frame: Color, fill: Color) -> ImageTexture:
	var s := float(size)
	return _icon(size, size, func(p: Vector2) -> Color:
		var cut := s * 0.3
		if not _in_rect(p, 1, 1, s - 1, s - 1) or (p.x - p.y) > (s - 2.0 - cut):
			return CLEAR
		var edge := p.x < 2.5 or p.y < 2.5 or p.x > s - 2.5 or p.y > s - 2.5 or (p.x - p.y) > (s - 3.6 - cut)
		if edge:
			return frame
		if fill.a > 0.0 and _in_rect(p, 5, 5, s - 5, s - 5):
			return fill
		return Color(frame, 0.08))


# The on/off switch: a slim slot with a block that sits left (off) or right (on).
func _switch_icon(on: bool, enabled: bool) -> ImageTexture:
	var line := (CYAN if on else TEXT_DIM) if enabled else TEXT_OFF
	var knob := (TEXT_BRIGHT if on else TEXT_DIM) if enabled else TEXT_OFF
	return _icon(52, 24, func(p: Vector2) -> Color:
		# The slot, with its top-right and bottom-left corners cut like the panels.
		if not _in_rect(p, 1, 2, 51, 22) or (p.x - p.y) > 43.0 or (p.y - p.x) > 15.0:
			return CLEAR
		var knob_x := 28.0 if on else 5.0
		if _in_rect(p, knob_x, 6, knob_x + 19.0, 18):
			return knob
		if p.x < 2.5 or p.y < 3.5 or p.x > 49.5 or p.y > 20.5 or (p.x - p.y) > 41.5 or (p.y - p.x) > 13.5:
			return Color(line, 0.95 if on else 0.55)
		return Color(line, 0.3 if on else 0.06))


# The small light on a chip: a solid square when on, an outline when off.
func _light_icon(color: Color, on: bool) -> ImageTexture:
	return _icon(12, 12, func(p: Vector2) -> Color:
		if not _in_rect(p, 2, 2, 10, 10):
			return CLEAR
		if on or not _in_rect(p, 3.4, 3.4, 8.6, 8.6):
			return color
		return CLEAR)


func _arrow_icon(color: Color) -> ImageTexture:
	return _icon(14, 14, func(p: Vector2) -> Color:
		var from_centre := absf(p.x - 7.0)
		return color if p.y > 4.5 and p.y < 10.5 and from_centre < (10.5 - p.y) else CLEAR)


func _diamond_icon(size: int, frame: Color, fill: Color) -> ImageTexture:
	var half := size * 0.5
	return _icon(size, size, func(p: Vector2) -> Color:
		var d := absf(p.x - half) + absf(p.y - half)
		if d > half - 1.0:
			return CLEAR
		if d > half - 2.6:
			return frame
		return fill if d < half - 4.2 else CLEAR)


func _block_icon(width: int, height: int, color: Color) -> ImageTexture:
	return _icon(width, height, func(p: Vector2) -> Color:
		return color if _in_rect(p, 1, 1, width - 1, height - 1) and (p.x + (height - p.y)) > 5.0 and ((width - p.x) + p.y) > 5.0 else CLEAR)


func _cross_icon(color: Color) -> ImageTexture:
	return _icon(18, 18, func(p: Vector2) -> Color:
		var q := p - Vector2(9, 9)
		var on_line := absf(absf(q.x) - absf(q.y)) < 1.1 and absf(q.x) < 5.5
		return color if on_line else CLEAR)


# --- Labels -----------------------------------------------------------------------------------------------------

func _labels() -> void:
	_colors(&"Label", {"font_color": TEXT, "font_shadow_color": Color(0, 0, 0, 0.5)})
	_constants(&"Label", {"shadow_offset_x": 0, "shadow_offset_y": 1, "line_spacing": 2})

	# The heading of a card: "SELECT ARENA".
	theme.set_type_variation(&"HeaderLabel", &"Label")
	theme.set_font(&"font", &"HeaderLabel", _display(700, 2))
	theme.set_font_size(&"font_size", &"HeaderLabel", 15)
	theme.set_color(&"font_color", &"HeaderLabel", Color(0.9, 0.97, 1.0))

	# The number in front of it: "01".
	theme.set_type_variation(&"IndexLabel", &"Label")
	theme.set_font(&"font", &"IndexLabel", _display(900, 1))
	theme.set_font_size(&"font_size", &"IndexLabel", 15)
	theme.set_color(&"font_color", &"IndexLabel", PINK)

	# Big names: the selected map, a screen's title.
	theme.set_type_variation(&"TitleLabel", &"Label")
	theme.set_font(&"font", &"TitleLabel", _display(800, 1))
	theme.set_font_size(&"font_size", &"TitleLabel", 28)
	theme.set_color(&"font_color", &"TitleLabel", TEXT_BRIGHT)
	theme.set_color(&"font_shadow_color", &"TitleLabel", Color(0, 0, 0, 0.6))
	theme.set_constant(&"shadow_offset_y", &"TitleLabel", 2)

	# Small spaced capitals above a value: "PILOT", "YOUR TEAM".
	theme.set_type_variation(&"CapsLabel", &"Label")
	theme.set_font(&"font", &"CapsLabel", _spaced(body_bold, 2))
	theme.set_font_size(&"font_size", &"CapsLabel", 13)
	theme.set_color(&"font_color", &"CapsLabel", TEXT_DIM)

	theme.set_type_variation(&"AccentLabel", &"Label")
	theme.set_font(&"font", &"AccentLabel", body_semi)
	theme.set_color(&"font_color", &"AccentLabel", CYAN)

	theme.set_type_variation(&"DimLabel", &"Label")
	theme.set_color(&"font_color", &"DimLabel", TEXT_DIM)

	_colors(&"RichTextLabel", {"default_color": TEXT, "font_selected_color": TEXT_BRIGHT, "selection_color": Color(CYAN, 0.3)})
	theme.set_font(&"normal_font", &"RichTextLabel", body)
	theme.set_font(&"bold_font", &"RichTextLabel", body_bold)
	var slanted := FontVariation.new()
	slanted.base_font = body
	slanted.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	theme.set_font(&"italics_font", &"RichTextLabel", slanted)
	theme.set_constant(&"line_separation", &"RichTextLabel", 3)

	_styles(&"HSeparator", {"separator": _line_style(false)})
	_constants(&"HSeparator", {"separation": 10})
	_styles(&"VSeparator", {"separator": _line_style(true)})
	_constants(&"VSeparator", {"separation": 10})


func _line_style(vertical: bool) -> StyleBoxLine:
	var line := StyleBoxLine.new()
	line.color = LINE
	line.thickness = 1
	line.vertical = vertical
	return line


# --- Buttons ----------------------------------------------------------------------------------------------------

func _buttons() -> void:
	var cut := [8, 0, 8, 0]
	var margin := [16, 8, 16, 8]
	var button_styles := {
		"normal": _box(FIELD, LINE, 1, cut, margin),
		"hover": _box(Color(0.09, 0.2, 0.3, 0.95), Color(CYAN, 0.85), 1, cut, margin, Color(CYAN, 0.22), 8),
		"pressed": _box(Color(CYAN, 0.28), CYAN, 1, cut, margin),
		"disabled": _box(Color(0.05, 0.08, 0.12, 0.6), Color(LINE, 0.1), 1, cut, margin),
		"focus": _box(CLEAR, Color(CYAN, 0.55), 1, cut, margin),
	}
	var button_colors := {
		"font_color": TEXT,
		"font_hover_color": TEXT_BRIGHT,
		"font_pressed_color": TEXT_BRIGHT,
		"font_hover_pressed_color": TEXT_BRIGHT,
		"font_focus_color": TEXT_BRIGHT,
		"font_disabled_color": TEXT_OFF,
		"icon_normal_color": TEXT,
		"icon_hover_color": TEXT_BRIGHT,
	}
	for type in [&"Button", &"MenuButton", &"OptionButton"]:
		_styles(type, button_styles)
		_colors(type, button_colors)
		theme.set_font(&"font", type, body_semi)
	# Plain buttons are labelled in capitals (JOIN, REFRESH), so they get the heavier, spaced face.
	theme.set_font(&"font", &"Button", _spaced(body_bold, 1))
	theme.set_font_size(&"font_size", &"Button", 16)
	_constants(&"Button", {"h_separation": 8})
	theme.set_icon(&"arrow", &"OptionButton", _arrow_icon(CYAN))
	_constants(&"OptionButton", {"arrow_margin": 10, "h_separation": 8, "modulate_arrow": 0})

	# The one action a screen is for: Host, Join, Log in.
	_solid_button(&"PrimaryButton", Color(0.86, 0.13, 0.53), PINK)
	theme.set_font(&"font", &"PrimaryButton", _display(800, 2))
	theme.set_font_size(&"font_size", &"PrimaryButton", 17)
	# The same pink for the main button in a row of ordinary ones (Edit), in the ordinary button face.
	_solid_button(&"AccentButton", Color(0.86, 0.13, 0.53), PINK)
	# Sends something online (Publish) and can't be undone (Delete).
	_solid_button(&"GoButton", Color(0.07, 0.5, 0.36), GREEN)
	_solid_button(&"DangerButton", Color(0.6, 0.13, 0.22), RED)

	# Quiet buttons for the top bar: just a line until the mouse is over them.
	theme.set_type_variation(&"GhostButton", &"Button")
	var ghost_margin := [18, 8, 18, 8]
	_styles(&"GhostButton", {
		"normal": _box(Color(1, 1, 1, 0.02), Color(LINE, 0.16), 1, cut, ghost_margin),
		"hover": _box(Color(CYAN, 0.1), Color(CYAN, 0.7), 1, cut, ghost_margin),
		"pressed": _box(Color(CYAN, 0.26), CYAN, 1, cut, ghost_margin),
		"focus": _empty(ghost_margin),
	})
	theme.set_font(&"font", &"GhostButton", _spaced(body_bold, 2))
	theme.set_font_size(&"font_size", &"GhostButton", 15)
	theme.set_color(&"font_color", &"GhostButton", TEXT_DIM)

	theme.set_type_variation(&"GhostDangerButton", &"GhostButton")
	_styles(&"GhostDangerButton", {
		"hover": _box(Color(RED, 0.14), Color(RED, 0.8), 1, cut, ghost_margin),
		"pressed": _box(Color(RED, 0.32), RED, 1, cut, ghost_margin),
	})

	# The three screens along the top. The line under the chosen one is drawn by index.gd, so it can slide.
	theme.set_type_variation(&"NavButton", &"Button")
	var nav_margin := [26, 0, 26, 0]
	_styles(&"NavButton", {
		"normal": _empty(nav_margin),
		"hover": _box(Color(CYAN, 0.05), CLEAR, 0, [0, 0, 0, 0], nav_margin),
		"pressed": _box(Color(CYAN, 0.09), CLEAR, 0, [0, 0, 0, 0], nav_margin),
		"hover_pressed": _box(Color(CYAN, 0.12), CLEAR, 0, [0, 0, 0, 0], nav_margin),
		"disabled": _empty(nav_margin),
		"focus": _empty(nav_margin),
	})
	theme.set_font(&"font", &"NavButton", _display(700, 2))
	theme.set_font_size(&"font_size", &"NavButton", 15)
	_colors(&"NavButton", {
		"font_color": TEXT_DIM,
		"font_hover_color": TEXT,
		"font_pressed_color": TEXT_BRIGHT,
		"font_hover_pressed_color": TEXT_BRIGHT,
		"font_focus_color": TEXT,
		"font_disabled_color": TEXT_OFF,
	})


func _solid_button(type: StringName, fill: Color, bright: Color) -> void:
	theme.set_type_variation(type, &"Button")
	var cut := [12, 0, 12, 0]
	var margin := [22, 10, 22, 10]
	_styles(type, {
		"normal": _box(Color(fill, 0.92), Color(bright, 0.85), 1, cut, margin, Color(bright, 0.2), 10),
		"hover": _box(fill.lightened(0.14), bright.lightened(0.3), 1, cut, margin, Color(bright, 0.42), 18),
		"pressed": _box(fill.darkened(0.25), bright, 1, cut, margin),
		"disabled": _box(Color(fill.darkened(0.6), 0.5), Color(bright, 0.18), 1, cut, margin),
		"focus": _box(CLEAR, Color(1, 1, 1, 0.5), 1, cut, margin),
	})
	_colors(type, {
		"font_color": TEXT_BRIGHT,
		"font_hover_color": TEXT_BRIGHT,
		"font_pressed_color": TEXT_BRIGHT,
		"font_focus_color": TEXT_BRIGHT,
		"font_disabled_color": Color(1, 1, 1, 0.3),
	})
	theme.set_font(&"font", type, _spaced(body_bold, 1))
	theme.set_font_size(&"font_size", type, 16)


# --- Tick boxes, chips and switches -----------------------------------------------------------------------------

func _toggles() -> void:
	var toggle_colors := {
		"font_color": TEXT,
		"font_hover_color": TEXT_BRIGHT,
		"font_pressed_color": TEXT_BRIGHT,
		"font_hover_pressed_color": TEXT_BRIGHT,
		"font_focus_color": TEXT,
		"font_disabled_color": TEXT_OFF,
	}
	var pad := [4, 5, 6, 5]
	var plain := {"normal": _empty(pad), "pressed": _empty(pad), "hover": _empty(pad), "hover_pressed": _empty(pad), "disabled": _empty(pad), "focus": _empty(pad)}

	_styles(&"CheckBox", plain)
	_colors(&"CheckBox", toggle_colors)
	_constants(&"CheckBox", {"h_separation": 10})
	theme.set_icon(&"unchecked", &"CheckBox", _tick_icon(20, Color(TEXT_DIM, 0.9), CLEAR))
	theme.set_icon(&"checked", &"CheckBox", _tick_icon(20, CYAN, CYAN))
	theme.set_icon(&"unchecked_disabled", &"CheckBox", _tick_icon(20, TEXT_OFF, CLEAR))
	theme.set_icon(&"checked_disabled", &"CheckBox", _tick_icon(20, TEXT_OFF, TEXT_OFF))

	# A tick box drawn as a tag that lights up when it is on. Used for the weapon, special and vehicle lists.
	theme.set_type_variation(&"ChipCheck", &"CheckBox")
	var chip_cut := [0, 7, 0, 7]
	var chip_pad := [10, 6, 14, 6]
	_styles(&"ChipCheck", {
		"normal": _box(Color(1, 1, 1, 0.025), Color(LINE, 0.16), 1, chip_cut, chip_pad),
		"hover": _box(Color(1, 1, 1, 0.06), Color(LINE, 0.5), 1, chip_cut, chip_pad),
		"pressed": _box(Color(CYAN, 0.15), Color(CYAN, 0.75), 1, chip_cut, chip_pad),
		"hover_pressed": _box(Color(CYAN, 0.24), CYAN, 1, chip_cut, chip_pad, Color(CYAN, 0.18), 6),
		"disabled": _box(Color(1, 1, 1, 0.01), Color(LINE, 0.08), 1, chip_cut, chip_pad),
		"focus": _empty(chip_pad),
	})
	theme.set_color(&"font_color", &"ChipCheck", TEXT_DIM)
	theme.set_font(&"font", &"ChipCheck", body_semi)
	theme.set_constant(&"h_separation", &"ChipCheck", 8)
	theme.set_icon(&"unchecked", &"ChipCheck", _light_icon(TEXT_OFF, false))
	theme.set_icon(&"checked", &"ChipCheck", _light_icon(CYAN, true))
	theme.set_icon(&"unchecked_disabled", &"ChipCheck", _light_icon(Color(TEXT_OFF, 0.5), false))
	theme.set_icon(&"checked_disabled", &"ChipCheck", _light_icon(TEXT_OFF, true))

	# A switch, with its label on the left and the switch on the right.
	var switch_pad := [0, 5, 0, 5]
	for key in plain:
		theme.set_stylebox(key, &"CheckButton", _empty(switch_pad))
	_colors(&"CheckButton", toggle_colors)
	_constants(&"CheckButton", {"h_separation": 12})
	for mirrored in ["", "_mirrored"]:
		theme.set_icon("checked" + mirrored, &"CheckButton", _switch_icon(true, true))
		theme.set_icon("unchecked" + mirrored, &"CheckButton", _switch_icon(false, true))
		theme.set_icon("checked_disabled" + mirrored, &"CheckButton", _switch_icon(true, false))
		theme.set_icon("unchecked_disabled" + mirrored, &"CheckButton", _switch_icon(false, false))


# --- Text fields ------------------------------------------------------------------------------------------------

func _fields() -> void:
	var margin := [14, 10, 14, 10]
	var cut := [0, 8, 0, 8]
	var field_styles := {
		"normal": _box(INSET, LINE, [1, 1, 1, 2], cut, margin),
		"focus": _box(Color(0.03, 0.08, 0.13, 0.9), CYAN, [1, 1, 1, 2], cut, margin, Color(CYAN, 0.2), 8),
		"read_only": _box(Color(INSET, 0.4), Color(LINE, 0.12), [1, 1, 1, 2], cut, margin),
	}
	var field_colors := {
		"font_color": TEXT_BRIGHT,
		"font_placeholder_color": TEXT_OFF,
		"font_uneditable_color": TEXT_DIM,
		"font_readonly_color": TEXT_DIM,
		"font_selected_color": TEXT_BRIGHT,
		"caret_color": CYAN,
		"selection_color": Color(CYAN, 0.35),
	}
	for type in [&"LineEdit", &"TextEdit"]:
		_styles(type, field_styles)
		_colors(type, field_colors)
	theme.set_font(&"font", &"LineEdit", body_semi)
	theme.set_font_size(&"font_size", &"LineEdit", 20)


# --- Lists ------------------------------------------------------------------------------------------------------

func _lists() -> void:
	var panel := _box(INSET, Color(LINE, 0.14), 1, [0, 0, 0, 0], [4, 4, 4, 4])
	var selected := _box(Color(CYAN, 0.17), CYAN, [3, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0])
	var hovered := _box(Color(CYAN, 0.06), Color(CYAN, 0.4), [3, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0])
	var hovered_selected := _box(Color(CYAN, 0.24), CYAN, [3, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0])
	var title := _box(Color(CYAN, 0.07), LINE, [0, 0, 0, 1], [0, 0, 0, 0], [10, 7, 10, 7])
	var list_colors := {
		"font_color": TEXT,
		"font_hovered_color": TEXT_BRIGHT,
		"font_hovered_dimmed_color": TEXT,
		"font_selected_color": TEXT_BRIGHT,
		"font_hovered_selected_color": TEXT_BRIGHT,
		"font_disabled_color": TEXT_OFF,
		"guide_color": Color(LINE, 0.07),
		"title_button_color": CYAN,
		"relationship_line_color": CLEAR,
		"children_hl_line_color": CLEAR,
		"parent_hl_line_color": CLEAR,
	}

	_styles(&"Tree", {
		"panel": panel,
		"focus": _empty(),
		"selected": selected,
		"selected_focus": selected,
		"hovered": hovered,
		"hovered_dimmed": hovered,
		"hovered_selected": hovered_selected,
		"hovered_selected_focus": hovered_selected,
		"cursor": _empty(),
		"cursor_unfocused": _empty(),
		"title_button_normal": title,
		"title_button_hover": title,
		"title_button_pressed": title,
	})
	_colors(&"Tree", list_colors)
	_constants(&"Tree", {
		"v_separation": 9,
		"h_separation": 10,
		"inner_item_margin_left": 8,
		"inner_item_margin_right": 8,
		"item_margin": 0,
		"draw_guides": 1,
		"draw_relationship_lines": 0,
		"scrollbar_margin_right": 2,
		"scrollbar_margin_top": 2,
		"scrollbar_margin_bottom": 2,
	})
	theme.set_font(&"title_button_font", &"Tree", _spaced(body_bold, 2))
	theme.set_font_size(&"title_button_font_size", &"Tree", 13)
	theme.set_font(&"font", &"Tree", body_semi)

	_styles(&"ItemList", {
		"panel": panel,
		"focus": _empty(),
		"selected": selected,
		"selected_focus": selected,
		"hovered": hovered,
		"hovered_selected": hovered_selected,
		"hovered_selected_focus": hovered_selected,
		"cursor": _empty(),
		"cursor_unfocused": _empty(),
	})
	_colors(&"ItemList", list_colors)
	_constants(&"ItemList", {"v_separation": 12, "h_separation": 10})
	theme.set_font(&"font", &"ItemList", body_semi)


# --- Panels -----------------------------------------------------------------------------------------------------

func _panels() -> void:
	# The card. hud_card.gd draws brackets on its two square corners.
	var card := _box(PANEL, LINE, 1, [0, 20, 0, 20], [20, 16, 20, 18], Color(0, 0, 0, 0.45), 14)
	_styles(&"PanelContainer", {"panel": card})
	_styles(&"Panel", {"panel": _box(PANEL, LINE, 1, [0, 20, 0, 20], [0, 0, 0, 0])})

	# A darker well inside a card: behind a picture, around a note.
	theme.set_type_variation(&"InsetPanel", &"Panel")
	_styles(&"InsetPanel", {"panel": _box(Color(0.008, 0.016, 0.035, 0.9), CLEAR, 0)})
	theme.set_type_variation(&"InsetCard", &"PanelContainer")
	_styles(&"InsetCard", {"panel": _box(INSET, Color(LINE, 0.14), 1, [0, 10, 0, 10], [14, 10, 14, 10])})

	# The line around a picture, drawn over it.
	theme.set_type_variation(&"FrameBorder", &"Panel")
	_styles(&"FrameBorder", {"panel": _box(CLEAR, Color(CYAN, 0.55), 1)})

	# The strips along the top and bottom of the screen.
	theme.set_type_variation(&"TopBar", &"PanelContainer")
	_styles(&"TopBar", {"panel": _box(Color(0.016, 0.03, 0.065, 0.9), LINE_STRONG, [0, 0, 0, 1], [0, 0, 0, 0], [28, 0, 20, 0], Color(0, 0, 0, 0.5), 16)})
	theme.set_type_variation(&"StatusBar", &"PanelContainer")
	_styles(&"StatusBar", {"panel": _box(Color(0.016, 0.03, 0.065, 0.92), LINE, [0, 1, 0, 0], [0, 0, 0, 0], [28, 8, 28, 8])})

	# The strip under the Create Game cards that holds the Host button.
	theme.set_type_variation(&"ActionBar", &"PanelContainer")
	_styles(&"ActionBar", {"panel": _box(Color(0.02, 0.04, 0.08, 0.78), LINE, [0, 1, 0, 0], [0, 0, 0, 0], [20, 12, 12, 12])})

	_styles(&"ScrollContainer", {"panel": _empty(), "focus": _empty()})

	# Tabs are only seen on the Settings screen; the three main screens hide theirs and use the top bar.
	var tab_margin := [20, 9, 20, 9]
	for type in [&"TabContainer", &"TabBar"]:
		_styles(type, {
			"tab_selected": _box(Color(CYAN, 0.12), CYAN, [0, 0, 0, 2], [0, 0, 0, 0], tab_margin),
			"tab_hovered": _box(Color(CYAN, 0.05), LINE, [0, 0, 0, 2], [0, 0, 0, 0], tab_margin),
			"tab_unselected": _box(CLEAR, Color(LINE, 0.12), [0, 0, 0, 2], [0, 0, 0, 0], tab_margin),
			"tab_disabled": _box(CLEAR, Color(LINE, 0.06), [0, 0, 0, 2], [0, 0, 0, 0], tab_margin),
			"tab_focus": _empty(),
		})
		_colors(type, {"font_selected_color": TEXT_BRIGHT, "font_hovered_color": TEXT, "font_unselected_color": TEXT_DIM, "font_disabled_color": TEXT_OFF})
		theme.set_font(&"font", type, _display(700, 1))
		theme.set_font_size(&"font_size", type, 14)
	_styles(&"TabContainer", {"panel": _empty(), "tabbar_background": _empty()})
	_constants(&"TabContainer", {"side_margin": 0})


# --- Scroll bars, sliders, progress -----------------------------------------------------------------------------

func _bars() -> void:
	for type in [&"VScrollBar", &"HScrollBar"]:
		var thin := [3, 0, 3, 0] if type == &"VScrollBar" else [0, 3, 0, 3]
		_styles(type, {
			"scroll": _box(Color(1, 1, 1, 0.03), CLEAR, 0, [0, 0, 0, 0], thin),
			"scroll_focus": _box(Color(1, 1, 1, 0.03), CLEAR, 0, [0, 0, 0, 0], thin),
			"grabber": _box(Color(CYAN, 0.35), CLEAR, 0, [0, 0, 0, 0], thin),
			"grabber_highlight": _box(Color(CYAN, 0.65), CLEAR, 0, [0, 0, 0, 0], thin),
			"grabber_pressed": _box(CYAN, CLEAR, 0, [0, 0, 0, 0], thin),
		})

	_styles(&"HSlider", {
		"slider": _box(Color(1, 1, 1, 0.1), CLEAR, 0, [0, 0, 0, 0], [0, 2, 0, 2]),
		"grabber_area": _box(Color(CYAN, 0.8), CLEAR, 0, [0, 0, 0, 0], [0, 2, 0, 2]),
		"grabber_area_highlight": _box(CYAN, CLEAR, 0, [0, 0, 0, 0], [0, 2, 0, 2]),
	})
	theme.set_icon(&"grabber", &"HSlider", _block_icon(10, 18, TEXT))
	theme.set_icon(&"grabber_highlight", &"HSlider", _block_icon(10, 18, TEXT_BRIGHT))
	theme.set_icon(&"grabber_disabled", &"HSlider", _block_icon(10, 18, TEXT_OFF))

	_styles(&"ProgressBar", {
		"background": _box(INSET, Color(LINE, 0.14), 1, [0, 0, 0, 0], [0, 0, 0, 0]),
		"fill": _box(Color(CYAN, 0.75), CLEAR, 0, [0, 0, 0, 0], [0, 0, 0, 0]),
	})


# --- Popups, tooltips and dialogs -------------------------------------------------------------------------------

func _popups() -> void:
	var popup_panel := _box(PANEL_SOLID, Color(CYAN, 0.45), 1, [0, 10, 0, 10], [6, 8, 6, 8], Color(0, 0, 0, 0.5), 10)
	_styles(&"PopupMenu", {
		"panel": popup_panel,
		"hover": _box(Color(CYAN, 0.2), CYAN, [3, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]),
		"separator": _line_style(false),
	})
	_colors(&"PopupMenu", {
		"font_color": TEXT,
		"font_hover_color": TEXT_BRIGHT,
		"font_disabled_color": TEXT_OFF,
		"font_separator_color": TEXT_DIM,
		"font_accelerator_color": TEXT_DIM,
	})
	_constants(&"PopupMenu", {"v_separation": 10, "h_separation": 10, "item_start_padding": 12, "item_end_padding": 16})
	theme.set_font(&"font", &"PopupMenu", body_semi)
	theme.set_icon(&"radio_unchecked", &"PopupMenu", _diamond_icon(16, TEXT_OFF, CLEAR))
	theme.set_icon(&"radio_checked", &"PopupMenu", _diamond_icon(16, CYAN, CYAN))
	theme.set_icon(&"radio_unchecked_disabled", &"PopupMenu", _diamond_icon(16, Color(TEXT_OFF, 0.5), CLEAR))
	theme.set_icon(&"radio_checked_disabled", &"PopupMenu", _diamond_icon(16, TEXT_OFF, TEXT_OFF))
	theme.set_icon(&"unchecked", &"PopupMenu", _tick_icon(16, TEXT_OFF, CLEAR))
	theme.set_icon(&"checked", &"PopupMenu", _tick_icon(16, CYAN, CYAN))
	_styles(&"PopupPanel", {"panel": popup_panel})

	_styles(&"TooltipPanel", {"panel": _box(PANEL_SOLID, Color(CYAN, 0.5), [3, 1, 1, 1], [0, 0, 0, 0], [12, 7, 12, 7])})
	theme.set_color(&"font_color", &"TooltipLabel", TEXT)
	theme.set_font(&"font", &"TooltipLabel", body_semi)
	theme.set_font_size(&"font_size", &"TooltipLabel", 16)

	# Dialogs (the game draws them inside its own window). The frame is one box behind both the title strip and
	# the body, pushed out past the body by its expand margins; the title strip is the 38 pixels on top.
	const TITLE_HEIGHT := 38
	for key in ["embedded_border", "embedded_unfocused_border"]:
		var frame := _box(PANEL_SOLID, Color(CYAN, 0.6 if key == "embedded_border" else 0.25), [1, 3, 1, 1], [0, 14, 0, 14], [0, 0, 0, 0], Color(0, 0, 0, 0.6), 24)
		frame.expand_margin_left = 8
		frame.expand_margin_right = 8
		frame.expand_margin_bottom = 8
		frame.expand_margin_top = TITLE_HEIGHT
		theme.set_stylebox(key, &"Window", frame)
	_colors(&"Window", {"title_color": TEXT_BRIGHT, "title_outline_modulate": CLEAR})
	_constants(&"Window", {"title_height": TITLE_HEIGHT, "close_h_offset": 22, "close_v_offset": 28, "resize_margin": 6})
	theme.set_font(&"title_font", &"Window", _display(700, 2))
	theme.set_font_size(&"title_font_size", &"Window", 14)
	theme.set_icon(&"close", &"Window", _cross_icon(TEXT_DIM))
	theme.set_icon(&"close_pressed", &"Window", _cross_icon(PINK))
	_styles(&"AcceptDialog", {"panel": _box(CLEAR, CLEAR, 0, [0, 0, 0, 0], [14, 14, 14, 12])})
	_constants(&"AcceptDialog", {"buttons_separation": 12, "buttons_min_width": 120, "buttons_min_height": 40})

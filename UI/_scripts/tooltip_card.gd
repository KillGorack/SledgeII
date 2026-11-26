extends RefCounted
class_name TooltipCard

# Hover cards for the menus: a fixed width so long descriptions wrap instead of running across the screen.
#
#   make()  a small card - an optional title in the accent color, the text wrapped to WIDTH, an optional dim note.
#           For controls that have a script (override _make_custom_tooltip and return this - see check_list.gd).
#   wrap_text()  the same width for plain built-in controls (a CheckButton with tooltip_text can't build a card): their
#           text gets line breaks, and the theme's tooltip panel draws it. wrap_all() does a whole screen at once.
#
# Either way the card sits in the theme's TooltipPanel (build_theme.gd: the dark panel with the cyan edge).

const WIDTH := 320
# Roughly WIDTH in characters of the tooltip font, for wrap_text(): the text is broken at words, never mid-word.
const WRAP_CHARS := 44
const TITLE_COLOR := Color(0.56, 0.85, 0.91)


static func make(title: String, text: String, note: String = "") -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 6)
	if title != "":
		var heading := Label.new()
		heading.theme_type_variation = &"CapsLabel"
		heading.text = title.to_upper()
		heading.add_theme_color_override("font_color", TITLE_COLOR)
		card.add_child(heading)
	if text != "":
		card.add_child(_wrapped_label(text, &"TooltipLabel"))
	if note != "":
		card.add_child(_wrapped_label(note, &"DimLabel"))
	return card


static func _wrapped_label(text: String, type: StringName) -> Label:
	var label := Label.new()
	label.theme_type_variation = type
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A wrapping Label only knows how tall it is once it knows how wide it is.
	label.custom_minimum_size = Vector2(WIDTH, 0)
	return label


# `text` with line breaks so no line runs past WRAP_CHARS. Existing line breaks are kept.
static func wrap_text(text: String) -> String:
	var lines: Array[String] = []
	for paragraph in text.split("\n"):
		var line := ""
		for word in paragraph.split(" ", false):
			if line != "" and line.length() + 1 + word.length() > WRAP_CHARS:
				lines.append(line)
				line = word
			else:
				line = word if line == "" else line + " " + word
		lines.append(line)
	return "\n".join(lines)


# wrap_text() every tooltip under `root`, once (a control that builds its own card is left alone).
static func wrap_all(root: Node) -> void:
	for node in root.find_children("*", "Control", true, false):
		var control := node as Control
		if control.tooltip_text != "" and not control is CheckList:
			control.tooltip_text = wrap_text(control.tooltip_text)

extends Tree
class_name CheckList

# A grouped list of checkboxes for the host screen (weapons, specials, vehicles, drops). A Tree, so it looks like the
# arena list next to it and scrolls by itself however long it gets.
#
#   WEAPONS            <- group header: its box ticks/unticks the whole group, and shows "some" when it's mixed
#     [x] MK IV
#     [ ] Plasma
#
# Clicking anywhere on a row toggles it (not just the little box). Each entry carries one piece of metadata - the
# key/value given to add_entry (e.g. "weapon_path" -> "res://...") - which is how the screen reads the list back.
# A ticked row is shown as a whole: an accent band across the row and bright text; an unticked one is plain and dim.
# An entry that can't be picked right now can be hidden (set_entry_hidden) - it keeps its tick for when it's back.

signal changed

const ICON_SIZE := 18
const ROW_SPACING := 3
# Ticked rows: a band in the screen's accent color (index.gd ACCENT) and bright text. Unticked: the chips' dim text.
const ON_BAND := Color(0.56, 0.85, 0.91, 0.22)
const ON_TEXT := Color(0.92, 0.98, 1.0)
const OFF_TEXT := Color(0.5, 0.6, 0.72)
# The theme's checkbox art lives on the chip style; borrowed so the list matches the rest of the screen.
const ART_FROM := &"ChipCheck"

var _root: TreeItem
# Where the mouse last was over the list, for the hover card's title.
var _hover_at := Vector2.ZERO


func _ready() -> void:
	hide_root = true
	hide_folding = true
	columns = 1
	focus_mode = Control.FOCUS_NONE
	select_mode = Tree.SELECT_ROW
	scroll_horizontal_enabled = false
	# Tighter rows than the arena list's (the theme's Tree spacing), so a whole loadout or drop table fits unscrolled.
	add_theme_constant_override("v_separation", ROW_SPACING)
	for icon_name in ["checked", "unchecked", "checked_disabled", "unchecked_disabled"]:
		add_theme_icon_override(icon_name, get_theme_icon(icon_name, ART_FROM))
	add_theme_icon_override("indeterminate", _indeterminate_icon())
	add_theme_icon_override("indeterminate_disabled", _indeterminate_icon())
	if _root == null:
		_root = create_item()
	gui_input.connect(_on_gui_input)


# A header row. keep_one: the group never ends up with nothing ticked (the vehicle list - a game needs a craft).
func add_group(title: String, keep_one: bool = false) -> TreeItem:
	if _root == null:
		_root = create_item()
	var group := create_item(_root)
	group.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	group.set_editable(0, true)
	group.set_text(0, title)
	group.set_custom_color(0, get_theme_color("font_color", &"CapsLabel"))
	group.set_custom_font(0, get_theme_font("font", &"CapsLabel"))
	group.set_custom_font_size(0, get_theme_font_size("font_size", &"CapsLabel"))
	group.set_meta("group", true)
	group.set_meta("keep_one", keep_one)
	return group


func add_entry(group: TreeItem, text: String, key: String, value: Variant, tooltip: String = "", icon: Texture2D = null, checked: bool = true) -> TreeItem:
	var entry := create_item(group)
	entry.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	entry.set_editable(0, true)
	entry.set_text(0, text)
	entry.set_checked(0, checked)
	entry.set_tooltip_text(0, tooltip)
	if icon != null:
		entry.set_icon(0, icon)
		entry.set_icon_max_width(0, ICON_SIZE)
	entry.set_meta(key, value)
	entry.set_meta("default", checked)
	_style(entry)
	_refresh_group(group)
	return entry


func remove_group(group: TreeItem) -> void:
	if group != null:
		group.free()


# Every entry (optionally only those carrying `key`), in list order.
func entries(key: String = "") -> Array[TreeItem]:
	var out: Array[TreeItem] = []
	if _root == null:
		return out
	for group in _root.get_children():
		for entry in group.get_children():
			if key == "" or entry.has_meta(key):
				out.append(entry)
	return out


func is_on(entry: TreeItem) -> bool:
	return entry.is_checked(0)


# The `key` values of the ticked entries (or of every entry, with only_checked false). include_hidden false leaves out
# what is hidden right now (what the game will really get, as opposed to what's saved).
func values(key: String, only_checked: bool = true, include_hidden: bool = true) -> Array:
	var out: Array = []
	for entry in entries(key):
		if not include_hidden and not entry.visible:
			continue
		if not only_checked or entry.is_checked(0):
			out.append(entry.get_meta(key))
	return out


# Set the ticks from saved settings or a preset. `checked`: the values to tick. `listed`: every value the list had
# when it was saved - entries NOT in it (added to the game since) get their default. listed = null: `checked` is
# exact, everything else is unticked.
func apply_ticks(key: String, checked: Array, listed: Variant = null) -> void:
	for entry in entries(key):
		var value = entry.get_meta(key)
		if listed == null or (listed as Array).has(value):
			entry.set_checked(0, checked.has(value))
		else:
			entry.set_checked(0, entry.get_meta("default", true))
		_style(entry)
	_refresh_all()


# Every entry carrying `key` back to the tick it was added with.
func reset_defaults(key: String) -> void:
	for entry in entries(key):
		entry.set_checked(0, entry.get_meta("default", true))
		_style(entry)
	_refresh_all()


func set_all(on: bool) -> void:
	for group in _root.get_children():
		_set_group(group, on)
	changed.emit()


# Out of the list (and out of the group's tick-all) but its tick is kept, so it comes back as it was. A group header
# hides too once all of its rows are hidden.
func set_entry_hidden(entry: TreeItem, hidden: bool) -> void:
	entry.visible = not hidden
	entry.set_editable(0, not hidden)
	var group := entry.get_parent()
	var any_shown := false
	for sibling in group.get_children():
		any_shown = any_shown or sibling.visible
	group.visible = any_shown
	_refresh_group(group)


func is_hidden(entry: TreeItem) -> bool:
	return not entry.visible


# Hovering a row: a card with the row's name and its description, wrapped to a fixed width (tooltip_card.gd).
func _make_custom_tooltip(for_text: String) -> Object:
	var item := get_item_at_position(_hover_at)
	return TooltipCard.make(item.get_text(0) if item != null else "", for_text)


# The whole row is the button: handled here, before the Tree's own click handling (which would only react to the
# box and would also select the row), and then swallowed.
func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover_at = event.position
		return
	var click := event as InputEventMouseButton
	if click == null or click.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if not click.pressed:
		return
	var item := get_item_at_position(click.position)
	if item == null or not item.is_editable(0):
		return
	if item.has_meta("group"):
		_set_group(item, not _all_on(item))
	else:
		var group := item.get_parent()
		if item.is_checked(0) and group.get_meta("keep_one", false) and _count_on(group) <= 1:
			return # the last one stays
		item.set_checked(0, not item.is_checked(0))
		_style(item)
		_refresh_group(group)
	changed.emit()


func _set_group(group: TreeItem, on: bool) -> void:
	var kept := false
	for entry in group.get_children():
		if not entry.is_editable(0):
			continue # disabled entries keep their tick
		if not on and group.get_meta("keep_one", false) and not kept and entry.is_checked(0):
			kept = true # unticking a keep-one group leaves its first ticked entry
			continue
		entry.set_checked(0, on)
		_style(entry)
	_refresh_group(group)


func _all_on(group: TreeItem) -> bool:
	for entry in group.get_children():
		if entry.visible and entry.is_editable(0) and not entry.is_checked(0):
			return false
	return true


func _count_on(group: TreeItem) -> int:
	var n := 0
	for entry in group.get_children():
		if entry.is_checked(0):
			n += 1
	return n


func _style(entry: TreeItem) -> void:
	if entry.is_checked(0):
		entry.set_custom_bg_color(0, ON_BAND)
		entry.set_custom_color(0, ON_TEXT)
	else:
		entry.clear_custom_bg_color(0)
		entry.set_custom_color(0, OFF_TEXT)


# Header box: ticked when every entry is, empty when none are, "some" in between.
func _refresh_group(group: TreeItem) -> void:
	var total := 0
	var on := 0
	for entry in group.get_children():
		if entry.visible:
			total += 1
			if entry.is_checked(0):
				on += 1
	group.set_checked(0, total > 0 and on == total)
	group.set_indeterminate(0, on > 0 and on < total)


func _refresh_all() -> void:
	if _root == null:
		return
	for group in _root.get_children():
		_refresh_group(group)


# The theme has no "some ticked" box, so one is made from its empty box with a bar across the middle.
func _indeterminate_icon() -> Texture2D:
	var base := get_theme_icon("unchecked", ART_FROM)
	if base == null:
		return null
	var image := base.get_image()
	if image == null:
		return base
	image = image.duplicate()
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	var w := image.get_width()
	var h := image.get_height()
	var bar := get_theme_color("font_color", ART_FROM)
	var thickness := maxi(2, h / 7)
	for y in range(h / 2 - thickness / 2, h / 2 - thickness / 2 + thickness):
		for x in range(int(w * 0.28), int(w * 0.72)):
			image.set_pixel(x, y, bar)
	return ImageTexture.create_from_image(image)

extends HBoxContainer

# Active weapon boosts on the HUD: an icon and a countdown per boost. A small
# fixed pool of slots is built once and shown/hidden as boosts come and go -
# nothing is created or freed while playing. Owner's HUD only (see
# hud_controller.gd, which adds this and sets weapon_node first).

const SLOTS := 6
const ICON_SIZE := 44.0
const WARN_SECONDS := 4.0

var weapon_node: Node

var _slots: Array = [] # {box, icon, label}
var _active: Array = [] # [{boost, end_msec}] in slot order


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Explicit anchors and offsets: set_anchors_preset() keeps the node's current
	# on-screen position (the top-left corner) by rewriting the offsets, which
	# pinned this bar to the left edge and stretched it tall.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	# Bottom edge just above the dial cluster (it rises 179 px from the bottom
	# edge); zero width/height offsets mean the bar is exactly as big as its icons.
	offset_left = 0.0
	offset_right = 0.0
	offset_top = -190.0
	offset_bottom = -190.0
	add_theme_constant_override("separation", 10)
	alignment = BoxContainer.ALIGNMENT_CENTER
	for i in SLOTS:
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.visible = false
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 13)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(icon)
		box.add_child(label)
		add_child(box)
		_slots.append({"box": box, "icon": icon, "label": label})
	if weapon_node:
		weapon_node.boosts_changed.connect(_refresh)
		_refresh()


# Boost list changed: reassign slots (no allocation).
func _refresh() -> void:
	var status: Array = weapon_node.boost_status()
	var now := Time.get_ticks_msec()
	_active.clear()
	for i in SLOTS:
		var slot: Dictionary = _slots[i]
		if i < status.size():
			var boost: BoostSettings = status[i]["boost"]
			_active.append(now + int(status[i]["left"] * 1000.0))
			slot["icon"].texture = boost.icon
			slot["icon"].self_modulate = Color.WHITE
			slot["box"].visible = true
		else:
			slot["box"].visible = false


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for i in _active.size():
		var left := maxf(0.0, (_active[i] - now) / 1000.0)
		var slot: Dictionary = _slots[i]
		slot["label"].text = "%d" % ceili(left)
		# Blink in the last few seconds.
		slot["icon"].modulate.a = 1.0 if left > WARN_SECONDS or int(left * 4.0) % 2 == 0 else 0.35

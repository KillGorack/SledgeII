extends PanelContainer
class_name TargetTile

# Info tile for the craft picked with cycle_teamies / cycle_enemies (see target_selector.gd), bottom-right corner:
# the handle on top, then the target's shield / armor / life rings (the same gauge as your own, health_rings.gd)
# around its craft icon tinted in its team color, then its other stats underneath. Visual only; it reads values the
# target's craft already has on every peer (health replicates to everyone, bounty comes from the roster pushes the
# F4 player list uses).

const HEALTH_RINGS := preload("res://Crafts/_scripts/health_rings.gd")
const RING_BOX := 112.0
const ICON_SIZE := 50.0
const MARGIN := 10.0

var _target: Node3D = null
var _rings: Control = null
var _ring_holder: Control
var _icon: TextureRect
var _handle: Label
var _craft_label: Label
var _bounty: Label
var _record: Label
var _distance: Label
var _style: StyleBoxFlat
var _last: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	# Anchored to the bottom-right corner, growing up and to the left as it needs room.
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_right = -MARGIN
	offset_bottom = -MARGIN
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	custom_minimum_size = Vector2(190.0, 0.0)

	_style = StyleBoxFlat.new()
	_style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	_style.set_border_width_all(1)
	_style.set_corner_radius_all(6)
	_style.set_content_margin_all(10.0)
	add_theme_stylebox_override("panel", _style)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 4)
	add_child(column)

	_handle = _label(18, column)
	_craft_label = _label(12, column)
	_craft_label.modulate = Color(1, 1, 1, 0.6)

	_ring_holder = Control.new()
	_ring_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_holder.custom_minimum_size = Vector2(RING_BOX, RING_BOX)
	_ring_holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(_ring_holder)
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	_icon.size = Vector2(ICON_SIZE, ICON_SIZE)
	_icon.position = (Vector2(RING_BOX, RING_BOX) - _icon.size) / 2.0
	_ring_holder.add_child(_icon)

	column.add_child(HSeparator.new())
	_bounty = _label(16, column)
	_record = _label(13, column)
	_distance = _label(13, column)


func _label(font_size: int, parent: Node) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	parent.add_child(label)
	return label


func clear() -> void:
	_target = null
	visible = false


# Called every frame by the selector while something is selected. `handle` is the player's name.
func show_target(target: Node3D, handle: String, color: Color, distance: float) -> void:
	if target != _target:
		_set_target(target, color)
	visible = true
	_handle.text = handle
	_handle.add_theme_color_override("font_color", color)
	_distance.text = "%d m away" % roundi(distance)
	var owner_id := Utilities.craft_owner_id(target)
	var score: Array = NetworkManager.peer_scores.get(owner_id, [])
	_bounty.text = "Bounty  %d" % int(score[2]) if score.size() > 2 else "Bounty  -"
	_record.text = "Takedowns %d   Wrecks %d" % [int(score[0]), int(score[1])] if score.size() > 1 else ""
	_update_rings(target)


func _set_target(target: Node3D, color: Color) -> void:
	_target = target
	_last = []
	_style.border_color = color
	var def := CraftCatalog.get_def(target.get_meta(&"craft_id", CraftCatalog.DEFAULT_ID))
	_icon.texture = _crisp(def.icon)
	_icon.self_modulate = color
	_craft_label.text = def.display_name.to_upper()
	# A fresh gauge per target, so its hit flash doesn't fire from the previous target's numbers.
	if _rings != null:
		_rings.queue_free()
	_rings = HEALTH_RINGS.new()
	_rings.life_radius = 30.0
	_rings.ring_thickness = 8.0
	_rings.vertical_stretch = 1.0
	_rings.show_readout = false
	_rings.center_fill = Color(0.0, 0.0, 0.0, 0.7)
	_rings.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rings.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ring_holder.add_child(_rings)
	_ring_holder.move_child(_rings, 0)


# The icon scaled down once with Lanczos to the size it is shown at: thin line art turns to mush under the plain
# bilinear scaling a TextureRect does from 256px to 50px.
var _icon_cache: Dictionary = {}


func _crisp(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	if _icon_cache.has(texture):
		return _icon_cache[texture]
	var result: Texture2D = texture
	var image := texture.get_image()
	if image != null and not image.is_empty():
		if image.is_compressed():
			image.decompress()
		image.clear_mipmaps()
		image.fix_alpha_edges()
		var longest := maxi(image.get_width(), image.get_height())
		if longest > int(ICON_SIZE):
			var factor := ICON_SIZE / float(longest)
			image.resize(maxi(1, roundi(image.get_width() * factor)), maxi(1, roundi(image.get_height() * factor)), Image.INTERPOLATE_LANCZOS)
			result = ImageTexture.create_from_image(image)
	_icon_cache[texture] = result
	return result


func _update_rings(target: Node3D) -> void:
	var health = target.get_node_or_null("health_node")
	if health == null or _rings == null:
		return
	var shields: float = maxf(health.shields, 0.0)
	var armor: float = maxf(health.armor, 0.0)
	var life: float = maxf(health.life, 0.0)
	var now := [shields, armor, life]
	if now == _last:
		return
	_last = now
	_rings.update_ratios(_ratio(shields, health._shields_max), _ratio(armor, health._armor_max), _ratio(life, health._life_max), shields, armor, life)


func _ratio(current: float, max_value: float) -> float:
	return current / max_value if max_value > 0.0 else 0.0

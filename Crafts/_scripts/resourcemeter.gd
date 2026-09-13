extends Control

# Mirror of speedometer.gd for the right bracket instead of the left -
# resource_hole_fill_resize.png is the same kind of pixel-accurate cutout,
# extracted the same way from hud_bezel_resize.png's own alpha channel, just
# for the right "(" shape instead of the left one. Same reasoning applies:
# the shape is already exactly right, so filling it is just cropping the
# texture by height and drawing that slice, bottom-anchored - no arc/angle
# math to fight, same as the speedometer's third and final pass.
#
# Placeholder for now: current_resource_ratio defaults to 1.0 (full) since
# there's no real resource/power system feeding this yet - set_resource_ratio()
# is here ready to wire up once one exists, same shape as
# speedometer.gd::set_speed_ratio().
#
# hole_texture must be the same pixel size as hud_bezel_resize.png and this
# control must share HudBezel's exact rect (see lightning.tscn) so the two
# line up 1:1 with no offset math needed.

@export var hole_texture: Texture2D
# Plain alpha/tint values, same trick as the speedometer - no geometry
# involved in the color, just how bright/opaque the shape is drawn.
@export var empty_color: Color = Color(1, 1, 1, 0.18)
@export var fill_color: Color = Color(0.95, 0.85, 0.1, 1.0)

var current_resource_ratio: float = 1.0

# The PNG has transparent padding above/below the actual ")" cutout (it's a
# square-ish image holding a narrower shape) - cropping/filling against the
# FULL image height like the crop below used to do put 0% at the image's
# bottom edge and 100% at its top edge, not at the shape's own bottom/top tip,
# so the visible fill didn't line up with where the bracket actually starts
# and ends. Scanning the alpha channel once for the shape's real vertical
# extent (rather than hardcoding pixel offsets that would silently go stale
# if the PNG is ever re-cropped or regenerated) is what content_top_px/
# content_height_px below are for. See speedometer.gd, same fix, mirrored.
var _content_top_px: float = 0.0
var _content_height_px: float = 0.0


func _ready() -> void:
	_measure_content_bounds()
	queue_redraw()


# Finds the first and last rows (top to bottom) that contain any non-transparent
# pixel - that's the shape's real bounding box within the padded image.
func _measure_content_bounds() -> void:
	if hole_texture == null:
		return
	var image := hole_texture.get_image()
	if image == null:
		return
	var tex_size := image.get_size()
	var top := -1
	var bottom := -1
	for y in range(tex_size.y):
		var row_has_content := false
		for x in range(tex_size.x):
			if image.get_pixel(x, y).a > 0.01:
				row_has_content = true
				break
		if row_has_content:
			if top == -1:
				top = y
			bottom = y
	if top == -1:
		# Fully transparent image - nothing to measure, fall back to the old
		# full-height behavior rather than dividing by a zero-height range.
		top = 0
		bottom = tex_size.y - 1
	_content_top_px = float(top)
	_content_height_px = float(bottom - top + 1)


func _draw() -> void:
	if hole_texture == null:
		return
	var tex_size = hole_texture.get_size()
	var dest_full = Rect2(Vector2.ZERO, size)

	# Dim version of the whole hole shape, always visible - reads as "here,
	# at zero" instead of vanishing, same reasoning as every other gauge.
	draw_texture_rect(hole_texture, dest_full, false, empty_color)

	if current_resource_ratio > 0.0:
		# Crop to just the bottom slice of the shape's OWN content bounds
		# (not the full padded image - see _measure_content_bounds), sized
		# proportional to the ratio, and draw that same slice into the
		# matching slice of this control - grows upward as ratio increases,
		# cut line is always a clean horizontal edge because the crop itself
		# is one. size and tex_size are assumed pixel-equal (see the class
		# comment), so the same content_top_px/content_height_px pixel
		# offsets apply directly to both the source crop and the destination
		# rect with no separate scaling needed.
		var fill_y = _content_top_px + _content_height_px * (1.0 - current_resource_ratio)
		var fill_height = _content_height_px * current_resource_ratio
		var src_rect = Rect2(0, fill_y, tex_size.x, fill_height)
		var dst_rect = Rect2(0, fill_y, size.x, fill_height)
		draw_texture_rect_region(hole_texture, dst_rect, src_rect, fill_color)


func set_resource_ratio(resource_ratio: float) -> void:
	current_resource_ratio = clamp(resource_ratio, 0.0, 1.0)
	queue_redraw()

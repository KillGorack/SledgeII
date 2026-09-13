extends Control

# Third pass. The first two tried to redraw the bracket's "(" hole
# mathematically (a flat bar, then a fitted arc) - both fought the actual art:
# a hand-drawn thick arc's end caps are cut RADIALLY (toward the circle's
# center) by default, but the real hole's top/bottom edges are cut
# HORIZONTALLY, so the two never quite lined up, worst right at zero.
#
# This version sidesteps that entirely: speedo_hole_fill.png is a solid-white
# cutout of the actual hole shape, pixel-accurate, extracted directly from
# hud_bezel.png's own alpha channel (not hand-drawn, not approximated) - see
# the .png generation notes if this ever needs regenerating from a new bezel.
# Since it's already exactly the right shape, there's nothing left to
# calculate geometrically - filling it is just cropping it by height and
# drawing that slice, bottom-anchored, which naturally gives a clean
# horizontal cut line at whatever height the fill currently sits at.
#
# hole_texture must be the same pixel size as hud_bezel.png and this control
# must share HudBezel's exact rect (see lightning.tscn) so the two line up
# 1:1 with no offset math needed.

@export var hole_texture: Texture2D
# Both colors are plain alpha/tint values - "tweak alpha to simulate" the
# empty-vs-filled look, no geometry involved.
@export var empty_color: Color = Color(1, 1, 1, 0.18)
@export var fill_color: Color = Color(1, 1, 1, 1.0)

var current_speed_ratio: float = 0.0

# The PNG has transparent padding above/below the actual "(" cutout (it's a
# square-ish image holding a narrower shape) - cropping/filling against the
# FULL image height like the crop below used to do put 0% at the image's
# bottom edge and 100% at its top edge, not at the shape's own bottom/top tip,
# so the visible fill didn't line up with where the bracket actually starts
# and ends. Scanning the alpha channel once for the shape's real vertical
# extent (rather than hardcoding pixel offsets that would silently go stale
# if the PNG is ever re-cropped or regenerated) is what content_top_px/
# content_height_px below are for.
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
	# at zero" instead of vanishing when parked, same reasoning as every
	# earlier version of this gauge.
	draw_texture_rect(hole_texture, dest_full, false, empty_color)

	if current_speed_ratio > 0.0:
		# Crop to just the bottom slice of the shape's OWN content bounds
		# (not the full padded image - see _measure_content_bounds), sized
		# proportional to the ratio, and draw that same slice into the
		# matching slice of this control - grows upward as ratio increases,
		# cut line is always a clean horizontal edge because the crop itself
		# is one. size and tex_size are assumed pixel-equal (see the class
		# comment), so the same content_top_px/content_height_px pixel
		# offsets apply directly to both the source crop and the destination
		# rect with no separate scaling needed.
		var fill_y = _content_top_px + _content_height_px * (1.0 - current_speed_ratio)
		var fill_height = _content_height_px * current_speed_ratio
		var src_rect = Rect2(0, fill_y, tex_size.x, fill_height)
		var dst_rect = Rect2(0, fill_y, size.x, fill_height)
		draw_texture_rect_region(hole_texture, dst_rect, src_rect, fill_color)


func set_speed_ratio(speed_ratio: float) -> void:
	current_speed_ratio = clamp(speed_ratio, 0.0, 1.0)
	queue_redraw()

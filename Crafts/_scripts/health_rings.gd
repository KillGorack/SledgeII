extends Control

# Three concentric depletion rings in the center circle of hud_bezel.png -
# shields outermost, armor middle, life innermost. Unlike the speedometer,
# this circle is a true closed ring with no tapering tip shape to match, so
# a plain math-drawn arc works cleanly here - the only seam is wherever the
# sweep starts/ends, and that's a single clean radial cut, not two edges
# that have to agree with a specific piece of art.
#
# Circle center measured directly off hud_bezel.png: source (700, 250) of
# the 1400x500 image, which is exactly the image's own center - unlike the
# speedometer bracket, no offset is needed here. This node shares HudBezel's
# exact rect (see lightning.tscn), so size/2 already lands on it for free.
# Usable interior radius (inside the bezel ring's own stroke) is about
# 62 local px - the three ring radii below stay comfortably under that.

@export var life_radius: float = 44.0
@export var ring_thickness: float = 6.0
# armor/shields are derived from life_radius, not their own independent
# numbers - each one sits exactly one ring_thickness further out than the
# last, so they're always touching edge-to-edge with zero gap between them
# by construction, whatever life_radius or ring_thickness end up being,
# rather than three numbers that have to be kept in sync by hand.
var armor_radius: float:
	get: return life_radius + ring_thickness + 1.0
var shields_radius: float:
	get: return armor_radius + ring_thickness + 1.0
# The bezel's own hole is very slightly taller than it is wide - rather than
# recomputing every radius for an ellipse, this just stretches the Y axis of
# the whole draw pass via draw_set_transform below, so the existing radius
# numbers stay exactly as measured and only the final on-screen shape changes.
# 1.0 = perfect circle, >1.0 = taller.
@export var vertical_stretch: float = 1.09

# No per-ring identity color anymore - all three start plain white and only
# pick up color as a warning, once a ring is most of the way gone. Ramp
# begins at ramp_start_ratio (0.4 = 60% depleted) and runs white -> yellow ->
# orange -> red as the remaining ratio drops from there to zero.
@export var ramp_start_ratio: float = 0.4
@export var color_full: Color = Color.WHITE
@export var color_warn_low: Color = Color(1.0, 0.9, 0.2)
@export var color_warn_high: Color = Color(1.0, 0.55, 0.1)
@export var color_critical: Color = Color(0.95, 0.15, 0.1)
@export var track_color: Color = Color(0, 0, 0, 0.5)

var _life_ratio: float = 1.0
var _armor_ratio: float = 1.0
var _shields_ratio: float = 1.0

# Fixed start point (top, sweeping clockwise) rather than derived from any
# art - there's no baked shape here to match, so this is just a style choice.
const START_ANGLE_DEG := -90.0
const FULL_SWEEP_DEG := 359.9 # 360 exactly can leave a visible seam at full


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	# Everything below is drawn in local space with the origin AT the ring
	# center (see _draw_ring's center=Vector2.ZERO) - this transform shifts
	# that origin out to the control's actual center and stretches Y only,
	# so X (the radius numbers as measured) is completely untouched.
	draw_set_transform(size / 2, 0.0, Vector2(1.0, vertical_stretch))
	_draw_ring(life_radius, _life_ratio)
	_draw_ring(armor_radius, _armor_ratio)
	_draw_ring(shields_radius, _shields_ratio)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_ring(radius: float, ratio: float) -> void:
	var center = Vector2.ZERO
	var start_radians = deg_to_rad(START_ANGLE_DEG)
	var full_sweep_radians = deg_to_rad(FULL_SWEEP_DEG)

	# Background track, always drawn even at zero - same reasoning as every
	# other gauge this session: reads as "here, empty" rather than missing.
	draw_arc(center, radius, start_radians, start_radians + full_sweep_radians, 48, track_color, ring_thickness + 2, true)

	if ratio > 0.0:
		draw_arc(center, radius, start_radians, start_radians + full_sweep_radians * ratio, 48, _color_for_ratio(ratio), ring_thickness, true)


# White above ramp_start_ratio (nothing to warn about yet). Below that, a
# 3-stage ramp white -> yellow -> orange -> red as the ring keeps draining
# toward zero - t=0 right at the ramp's start (still basically white),
# t=1 at fully empty (full red, right before it goes poof).
func _color_for_ratio(ratio: float) -> Color:
	if ratio >= ramp_start_ratio or ramp_start_ratio <= 0.0:
		return color_full
	var t = 1.0 - (ratio / ramp_start_ratio)
	if t <= 1.0 / 3.0:
		return color_full.lerp(color_warn_low, t * 3.0)
	elif t <= 2.0 / 3.0:
		return color_warn_low.lerp(color_warn_high, (t - 1.0 / 3.0) * 3.0)
	else:
		return color_warn_high.lerp(color_critical, (t - 2.0 / 3.0) * 3.0)


# Single call so all three rings redraw together off one set of numbers,
# rather than three separate setters each triggering their own redraw.
func update_ratios(shields_ratio: float, armor_ratio: float, life_ratio: float) -> void:
	_shields_ratio = clamp(shields_ratio, 0.0, 1.0)
	_armor_ratio = clamp(armor_ratio, 0.0, 1.0)
	_life_ratio = clamp(life_ratio, 0.0, 1.0)
	queue_redraw()

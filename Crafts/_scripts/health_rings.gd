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
# Extremely muted identity tint per pool, only while the ring is healthy; the warning ramp takes over as it drains.
@export var life_tint: Color = Color(0.45, 0.85, 0.5)
@export var armor_tint: Color = Color(0.6, 0.6, 0.6)
@export var shields_tint: Color = Color(0.45, 0.65, 1.0)
@export_range(0.0, 1.0) var tint_strength: float = 0.3
# Seconds the ring stays brightened after its pool takes damage.
@export var hit_flash_time: float = 0.15
@export_range(0.0, 1.0) var texture_strength: float = 1.0
# Fill for the hole inside the innermost ring; transparent (the default) leaves it empty. The target info tile
# (target_tile.gd) darkens it behind the craft icon.
@export var center_fill: Color = Color(0, 0, 0, 0)
const RING_SHADER := preload("res://Materials/Shaders/health_rings.gdshader")

var _life_ratio: float = 1.0
var _armor_ratio: float = 1.0
var _shields_ratio: float = 1.0

# Digital readout of the three values in the middle of the rings, stacked in the same order as the rings
# (shields on top = outermost ring, then armor, then life). Each number warms up with its own ring.
# -1 = no value given yet, nothing is drawn.
const READOUT_FONT := preload("res://UI/fonts/Orbitron.ttf")
@export var show_readout: bool = true
@export var readout_font_size: int = 16
# Distance between the three lines, in px. The middle line sits on the ring center.
@export var readout_line_gap: float = 20.0
@export var readout_shadow: Color = Color(0, 0, 0, 0.85)
var _shields_value: float = -1.0
var _armor_value: float = -1.0
var _life_value: float = -1.0
# Hit flash per pool, 1 right after damage and fading to 0.
var _life_flash: float = 0.0
var _armor_flash: float = 0.0
var _shields_flash: float = 0.0
# Child that runs the ring shader. It draws over this node's own _draw (the readout), but the middle is transparent.
var _ring_rect: ColorRect
var _ring_mat: ShaderMaterial

# Fixed start point (top, sweeping clockwise) rather than derived from any
# art - there's no baked shape here to match, so this is just a style choice.


func _ready() -> void:
	_ring_mat = ShaderMaterial.new()
	_ring_mat.shader = RING_SHADER
	_ring_rect = ColorRect.new()
	_ring_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ring_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_rect.material = _ring_mat
	add_child(_ring_rect)
	resized.connect(_push_shader)
	_push_shader()
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	var step := delta / maxf(hit_flash_time, 0.001)
	_life_flash = maxf(_life_flash - step, 0.0)
	_armor_flash = maxf(_armor_flash - step, 0.0)
	_shields_flash = maxf(_shields_flash - step, 0.0)
	if _life_flash + _armor_flash + _shields_flash <= 0.0:
		set_process(false)
	_push_shader()


# The rings themselves are drawn by the shader; only the readout is drawn here.
func _draw() -> void:
	if show_readout:
		_draw_readout()


# Hands the shader the rings this match has (a pool the host switched off doesn't exist: no ring, no number -
# NetworkManager.shields_enabled/armor_enabled). They share the whole band the three-ring layout would have
# covered, so a life-only match gets one wide ring and no gap.
func _push_shader() -> void:
	if _ring_mat == null:
		return
	var ratios := PackedFloat32Array([_life_ratio, 0.0, 0.0])
	var colors := PackedColorArray([_ring_color(_life_ratio, life_tint), Color.WHITE, Color.WHITE])
	var kinds := PackedInt32Array([0, 1, 2])
	var flashes := PackedFloat32Array([_life_flash, 0.0, 0.0])
	var n := 1
	if NetworkManager.armor_enabled:
		ratios[n] = _armor_ratio
		colors[n] = _ring_color(_armor_ratio, armor_tint)
		kinds[n] = 1
		flashes[n] = _armor_flash
		n += 1
	if NetworkManager.shields_enabled:
		ratios[n] = _shields_ratio
		colors[n] = _ring_color(_shields_ratio, shields_tint)
		kinds[n] = 2
		flashes[n] = _shields_flash
		n += 1
	_ring_mat.set_shader_parameter("rect_size", size)
	_ring_mat.set_shader_parameter("vertical_stretch", vertical_stretch)
	_ring_mat.set_shader_parameter("band_inner", life_radius - ring_thickness / 2.0)
	_ring_mat.set_shader_parameter("band_outer", shields_radius + ring_thickness / 2.0)
	_ring_mat.set_shader_parameter("ring_count", n)
	_ring_mat.set_shader_parameter("track_color", track_color)
	_ring_mat.set_shader_parameter("texture_strength", texture_strength)
	_ring_mat.set_shader_parameter("center_fill", center_fill)
	_ring_mat.set_shader_parameter("ratios", ratios)
	_ring_mat.set_shader_parameter("colors", colors)
	_ring_mat.set_shader_parameter("kinds", kinds)
	_ring_mat.set_shader_parameter("flashes", flashes)


# Warning color for the ratio, with the pool's tint mixed in. The tint fades out as the ring drains so the
# yellow/orange/red warning stays unmistakable.
func _ring_color(ratio: float, tint: Color) -> Color:
	var weight := tint_strength * clampf(ratio / maxf(ramp_start_ratio, 0.001), 0.0, 1.0)
	return _color_for_ratio(ratio).lerp(tint, weight)


func _draw_readout() -> void:
	# Only the pools this match has, kept centred on the ring: three lines, two, or just life.
	var lines: Array = []
	if NetworkManager.shields_enabled:
		lines.append([_shields_value, _shields_ratio])
	if NetworkManager.armor_enabled:
		lines.append([_armor_value, _armor_ratio])
	lines.append([_life_value, _life_ratio])
	for i in lines.size():
		_draw_value(lines[i][0], lines[i][1], (i - (lines.size() - 1) / 2.0) * readout_line_gap)


# One centered number, `y_offset` px above/below the ring center. Not stretched like the rings (this is
# drawn with the identity transform), so the digits keep their proportions.
func _draw_value(value: float, ratio: float, y_offset: float) -> void:
	if value < 0.0:
		return
	var text := str(ceili(value))
	var width := 80.0
	# Digits sit between the baseline and about 0.72 em above it, so drop the baseline by half of that to
	# center them on the line.
	var baseline := size.y / 2.0 + y_offset + readout_font_size * 0.36
	var x := size.x / 2.0 - width / 2.0
	draw_string(READOUT_FONT, Vector2(x + 1.0, baseline + 1.0), text, HORIZONTAL_ALIGNMENT_CENTER, width, readout_font_size, readout_shadow)
	draw_string(READOUT_FONT, Vector2(x, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, width, readout_font_size, _color_for_ratio(ratio))


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
func update_ratios(shields_ratio: float, armor_ratio: float, life_ratio: float, shields: float = -1.0, armor: float = -1.0, life: float = -1.0) -> void:
	# A pool that dropped since the last call was hit: flash its ring.
	if _life_value >= 0.0 and life >= 0.0 and life < _life_value:
		_life_flash = 1.0
	if _armor_value >= 0.0 and armor >= 0.0 and armor < _armor_value:
		_armor_flash = 1.0
	if _shields_value >= 0.0 and shields >= 0.0 and shields < _shields_value:
		_shields_flash = 1.0
	_shields_ratio = clamp(shields_ratio, 0.0, 1.0)
	_armor_ratio = clamp(armor_ratio, 0.0, 1.0)
	_life_ratio = clamp(life_ratio, 0.0, 1.0)
	_shields_value = shields
	_armor_value = armor
	_life_value = life
	if _life_flash + _armor_flash + _shields_flash > 0.0:
		set_process(true)
	_push_shader()
	queue_redraw()

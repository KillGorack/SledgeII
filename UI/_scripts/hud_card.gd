@tool
extends PanelContainer

# The menu's card: a PanelContainer that draws a few accents over its theme panel. The theme cuts the top-right
# and bottom-left corners; this adds brackets on the two square corners, a bright bar on the top edge and a
# short row of ticks along the bottom.

@export var accent := Color(0.27, 0.88, 1.0):
	set(value):
		accent = value
		queue_redraw()
@export var bracket := 16.0:
	set(value):
		bracket = value
		queue_redraw()
@export var show_ticks := true:
	set(value):
		show_ticks = value
		queue_redraw()


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	var bright := accent
	var soft := Color(accent, 0.35)
	# Top-left bracket and the bar beside it.
	draw_rect(Rect2(0, 0, bracket, 2), bright)
	draw_rect(Rect2(0, 0, 2, bracket), bright)
	draw_rect(Rect2(bracket + 6, 0, minf(72.0, w * 0.2), 2), soft)
	# Bottom-right bracket.
	draw_rect(Rect2(w - bracket, h - 2, bracket, 2), bright)
	draw_rect(Rect2(w - 2, h - bracket, 2, bracket), bright)
	if show_ticks:
		for i in 5:
			draw_rect(Rect2(w - bracket - 12.0 - i * 7.0, h - 2, 3, 2), Color(accent, 0.45 - i * 0.07))

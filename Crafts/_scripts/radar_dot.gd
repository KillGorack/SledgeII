extends Control
class_name RadarDot

# Procedural circle instead of a plain ColorRect - the "round dot" ask for the
# radar's self marker doesn't need an actual texture asset, just draw_circle().
@export var dot_color: Color = Color.WHITE:
	set(value):
		dot_color = value
		queue_redraw()


func _draw() -> void:
	draw_circle(size / 2.0, size.x / 2.0, dot_color)

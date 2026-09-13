extends Control

@export var background_color: Color = Color(1, 1, 1, 0.18)
@export var fill_color: Color = Color(0.4, 0.9, 1.0, 1.0)

var current_ratio: float = 1.0

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), background_color)
	if current_ratio > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * current_ratio, size.y)), fill_color)

func set_juice_ratio(ratio: float) -> void:
	current_ratio = clamp(ratio, 0.0, 1.0)
	queue_redraw()

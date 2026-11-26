extends Control

# Highlight on the radar blip of the craft picked with cycle_teamies / cycle_enemies (see target_selector.gd):
# four corner brackets just outside the blip. Added/removed by radar_controller.gd::_update_select_mark.

const PAD := 3.0
const LEN := 3.0


func _draw() -> void:
	var rect := Rect2(Vector2(-PAD, -PAD), size + Vector2(PAD, PAD) * 2.0)
	for sx in [0.0, 1.0]:
		for sy in [0.0, 1.0]:
			var corner := rect.position + Vector2(rect.size.x * sx, rect.size.y * sy)
			var dx := Vector2(LEN if sx == 0.0 else -LEN, 0.0)
			var dy := Vector2(0.0, LEN if sy == 0.0 else -LEN)
			draw_line(corner, corner + dx, Color.WHITE, 1.0)
			draw_line(corner, corner + dy, Color.WHITE, 1.0)

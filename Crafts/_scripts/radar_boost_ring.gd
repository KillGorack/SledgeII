extends Control

# A ring drawn round a radar blip: "this craft has weapon boosts running".
# radar_controller.gd adds/removes it as a child of the blip.

const RING_COLOR := Color(1.0, 0.85, 0.25, 0.95)


func _draw() -> void:
	var parent_control := get_parent() as Control
	if parent_control == null:
		return
	var centre := parent_control.size / 2.0
	var radius := maxf(parent_control.size.x, parent_control.size.y) / 2.0 + 3.0
	draw_arc(centre, radius, 0.0, TAU, 20, RING_COLOR, 1.5, true)

extends Node3D
class_name BaseGun

# Movement/timing only - the actual capture-beam/particle look lives on
# Capture_Effect's own children (see set_effect_active) and is expected to
# get built out further; this just turns whatever's there on and off at the
# right moments.

const ASCEND_HEIGHT := 5.0
const HOVER_HEIGHT_ABOVE_RECON := 2.0
const CAPTURE_DURATION := 10.0
const TRAVEL_SPEED := 12.0  # units/sec, both horizontal and vertical legs

@onready var capture_effect: Node3D = $Capture_Effect

# Server sets this true the moment a request is accepted (see match.gd) and
# clears it once the whole round trip (there, hold, back) finishes - a busy
# gun isn't offered for a second, different capture in the meantime.
var is_busy: bool = false

var _rest_position: Vector3


func _ready() -> void:
	_rest_position = global_position


func set_effect_active(active: bool) -> void:
	capture_effect.visible = active
	for child in capture_effect.get_children():
		if child is GPUParticles3D:
			child.emitting = active


# Runs identically on every peer (called from match.gd's broadcast RPC, not
# locally decided) - flies out to hover over `recon`, holds there with the
# effect on for CAPTURE_DURATION, calls on_capture_ready (this is where the
# caller should actually apply the color change - while the gun's still
# there, not after it's already flown home), then reverses the whole path
# back to rest.
func begin_capture(recon: Node3D, on_capture_ready: Callable) -> void:
	is_busy = true
	var cruise_y := _rest_position.y + ASCEND_HEIGHT
	var above_base := Vector3(_rest_position.x, cruise_y, _rest_position.z)
	var above_recon := Vector3(recon.global_position.x, cruise_y, recon.global_position.z)
	var hover_position := Vector3(recon.global_position.x, recon.global_position.y + HOVER_HEIGHT_ABOVE_RECON, recon.global_position.z)

	await _move_to(above_base)
	await _move_to(above_recon)
	await _move_to(hover_position)

	set_effect_active(true)
	await get_tree().create_timer(CAPTURE_DURATION).timeout
	set_effect_active(false)
	on_capture_ready.call()

	await _move_to(above_recon)
	await _move_to(above_base)
	await _move_to(_rest_position)
	is_busy = false


func _move_to(target: Vector3) -> void:
	var distance := global_position.distance_to(target)
	if distance < 0.01:
		return
	var tween := create_tween()
	tween.tween_property(self, "global_position", target, distance / TRAVEL_SPEED)
	await tween.finished

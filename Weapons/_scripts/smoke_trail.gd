class_name SmokeTrail extends GPUParticles3D

# Deliberately never parented under the thing it trails (see
# collision_handler.gd::_spawn_smoke_trail and smoke_trail_prefab's comment
# in weapon_settings.gd) - a GPUParticles3D child only sees its parent's raw,
# stepped replicated transform, which turns a trail into clumped, jumping
# puffs instead of a smooth line. Sampling get_global_transform_interpolated()
# here every frame, exactly like Trail3D.gd does for its own mesh, sidesteps
# that entirely regardless of how coarse network replication is.

var _target: Node3D


func follow(target: Node3D) -> void:
	_target = target
	global_position = target.get_global_transform_interpolated().origin
	emitting = true


func _process(_delta: float) -> void:
	if _target and is_instance_valid(_target):
		global_position = _target.get_global_transform_interpolated().origin
		return
	if emitting:
		emitting = false
		get_tree().create_timer(lifetime + preprocess).timeout.connect(queue_free)

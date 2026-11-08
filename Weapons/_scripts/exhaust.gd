class_name ProjectileExhaust extends Node3D

# Root of a weapon's exhaust scene (WeaponSettings.exhaust_prefab). Put any
# number of GPUParticles3D (smoke, sparks, glow...) under it to combine
# effects - they all share this root's follow/fade handling, and each child
# keeps its own local offset from the root, so move a child to move that
# effect relative to the projectile.
#
# Deliberately never parented under the thing it trails (see
# collision_handler.gd::_spawn_exhaust and exhaust_prefab's comment in
# weapon_settings.gd) - a GPUParticles3D child only sees its parent's raw,
# stepped replicated transform, which turns a trail into clumped, jumping
# puffs instead of a smooth line. Sampling get_global_transform_interpolated()
# here every frame, exactly like Trail3D.gd does for its own mesh, sidesteps
# that entirely regardless of how coarse network replication is.

var _target: Node3D
var _finished: bool = false


func _ready() -> void:
	# This node is moved every render frame to the target's ALREADY-interpolated
	# transform (below), so the engine must not interpolate it a second time: that
	# lags it behind the projectile by a fraction of a physics tick that changes
	# with the render/physics phase - the trail then wobbles intermittently.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Spinners inside it still rotate in _physics_process and want their own
	# smoothing between ticks (75 rad/s is over half a radian per tick).
	for node in find_children("*", "Node3D", true, false):
		if "spin_speed" in node:
			node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON


# Multiplies the colour of every particle system under this exhaust (smoke has
# a fixed grey ramp and nothing else tints it). Each system gets its own copy
# of its material, so the shared scene file is never touched. See
# WeaponSettings.exhaust_color.
func tint_particles(color: Color) -> void:
	for node in find_children("*", "GPUParticles3D", true, false):
		var material := (node as GPUParticles3D).process_material as ParticleProcessMaterial
		if material:
			material = material.duplicate()
			material.color = color
			(node as GPUParticles3D).process_material = material


func follow(target: Node3D) -> void:
	_target = target
	global_transform = target.get_global_transform_interpolated()
	_set_emitting(true)


func _process(_delta: float) -> void:
	if _target and is_instance_valid(_target):
		global_transform = _target.get_global_transform_interpolated()
		return
	if _finished:
		return
	_finished = true
	_set_emitting(false)
	get_tree().create_timer(_longest_fade()).timeout.connect(queue_free)


# Same job as collision_handler.gd::_clear_trails, for ribbons that live in
# the exhaust instead of under the projectile.
func clear_trails() -> void:
	for child in find_children("*", "Trail3D", true, false):
		child.clear_trail()


func _set_emitting(value: bool) -> void:
	for child in find_children("*", "GPUParticles3D", true, false):
		child.emitting = value


func _longest_fade() -> float:
	var longest := 0.0
	for child in find_children("*", "GPUParticles3D", true, false):
		longest = maxf(longest, child.lifetime + child.preprocess)
	for child in find_children("*", "Trail3D", true, false):
		longest = maxf(longest, child._lifeSpan)
	return longest

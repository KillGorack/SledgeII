extends Node3D


@export var stats: CraftStats
@export var team: String = "team_a"

const SELF_RENDER_LAYER := 20

var engine_audio: AudioStreamPlayer
var target_pitch = 2.0
var target_volume = -30.0
var ui_pitch: float = 1
var pitch_transition_speed = 5.0
var volume_transition_speed = 5.0

var rotational_velocity_set_to_zero = false
var isGrounded: bool = false
var current_turn_speed = 0.0
var body: RigidBody3D
var stop_forces = false
var _knockback_until_msec: int = 0
@onready var ground_check_area = $"../FloorDetection"
@onready var engine_audio_path = $"../Engine Sound"

# Turret variables
var yaw = 0.0
var pitch = 0.0
var recentering = false
@onready var barrel = $"../Turret/Barrel"
@onready var turret = $"../Turret"


func _ready() -> void:
	var node = get_parent()
	while node and not node is RigidBody3D:
		node = node.get_parent()
	body = node
	if body == null:
		return
	Utilities.set_allegiance(body, team)
	engine_audio = engine_audio_path as AudioStreamPlayer
	# Turret setup
	yaw = get_node("../Turret").rotation_degrees.y if has_node("../Turret") else 0.0
	pitch = barrel.rotation_degrees.x if barrel else 0.0
	if is_multiplayer_authority():
		_hide_own_body()


func setFreezeState(frozen: bool) -> void:
	stop_forces = frozen


# Called from health_node when an external hit lands (repulsor and friends).
# move_player() below hard-sets linear velocity to max_speed on every physics
# tick while grounded, so without a stand-off window any knockback is erased
# on the very next tick - a 310 impulse on this 5kg hull is a 62 m/s shove
# clamped straight back down to 4. The normal deceleration force still runs
# during the window, so the craft slides and settles rather than skating.
func apply_knockback_grace(duration: float = 1.5) -> void:
	_knockback_until_msec = max(_knockback_until_msec, Time.get_ticks_msec() + int(duration * 1000.0))


func _is_knockback_active() -> bool:
	return Time.get_ticks_msec() < _knockback_until_msec


# Every spawned craft is the same scene, so this can't be a static layer
# baked into the .tscn - that would hide EVERY craft's body from EVERY
# camera. Instead, only the locally-authoritative instance moves its own
# meshes onto a reserved layer. The one persistent camera each client owns
# (see Networking/match.gd) permanently excludes this layer, so whichever
# craft is currently locally-owned always has its own body hidden from it -
# camera setup itself no longer lives here at all, see match.gd.
func _hide_own_body() -> void:
	var self_layer_bit := 1 << (SELF_RENDER_LAYER - 1)
	for mesh in _find_mesh_instances(body):
		mesh.layers = self_layer_bit


func _find_mesh_instances(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		if child is MeshInstance3D:
			result.append(child)
		result += _find_mesh_instances(child)
	return result


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if stop_forces or stats == null:
		return
	if not target_pitch:
		target_pitch = stats.target_audio_pitch
	var forward_input = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	var turn_input = Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")
	isGrounded = ground_check_area.get_overlapping_bodies().size() > 0

	# Turret movement
	handle_turret_barrel_look()
	if Input.is_action_just_pressed("ui_recenter"):
		recentering = true
	if recentering:
		recenter_turret_barrel()

	if Input.is_action_pressed("unturtle"):
		activate_thrusters(delta)
	else:
		if is_right_side_up() and isGrounded:
			rotational_velocity_set_to_zero = false
			adjust_rotation(turn_input, delta)
			move_player(forward_input)
	if rotational_velocity_set_to_zero:
		body.set_angular_velocity(body.get_angular_velocity() * 0.99)
	update_engine_sound()


func handle_turret_barrel_look():
	if not recentering:
		var look_x = Input.get_action_strength("camera_left") - Input.get_action_strength("camera_right")
		var look_y = Input.get_action_strength("camera_down") - Input.get_action_strength("camera_up")
		var sensitivity = stats.look_sensitivity
		if Input.is_action_pressed("ui_shift"):
			sensitivity *= stats.fine_aim_multiplier
		yaw += look_x * sensitivity
		pitch -= look_y * sensitivity
		yaw = clamp(yaw, -90, 90)
		pitch = clamp(pitch, -90, 90)
		if has_node("../Turret"):
			get_node("../Turret").rotation_degrees.y = yaw
		if barrel:
			barrel.rotation_degrees.x = pitch

func recenter_turret_barrel():
	var target_yaw = 0.0
	target_pitch = 0.0
	yaw = lerp(yaw, target_yaw, stats.recenter_speed * get_process_delta_time())
	pitch = lerp(pitch, target_pitch, stats.recenter_speed * get_process_delta_time())
	if abs(yaw) < 0.1 and abs(pitch) < 0.1:
		yaw = target_yaw
		pitch = target_pitch
		recentering = false
	if has_node("../Turret"):
		get_node("../Turret").rotation_degrees.y = yaw
	if barrel:
		barrel.rotation_degrees.x = pitch



func adjust_rotation(turn_input, delta):
	if stop_forces:
		return
	var rate = stats.turn_acceleration if turn_input != 0 else stats.turn_deceleration
	current_turn_speed = move_toward(
		current_turn_speed,
		turn_input * stats.turn_speed,
		rate * delta
	)
	var angular_velocity = body.angular_velocity
	angular_velocity.y = current_turn_speed
	body.angular_velocity = angular_velocity



func move_player(forward_input):
	if stop_forces:
		return
	var direction = body.transform.basis.z
	if forward_input != 0:
		var force = direction * forward_input * stats.acceleration
		body.apply_central_force(force)
	else:
		var current_velocity = body.get_linear_velocity()
		var deceleration_force = -current_velocity * stats.deceleration
		body.apply_central_force(deceleration_force)
	if isGrounded and not _is_knockback_active():
		var clamped_velocity = body.get_linear_velocity().limit_length(stats.max_speed)
		body.set_linear_velocity(clamped_velocity)



func update_engine_sound():
	if engine_audio:
		var speed : float = body.get_linear_velocity().length()
		if isGrounded:
			target_pitch = clamp(2.0 + speed / max(stats.max_speed, 1.0) * 2.0, 2.0, 4.0) * ui_pitch
			target_volume = clamp(-20 + 10 * (speed / max(stats.max_speed, 1.0)), -60.0, -20.0)
		else:
			target_pitch = 2.0 * ui_pitch
			target_volume = -20.0
		engine_audio.pitch_scale = lerp(engine_audio.pitch_scale, target_pitch, pitch_transition_speed * get_process_delta_time())
		engine_audio.volume_db = lerp(engine_audio.volume_db, target_volume, volume_transition_speed * get_process_delta_time())


func activate_thrusters(delta):
	body.apply_central_force(Vector3.UP * stats.thruster_force)
	var current_up = body.transform.basis.y
	var target_up = Vector3.UP
	var rotation_axis = current_up.cross(target_up).normalized()
	var angle_diff = acos(current_up.dot(target_up))
	if angle_diff > 0.1:
		var torque = rotation_axis * min(stats.rotation_speed * delta, angle_diff)
		body.apply_torque_impulse(torque)
	else:
		rotational_velocity_set_to_zero = true


func is_right_side_up() -> bool:
	return body.transform.basis.y.dot(Vector3.UP) > stats.right_side_up_threshold

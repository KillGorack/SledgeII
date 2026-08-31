extends Node3D


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
@onready var ground_check_area = $"../GroundCheck"
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
	Utilities.set_allegiance(body, "Player")
	engine_audio = engine_audio_path as AudioStreamPlayer
	# Turret setup
	yaw = get_node("../Turret").rotation_degrees.y if has_node("../Turret") else 0.0
	pitch = barrel.rotation_degrees.x if barrel else 0.0






func _physics_process(delta: float) -> void:

	if stop_forces:
		return	
	if not target_pitch:
		target_pitch = UserData.UserSettings["Craft"].target_audio_pitch
	var forward_input = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	var turn_input = Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")
	isGrounded = ground_check_area.get_overlapping_bodies().size() > 0

	# Turret movement
	if UserData.UserSettings["Craft"] != null:
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
		var sensitivity = UserData.UserSettings["Craft"].look_sensitivity
		if Input.is_action_pressed("ui_shift"):
			sensitivity *= UserData.UserSettings["Craft"].fine_aim_multiplier
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
	yaw = lerp(yaw, target_yaw, UserData.UserSettings["Craft"].recenter_speed * get_process_delta_time())
	pitch = lerp(pitch, target_pitch, UserData.UserSettings["Craft"].recenter_speed * get_process_delta_time())
	if abs(yaw) < 0.1 and abs(pitch) < 0.1:
		yaw = target_yaw
		pitch = target_pitch
		recentering = false
	if has_node("../Turret"):
		get_node("../Turret").rotation_degrees.y = yaw
	if barrel:
		barrel.rotation_degrees.x = pitch



func adjust_rotation(turn_input, delta):
	if not UserData.UserSettings["Craft"] || stop_forces:
		return
	current_turn_speed = move_toward(
		current_turn_speed,
		turn_input * UserData.UserSettings["Craft"].turn_speed,
		UserData.UserSettings["Craft"].turn_acceleration * delta
	)
	var angular_velocity = body.angular_velocity
	angular_velocity.y = current_turn_speed
	body.angular_velocity = angular_velocity
	
	

func move_player(forward_input):
	if not UserData.UserSettings["Craft"] || stop_forces:
		return
	var direction = body.transform.basis.z
	if forward_input != 0:
		var force = direction * forward_input * UserData.UserSettings["Craft"].acceleration
		body.apply_central_force(force)
	else:
		var current_velocity = body.get_linear_velocity()
		var deceleration_force = -current_velocity * UserData.UserSettings["Craft"].deceleration
		body.apply_central_force(deceleration_force)
	if isGrounded:
		var clamped_velocity = body.get_linear_velocity().limit_length(UserData.UserSettings["Craft"].max_speed)
		body.set_linear_velocity(clamped_velocity)



func update_engine_sound():
	if engine_audio && UserData.UserSettings["Craft"]:
		var speed : float = body.get_linear_velocity().length()
		if isGrounded:
			target_pitch = clamp(2.0 + speed / max(UserData.UserSettings["Craft"].max_speed, 1.0) * 2.0, 2.0, 4.0) * ui_pitch
			target_volume = clamp(-20 + 10 * (speed / max(UserData.UserSettings["Craft"].max_speed, 1.0)), -60.0, -20.0)
		else:
			target_pitch = 2.0 * ui_pitch
			target_volume = -20.0
		engine_audio.pitch_scale = lerp(engine_audio.pitch_scale, target_pitch, pitch_transition_speed * get_process_delta_time())
		engine_audio.volume_db = lerp(engine_audio.volume_db, target_volume, volume_transition_speed * get_process_delta_time())


func activate_thrusters(delta):
	body.apply_central_force(Vector3.UP * UserData.UserSettings["Craft"].thruster_force)
	var current_up = body.transform.basis.y
	var target_up = Vector3.UP
	var rotation_axis = current_up.cross(target_up).normalized()
	var angle_diff = acos(current_up.dot(target_up))
	if angle_diff > 0.1:
		var torque = rotation_axis * min(UserData.UserSettings["Craft"].rotation_speed * delta, angle_diff)
		body.apply_torque_impulse(torque)
	else:
		rotational_velocity_set_to_zero = true
		

func is_right_side_up() -> bool:
	if UserData.UserSettings["Craft"] == null:
		return false
	return body.transform.basis.y.dot(Vector3.UP) > UserData.UserSettings["Craft"].right_side_up_threshold

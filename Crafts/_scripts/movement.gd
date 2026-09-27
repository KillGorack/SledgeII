extends Node3D


@export var stats: CraftStats
@export var team: String = "team_red"

const SELF_RENDER_LAYER := 20
const FALL_DAMAGE_RAY_LENGTH := 5.0
@export var SUSPENSION_RAY_LENGTH := 0.04
@export var SUSPENSION_SPRING_STRENGTH := 7000.0
@export var SUSPENSION_DAMPING := 100.0
const LATERAL_GRIP_STRENGTH := 10.0
const LONGITUDINAL_GRIP_STRENGTH := 2.0

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
var _airborne_velocity: Vector3 = Vector3.ZERO

@onready var engine_audio_path = $"../Engine Sound"
@onready var suspension_rays: Array[RayCast3D] = []
@onready var ground_check_area = $"../FloorDetection"

var yaw = 0.0
var pitch = 0.0
var recentering = false
@onready var barrel = $"../Turret/Barrel"
@onready var turret = $"../Turret"
@onready var chat: Control = get_node("../Hud_InGame/Chat")


func _ready() -> void:
	var node = get_parent()
	while node and not node is RigidBody3D:
		node = node.get_parent()
	body = node
	if body == null:
		return
	Utilities.set_allegiance(body, team)
	body.angular_damp = 0.0
	engine_audio = engine_audio_path as AudioStreamPlayer
	if has_node("../Suspension"):
		for ray in get_node("../Suspension").get_children():
			if ray is RayCast3D:
				suspension_rays.append(ray)
	yaw = get_node("../Turret").rotation_degrees.y if has_node("../Turret") else 0.0
	pitch = barrel.rotation_degrees.x if barrel else 0.0
	if is_multiplayer_authority():
		_hide_own_body()





func setFreezeState(frozen: bool) -> void:
	stop_forces = frozen





func get_speed_ratio() -> float:
	if body == null or stats == null or stats.max_speed <= 0.0:
		return 0.0
	return clamp(body.linear_velocity.length() / stats.max_speed, 0.0, 1.0)





func _handle_landing() -> void:
	var health_node = get_node_or_null("../health_node")
	if health_node == null or not health_node.has_method("request_fall_damage"):
		return
	var space_state := body.get_world_3d().direct_space_state
	var origin := body.global_position
	var query := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * FALL_DAMAGE_RAY_LENGTH)
	query.collision_mask = 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)
	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return
	var impact_speed = max(0.0, -_airborne_velocity.dot(result.normal))
	if impact_speed <= 0.0:
		return
	# One path, not two - this used to branch (direct local call if already
	# the server, rpc_id() otherwise), almost certainly because rpc_id(1,...)
	# used to be a no-op when the caller's own peer id is 1 (i.e. whenever
	# the HOST owns the landing craft) without call_local on
	# request_fall_damage's own @rpc annotation. Now that it has call_local,
	# a single rpc_id() call is correct either way - no reason for two
	# different code paths to stay in sync for what's supposed to be one
	# event.
	health_node.request_fall_damage.rpc_id(1, impact_speed)





func apply_knockback_grace(duration: float = 1.5) -> void:
	_knockback_until_msec = max(_knockback_until_msec, Time.get_ticks_msec() + int(duration * 1000.0))





func _is_knockback_active() -> bool:
	return Time.get_ticks_msec() < _knockback_until_msec






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
	var health_node = body.get_node_or_null("health_node")
	if health_node and health_node.has_method("_is_destroyed"):
		if health_node._is_destroyed:
			return
	if stop_forces or stats == null:
		return
	if not target_pitch:
		target_pitch = stats.target_audio_pitch
	# While chatting, arrow keys/WASD/etc. are being typed, not driving the
	# craft - see chat_controller.gd::is_open. Physics below (suspension,
	# grounding, landing, engine sound) still runs as normal either way; only
	# the actual input reads freeze, so a chatting player still falls/lands
	# normally instead of the craft just stopping dead.
	var chatting: bool = chat.is_open
	var forward_input = 0.0
	var turn_input = 0.0
	if not chatting:
		forward_input = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
		turn_input = Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")
	var was_grounded := isGrounded
	isGrounded = ground_check_area.get_overlapping_bodies().size() > 0
	if isGrounded and not was_grounded:
		_handle_landing()
	elif not isGrounded:
		_airborne_velocity = body.linear_velocity
	_apply_suspension_forces(forward_input)
	if not chatting:
		handle_turret_barrel_look()
		if Input.is_action_just_pressed("ui_recenter"):
			recentering = true
	if recentering:
		recenter_turret_barrel()
	if not chatting and Input.is_action_pressed("unturtle"):
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





func _apply_suspension_forces(forward_input: float) -> void:
	var right: Vector3 = body.global_transform.basis.x
	var forward: Vector3 = body.global_transform.basis.z
	var is_accelerating := not is_zero_approx(forward_input)
	for ray in suspension_rays:
		if not ray.is_colliding():
			continue
		var hit_point: Vector3 = ray.get_collision_point()
		var ray_up: Vector3 = ray.global_transform.basis.y
		var current_length := ray.global_position.distance_to(hit_point)
		var compression := SUSPENSION_RAY_LENGTH - current_length
		if compression <= 0.0:
			continue
		var offset: Vector3 = ray.global_position - body.global_position
		var point_velocity: Vector3 = body.linear_velocity + body.angular_velocity.cross(offset)
		var closing_speed := point_velocity.dot(ray_up)
		var force_magnitude := (compression * SUSPENSION_SPRING_STRENGTH) - (closing_speed * SUSPENSION_DAMPING)
		if force_magnitude > 0.0:
			body.apply_force(ray_up * force_magnitude, offset)
		var lateral_speed := point_velocity.dot(right)
		body.apply_force(-right * lateral_speed * LATERAL_GRIP_STRENGTH, offset)
		if not is_accelerating:
			var longitudinal_speed := point_velocity.dot(forward)
			body.apply_force(-forward * longitudinal_speed * LONGITUDINAL_GRIP_STRENGTH, offset)





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

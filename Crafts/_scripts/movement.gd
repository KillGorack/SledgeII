extends Node3D


@export var stats: CraftStats
@export var team: String = "team_red"

const SELF_RENDER_LAYER := 20
# Fall damage is worked out from how far the craft FELL, not from collision
# forces (which jitter): from the highest point reached since it last had
# contact with the world, to where it touches down. That distance becomes the
# speed an object dropped from that height would hit at (v = sqrt(2*g*d)),
# which feeds the existing fall_damage_* stats. Same result whichever way up
# the craft lands, and the same fall always costs the same.
# Airborne spells shorter than this are bumps over lips and ripples, not falls.
const FALL_MIN_AIR_MSEC := 120
# Rockets (R) lift the craft. They don't work when it is mostly upside down: 1 = upright,
# 0 = on its side, -1 = upside down.
const ROCKET_MIN_UP_DOT := -0.3
# Unturtling (left / right): an overturned craft that is on the ground and nearly stopped rolls
# toward the key pressed, and after a while rights itself so it is never stuck for good.
const UNTURTLE_SETTLED_SPEED := 1.0
const UNTURTLE_AUTO_MSEC := 4000
const UNTURTLE_TORQUE_MULT := 2.0
const UNTURTLE_LIFT_RATIO := 0.5 # of thruster_force: just enough to take weight off while it rolls
const THRUST_LOCK_MAX_MSEC := 4000
# A shove that never lifts the craft off the ground frees the thrusters again after this long.
const THRUST_LOCK_GROUNDED_MSEC := 500
# After being shoved (Repulsor and friends - see apply_knockback_grace) a
# landing this soon does no fall damage, so a craft thrown at a ramp keeps
# flying instead of being killed by the impact speed. Tune freely.
const KNOCKBACK_FALL_IMMUNITY := 0.5
@export var SUSPENSION_RAY_LENGTH := 0.04
@export var SUSPENSION_SPRING_STRENGTH := 7000.0
@export var SUSPENSION_DAMPING := 100.0
const LATERAL_GRIP_STRENGTH := 10.0
const LONGITUDINAL_GRIP_STRENGTH := 2.0
# Remote-copy snapshot interpolation (see _interpolate_remote). Remote craft
# are drawn INTERP_DELAY in the past, blending between the two real
# snapshots around that moment - ~3 snapshots deep at the root
# synchronizer's 30Hz, enough to ride out a late or lost packet without
# stalling. If the buffer runs dry anyway, extrapolate along the last known
# velocity for up to MAX_EXTRAPOLATION, then hold. Two snapshots further
# apart than NET_SNAP_DISTANCE are a teleport (respawn) - jump, never glide.
const INTERP_DELAY := 0.1
const MAX_EXTRAPOLATION := 0.25
const NET_SNAP_DISTANCE := 8.0
const SNAPSHOT_BUFFER_MAX := 32

var engine_audio: AudioStreamPlayer3D
var target_pitch = 3.0
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
var _fall_immune_until_msec: int = 0
var _airborne: bool = false
# Downward speed in the last airborne tick - what the craft actually hit the ground at.
var _last_air_down_speed: float = 0.0
# Thrusters are locked from a shove until the craft next touches down (or this runs out), so a
# Repulsor launch can't simply be rocketed out of. See _rockets_allowed.
var _thrust_locked: bool = false
var _stuck_since_msec: int = 0
var _thrust_lock_msec: int = 0
# Set while dead: the first touchdown after a respawn is just settling onto
# the pad, never a fall.
var _ignore_next_landing: bool = false
var _fall_peak_y: float = 0.0
var _air_start_msec: int = 0

@onready var engine_audio_path = $"../Engine Sound"
@onready var suspension_rays: Array[RayCast3D] = []
@onready var ground_check_area = $"../FloorDetection"

var yaw: float = 0.0
var pitch: float = 0.0
# The owner's craft state, packed into one replicated property (written by
# the owner every physics tick, sent ~30x/s by the root
# MultiplayerSynchronizer): [pos.xyz, rot quat.xyzw, velocity.xyz, yaw, pitch]
# in global space (the Crafts container sits at the origin on every peer).
# net_time is when it was sampled, on the shared server clock
# (NetworkManager.server_time) - kept as its own full-precision float,
# since float32 would lose milliseconds an hour into a match.
var net_state := PackedFloat32Array()
var net_time: float = 0.0
# Remote copies only: received snapshots, oldest first.
var _snapshots: Array[Dictionary] = []
# Remote copies only: last hard reset (spawn/respawn) - see _on_net_snapshot.
var _snap_time: float = -INF
var _snap_position := Vector3.ZERO
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
	if is_multiplayer_authority():
		# get_colliding_bodies() (impact detection) only works with this on.
		body.contact_monitor = true
		body.max_contacts_reported = 8
	engine_audio = engine_audio_path as AudioStreamPlayer3D
	if engine_audio and stats and stats.engine_sound:
		engine_audio.stream = stats.engine_sound
	if engine_audio and is_multiplayer_authority():
		engine_audio.pitch_scale = target_pitch
		engine_audio.volume_db = target_volume
		engine_audio.play()
	if has_node("../Suspension"):
		for ray in get_node("../Suspension").get_children():
			if ray is RayCast3D:
				suspension_rays.append(ray)
	yaw = get_node("../Turret").rotation_degrees.y if has_node("../Turret") else 0.0
	pitch = barrel.rotation_degrees.x if barrel else 0.0
	snap_net_target(body.global_transform)
	if is_multiplayer_authority():
		_hide_own_body()
	else:
		# Only the owner simulates this craft. Every other copy used to stay a
		# live dynamic body - falling under gravity between updates (nothing
		# but the owner runs suspension) and then being teleported back by the
		# next packet, which both jittered and, when it teleported into
		# another craft, resolved the overlap as a huge collision impulse.
		# Kinematic: still solid, still pushes the local player like a moving
		# platform would, but only ever moves where it's told.
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
		var root_sync := body.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
		if root_sync:
			root_sync.synchronized.connect(_on_net_snapshot)


# Hard reset of the remote snapshot buffer - initial spawn, and
# health_node.gd::respawn_at so a respawn never glides from the death spot.
func snap_net_target(target: Transform3D) -> void:
	_snap_time = NetworkManager.server_time()
	_snap_position = target.origin
	_snapshots.clear()
	# Back-dated so the owner's first real snapshots - sampled slightly
	# earlier than this moment, by their travel time - still sort after it
	# instead of being dropped as stale. Same position as those, so nothing
	# glides across the gap.
	_snapshots.append({
		"t": _snap_time - 1.0,
		"pos": target.origin,
		"rot": target.basis.get_rotation_quaternion(),
		"vel": Vector3.ZERO,
		"yaw": yaw,
		"pitch": pitch,
	})


# Owner only, every physics tick.
func _write_net_state() -> void:
	var p := body.global_position
	var q := body.global_basis.get_rotation_quaternion()
	var v := body.linear_velocity
	net_state = PackedFloat32Array([p.x, p.y, p.z, q.x, q.y, q.z, q.w, v.x, v.y, v.z, yaw, pitch])
	net_time = NetworkManager.server_time()


# Remote copies only - the root synchronizer just applied a fresh
# net_state/net_time from the owner.
func _on_net_snapshot() -> void:
	if net_state.size() < 12:
		return
	var snapshot := {
		"t": net_time,
		"pos": Vector3(net_state[0], net_state[1], net_state[2]),
		"rot": Quaternion(net_state[3], net_state[4], net_state[5], net_state[6]).normalized(),
		"vel": Vector3(net_state[7], net_state[8], net_state[9]),
		"yaw": net_state[10],
		"pitch": net_state[11],
	}
	# Duplicates and reordered stragglers - unreliable sync can do both.
	if not _snapshots.is_empty() and snapshot.t <= _snapshots.back().t:
		return
	# A pre-respawn snapshot still in flight when the respawn landed - it
	# would yank the craft back to where it died.
	if snapshot.t < _snap_time and snapshot.pos.distance_to(_snap_position) > NET_SNAP_DISTANCE:
		return
	_snapshots.append(snapshot)
	if _snapshots.size() > SNAPSHOT_BUFFER_MAX:
		_snapshots.pop_front()





func setFreezeState(frozen: bool) -> void:
	stop_forces = frozen





func get_speed_ratio() -> float:
	if body == null or stats == null or stats.max_speed <= 0.0:
		return 0.0
	return clamp(body.linear_velocity.length() / stats.max_speed, 0.0, 1.0)





func _track_fall() -> void:
	var now := Time.get_ticks_msec()
	var y := body.global_position.y
	if _has_world_contact():
		if _airborne:
			_airborne = false
			_thrust_locked = false
			_on_landed(_fall_peak_y - y, now - _air_start_msec)
		else:
			# Spawned already touching the pad: there is no landing to swallow.
			_ignore_next_landing = false
			if _thrust_locked and now - _thrust_lock_msec > THRUST_LOCK_GROUNDED_MSEC:
				_thrust_locked = false
	elif not _airborne:
		_airborne = true
		_fall_peak_y = y
		_air_start_msec = now
		_last_air_down_speed = maxf(0.0, -body.linear_velocity.y)
	else:
		_fall_peak_y = maxf(_fall_peak_y, y)
		_last_air_down_speed = maxf(0.0, -body.linear_velocity.y)


func _on_landed(fall_distance: float, air_msec: int) -> void:
	if _ignore_next_landing:
		_ignore_next_landing = false
		return
	if fall_distance <= 0.0 or air_msec < FALL_MIN_AIR_MSEC:
		return
	if Time.get_ticks_msec() < _fall_immune_until_msec:
		return
	var health_node = get_node_or_null("../health_node")
	if health_node == null or not health_node.has_method("request_fall_damage"):
		return
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	# The speed a drop from that height would reach - but never more than the speed the craft was actually
	# doing when it touched down, so a rocket-assisted or otherwise gentle landing from a great height is not
	# punished as if it were a free fall.
	var impact_speed := minf(sqrt(2.0 * gravity * fall_distance), _last_air_down_speed)
	if impact_speed <= 0.0:
		return
	# One path for host and clients: request_fall_damage is call_local, so
	# rpc_id(1, ...) also works when this peer IS the server.
	health_node.request_fall_damage.rpc_id(1, impact_speed)


# Any contact with the world counts - wheels, floor sensor, or a roof/side
# when upside down or tumbling.
func _has_world_contact() -> bool:
	if isGrounded or _touching_world():
		return true
	for ray in suspension_rays:
		if ray.is_colliding():
			return true
	return false


func _touching_world() -> bool:
	var world_bit: int = 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)
	for other in body.get_colliding_bodies():
		if other.collision_layer & world_bit:
			return true
	return false


func apply_knockback_grace(duration: float = 1.5) -> void:
	_thrust_locked = true
	_thrust_lock_msec = Time.get_ticks_msec()
	_fall_immune_until_msec = max(_fall_immune_until_msec, Time.get_ticks_msec() + int(KNOCKBACK_FALL_IMMUNITY * 1000.0))
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
		_interpolate_remote()
		return
	_write_net_state()
	var health_node = body.get_node_or_null("health_node")
	# _is_destroyed is a variable, not a method - has_method() on it is always
	# false, which silently disabled this whole guard.
	if health_node and "_is_destroyed" in health_node:
		if health_node._is_destroyed:
			# Whatever the corpse does (or the respawn teleport that follows)
			# must never count as a fall.
			_airborne = false
			_last_air_down_speed = 0.0
			_ignore_next_landing = true
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
	isGrounded = ground_check_area.get_overlapping_bodies().size() > 0
	_track_fall()
	_apply_suspension_forces(forward_input)
	if not chatting:
		handle_turret_barrel_look()
		if Input.is_action_just_pressed("ui_recenter"):
			recentering = true
	if recentering:
		recenter_turret_barrel()
	if not chatting and Input.is_action_pressed("rockets") and _rockets_allowed():
		activate_thrusters(delta)
	elif not _unturtle(turn_input, delta):
		if is_right_side_up() and isGrounded:
			rotational_velocity_set_to_zero = false
			adjust_rotation(turn_input, delta)
			move_player(forward_input)
	if rotational_velocity_set_to_zero:
		body.set_angular_velocity(body.get_angular_velocity() * 0.99)
	update_engine_sound()





# Remote copies only. Runs in _physics_process on purpose: transforms set
# here are what physics interpolation blends between, so the render stays
# smooth at any frame rate even though snapshots only arrive ~30x a second.
func _interpolate_remote() -> void:
	if body == null or _snapshots.is_empty() or not NetworkManager.is_clock_synced():
		return
	var render_time := NetworkManager.server_time() - INTERP_DELAY
	# Keep exactly one snapshot at or before render_time as the "from" side.
	while _snapshots.size() >= 2 and _snapshots[1].t <= render_time:
		_snapshots.pop_front()
	var from: Dictionary = _snapshots[0]
	var pos: Vector3 = from.pos
	var rot: Quaternion = from.rot
	var aim_yaw: float = from.yaw
	var aim_pitch: float = from.pitch
	if _snapshots.size() >= 2 and render_time > from.t:
		var to: Dictionary = _snapshots[1]
		var span: float = to.t - from.t
		if span > 0.0 and from.pos.distance_to(to.pos) <= NET_SNAP_DISTANCE:
			var f := clampf((render_time - from.t) / span, 0.0, 1.0)
			pos = _hermite(from.pos, from.vel, to.pos, to.vel, f, span)
			rot = from.rot.slerp(to.rot, f)
			aim_yaw = lerpf(from.yaw, to.yaw, f)
			aim_pitch = lerpf(from.pitch, to.pitch, f)
	elif render_time > from.t:
		# Buffer ran dry - a late/lost packet. Coast on the last velocity
		# briefly rather than freezing, then hold.
		pos = from.pos + from.vel * minf(render_time - from.t, MAX_EXTRAPOLATION)
	var teleported := body.global_position.distance_to(pos) > NET_SNAP_DISTANCE
	body.global_transform = Transform3D(Basis(rot), pos)
	if teleported:
		body.reset_physics_interpolation()
	if turret:
		turret.rotation_degrees.y = aim_yaw
	if barrel:
		barrel.rotation_degrees.x = aim_pitch


# Cubic Hermite between two snapshots, using each one's velocity as its
# tangent - follows the actual curve of a turning/accelerating craft instead
# of cutting straight corners between samples the way a plain lerp would.
func _hermite(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, f: float, span: float) -> Vector3:
	var f2 := f * f
	var f3 := f2 * f
	return (2.0 * f3 - 3.0 * f2 + 1.0) * p0 \
		+ (f3 - 2.0 * f2 + f) * span * v0 \
		+ (-2.0 * f3 + 3.0 * f2) * p1 \
		+ (f3 - f2) * span * v1


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





# Rockets are allowed when the host has them on, the craft isn't locked out after a shove, and it
# isn't mostly upside down.
func _rockets_allowed() -> bool:
	if not NetworkManager.rockets_enabled:
		return false
	if _thrust_locked and Time.get_ticks_msec() - _thrust_lock_msec < THRUST_LOCK_MAX_MSEC:
		return false
	return body.global_basis.y.dot(Vector3.UP) > ROCKET_MIN_UP_DOT


# Rolls an overturned craft back over. Returns true when the craft is in that state (so normal
# driving, which needs an upright craft, is skipped). Separate from the rockets on purpose: needs
# no rocket, no host rule, and isn't blocked by the post-shove lock.
func _unturtle(turn_input: float, delta: float) -> bool:
	if is_right_side_up() or not _has_world_contact():
		_stuck_since_msec = 0
		return false
	if body.linear_velocity.length() > UNTURTLE_SETTLED_SPEED:
		_stuck_since_msec = 0
		return true
	var now := Time.get_ticks_msec()
	if _stuck_since_msec == 0:
		_stuck_since_msec = now
	var direction := signf(turn_input)
	if direction == 0.0 and now - _stuck_since_msec > UNTURTLE_AUTO_MSEC:
		direction = 1.0
	if direction != 0.0:
		var roll_axis := -body.global_basis.z
		body.apply_torque_impulse(roll_axis * direction * stats.rotation_speed * UNTURTLE_TORQUE_MULT * delta)
		body.apply_central_force(Vector3.UP * stats.thruster_force * UNTURTLE_LIFT_RATIO)
	return true


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

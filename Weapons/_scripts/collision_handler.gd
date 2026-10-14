extends RigidBody3D

# Ported from the predecessor project's collisionHandler.gd. There, whichever
# client happened to be simulating a projectile called apply_damage()
# directly and locally - fine single-player, not safe for real multiplayer
# (clients could disagree on hits, or a modified client could deal extra
# damage). Here the server's copy is the only real one - its default
# multiplayer_authority is the server, and _physics_process/_integrate_forces
# below only do hit resolution when is_multiplayer_authority() is true.
#
# Nothing about a projectile is streamed per frame. Every peer spawns its
# own copy from one spawn event (match.gd::spawn_projectile /
# _spawn_projectile_event) and simulates it locally - straight, ballistic
# and guided flight are all predictable from launch state - and the server
# only speaks up again for the things a client can't predict: guided
# course changes and ricochets (corrections, see apply_correction) and the
# end of the projectile's life (end_cosmetic). Non-server copies are
# "cosmetic": frozen, collision-free, moved by _cosmetic_step.

var weapon_settings: WeaponSettings
# The .tres path weapon_settings came from - kept separately because a
# team-tinted shot's weapon_settings is a duplicate() (see
# match.gd::_create_volley), and a duplicate's own resource_path is empty.
var weapon_settings_path: String = ""
var team: String = "" # shooter's team, e.g. "team_red" - kept for reference
var allegiance_group: String = "" # projectile's own group, e.g. "projectile_team_red"

var collided_object: Object
var collision_point: Vector3
var collision_normal: Vector3
var damage_one_off: bool = false
var aoe_damage_one_off: bool = false
var current_direction: Vector3
var ricochet_count: int = 0
var bullet_hole_one_off: bool = false
var hit_scene_one_off: bool = false
var collided_layer: int = -1
var ignored_objects: Array = []
var guided_target: Node = null
var targeted_group: bool = false
var result = []
var distance_traveled: float = 0.0
var max_distance: float
# Only matters for weapon_settings.affected_by_gravity - the launch velocity
# gets set exactly once, on this projectile's first physics tick, then left
# alone so gravity_scale can curve it from there. See _physics_process().
var _ballistic_launched: bool = false

# Network identity, shared by every peer's copy of this one projectile - see
# match.gd's _projectiles registry. -1 until assigned (a shooter's own
# predicted shot gets its id when the server confirms it).
var net_id: int = -1
const GUIDED_CORRECTION_INTERVAL := 0.05
const CORRECTION_SNAP_DISTANCE := 5.0
const CORRECTION_BLEND_RATE := 15.0
# Cosmetic copies turn toward their own direction of travel at this rate
# (1/time-constant) instead of taking the server's facing verbatim - see
# _face_travel_direction.
const COSMETIC_TURN_RATE := 20.0
var _correction_elapsed := 0.0
var _destroying := false
# Cosmetic copies only.
var _cosmetic_velocity := Vector3.ZERO
var _position_error := Vector3.ZERO
var _cosmetic_ended := false
var _match_node: Node = null

@onready var raycast: RayCast3D = $RayCast3D


func _ready() -> void:
	_match_node = get_tree().get_first_node_in_group("match")
	if is_multiplayer_authority():
		contact_monitor = true
		max_contacts_reported = 5
	if team != "":
		allegiance_group = "projectile_" + team
		Utilities.set_allegiance(self, allegiance_group)
	if not is_multiplayer_authority():
		# Cosmetic copy - see the header comment. Frozen so the physics engine
		# never moves it (_cosmetic_step does), and collision-free so it can't
		# shove anything in this peer's own world: a solid mass-50 shell used
		# to physically knock the local player's craft around on their own
		# machine, on top of the server's real knockback.
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
		contact_monitor = false
		collision_layer = 0
		collision_mask = 0
		if weapon_settings:
			_cosmetic_velocity = -global_transform.basis.z.normalized() * weapon_settings.projectile_speed
	if weapon_settings:
		_apply_projectile_color(weapon_settings.projectile_color)
		_spawn_smoke_trail()


func _gravity() -> Vector3:
	var strength: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	return direction * strength * gravity_scale


func _world_mask() -> int:
	return 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)


# Advances a freshly spawned projectile `seconds` along its launch
# trajectory - latency compensation. The server advances its own copy by the
# shooter's one-way latency (the shot really left their barrel that long
# ago), and every other peer additionally by its own one-way latency (the
# spawn event took that long to get here) - see match.gd. Raycast first so a
# point-blank shot can't be skipped clean through a wall or a craft; it stops
# just short and lets the normal collision path take it from there.
func fast_forward(seconds: float) -> void:
	if seconds <= 0.0 or weapon_settings == null:
		return
	var velocity := -global_transform.basis.z.normalized() * weapon_settings.projectile_speed
	var gravity := _gravity() if weapon_settings.affected_by_gravity else Vector3.ZERO
	var start := global_position
	var end := start + velocity * seconds + 0.5 * gravity * seconds * seconds
	var query := PhysicsRayQueryParameters3D.create(start, end)
	query.collision_mask = collision_mask if is_multiplayer_authority() else _world_mask()
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var back_off: Vector3 = (end - start).normalized() * 0.2
		end = hit.position - back_off
		if (end - start).dot(velocity) < 0.0:
			end = start
	global_position = end
	distance_traveled += start.distance_to(end)
	var launch_velocity := velocity + gravity * seconds
	if is_multiplayer_authority():
		if weapon_settings.affected_by_gravity:
			linear_velocity = launch_velocity
			_ballistic_launched = true
	else:
		_cosmetic_velocity = launch_velocity
	reset_physics_interpolation()


# Runs identically on every peer - weapon_settings is assigned by
# match.gd::_create_volley before this node is added to the tree (same
# ordering apply_damage()/respawn_at() already rely on elsewhere), and every
# peer loads its own copy of the same weapon_settings.tres by path, so there
# is nothing here that needs authority gating or a network trip; it's exactly
# as local as the mesh and material this projectile scene already ships with.
#
# Deliberately duck-typed rather than reaching for named child paths: rocket,
# laser, plasma and shell are all different scene shapes (rocket has a
# tinted mesh, laser has none, plasma has a tinted sprite, shell's mesh
# stays its own Gun_Metal on purpose) sharing this one script, so it asks
# each descendant whether it knows how to color itself instead of assuming
# any particular one exists. See colorable_light.gd, colorable_mesh.gd,
# colorable_sprite.gd and Trail3D.gd::apply_projectile_color for the nodes
# that currently answer yes.
func _apply_projectile_color(color: Color) -> void:
	Utilities.apply_projectile_color_recursive(self, color)


# Added as a sibling under get_parent() (same parent explosion/bullet-hole
# effects use below), NOT as a child of this projectile - see
# smoke_trail_prefab's own comment in weapon_settings.gd for why a
# GPUParticles3D child would jitter with the replicated transform where
# Trail3D doesn't. follow() makes the trail sample this projectile's
# interpolated transform itself every frame instead, and keeps fading out
# on its own after this projectile is gone.
func _spawn_smoke_trail() -> void:
	if not weapon_settings.smoke_trail_prefab or not get_parent():
		return
	var trail_instance = weapon_settings.smoke_trail_prefab.instantiate()
	get_parent().add_child(trail_instance)
	trail_instance.follow(self)


# Same duck-typed walk as color above, for the same reason: rocket/laser/
# shell each carry a different number of Trail3D children (or none) under
# their own Spinner, so this doesn't assume any particular one exists.
# Called from handle_ricochet() - see clear_trail() in Trail3D.gd for why.
func _clear_trails() -> void:
	_clear_trails_on(self)


func _clear_trails_on(node: Node) -> void:
	if node is Trail3D:
		node.clear_trail()
	for child in node.get_children():
		_clear_trails_on(child)


func _physics_process(delta: float) -> void:
	if weapon_settings == null:
		return
	if not is_multiplayer_authority():
		_cosmetic_step(delta)
		return

	max_distance = weapon_settings.projectile_range

	var distance_this_frame = linear_velocity.length() * delta
	distance_traveled += distance_this_frame

	if weapon_settings.affected_by_gravity:
		# Set the launch velocity once, then leave it alone - the physics
		# engine's own gravity integration (this body's gravity_scale) runs
		# every tick regardless of whether this script touches linear_velocity,
		# so from here on it just curves naturally instead of snapping back
		# to a straight line. current_direction tracks the CURRENT velocity
		# instead of the original facing, so anything that reads it (ricochet,
		# guided targeting) still gets something sane once the arc bends.
		if not _ballistic_launched:
			linear_velocity = -global_transform.basis.z.normalized() * weapon_settings.projectile_speed
			_ballistic_launched = true
		current_direction = linear_velocity.normalized() if not linear_velocity.is_zero_approx() else -global_transform.basis.z.normalized()
	else:
		current_direction = -global_transform.basis.z.normalized()
		linear_velocity = current_direction * weapon_settings.projectile_speed

	if distance_traveled >= max_distance:
		destroy_self()

	if weapon_settings.targeting_system:
		if guided_target == null and Utilities.GROUP_LAYER_SCOPE.has(allegiance_group):
			var scope_targets = Utilities.GROUP_LAYER_SCOPE[allegiance_group]["target_groups"]
			guided_target = Utilities.select_target(
				global_transform.origin,
				-global_transform.basis.z,
				weapon_settings.target_system_scan_radius,
				15,
				scope_targets
			)
		handle_guided(delta)
		# Guided flight depends on a target only the server picks, so it's
		# the one kind of course change clients can't predict on their own.
		_correction_elapsed += delta
		if _correction_elapsed >= GUIDED_CORRECTION_INTERVAL:
			_correction_elapsed = 0.0
			_send_correction(false)


# Server-only. snap=true for discrete course changes (ricochet/pierce/bounce),
# sent reliably; false for the periodic guided stream, sent unreliably.
func _send_correction(snap: bool) -> void:
	if net_id < 0 or _match_node == null or _destroying:
		return
	_match_node.send_projectile_correction(net_id, global_transform, _authoritative_velocity(), snap)


# What the server's copy will actually be moving at from here on - for
# non-gravity weapons _physics_process re-derives velocity from the facing
# every tick, so that (not whatever linear_velocity happens to hold right
# now) is what a client should extrapolate.
func _authoritative_velocity() -> Vector3:
	if weapon_settings.affected_by_gravity:
		return linear_velocity
	return -global_transform.basis.z.normalized() * weapon_settings.projectile_speed


# Cosmetic copies only - local flight between (rare) server corrections.
# Runs in _physics_process so physics interpolation smooths the render, and
# Trail3D/smoke trails sample that interpolated transform.
func _cosmetic_step(delta: float) -> void:
	if _cosmetic_ended:
		return
	if weapon_settings.affected_by_gravity:
		_cosmetic_velocity += _gravity() * delta
	var start := global_position
	var motion := _cosmetic_velocity * delta
	if not _position_error.is_zero_approx():
		var blend := _position_error * minf(1.0, CORRECTION_BLEND_RATE * delta)
		motion += blend
		_position_error -= blend
	var end := start + motion
	# A weapon that never bounces off the world can safely stop at the first
	# wall it reaches here, rather than visibly flying on into it until the
	# server's end event arrives a half-RTT later. Bouncing weapons keep
	# going and wait for the server's correction instead.
	if weapon_settings.projectile_ricochet_count == 0 and weapon_settings.bounce_count == 0:
		var query := PhysicsRayQueryParameters3D.create(start, end, _world_mask())
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			global_position = hit.position
			_park()
			return
	global_position = end
	distance_traveled += motion.length()
	_face_travel_direction(delta)
	# The server's end event normally arrives first - this is only a fallback
	# so a lost/late one can never leave a projectile flying forever.
	if distance_traveled >= weapon_settings.projectile_range * 1.2:
		_park()


# Cosmetic copies only. Guided corrections land ~20x a second, and snapping
# the basis to each one stepped the facing in visible jerks - and since the
# Trail3D ribbons hang off-center on the Spinner and take their width from
# its basis, every step kinked the trail even when the path itself was
# smooth. Easing toward the velocity this copy is actually flying along also
# makes ballistic shells pitch down their arc, which they never did here.
func _face_travel_direction(delta: float) -> void:
	if _cosmetic_velocity.is_zero_approx():
		return
	var target := _basis_facing(_cosmetic_velocity).get_rotation_quaternion()
	var current := global_basis.get_rotation_quaternion()
	var t := 1.0 - exp(-COSMETIC_TURN_RATE * delta)
	global_basis = Basis(current.slerp(target, t))


# -Z along direction, with a fallback up for straight-up/down shots.
func _basis_facing(direction: Vector3) -> Basis:
	var up := Vector3.UP if absf(direction.normalized().dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	return Basis.looking_at(direction, up)


# Cosmetic copies only - stop and hide, then free shortly after if the
# server's end event (end_cosmetic) never comes to do it.
func _park() -> void:
	_cosmetic_ended = true
	visible = false
	get_tree().create_timer(1.0).timeout.connect(queue_free)


# Cosmetic copies only - the server says this projectile is gone.
func end_cosmetic() -> void:
	_cosmetic_ended = true
	visible = false
	get_tree().create_timer(weapon_settings.projectile_destruction_delay if weapon_settings else 0.0).timeout.connect(queue_free)


# Cosmetic copies only. latency = this peer's one-way latency, so the
# server's position is projected forward to where it is "now". Small errors
# blend out over a few ticks; big ones (or snap) jump outright.
func apply_correction(server_transform: Transform3D, velocity: Vector3, latency: float, snap: bool) -> void:
	if _cosmetic_ended:
		return
	var target := server_transform.origin + velocity * latency
	_cosmetic_velocity = velocity
	if snap or global_position.distance_to(target) > CORRECTION_SNAP_DISTANCE:
		# A discrete course change (ricochet etc.) - turn instantly too, the
		# trail gets cleared below anyway. Otherwise _face_travel_direction
		# eases into the new heading.
		global_basis = _basis_facing(velocity) if not velocity.is_zero_approx() else server_transform.basis
		global_position = target
		_position_error = Vector3.ZERO
		reset_physics_interpolation()
		if snap:
			_clear_trails()
	else:
		_position_error = target - global_position


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not is_multiplayer_authority():
		return
	if state.get_contact_count() == 0:
		return

	for i in range(state.get_contact_count()):
		var collider = state.get_contact_collider_object(i)
		if collider and Utilities.GROUP_LAYER_SCOPE.has(allegiance_group):
			for target_group in Utilities.GROUP_LAYER_SCOPE[allegiance_group]["target_groups"]:
				if collider.is_in_group(target_group):
					targeted_group = true
					break

			collided_object = collider
			collided_layer = collider.collision_layer
			collision_point = state.get_contact_local_position(i)
			collision_normal = state.get_contact_local_normal(i)
			if collision_point == Vector3.ZERO:
				use_raycast_fallback()
			handle_collision()
			break


func use_raycast_fallback() -> void:
	if raycast:
		raycast.force_raycast_update()
		if raycast.is_colliding():
			collision_point = raycast.get_collision_point()
			collision_normal = raycast.get_collision_normal()


func handle_collision() -> void:
	var destroy = true
	targeted_group = true if weapon_settings.friendly_fire else targeted_group

	if (weapon_settings.explosive_force > 0 and weapon_settings.explosive_force_distance > 0) or weapon_settings.unfreeze or weapon_settings.bounce_count > 0:
		var dist = weapon_settings.explosive_force_distance if weapon_settings.explosive_force_distance > 0 else weapon_settings.target_system_scan_radius
		var scope_targets = Utilities.GROUP_LAYER_SCOPE[allegiance_group]["target_groups"] if Utilities.GROUP_LAYER_SCOPE.has(allegiance_group) else []

		result = Utilities.collect_bodies(
			get_world_3d().direct_space_state,
			global_transform.origin,
			weapon_settings.body_collection_max,
			dist,
			scope_targets
		)

		if weapon_settings.explosive_force > 0 and weapon_settings.explosive_force_distance > 0:
			apply_explosive_forces(result)
			if weapon_settings.hit_points > 0:
				apply_aoe_damage(result)

		if weapon_settings.unfreeze:
			unfreeze_targets(result)

	if targeted_group:
		if weapon_settings.freeze_timer > 0:
			freeze_target()

		# Skips direct damage when the AOE branch above already hit this same
		# target - the blast origin is the impact point, so whatever this
		# projectile struck directly is already getting near-full damage from
		# apply_aoe_damage()'s own falloff. Derived from aoe_damage_one_off
		# (flipped true the moment that branch actually runs) instead of a
		# separate weapon_type field a designer had to remember to set to
		# match - a weapon with explosive_force left at 0 no longer loses its
		# direct damage for no reason.
		if weapon_settings.hit_points > 0 and not aoe_damage_one_off:
			apply_direct_damage(weapon_settings.hit_points)

		if weapon_settings.projectile_force > 0:
			apply_hit_force(weapon_settings.projectile_force)

		if weapon_settings.projectile_pierce_count > 0:
			destroy = handle_pierce()

	if weapon_settings.bounce_count > 0:
		destroy = handle_bounce(result)

	if weapon_settings.projectile_ricochet_count > 0:
		destroy = handle_ricochet()

	set_hit_scene(true)

	if destroy:
		destroy_self()


func unfreeze_targets(body_result) -> void:
	if weapon_settings.body_collection_max > 0 and weapon_settings.explosive_force_distance > 0:
		for item in body_result:
			var body = item.collider
			if body and is_instance_valid(body) and body != self:
				_set_freeze_on(body, false)


func freeze_target() -> void:
	if collided_object:
		_set_freeze_on(collided_object, true)
		var target_movement = collided_object.get_node_or_null("movement_node")
		if target_movement:
			var timer = Timer.new()
			timer.wait_time = weapon_settings.freeze_timer
			timer.one_shot = true
			target_movement.add_child(timer)
			timer.timeout.connect(_set_freeze_on.bind(collided_object, false))
			timer.start()


# The predecessor calls collided_object.call("setFreezeState", ...) directly,
# assuming the hit body itself has that method. Here setFreezeState lives on
# the craft's movement_node (a child), not the RigidBody3D root, so this
# looks it up explicitly rather than assuming the root has the method.
func _set_freeze_on(body: Object, frozen: bool) -> void:
	if not is_instance_valid(body):
		return
	var target_movement = body.get_node_or_null("movement_node")
	if target_movement and target_movement.has_method("setFreezeState"):
		target_movement.setFreezeState(frozen)


func apply_direct_damage(damage: float, target: Object = null) -> void:
	if damage_one_off:
		return
	var stdev = damage * (0.2 / 6)
	var varied_damage = damage + randfn(0, stdev)
	varied_damage = clamp(varied_damage, damage - (3 * stdev), damage + (3 * stdev))
	if randf() < weapon_settings.crit_chance:
		varied_damage *= weapon_settings.crit_multiplier
		play_crit_sound()
	var parental_object = target if target != null else collided_object
	_apply_damage_to(parental_object, varied_damage)
	damage_one_off = true


func apply_aoe_damage(bodies) -> void:
	if aoe_damage_one_off:
		return
	for item in bodies:
		var body = item.collider
		if body == self:
			continue
		var distance = global_transform.origin.distance_to(body.global_transform.origin)
		if distance < weapon_settings.explosive_force_distance:
			var damage = weapon_settings.hit_points * (1.0 - (distance / weapon_settings.explosive_force_distance))
			var stdev = damage * (0.2 / 6)
			var varied_damage = damage + randfn(0, stdev)
			varied_damage = clamp(varied_damage, damage - (3 * stdev), damage + (3 * stdev))
			if randf() < weapon_settings.crit_chance:
				varied_damage *= weapon_settings.crit_multiplier
				play_crit_sound()
			_apply_damage_to(body, varied_damage)
	aoe_damage_one_off = true


# Damage is only ever decided here, on the server (this whole script only
# runs its real logic when is_multiplayer_authority() is true). HP itself is
# server-only state - see health_node.gd::apply_damage for how the owner and
# everyone else hear about the result.
func _apply_damage_to(body: Object, damage: float) -> void:
	if not is_instance_valid(body):
		return
	var health_node = body.get_node_or_null("health_node")
	if health_node and health_node.has_method("apply_damage"):
		health_node.apply_damage(damage)


# Routed through the target's health_node instead of being applied straight
# here. This whole script only runs its real logic on the server, and the
# server is NOT the authority for a client's craft - see apply_impulse() in
# Crafts/_scripts/health_node.gd for why applying it locally did nothing.
func apply_hit_force(force: float, target: Object = null, direction: Vector3 = Vector3.ZERO) -> void:
	var force_target = target if target != null else collided_object
	var force_direction = direction if not direction.is_zero_approx() else current_direction.normalized()
	if force_target == null or not (force_target is RigidBody3D):
		return
	var impulse: Vector3 = force * force_direction
	var health_node = force_target.get_node_or_null("health_node")
	if health_node and health_node.has_method("apply_impulse"):
		health_node.apply_impulse.rpc(impulse)
	else:
		# Plain world physics props have no networked owner to hand this to.
		force_target.apply_central_impulse(impulse)


func apply_explosive_forces(body_result) -> void:
	for item in body_result:
		var body = item.collider
		if body != self and body is RigidBody3D:
			var distance = global_transform.origin.distance_to(body.global_transform.origin)
			if distance < weapon_settings.explosive_force_distance:
				var force_strength = weapon_settings.explosive_force * (1.0 - (distance / weapon_settings.explosive_force_distance))
				var direction = (body.global_transform.origin - global_transform.origin).normalized()
				apply_hit_force(force_strength, body, direction)


func handle_ricochet() -> bool:
	ricochet_count += 1
	if ricochet_count <= weapon_settings.projectile_ricochet_count:
		play_hit_sound()
		var reflect_direction = current_direction.bounce(collision_normal).normalized()
		current_direction = reflect_direction
		linear_velocity = reflect_direction * weapon_settings.projectile_speed
		# 2x the collider's own radius (0.05), same margin handle_pierce() uses
		# below - 1x was barely more than the radius itself, so a shallow or
		# corner hit could still be touching next physics step and immediately
		# ricochet again in the same spot.
		global_transform.origin += collision_normal * 0.1
		var adjusted_direction = reflect_direction
		if abs(reflect_direction.dot(Vector3.UP)) > 0.99:
			adjusted_direction += Vector3(0.001, 0, 0)
		look_at(global_transform.origin + adjusted_direction, Vector3.UP)
		# look_at() only snaps where it's FACING - it does nothing to whatever
		# angular_velocity the actual physics collision just imparted (real
		# torque/friction from the contact), so without this the leftover spin
		# keeps integrating right through the reorient and compounds with each
		# subsequent bounce. handle_pierce() below already does this for the
		# exact same reason.
		angular_velocity = Vector3.ZERO
		_clear_trails()
		_reset_one_offs()
		_send_correction(true)
		return false
	return true


func handle_pierce() -> bool:
	if collided_layer == 2: # world
		return true
	if ricochet_count <= weapon_settings.projectile_pierce_count and collided_object not in ignored_objects:
		ricochet_count += 1
		ignored_objects.append(collided_object)
		global_transform.origin += current_direction.normalized() * 0.1
		look_at(global_transform.origin + current_direction, Vector3.UP)
		linear_velocity = current_direction.normalized() * weapon_settings.projectile_speed
		angular_velocity = Vector3.ZERO
		_reset_one_offs()
		_send_correction(true)
		return false
	return true


func handle_bounce(bodies) -> bool:
	if bodies.size() > 0 and ricochet_count <= weapon_settings.bounce_count:
		ricochet_count += 1
		var body = bodies[0].collider
		var direction = (body.global_transform.origin - global_transform.origin).normalized()
		linear_velocity = direction * weapon_settings.projectile_speed
		_reset_one_offs()
		_send_correction(true)
		return false
	return true


func _reset_one_offs() -> void:
	hit_scene_one_off = false
	bullet_hole_one_off = false
	damage_one_off = false
	aoe_damage_one_off = false


func play_hit_sound() -> void:
	if weapon_settings.hit_sound:
		Utilities.play_sound(weapon_settings.hit_sound, global_transform.origin, 0.1)


func play_crit_sound() -> void:
	if weapon_settings.crit_sound:
		Utilities.play_sound(weapon_settings.crit_sound, global_transform.origin, 10.0)


func handle_guided(delta: float) -> void:
	if not weapon_settings.targeting_system:
		return
	if guided_target and is_instance_valid(guided_target):
		guide_to_target(delta)


func guide_to_target(delta: float) -> void:
	if not (guided_target and is_instance_valid(guided_target)):
		return
	var direction_to_target = (guided_target.global_transform.origin - global_transform.origin).normalized()
	var forward = -global_transform.basis.z
	var rotation_axis = forward.cross(direction_to_target)
	rotation_axis = rotation_axis.normalized() if rotation_axis.length() > 0 else Vector3.UP
	var rotation_delta = Quaternion(rotation_axis, forward.angle_to(direction_to_target) * weapon_settings.target_rotation_speed * delta).normalized()
	global_transform.basis = (Basis(rotation_delta) * global_transform.basis).orthonormalized()
	linear_velocity = -global_transform.basis.z * weapon_settings.projectile_speed


# Called from handle_collision()/destroy_self(), which only ever run on the
# server. Decides ON THE SERVER whether anything should play (respecting the
# one-off flags), then sends ONE unreliable cosmetic message for the
# explosion and the bullet hole together - see match.gd::_play_impact_fx.
# Routed through match.gd rather than an RPC on this projectile, so the
# effect doesn't depend on this node still existing on the receiving peer
# when it arrives (it's on a different channel than the despawn).
func set_hit_scene(include_bullet_hole: bool = false) -> void:
	var show_hit := not hit_scene_one_off
	var show_hole := include_bullet_hole and not bullet_hole_one_off and collided_layer == 2 # world
	hit_scene_one_off = true
	if include_bullet_hole:
		bullet_hole_one_off = true
	if not show_hit and not show_hole:
		return
	var match_node = get_tree().get_first_node_in_group("match")
	if match_node == null:
		return
	match_node._play_impact_fx.rpc(
		weapon_settings_path,
		weapon_settings.projectile_color,
		global_transform,
		show_hit,
		show_hole,
		collision_point,
		collision_normal
	)


func destroy_self() -> void:
	# Range-out and a collision can both land in the same tick.
	if _destroying:
		return
	_destroying = true
	set_hit_scene()
	if is_multiplayer_authority() and net_id >= 0 and _match_node:
		_match_node.notify_projectile_ended(net_id)
	await get_tree().create_timer(weapon_settings.projectile_destruction_delay).timeout
	queue_free()

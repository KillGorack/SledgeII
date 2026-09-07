extends RigidBody3D

# Ported from the predecessor project's collisionHandler.gd. There, whichever
# client happened to be simulating a projectile called apply_damage()
# directly and locally - fine single-player, not safe for real multiplayer
# (clients could disagree on hits, or a modified client could deal extra
# damage). Here the projectile is always spawned by the server (see
# Weapons/weapon_node.gd), so its default multiplayer_authority is already
# the server - _physics_process/_integrate_forces below only do real work
# when is_multiplayer_authority() is true, exactly like movement.gd already
# gates craft input. Every other peer just sees the replicated transform.

var weapon_settings: WeaponSettings
var team: String = "" # shooter's team, e.g. "team_a" - kept for reference
var allegiance_group: String = "" # projectile's own group, e.g. "projectile_team_a"

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

@onready var raycast: RayCast3D = $RayCast3D


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 5
	if team != "":
		allegiance_group = "projectile_" + team
		Utilities.set_allegiance(self, allegiance_group)
	if weapon_settings:
		_apply_projectile_color(weapon_settings.projectile_color)


# Runs identically on every peer - weapon_settings is assigned by
# match.gd::_spawn_projectile before this node is added to the tree (same
# ordering apply_damage()/respawn_at() already rely on elsewhere), and every
# peer loads its own copy of the same weapon_settings.tres by path, so there
# is nothing here that needs authority gating or a network trip; it's exactly
# as local as the mesh and material this projectile scene already ships with.
#
# Deliberately duck-typed rather than reaching for named child paths: rocket,
# laser and shell are three different scene shapes (rocket has a tinted mesh,
# laser has none, shell's mesh stays its own Gun_Metal on purpose) sharing
# this one script, so it asks each descendant whether it knows how to color
# itself instead of assuming any particular one exists. See
# colorable_light.gd, colorable_mesh.gd and Trail3D.gd::apply_projectile_color
# for the nodes that currently answer yes.
func _apply_projectile_color(color: Color) -> void:
	_apply_projectile_color_to(self, color)


func _apply_projectile_color_to(node: Node, color: Color) -> void:
	if node.has_method("apply_projectile_color"):
		node.apply_projectile_color(color)
	for child in node.get_children():
		_apply_projectile_color_to(child, color)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if weapon_settings == null:
		return

	max_distance = weapon_settings.projectile_range
	current_direction = -global_transform.basis.z.normalized()

	var distance_this_frame = linear_velocity.length() * delta
	distance_traveled += distance_this_frame
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

	set_hit_scene()
	create_bullet_hole()

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
# runs its real logic when is_multiplayer_authority() is true). health_node's
# apply_damage is an authority-only RPC with call_local, so this both applies
# the damage locally on the server and pushes the same result to every client.
func _apply_damage_to(body: Object, damage: float) -> void:
	if not is_instance_valid(body):
		return
	var health_node = body.get_node_or_null("health_node")
	if health_node and health_node.has_method("apply_damage"):
		health_node.apply_damage.rpc(damage)


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
		_reset_one_offs()
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
		return false
	return true


func handle_bounce(bodies) -> bool:
	if bodies.size() > 0 and ricochet_count <= weapon_settings.bounce_count:
		ricochet_count += 1
		var body = bodies[0].collider
		var direction = (body.global_transform.origin - global_transform.origin).normalized()
		linear_velocity = direction * weapon_settings.projectile_speed
		_reset_one_offs()
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


# These three are called from handle_collision(), which only ever runs on
# the server. Each wrapper below still decides ON THE SERVER whether to fire
# (respecting the one-off flags), but the actual instantiate+add_child work
# happens inside an RPC so every peer plays the same cosmetic effect locally
# - not just whichever machine happens to be the host.

func create_bullet_hole() -> void:
	if bullet_hole_one_off:
		return
	if collided_layer == 2: # world
		_play_bullet_hole_effect.rpc(collision_point, collision_normal)
	bullet_hole_one_off = true


@rpc("authority", "call_local", "reliable")
func _play_bullet_hole_effect(hit_point: Vector3, hit_normal: Vector3) -> void:
	if not weapon_settings.bullet_hole_prefab or not get_parent():
		return
	var bullet_hole_instance = weapon_settings.bullet_hole_prefab.instantiate()
	get_parent().add_child(bullet_hole_instance)
	var offset_position = hit_point + hit_normal * 0.01
	bullet_hole_instance.global_transform.origin = offset_position
	var up_vector = Vector3.UP
	if hit_normal.dot(up_vector) > 0.999:
		up_vector = Vector3.RIGHT
	up_vector = up_vector.rotated(hit_normal, randf() * TAU)
	var direction = (offset_position + hit_normal) - offset_position
	if not direction.is_zero_approx() and not up_vector.cross(direction).is_zero_approx():
		bullet_hole_instance.look_at_from_position(offset_position, offset_position + hit_normal, up_vector)


func set_hit_scene() -> void:
	if hit_scene_one_off:
		return
	_play_hit_effect.rpc()
	hit_scene_one_off = true


@rpc("authority", "call_local", "reliable")
func _play_hit_effect() -> void:
	play_hit_sound()
	if weapon_settings.explosion_prefab and get_parent():
		var explosion_instance = weapon_settings.explosion_prefab.instantiate()
		get_parent().add_child(explosion_instance)
		explosion_instance.transform = global_transform


func destroy_self() -> void:
	set_hit_scene()
	await get_tree().create_timer(weapon_settings.projectile_destruction_delay).timeout
	queue_free()

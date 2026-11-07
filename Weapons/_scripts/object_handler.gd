extends Plaything
class_name ThrownObject

# Handler for "dead body" game objects tossed from a weapon (the D20): real
# physics bodies that bounce, roll, and collide with EVERYTHING - the world,
# every craft (the shooter's too), other thrown objects - instead of being
# consumed on first contact like collision_handler.gd's projectiles.
#
# Shares the WeaponSettings resource and match.gd's spawn/stream plumbing
# (same property names + fast_forward/apply_correction/end_cosmetic), so a
# weapon fires one exactly like any other. Settings it reads:
#   projectile_speed      launch speed (straight along the muzzle)
#   projectile_lifetime   seconds until it removes itself (0 = never!)
#   projectile_destruction_delay  seconds between removal and queue_free
#   hit_points            damage on a hard enough impact with a craft
#   friendly_fire         impact damage also hurts the shooter's team
#   projectile_force      extra shove on the thing it hits (0 = just physics)
#   cool_down, launch_offset, ... as for any weapon.
#   Gravity/bounce come from the prefab's RigidBody3D / PhysicsMaterial.
#
# Network model: the server's body is the only real one. Clients get a frozen
# cosmetic copy that extrapolates (gravity) between the server's ~20Hz state
# stream - match.gd::send_projectile_correction / apply_correction.

var weapon_settings: WeaponSettings
var weapon_settings_path: String = ""
var team: String = ""
var shooter_peer: int = 0
var reverse_force: bool = false
var net_id: int = -1

# Physics layer 15. Projectiles (collision_handler.gd) add this bit to their
# mask so they strike objects; objects mask the world, every craft layer, and
# each other.
const OBJECT_LAYER_BIT := 1 << 14
const STREAM_INTERVAL := 0.05
const SNAP_DISTANCE := 5.0
const BLEND_RATE := 15.0
const TURN_RATE := 20.0
# Change in speed (m/s) an impact must cause to count as a "hit" - below this
# it's just resting / rolling contact and does no damage.
const MIN_HIT_SPEED := 3.0
# Per-body damage cooldown so a die grinding on a craft doesn't tick every frame.
const HIT_COOLDOWN := 0.5
const FALL_LIMIT_Y := -500.0

var _age := 0.0
var _stream_elapsed := 0.0
var _was_sleeping := false
var _match_node: Node = null
var _hit_times := {} # body instance id -> _age of last damaging hit
var _cosmetic_velocity := Vector3.ZERO
var _position_error := Vector3.ZERO
var _cosmetic_ended := false
var _target_basis := Basis.IDENTITY


func _ready() -> void:
	_match_node = get_tree().get_first_node_in_group("match")
	super._ready() # joins "playthings" - see plaything.gd
	if weapon_settings:
		Utilities.apply_projectile_color_recursive(self, weapon_settings.projectile_color)
	if is_multiplayer_authority():
		contact_monitor = true
		max_contacts_reported = 8
		collision_layer = OBJECT_LAYER_BIT
		collision_mask = OBJECT_LAYER_BIT | _bits_for_layers([1, 2, 3, 4, 5, 6])
		if weapon_settings:
			linear_velocity = -global_transform.basis.z.normalized() * weapon_settings.projectile_speed
		enforce_cap()
	else:
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
		contact_monitor = false
		collision_layer = 0
		collision_mask = 0
		_target_basis = global_basis
		if weapon_settings:
			_cosmetic_velocity = -global_transform.basis.z.normalized() * weapon_settings.projectile_speed


static func _bits_for_layers(layers: Array) -> int:
	var bits := 0
	for layer in layers:
		bits |= 1 << (int(layer) - 1)
	return bits


func _gravity() -> Vector3:
	var strength: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	return direction * strength * gravity_scale


# match.gd calls this right after spawning. The server's body just keeps
# simulating (it was launched in _ready), so only the cosmetic copy needs to
# catch up with the time the spawn event spent in transit.
func fast_forward(seconds: float) -> void:
	if seconds <= 0.0 or weapon_settings == null or is_multiplayer_authority():
		return
	global_position += _cosmetic_velocity * seconds + 0.5 * _gravity() * seconds * seconds
	_cosmetic_velocity += _gravity() * seconds
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	if weapon_settings == null:
		return
	_age += delta
	if not is_multiplayer_authority():
		_cosmetic_step(delta)
		return
	if weapon_settings.projectile_lifetime > 0.0 and _age >= weapon_settings.projectile_lifetime:
		destroy_self()
		return
	if global_position.y < FALL_LIMIT_Y: # fell off the map
		destroy_self()
		return
	# Stream state; once asleep send a single final update, then go quiet.
	_stream_elapsed += delta
	if _stream_elapsed >= STREAM_INTERVAL:
		_stream_elapsed = 0.0
		var asleep := sleeping
		if not asleep or not _was_sleeping:
			_send_state()
		_was_sleeping = asleep


func _send_state() -> void:
	if net_id < 0 or _match_node == null or destroying:
		return
	_match_node.send_projectile_correction(net_id, global_transform, linear_velocity, false)


# --- cosmetic copies -------------------------------------------------------

func _cosmetic_step(delta: float) -> void:
	if _cosmetic_ended:
		return
	# Fallback for a lost end event.
	if weapon_settings.projectile_lifetime > 0.0 and _age >= weapon_settings.projectile_lifetime + 1.0:
		end_cosmetic()
		return
	_cosmetic_velocity += _gravity() * delta
	var motion := _cosmetic_velocity * delta
	if not _position_error.is_zero_approx():
		var blend := _position_error * minf(1.0, BLEND_RATE * delta)
		motion += blend
		_position_error -= blend
	global_position += motion
	var t := 1.0 - exp(-TURN_RATE * delta)
	global_basis = Basis(global_basis.get_rotation_quaternion().slerp(_target_basis.get_rotation_quaternion(), t))


# match.gd: server_transform/velocity from the stream. snap = discrete jump.
func apply_correction(server_transform: Transform3D, velocity: Vector3, latency: float, snap: bool) -> void:
	if _cosmetic_ended:
		return
	var target := server_transform.origin + velocity * latency
	_cosmetic_velocity = velocity
	_target_basis = server_transform.basis
	if snap or global_position.distance_to(target) > SNAP_DISTANCE:
		global_position = target
		global_basis = server_transform.basis
		_position_error = Vector3.ZERO
		reset_physics_interpolation()
	else:
		_position_error = target - global_position


func end_cosmetic() -> void:
	_cosmetic_ended = true
	visible = false
	var delay := weapon_settings.projectile_destruction_delay if weapon_settings else 0.0
	get_tree().create_timer(delay).timeout.connect(queue_free)


# --- server: collisions ------------------------------------------------------

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not is_multiplayer_authority() or weapon_settings == null:
		return
	for i in state.get_contact_count():
		var collider := state.get_contact_collider_object(i) as Node
		if collider == null or collider == self:
			continue
		# Change in speed this contact caused (impulse / mass).
		var impact := state.get_contact_impulse(i).length() / maxf(mass, 0.001)
		if impact < MIN_HIT_SPEED:
			continue
		_on_impact(collider, state.get_contact_local_position(i), state.get_contact_local_normal(i), impact)


func _on_impact(collider: Node, point: Vector3, normal: Vector3, impact: float) -> void:
	var id := collider.get_instance_id()
	if _hit_times.has(id) and _age - float(_hit_times[id]) < HIT_COOLDOWN:
		return
	_hit_times[id] = _age
	_play_hit_fx(point, normal)
	if not _can_hurt(collider):
		return
	if weapon_settings.hit_points > 0.0:
		var health_node = collider.get_node_or_null("health_node")
		if health_node and health_node.has_method("apply_damage"):
			var cause: int = health_node.DeathCause.BASE_GUN if shooter_peer == 0 else health_node.DeathCause.WEAPON
			health_node.apply_damage(weapon_settings.hit_points, shooter_peer, cause)
	if weapon_settings.projectile_force > 0.0 and collider is RigidBody3D:
		var dir: Vector3 = ((collider as Node3D).global_position - global_position).normalized()
		var force := weapon_settings.projectile_force * (-1.0 if reverse_force else 1.0)
		var health_node = collider.get_node_or_null("health_node")
		if health_node and health_node.has_method("apply_impulse"):
			health_node.note_attacker(shooter_peer)
			health_node.apply_impulse.rpc(dir * force)
		else:
			(collider as RigidBody3D).apply_central_impulse(dir * force)


# Enemy craft always; the shooter's own team only with friendly_fire.
func _can_hurt(collider: Node) -> bool:
	if collider.get_node_or_null("health_node") == null:
		return false
	if weapon_settings.friendly_fire:
		return true
	var allegiance := "projectile_" + team
	if Utilities.GROUP_LAYER_SCOPE.has(allegiance):
		for group in Utilities.GROUP_LAYER_SCOPE[allegiance]["target_groups"]:
			if collider.is_in_group(group):
				return true
	return false


# One cosmetic impact (hit sound/explosion if the weapon has them) to all peers.
func _play_hit_fx(point: Vector3, normal: Vector3) -> void:
	if _match_node == null or (weapon_settings.hit_sound == null and weapon_settings.explosion_prefab == null):
		return
	_match_node._play_impact_fx.rpc(weapon_settings_path, weapon_settings.projectile_color, global_transform, true, false, point, normal, false)


func destroy_self() -> void:
	if destroying:
		return
	destroying = true
	if is_multiplayer_authority() and net_id >= 0 and _match_node:
		_match_node.notify_projectile_ended(net_id)
	visible = false
	collision_layer = 0
	collision_mask = 0
	await get_tree().create_timer(weapon_settings.projectile_destruction_delay).timeout
	queue_free()

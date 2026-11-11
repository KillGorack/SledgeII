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
var shooter_peer: int = 0
var reverse_force: bool = false
var net_id: int = -1

# Physics layer 15. Projectiles (collision_handler.gd) add this bit to their
# mask so they strike objects; objects mask the world, every craft layer, and
# each other.
const OBJECT_LAYER_BIT := 1 << 14
const STREAM_INTERVAL := 0.05
# Cosmetic copies draw the server's snapshots this far in the past, interpolating
# between two real ones - so they never guess, never sink through the floor, and
# a bounce shows exactly where it happened. The delay builds up over the first
# INTERP_RAMP seconds after launch (the start is predicted ballistic flight), so
# a throw doesn't hitch.
const INTERP_DELAY := 0.12
const INTERP_RAMP := 0.5
const SEED_SECONDS := 0.6
const SEED_STEP := 0.025
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
var _cosmetic_velocity := Vector3.ZERO # launch velocity, used to seed the buffer
var _cosmetic_ended := false
# Snapshot buffer: [{t, p, q, v, syn}] in this copy's own clock (_clock). "syn"
# ones are predicted launch flight, replaced as real snapshots arrive.
var _snaps: Array = []
var _clock := 0.0
var _seeded := false


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
func fast_forward(_seconds: float) -> void:
	# Nothing to do. The server's body just keeps simulating, and cosmetic copies
	# draw the server's snapshots in the past (see _show_pose_at), so catching up
	# to "now" would only put them ahead of the data they're about to play back.
	pass


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
		if not asleep:
			_send_state(false)
		elif not _was_sleeping:
			_send_state(true) # final resting pose: reliable, can't be lost
		_was_sleeping = asleep


func _send_state(final_pose: bool) -> void:
	if net_id < 0 or _match_node == null or destroying:
		return
	_match_node.send_projectile_correction(net_id, global_transform, Vector3.ZERO if final_pose else linear_velocity, final_pose)


# --- cosmetic copies -------------------------------------------------------

func _cosmetic_step(delta: float) -> void:
	if _cosmetic_ended:
		return
	# Fallback for a lost end event.
	if weapon_settings.projectile_lifetime > 0.0 and _age >= weapon_settings.projectile_lifetime + 1.0:
		end_cosmetic()
		return
	_clock += delta
	if not _seeded:
		_seed_snapshots()
	var delay := INTERP_DELAY * clampf(_age / INTERP_RAMP, 0.0, 1.0)
	_show_pose_at(_clock - delay)


# Predicted launch flight, so there is something to play back until the
# server's own snapshots start arriving (the first one is ~50 ms away).
func _seed_snapshots() -> void:
	_seeded = true
	var p0 := global_position
	var q := global_basis.get_rotation_quaternion()
	var g := _gravity()
	var steps := int(SEED_SECONDS / SEED_STEP)
	for i in steps + 1:
		var dt := i * SEED_STEP
		_snaps.append({"t": _clock + dt, "p": p0 + _cosmetic_velocity * dt + 0.5 * g * dt * dt, "q": q, "syn": true})
	reset_physics_interpolation()


# Straight-line interpolation between the two snapshots around `time` (not a
# curve: a curve can overshoot and dip a die below the floor at a bounce).
func _show_pose_at(time: float) -> void:
	var n := _snaps.size()
	if n == 0:
		return
	# Drop what's long past, keeping one snapshot before `time` to interpolate from.
	while n > 2 and _snaps[1]["t"] < time:
		_snaps.pop_front()
		n -= 1
	var a: Dictionary = _snaps[0]
	if time <= a["t"] or n == 1:
		global_position = a["p"]
		global_basis = Basis(a["q"])
		return
	var b: Dictionary = _snaps[1]
	if time >= b["t"]:
		# Out of data (late or lost update): hold the newest pose, don't guess.
		global_position = b["p"]
		global_basis = Basis(b["q"])
		return
	var s: float = (time - a["t"]) / (b["t"] - a["t"])
	global_position = (a["p"] as Vector3).lerp(b["p"], s)
	global_basis = Basis((a["q"] as Quaternion).slerp(b["q"], s))


# match.gd: a server snapshot (~20/s while awake; one reliable final pose when it
# goes to sleep), labelled with when it ARRIVED and holding the server's raw
# position - never projected forward, which would push a landing die below the
# floor it is actually resting on.
func apply_correction(server_transform: Transform3D, _velocity: Vector3, _latency: float, _snap: bool) -> void:
	if _cosmetic_ended:
		return
	# Real data replaces any predicted flight from this moment on.
	while not _snaps.is_empty() and _snaps.back()["syn"] and _snaps.back()["t"] >= _clock:
		_snaps.pop_back()
	_snaps.append({
		"t": _clock,
		"p": server_transform.origin,
		"q": server_transform.basis.get_rotation_quaternion(),
		"syn": false,
	})


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


func _on_impact(collider: Node, point: Vector3, normal: Vector3, _impact: float) -> void:
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

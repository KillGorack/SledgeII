extends Node3D

@export var weapon_settings: Array[WeaponSettings] = []
@export var team: String = "team_a"

var current_weapon_index: int = 0
var _client_shoot_timer: float = 0.0
# Server-only: authoritative per-weapon cooldown, re-checked regardless of
# what the client claims - a modified client spamming request_fire still
# gets rejected here.
var _server_next_fire_time: Dictionary = {}

@onready var barrel: Node3D = get_node("../Turret/Barrel")


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if weapon_settings.is_empty():
		return
	if _client_shoot_timer > 0:
		_client_shoot_timer -= delta
	if Input.is_action_just_pressed("weapon_change"):
		switch_weapon()
	if Input.is_action_pressed("fire_weapon") and _client_shoot_timer <= 0:
		var settings := weapon_settings[current_weapon_index]
		# Client-side rate limiting only, for feel - keeps us from spamming
		# RPCs the server would reject anyway. Not trusted for correctness.
		_client_shoot_timer = settings.cool_down
		request_fire.rpc_id(1, current_weapon_index)


# Client-feel only, same caveat as _client_shoot_timer itself: this is what
# actually gates the fire_weapon input above, so it's the right thing for a
# reticle to read - it already tracks whichever weapon is currently equipped,
# since cool_down is re-read from that weapon's settings every time a shot
# fires (see request below).
func is_on_cooldown() -> bool:
	return _client_shoot_timer > 0.0


func switch_weapon() -> void:
	if weapon_settings.is_empty():
		return
	current_weapon_index = (current_weapon_index + 1) % weapon_settings.size()


@rpc("any_peer", "call_local", "reliable")
func request_fire(weapon_index: int) -> void:
	if not multiplayer.is_server():
		return
	if weapon_index < 0 or weapon_index >= weapon_settings.size():
		return
	var settings := weapon_settings[weapon_index]
	if settings == null or settings.projectile_prefab == null:
		return
	# The spawner still needs a plain res:// string, not the Resource itself -
	# see match.gd::_spawn_projectile for why (replication can't safely decode
	# arbitrary Objects, so every peer loads its own copy from disk by path).
	# resource_path is populated automatically for any .tres dragged into the
	# weapon_settings slot below, so this is just reading it back off, not
	# reintroducing the string typing this change was meant to get rid of.
	var path := settings.resource_path
	if path.is_empty():
		push_warning("weapon_node: weapon_settings[%d] has no resource_path (not a saved .tres?)" % weapon_index)
		return
	var now = Time.get_ticks_msec() / 1000.0
	var next_allowed = _server_next_fire_time.get(weapon_index, 0.0)
	if now < next_allowed:
		return
	_server_next_fire_time[weapon_index] = now + settings.cool_down
	var match_node = get_tree().get_first_node_in_group("match")
	if match_node and match_node.has_method("spawn_projectile"):
		var muzzle := barrel.global_transform
		var forward = -muzzle.basis.z.normalized()
		muzzle.origin += forward * settings.launch_offset
		_fire_volley(match_node, path, muzzle, settings)
		if settings.projectile_recoil > 0 and get_parent() is RigidBody3D:
			get_parent().apply_central_impulse(-forward * settings.projectile_recoil)


# Ported from the predecessor project's shoot.gd::fire_weapon. That version
# looped over settings.projectile_count, fanning shots around a small ring
# (settings.projectile_spacing) rather than diverging their angle - so a
# multi-shot weapon fires dead straight, just from several separated points -
# with a per-count start_angle so each count's pattern sits symmetrically
# instead of always starting from the same spot. That loop just never made it
# into request_fire when this got ported to multiplayer, so every weapon
# quietly fired only its first projectile regardless of projectile_count.
#
# Each shot below is still its own separate spawn_projectile() call, i.e. its
# own MultiplayerSpawner.spawn() - so a volley of 4 is 4 fully independent
# collision_handler instances, not one entity moving 4 meshes. That's what
# guided weapons need: guided_target in collision_handler.gd is per-instance
# state, so each missile in a volley can lock onto its own separate target.
const _VOLLEY_START_ANGLES := [0, 0, -30, 45, 18, 0]

func _fire_volley(match_node: Node, weapon_settings_path: String, muzzle: Transform3D, settings: WeaponSettings) -> void:
	var count = max(settings.projectile_count, 1)
	var right = muzzle.basis.x.normalized()
	var up = muzzle.basis.y.normalized()
	var angle_step = 360.0 / count
	var start_angle = _VOLLEY_START_ANGLES[count - 1] if count - 1 < _VOLLEY_START_ANGLES.size() else 0
	for i in range(count):
		var angle = deg_to_rad(start_angle + i * angle_step)
		var offset = (right * cos(angle) + up * sin(angle)) * settings.projectile_spacing
		var shot_transform := Transform3D(muzzle.basis, muzzle.origin + offset)
		match_node.spawn_projectile(weapon_settings_path, team, shot_transform)

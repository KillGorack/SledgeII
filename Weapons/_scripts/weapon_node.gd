extends Node3D

@export var weapon_settings: Array[WeaponSettings] = []
@export var team: String = "team_red"

var current_weapon_index: int = 0
# Absolute timestamp (Time.get_ticks_msec(), same clock request_fire() below
# checks against), not a per-frame countdown - a countdown decremented by
# _physics_process's delta drifts against the server's wall-clock check by a
# few ms every tick (physics steps don't land at perfectly even wall-clock
# intervals), and that drift accumulates shot over shot until it crosses a
# whole cool_down and a shot lands a beat early or late - read as "cooldown's
# randomly off every few shots" before this was an absolute timestamp.
var _client_next_fire_time: float = 0.0
# Server-only: authoritative per-weapon cooldown, re-checked regardless of
# what the client claims - a modified client spamming request_fire still
# gets rejected here.
var _server_next_fire_time: Dictionary = {}
# Server-only, per-weapon-index remaining ammo for physical (non-power)
# weapons - see request_fire() below for why this can't live on the shared
# WeaponSettings resource itself.
var _ammo_remaining: Dictionary = {}

@onready var barrel: Node3D = get_node("../Turret/Barrel")
@onready var power_node: Node3D = get_node("../power_node")


func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if weapon_settings.is_empty():
		return
	if Input.is_action_just_pressed("weapon_change"):
		switch_weapon()
	var now = Time.get_ticks_msec() / 1000.0
	if Input.is_action_pressed("fire_weapon") and now >= _client_next_fire_time:
		var settings := weapon_settings[current_weapon_index]
		# Predicted locally off power_node's replicated current_power - same
		# "not trusted for correctness" caveat as the cooldown below, the
		# server re-checks for real in request_fire(). Skipping the RPC
		# entirely here (rather than sending it and doing nothing with the
		# rejection) is what lets is_on_cooldown() below show a steady "can't
		# fire" state instead of the trigger silently eating presses once
		# you're out - that silence was what read as "inconsistent" before
		# this existed.
		if settings.power_consumption > 0.0 and power_node.current_power < settings.power_consumption:
			return
		# Client-side rate limiting only, for feel - keeps us from spamming
		# RPCs the server would reject anyway. Not trusted for correctness.
		_client_next_fire_time = now + settings.cool_down
		request_fire.rpc_id(1, current_weapon_index)


# Client-feel only, same caveat as _client_next_fire_time itself: this is
# what actually gates the fire_weapon input above, so it's the right thing
# for a reticle to read - it already tracks whichever weapon is currently
# equipped, since cool_down is re-read from that weapon's settings every time
# a shot fires (see request below). Also true while there isn't enough power
# for the current weapon, for the same reason - the reticle shouldn't just go
# quiet. Ammo isn't checked here (unlike power) - remaining count only lives
# server-side right now (see _ammo_remaining), so a remote client has no
# accurate number to predict against yet; a guess here would be wrong exactly
# as often as it's right.
func is_on_cooldown() -> bool:
	if Time.get_ticks_msec() / 1000.0 < _client_next_fire_time:
		return true
	if weapon_settings.is_empty():
		return false
	var settings := weapon_settings[current_weapon_index]
	return settings.power_consumption > 0.0 and power_node.current_power < settings.power_consumption


# Called by recon_station.gd (server-only, see its own comment) when the
# craft enters a recon station's Area3D - tops every weapon's ammo back up to
# its capacity. Power isn't touched here, same reason as ammo not being
# checked in is_on_cooldown(): the station already charges that continuously
# via power_node.gd just from being nearby.
func refill_ammo() -> void:
	for i in range(weapon_settings.size()):
		var settings := weapon_settings[i]
		if settings and settings.projectile_count_capacity != 0:
			_ammo_remaining[i] = settings.projectile_count_capacity


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
	# Checked (and spent) before the cooldown is committed below, so a shot
	# rejected for insufficient power doesn't also cost you the cooldown - as
	# far as the weapon's concerned, nothing happened.
	if settings.power_consumption > 0.0 and not power_node.try_spend(settings.power_consumption):
		return
	# Physical weapons (missiles, shells) spend ammo instead of power -
	# capacity 0 means unlimited, same convention as the old game. This has to
	# be its own Dictionary rather than decrementing settings.projectile_count_actual
	# directly: weapon_settings entries are the same shared .tres Resource
	# referenced by every craft using this weapon, so writing the live count
	# onto the resource itself would drain one shared ammo pool across every
	# player instead of a separate one per craft. projectile_count_actual is
	# only ever read here, as the starting amount.
	if settings.projectile_count_capacity != 0:
		var ammo_left: int = _ammo_remaining.get(weapon_index, settings.projectile_count_actual)
		if ammo_left < settings.projectile_count:
			return
		_ammo_remaining[weapon_index] = ammo_left - settings.projectile_count
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

extends Node3D

@export var weapon_settings_paths: Array[String] = []
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
	if weapon_settings_paths.is_empty():
		return
	if _client_shoot_timer > 0:
		_client_shoot_timer -= delta
	if Input.is_action_just_pressed("weapon_change"):
		switch_weapon()
	if Input.is_action_pressed("fire_weapon") and _client_shoot_timer <= 0:
		var settings: WeaponSettings = load(weapon_settings_paths[current_weapon_index])
		# Client-side rate limiting only, for feel - keeps us from spamming
		# RPCs the server would reject anyway. Not trusted for correctness.
		_client_shoot_timer = settings.cool_down
		request_fire.rpc_id(1, current_weapon_index)


func switch_weapon() -> void:
	if weapon_settings_paths.is_empty():
		return
	current_weapon_index = (current_weapon_index + 1) % weapon_settings_paths.size()


@rpc("any_peer", "call_local", "reliable")
func request_fire(weapon_index: int) -> void:
	if not multiplayer.is_server():
		return
	if weapon_index < 0 or weapon_index >= weapon_settings_paths.size():
		return
	var path = weapon_settings_paths[weapon_index]
	var settings: WeaponSettings = load(path)
	if settings == null or settings.projectile_prefab == null:
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
		match_node.spawn_projectile(path, team, muzzle)
		if settings.projectile_recoil > 0 and get_parent() is RigidBody3D:
			get_parent().apply_central_impulse(-forward * settings.projectile_recoil)

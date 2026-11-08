extends Node3D
class_name Sentry

# A stationary turret (the old game's Sentry, which Creative levels place as "Turret"). It belongs to a team
# and shoots the nearest enemy it can see, like a base gun does, but it is a gun on a mount: the barrel
# swings round and leads its target before each shot. Built in code from four models so there is no scene to
# keep in step. Set `team` (a "team_red"... name) before adding it to the tree.
#
# Aiming is cosmetic and runs on every peer; only the server fires and keeps the hit points (the same
# split as base_gun.gd, whose hit-body proxy it reuses).

const MODELS := "res://Models/Sentry/"
const WEAPON_PATH := "res://Weapons/settings_object/plasma_base.tres"
const CHROME := preload("res://Materials/Creative/base_colors/chrome.tres")
const DESTROY_EXPLOSION := preload("res://Weapons/Scenes/explosions/explosion_main.tscn")

const MAX_HP := 100.0
const HITBOX_RADIUS := 0.6
# Same offset as base_gun.gd: the hit body sits on its team's craft layer + this, so only enemy shots touch it.
const HIT_LAYER_OFFSET := 8
const TURN_SPEED := 8.0
# How close (degrees) the barrel must be to the target before it fires.
const FIRE_CONE_DEGREES := 6.0
const SCAN_INTERVAL := 0.15

var team: String = ""
var is_dead := false

var _weapon: WeaponSettings
var _turret: MeshInstance3D
var _barrel: MeshInstance3D
var _muzzle: Marker3D
var _hit_body: StaticBody3D
var _hp := MAX_HP
var _target: Node3D
var _scan_left := 0.0
var _next_fire_time := 0.0
var _last_target_position := Vector3.ZERO


func _ready() -> void:
	_weapon = load(WEAPON_PATH)
	_build_model()
	_build_hit_body()
	_refresh_state()


func _build_model() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.16, 0.17, 0.19)
	metal.metallic = 0.85
	metal.roughness = 0.35
	var accent := StandardMaterial3D.new()
	accent.albedo_color = ReconStation.render_color_for_team(team) if team != "" else Color(0.6, 0.6, 0.6)
	accent.metallic = 0.6
	accent.roughness = 0.3
	_turret = _part(self, "sentry_base", metal)
	_turret.name = "Turret"
	_part(_turret, "sentry_pivot", CHROME)
	_barrel = _part(_turret, "sentry_barrel", metal)
	_barrel.name = "Barrel"
	_part(_barrel, "sentry_counter_weight", accent)
	_muzzle = Marker3D.new()
	_muzzle.name = "Muzzle"
	_muzzle.position = Vector3(0.0, 0.0, -0.9)
	_barrel.add_child(_muzzle)


func _part(parent: Node3D, model: String, material: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = load(MODELS + model + ".obj")
	part.material_override = material
	parent.add_child(part)
	return part


func _build_hit_body() -> void:
	_hit_body = StaticBody3D.new()
	_hit_body.name = "HitBody"
	_hit_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = HITBOX_RADIUS
	shape.shape = sphere
	_hit_body.add_child(shape)
	# collision_handler.gd looks for this exact child name on whatever it hit.
	var health := Node.new()
	health.name = "health_node"
	health.set_script(preload("res://Game_Objects/_scripts/base_gun_health.gd"))
	_hit_body.add_child(health)
	add_child(_hit_body)
	_hit_body.add_to_group("BaseGunHitbox")   # turrets and guns don't shoot each other (see _find_target)


# The hit body is on the team's layer and group while alive, so that team's enemies' shots land on it.
func _refresh_state() -> void:
	visible = not is_dead
	var layer_data: Dictionary = Utilities.GROUP_LAYER_SCOPE.get(team, {})
	if not is_dead and not layer_data.is_empty():
		_hit_body.collision_layer = 1 << (int(layer_data["layer"]) + HIT_LAYER_OFFSET - 1)
		if not _hit_body.is_in_group(team):
			_hit_body.add_to_group(team)
		# The radar's blip_turret row finds these by group.
		add_to_group("Turret")
	else:
		_hit_body.collision_layer = 0
		remove_from_group("Turret")
		if team != "" and _hit_body.is_in_group(team):
			_hit_body.remove_from_group(team)


func _physics_process(delta: float) -> void:
	# Nothing shoots at a creator who is building (Creative/creative_editor.gd); testing is the real thing.
	if is_dead or team == "" or _weapon == null or NetworkManager.creative_building:
		return
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = SCAN_INTERVAL
		_target = _find_target()
	if not is_instance_valid(_target):
		_target = null
		return
	var aim_point := _lead_point(_target, delta)
	_aim_at(aim_point, delta)
	if NetworkManager.is_live_server():
		_try_fire(aim_point)


# Nearest enemy in range with a clear line, the way base_gun.gd picks: the projectile's own range is the
# gun's range, and the line of sight uses exactly what a shot from here would collide with.
func _find_target() -> Node3D:
	var scope: Dictionary = Utilities.GROUP_LAYER_SCOPE.get(team, {})
	var best: Node3D = null
	var best_dist := _weapon.projectile_range
	for group_name in scope.get("target_groups", []):
		for body in get_tree().get_nodes_in_group(group_name):
			if not (body is Node3D) or not is_instance_valid(body) or body.is_in_group("BaseGunHitbox"):
				continue
			var dist := global_position.distance_to(body.global_position)
			if dist < best_dist and _has_line_of_sight(body):
				best = body
				best_dist = dist
	return best


func _has_line_of_sight(target: Node3D) -> bool:
	var query := PhysicsRayQueryParameters3D.create(_turret.global_position, target.global_position)
	var mask := 0
	for layer in Utilities.GROUP_LAYER_SCOPE.get("projectile_" + team, {}).get("layer_mask", []):
		mask |= 1 << (layer - 1)
	query.collision_mask = mask
	query.exclude = [_hit_body.get_rid()]
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	return result.is_empty() or result.collider == target


# Where to aim so a shot of this speed meets a moving target.
func _lead_point(target: Node3D, delta: float) -> Vector3:
	var position := target.global_position
	var velocity := Vector3.ZERO
	if target is RigidBody3D:
		velocity = (target as RigidBody3D).linear_velocity
	elif delta > 0.0 and _last_target_position != Vector3.ZERO:
		velocity = (position - _last_target_position) / delta
	_last_target_position = position
	var travel := _turret.global_position.distance_to(position) / maxf(_weapon.projectile_speed, 1.0)
	return position + velocity * travel


# The turret turns about the vertical, the barrel tips up and down; both ease toward the target.
func _aim_at(point: Vector3, delta: float) -> void:
	var local := _turret.get_parent_node_3d().to_local(point) - _turret.position
	var yaw := atan2(-local.x, -local.z)
	_turret.rotation.y = lerp_angle(_turret.rotation.y, yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))
	var flat := Vector2(local.x, local.z).length()
	var pitch := atan2(local.y, flat)
	_barrel.rotation.x = lerp_angle(_barrel.rotation.x, pitch, clampf(TURN_SPEED * delta, 0.0, 1.0))


func _try_fire(point: Vector3) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _next_fire_time:
		return
	var aim := (point - _muzzle.global_position).normalized()
	if (-_barrel.global_basis.z).angle_to(aim) > deg_to_rad(FIRE_CONE_DEGREES):
		return
	var match_node := get_tree().get_first_node_in_group("match")
	if match_node == null or not match_node.has_method("spawn_projectile"):
		return
	_next_fire_time = now + _weapon.cool_down
	# Along the barrel, from its tip; the trailing `true` tints the shot in the team's colour.
	var muzzle := Transform3D(_barrel.global_basis.orthonormalized(), _muzzle.global_position)
	match_node.spawn_projectile(WEAPON_PATH, team, muzzle, true)


# Server only (collision_handler.gd resolves hits there, through base_gun_health.gd).
func take_damage(damage: float, _attacker_id: int = 0) -> void:
	if not multiplayer.is_server() or is_dead or team == "":
		return
	# Same as base_gun.gd: with nobody on this turret's team, shots are absorbed and do nothing.
	if not NetworkManager.peer_teams.values().has(team):
		return
	_hp -= damage
	if _hp > 0.0:
		return
	_destroyed.rpc()
	var match_node := get_tree().get_first_node_in_group("match")
	if match_node:
		match_node.drop_loot_for_structure(global_position)
	await get_tree().create_timer(NetworkManager.base_gun_respawn_seconds).timeout
	if is_instance_valid(self) and is_dead:
		_restored.rpc()


@rpc("authority", "call_local", "reliable")
func _destroyed() -> void:
	if is_dead:
		return
	var explosion := DESTROY_EXPLOSION.instantiate()
	get_parent().add_child(explosion)
	explosion.global_position = global_position
	Utilities.GarbageCollection(explosion, 5.0)
	is_dead = true
	_target = null
	_refresh_state()


@rpc("authority", "call_local", "reliable")
func _restored() -> void:
	is_dead = false
	_hp = MAX_HP
	_refresh_state()

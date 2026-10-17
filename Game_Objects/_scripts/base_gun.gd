extends Node3D
class_name BaseGun
const ASCEND_HEIGHT := 5.0
# 4, not 2: a recon station carries its own gun 2 above the pad (see
# match.gd::_spawn_recon_stations), and a capturing gun must not hover inside it.
const HOVER_HEIGHT_ABOVE_RECON := 4.0
const CAPTURE_DURATION := 10.0
const TRAVEL_SPEED := 12.0
const VERTICAL_SPEED := 1.0

const MAX_HP := 100.0
const HITBOX_RADIUS := 1.0
# A gun's hit body sits on its team's craft layer + this (3..6 -> 11..14), so
# only ENEMY projectiles collide with it and crafts fly straight through. See
# utilities.gd::GROUP_LAYER_SCOPE and collect_bodies.
const HIT_LAYER_OFFSET := 8
const DESTROY_EXPLOSION := preload("res://Weapons/Scenes/explosions/explosion_main.tscn")
const DESTROY_EXPLOSION_SCALE := 0.75

# Turret settings for the (unrelated to capture) auto-fire behavior below -
# no barrel to aim, ever, so every shot is a straight line from this node's
# own origin at whatever it's targeting. Assigned in base_gun.tscn's
# inspector, same as any craft's weapon_node.weapon_settings entries.
@export var weapon_settings: WeaponSettings

# Set by match.gd right after spawn (see _spawn_base_guns) - which enemy
# groups to shoot at (Utilities.GROUP_LAYER_SCOPE[team].target_groups) and
# which projectile-collision layers count as "in the way" for the line-of-
# sight check below (Utilities.GROUP_LAYER_SCOPE["projectile_"+team] - the
# exact mask a shot fired from here would itself collide with, so LOS never
# disagrees with what the shot actually does once it's in flight).
var team: String = ""

# Set (before add_child) for a gun that sits on a recon station instead of
# belonging to a base: it never flies, and its team follows whoever has
# captured the station - no team (neutral) means the gun is simply absent.
var recon: ReconStation = null

@onready var capture_effect: Node3D = $Capture_Effect
@onready var _gun_mesh: MeshInstance3D = $Geometry/Gun
@onready var _wings_mesh: MeshInstance3D = $Geometry/Wings

# Server sets this true the moment a request is accepted (see match.gd) and
# clears it once the whole round trip (there, hold, back) finishes - a busy
# gun isn't offered for a second, different capture in the meantime.
var is_busy: bool = false

var _rest_position: Vector3
var _hp: float = MAX_HP
var is_dead: bool = false
var _hit_body: StaticBody3D
# Bumped whenever a capture flight is cancelled, so the awaits in
# begin_capture know to stop instead of carrying on with a dead gun.
var _flight_serial: int = 0
var _tween: Tween
var _on_capture_aborted: Callable
# Absolute timestamp, same reasoning as weapon_node.gd's _server_next_fire_time
# - a per-frame countdown drifts against wall-clock cool_down over many shots.
var _next_fire_time: float = 0.0


func _ready() -> void:
	_rest_position = global_position
	add_to_group("BaseGunAll")
	_build_hit_body()
	_refresh_state()
	if recon:
		_sync_recon_team()


# Server-only auto-fire: every cool_down seconds (weapon_settings.cool_down),
# look for the nearest enemy within weapon_settings.projectile_range that
# isn't blocked by terrain or another body, and shoot it. Every peer runs
# this same _physics_process, but only the server's copy ever gets past the
# is_server() check - same split as weapon_node.gd's request_fire, just
# there's no player input or RPC involved here, the server decides on its
# own when to fire.
func _physics_process(_delta: float) -> void:
	if recon:
		_sync_recon_team()
	if is_dead:
		return
	# See NetworkManager.is_live_server() for why not plain is_server() (4 base
	# guns per map, every physics tick, made this the loudest of the error spam).
	if not NetworkManager.is_live_server():
		return
	if weapon_settings == null or team == "":
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _next_fire_time:
		return
	var target := _find_target()
	if target == null:
		return
	_next_fire_time = now + weapon_settings.cool_down
	_fire_at(target)


# Nearest valid target wins (rather than select_target()'s random pick in
# utilities.gd - that one's built for a homing missile's narrow forward cone,
# this gun has no forward to speak of and should always prefer whatever's
# closest instead of anything in range). weapon_settings.projectile_range
# doubles as this gun's engagement range - the same number the projectile
# itself self-destructs at (see collision_handler.gd's max_distance), so this
# never targets something a fired shot couldn't reach anyway.
func _find_target() -> Node3D:
	var scope: Dictionary = Utilities.GROUP_LAYER_SCOPE.get(team, {})
	var best: Node3D = null
	var best_dist := weapon_settings.projectile_range
	for group_name in scope.get("target_groups", []):
		for body in get_tree().get_nodes_in_group(group_name):
			if not (body is Node3D) or not is_instance_valid(body):
				continue
			# Other guns' hit bodies share their team's group (that's how
			# projectiles know them as targets) - guns don't shoot guns.
			if body.is_in_group("BaseGunHitbox"):
				continue
			var dist := global_position.distance_to(body.global_position)
			if dist > best_dist:
				continue
			if not _has_line_of_sight(body):
				continue
			best = body
			best_dist = dist
	return best


# Straight raycast from this gun's own origin to the candidate target,
# masked to exactly what a shot fired from here would physically collide
# with (see _obstruction_mask) - true unless something else (terrain, a
# body in between) is hit first.
func _has_line_of_sight(target: Node3D) -> bool:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position, target.global_position)
	query.collision_mask = _obstruction_mask()
	var result := space_state.intersect_ray(query)
	return result.is_empty() or result.collider == target


func _obstruction_mask() -> int:
	var scope: Dictionary = Utilities.GROUP_LAYER_SCOPE.get("projectile_" + team, {})
	var mask := 0
	for layer in scope.get("layer_mask", []):
		mask |= 1 << (layer - 1)
	return mask


# No barrel, no aiming - the muzzle transform is just this node's own
# position with -Z pointed straight at the target, built fresh every shot
# (see collision_handler.gd, which launches every projectile along its own
# -global_transform.basis.z). Goes through match.gd::spawn_projectile, the
# same replicated spawn path weapon_node.gd's request_fire uses, so these
# shots deal damage and show up for every peer exactly like any player's -
# the trailing `true` is the one difference: it tells the projectile to
# recolor itself to this base's team color (matching set_team_color() below)
# instead of keeping weapon_settings.projectile_color, which is what a
# player firing the same weapon still gets.
func _fire_at(target: Node3D) -> void:
	var match_node := get_tree().get_first_node_in_group("match")
	if match_node == null or not match_node.has_method("spawn_projectile"):
		return
	var path := weapon_settings.resource_path
	if path.is_empty():
		push_warning("base_gun: weapon_settings has no resource_path (not a saved .tres?)")
		return
	var direction := (target.global_position - global_position).normalized()
	var muzzle := Transform3D(Basis.looking_at(direction, Vector3.UP), global_position)
	match_node.spawn_projectile(path, team, muzzle, true)


# The one way a gun's team changes. Team drives the tint, the hit body's
# layer/group and (via match.gd) what the gun shoots. "" = neutral recon gun.
func set_team(new_team: String) -> void:
	if new_team == team and _hit_body != null:
		return
	if _hit_body:
		if team != "":
			_hit_body.remove_from_group(team)
	team = new_team
	if team != "":
		set_team_color(ReconStation.render_color_for_team(team))
	_refresh_state()


func _sync_recon_team() -> void:
	set_team(ReconStation.team_for_color(recon.captured_color))


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
	_hit_body.add_to_group("BaseGunHitbox")


# Visibility, hit body layer/group and the radar group all follow the same
# two facts: has a team, and is alive.
func _refresh_state() -> void:
	var active := team != "" and not is_dead
	visible = active
	if _hit_body == null:
		return
	var layer_data: Dictionary = Utilities.GROUP_LAYER_SCOPE.get(team, {})
	if active and not layer_data.is_empty():
		_hit_body.collision_layer = 1 << (int(layer_data["layer"]) + HIT_LAYER_OFFSET - 1)
		if not _hit_body.is_in_group(team):
			_hit_body.add_to_group(team)
		add_to_group("BaseGun")
	else:
		_hit_body.collision_layer = 0
		remove_from_group("BaseGun")
		if team != "" and _hit_body.is_in_group(team):
			_hit_body.remove_from_group(team)


# Server-only (collision_handler.gd only resolves hits there, via
# base_gun_health.gd). HP is server state; everyone else just hears about the
# destruction and the return.
func take_damage(damage: float, attacker_id: int = 0) -> void:
	if not multiplayer.is_server() or is_dead or team == "":
		return
	# Nobody on this gun's team is here to be hurt by it going down - shots
	# still land on it (so they are absorbed), they just do nothing.
	if not NetworkManager.peer_teams.values().has(team):
		return
	_hp -= damage
	if _hp > 0.0:
		return
	_destroyed.rpc()
	var match_node := get_tree().get_first_node_in_group("match")
	if match_node:
		match_node.on_gun_destroyed(attacker_id)
	var delay := NetworkManager.base_gun_respawn_seconds
	await get_tree().create_timer(delay).timeout
	if is_instance_valid(self) and is_dead:
		_restored.rpc()


@rpc("authority", "call_local", "reliable")
func _destroyed() -> void:
	if is_dead:
		return
	var explosion := DESTROY_EXPLOSION.instantiate()
	get_parent().add_child(explosion)
	explosion.global_position = global_position
	explosion.scale = Vector3.ONE * DESTROY_EXPLOSION_SCALE
	Utilities.GarbageCollection(explosion, 5.0)
	_apply_dead()


# Late joiners: same state as _destroyed without replaying the explosion.
@rpc("authority", "reliable")
func _sync_dead() -> void:
	_apply_dead()


func _apply_dead() -> void:
	is_dead = true
	_cancel_flight()
	_refresh_state()


@rpc("authority", "call_local", "reliable")
func _restored() -> void:
	is_dead = false
	_hp = MAX_HP
	is_busy = false
	global_position = _rest_position
	reset_physics_interpolation()
	_refresh_state()


# A capture in flight dies with the gun: the recon stays as it was, and the
# server is told so the recon can be captured again.
func _cancel_flight() -> void:
	_flight_serial += 1
	if _tween:
		_tween.kill()
	set_effect_active(false)
	if _on_capture_aborted.is_valid():
		_on_capture_aborted.call()
	_on_capture_aborted = Callable()


# Called once from match.gd right after spawning (see _spawn_base_guns) -
# every BaseGun instance shares the same textured StandardMaterial3D baked
# into base_gun.tscn's Gun/Wings meshes, so painting straight onto that
# resource would recolor every team's guns at once. set_surface_override_material
# keeps the tint local to this one MeshInstance3D instead, same reasoning as
# colorable_mesh.gd/recon_station.gd::set_pad_color, just via the surface
# override rather than material_override since that's how these meshes are
# authored (material lives on the mesh surface, not on the node).
func set_team_color(color: Color) -> void:
	_tint_surface(_gun_mesh, color)
	_tint_surface(_wings_mesh, color)


func _tint_surface(mesh_instance: MeshInstance3D, color: Color) -> void:
	var mat := mesh_instance.get_active_material(0)
	if not (mat is StandardMaterial3D):
		return
	mat = mat.duplicate()
	mat.albedo_color = color
	mesh_instance.set_surface_override_material(0, mat)


func set_effect_active(active: bool) -> void:
	capture_effect.visible = active
	for child in capture_effect.get_children():
		if child is GPUParticles3D:
			child.emitting = active


# Runs identically on every peer (called from match.gd's broadcast RPC, not
# locally decided) - flies out to hover over `recon`, holds there with the
# effect on for CAPTURE_DURATION, calls on_capture_ready (this is where the
# caller should actually apply the color change - while the gun's still
# there, not after it's already flown home), then reverses the whole path
# back to rest.
func begin_capture(target_recon: Node3D, on_capture_ready: Callable, on_aborted: Callable = Callable()) -> void:
	is_busy = true
	_on_capture_aborted = on_aborted
	var serial := _flight_serial
	var cruise_y := _rest_position.y + ASCEND_HEIGHT
	var above_base := Vector3(_rest_position.x, cruise_y, _rest_position.z)
	var above_recon := Vector3(target_recon.global_position.x, cruise_y, target_recon.global_position.z)
	var hover_position := Vector3(target_recon.global_position.x, target_recon.global_position.y + HOVER_HEIGHT_ABOVE_RECON, target_recon.global_position.z)

	await _move_to(above_base, VERTICAL_SPEED)
	if serial != _flight_serial:
		return
	await _move_to(above_recon, TRAVEL_SPEED)
	if serial != _flight_serial:
		return
	await _move_to(hover_position, VERTICAL_SPEED)
	if serial != _flight_serial:
		return

	set_effect_active(true)
	await get_tree().create_timer(CAPTURE_DURATION).timeout
	if serial != _flight_serial:
		return
	set_effect_active(false)
	_on_capture_aborted = Callable()
	on_capture_ready.call()

	await _move_to(above_recon, VERTICAL_SPEED)
	if serial != _flight_serial:
		return
	await _move_to(above_base, TRAVEL_SPEED)
	if serial != _flight_serial:
		return
	await _move_to(_rest_position, VERTICAL_SPEED)
	if serial != _flight_serial:
		return
	is_busy = false


func _move_to(target: Vector3, speed: float) -> void:
	var distance := global_position.distance_to(target)
	if distance < 0.01:
		return
	_tween = create_tween()
	_tween.tween_property(self, "global_position", target, distance / speed)
	await _tween.finished

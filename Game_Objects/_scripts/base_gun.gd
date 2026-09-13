extends Node3D
class_name BaseGun

# Movement/timing only - the actual capture-beam/particle look lives on
# Capture_Effect's own children (see set_effect_active) and is expected to
# get built out further; this just turns whatever's there on and off at the
# right moments.

const ASCEND_HEIGHT := 5.0
const HOVER_HEIGHT_ABOVE_RECON := 2.0
const CAPTURE_DURATION := 10.0
const TRAVEL_SPEED := 12.0  # units/sec, horizontal cruise legs only
const VERTICAL_SPEED := 1.0  # units/sec, ascend/descend legs only

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

@onready var capture_effect: Node3D = $Capture_Effect
@onready var _gun_mesh: MeshInstance3D = $Geometry/Gun
@onready var _wings_mesh: MeshInstance3D = $Geometry/Wings

# Server sets this true the moment a request is accepted (see match.gd) and
# clears it once the whole round trip (there, hold, back) finishes - a busy
# gun isn't offered for a second, different capture in the meantime.
var is_busy: bool = false

var _rest_position: Vector3
# Absolute timestamp, same reasoning as weapon_node.gd's _server_next_fire_time
# - a per-frame countdown drifts against wall-clock cool_down over many shots.
var _next_fire_time: float = 0.0


func _ready() -> void:
	_rest_position = global_position


# Server-only auto-fire: every cool_down seconds (weapon_settings.cool_down),
# look for the nearest enemy within weapon_settings.projectile_range that
# isn't blocked by terrain or another body, and shoot it. Every peer runs
# this same _physics_process, but only the server's copy ever gets past the
# is_server() check - same split as weapon_node.gd's request_fire, just
# there's no player input or RPC involved here, the server decides on its
# own when to fire.
func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server():
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
# shots deal damage and show up for every peer exactly like any player's.
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
	match_node.spawn_projectile(path, team, muzzle)


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
func begin_capture(recon: Node3D, on_capture_ready: Callable) -> void:
	is_busy = true
	var cruise_y := _rest_position.y + ASCEND_HEIGHT
	var above_base := Vector3(_rest_position.x, cruise_y, _rest_position.z)
	var above_recon := Vector3(recon.global_position.x, cruise_y, recon.global_position.z)
	var hover_position := Vector3(recon.global_position.x, recon.global_position.y + HOVER_HEIGHT_ABOVE_RECON, recon.global_position.z)

	await _move_to(above_base, VERTICAL_SPEED)
	await _move_to(above_recon, TRAVEL_SPEED)
	await _move_to(hover_position, VERTICAL_SPEED)

	set_effect_active(true)
	await get_tree().create_timer(CAPTURE_DURATION).timeout
	set_effect_active(false)
	on_capture_ready.call()

	await _move_to(above_recon, VERTICAL_SPEED)
	await _move_to(above_base, TRAVEL_SPEED)
	await _move_to(_rest_position, VERTICAL_SPEED)
	is_busy = false


func _move_to(target: Vector3, speed: float) -> void:
	var distance := global_position.distance_to(target)
	if distance < 0.01:
		return
	var tween := create_tween()
	tween.tween_property(self, "global_position", target, distance / speed)
	await tween.finished

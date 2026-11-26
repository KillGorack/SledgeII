class_name BotBrain
extends Node

# Drives a bot's craft in place of a player's keyboard. Lives on the host only, as a child of the bot's craft (see
# match.gd::_spawn_craft); movement.gd reads the outputs below every physics tick exactly where it would otherwise
# read the keys, so a bot drives with the same physics, speeds and limits as a player.
#
# No navigation mesh: the maps have none and are not built for one. Instead the bot steers straight at a goal and
# feels its way with three short rays fanned out ahead (walls, crafts, and drops it would fall down). When something
# blocks the way it picks a side and follows the obstacle round until the straight line to the goal is open again
# (steering at the goal and away from a wall at the same time just parks it facing the wall). Still going nowhere
# after that: it backs out, turns, and tries the other side.
#
# Goals: the nearest enemy craft it can see (or, failing that, the nearest in range, to go and find), otherwise a
# recon station or an enemy base. In a fight it closes to a comfortable range for its weapon, then circles the
# enemy, weaving from side to side rather than sitting still, and reverses away if one gets right up close. It fires
# through weapon_node.gd the same way a player does (cooldown, power and ammo all apply), only when it has had the
# target in sight for a moment, and with a deliberate aiming error so it can be beaten - see Skill below.

# --- Outputs, read by movement.gd -----------------------------------------------------------------------------
var drive: float = 0.0 # -1..1, + = forward
var turn: float = 0.0 # -1..1, + = left
var rockets: bool = false
var aim_yaw: float = 0.0 # degrees, turret, + = left
var aim_pitch: float = 0.0 # degrees, barrel, + = up
# Read by weapon_node.gd:
var fire: bool = false # trigger held
var weapon_index: int = 0 # which of the craft's weapons to use

# --- Tuning ---------------------------------------------------------------------------------------------------
const THINK_SECONDS := 0.1 # how often it re-plans; the outputs hold in between
const ENGAGE_RANGE := 60.0 # enemy crafts closer than this become the goal
const FIGHT_RANGE_MAX := 25.0 # closes to within this of an enemy (or nearer, for a short-range weapon) ...
const FIGHT_RANGE_MIN := 10.0 # ... but never plans to fight nearer than this
const TOO_CLOSE := 5.0 # reverses away when an enemy is nearer than this
const STRAFE_ANGLE := deg_to_rad(55.0) # in range, drives this far off the line to the enemy, so it circles round it
const STRAFE_SWITCH_SECONDS := Vector2(2.5, 5.0) # and swaps sides every so often (random in this range)

# Skill: the host's "Bot skill" setting (NetworkManager.bot_skill) picks one row. Per row:
#   aim_error  - the most its aim is off by, either way, in each direction (degrees)
#   reaction   - has to have seen a target this long before it starts shooting (seconds)
#   fire_cone  - only fires when the turret is this close to where it means to aim (degrees)
#   turret     - how fast it can swing the turret (degrees a second)
#   lead       - how much of a moving target's travel it allows for (0 = shoots where you are, 1 = where you'll be)
const SKILLS := [
	{"name": "Easy", "aim_error": 9.0, "reaction": 1.4, "fire_cone": 6.0, "turret": 60.0, "lead": 0.4},
	{"name": "Normal", "aim_error": 6.0, "reaction": 0.9, "fire_cone": 5.0, "turret": 90.0, "lead": 0.75},
	{"name": "Hard", "aim_error": 3.0, "reaction": 0.5, "fire_cone": 4.0, "turret": 120.0, "lead": 1.0},
]
const AIM_ERROR_CHANGE_SECONDS := 0.8 # how often the aiming error changes
var aim_error_degrees: float
var reaction_seconds: float
var fire_cone_degrees: float
var turret_degrees_per_second: float # read by movement.gd
var lead_fraction: float
const AIM_HEIGHT := -0.15 # aims this far above the target's origin (the turret pivot); below = at the hull
const TURRET_REACH_DEGREES := 85.0 # the turret turns 90 either way; beyond this the hull has to turn instead
const ARRIVE := 6.0 # a wander goal counts as reached this close
const WANDER_GIVE_UP_SECONDS := 30.0 # picks another wander goal if one takes longer than this
const HUNT_CHANCE := 0.6 # when roaming, how often it heads for where an enemy is rather than a recon or base
const HUNT_REFRESH_SECONDS := 8.0 # a hunt goal is re-read this often, as the enemy moves
const FEELER_SIDE_ANGLE := deg_to_rad(35.0)
const FEELER_LENGTH := 3.0 # plus FEELER_PER_SPEED for every m/s it is doing
const FEELER_PER_SPEED := 0.8
const FEELER_HEIGHT := 0.15 # above the craft's origin, so the floor itself doesn't count
const STEEP_NORMAL_Y := 0.6 # a hit surface flatter than this is a ramp to drive up, not a wall
const DROP_LOOK_AHEAD := 2.5 # checks for a drop this far ahead
const DROP_MAX := 2.0 # deeper than this is a drop to avoid (falls hurt)
const STUCK_SPEED := 0.25 # m/s; trying to drive but slower than this for STUCK_SECONDS = stuck
const STUCK_SECONDS := 1.5
const BACKUP_SECONDS := 1.2
const TURN_GAIN := 2.0 # how hard it turns for a given heading error (radians)
const BLOCKED_FRACTION := 0.6 # something nearer than this much of the feeler length ahead = blocked, go round it
const DETOUR_MIN_SECONDS := 0.8 # follows an obstacle at least this long before heading for the goal again
const DETOUR_MAX_SECONDS := 8.0 # gives up going round after this long (and picks another goal if wandering)
const DETOUR_CLEAR := 6.0 # the line to the goal counts as open when it is clear this far (or all the way)

var craft: RigidBody3D
var _health: Node
var _weapon: Node
var _match: Node
var _think_left: float = 0.0
var _goal := Vector3.INF
var _goal_since: float = 0.0
var _hunting: bool = false
var _enemy: Node3D = null
var _stuck_for: float = 0.0
var _backup_left: float = 0.0
var _backup_turn: float = 1.0
var _clock: float = 0.0
var _detour_side: float = 0.0 # 0 = heading straight for the goal; +1 / -1 = going round something to the left / right
var _detour_since: float = 0.0
var _holding: bool = false # backing off from an enemy on purpose, so not "stuck"
var _enemy_in_sight: bool = false
var _seen_since: float = 0.0
var _enemy_velocity := Vector3.ZERO # estimated from where it has been: a remote player's copy on the host is
var _enemy_last_pos := Vector3.INF # kinematic, so its linear_velocity is always zero
var _strafe_side: float = 1.0
var _strafe_switch_at: float = 0.0
var _aim_error := Vector2.ZERO # degrees (yaw, pitch)
var _aim_error_at: float = 0.0
@onready var _movement: Node = get_parent().get_node_or_null("movement_node")
@onready var _power: Node = get_parent().get_node_or_null("power_node")
@onready var _barrel: Node3D = get_parent().get_node_or_null("Turret/Barrel")


func _ready() -> void:
	craft = get_parent() as RigidBody3D
	_health = craft.get_node_or_null("health_node")
	_weapon = craft.get_node_or_null("weapon_node")
	_match = get_tree().get_first_node_in_group("match")
	var skill: Dictionary = SKILLS[clampi(NetworkManager.bot_skill, 0, SKILLS.size() - 1)]
	aim_error_degrees = skill.aim_error
	reaction_seconds = skill.reaction
	fire_cone_degrees = skill.fire_cone
	turret_degrees_per_second = skill.turret
	lead_fraction = skill.lead
	# Plan before movement.gd reads the outputs in the same tick.
	process_physics_priority = -10
	# Spread the bots' thinking over different ticks.
	_think_left = randf() * THINK_SECONDS


func _physics_process(delta: float) -> void:
	_clock += delta
	if craft == null or _dead():
		_stop()
		return
	_track_stuck(delta)
	if _backup_left > 0.0:
		_backup_left -= delta
		drive = -0.8
		turn = _backup_turn
		return
	_think_left -= delta
	if _think_left > 0.0:
		return
	_think_left = THINK_SECONDS
	_think()


func _think() -> void:
	# On its back: movement.gd rolls it over when told which way.
	if craft.global_basis.y.dot(Vector3.UP) < 0.3:
		drive = 0.0
		turn = 1.0
		fire = false
		return
	_pick_enemy()
	_holding = false
	if _enemy == null:
		_drive_to(_wander_goal())
		_aim_ahead()
		return
	var to_enemy := _enemy.global_position - craft.global_position
	to_enemy.y = 0.0
	var distance := to_enemy.length()
	weapon_index = _choose_weapon(distance)
	var fight_range := FIGHT_RANGE_MAX
	if weapon_index >= 0:
		fight_range = clampf(_weapon.effective(_weapon.weapon_settings[weapon_index]).projectile_range * 0.5, FIGHT_RANGE_MIN, FIGHT_RANGE_MAX)
	if not _enemy_in_sight or distance > fight_range:
		_drive_to(_enemy.global_position)
	elif distance < TOO_CLOSE:
		# Back away, turning to keep it in front.
		_end_detour()
		_holding = true
		drive = -0.6
		turn = clampf(_heading_error(to_enemy) * TURN_GAIN, -1.0, 1.0)
	else:
		_strafe(to_enemy)
	_aim_at_enemy(distance)


# Heads for `goal`, feeling the way round anything in between.
func _drive_to(goal: Vector3) -> void:
	var to_goal := goal - craft.global_position
	to_goal.y = 0.0
	_steer_along(to_goal, to_goal.length())


# Circles the enemy: drives at an angle off the line to it, swapping sides now and then.
func _strafe(to_enemy: Vector3) -> void:
	if _clock >= _strafe_switch_at:
		_strafe_side = -_strafe_side
		_strafe_switch_at = _clock + randf_range(STRAFE_SWITCH_SECONDS.x, STRAFE_SWITCH_SECONDS.y)
	var heading := to_enemy.normalized().rotated(Vector3.UP, _strafe_side * STRAFE_ANGLE)
	_steer_along(heading * FIGHT_RANGE_MAX, FIGHT_RANGE_MAX)


func _steer_along(to_goal: Vector3, distance: float) -> void:
	var feel := _feel_ahead(to_goal, distance)
	var steer := feel.x
	var want_drive := feel.y
	# Slow right down to turn when the way it wants to go is well off the nose; tracks can pivot on the spot.
	if want_drive > 0.0:
		want_drive *= clampf(1.0 - (absf(steer) - 0.4) / 1.2, 0.15, 1.0)
	drive = want_drive
	turn = clampf(steer * TURN_GAIN, -1.0, 1.0)


func _dead() -> bool:
	return _health != null and (_health._is_destroyed or (_health.has_method("is_frozen") and _health.is_frozen()))


func _stop() -> void:
	drive = 0.0
	turn = 0.0
	rockets = false
	fire = false
	_enemy = null
	_stuck_for = 0.0
	_backup_left = 0.0


# Signed angle (radians) from the craft's nose to `direction`, both flattened; + = the goal is to the left.
func _heading_error(direction: Vector3) -> float:
	var forward := -craft.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001 or direction.length_squared() < 0.0001:
		return 0.0
	return forward.normalized().signed_angle_to(direction.normalized(), Vector3.UP)


# --- Goals ------------------------------------------------------------------------------------------------------

# The nearest enemy craft it can see; if it can see none, the nearest one in range (to go and find). Sets _enemy,
# _enemy_in_sight, and keeps the sighting time and velocity estimate for the one it is after.
func _pick_enemy() -> void:
	var my_team: String = _weapon.team if _weapon else ""
	var nearest: Node3D = null
	var nearest_distance := ENGAGE_RANGE
	var seen: Node3D = null
	var seen_distance := ENGAGE_RANGE
	for other in get_tree().get_nodes_in_group("Craft"):
		if other == craft or not (other is Node3D) or not other.visible:
			continue
		var other_weapon := other.get_node_or_null("weapon_node")
		if other_weapon == null or other_weapon.team == my_team:
			continue
		var other_health := other.get_node_or_null("health_node")
		if other_health and other_health._is_destroyed:
			continue
		var distance := craft.global_position.distance_to(other.global_position)
		if distance >= ENGAGE_RANGE:
			continue
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = other
		if distance < seen_distance and _can_see(other):
			seen_distance = distance
			seen = other
	var target: Node3D = seen if seen else nearest
	if target != _enemy:
		_enemy_last_pos = Vector3.INF
		_enemy_velocity = Vector3.ZERO
		_seen_since = _clock
	var in_sight := seen != null
	if in_sight and not _enemy_in_sight:
		_seen_since = _clock
	_enemy = target
	_enemy_in_sight = in_sight
	if _enemy:
		var position := _enemy.global_position
		if _enemy_last_pos != Vector3.INF:
			_enemy_velocity = _enemy_velocity.lerp((position - _enemy_last_pos) / THINK_SECONDS, 0.5)
		_enemy_last_pos = position


# A clear line from the barrel to the target, through the world (other crafts don't block it).
func _can_see(target: Node3D) -> bool:
	var from := _barrel.global_position if _barrel else craft.global_position
	var to := target.global_position + Vector3.UP * AIM_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(from, to, _world_mask(), [craft.get_rid()])
	return craft.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


# Somewhere worth driving to when no enemy is near: a recon station or another team's base, else a random spot.
func _wander_goal() -> Vector3:
	var reached := _goal != Vector3.INF and Vector2(_goal.x - craft.global_position.x, _goal.z - craft.global_position.z).length() < ARRIVE
	var stale_hunt := _hunting and _clock - _goal_since > HUNT_REFRESH_SECONDS
	if _goal == Vector3.INF or reached or stale_hunt or _clock - _goal_since > WANDER_GIVE_UP_SECONDS:
		_pick_wander_goal()
	return _goal


func _pick_wander_goal() -> void:
	_goal_since = _clock
	_hunting = false
	if randf() < HUNT_CHANCE:
		var hunted := _hunt_target()
		if hunted != Vector3.INF:
			_goal = hunted
			_hunting = true
			return
	var options: Array[Vector3] = []
	for recon in get_tree().get_nodes_in_group("Recon"):
		if recon is Node3D:
			options.append(recon.global_position)
	var my_team: String = _weapon.team if _weapon else ""
	if _match and "_spawn_points_by_team" in _match:
		for team in _match._spawn_points_by_team:
			if team == my_team:
				continue
			for pad in _match._spawn_points_by_team[team]:
				if pad is Node3D:
					options.append(pad.global_position)
	# Not the one it is already at.
	options = options.filter(func(p: Vector3): return Vector2(p.x - craft.global_position.x, p.z - craft.global_position.z).length() > ARRIVE * 2.0)
	if options.is_empty():
		var angle := randf() * TAU
		_goal = craft.global_position + Vector3(cos(angle), 0.0, sin(angle)) * randf_range(15.0, 40.0)
	else:
		_goal = options.pick_random()
	_goal_since = _clock


# Where one of the three nearest enemy crafts is (any distance), or INF if there are none.
func _hunt_target() -> Vector3:
	var my_team: String = _weapon.team if _weapon else ""
	var found: Array = []
	for other in get_tree().get_nodes_in_group("Craft"):
		if other == craft or not (other is Node3D) or not other.visible:
			continue
		var other_weapon := other.get_node_or_null("weapon_node")
		if other_weapon == null or other_weapon.team == my_team:
			continue
		var other_health := other.get_node_or_null("health_node")
		if other_health and other_health._is_destroyed:
			continue
		found.append([craft.global_position.distance_to(other.global_position), other.global_position])
	if found.is_empty():
		return Vector3.INF
	found.sort_custom(func(a, b): return a[0] < b[0])
	return found[randi() % mini(3, found.size())][1]


# --- Feeling the way ----------------------------------------------------------------------------------------

# Three rays ahead, plus one along the line to the goal while going round something. Returns (the heading to steer
# for in radians from the nose, + = left; how much of full speed to use, 0..1).
func _feel_ahead(to_goal: Vector3, goal_distance: float) -> Vector2:
	var forward := -craft.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return Vector2(0.0, 1.0)
	forward = forward.normalized()
	var length := FEELER_LENGTH + FEELER_PER_SPEED * craft.linear_velocity.length()
	var centre := _free_distance(forward, length)
	var left := _free_distance(forward.rotated(Vector3.UP, FEELER_SIDE_ANGLE), length)
	var right := _free_distance(forward.rotated(Vector3.UP, -FEELER_SIDE_ANGLE), length)
	var blocked := centre < length * BLOCKED_FRACTION or _drop_ahead(forward)
	var goal_heading := _heading_error(to_goal)
	if _detour_side != 0.0:
		var detour_time := _clock - _detour_since
		var goal_line_open := _free_distance(to_goal.normalized(), minf(goal_distance, DETOUR_CLEAR)) >= minf(goal_distance, DETOUR_CLEAR) - 0.01
		if detour_time > DETOUR_MAX_SECONDS:
			_end_detour()
			if _enemy == null:
				_goal = Vector3.INF
		elif detour_time > DETOUR_MIN_SECONDS and goal_line_open and not blocked:
			_end_detour()
	elif blocked:
		_start_detour(1.0 if left >= right else -1.0)
	if _detour_side == 0.0:
		# Straight for the goal, edging away from anything brushing past a side feeler.
		var steer := goal_heading
		if left < length:
			steer -= 0.5 * (1.0 - left / length)
		if right < length:
			steer += 0.5 * (1.0 - right / length)
		return Vector2(steer, 1.0)
	# Going round: turn away while it is still in the way, otherwise run along it, easing back toward it when the
	# feeler on its side comes clear (that is the end of the wall, or a gap, to go round).
	var wall_side_free := right if _detour_side > 0.0 else left
	if blocked:
		return Vector2(_detour_side * 1.4, clampf(centre / length, 0.0, 1.0) * 0.5)
	if wall_side_free >= length:
		return Vector2(-_detour_side * 0.5, 0.8)
	return Vector2(_detour_side * 0.15, 0.9)


func _start_detour(side: float) -> void:
	_detour_side = side
	_detour_since = _clock


func _end_detour() -> void:
	_detour_side = 0.0


# How far the craft could go along `direction` before something steep (a wall, a craft) is in the way.
func _free_distance(direction: Vector3, length: float) -> float:
	var space := craft.get_world_3d().direct_space_state
	var from := craft.global_position + Vector3.UP * FEELER_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * length, _obstacle_mask(), [craft.get_rid()])
	var hit := space.intersect_ray(query)
	if hit.is_empty() or hit.normal.y > STEEP_NORMAL_Y:
		return length
	return from.distance_to(hit.position)


# True when the ground a little way ahead falls away by more than DROP_MAX.
func _drop_ahead(forward: Vector3) -> bool:
	var space := craft.get_world_3d().direct_space_state
	var ahead := craft.global_position + forward * DROP_LOOK_AHEAD + Vector3.UP * 0.5
	var query := PhysicsRayQueryParameters3D.create(ahead, ahead + Vector3.DOWN * (DROP_MAX + 1.0), _world_mask(), [craft.get_rid()])
	return space.intersect_ray(query).is_empty()


func _world_mask() -> int:
	return 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)


# The world plus every team's crafts.
func _obstacle_mask() -> int:
	var mask := _world_mask()
	for team in NetworkManager.TEAM_NAMES:
		if Utilities.GROUP_LAYER_SCOPE.has(team):
			mask |= 1 << (Utilities.GROUP_LAYER_SCOPE[team]["layer"] - 1)
	return mask


# Meant to be moving but going nowhere: back up and turn for a moment, then go round the other way (with a new goal if
# wandering and it has already tried both ways).
func _track_stuck(delta: float) -> void:
	if _backup_left > 0.0 or _holding:
		_stuck_for = 0.0
		return
	var flat := craft.linear_velocity
	flat.y = 0.0
	if flat.length() < STUCK_SPEED:
		_stuck_for += delta
	else:
		_stuck_for = 0.0
	if _stuck_for >= STUCK_SECONDS:
		_stuck_for = 0.0
		_backup_left = BACKUP_SECONDS
		var side := _detour_side
		if side == 0.0:
			side = 1.0 if randf() < 0.5 else -1.0
		elif _enemy == null:
			_goal = Vector3.INF
		_backup_turn = side
		# Comes out of the backup already going round the other way.
		_start_detour(-side)


# --- Weapons and aim ------------------------------------------------------------------------------------------

# The best weapon to use at `distance`: in range, does something to whoever it hits, and can be fired right now
# (power, ammo). Damage per second decides; a weapon that only shoves, blasts or freezes (the Repulsor) comes after
# anything that does damage, so it is used when there is nothing else - a Repulsor-only arena, say. -1 when none
# will do (it still drives and aims, it just doesn't shoot).
func _choose_weapon(distance: float) -> int:
	if _weapon == null:
		return -1
	var best := -1
	var best_rate := 0.0
	for i in _weapon.weapon_settings.size():
		var base: WeaponSettings = _weapon.weapon_settings[i]
		if base == null or base.projectile_prefab == null or base.weapon_kind == WeaponSettings.WeaponKind.OBJECT:
			continue
		var settings: WeaponSettings = _weapon.effective(base)
		var effect := settings.projectile_force + settings.explosive_force + settings.freeze_timer
		if (settings.hit_points <= 0.0 and effect <= 0.0) or distance > settings.projectile_range * 0.9:
			continue
		if settings.power_consumption > 0.0 and (_power == null or _power.current_power < settings.power_consumption):
			continue
		if settings.projectile_count_capacity != 0 and (i >= _weapon._ammo_remaining.size() or _weapon._ammo_remaining[i] < settings.projectile_count):
			continue
		var rate := (settings.hit_points + effect * 0.001) * settings.projectile_count / maxf(settings.cool_down, 0.1)
		if rate > best_rate:
			best_rate = rate
			best = i
	return best


# Turret on the enemy (where it will be when the shot gets there, and allowing for drop on a shell), give or take
# the aiming error; trigger held once it has been seen for a moment and the turret is on the mark.
func _aim_at_enemy(_distance: float) -> void:
	var settings: WeaponSettings = null
	if weapon_index >= 0:
		settings = _weapon.effective(_weapon.weapon_settings[weapon_index])
	var from := _barrel.global_position if _barrel else craft.global_position
	var target := _enemy.global_position + Vector3.UP * AIM_HEIGHT
	var speed := settings.projectile_speed if settings and settings.projectile_speed > 0.0 else 0.0
	if speed > 0.0:
		for i in 2:
			target = _enemy.global_position + Vector3.UP * AIM_HEIGHT + _enemy_velocity * lead_fraction * (from.distance_to(target) / speed)
	var local := craft.global_basis.inverse() * (target - from)
	var yaw := rad_to_deg(atan2(-local.x, -local.z))
	var pitch := rad_to_deg(atan2(local.y, Vector2(local.x, local.z).length()))
	if settings and settings.affected_by_gravity and speed > 0.0:
		pitch += _drop_compensation(target - from, speed)
	if _clock >= _aim_error_at:
		_aim_error = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * aim_error_degrees
		_aim_error_at = _clock + AIM_ERROR_CHANGE_SECONDS
	aim_yaw = yaw + _aim_error.x
	aim_pitch = pitch + _aim_error.y
	fire = false
	if settings == null or not _enemy_in_sight or _clock - _seen_since < reaction_seconds:
		return
	if absf(yaw) > TURRET_REACH_DEGREES or _movement == null:
		return
	if absf(_movement.yaw - aim_yaw) <= fire_cone_degrees and absf(_movement.pitch - aim_pitch) <= fire_cone_degrees:
		fire = true


# How much higher (degrees) to point a shell that falls under gravity than straight at the target, to land on it.
func _drop_compensation(offset: Vector3, speed: float) -> float:
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var d := Vector2(offset.x, offset.z).length()
	var h := offset.y
	if d < 0.5:
		return 0.0
	var straight := atan2(h, d)
	var root := speed * speed * speed * speed - g * (g * d * d + 2.0 * h * speed * speed)
	if root < 0.0:
		return rad_to_deg(deg_to_rad(45.0) - straight) # out of reach: lob it as far as it goes
	var lobbed := atan((speed * speed - sqrt(root)) / (g * d))
	return rad_to_deg(lobbed - straight)


func _aim_ahead() -> void:
	aim_yaw = 0.0
	aim_pitch = 0.0
	fire = false

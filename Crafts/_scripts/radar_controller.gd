extends Control

# Minimap-style radar, visually modeled on the predecessor project's (Sledge)
# radar_detection.gd - one blip per node found in each target_defs[] entry's
# group_name, sized/shaped/colored per that entry, plus a fixed self blip at
# center. zoom_radar cycles range via zoom_levels. No projectile tracking.
#
# target_defs is the whole point: add a new trackable kind (a mine, loot,
# whatever) by tagging it with a group in the scene and adding one row here
# in the Inspector - group_name/color/size/shape, no script editing needed.
# The one thing that table CAN'T hold is dynamic color - a recon station's
# color depends on which team captured it (captured_color, changes mid-match)
# and a craft's depends on which team it is (weapon_node.team) - neither is a
# fact the Inspector can know ahead of time, so those two group names are
# special-cased in _color_for() to compute color live instead of using the
# entry's static color. Everything else just uses the table as-is.
#
# Entirely client-local, no networking of its own needed: a craft's team and
# a station's captured_color are already correct on every peer (team's baked
# in at spawn from replicated spawn data - see match.gd::_spawn_craft; a
# station's captured_color comes from a map-authored group tag, see
# recon_station.gd::_apply_fixed_color_from_marker) - this just polls scene
# state every peer already has locally, the same way power_node.gd does.
@export var target_defs: Array[RadarTargetDef] = []
@export var self_size: Vector2 = Vector2(5, 5)
@export var radar_range: float = 100.0
# radar_range above is the 1.0x entry's baseline - zoom_radar cycles through
# these multipliers, same idea as the predecessor's zoom_scale array.
@export var zoom_levels: Array[float] = [2.0, 1.0, 0.75, 0.5, 0.25]
var _zoom_index: int = 1

# Two levels up: this Control -> Hud_InGame -> the craft root.
@onready var _craft: Node3D = get_node("../../..")
# Facing comes from the turret, not the hull - the turret (and the camera
# mounted on its Barrel) yaws independently of the craft's own movement (see
# movement.gd::_physics_process setting Turret.rotation_degrees.y from look
# input), so this is "the direction we're actually looking", same reason the
# predecessor's radar_detection.gd was parented under Turret instead of the
# vehicle root.
@onready var _turret: Node3D = _find_turret()

const RadarDotScript := preload("res://Crafts/_scripts/radar_dot.gd")

var _blips: Dictionary = {}
var _self_blip: Control


func _find_turret() -> Node3D:
	var turret_node := _craft.get_node_or_null("Turret")
	return turret_node if turret_node else _craft


func _ready() -> void:
	# Same trick as hud_controller.gd::_ready - this Control's own authority
	# already matches the craft's owning peer, so every other peer's copy of
	# this same scene just stays hidden forever.
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return

	# Always dead-center, own team color, round to stand out from the square
	# recon blips.
	var weapon_node = _craft.get_node_or_null("weapon_node")
	_self_blip = RadarDotScript.new()
	_self_blip.mouse_filter = MOUSE_FILTER_IGNORE
	_self_blip.dot_color = ReconStation.render_color_for_team(weapon_node.team) if weapon_node else Color.WHITE
	_self_blip.size = self_size
	add_child(_self_blip)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("zoom_radar"):
		_zoom_index = (_zoom_index + 1) % zoom_levels.size()
	var effective_range: float = radar_range * zoom_levels[_zoom_index]

	_self_blip.position = size / 2.0 - self_size / 2.0

	var origin: Vector3 = _craft.global_position
	# Yaw-only facing, quaternion component-zeroing rather than reading
	# global_rotation.y directly - same approach (and same reason: avoids
	# Euler gimbal weirdness) as the predecessor's radar_detection.gd. Off
	# the turret, not the hull - see _find_turret.
	var yaw := _turret.global_transform.basis.get_rotation_quaternion()
	yaw.x = 0
	yaw.z = 0
	var facing := Basis(yaw.normalized())

	var seen: Dictionary = {}

	for target_def in target_defs:
		for target in get_tree().get_nodes_in_group(target_def.group_name):
			if target == _craft:
				continue
			seen[target] = true
			_update_blip(target, _color_for(target_def, target), target_def, origin, facing, effective_range)

	for tracked in _blips.keys():
		if not seen.has(tracked):
			_blips[tracked].queue_free()
			_blips.erase(tracked)


# Recon is the one exception target_defs' use_team_color can't cover - see
# the header comment on RadarTargetDef. Everything else either uses
# use_team_color (crafts, base guns, ...) or the row's static color as-is.
func _color_for(target_def: RadarTargetDef, target: Node) -> Color:
	if target_def.group_name == "Recon":
		return ReconStation.render_color_for_station(target.captured_color)
	if target_def.use_team_color:
		var team := _team_of(target)
		return ReconStation.render_color_for_team(team) if team != "" else target_def.color
	return target_def.color


# Team lives directly on some nodes (base_gun.gd's own "team") and on a
# child for others (craft's "weapon_node.team") - duck-typed so target_defs
# rows don't need to know or care which shape a given group's nodes are.
func _team_of(target: Node) -> String:
	var direct = target.get("team")
	if typeof(direct) == TYPE_STRING and direct != "":
		return direct
	var weapon_node = target.get_node_or_null("weapon_node")
	return weapon_node.team if weapon_node else ""


func _update_blip(target: Node3D, color: Color, target_def: RadarTargetDef, origin: Vector3, facing: Basis, effective_range: float) -> void:
	var local_pos: Vector3 = facing.inverse() * (target.global_position - origin)
	var flat := Vector2(local_pos.x, local_pos.z)

	if flat.length() > effective_range:
		if _blips.has(target):
			_blips[target].queue_free()
			_blips.erase(target)
		return

	if not _blips.has(target):
		var blip: Control = RadarDotScript.new() if target_def.shape == RadarTargetDef.Shape.DOT else ColorRect.new()
		blip.mouse_filter = MOUSE_FILTER_IGNORE
		add_child(blip)
		_blips[target] = blip

	var blip: Control = _blips[target]
	if target_def.shape == RadarTargetDef.Shape.DOT:
		blip.dot_color = color
	else:
		blip.color = color
	blip.size = target_def.size
	blip.position = flat * (size / (2.0 * effective_range)) + size / 2.0 - target_def.size / 2.0

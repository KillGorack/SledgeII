extends Node3D
class_name ReconStation

enum StationColor { NONE, RED, GREEN, BLUE, GRAY }

const _FIXED_COLOR_GROUPS := {
	"recon_red": StationColor.RED,
	"recon_green": StationColor.GREEN,
	"recon_blue": StationColor.BLUE,
	"recon_gray": StationColor.GRAY,
}

const _RENDER_COLORS := {
	StationColor.RED: Color(0.9, 0.15, 0.15),
	StationColor.GREEN: Color(0.2, 0.85, 0.25),
	StationColor.BLUE: Color(0.2, 0.55, 1.0),
	StationColor.GRAY: Color(0.6, 0.6, 0.6),
}


static func color_for_team(team: String) -> StationColor:
	match team:
		"team_red": return StationColor.RED
		"team_green": return StationColor.GREEN
		"team_blue": return StationColor.BLUE
		"team_gray": return StationColor.GRAY
		_: return StationColor.NONE


static func team_for_color(color: StationColor) -> String:
	match color:
		StationColor.RED: return "team_red"
		StationColor.GREEN: return "team_green"
		StationColor.BLUE: return "team_blue"
		StationColor.GRAY: return "team_gray"
		_: return ""


static func render_color_for_team(team: String) -> Color:
	return _RENDER_COLORS.get(color_for_team(team), Color.WHITE)


static func render_color_for_station(color: StationColor) -> Color:
	return _RENDER_COLORS.get(color, Color(0.0, 0.0, 0.0))


var changeable: bool = true
var captured_color: StationColor = StationColor.NONE
@export var resupply_sound: AudioStream
@onready var _energy_mesh: MeshInstance3D = $MeshInstance3D/Energy


var _overlapping_bodies: Array = []

func _ready() -> void:
	$Area3D.body_entered.connect(_on_body_entered)
	$Area3D.body_exited.connect(_on_body_exited)
	_apply_fixed_color_from_marker()


func _apply_fixed_color_from_marker() -> void:
	var marker := get_parent()
	if marker == null:
		return
	for group_name in _FIXED_COLOR_GROUPS:
		if marker.is_in_group(group_name):
			changeable = false
			captured_color = _FIXED_COLOR_GROUPS[group_name]
			set_pad_color(_RENDER_COLORS[captured_color])
			return



func _on_body_entered(body: Node3D) -> void:
	_overlapping_bodies.append(body)
	if not multiplayer.is_server():
		return
	var weapon_node = body.get_node_or_null("weapon_node")
	if weapon_node and weapon_node.has_method("refill_ammo") and weapon_node.refill_ammo(captured_color):
		_play_resupply_sound.rpc()


func _on_body_exited(body: Node3D) -> void:
	_overlapping_bodies.erase(body)



# Cosmetic - unreliable, own channel (see weapon_node.gd::_play_launch_sound).
@rpc("any_peer", "call_local", "unreliable", 1)
func _play_resupply_sound() -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	if resupply_sound:
		Utilities.play_sound(resupply_sound, global_position)


func is_body_inside(body: Node3D) -> bool:
	return body in _overlapping_bodies


func set_pad_color(color: Color) -> void:
	var mat := _energy_mesh.material_override
	if not (mat is ShaderMaterial):
		return
	mat = mat.duplicate()
	mat.set_shader_parameter("pad_color", color)
	_energy_mesh.material_override = mat



func capture(team: String) -> void:
	if not changeable:
		return
	captured_color = color_for_team(team)
	set_pad_color(_RENDER_COLORS.get(captured_color, Color.WHITE))

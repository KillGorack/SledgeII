extends Node3D
class_name ReconStation

enum StationColor { NONE, RED, GREEN, BLUE, GRAY }

# Map-side authoring hook: a station's Marker3D (see match.gd - this scene is
# always instanced as a direct child of one) can be tagged in the editor's
# built-in Groups tab with one of these names, no script or custom class
# needed in whatever separate project builds the map .pck. Untagged = neutral
# and freely capturable later; tagged = fixed for the whole match, never
# changes hands regardless of whatever capture mechanic gets built on top of
# this later.
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

# A craft's real team identity is the string movement_node/weapon_node.team
# holds ("team_red" etc - see Utilities.GROUP_LAYER_SCOPE), not this enum -
# this is just the translation between the two, for power_node.gd (and
# whatever capture mechanic comes next) to compare a craft's team against a
# station's captured_color without either side needing to know the other's
# vocabulary.
static func color_for_team(team: String) -> StationColor:
	match team:
		"team_red": return StationColor.RED
		"team_green": return StationColor.GREEN
		"team_blue": return StationColor.BLUE
		"team_gray": return StationColor.GRAY
		_: return StationColor.NONE

# Public wrapper around color_for_team + _RENDER_COLORS for anything outside
# this script that just wants "what color paint goes on this team's stuff"
# (base_gun.gd's team tint, say) without needing its own copy of the
# team<->color table or reaching into the underscore-prefixed const directly.
static func render_color_for_team(team: String) -> Color:
	return _RENDER_COLORS.get(color_for_team(team), Color.WHITE)

# Once false, captured_color is permanent - set only from a map-authored
# fixed-color marker (see _apply_fixed_color_from_marker), never by whatever
# capture mechanic reads/writes this later. That mechanic should check this
# first and simply refuse to touch a non-changeable station.
var changeable: bool = true
var captured_color: StationColor = StationColor.NONE

@onready var _energy_mesh: MeshInstance3D = $MeshInstance3D/Energy


# Who's currently standing in the pad, for the capture mechanic (see
# is_body_inside/match.gd) - a plain overlap list rather than querying
# Area3D.get_overlapping_bodies() on demand, since that returns physics-frame
# stale results if called outside a physics callback (input handling isn't
# one), where this is just always current.
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


# Overlap tracking (is_body_inside, just below) has to happen on every peer,
# not just the server - the capture input (match.gd) is read locally, off
# whichever craft belongs to the peer pressing the button, so each peer needs
# its own accurate answer to "am I standing in this pad right now". The ammo
# refill below it stays server-only, same reasoning as everywhere else
# ammo/power gets mutated: every peer has its own copy of this map and this
# Area3D, so body_entered fires identically everywhere, but only the server's
# copy is allowed to actually change craft state.
func _on_body_entered(body: Node3D) -> void:
	_overlapping_bodies.append(body)
	if not multiplayer.is_server():
		return
	var weapon_node = body.get_node_or_null("weapon_node")
	if weapon_node and weapon_node.has_method("refill_ammo"):
		weapon_node.refill_ammo()


func _on_body_exited(body: Node3D) -> void:
	_overlapping_bodies.erase(body)


func is_body_inside(body: Node3D) -> bool:
	return body in _overlapping_bodies


# Tints the pad's energy overlay - e.g. to a team's color once a capture
# mechanic decides to call this. _energy_mesh.material_override is the one
# ShaderMaterial sub_resource embedded in recon_station.tscn and shared by
# every station instance on the map (not resource_local_to_scene) -
# duplicating once, on first tint, keeps each station's color its own instead
# of recoloring every station on the map at once. Same reasoning as
# colorable_mesh.gd::apply_projectile_color.
func set_pad_color(color: Color) -> void:
	var mat := _energy_mesh.material_override
	if not (mat is ShaderMaterial):
		return
	mat = mat.duplicate()
	mat.set_shader_parameter("pad_color", color)
	_energy_mesh.material_override = mat


# The actual capture mechanic (see match.gd's base_gun flight sequence) calls
# this once a gun's hold-and-effect phase completes - runs identically on
# every peer (triggered by the same broadcast RPC that started the flight),
# so captured_color ends up the same everywhere without needing its own
# separate sync. changeable is checked here too, not just by the caller, so
# this stays safe to call even if that check is ever skipped upstream.
func capture(team: String) -> void:
	if not changeable:
		return
	captured_color = color_for_team(team)
	set_pad_color(_RENDER_COLORS.get(captured_color, Color.WHITE))

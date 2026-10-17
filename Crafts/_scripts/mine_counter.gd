extends Control

# Hud_InGame/MineCounter - a team-colored mine icon and "left / max", like the
# weapon readout beside it. The icon is a drawn placeholder hexagon (matching
# the mine model's shape); swap _draw for a TextureRect/texture when there is
# real HUD art. Hidden when the host turned mines off.
const ICON_RADIUS := 11.0
const ICON_CENTER := Vector2(16, 16)

@onready var _weapon_node: Node = get_node("../../weapon_node")
@onready var _match_node: Node = get_tree().get_first_node_in_group("match")

var _label: Label
var _last_text: String = ""
var _color: Color = Color.WHITE


func _ready() -> void:
	# Same "is this my craft" test as hud_controller.gd.
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return
	_label = Label.new()
	_label.position = Vector2(36, 4)
	add_child(_label)


func _process(_delta: float) -> void:
	var manager: MineManager = _match_node.mines if _match_node else null
	visible = NetworkManager.mines_enabled and manager != null
	if not visible:
		return
	var color := ReconStation.render_color_for_team(_weapon_node.team)
	if color != _color:
		_color = color
		queue_redraw()
	var text := "%d / %d" % [manager.mines_left(multiplayer.get_unique_id()), MineManager.MAX_MINES_PER_PLAYER]
	if text != _last_text:
		_last_text = text
		_label.text = text


func _draw() -> void:
	var points := PackedVector2Array()
	for i in 6:
		points.append(ICON_CENTER + Vector2.from_angle(deg_to_rad(60.0 * i)) * ICON_RADIUS)
	draw_colored_polygon(points, _color)
	draw_polyline(points + PackedVector2Array([points[0]]), _color.darkened(0.5), 2.0)
	draw_circle(ICON_CENTER, 3.0, _color.darkened(0.5))

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
var _last_mine_index: int = -1
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
	visible = NetworkManager.mines_enabled and manager != null and NetworkManager.is_online()
	if not visible:
		return
	var color := ReconStation.render_color_for_team(_weapon_node.team)
	if color != _color or _weapon_node.current_mine_index != _last_mine_index:
		_color = color
		_last_mine_index = _weapon_node.current_mine_index
		queue_redraw()
	var settings: MineSettings = _weapon_node.current_mine()
	if settings == null:
		visible = false
		return
	var text := "%s  %d / %d" % [settings.mine_name, manager.mines_left(multiplayer.get_unique_id(), settings.max_count), settings.max_count]
	if text != _last_text:
		_last_text = text
		_label.text = text


func _draw() -> void:
	var points := PackedVector2Array()
	for i in 6:
		points.append(ICON_CENTER + Vector2.from_angle(deg_to_rad(60.0 * i)) * ICON_RADIUS)
	var settings: MineSettings = _weapon_node.current_mine() if _weapon_node else null
	if settings and settings.mine_icon:
		draw_texture_rect(settings.mine_icon, Rect2(ICON_CENTER - Vector2.ONE * ICON_RADIUS, Vector2.ONE * ICON_RADIUS * 2.0), false, _color)
		return
	draw_colored_polygon(points, _color)
	draw_polyline(points + PackedVector2Array([points[0]]), _color.darkened(0.5), 2.0)
	draw_circle(ICON_CENTER, 3.0, _color.darkened(0.5))

extends Control
class_name TargetSelector

# Visual-only target marking, for finding whoever just shot you. cycle_teamies / cycle_enemies step through the
# crafts the radar currently shows (so a target that drifts out of radar range simply gets dropped), nearest first.
# The selection gets corner brackets on screen (an edge arrow when it is off-screen or behind you), an info tile in
# the bottom-right corner (target_tile.gd: name, rings, craft icon, bounty), and a highlight on its radar blip (radar_controller.gd reads `selected`). Nothing here is networked or affects play.
# Added to your own Hud_InGame by hud_controller.gd.

const TARGET_TILE := preload("res://Crafts/_scripts/target_tile.gd")
const MIN_HALF := 16.0
const MAX_HALF := 90.0
const BRACKET_LEN_RATIO := 0.4
const LINE_WIDTH := 2.0
const EDGE_MARGIN := 50.0
const ARROW_SIZE := 14.0
# World-space radius used to scale the brackets with distance.
@export var target_radius: float = 2.0

var selected: Node3D = null

var _craft: Node3D
var _radar: Control
var _chat: Control
var _tile: Control


func _init() -> void:
	name = &"TargetSelector"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The HUD's authority, not this node's own: this node is made in code (hud_controller.gd) and a node added later
	# does NOT inherit its parent's authority - it stays with the host, so on a client this check always failed and the
	# whole selector switched itself off. (The HUD only builds it for the owning peer anyway.)
	if not get_parent().is_multiplayer_authority():
		visible = false
		set_process(false)
		return
	var hud := get_parent()
	_craft = hud.get_parent()
	_radar = hud.get_node_or_null("Radar_Bezel/Radar")
	_chat = hud.get_node_or_null("Chat")
	_tile = TARGET_TILE.new()
	add_child(_tile)


func _process(_delta: float) -> void:
	# Brackets/bar keys are live characters while typing a chat message, same guard as the radar zoom key.
	var typing: bool = _chat != null and _chat.is_open
	if not typing:
		if Input.is_action_just_pressed("cycle_teamies"):
			_cycle(true)
		elif Input.is_action_just_pressed("cycle_enemies"):
			_cycle(false)
	if selected != null and not _still_valid(selected):
		selected = null
	if selected != null:
		_tile.show_target(selected, _name_of(selected), _color_of(selected), _craft.global_position.distance_to(selected.global_position))
	else:
		_tile.clear()
	queue_redraw()


# A selection is kept only while it is alive, in the tree, and still shown on the radar (in range at the current zoom).
func _still_valid(target: Node3D) -> bool:
	if not is_instance_valid(target) or not target.is_inside_tree():
		return false
	var health = target.get_node_or_null("health_node")
	if health != null and health.get("_is_destroyed"):
		return false
	if _radar == null:
		return false
	return _radar.crafts_in_range(true).has(target) or _radar.crafts_in_range(false).has(target)


func _cycle(teammates: bool) -> void:
	if _radar == null:
		return
	var candidates: Array = _radar.crafts_in_range(teammates)
	var origin := _craft.global_position
	candidates.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin))
	if candidates.is_empty():
		selected = null
		return
	var at := candidates.find(selected)
	selected = candidates[(at + 1) % candidates.size()]


func _draw() -> void:
	if selected == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var color := _color_of(selected)
	var world := selected.global_position
	var behind := cam.is_position_behind(world)
	var screen := cam.unproject_position(world)
	var margin := Vector2(EDGE_MARGIN, EDGE_MARGIN)
	var on_screen := not behind and Rect2(margin, size - margin * 2.0).has_point(screen)
	if on_screen:
		var half := clampf((cam.unproject_position(world + cam.global_basis.y * target_radius) - screen).length(), MIN_HALF, MAX_HALF)
		_draw_brackets(screen, half, color)
	else:
		# Off-screen or behind: the same brackets pinned to the screen edge, with an arrow pointing the way to turn.
		var dir := screen - size / 2.0
		if behind:
			dir = -dir
		if dir.length() < 1.0:
			dir = Vector2.DOWN
		dir = dir.normalized()
		var edge := _edge_point(dir, margin)
		_draw_brackets(edge, MIN_HALF, color)
		_draw_arrow(edge + dir * (MIN_HALF + 4.0 + ARROW_SIZE), dir, color)


func _draw_brackets(center: Vector2, half: float, color: Color) -> void:
	var arm := half * BRACKET_LEN_RATIO
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := center + Vector2(sx * half, sy * half)
			# Dark underlay so the brackets read on any background.
			draw_line(corner, corner - Vector2(sx * arm, 0.0), Color(0, 0, 0, 0.6), LINE_WIDTH + 2.0)
			draw_line(corner, corner - Vector2(0.0, sy * arm), Color(0, 0, 0, 0.6), LINE_WIDTH + 2.0)
			draw_line(corner, corner - Vector2(sx * arm, 0.0), color, LINE_WIDTH)
			draw_line(corner, corner - Vector2(0.0, sy * arm), color, LINE_WIDTH)


func _draw_arrow(tip: Vector2, dir: Vector2, color: Color) -> void:
	var side := dir.orthogonal()
	var base := tip - dir * ARROW_SIZE
	var points := PackedVector2Array([tip, base + side * ARROW_SIZE * 0.6, base - side * ARROW_SIZE * 0.6])
	draw_colored_polygon(points, color)
	draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[0]]), Color(0, 0, 0, 0.6), 1.0)


# Where a ray from the screen center along `dir` leaves the screen rect (inset by margin).
func _edge_point(dir: Vector2, margin: Vector2) -> Vector2:
	var half := size / 2.0 - margin
	var scale_x := half.x / absf(dir.x) if absf(dir.x) > 0.0001 else INF
	var scale_y := half.y / absf(dir.y) if absf(dir.y) > 0.0001 else INF
	return size / 2.0 + dir * minf(scale_x, scale_y)


func _color_of(target: Node) -> Color:
	var weapon_node = target.get_node_or_null("weapon_node")
	return ReconStation.render_color_for_team(weapon_node.team) if weapon_node else Color.WHITE


# Player name from the server's roster; bots (and anyone not in it) get a generic label.
func _name_of(target: Node) -> String:
	var id := Utilities.craft_owner_id(target)
	var roster_name: String = NetworkManager.peer_names.get(id, "")
	if roster_name != "":
		return roster_name
	return "Bot" if NetworkManager.is_bot_id(id) else "Player %d" % id

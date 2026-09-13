class_name Trail3D extends MeshInstance3D

var _points = []
var _widths = []
var _lifePoints = []
var _oldPos: Vector3

@export_range(0.5, 1.5) var _scaleAcceleration: float = 1.0
@export var _motionDelta: float = 0.01
@export var _lifeSpan: float = 1.0
@export var _startColor: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var _endColor: Color = Color(1.0, 1.0, 1.0, 0.0)
@export var _trailEnabled: bool = true
@export var _fromWidth: float = 0.05
@export var _toWidth: float = 0.0


# Paired with colorable_light.gd/colorable_mesh.gd - see
# collision_handler.gd::_apply_projectile_color for how these all get called.
# _endColor keeps its existing alpha (0.0, fading to transparent) - only the
# hue changes, so the fade-out behavior is untouched.
func apply_projectile_color(color: Color) -> void:
	_startColor = color
	_endColor = Color(color.r, color.g, color.b, _endColor.a)


func _ready():
	_oldPos = get_global_transform().origin
	mesh = ImmediateMesh.new()
	layers = 4
	
	
	
	
	
func _process(delta):
	if (_oldPos - get_global_transform().origin).length() > _motionDelta and _trailEnabled:
		AppendPoint()
		_oldPos = get_global_transform().origin
	var p = 0
	var max_points = _points.size()
	while p < max_points:
		_lifePoints[p] += delta
		if _lifePoints[p] > _lifeSpan:
			RemovePoint(p)
			p -= 1
			if(p < 0): p = 0
		max_points = _points.size()
		p += 1
	mesh.clear_surfaces()
	if _points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in range(_points.size()):
		var t = float (i) / (_points.size() - 1.0)
		var currColor = _startColor.lerp(_endColor, 1 - t)
		mesh.surface_set_color(currColor)
		var currWidth = _widths[i][0] - pow(1 - t, _scaleAcceleration) * _widths[i][1]
		var t0 = float(i) / float(_points.size())
		var t1 = t
		mesh.surface_set_uv(Vector2(t0, 0))
		mesh.surface_add_vertex(to_local(_points[i] + currWidth))
		mesh.surface_set_uv(Vector2(t1, 1))
		mesh.surface_add_vertex(to_local(_points[i] - currWidth))
	mesh.surface_end()
	
	



func AppendPoint():
	_points.append(get_global_transform().origin)	
	_widths.append([
		get_global_transform().basis.x * _fromWidth,
		get_global_transform().basis.x * _fromWidth - get_global_transform().basis.x * _toWidth])
	_lifePoints.append(0.0)
	
	
	
	
	
# Wipes the whole point history rather than removing it one at a time - for
# an abrupt redirect (a ricochet reorienting the projectile in a single
# frame), the trail otherwise has to connect the last pre-bounce point
# straight to the first post-bounce one, a visible whip across the turn.
# Clearing means nothing draws until it has regrown at least 2 fresh points
# (see _process()'s _points.size() < 2 check), which happens within a couple
# of frames, so the trail just picks back up cleanly from the new direction.
func clear_trail() -> void:
	_points.clear()
	_widths.clear()
	_lifePoints.clear()


func RemovePoint(i):
	_points.remove_at(i)
	_widths.remove_at(i)
	_lifePoints.remove_at(i)

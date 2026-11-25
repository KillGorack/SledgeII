extends Node
class_name ShieldShell

# The visible shield on a craft: a copy of each of its meshes (hull, turret, barrel) pushed slightly out and drawn
# mostly see-through by shield_shell.gdshader, so the tank shows through and the shield reads as a skin around
# it. Shown while shields > 0 and fades with them; a small brightening when the shield takes a hit.
#
# Purely local, nothing is networked: every peer builds it from the craft (CraftBuilder.build, which runs
# identically everywhere) and drives it from `shields`, which already reaches every peer through the synchronizer.
# Your own craft's copy is hidden from your camera along with the rest of your body (movement.gd::_hide_own_body
# moves every mesh under it onto the self-render layer), and dies with the body when the craft is destroyed.
#
# The look is Materials/Shaders/shield_shell.tres - edit that in the Inspector. The constants below are the
# behavior.

const SHELL_MATERIAL := preload("res://Materials/Shaders/shield_shell.tres")
const GROUP := &"shield_shell"
# Which meshes get a shell (paths under the craft).
const MESH_PATHS := ["Hull", "Turret", "Turret/Barrel"]
# How fast the shown amount follows the real one (1/s): the shield fades in/out and eases instead of snapping.
const FOLLOW_RATE := 4.0
# Intensity at the lowest non-empty shield, rising to 1 at full.
const MIN_INTENSITY := 0.4
# Below this fraction the shield flickers slightly, so a failing shield is readable.
const FLICKER_BELOW := 0.2
const FLICKER_AMOUNT := 0.15
# A hit brightens the shell by this much (0 = no pulse), decaying at PULSE_DECAY per second.
const PULSE_STRENGTH := 0.5
const PULSE_DECAY := 6.0

# Mesh -> its smoothed copy, shared by every craft of the same model.
static var _smooth_cache: Dictionary = {}

var _health: Node
var _material: ShaderMaterial
var _shells: Array[MeshInstance3D] = []
var _shown := 0.0
var _pulse := 0.0
var _last_shields := -1.0
var _visible := false


# Called at the end of CraftBuilder.build, once the craft's meshes are assigned.
static func attach(craft: Node3D) -> void:
	var node := ShieldShell.new()
	node.name = "ShieldShell"
	craft.add_child(node)
	node._setup(craft)


func _setup(craft: Node3D) -> void:
	_health = craft.get_node_or_null("health_node")
	_material = SHELL_MATERIAL.duplicate() as ShaderMaterial
	for path in MESH_PATHS:
		var mesh_node := craft.get_node_or_null(path) as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null:
			continue
		var shell := MeshInstance3D.new()
		shell.name = "ShieldShell"
		shell.mesh = _smoothed(mesh_node.mesh)
		shell.material_override = _material
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		shell.visible = false
		shell.add_to_group(GROUP)
		mesh_node.add_child(shell)
		_shells.append(shell)
	set_process(_health != null and not _shells.is_empty())


func _process(delta: float) -> void:
	var shields: float = _health.shields
	var shields_max: float = _health._shields_max
	var target := clampf(shields / shields_max, 0.0, 1.0) if shields_max > 0.0 and shields > 0.0 else 0.0
	# A hit that leaves some shield: a quick brightening. (Hits at 0 do nothing, and a refill is not a hit.)
	if _last_shields >= 0.0 and shields < _last_shields - 0.01 and shields > 0.0:
		_pulse = 1.0
	_last_shields = shields
	_pulse = move_toward(_pulse, 0.0, PULSE_DECAY * delta)
	_shown = move_toward(_shown, target, FOLLOW_RATE * delta)

	var show_now := _shown > 0.002
	if show_now != _visible:
		_visible = show_now
		for shell in _shells:
			shell.visible = show_now
	if not show_now:
		return
	# Fade out over the last stretch so it dissolves instead of popping off at zero.
	var fade := clampf(_shown * 4.0, 0.0, 1.0)
	var level := fade * lerpf(MIN_INTENSITY, 1.0, _shown)
	if _shown < FLICKER_BELOW:
		level *= 1.0 - FLICKER_AMOUNT * (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.03))
	_material.set_shader_parameter("intensity", level)
	_material.set_shader_parameter("pulse", _pulse * PULSE_STRENGTH)


# A copy of `src` made to be pushed outward by the shader without tearing. The shader pushes every vertex out along its
# normal, so vertices that sit at the same spot must share ONE normal, or they move apart and open a crack:
#  - a hard-edged mesh has several normals at one corner (one per face), and
#  - a mesh with several surfaces (one per material, like the tank hull) has a separate copy of every vertex on the
#    border between two surfaces.
# So the normals are averaged over every vertex at the same position across ALL surfaces. Only the shell uses this
# copy; the tank's own mesh is untouched.
static func _smoothed(src: Mesh) -> Mesh:
	if _smooth_cache.has(src):
		return _smooth_cache[src]
	var sums: Dictionary = {} # quantized position -> summed (area-weighted) face normal, over every surface
	var surfaces: Array = [] # the arrays of each triangle surface, kept for the second pass
	for s in src.get_surface_count():
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var tri_count := indices.size() / 3 if indices.size() > 0 else verts.size() / 3
		for t in tri_count:
			var ia := indices[t * 3] if indices.size() > 0 else t * 3
			var ib := indices[t * 3 + 1] if indices.size() > 0 else t * 3 + 1
			var ic := indices[t * 3 + 2] if indices.size() > 0 else t * 3 + 2
			# Godot's winding: this is the outward face normal, with the triangle's area as its length.
			var face := (verts[ia] - verts[ic]).cross(verts[ia] - verts[ib])
			for i in [ia, ib, ic]:
				var key := _key(verts[i])
				sums[key] = sums.get(key, Vector3.ZERO) + face
		surfaces.append(arrays)
	var out := ArrayMesh.new()
	for arrays in surfaces:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals := PackedVector3Array()
		normals.resize(verts.size())
		for i in verts.size():
			var n: Vector3 = sums.get(_key(verts[i]), Vector3.ZERO)
			normals[i] = n.normalized() if n.length_squared() > 0.0 else Vector3.UP
		arrays[Mesh.ARRAY_NORMAL] = normals
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_smooth_cache[src] = out
	return out


static func _key(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0))

extends MeshInstance3D

# One number, right here, controls both the ring's grow/fade speed and how
# long the whole effect lives - this script frees its own parent once the
# animation finishes instead of relying on _gc.gd's separate timer on the
# Shockwave root to happen to match.
#
# Earlier version instead tried to SYNC this field FROM _gc.gd's own duration
# in _ready(), meant to avoid keeping two numbers in sync by hand - but that
# meant editing THIS field directly (the one actually visible next to the
# material) did nothing, it got silently overwritten every time before the
# first frame even rendered. _gc.gd is still on the parent and will still
# fire its own queue_free() eventually, but by then this will have already
# freed it - calling queue_free() twice is harmless, so nothing needs to be
# removed there.
@export var duration: float = 0.75
# Maps progress (0-1) to alpha - the ring's fade-out shape, tunable here
# instead of fixed as 1.0 - progress in the shader. X axis is progress,
# Y axis is alpha; default curve (set in the .tscn) reproduces the old
# linear falloff so existing instances look unchanged until edited.
@export var fade_curve: Curve
# _play_hit_effect() (collision_handler.gd) spawns the whole explosion at the
# PROJECTILE's own transform, which is right for its particles/sound but not
# for this ring: a shell's contact point can sit a little above the actual
# ground mesh (its collision shape's radius, or a shallow embed on impact),
# so the ring would render floating. A short downward raycast from spawn
# finds the real surface and drops the ring onto it; if nothing is hit
# (e.g. an airburst with no ground nearby) it stays where it spawned.
@export var ground_snap_distance: float = 10.0
@export_flags_3d_physics var ground_snap_mask: int = 0xFFFFFFFF

var _elapsed: float = 0.0
var _material: ShaderMaterial
var _flattened: bool = false
var _flat_basis: Basis


func _ready() -> void:
	# Captured here, APPLIED on the first _process() tick instead - see the
	# comment down there for why it can't safely happen right here.
	_flat_basis = basis
	_material = get_active_material(0) as ShaderMaterial
	set_process(_material != null and duration > 0.0)


func _process(delta: float) -> void:
	if not _flattened:
		# _play_hit_effect() (collision_handler.gd) calls add_child() and
		# THEN sets .transform on this same node, both synchronously, before
		# _ready() ever runs - reading/writing global_transform (or
		# global_basis) that early, on a node just added and reparented in
		# the same frame, is a known Godot timing gotcha: the engine hasn't
		# necessarily finished resolving the parent chain's transform yet, so
		# doing this fix in _ready() itself was unreliable. By the first
		# _process() tick a full frame has settled, so it's safe here.
		_snap_to_nearest_surface()
		#
		# This mesh's own LOCAL rotation (baked in the .tscn / tuned in the
		# editor) already lies flat under an identity parent - reapplying the
		# captured value as GLOBAL locks the ring flat on the ground (Y-up)
		# regardless of what angle the shell hit at, without hardcoding the
		# actual angle, so retuning it in the editor still works as before.
		global_basis = _flat_basis
		_flattened = true
	_elapsed += delta
	var progress = clamp(_elapsed / duration, 0.0, 1.0)
	_material.set_shader_parameter("progress", progress)
	var fade_alpha = fade_curve.sample(progress) if fade_curve else 1.0 - progress
	_material.set_shader_parameter("fade_alpha", fade_alpha)
	if progress >= 1.0:
		set_process(false)
		var parent = get_parent()
		if parent:
			parent.queue_free()


func _snap_to_nearest_surface() -> void:
	var space_state = get_world_3d().direct_space_state
	var origin = global_position
	var query = PhysicsRayQueryParameters3D.create(
		origin + Vector3.UP * 0.5,
		origin + Vector3.DOWN * ground_snap_distance
	)
	query.collision_mask = ground_snap_mask
	var result = space_state.intersect_ray(query)
	if result:
		# Tiny offset along the surface normal, same trick create_bullet_hole()
		# uses, so the ring doesn't z-fight with the surface it's flush against.
		global_position = result.position + result.normal * 0.01

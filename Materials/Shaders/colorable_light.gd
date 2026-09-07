extends OmniLight3D

# Paired with colorable_mesh.gd and Trail3D.gd::apply_projectile_color - see
# collision_handler.gd::_apply_projectile_color for how these all get called.
func apply_projectile_color(color: Color) -> void:
	light_color = color

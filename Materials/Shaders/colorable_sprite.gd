extends Sprite3D

# Paired with colorable_mesh.gd and colorable_light.gd - see
# collision_handler.gd::_apply_projectile_color for how these all get called.
# Sprite3D tints via modulate natively, so unlike colorable_mesh.gd there's
# no shared material_override to duplicate before recoloring.
func apply_projectile_color(color: Color) -> void:
	modulate = color

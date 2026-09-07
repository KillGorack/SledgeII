extends MeshInstance3D

# material_override on the scene is an ExtResource - every instance of this
# projectile shares that one Material resource object until something
# duplicates it. Setting albedo_color directly on it would repaint every
# other in-flight projectile using the same base material (e.g. every rocket
# on screen, regardless of which weapon or team fired it), not just this one.
# Duplicating once, on the first tint, keeps each instance's color its own.
func apply_projectile_color(color: Color) -> void:
	var mat := material_override
	if not (mat is StandardMaterial3D):
		return
	mat = mat.duplicate()
	mat.albedo_color = color
	material_override = mat

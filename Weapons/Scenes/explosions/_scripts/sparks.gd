extends Node3D

@onready var _clash: GPUParticles3D = $Clash
@onready var _spark: GPUParticles3D = $Spark

func _ready() -> void:
	_clash.restart()
	_spark.restart()
	_spark.finished.connect(queue_free)


# Answers the same duck-typed apply_projectile_color() call collision_handler.gd
# already sends to the projectile itself (see colorable_mesh.gd/colorable_light.gd/
# Trail3D.gd) - _play_hit_effect() walks the whole explosion instance looking
# for anything that knows how to color itself, so this is the only wiring this
# scene needs to pick up weapon_settings.projectile_color.
func apply_projectile_color(color: Color) -> void:
	_tint(_clash, color)
	_tint(_spark, color)


func _tint(particles: GPUParticles3D, color: Color) -> void:
	var mat := particles.material_override
	if not (mat is StandardMaterial3D):
		return
	mat = mat.duplicate()
	mat.albedo_color = color
	particles.material_override = mat

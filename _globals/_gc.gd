extends Node3D

# Frees itself after `duration`. For an effect scene's root it can also fire
# the effect's one-off parts, so the scene needs no other code:
#  - sound: played through Utilities.play_sound (the pooled 3D players), NOT a
#    child AudioStreamPlayer - the sound then lives and finishes on its own and
#    never depends on how long this node does, so `duration` only has to cover
#    the visuals. sound_volume is play_sound's scale (5.0 = full volume).
#  - one_shot_particles: every GPUParticles3D below is made one-shot and
#    restarted, so the effect plays exactly once however long it stays around.
@export var duration: float = 0.25
@export var sound: AudioStream
@export var sound_volume: float = 5.0
@export var one_shot_particles: bool = false


func _ready() -> void:
	Utilities.GarbageCollection(self, duration)
	if one_shot_particles:
		for particles in find_children("*", "GPUParticles3D", true, false):
			particles.one_shot = true
			particles.restart()
	if sound:
		# Deferred: whoever spawned this sets its transform right after
		# add_child, so the position is only right once they have finished.
		_play_sound.call_deferred()


func _play_sound() -> void:
	if is_inside_tree():
		Utilities.play_sound(sound, global_position, sound_volume)

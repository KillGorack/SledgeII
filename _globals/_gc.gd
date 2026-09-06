extends Node3D

@export var duration: float = 0.25

func _ready() -> void:
	Utilities.GarbageCollection(self, duration)

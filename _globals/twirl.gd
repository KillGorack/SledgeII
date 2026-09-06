extends Node3D

@export var spin_speed: float = 1.0
@export var enable_x: bool = true
@export var enable_y: bool = true
@export var enable_z: bool = true

var spin_axis: String
var spin_direction: float

func _ready() -> void:
		
	var axes = []
	if enable_x: axes.append("x")
	if enable_y: axes.append("y")
	if enable_z: axes.append("z")

	if axes.is_empty():
		print("No axis enabled! Defaulting to 'y'.")
		axes.append("y")  # Avoid errors

	spin_axis = axes[randi() % axes.size()]  # Randomly pick an enabled axis
	spin_direction = [-1.0, 1.0][randi() % 2]  # Randomly pick +1 or -1

func _physics_process(delta: float) -> void:
	match spin_axis:
		"x":
			rotate_x(spin_speed * spin_direction * delta)
		"y":
			rotate_y(spin_speed * spin_direction * delta)
		"z":
			rotate_z(spin_speed * spin_direction * delta)

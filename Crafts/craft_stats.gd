extends Resource
class_name CraftStats

@export var target_audio_pitch: float = 2.0
@export var look_sensitivity: float = 1.0
@export var fine_aim_multiplier: float = 0.35
@export var recenter_speed: float = 16.0

@export var turn_speed: float = 1.5
@export var turn_acceleration: float = 3.0
@export var turn_deceleration: float = 3.0
@export var acceleration: float = 40.0
@export var deceleration: float = 4.0
@export var max_speed: float = 12.0

@export var thruster_force: float = 60.0
@export var rotation_speed: float = 3.0
@export var right_side_up_threshold: float = 0.3

# Health (per-instance mutable state duplicates these - see health_node.gd)
@export var shields: float = 100.0
@export var armor: float = 100.0
@export var life: float = 100.0
@export var regeneration_delay: float = 5.0
@export var regeneration_rate: float = 10.0

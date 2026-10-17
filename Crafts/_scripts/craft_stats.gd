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
# Armor-then-life heal rate while parked inside a recon station captured by
# this craft's own team (see health_node.gd::_process_station_healing) -
# shields already regen on their own via regeneration_rate above, so this
# never touches shields.
@export var station_heal_rate: float = 10.0
# Fall damage (see movement.gd::_handle_landing and
# health_node.gd::request_fall_damage) - impact speed is the component of
# landing velocity straight into whatever surface you hit (world-space
# ground normal, not the craft's own orientation), so a hard flat slam
# damages a lot more than skimming the same speed along a ramp. Below
# fall_damage_safe_speed nothing happens at all, same as any normal landing;
# above it, damage scales with the SQUARE of the excess speed (kinetic
# energy, not linear) so a landing twice as hard hurts four times as much.
@export var fall_damage_safe_speed: float = 2.5
@export var fall_damage_coefficient: float = 1.5

# Power (per-instance mutable state duplicates this - see power_node.gd)
@export var power_capacity: float = 100.0
@export var power_gain_rate: float = 10.0
@export var max_effect_distance: float = 25.0
# Optional taper for the recon charge rate: x = distance from the station as a
# fraction of max_effect_distance (0 = epicenter, 1 = edge), y = fraction of
# power_gain_rate gained there. Empty = straight line from full at the
# epicenter to nothing at the edge.
@export var power_falloff_curve: Curve
 
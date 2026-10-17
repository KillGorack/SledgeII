extends Resource
class_name MineSettings

# One kind of mine - the mine counterpart of WeaponSettings (ported from the
# original Sledge's MineSettings). Assigned per craft on weapon_node's
# mine_settings. Mines are always area-of-effect: everything inside
# explosive_force_distance of the mine is affected, fading linearly from full
# strength at the mine to nothing at the edge.
#
# Damage and force are independent: hit_points = 0 is a no-damage mine,
# explosive_force = 0 pushes nobody. Use either or both.

@export var mine_name: String = "Mine"
# Seeds the checkbox on the host's Create Game mine list, like
# WeaponSettings.default_available.
@export var default_available: bool = true
@export var mine_icon: Texture
@export_multiline var mine_lore: String = ""

@export_group("Limits")
# Most mines one player can have laid at once (also the HUD counter's max).
@export var max_count: int = 6
# Seconds between laying one mine and the next.
@export var cool_down: float = 1.0
# Seconds after laying before it can go off.
@export var arm_time: float = 1.5
# Seconds until an unexploded mine fizzles out harmlessly. 0 = never.
@export var life_span: float = 900.0

@export_group("Triggering")
# An enemy craft near the mine sets it off.
@export var proximity_trigger: bool = true
@export var activation_range: float = 1.5
# The owner's blow_mines key sets it off.
@export var remote_detonate: bool = true
# The blast also hits the owner's own team (and the owner).
@export var friendly_fire: bool = false

@export_group("Blast")
# Radius of the blast, for damage and force alike.
@export var explosive_force_distance: float = 8.0
# Damage at the epicenter. 0 = no damage.
@export var hit_points: float = 0.0
# Knockback impulse at the epicenter. 0 = no push.
@export var explosive_force: float = 0.0
# Seconds the weapons/movement of everything hit are frozen for. 0 = none.
@export var freeze_timer: float = 0.0

@export_group("Scenes and sounds")
# Root must carry mine.gd (Mine).
@export var mine_prefab: PackedScene
@export var explosion_prefab: PackedScene
@export var explosion_scale: float = 1.5
@export var explosion_sound: AudioStream
@export var lay_sound: AudioStream

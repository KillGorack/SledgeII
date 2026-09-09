extends Resource
class_name WeaponSettings

@export var weapon_name: String = "Default Weapon"
@export var weapon_icon: Texture
# Seeds the checkbox state on the host's Create Game weapon list - read-only
# at runtime (see UI/_scripts/index.gd and Networking/match.gd), never
# written back to, since this Resource is shared/cached across every match.
@export var default_available: bool = true
@export var hit_points: float = 0.0
@export var crit_chance: float = 0.0
@export var crit_multiplier: float = 1.0
@export var cool_down: float = 0.5

@export var projectile_prefab: PackedScene
# Tint for this weapon's projectile - see collision_handler.gd::_apply_projectile_color.
# Projectile scenes (rocket/laser/shell) now carry one shared grayscale-ready
# material/trail/light setup each, instead of a separate color-baked scene per
# weapon; this is what actually paints that shared setup per weapon. No-alpha
# so the picker can't accidentally leave a projectile half-transparent.
@export_color_no_alpha var projectile_color: Color = Color.WHITE
@export var explosion_prefab: PackedScene
@export var bullet_hole_prefab: PackedScene

@export var launch_sound: AudioStream
@export var hit_sound: AudioStream
@export var crit_sound: AudioStream

@export var projectile_count_capacity: int = 0 # 0 is infinite
@export var projectile_count_actual: int = 0

@export var projectile_pierce_count: int = 0
@export var projectile_ricochet_count: int = 0
@export var bounce_count: int = 0
@export var freeze_timer: float = 0.0
@export var unfreeze: bool = false
@export var projectile_force: float = 0.0

@export var explosive_force: float = 0.0
@export var explosive_force_distance: float = 0.0
@export var body_collection_max: int = 0

@export var targeting_system: bool = false
@export var target_rotation_speed: float = 0.0
@export var target_system_scan_radius: float = 40.0

@export var projectile_count: int = 1
@export var projectile_spacing: float = 0.0

@export var projectile_recoil: float = 0.0

@export var projectile_range: float = 100.0
@export var projectile_speed: float = 45.0

@export var launch_offset: float = -0.5
@export var projectile_destruction_delay: float = 0.0
@export var friendly_fire: bool = false
@export var turncoat: String = ""

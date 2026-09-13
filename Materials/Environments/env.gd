extends Node3D

@export var day_length_seconds: float = 600.0
@export_range(0.0, 1.0) var start_time_of_day: float = 0.3
@export var sun_azimuth_dir: Vector2 = Vector2(1, 0)

const SKY_TOP_DAY := Color(0.51319635, 0.55616623, 0.7278104)
const SKY_HORIZON_DAY := Color(0.79732156, 0.606513, 0.50890225)
const GROUND_DAY := Color(0.22134113, 0.16245908, 0.11599592)

const SKY_TOP_SUNSET := Color(0.15, 0.10, 0.35)
const SKY_HORIZON_SUNSET := Color(0.95, 0.45, 0.25)
const GROUND_SUNSET := Color(0.25, 0.12, 0.10)

const floor_dim_min: float = 0.5
const HUE_TRANSITION_WIDTH: float = 0.25
# How often the server re-broadcasts its own time_of_day to every already-
# connected peer (see _process/sync_time_to). Every peer was independently
# integrating delta/day_length_seconds on their own before this - no cross-
# peer correction at all, so any per-frame timing difference (which peer's
# frame landed exactly when, physics catching up after a hitch, etc.)
# compounded for the rest of the match into a visibly different sun position
# on different screens. Clients still integrate locally between syncs too
# (see _process) so the sun keeps moving smoothly rather than visibly
# stepping every SYNC_INTERVAL - this periodic broadcast is just the
# correction that keeps that local guess from ever drifting far.
const SYNC_INTERVAL := 5.0

var time_of_day: float
var _sync_elapsed := 0.0

@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var moon: DirectionalLight3D = $Moon
@onready var sky_material: ShaderMaterial = world_environment.environment.sky.sky_material

var _base_light_energy: float
var _base_moon_energy: float
var _base_star_brightness: float


func _ready() -> void:
	_base_light_energy = sun.light_energy
	_base_moon_energy = moon.light_energy
	_base_star_brightness = sky_material.get_shader_parameter("star_brightness")
	time_of_day = start_time_of_day
	_update_sun()


func _process(delta: float) -> void:
	# When the host disabled the cycle, time_of_day just stays pinned at
	# start_time_of_day forever - _update_sun() still runs every frame so the
	# lighting stays consistent, it just keeps recomputing the same fixed
	# position instead of a moving one. Every peer (server included) keeps
	# integrating this locally, purely so the sun visibly keeps moving
	# smoothly between syncs instead of stepping once every SYNC_INTERVAL -
	# the server's version of this local guess IS the authoritative one, and
	# clients' guesses get corrected back onto it below.
	if NetworkManager.day_night_enabled:
		time_of_day = fmod(time_of_day + delta / day_length_seconds, 1.0)
	_update_sun()
	if multiplayer.is_server():
		_sync_elapsed += delta
		if _sync_elapsed >= SYNC_INTERVAL:
			_sync_elapsed = 0.0
			sync_time_to.rpc(time_of_day)


# Broadcast (server) or targeted at one newly-ready peer (see
# match.gd::_notify_ready) - either way, this is the one thing that actually
# keeps every peer's own independently-integrated time_of_day (see _process)
# from drifting apart over the course of a match: each peer's local guess is
# just smoothing between these authoritative corrections, never the source
# of truth itself.
@rpc("authority", "reliable")
func sync_time_to(server_time_of_day: float) -> void:
	time_of_day = server_time_of_day


func _update_sun() -> void:
	var sun_angle_deg = time_of_day * 360.0
	sky_material.set_shader_parameter("sun_angle", sun_angle_deg)
	sky_material.set_shader_parameter("sun_azimuth_dir", sun_azimuth_dir)
	var az = sun_azimuth_dir.normalized() if sun_azimuth_dir.length() > 0.0001 else Vector2(1, 0)
	var el = deg_to_rad(sun_angle_deg)
	var sun_direction = Vector3(az.x * cos(el), sin(el), az.y * cos(el)).normalized()

	var up = Vector3.UP if abs(sun_direction.y) < 0.99 else Vector3.RIGHT
	sun.global_transform.basis = Basis.looking_at(-sun_direction, up)

	var day_factor = clamp(sun_direction.y / 0.15, 0.0, 1.0)
	sun.light_energy = _base_light_energy * day_factor
	sun.shadow_enabled = day_factor > 0.02
	var night_factor = clamp(-sun_direction.y / 0.15, 0.0, 1.0)
	sky_material.set_shader_parameter("star_brightness", _base_star_brightness * night_factor)

	moon.global_transform.basis = Basis.looking_at(sun_direction, up)
	moon.light_energy = _base_moon_energy * night_factor
	moon.shadow_enabled = night_factor > 0.02

	var twilight_blend = 1.0 - smoothstep(0.0, HUE_TRANSITION_WIDTH, sun_direction.y)
	var top_color = SKY_TOP_DAY.lerp(SKY_TOP_SUNSET, twilight_blend)
	var horizon_color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_SUNSET, twilight_blend)
	var ground_col = GROUND_DAY.lerp(GROUND_SUNSET, twilight_blend)


	var night_dim = 1.0 if sun_direction.y >= 0.0 else lerp(1.0, floor_dim_min, -sun_direction.y)
	sky_material.set_shader_parameter("sky_top_color", top_color * night_dim)
	sky_material.set_shader_parameter("sky_horizon_color", horizon_color * night_dim)
	sky_material.set_shader_parameter("ground_color", ground_col * night_dim)

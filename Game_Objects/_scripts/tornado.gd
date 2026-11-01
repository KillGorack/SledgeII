extends Node3D
class_name Tornado

# The old game's roaming tornado, which Creative levels place as "Tornado". A funnel of smoke that wanders the
# level, bouncing off the edge of its footprint, and drags any craft that comes near it round and up.
#
# While building it stays exactly where it was placed (so it can be picked and removed) and does nothing. Playing,
# the host moves it and tells everybody where it is; every peer draws it and pushes only its own craft, since a
# peer only drives its own craft's physics (the others are frozen copies, see movement.gd).
#
# Set `bounds` (the XZ area it may roam, already shrunk by the margin) before adding it to the tree.

const FLIPBOOK := preload("res://Materials/Textures/Particles/T_smoke_flipbook.png")
# A short wind recording (Roloxi, CC BY 4.0 - see the Credits screen), looped by _ready().
const WIND := preload("res://Game_Objects/Sounds/tornado_wind.ogg")

const SPEED := 2.0               # metres per second across the level
const SYNC_INTERVAL := 0.5       # the host re-sends where it is this often

# The funnel is a wind field: at every point there is a wind (round, in and up near the core, thrown out at the
# top), and a craft is dragged toward it with a real force, DRAG newtons for every m/s it differs from the wind.
# The force doesn't depend on the craft, so a light craft (the Lightning, 5 kg) is whipped about while a heavy
# one is barely moved, and nothing can speed up past the wind itself. Turn these up or down to taste.
const RADIUS := 10.0
const HEIGHT := 15.0
const DRAG := 14.0               # N per m/s of difference from the wind: how hard it grips
const SWIRL_SPEED := 26.0        # m/s round the funnel at its fastest
const INFLOW_SPEED := 7.0        # m/s toward the middle (more near the core)
const UPDRAFT_SPEED := 14.0      # m/s up at the core
const THROW_SPEED := 30.0        # m/s outward once it reaches the top
const TOP_START := 0.7           # fraction of HEIGHT where the updraft ends and the throw begins
# The pull that bends a craft's path round the funnel instead of letting it slide off: v^2/r times this. A
# little over 1 spirals a craft slowly in rather than holding it in a circle.
const BEND := 1.15
const REFERENCE_MASS := 5.0      # the Lightning; BEND's pull is sized for it
const SPIN_RATE := 6.0           # rad/s the funnel turns a craft about its up axis
const SPIN_GRIP := 10.0          # N m per rad/s of difference from that
const TUMBLE := 16.0             # N m that rolls a craft about, deep in the funnel

var bounds := Rect2()

var _home := Vector3.ZERO        # where it was placed
var _velocity := Vector3.ZERO
var _sync_left := 0.0
var _was_building := true
var _wind: AudioStreamPlayer3D


func _ready() -> void:
	_home = position
	_reset_course()
	add_child(_build_funnel())
	_wind = AudioStreamPlayer3D.new()
	_wind.name = "Wind"
	var wind: AudioStreamOggVorbis = WIND.duplicate()
	wind.loop = true
	_wind.stream = wind
	_wind.unit_size = 20.0
	_wind.max_distance = 120.0
	add_child(_wind)


# The smoke: 250 camera-facing flipbook puffs spun slowly round the up axis, as in the old scene.
func _build_funnel() -> GPUParticles3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 1.0, 2.0)
	material.albedo_texture = FLIPBOOK
	material.emission_enabled = true
	material.emission_energy_multiplier = 2.89
	material.emission_texture = FLIPBOOK
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.particles_anim_h_frames = 8
	material.particles_anim_v_frames = 8
	material.particles_anim_loop = false

	var swirl_curve := Curve.new()
	swirl_curve.min_value = 0.0
	swirl_curve.max_value = 50.0
	for point in [Vector2(0.0, 1.2378), Vector2(14.257, 1.2378), Vector2(47.5904, 1.72543), Vector2(49.2972, 46.5866)]:
		swirl_curve.add_point(point)
	var swirl_texture := CurveTexture.new()
	swirl_texture.curve = swirl_curve

	var process := ParticleProcessMaterial.new()
	process.particle_flag_rotate_y = true
	process.angle_min = -360.0
	process.angle_max = 360.0
	process.direction = Vector3(0.0, 4.0, 0.0)
	process.spread = 0.01
	process.initial_velocity_min = 3.0
	process.initial_velocity_max = 3.0
	process.angular_velocity_min = -50.0
	process.angular_velocity_max = 50.0
	process.gravity = Vector3.ZERO
	process.tangential_accel_min = 3.0
	process.tangential_accel_max = 7.0
	process.tangential_accel_curve = swirl_texture
	process.anim_speed_min = 1.0
	process.anim_speed_max = 1.0

	var quad := QuadMesh.new()
	quad.size = Vector2(8.0, 8.0)

	var funnel := GPUParticles3D.new()
	funnel.name = "Funnel"
	funnel.scale = Vector3.ONE * 10.0
	funnel.amount = 250
	funnel.fixed_fps = 60
	funnel.local_coords = true
	funnel.material_override = material
	funnel.process_material = process
	funnel.draw_pass_1 = quad
	# Far bigger than the default box once scaled up, so it isn't culled while the funnel is on screen.
	funnel.visibility_aabb = AABB(Vector3(-5.0, -1.0, -5.0), Vector3(10.0, 8.0, 10.0))
	var twirl := Node3D.new()
	twirl.set_script(preload("res://_globals/twirl.gd"))
	twirl.set("spin_speed", 5.0)
	twirl.set("enable_x", false)
	twirl.set("enable_z", false)
	funnel.add_child(twirl)
	return funnel


func _physics_process(delta: float) -> void:
	var building := NetworkManager.creative_building
	if building:
		# Back where it was placed, still, so what you see is what you built.
		position = _home
		_was_building = true
		_wind.stream_paused = true
		return
	if _was_building:
		_was_building = false
		_reset_course()
		if not _wind.playing:
			_wind.play()
		_wind.stream_paused = false
	_move(delta)
	_grip_crafts()
	if multiplayer.is_server():
		_sync_left -= delta
		if _sync_left <= 0.0:
			_sync_left = SYNC_INTERVAL
			_sync_to_peers.rpc(position, _velocity)


# Everybody integrates the same straight line and bounce; the host's occasional word keeps them together.
func _move(delta: float) -> void:
	position += _velocity * delta
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	if position.x < bounds.position.x or position.x > bounds.end.x:
		_velocity.x = -_velocity.x
		position.x = clampf(position.x, bounds.position.x, bounds.end.x)
	if position.z < bounds.position.y or position.z > bounds.end.y:
		_velocity.z = -_velocity.z
		position.z = clampf(position.z, bounds.position.y, bounds.end.y)


# A direction made from where it stands, so every peer starts the same way until the host says otherwise.
func _reset_course() -> void:
	var angle := fposmod(sin(_home.x * 12.9898 + _home.z * 78.233) * 43758.5453, 1.0) * TAU
	_velocity = Vector3(cos(angle), 0.0, sin(angle)) * SPEED
	position = _home


func _grip_crafts() -> void:
	var clock := Time.get_ticks_msec() / 1000.0
	for craft in get_tree().get_nodes_in_group("Craft"):
		if not craft is RigidBody3D or not craft.is_multiplayer_authority():
			continue
		var offset: Vector3 = global_position - craft.global_position
		var flat := Vector3(offset.x, 0.0, offset.z)
		var height: float = -offset.y   # how far up the funnel the craft is
		if flat.length() > RADIUS or height < -2.0 or height > HEIGHT * 1.15:
			continue
		var core := smoothstep(0.0, 1.0, 1.0 - flat.length() / RADIUS)   # 1 at the middle, 0 at the rim
		var level := clampf(height / HEIGHT, 0.0, 1.0)
		# Straight toward and round the middle; on the axis itself they have no direction, so they fade to nothing.
		var inward := flat.normalized() if flat.length() > 0.5 else Vector3.ZERO
		var around := Vector3.UP.cross(inward).normalized() if inward != Vector3.ZERO else Vector3.ZERO
		var swirl := SWIRL_SPEED * (0.35 + 0.65 * core) * minf(flat.length() / 3.0, 1.0)
		var wind: Vector3
		var bend := Vector3.ZERO
		if level < TOP_START:
			# Down in the funnel: carried round, drawn in and lifted, hardest at the core.
			wind = around * swirl + inward * INFLOW_SPEED * (0.4 + 0.6 * core) + Vector3.UP * UPDRAFT_SPEED * (0.3 + 0.7 * core)
			bend = inward * minf(swirl * swirl / maxf(flat.length(), 2.5) * BEND, 60.0) * REFERENCE_MASS
		else:
			# At the top it lets go: no more lift, and the craft is thrown out along the way it was turning.
			var release := smoothstep(TOP_START, 1.0, level)
			wind = (-inward * THROW_SPEED + around * swirl * 1.2) * release
		craft.apply_central_force((wind - craft.linear_velocity) * DRAG + bend)
		# Turned round with the swirl, and rolled about when it's deep in.
		var spin_target := SPIN_RATE * core
		craft.apply_torque(Vector3.UP * (spin_target - craft.angular_velocity.y) * SPIN_GRIP)
		craft.apply_torque(-craft.global_basis.z * TUMBLE * core * core * sin(clock * 2.3 + float(craft.get_instance_id() % 7)))


@rpc("authority", "call_remote", "unreliable")
func _sync_to_peers(at: Vector3, velocity: Vector3) -> void:
	if NetworkManager.creative_building:
		return
	position = at
	_velocity = velocity

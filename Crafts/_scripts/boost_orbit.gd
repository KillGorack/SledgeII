extends Node3D
class_name BoostOrbit

# Small spinning medallions circling a craft that has weapon boosts active, so
# everyone ELSE can read the threat (which boosts, and roughly how long they
# have left). Never created on your own craft - your HUD already shows yours and
# the coins would only get in your way - see weapon_node.gd::_ready. Teammates
# see them too.
#
# A pooled set of billboard sprites built once and shown/hidden as boosts come
# and go (nothing is created or freed while playing). The look is the boost's own
# icon sheet row, replayed as the same spinning coin the pickup uses. The orbit
# is centred on the craft's collider (its true middle, fore/aft - the craft's
# origin is at the turret pivot, not the middle of the hull), turning with the
# craft's heading but not its tilt, so the ring stays level.

const SLOTS := 6
const ORBIT_RADIUS := 0.4 # m: clears the 1.6 m hull
const ORBIT_HEIGHT := 0.2 # m above the craft's origin: over the turret
const COIN_WIDTH := 0.125 # m on screen
const TURN_RATE := 2 # rad/s
const BOB := 0.1 # m: how far each coin bobs up and down
const BOB_RATE := 10.0 # rad/s: how fast (2 is about one bob every 3 s)
const FRAME_SIZE := 256.0
const WARN_SECONDS := 4.0 # blink like the HUD icon

# boost resource_path -> SpriteFrames, shared by every craft's orbit.
static var _frames_cache: Dictionary = {}

var weapon_node: Node
var craft: Node3D

var _slots: Array[AnimatedSprite3D] = []
var _end_msec: Array = [] # per shown slot
var _angle := 0.0
# Middle of the craft's collider, in the craft's local space (x, z only).
var _centre_offset := Vector3.ZERO
var _time := 0.0


func _ready() -> void:
	top_level = true
	_centre_offset = _collider_centre()
	for i in SLOTS:
		var sprite := AnimatedSprite3D.new()
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.pixel_size = COIN_WIDTH / FRAME_SIZE
		sprite.visible = false
		add_child(sprite)
		_slots.append(sprite)
	if weapon_node:
		weapon_node.boosts_changed.connect(_refresh)
		_refresh()


func _refresh() -> void:
	var status: Array = weapon_node.boost_status()
	var now := Time.get_ticks_msec()
	_end_msec.clear()
	for i in SLOTS:
		var sprite := _slots[i]
		if i < status.size():
			var boost: BoostSettings = status[i]["boost"]
			var frames := _frames_for(boost)
			if frames:
				sprite.sprite_frames = frames
				sprite.play(&"default")
			_end_msec.append(now + int(status[i]["left"] * 1000.0))
			sprite.visible = frames != null
		else:
			sprite.visible = false
			sprite.stop()


func _process(delta: float) -> void:
	if craft == null or not is_instance_valid(craft):
		return
	var shown := _end_msec.size()
	if shown == 0:
		return
	_time += delta
	_angle += TURN_RATE * delta
	var craft_xf := craft.get_global_transform_interpolated()
	var yaw := craft_xf.basis.get_euler(EULER_ORDER_YXZ).y
	global_position = craft_xf.origin + Basis(Vector3.UP, yaw) * _centre_offset
	var now := Time.get_ticks_msec()
	for i in shown:
		var a := _angle + TAU * i / shown
		var sprite := _slots[i]
		sprite.position = Vector3(cos(a) * ORBIT_RADIUS, ORBIT_HEIGHT + sin(_time * BOB_RATE + i) * BOB, sin(a) * ORBIT_RADIUS)
		var left := maxf(0.0, (_end_msec[i] - now) / 1000.0)
		sprite.modulate.a = 1.0 if left > WARN_SECONDS or int(left * 4.0) % 2 == 0 else 0.3


# Where the middle of the craft's collider sits, local to the craft, flattened to
# the ground plane. The collider is a convex hull assigned by craft_builder.gd,
# so this is the centre of its bounding box.
func _collider_centre() -> Vector3:
	var collider := craft.get_node_or_null("Collider") as CollisionShape3D if craft else null
	var hull := collider.shape as ConvexPolygonShape3D if collider else null
	if hull == null or hull.points.is_empty():
		return Vector3.ZERO
	var box := AABB(hull.points[0], Vector3.ZERO)
	for point in hull.points:
		box = box.expand(point)
	var centre := collider.transform * box.get_center()
	return Vector3(centre.x, 0.0, centre.z)


# The boost's pickup coin: its icon is frame 1 of a 16-frame row of the sheet, so
# the rest of the row is the spin. Falls back to a still image for any other icon.
static func _frames_for(boost: BoostSettings) -> SpriteFrames:
	if boost == null or boost.icon == null:
		return null
	var key := boost.resource_path
	if _frames_cache.has(key):
		return _frames_cache[key]
	var frames := SpriteFrames.new()
	frames.set_animation_speed(&"default", 17.0)
	frames.set_animation_loop(&"default", true)
	var icon := boost.icon as AtlasTexture
	if icon == null:
		frames.add_frame(&"default", boost.icon)
	else:
		for i in 16:
			var frame := AtlasTexture.new()
			frame.atlas = icon.atlas
			frame.region = Rect2(i * FRAME_SIZE, icon.region.position.y, FRAME_SIZE, FRAME_SIZE)
			frames.add_frame(&"default", frame)
	_frames_cache[key] = frames
	return frames

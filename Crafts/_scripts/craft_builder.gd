class_name CraftBuilder

# Dresses the shared craft.tscn body as a specific CraftDef. Runs identically on
# every peer (inside match.gd::_spawn_craft, before the craft enters the tree),
# purely from the def + team, so nothing here is replicated.

const SPAWN_CLEARANCE := 0.12
const FLOOR_SENSOR_HEIGHT := 0.35
const FLOOR_SENSOR_BELOW_HULL := 0.06
const RAY_INSET_X := 0.75
const RAY_Z_FRACTION := 0.35
# The source art is dark (mean ~0.25), so the grayscale is lifted before the team tint multiplies it down again
const GRAY_GAIN := 1.4
# How much of the (very saturated) station color survives on the hull: 0 = plain gray, 1 = full color
const TINT_STRENGTH := 0.45

# "<model path>|<team>" -> Array[Material] (per surface). The tank textures are
# a few dozen pixels square, so recoloring one is trivially cheap, but only once.
static var _tinted: Dictionary = {}
static var _gray: Dictionary = {}


static func build(craft: RigidBody3D, def: CraftDef, team: String) -> void:
	var model := def.model.instantiate()
	var body_src := model.get_node("Body") as MeshInstance3D
	var turret_src := model.get_node_or_null("Turret") as MeshInstance3D
	var barrel_src := model.get_node("Barrel") as MeshInstance3D

	var hull := craft.get_node("Hull") as MeshInstance3D
	var turret := craft.get_node("Turret") as MeshInstance3D
	var barrel := craft.get_node("Turret/Barrel") as MeshInstance3D
	hull.mesh = body_src.mesh
	turret.mesh = turret_src.mesh if turret_src else null
	barrel.mesh = barrel_src.mesh
	_apply_team_materials(hull, def, team)
	_apply_team_materials(turret, def, team)
	_apply_team_materials(barrel, def, team)

	var body_box := body_src.mesh.get_aabb()
	var hull_points := body_src.mesh.get_faces()
	if turret_src:
		hull_points.append_array(turret_src.mesh.get_faces())
	var top := body_box.end.y
	if turret_src:
		top = maxf(top, turret_src.mesh.get_aabb().end.y)
	var bottom := body_box.position.y
	var centre := body_box.get_center()

	var shape := ConvexPolygonShape3D.new()
	shape.points = hull_points
	craft.get_node("Collider").shape = shape

	var sensor_shape := BoxShape3D.new()
	sensor_shape.size = Vector3(body_box.size.x * 0.95, FLOOR_SENSOR_HEIGHT, body_box.size.z)
	var sensor := craft.get_node("FloorDetection/CollisionShape3D") as CollisionShape3D
	sensor.shape = sensor_shape
	sensor.position = Vector3(centre.x, bottom - FLOOR_SENSOR_BELOW_HULL, centre.z)

	var rays := craft.get_node("Suspension")
	var x := body_box.size.x * 0.5 * RAY_INSET_X
	var z := body_box.size.z * RAY_Z_FRACTION
	rays.get_node("FrontLeft").position = Vector3(x, bottom, centre.z - z)
	rays.get_node("FrontRight").position = Vector3(-x, bottom, centre.z - z)
	rays.get_node("RearLeft").position = Vector3(x, bottom, centre.z + z)
	rays.get_node("RearRight").position = Vector3(-x, bottom, centre.z + z)

	craft.center_of_mass = Vector3(centre.x, bottom, centre.z)
	craft.get_node("DamageSmoke").position = Vector3(centre.x, top, body_box.end.z - body_box.size.z * 0.2)

	craft.get_node("movement_node").stats = def.stats
	craft.get_node("health_node").stats = def.stats
	craft.get_node("power_node").stats = def.stats
	model.free()


# How far above a marker's ground point the craft origin must sit to clear it.
static func spawn_lift(def: CraftDef) -> float:
	var model := def.model.instantiate()
	var lift := -(model.get_node("Body") as MeshInstance3D).mesh.get_aabb().position.y + SPAWN_CLEARANCE
	model.free()
	return lift


static func _apply_team_materials(mi: MeshInstance3D, def: CraftDef, team: String) -> void:
	if mi.mesh == null:
		return
	var key := "%s|%s|%s" % [def.id, team, mi.name]
	if not _tinted.has(key):
		var list: Array[Material] = []
		for s in mi.mesh.get_surface_count():
			list.append(_team_material(mi.mesh.surface_get_material(s), def, team))
		_tinted[key] = list
	var mats: Array = _tinted[key]
	for s in mats.size():
		mi.set_surface_override_material(s, mats[s])


# The painted texture is flattened to grayscale once per source material and the
# team color is applied as the material's albedo tint, so all four teams share
# one texture per surface and hue never has to be "shifted" (which wrecked
# near-gray and red pixels).
static func _team_material(src: Material, def: CraftDef, team: String) -> Material:
	var std := src as StandardMaterial3D
	if std == null or std.albedo_texture == null:
		return src
	var out := std.duplicate() as StandardMaterial3D
	out.albedo_texture = _gray_texture(std.albedo_texture)
	out.albedo_color = Color.WHITE.lerp(ReconStation.render_color_for_team(team), TINT_STRENGTH)
	return out


static func _gray_texture(source: Texture2D) -> Texture2D:
	if _gray.has(source):
		return _gray[source]
	var image := source.get_image()
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			var v := minf(c.get_luminance() * GRAY_GAIN, 1.0)
			image.set_pixel(x, y, Color(v, v, v, c.a))
	var tex := ImageTexture.create_from_image(image)
	_gray[source] = tex
	return tex

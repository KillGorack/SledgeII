class_name CreativeLevelBuilder

# Turns sanitized CreativeLevel data into a Node3D laid out the way
# match.gd expects of a map: base pads and spawns tagged by group, recon
# anchors under a "recon_locations" node. Used by the editor (to rebuild a
# level for editing/testing) and by match.gd (to load a Creative level).
#
# Every building piece is a StaticBody3D whose origin is the piece's corner
# (as in the old game) with Face/Back meshes, so painting just swaps the
# material on those two.

const PAD_SIZE := Vector2(7.0, 7.0)
const PAD_THICKNESS := 0.02
const WORLD_LAYER := 2 # bit value for Utilities.GROUP_LAYER_SCOPE["world"]
# Editor-only layer so the builder's raycast can hit spawn/recon markers, which
# have no collider of their own. Nothing else masks this layer.
const PICK_LAYER := 1 << 19
# Same friction/bounce the old game's creative surfaces used.
const WALL_PHYSICS := preload("res://Physics/physics_walls.tres")
const FLOOR_PHYSICS := preload("res://Physics/physics_floor.tres")
const GROUND_THICKNESS := 2.0
# Recon stations and base pads sit exactly on the surface they were placed on, which tears (z-fighting). Built
# this much higher; the saved level keeps the placed position.
const SURFACE_LIFT := 0.003
static var _pad_materials: Dictionary = {}

# "material_id|w|h" -> Material. A tiled surface needs its own uv scale, but
# thousands of surfaces share a handful of sizes, so don't make one each.
static var _material_cache: Dictionary = {}
static var _piece_mesh_cache: Dictionary = {}
# The XZ area the level's own geometry covers: where a tornado is allowed to roam.
static var _footprint := Rect2()
# The XZ rectangle the recon stations span: a tornado keeps inside it when there are enough recons to make one.
static var _recon_area := Rect2()
const MIN_RECON_AREA := 8.0
const TORNADO_MARGIN := 10.0


# `editing` adds the pick proxies that make markers visible and removable.
# Every node made for an entry carries it as meta "entry" (the same Dictionary
# that lives in `data`), and meta "root" is the node to free to remove it.
static func build(data: Dictionary, editing: bool = false) -> Node3D:
	_footprint = _level_footprint(data)
	_recon_area = _recon_footprint(data)
	var root := Node3D.new()
	root.name = "CreativeLevel"
	var recon_locations := Node3D.new()
	recon_locations.name = "recon_locations"
	root.add_child(recon_locations)
	# While building, the big ground is what you place things on. Playing, there is a boundary instead: the floor
	# trimmed to the level and clear walls round it (see make_boundary).
	if editing and not data.get("ground", {}).is_empty():
		root.add_child(make_ground(data.ground))
	for entry in data.get("surfaces", []):
		root.add_child(make_surface(entry))
	for entry in data.get("pieces", []):
		root.add_child(make_piece(entry))
	for entry in data.get("objects", []):
		var node := make_object(entry, recon_locations, editing)
		if node:
			root.add_child(node)
	if not editing:
		root.add_child(make_boundary(data, root))
	return root


# --- boundary --------------------------------------------------------------

const WALL_THICKNESS := 4.0
# How far the clear walls reach above the floor in a Force level; any other genre gets WALL_ABOVE over its highest piece.
const FORCE_CEILING := 128.0
const WALL_ABOVE := 10.0
# Below the lowest piece, so nothing slips under a wall.
const WALL_BELOW := 20.0


# The floor trimmed to what was built (no margin) and invisible walls and a lid round it, so nothing leaves the
# level. The footprint is measured from the built level, so it is exactly what is there; a level with nothing
# in it falls back to a floor of the ground's own size. `root` is the built level (without a boundary yet).
static func make_boundary(data: Dictionary, root: Node3D) -> Node3D:
	var boundary := Node3D.new()
	boundary.name = "Boundary"
	var bounds := measure(root, data)
	var has_ground: bool = not data.get("ground", {}).is_empty()
	if bounds.size == Vector3.ZERO:
		var half: float = float(data.ground.size) * 0.5 if has_ground else 0.0
		if half <= 0.0:
			return boundary
		bounds = AABB(Vector3(-half, 0.0, -half), Vector3(half * 2.0, 1.0, half * 2.0))
	if has_ground:
		boundary.add_child(_floor(data.ground, bounds))
	var top: float = maxf(bounds.end.y + WALL_ABOVE, 0.0 + WALL_ABOVE)
	if data.get("genre", "") == CreativeLevel.FORCE_GENRE:
		top = maxf(FORCE_CEILING, bounds.end.y + WALL_ABOVE)
	var bottom: float = minf(bounds.position.y, 0.0) - WALL_BELOW
	var height := top - bottom
	var x0 := bounds.position.x
	var x1 := bounds.end.x
	var z0 := bounds.position.z
	var z1 := bounds.end.z
	var t := WALL_THICKNESS
	var mid_y := bottom + height * 0.5
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	walls.collision_layer = WORLD_LAYER
	walls.collision_mask = 0
	walls.physics_material_override = WALL_PHYSICS
	# [centre, size]: west, east, north, south sides (each spans the corners too), then the lid.
	for slab in [
		[Vector3(x0 - t * 0.5, mid_y, (z0 + z1) * 0.5), Vector3(t, height, z1 - z0 + t * 2.0)],
		[Vector3(x1 + t * 0.5, mid_y, (z0 + z1) * 0.5), Vector3(t, height, z1 - z0 + t * 2.0)],
		[Vector3((x0 + x1) * 0.5, mid_y, z0 - t * 0.5), Vector3(x1 - x0, height, t)],
		[Vector3((x0 + x1) * 0.5, mid_y, z1 + t * 0.5), Vector3(x1 - x0, height, t)],
		[Vector3((x0 + x1) * 0.5, top + t * 0.5, (z0 + z1) * 0.5), Vector3(x1 - x0 + t * 2.0, t, z1 - z0 + t * 2.0)],
	]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = slab[1]
		shape.shape = box
		shape.position = slab[0]
		walls.add_child(shape)
	boundary.add_child(walls)
	boundary.set_meta("bounds", bounds)
	return boundary


# The ground as a flat rectangle exactly over `bounds`, tiled once per metre.
static func _floor(ground: Dictionary, bounds: AABB) -> StaticBody3D:
	var width := bounds.size.x
	var depth := bounds.size.z
	var centre := Vector3(bounds.position.x + width * 0.5, 0.0, bounds.position.z + depth * 0.5)
	var body := StaticBody3D.new()
	body.name = "Floor"
	body.position = centre
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	body.physics_material_override = FLOOR_PHYSICS
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, GROUND_THICKNESS, depth)
	shape.shape = box
	shape.position.y = -GROUND_THICKNESS * 0.5
	body.add_child(shape)
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, depth)
	mesh_instance.mesh = plane
	var material: Material = CreativeCatalog.get_material(StringName(ground.m)).duplicate()
	if material is BaseMaterial3D:
		material.uv1_scale = Vector3(width, depth, width)
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	return body


# What the level covers, as one box: the visible meshes of everything built (not the ground or boundary) and the
# position of every object that stands somewhere (the spawn marker does not count: it is a fallback at the
# origin, nowhere near the level). An empty box means nothing was built.
static func measure(root: Node3D, data: Dictionary = {}) -> AABB:
	var bounds := AABB()
	var found := false
	for entry in _mesh_boxes(root, Transform3D.IDENTITY):
		bounds = entry if not found else bounds.merge(entry)
		found = true
	for entry in data.get("objects", []):
		if entry.get("id") == "spawn" or entry.get("p", []).size() < 3:
			continue
		var spot := AABB(Vector3(entry.p[0] - 0.5, entry.p[1], entry.p[2] - 0.5), Vector3(1.0, 1.0, 1.0))
		bounds = spot if not found else bounds.merge(spot)
		found = true
	return bounds


static func _mesh_boxes(node: Node, to_root: Transform3D) -> Array:
	var boxes: Array = []
	for child in node.get_children():
		if not child is Node3D or not child.visible or child.name in ["Ground", "Floor", "Boundary", "recon_locations"]:
			continue
		var xform: Transform3D = to_root * child.transform
		if child is MeshInstance3D and child.mesh:
			boxes.append(xform * child.mesh.get_aabb())
		boxes.append_array(_mesh_boxes(child, xform))
	return boxes


# The XZ rectangle covering every surface, piece and object (surfaces by their longest side, so a rotated
# one is never cut short).
static func _level_footprint(data: Dictionary) -> Rect2:
	var area := Rect2()
	var first := true
	for key in ["surfaces", "pieces", "objects"]:
		for entry in data.get(key, []):
			var p: Array = entry.get("p", [])
			if p.size() < 3:
				continue
			var reach: float = maxf(entry.s[0], entry.s[1]) if entry.has("s") else 1.0
			var box := Rect2(Vector2(p[0] - reach, p[2] - reach), Vector2(reach, reach) * 2.0)
			area = box if first else area.merge(box)
			first = false
	return area


# The XZ rectangle spanning the recon stations, or an empty one with fewer than two.
static func _recon_footprint(data: Dictionary) -> Rect2:
	var points: Array[Vector2] = []
	for entry in data.get("objects", []):
		if entry.get("id") == "recon" and entry.get("p", []).size() >= 3:
			points.append(Vector2(entry.p[0], entry.p[2]))
	if points.size() < 2:
		return Rect2()
	var area := Rect2(points[0], Vector2.ZERO)
	for point in points:
		area = area.expand(point)
	return area


# Flat ground with its top at y = 0, centered on the origin. Not an entry:
# it can't be picked, painted or removed with the build tools.
static func make_ground(ground: Dictionary) -> StaticBody3D:
	var size: float = ground.size
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	body.physics_material_override = FLOOR_PHYSICS
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, GROUND_THICKNESS, size)
	shape.shape = box
	shape.position.y = -GROUND_THICKNESS * 0.5
	body.add_child(shape)
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	mesh_instance.mesh = plane
	# The turf material is authored to tile once per metre at 500m.
	var material: Material = CreativeCatalog.get_material(StringName(ground.m)).duplicate()
	if material is BaseMaterial3D:
		material.uv1_scale = Vector3(size, size, size)
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	return body


static func make_surface(entry: Dictionary) -> StaticBody3D:
	var size := Vector2(entry.s[0], entry.s[1])
	var body := _body(entry)
	# Quad centered on its own origin, then shifted so the corner is the origin.
	var mesh := QuadMesh.new()
	mesh.size = size
	var offset := Transform3D(Basis.IDENTITY, Vector3(size.x * 0.5, size.y * 0.5, 0.0))
	_add_faces(body, mesh, offset)
	var corners := [Vector3(0, 0, 0), Vector3(size.x, 0, 0), Vector3(size.x, size.y, 0), Vector3(0, size.y, 0)]
	body.add_child(_trimesh_collider(corners, [0, 1, 2, 2, 3, 0]))
	paint(body, StringName(entry.m))
	return body


static func make_piece(entry: Dictionary) -> StaticBody3D:
	var id := StringName(entry.id)
	var def: Dictionary = CreativeCatalog.PIECES[id]
	var body := _body(entry)
	_add_faces(body, piece_mesh(id), Transform3D.IDENTITY, piece_mesh(id, true))
	body.add_child(_trimesh_collider(def.points, def.faces))
	paint(body, StringName(entry.m))
	return body


# The editor's ghost and the pieces share these meshes. `reversed` is the same
# face wound the other way, drawn as the back so the piece shows from both sides.
static func piece_mesh(id: StringName, reversed: bool = false) -> ArrayMesh:
	var cache_key := "%s|%s" % [id, reversed]
	if _piece_mesh_cache.has(cache_key):
		return _piece_mesh_cache[cache_key]
	var def: Dictionary = CreativeCatalog.PIECES[id]
	var points: Array = def.points
	var faces: Array = def.faces
	var normal := _face_normal(points, faces) * (-1.0 if reversed else 1.0)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Texture laid across the face's own plane, one tile per metre.
	var origin: Vector3 = points[0]
	var u_axis := ((points[1] as Vector3) - origin).normalized()
	var v_axis := normal.cross(u_axis).normalized()
	if def.has("uv_axes"):
		u_axis = def.uv_axes[0]
		v_axis = def.uv_axes[1]
	for point in points:
		vertices.append(point)
		normals.append(normal)
		var local: Vector3 = point - origin
		uvs.append(Vector2(local.dot(u_axis), local.dot(v_axis)))
	for i in range(0, faces.size(), 3):
		if reversed:
			indices.append_array(PackedInt32Array([faces[i], faces[i + 2], faces[i + 1]]))
		else:
			indices.append_array(PackedInt32Array([faces[i], faces[i + 1], faces[i + 2]]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_piece_mesh_cache[cache_key] = mesh
	return mesh


# The old game's collision: the bare face as a triangle mesh, solid from both
# sides, no thickness. Anything thicker adds edges the old pieces never had.
static func _trimesh_collider(points: Array, faces: Array) -> CollisionShape3D:
	var triangles := PackedVector3Array()
	for index in faces:
		triangles.append(points[index])
	var shape := ConcavePolygonShape3D.new()
	shape.data = triangles
	shape.backface_collision = true
	var collider := CollisionShape3D.new()
	collider.shape = shape
	return collider


# Outward (front) normal of the piece's first triangle. Godot treats clockwise
# as front-facing, hence the sign flip from the usual counter-clockwise cross.
static func _face_normal(points: Array, faces: Array) -> Vector3:
	var a: Vector3 = points[faces[0]]
	var b: Vector3 = points[faces[1]]
	var c: Vector3 = points[faces[2]]
	return -(b - a).cross(c - a).normalized()


static func make_object(entry: Dictionary, recon_locations: Node3D, editing: bool = false) -> Node3D:
	var id := StringName(entry.id)
	var def: Dictionary = CreativeCatalog.OBJECTS[id]
	var team := CreativeCatalog.object_team(id, entry.get("t"))
	var color: Color = CreativeCatalog.TEAMS[team] if def.has("teams") else def.get("color", Color(1.0, 0.8, 0.2))
	var node: Node3D
	match def.kind:
		"pad":
			# Bounds from a mesh because match.gd sizes the spawn grid from them.
			node = _pad(entry, color)
			node.position.y += SURFACE_LIFT
			if editing:
				_add_pad_pick_proxy(node, entry)
		"recon":
			# match.gd parents a real station to each child of recon_locations.
			var anchor := Marker3D.new()
			anchor.set_meta("team", String(team))
			# recon_station.gd keeps a station of a fixed colour (never captured) when its anchor is in recon_<colour>.
			if team != &"neutral":
				anchor.add_to_group("recon_%s" % team)
			recon_locations.add_child(anchor)
			_place(anchor, entry)
			anchor.position.y += SURFACE_LIFT
			if editing:
				_add_pick_proxy(anchor, entry, color, CreativeCatalog.object_lift(id), false)
			return null
		"turret":
			# Built the same while editing and playing: it only acts when the match is not in build mode.
			var sentry := Sentry.new()
			sentry.team = "team_%s" % team
			node = sentry
			_place(node, entry)
			# A distinct name on every peer: the turret's destroyed/restored calls travel by node path.
			node.name = "Sentry_%d_%d_%d" % [roundi(node.position.x), roundi(node.position.y), roundi(node.position.z)]
			if editing:
				_add_pick_proxy(node, entry, color, 0.0, false)
			return node
		"tornado":
			var tornado := Tornado.new()
			if _recon_area.size.x >= MIN_RECON_AREA and _recon_area.size.y >= MIN_RECON_AREA:
				tornado.bounds = _recon_area
			elif _footprint.size.x > TORNADO_MARGIN * 2.0 and _footprint.size.y > TORNADO_MARGIN * 2.0:
				tornado.bounds = _footprint.grow(-TORNADO_MARGIN)   # too few recons to make an area: the level instead
			node = tornado
			_place(node, entry)
			# Named by where it stands, so the host's position updates find it on every peer.
			node.name = "Tornado_%d_%d_%d" % [roundi(node.position.x), roundi(node.position.y), roundi(node.position.z)]
			if editing:
				_add_pick_proxy(node, entry, color, CreativeCatalog.object_lift(id))
			return node
		"spawn":
			node = Marker3D.new()
			_place(node, entry)
			if editing:
				_add_pick_proxy(node, entry, Color(1.0, 0.8, 0.2), CreativeCatalog.object_lift(id))
		"boulder":
			node = make_boulder(entry)
			_place(node, entry)
			node.scale = Vector3.ONE * CreativeCatalog.boulder_scale(entry.get("sc"))
		"decor":
			node = def.scene.instantiate()
			_place(node, entry)
			if editing:
				_add_decor_pick_proxy(node, entry)
		"placeholder":
			if not editing:
				return null
			node = Marker3D.new()
			_place(node, entry)
			_add_pick_proxy(node, entry, color, CreativeCatalog.object_lift(id))
		_:
			return null
	if def.has("group"):
		node.add_to_group(String(def.group) + (String(team) if def.has("teams") else ""))
	node.name = String(id)
	return node


# Swap the material on a piece's faces (both sides), keeping its tiling.
static func paint(body: Node, material_id: StringName) -> void:
	var size: Array = body.get_meta("entry").get("s", [])
	var material := _material_for(material_id, size)
	for face_name in ["Face", "Back"]:
		var face: MeshInstance3D = body.get_node(face_name)
		face.material_override = material


static func _material_for(material_id: StringName, size: Array) -> Material:
	var key := "%s|%s" % [material_id, size]
	if _material_cache.has(key):
		return _material_cache[key]
	var material: Material = CreativeCatalog.get_material(material_id)
	if not size.is_empty() and material is BaseMaterial3D:
		# Tile once per metre, like the old game's resize_surface.
		material = material.duplicate()
		material.uv1_scale = Vector3(size[0], size[1], 1.0)
	_material_cache[key] = material
	return material


static func _body(entry: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	body.physics_material_override = WALL_PHYSICS
	body.set_meta("entry", entry)
	body.set_meta("root", body)
	_place(body, entry)
	return body


# Two meshes back to back, like the old game, so both sides draw and take the
# same material. A surface's back is its front turned around its own centre;
# a piece passes its own reversed mesh, since turning it would pivot on its corner.
static func _add_faces(body: StaticBody3D, mesh: Mesh, offset: Transform3D, back_mesh: Mesh = null) -> void:
	var face := MeshInstance3D.new()
	face.name = "Face"
	face.mesh = mesh
	face.transform = offset
	body.add_child(face)
	var back := MeshInstance3D.new()
	back.name = "Back"
	if back_mesh:
		back.mesh = back_mesh
		back.transform = offset
	else:
		back.mesh = mesh
		back.transform = offset * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	body.add_child(back)


# A flat, shiny slab that only looks like a pad: no collision, so craft pass over it without a ledge. It is a
# MeshInstance3D because match.gd sizes the spawn grid from a pad's mesh bounds, and the mesh is offset so the
# node's origin is the pad's corner (it extends along +X and +Z). "corner_origin" tells match.gd to centre the
# base guns and hum on the footprint rather than on that corner.
static func _pad(entry: Dictionary, color: Color) -> MeshInstance3D:
	var pad := MeshInstance3D.new()
	pad.mesh = _pad_mesh(color)
	pad.set_meta("corner_origin", true)
	_place(pad, entry)
	return pad


# A box that starts at the origin and extends along +X and +Z (BoxMesh can only be centred).
static func _pad_mesh(color: Color) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3(PAD_SIZE.x, PAD_THICKNESS, PAD_SIZE.y)
	var arrays := box.get_mesh_arrays()
	var shift := box.size * 0.5
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		vertices[i] += shift
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _pad_material(color))
	return mesh


static func _pad_material(color: Color) -> StandardMaterial3D:
	if _pad_materials.has(color):
		return _pad_materials[color]
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.4
	material.metallic_specular = 0.9
	material.roughness = 0.15
	_pad_materials[color] = material
	return material


# Editor only: a thin pick target over the pad's footprint, so Remove can find a pad that has no collision.
static func _add_pad_pick_proxy(pad: Node3D, entry: Dictionary) -> void:
	var proxy := StaticBody3D.new()
	proxy.position = Vector3(PAD_SIZE.x * 0.5, 0.03, PAD_SIZE.y * 0.5)
	proxy.collision_layer = PICK_LAYER
	proxy.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(PAD_SIZE.x, 0.06, PAD_SIZE.y)
	shape.shape = box
	proxy.add_child(shape)
	proxy.set_meta("entry", entry)
	proxy.set_meta("root", pad)
	pad.add_child(proxy)


# Editor only: an invisible pick target around everything a visual-only object draws, so Remove can find it.
static func _add_decor_pick_proxy(node: Node3D, entry: Dictionary) -> void:
	var bounds := _mesh_bounds(node, Transform3D.IDENTITY)
	if bounds.size == Vector3.ZERO:
		return
	var proxy := StaticBody3D.new()
	proxy.position = bounds.get_center()
	proxy.collision_layer = PICK_LAYER
	proxy.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = bounds.size.max(Vector3(0.5, 0.5, 0.5))
	shape.shape = box
	proxy.add_child(shape)
	proxy.set_meta("entry", entry)
	proxy.set_meta("root", node)
	node.add_child(proxy)


# The box around every mesh under `node`, in the space `to_node` takes it to (children of a model can carry their own
# transforms, e.g. an imported .glb).
static func _mesh_bounds(node: Node, to_node: Transform3D) -> AABB:
	var bounds := AABB()
	var found := false
	if node is MeshInstance3D and node.mesh:
		bounds = to_node * (node as MeshInstance3D).get_aabb()
		found = true
	for child in node.get_children():
		var child_to_node := to_node * (child as Node3D).transform if child is Node3D else to_node
		var child_bounds := _mesh_bounds(child, child_to_node)
		if child_bounds.size != Vector3.ZERO:
			bounds = child_bounds if not found else bounds.merge(child_bounds)
			found = true
	return bounds


static func _add_pick_proxy(marker: Node3D, entry: Dictionary, color: Color, lift: float, show_cube: bool = true) -> void:
	var proxy := StaticBody3D.new()
	proxy.position.y = lift
	proxy.collision_layer = PICK_LAYER
	proxy.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.shape = box
	proxy.add_child(shape)
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color, 0.6)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = material
	mesh_instance.mesh = mesh
	mesh_instance.visible = show_cube
	proxy.add_child(mesh_instance)
	proxy.set_meta("entry", entry)
	proxy.set_meta("root", marker)
	marker.add_child(proxy)


# variant index -> its material: the pack's normal map for relief over one flat rock colour (the pack has no colour
# texture of its own).
static var _boulder_materials: Dictionary = {}


static func _boulder_material_for(variant: int) -> Material:
	if not _boulder_materials.has(variant):
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.5, 0.48, 0.45)
		material.roughness = 1.0
		material.normal_enabled = true
		material.normal_texture = load(CreativeCatalog.BOULDERS[variant].normal)
		_boulder_materials[variant] = material
	return _boulder_materials[variant]


static func boulder_mesh(variant: int) -> Mesh:
	return load(CreativeCatalog.BOULDERS[CreativeCatalog.boulder_variant(variant)].mesh)


# How far a boulder's mesh is moved (the rocks are modelled around their middle) so its lowest point sits `sink` of
# its height below the ground it was placed on. Per unit of scale.
static func boulder_drop(mesh: Mesh, sink: float) -> float:
	var box := mesh.get_aabb()
	return -box.position.y - sink * box.size.y


# A solid rock: world layer like a wall, so crafts and shots hit it. The caller scales the body; the mesh and its
# collider scale with it.
static func make_boulder(entry: Dictionary) -> StaticBody3D:
	var mesh := boulder_mesh(CreativeCatalog.boulder_variant(entry.get("v")))
	var body := StaticBody3D.new()
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	body.physics_material_override = WALL_PHYSICS
	var offset := Transform3D(Basis.IDENTITY, Vector3(0.0, boulder_drop(mesh, CreativeCatalog.boulder_sink(entry.get("sk"))), 0.0))
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.name = "Rock"
	visual.material_override = _boulder_material_for(CreativeCatalog.boulder_variant(entry.get("v")))
	visual.transform = offset
	body.add_child(visual)
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_convex_shape()
	shape.transform = offset
	body.add_child(shape)
	# Found by the editor's Remove, the way a surface is.
	body.set_meta("entry", entry)
	body.set_meta("root", body)
	return body


static func _place(node: Node3D, entry: Dictionary) -> void:
	var p: Array = entry.p
	var r: Array = entry.r
	node.position = Vector3(p[0], p[1], p[2])
	node.rotation_degrees = Vector3(r[0], r[1], r[2])

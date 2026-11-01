class_name CreativeThumbnail

# The picture a published level gets in the Create Game list: an aerial view of its geometry, framed from its own
# bounds. The camera rig is the one the map pipeline uses for the old maps' thumbnails (Pipeline/tools/thumbs_blender.py)
# so the list looks of a piece: from the south-west side, 42 degrees down (steeper for a tall level), pulled back until
# the footprint fits with a margin. The level's ground is in the picture but not in the framing: only what was built is measured.
#
# var image: Image = await CreativeThumbnail.render(self, level_content)

const SIZE := Vector2i(640, 360)
const PITCH := deg_to_rad(42.0)
const YAW := deg_to_rad(-45.0)
const FOV := 54.4          # horizontal, the 35 mm lens the pipeline uses
const MARGIN := 0.96       # the footprint fills at most this much of the frame width
const BLEED := 0.04        # top and bottom may run this far (fraction of height) out of frame: zooms in on the detail


# Draws the level off screen and returns the picture, or null when nothing can be drawn (headless) or it is empty.
static func render(host: Node, content: Dictionary) -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var level := CreativeLevelBuilder.build(CreativeLevel.sanitize(content), false)
	# The ground is drawn but never measured: it is 500 m of turf whatever the level is, so only what was built
	# decides the framing.
	var meshes := _meshes(level, Transform3D.IDENTITY).filter(func(m): return not m.ground)
	if meshes.is_empty():
		level.free()
		return null
	var bounds: AABB = meshes[0].box
	for m in meshes:
		bounds = bounds.merge(m.box)

	var viewport := SubViewport.new()
	viewport.size = SIZE
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	host.add_child(viewport)
	viewport.add_child(level)
	# Only the picture is wanted: no turret aiming, no tornado wandering, no sounds.
	level.process_mode = Node.PROCESS_MODE_DISABLED

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.012, 0.018, 0.03)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.65, 0.85)
	environment.ambient_light_energy = 0.9
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, -60.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4000.0
	viewport.add_child(sun)
	var camera := Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = FOV
	camera.far = 20000.0
	viewport.add_child(camera)
	_frame(camera, bounds)

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	return image


# Every mesh below `node` with its box in the level's space: [{box: AABB, node, ground}]. Walked by hand: nothing here is in
# the tree yet, so global transforms are not available.
static func _meshes(node: Node, to_level: Transform3D) -> Array:
	var found: Array = []
	for child in node.get_children():
		if not child is Node3D or not child.visible:
			continue
		var xform: Transform3D = to_level * child.transform
		if child is MeshInstance3D and child.mesh:
			found.append({"box": xform * child.mesh.get_aabb(), "node": child, "ground": child.get_parent().name in ["Ground", "Floor"]})
		found.append_array(_meshes(child, xform))
	return found


# The pipeline's own fit: aim near the floor, steeper the taller the level is, then back the camera off until the
# footprint's corners fit, and slide it so their projected box is centred.
static func _frame(camera: Camera3D, bounds: AABB) -> void:
	var low := bounds.position
	var high := bounds.end
	var extent := maxf(bounds.size.x, bounds.size.z)
	var tall := high.y - low.y
	var pitch := PITCH + deg_to_rad(25.0) * minf(tall / maxf(extent, 0.001), 0.4) / 0.4
	var centre := Vector3((low.x + high.x) * 0.5, low.y + minf(tall, 6.0) * 0.3, (low.z + high.z) * 0.5)
	# Camera on the south-west side (-X, +Z in Godot), looking at the centre.
	var toward := Vector3(sin(YAW) * cos(pitch), sin(pitch), -cos(YAW) * cos(pitch)).normalized()
	toward.x = -absf(toward.x)
	toward.z = absf(toward.z)
	var corners: Array[Vector3] = []
	for x in [low.x, high.x]:
		for y in [low.y, high.y]:
			for z in [low.z, high.z]:
				corners.append(Vector3(x, y, z))
	var aspect := float(SIZE.x) / float(SIZE.y)
	var half := tan(deg_to_rad(FOV) * 0.5)
	var basis := Basis.looking_at(-toward, Vector3.UP)
	var shift := Vector2.ZERO

	# Projected corners in the frame (-1..1 across and up), for a camera at `distance` slid by `shift` metres.
	var project := func(distance: float, slide: Vector2) -> Rect2:
		var position := centre + toward * distance + basis.x * slide.x + basis.y * slide.y
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for corner in corners:
			var view: Vector3 = basis.inverse() * (corner - position)
			var depth := maxf(-view.z, 0.001)
			var ndc := Vector2(view.x / (depth * half), view.y / (depth * half) * aspect)
			lo = lo.min(ndc)
			hi = hi.max(ndc)
		return Rect2(lo, hi - lo)

	var near := 1.0
	var far := extent * 20.0 + 100.0
	for _i in 40:
		var mid := (near + far) * 0.5
		var box: Rect2 = project.call(mid, shift)
		if box.size.x <= 2.0 * MARGIN and box.size.y <= 2.0 * (1.0 + 2.0 * BLEED):
			far = mid
		else:
			near = mid
	var distance := far
	# Slide it so the projected box sits in the middle of the frame.
	for _i in 4:
		var box: Rect2 = project.call(distance, shift)
		var middle := box.get_center()
		shift += Vector2(middle.x * distance * half, middle.y * distance * half / aspect)
	camera.global_transform = Transform3D(basis, centre + toward * distance + basis.x * shift.x + basis.y * shift.y)

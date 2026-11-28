extends Node

const GROUP_LAYER_SCOPE = {
	"world": {
		"layer": 2,
		"layer_mask": [],
		"target_groups": []
	},
	# 4 teams instead of 2 - each craft's layer_mask still includes every
	# team's craft layer (so crafts always physically collide with each
	# other, friend or foe, same as the old team_a/team_b setup), but
	# target_groups (used for weapon-targeting queries, not physics) now
	# lists the other three instead of just one opponent.
	"team_red": {
		"layer": 3,
		"layer_mask": [2, 3, 4, 5, 6],
		"target_groups": ["team_green", "team_blue", "team_gray"]
	},
	"team_green": {
		"layer": 4,
		"layer_mask": [2, 3, 4, 5, 6],
		"target_groups": ["team_red", "team_blue", "team_gray"]
	},
	"team_blue": {
		"layer": 5,
		"layer_mask": [2, 3, 4, 5, 6],
		"target_groups": ["team_red", "team_green", "team_gray"]
	},
	"team_gray": {
		"layer": 6,
		"layer_mask": [2, 3, 4, 5, 6],
		"target_groups": ["team_red", "team_green", "team_blue"]
	},
	# Each team's projectile layer masks world + the three ENEMY craft
	# layers only (never its own team's craft layer, never another team's
	# projectile layer) - that's the actual friendly-fire-at-the-physics-level
	# mechanism collision_handler.gd relies on, same as the old 2-team setup.
	"projectile_team_red": {
		"layer": 7,
		"layer_mask": [2, 4, 5, 6, 12, 13, 14],
		"target_groups": ["team_green", "team_blue", "team_gray"]
	},
	"projectile_team_green": {
		"layer": 8,
		"layer_mask": [2, 3, 5, 6, 11, 13, 14],
		"target_groups": ["team_red", "team_blue", "team_gray"]
	},
	"projectile_team_blue": {
		"layer": 9,
		"layer_mask": [2, 3, 4, 6, 11, 12, 14],
		"target_groups": ["team_red", "team_green", "team_gray"]
	},
	"projectile_team_gray": {
		"layer": 10,
		"layer_mask": [2, 3, 4, 5, 11, 12, 13],
		"target_groups": ["team_red", "team_green", "team_blue"]
	}
}

const MAX_AUDIO_PLAYERS = 32
var audio_pool: Array = []

# Godot's own AudioStreamPlayer3D defaults (unit_size=10, max_distance=0 i.e.
# unlimited) are sized for room-scale games, not a craft combat arena where
# basic_cannon alone has a 300-unit projectile_range - left untouched, every
# sound stayed near full volume way past where it should have started fading
# and never fully cut off at range. unit_size=15 keeps close-range (muzzle
# right at the listener) sounds at full volume; max_distance=350 (just past
# the longest weapon range) means distant fire actually fades out instead of
# lingering audibly forever.
const AUDIO_UNIT_SIZE := 15.0
const AUDIO_MAX_DISTANCE := 350.0

func _ready() -> void:
	for i in range(MAX_AUDIO_PLAYERS):
		var player = AudioStreamPlayer3D.new()
		player.name = "AudioStreamPlayer3D_%d" % i
		player.unit_size = AUDIO_UNIT_SIZE
		player.max_distance = AUDIO_MAX_DISTANCE
		player.finished.connect(_on_audio_finished.bind(player))
		add_child(player)
		audio_pool.append(player)

func _process(_delta: float) -> void:
	pass


func GarbageCollection(node: Node, delay: float) -> void:
	if not node:
		return
	var timer = Timer.new()
	timer.wait_time = delay
	timer.one_shot = true
	node.add_child(timer)
	timer.connect("timeout", func():
		if is_instance_valid(node):
			node.queue_free()
		timer.queue_free()
	)
	timer.start()

# Duck-typed walk for projectile/explosion tinting - see
# collision_handler.gd::_apply_projectile_color for why it asks each node
# rather than assuming any particular child exists.
func apply_projectile_color_recursive(node: Node, color: Color) -> void:
	if node.has_method("apply_projectile_color"):
		node.apply_projectile_color(color)
	for child in node.get_children():
		apply_projectile_color_recursive(child, color)


func set_allegiance(body: Node3D, group_name: String):
	if body and GROUP_LAYER_SCOPE.has(group_name):
		var layer_data = GROUP_LAYER_SCOPE[group_name]
		var collision_flags = 1 << (layer_data["layer"] - 1)
		var mask_flags = 0
		for mask_layer in layer_data["layer_mask"]:
			mask_flags |= 1 << (mask_layer - 1)
		if body is RigidBody3D or body is Area3D:
			body.collision_layer = collision_flags
			body.collision_mask = mask_flags
		body.add_to_group(group_name)

# Whose craft this is: the player (or bot) id it scores for, takes credit for, and is named after. For a player it
# is also the peer simulating it (its multiplayer authority); a bot is simulated by the host (authority 1) but keeps
# its own id here - see match.gd::_spawn_craft.
# Server only. The peers whose match scene (and so the level and everything in it) exists. A plain .rpc() on a node
# inside the level also reaches peers still loading, which have no such node and log "Node not found" for every call -
# send to these with rpc_id instead. Whatever a loading peer misses is caught up when it reports ready.
func ready_peers() -> Array:
	var match_node := get_tree().get_first_node_in_group("match")
	return match_node._ready_peers.keys() if match_node != null else []


func craft_owner_id(craft: Node) -> int:
	return int(craft.get_meta(&"owner_id", craft.get_multiplayer_authority()))


func is_bot_craft(craft: Node) -> bool:
	return NetworkManager.is_bot_id(craft_owner_id(craft))


func encode_dict_string(data: Dictionary) -> String:
	var query_string = []
	for key in data.keys():
		var encoded_key = String(key).uri_encode()
		var encoded_value = str(data[key]).uri_encode()
		query_string.append(encoded_key + "=" + encoded_value)
	return String("&").join(query_string)


func collect_bodies(space_state: PhysicsDirectSpaceState3D, origin: Vector3, n: int, dist: float, target_groups: Array) -> Array:
	var query := PhysicsShapeQueryParameters3D.new()
	query.transform = Transform3D(Basis(), origin)
	query.shape = SphereShape3D.new()
	query.shape.radius = dist

	var mask := 0
	for group_name in target_groups:
		if GROUP_LAYER_SCOPE.has(group_name):
			var layer: int = GROUP_LAYER_SCOPE[group_name]["layer"]
			mask |= 1 << (layer - 1)
			# Base guns' hit bodies (base_gun.gd::HIT_LAYER_OFFSET) sit on
			# their own layers, so splash has to look there too.
			if group_name.begins_with("team_"):
				mask |= 1 << (layer + 8 - 1)
	if mask == 0:
		mask = 0x7fffffff
	else:
		# Thrown objects (physics layer 15, see object_handler.gd) are no
		# team's target, but blasts should still be able to shove them.
		mask |= 1 << 14
		# Breakable props (barrels, layer 16) too.
		mask |= 1 << 15
	query.collision_mask = mask

	var result := space_state.intersect_shape(query, n)
	var filtered_result = []
	for item in result:
		# Thrown objects always pass: no team group, but blasts shove them.
		if item.collider.is_in_group("playthings") or item.collider.is_in_group("Breakable"):
			filtered_result.append(item)
			continue
		for group in target_groups:
			if item.collider.is_in_group(group):
				filtered_result.append(item)
				break
	return filtered_result


func select_target(origin: Vector3, forward_direction: Vector3, radius: float, max_angle: float, target_group: Array) -> Node:
	var min_bound = origin - Vector3(radius, radius, radius)
	var max_bound = origin + Vector3(radius, radius, radius)
	var max_angle_rad = deg_to_rad(max_angle)
	# Nearest valid target inside the box + cone wins.
	var best: Node = null
	var best_d2 := INF
	for group in target_group:
		for body in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(body):
				continue
			var pos = body.global_position
			if pos.x >= min_bound.x and pos.x <= max_bound.x and pos.y >= min_bound.y and pos.y <= max_bound.y and pos.z >= min_bound.z and pos.z <= max_bound.z:
				var to_target = (pos - origin).normalized()
				if abs(to_target.angle_to(forward_direction)) <= max_angle_rad:
					var d2 := origin.distance_squared_to(pos)
					if d2 < best_d2:
						best_d2 = d2
						best = body
	return best


func play_sound(audio_input: Variant, position: Vector3 = Vector3.ZERO, vol: float = 1.0):
	vol = vol / 5
	var stream = null
	if typeof(audio_input) == TYPE_STRING:
		stream = load(audio_input)
	elif audio_input is AudioStream:
		stream = audio_input
	else:
		return
	var player = get_free_player()
	if player:
		player.stream = stream
		player.global_transform.origin = position
		player.volume_db = linear_to_db(vol)
		player.play()


func get_free_player() -> AudioStreamPlayer3D:
	for player in audio_pool:
		if not player.is_playing():
			return player
	return null


func _on_audio_finished(player: AudioStreamPlayer3D):
	if player:
		player.stream = null

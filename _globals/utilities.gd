extends Node

const GROUP_LAYER_SCOPE = {
	"world": {
		"layer": 2,
		"layer_mask": [],
		"target_groups": []
	},
	"team_a": {
		"layer": 3,
		"layer_mask": [2, 3, 4],
		"target_groups": ["team_b"]
	},
	"team_b": {
		"layer": 4,
		"layer_mask": [2, 3, 4],
		"target_groups": ["team_a"]
	},
	"projectile_team_a": {
		"layer": 5,
		"layer_mask": [2, 4],
		"target_groups": ["team_b"]
	},
	"projectile_team_b": {
		"layer": 6,
		"layer_mask": [2, 3],
		"target_groups": ["team_a"]
	}
}

const MAX_AUDIO_PLAYERS = 32
var audio_pool: Array = []

func _ready() -> void:
	for i in range(MAX_AUDIO_PLAYERS):
		var player = AudioStreamPlayer3D.new()
		player.name = "AudioStreamPlayer3D_%d" % i
		player.finished.connect(_on_audio_finished.bind(player))
		add_child(player)
		audio_pool.append(player)

func _process(_delta: float) -> void:
	pass

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
	if mask == 0:
		mask = 0x7fffffff
	query.collision_mask = mask

	var result := space_state.intersect_shape(query, n)
	var filtered_result = []
	for item in result:
		for group in target_groups:
			if item.collider.is_in_group(group):
				filtered_result.append(item)
				break
	return filtered_result


func select_target(origin: Vector3, forward_direction: Vector3, radius: float, max_angle: float, target_group: Array) -> Node:
	var min_bound = origin - Vector3(radius, radius, radius)
	var max_bound = origin + Vector3(radius, radius, radius)
	var max_angle_rad = deg_to_rad(max_angle)
	var potential_targets = []
	for group in target_group:
		for body in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(body):
				continue
			var pos = body.global_position
			if pos.x >= min_bound.x and pos.x <= max_bound.x and pos.y >= min_bound.y and pos.y <= max_bound.y and pos.z >= min_bound.z and pos.z <= max_bound.z:
				var to_target = (pos - origin).normalized()
				if abs(to_target.angle_to(forward_direction)) <= max_angle_rad:
					potential_targets.append(body)
	if potential_targets.size() > 0:
		return potential_targets[randi() % potential_targets.size()]
	return null


func play_sound(audio_input: Variant, position: Vector3 = Vector3.ZERO, vol: float = 1.0):
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

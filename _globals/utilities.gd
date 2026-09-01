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
	}
}

func _ready() -> void:
	pass

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

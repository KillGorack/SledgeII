extends Node

# Developer launcher: run this scene (F6) to jump straight into building. The
# main menu's Build button does the same thing.


func _ready() -> void:
	if CreativeEditor.start_session() == OK:
		get_tree().change_scene_to_file.call_deferred("res://Networking/match.tscn")

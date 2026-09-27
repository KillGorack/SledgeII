extends Node

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if Input.is_action_pressed("screen_capture"):
			take_screen_capture()

func take_screen_capture():
	var documents_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var my_games_dir = "%s/My Games" % documents_dir
	var dir = DirAccess.open(my_games_dir)
	if dir == null:
		dir = DirAccess.open(documents_dir)
		if not dir.make_dir("My Games"):
			return
	var game_name = ProjectSettings.get_setting("application/config/name", "Game")
	var screenies_dir = "%s/%s/Screen Captures" % [my_games_dir, game_name]
	dir = DirAccess.open(screenies_dir)
	if dir == null:
		dir = DirAccess.open(my_games_dir)
		if not dir.make_dir_recursive(screenies_dir):
			dir = DirAccess.open(screenies_dir)
			if dir == null:
				return
	var now = Time.get_time_dict_from_system()
	var now_date = Time.get_date_dict_from_system()
	var datetime_string = "%04d%02d%02d%02d%02d%02d" % [
		now_date.year, now_date.month, now_date.day, now.hour, now.minute, now.second
	]
	var filename = "%s Screen Capture %s.png" % [game_name, datetime_string]
	var file_path = "%s/%s" % [screenies_dir, filename]
	var image = get_viewport().get_texture().get_image()
	if image:
		image.save_png(file_path)
	print("Screen capture saved.")

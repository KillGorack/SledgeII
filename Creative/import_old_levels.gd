extends Node

# Developer tool: imports old-game levels dumped as JSON text files into the
# local store. Put the files in user://old_levels/ named <server ID>.json (the
# game_creative_levels row's gcl_content), then run this scene. Each file is
# imported once; running again skips ones already imported.

const SOURCE_DIR := "user://old_levels/"


func _ready() -> void:
	for file_name in DirAccess.get_files_at(SOURCE_DIR):
		var source := "gcl:%s" % file_name.get_basename()
		if CreativeStore.find_imported(source) != "":
			print("skip %s (already imported)" % source)
			continue
		var converted := CreativeImport.from_old_text(FileAccess.get_file_as_string(SOURCE_DIR + file_name), "Imported %s" % file_name.get_basename())
		if converted.is_empty():
			print("could not read %s" % file_name)
			continue
		var level: Dictionary = converted.level
		print("%s: %d surfaces, %d pieces, %d objects, %d skipped" % [source, level.surfaces.size(), level.pieces.size(), level.objects.size(), converted.skipped])
		CreativeStore.create(level.name, level, source)
	# Levels imported before the ground existed: give them the old game's ground.
	for header in CreativeStore.list():
		var level := CreativeStore.get_level(header.local_id)
		if str(level.imported_from).begins_with("gcl:") and level.content.get("ground", {}).is_empty():
			level.content["ground"] = CreativeLevel.default_ground()
			CreativeStore.update_content(header.local_id)
			print("added ground to %s" % level.name)
	get_tree().quit()

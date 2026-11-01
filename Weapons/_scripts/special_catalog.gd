class_name SpecialCatalog

# Specials that aren't a resource - one-off abilities with their own code rather
# than a MineSettings-style .tres. They sit in the same Specials list as mines:
# the host ticks them on the host screen (index.gd), Shift+Tab cycles through
# them with the mines (weapon_node.gd), M is the action and Shift+M the
# secondary action, and the HUD shows the icon (hud_controller.gd).
#
# Adding one: an id + entry here, then what M / Shift+M do for it in
# weapon_node.gd and what the HUD counts for it in hud_controller.gd.

const CONTROLLER := &"controller"

const ENTRIES := {
	CONTROLLER: {
		"name": "Controller",
		"icon": preload("res://Weapons/icons/base_gun.png"),
		"description": "M calls one of your base's guns to where you are. Shift+M sends yours home.",
	},
}


static func ids() -> Array:
	return ENTRIES.keys()


static func display_name(id: StringName) -> String:
	return ENTRIES[id]["name"]


static func icon(id: StringName) -> Texture2D:
	return ENTRIES[id]["icon"]


static func description(id: StringName) -> String:
	return ENTRIES[id]["description"]

extends Control

# MOCK-UP ONLY - a throwaway layout for the redesigned Host Game screen. Nothing here
# talks to the network or the real lists; the data below is made up. Run this scene on
# its own (F6) and tell me what to move, then it gets built into UI/index.tscn.

const SAMPLE_MAPS := [
	["Aquaduct", "KillGorack", "Open", "Long sweeping channels with a recon at every bend. Fast, forgiving, and a good first map for new drivers."],
	["Bane", "KillGorack", "Open", "Four bases at the compass points, a wide arena between them."],
	["Chasm", "KillGorack", "Tight", "Floating recons over a deep drop. Fall damage matters here."],
	["Converge", "Community", "Open", "Every lane leads to the middle. Expect a lot of company there."],
]
const SAMPLE_WEAPONS := ["Basic Cannon", "Detno", "MKIV CEB", "Repulsor", "Plasma"]
const SAMPLE_SPECIALS := ["Detno Mine", "Force Mine"]
# What each preset ticks. "Custom" leaves the boxes alone.
const PRESETS := {
	"Standard": ["Basic Cannon", "Detno", "MKIV CEB", "Repulsor", "Plasma"],
	"Force only": ["Repulsor"],
	"Cannons only": ["Basic Cannon", "MKIV CEB"],
}

@onready var map_list: Tree = %MapList
@onready var map_title: Label = %MapTitle
@onready var map_byline: Label = %MapByline
@onready var map_description: RichTextLabel = %MapDescription
@onready var weapon_list: VBoxContainer = %WeaponList
@onready var specials_list: VBoxContainer = %SpecialsList
@onready var preset_picker: OptionButton = %PresetPicker
@onready var team_picker: OptionButton = %TeamPicker


func _ready() -> void:
	for team in ["Red", "Green", "Blue", "Gray"]:
		team_picker.add_item(team)
	preset_picker.add_item("Custom")
	for preset in PRESETS:
		preset_picker.add_item(preset)
	preset_picker.item_selected.connect(_on_preset_selected)
	for weapon in SAMPLE_WEAPONS:
		_add_check(weapon_list, weapon, true)
	for special in SAMPLE_SPECIALS:
		_add_check(specials_list, special, true)

	map_list.set_column_titles_visible(true)
	for i in 3:
		map_list.set_column_title(i, ["Title", "Author", "Type"][i])
	map_list.set_column_expand(0, true)
	var root := map_list.create_item()
	for map in SAMPLE_MAPS:
		var row := map_list.create_item(root)
		for i in 3:
			row.set_text(i, map[i])
		row.set_metadata(0, map)
	map_list.item_selected.connect(_on_map_selected)
	root.get_child(0).select(0)


func _add_check(parent: Container, text: String, pressed: bool) -> void:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = pressed
	check.toggled.connect(func(_on): preset_picker.select(0))
	parent.add_child(check)


func _on_map_selected() -> void:
	var map = map_list.get_selected().get_metadata(0)
	map_title.text = map[0]
	map_byline.text = "by %s   -   %s" % [map[1], map[2]]
	map_description.text = map[3]


func _on_preset_selected(index: int) -> void:
	var preset := preset_picker.get_item_text(index)
	if not PRESETS.has(preset):
		return
	for check in weapon_list.get_children():
		check.set_pressed_no_signal(PRESETS[preset].has(check.text))

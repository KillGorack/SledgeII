extends Control

# Sibling nodes on the same craft, not children of this HUD.
@onready var health_node: Node3D = get_node("../health_node")
@onready var weapon_node: Node3D = get_node("../weapon_node")
@onready var health_label: Label = $MarginContainer/VBoxContainer/Health
@onready var weapon_label: Label = $MarginContainer/VBoxContainer/Weapon

# Cached so the labels are only rebuilt on an actual change, not every frame -
# this runs once per visible craft per frame otherwise, for values that mostly
# sit still between hits.
var _last_shields: float = -1.0
var _last_armor: float = -1.0
var _last_life: float = -1.0
var _last_weapon_index: int = -1


func _ready() -> void:
	# This Control is never explicitly excluded from the recursive
	# set_multiplayer_authority() call in match.gd::_spawn_craft, so its own
	# authority already matches the craft's owning peer - same trick
	# movement.gd uses (_hide_own_body) to tell "is this actually my craft".
	# Every other peer's copy of this same scene just stays hidden forever.
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return


func _process(_delta: float) -> void:
	_update_health()
	_update_weapon()


func _update_health() -> void:
	if health_node.shields == _last_shields and health_node.armor == _last_armor and health_node.life == _last_life:
		return
	_last_shields = health_node.shields
	_last_armor = health_node.armor
	_last_life = health_node.life
	health_label.text = "Shields %d/%d   Armor %d/%d   Hull %d/%d" % [
		ceil(health_node.shields), health_node._shields_max,
		ceil(health_node.armor), health_node._armor_max,
		ceil(health_node.life), health_node._life_max,
	]


func _update_weapon() -> void:
	var index = weapon_node.current_weapon_index
	if index == _last_weapon_index:
		return
	_last_weapon_index = index
	var settings: WeaponSettings = weapon_node.weapon_settings[index] if index >= 0 and index < weapon_node.weapon_settings.size() else null
	weapon_label.text = "Weapon: %s" % (settings.weapon_name if settings else "-")

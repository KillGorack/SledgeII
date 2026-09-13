extends Control

# Sibling nodes on the same craft, not children of this HUD.
@onready var health_node: Node3D = get_node("../health_node")
@onready var weapon_node: Node3D = get_node("../weapon_node")
@onready var movement_node: Node3D = get_node("../movement_node")
@onready var power_node: Node3D = get_node("../power_node")
@onready var weapon_label: Label = $Weapon
@onready var speedometer: Control = $Speedometer
@onready var health_rings: Control = $HealthRings
@onready var resourcemeter: Control = $Resourcemeter
@onready var team_juice_bar: Control = $Bezel/TeamJuiceBar

# Team juice isn't per-craft (see match.gd/network_manager.gd) - "the
# match" is the one place that knows JUICE_CAPACITY, so this is looked up
# once rather than duplicating that number here to go stale if it's ever
# retuned.
var _match_node: Node = null

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
	_match_node = get_tree().get_first_node_in_group("match")
	NetworkManager.team_juice_changed.connect(_on_team_juice_changed)
	_update_team_juice_bar()


func _process(_delta: float) -> void:
	_update_health()
	_update_weapon()
	# No change-detection cache here like the two above - speed is basically
	# always changing while driving, so there'd be nothing to skip most frames.
	speedometer.set_speed_ratio(movement_node.get_speed_ratio())
	resourcemeter.set_resource_ratio(power_node.get_power_ratio())


func _on_team_juice_changed(team: String, _amount: float) -> void:
	if team == weapon_node.team:
		_update_team_juice_bar()


func _update_team_juice_bar() -> void:
	if _match_node == null:
		return
	var amount: float = NetworkManager.team_juice.get(weapon_node.team, 0.0)
	team_juice_bar.set_juice_ratio(amount / _match_node.JUICE_CAPACITY)


func _update_health() -> void:
	if health_node.shields == _last_shields and health_node.armor == _last_armor and health_node.life == _last_life:
		return
	_last_shields = health_node.shields
	_last_armor = health_node.armor
	_last_life = health_node.life
	health_rings.update_ratios(
		_ratio(health_node.shields, health_node._shields_max),
		_ratio(health_node.armor, health_node._armor_max),
		_ratio(health_node.life, health_node._life_max),
	)


func _ratio(current: float, max_value: float) -> float:
	return current / max_value if max_value > 0.0 else 0.0


func _update_weapon() -> void:
	var index = weapon_node.current_weapon_index
	if index == _last_weapon_index:
		return
	_last_weapon_index = index
	var settings: WeaponSettings = weapon_node.weapon_settings[index] if index >= 0 and index < weapon_node.weapon_settings.size() else null
	weapon_label.text = settings.weapon_name

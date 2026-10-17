extends Control

const PLAYER_LIST := preload("res://Crafts/_scripts/player_list.gd")

# Sibling nodes on the same craft, not children of this HUD.
@onready var health_node: Node3D = get_node("../health_node")
@onready var weapon_node: Node3D = get_node("../weapon_node")
@onready var movement_node: Node3D = get_node("../movement_node")
@onready var power_node: Node3D = get_node("../power_node")
@onready var weapon_label: Label = $Weapon
@onready var ammo_label: Label = $Weapon2
@onready var fps_label: Label = $FPS
@onready var arena_label: Label = $Arena
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
	arena_label.text = NetworkManager.current_map_title
	add_child(PLAYER_LIST.new())
	NetworkManager.team_juice_changed.connect(_on_team_juice_changed)
	_update_team_juice_bar()


func _process(_delta: float) -> void:
	_update_health()
	_update_weapon()
	_update_ammo()
	# No change-detection cache here like the two above - speed is basically
	# always changing while driving, so there'd be nothing to skip most frames.
	speedometer.set_speed_ratio(movement_node.get_speed_ratio())
	resourcemeter.set_resource_ratio(power_node.get_power_ratio())
	# The needle this whole lighting/light-count pass is trying to move -
	# Engine.get_frames_per_second() is the engine's own already-computed
	# rolling average, not something worth recomputing by hand here.
	# Second line: takedowns/wrecks and bounty. The bounty is read live (see
	# match.gd::get_my_bounty), the F4 list only refreshes it on events.
	var score: Array = NetworkManager.peer_scores.get(multiplayer.get_unique_id(), [0, 0, 0]) if NetworkManager.is_online() else [0, 0, 0]
	var bounty := int(_match_node.get_my_bounty()) if _match_node else 0
	fps_label.text = "FPS: %d\n%d/%d %d" % [Engine.get_frames_per_second(), score[0], score[1], bounty]
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


# No change-detection cache like _update_weapon()'s - unlike the weapon
# name, this changes on every shot fired, not just on switching weapons, so
# there'd be nothing to skip most of the time. Three states, same
# power-vs-ammo distinction request_fire() itself uses (power_consumption >
# 0.0 means this weapon spends power_node's shared pool, not per-weapon
# ammo): energy weapons show current/max power (rounded - the HUD doesn't
# need fractional power), ammo weapons show current/max count, and
# projectile_count_capacity == 0 (request_fire()'s own "unlimited" sentinel)
# skips the ratio entirely.
func _update_ammo() -> void:
	var index = weapon_node.current_weapon_index
	if index < 0 or index >= weapon_node.weapon_settings.size():
		return
	var settings: WeaponSettings = weapon_node.weapon_settings[index]
	if settings == null:
		return
	if settings.power_consumption > 0.0:
		var capacity: float = power_node.stats.power_capacity if power_node.stats else 0.0
		ammo_label.text = "%d / %d" % [roundi(power_node.current_power), roundi(capacity)]
	elif settings.projectile_count_capacity == 0:
		ammo_label.text = "Unlimited"
	else:
		# Bounds-checked, not a plain index - on a freshly-joined client the
		# replicated Array may not have arrived yet (starts empty, unlike the
		# old Dictionary's safe .get() fallback), so this still needs a
		# fallback for that brief window before the first sync lands.
		var remaining: int = weapon_node._ammo_remaining[index] if index < weapon_node._ammo_remaining.size() else settings.projectile_count_actual
		ammo_label.text = "%d / %d" % [remaining, settings.projectile_count_capacity]

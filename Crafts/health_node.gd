extends Node3D

@export var stats: CraftStats

var shields: float
var armor: float
var life: float

var _shields_max: float
var _armor_max: float
var _life_max: float

var _regeneration_timer: Timer
var _is_regenerating: bool = false

@onready var body: Node3D = get_parent()


func _ready() -> void:
	if stats == null:
		return
	# stats is a shared template resource (same values for every Lightning) -
	# current HP has to be per-instance mutable state, so it starts as a copy
	# of the template rather than mutating the shared resource directly.
	shields = stats.shields
	armor = stats.armor
	life = stats.life
	_shields_max = stats.shields
	_armor_max = stats.armor
	_life_max = stats.life

	_regeneration_timer = Timer.new()
	_regeneration_timer.wait_time = stats.regeneration_delay
	_regeneration_timer.one_shot = true
	_regeneration_timer.timeout.connect(_on_regeneration_timeout)
	add_child(_regeneration_timer)


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if _is_regenerating and shields < _shields_max:
		shields = min(_shields_max, shields + stats.regeneration_rate * delta)


# Only the server should ever decide damage - the collision handler that
# calls this only runs its hit-resolution logic on the server (see
# Weapons/collision_handler.gd), and this RPC shape ("authority", call_local)
# means only the server is allowed to invoke it, while the resulting HP
# values still get pushed out and applied identically on every client.
@rpc("authority", "call_local", "reliable")
func apply_damage(damage: float) -> void:
	_regeneration_timer.start()
	_is_regenerating = false
	if shields > 0:
		shields -= damage
		if shields <= 0:
			damage = -shields
			shields = 0
		else:
			return
	if armor > 0 and damage > 0:
		armor -= damage
		if armor < 0:
			damage = -armor
			armor = 0
		else:
			return
	if damage > 0:
		life -= damage
	if life <= 0 and multiplayer.is_server():
		destroy_self()


func destroy_self() -> void:
	# TODO: respawn/elimination flow - for now just report it happened.
	print("%s destroyed" % body.name)


func _on_regeneration_timeout() -> void:
	_is_regenerating = true

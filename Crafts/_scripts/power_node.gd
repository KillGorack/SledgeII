extends Node3D

# Proximity power charging - ported from the old game's power_node.gd.
# Recon stations (Game_Objects/recon_station.tscn, spawned onto each map's
# "recon_locations" markers - see match.gd) are tagged with the "Recon"
# group; being within stats.max_effect_distance of one charges power,
# faster the closer you are.
#
# Server-authoritative, same shape as health_node.gd's regen - not because
# charging itself needs defending yet, but because weapon_node.gd's
# request_fire() has to trust current_power enough to gate whether a shot is
# even allowed to fire, so the server has to be the one actually holding that
# number. Its own MultiplayerSynchronizer (see lightning.tscn) replicates
# .:current_power out to the owning client afterward, same reason
# health_node needed one for .:shields - a per-frame value that changes on
# its own has to be pushed, there's no discrete already-broadcast event to
# hang it off.

@export var stats: CraftStats

var current_power: float = 0.0

@onready var body: Node3D = get_parent()


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if stats == null:
		return
	# Real team now that one exists (was a host/client placeholder before -
	# see ReconStation.color_for_team for the string<->enum translation).
	var weapon_node = body.get_node_or_null("weapon_node")
	var my_color = ReconStation.color_for_team(weapon_node.team) if weapon_node else ReconStation.StationColor.NONE
	var total_gain := 0.0
	for recon in get_tree().get_nodes_in_group("Recon"):
		# Uncolored (never map-tagged, not yet captured) stations are inert
		# for now - only a colored one actually transmits, in either
		# direction, until a real capture mechanic decides what "neutral"
		# should mean.
		if recon.captured_color == ReconStation.StationColor.NONE:
			continue
		var distance = body.global_position.distance_to(recon.global_position)
		if distance <= stats.max_effect_distance:
			var closeness = 1.0 - (distance / stats.max_effect_distance)
			var rate = stats.power_gain_rate * closeness * delta
			total_gain += rate if recon.captured_color == my_color else -rate
	current_power = clamp(current_power + total_gain, 0.0, stats.power_capacity)


func get_power_ratio() -> float:
	return current_power / stats.power_capacity if stats and stats.power_capacity > 0.0 else 0.0


# Server-only, called from weapon_node.gd::request_fire(). Returns false (and
# leaves current_power untouched) if there isn't enough to cover the cost, so
# the caller can reject the shot outright rather than letting power go negative.
func try_spend(amount: float) -> bool:
	if amount > current_power:
		return false
	current_power -= amount
	return true

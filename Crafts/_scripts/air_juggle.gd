class_name AirJuggle
extends RefCounted

# Server-only juggle bookkeeping for one craft (owned by its health_node).
# While the craft is in the air, every hit counts for whoever landed it; if
# that air spell ends in the craft's death, the credited attacker's own count
# multiplies the kill payout (match.gd::_record_defeat). The hit that launches
# it lands while still grounded, so it doesn't count - only hits in the air do.
#
# "In the air" = no floor-like surface just below the craft, looking straight
# down in world space. A wall or the arena boundary is vertical, so it never
# counts as floor even with the craft pinned against it, and a craft flipped
# on its side on the ground still has the floor right below it - orientation
# doesn't matter. Runs on the server's own copy, so no client can claim it.

# Floor this far below the craft's origin (the turret pivot, ~0.3-0.5 above
# the hull bottom) still counts as grounded.
const PROBE_DEPTH := 1.0
const PROBE_START_UP := 0.2
# Flattest a surface may lean and still be floor (cos 45 degrees); walls never pass.
const FLOOR_MIN_NORMAL_Y := 0.7
# Rays at the centre and four points this far out, so teetering on an edge reads as grounded.
const FOOTPRINT := 0.3
# Grounded this long before the air spell (and its counts) ends, so a skim or bounce doesn't reset it.
const GROUND_GRACE_MSEC := 250
# One projectile can report itself twice (its shove, then its damage); count it once.
const SAME_HIT_MSEC := 100

var airborne: bool = false
var _ground_since: int = 0
# attacker peer id -> hits landed during this air spell
var _hits: Dictionary = {}
var _last_hit_msec: Dictionary = {}


func update(body: Node3D) -> void:
	var now := Time.get_ticks_msec()
	if not _on_floor(body):
		airborne = true
		_ground_since = 0
		return
	if _ground_since == 0:
		_ground_since = now
	if airborne and now - _ground_since >= GROUND_GRACE_MSEC:
		airborne = false
		_hits.clear()
		_last_hit_msec.clear()


func note_hit(attacker_id: int) -> void:
	if not airborne:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_hit_msec.get(attacker_id, -SAME_HIT_MSEC)) < SAME_HIT_MSEC:
		return
	_last_hit_msec[attacker_id] = now
	_hits[attacker_id] = int(_hits.get(attacker_id, 0)) + 1


# x1 unless this attacker landed hits in the air: then one times per hit.
func multiplier(attacker_id: int) -> int:
	return maxi(1, int(_hits.get(attacker_id, 0)))


func reset() -> void:
	airborne = false
	_ground_since = 0
	_hits.clear()
	_last_hit_msec.clear()


func _on_floor(body: Node3D) -> bool:
	var space := body.get_world_3d().direct_space_state
	var mask := 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)
	var origin := body.global_position
	for offset in [Vector3.ZERO, Vector3(FOOTPRINT, 0, 0), Vector3(-FOOTPRINT, 0, 0), Vector3(0, 0, FOOTPRINT), Vector3(0, 0, -FOOTPRINT)]:
		var start: Vector3 = origin + offset + Vector3.UP * PROBE_START_UP
		var query := PhysicsRayQueryParameters3D.create(start, origin + offset + Vector3.DOWN * PROBE_DEPTH, mask)
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and hit.normal.y >= FLOOR_MIN_NORMAL_Y:
			return true
	return false

extends Node3D
class_name LootManager

# Everything about drops, moved out of match.gd: how many a kill leaves, which item each is, placing it on the
# floor, and telling every peer. A child of the match (named "LootManager" on every peer - the RPCs below rely
# on it), and the parent of every pickup on the floor.
#
# Server rolls and places a drop when a craft is destroyed, then sends ONE reliable event (same channel as
# projectile spawn/end, so ordering holds). Every peer spawns its own static copy; the server detects pickups
# and announces them. Nothing about a drop is streamed.
#
# Which items can drop is data: the two tables below. Roll = pick a table (powerup_chance), then an item by
# its drop_weight. Items the match has no use for (LootItem.requires) sit out the roll.

const LOOT_SCENE := preload("res://Game_Objects/Loot/Scenes/loot_pickup.tscn")

@export var consumables: LootTable
@export var powerups: LootTable
# Chance that a drop comes from the powerups table (timed powerups and weapons) instead of the consumables.
@export_range(0.0, 1.0, 0.01) var powerup_chance: float = 0.25

# How many drops a destroyed craft (or base gun, sentry, barrel) leaves, set by the host's "Drops" setting
# (NetworkManager.loot_level picks a row). chance: the chance of at least one; extra: each further drop needs this
# again (at Normal, 2 is uncommon and 5 a rarity); most: the cap per kill; cap: the most lying around the arena at
# once (over it, the oldest goes). Every drop picks its own item by weight, so repeats can happen. On average a
# kill leaves nothing at None, about 0.7 drops at Normal, 1.5 at Abundance, 2.9 at Cornucopia and 6.5 at Absolute madness.
const LOOT_LEVELS := [
	{"name": "None", "chance": 0.0, "extra": 0.0, "most": 0, "cap": 1},
	{"name": "Normal", "chance": 0.5, "extra": 0.25, "most": 5, "cap": 30},
	{"name": "Abundance", "chance": 0.8, "extra": 0.45, "most": 6, "cap": 50},
	{"name": "Cornucopia", "chance": 1.0, "extra": 0.65, "most": 8, "cap": 80},
	{"name": "Absolute madness", "chance": 1.0, "extra": 0.85, "most": 12, "cap": 120},
]
# Index of "Normal" - what a new game starts on (the picker, the saved setting and NetworkManager all use it).
const DEFAULT_LEVEL := 1
# Several drops fan out in a ring around the wreck: this far (meters), plus a bit per drop so a big pile doesn't overlap.
const LOOT_RING_RADIUS := 2.0
const LOOT_RING_PER_DROP := 0.2
# TEMPORARY test switch: a .tres path here makes EVERY drop that item. Set back to "" for normal weighted drops.
const DEBUG_FORCE_LOOT := ""
# TEMPORARY test switch: every kill drops the WHOLE of both tables, in a ring around the wreck. Set to false
# for normal weighted drops. Wins over DEBUG_FORCE_LOOT.
const DEBUG_DROP_ALL := false

var _next_loot_id := 1
var _loot: Dictionary = {} # id -> LootPickup, on every peer
var _match: Node = null


func _ready() -> void:
	_match = get_parent()


# What this match is made of, for LootItem.requires. Everyone shares one loadout, so any craft's (already
# host-filtered) weapon list is the match's. Recomputed per roll: a handful of weapons, a few rolls per kill.
# No craft to read from = no conditions, everything may drop.
func _facts() -> Dictionary:
	for craft in get_tree().get_nodes_in_group("Craft"):
		var weapon_node := craft.get_node_or_null("weapon_node")
		if weapon_node:
			return LootItem.match_facts(weapon_node.weapon_settings, NetworkManager.recon_capture_enabled, NetworkManager.shields_enabled)
	return {}


func _roll() -> LootItem:
	if not DEBUG_FORCE_LOOT.is_empty():
		return load(DEBUG_FORCE_LOOT) as LootItem
	var facts := _facts()
	var first := powerups if randf() < powerup_chance else consumables
	var second := consumables if first == powerups else powerups
	var item := _pick(first, facts)
	return item if item != null else _pick(second, facts)


# Weighted pick from one table; null if it has nothing available.
func _pick(table: LootTable, facts: Dictionary) -> LootItem:
	if table == null:
		return null
	var pool: Array[LootItem] = []
	var total := 0.0
	for entry in table.items:
		if entry != null and entry.is_available(facts) and _allowed(entry):
			pool.append(entry)
			total += maxf(entry.drop_weight, 0.0)
	if total <= 0.0:
		return null
	var roll := randf() * total
	for entry in pool:
		roll -= maxf(entry.drop_weight, 0.0)
		if roll < 0.0:
			return entry
	return pool.back()


# The host's pick from the Drops tab (NetworkManager.allowed_loot); null = everything.
func _allowed(item: LootItem) -> bool:
	var allowed = NetworkManager.allowed_loot
	return item.easter_egg or allowed == null or allowed.has(item.resource_path)


func _level() -> Dictionary:
	return LOOT_LEVELS[clampi(NetworkManager.loot_level, 0, LOOT_LEVELS.size() - 1)]


func _roll_count() -> int:
	var level := _level()
	if randf() >= level.chance:
		return 0
	var count := 1
	while count < level.most and randf() < level.extra:
		count += 1
	return count


# Server only. A craft or structure was destroyed here: roll the drops and place them.
# dropper_peer: whose death left this - they can never pick it up (see loot_pickup.gd).
func drop_at(drop_at_pos: Vector3, dropper_peer: int = 0) -> void:
	if not multiplayer.is_server() or NetworkManager.creative_building:
		return
	if DEBUG_DROP_ALL:
		var all: Array[LootItem] = []
		for table in [consumables, powerups]:
			if table != null:
				all.append_array(table.items)
		for i in all.size():
			var angle := TAU * i / all.size()
			_spawn(all[i], drop_at_pos + Vector3(cos(angle), 0.0, sin(angle)) * 2.5, dropper_peer, drop_at_pos)
		return
	var count := _roll_count()
	if count == 0:
		return
	# One drop sits right under the wreck; several fan out in an evenly spaced
	# ring (random starting angle) so they never overlap.
	var start_angle := randf() * TAU
	for i in count:
		var spot := drop_at_pos
		if count > 1:
			var angle := start_angle + TAU * i / count
			spot += Vector3(cos(angle), 0.0, sin(angle)) * (LOOT_RING_RADIUS + LOOT_RING_PER_DROP * count)
		_spawn(_roll(), spot, dropper_peer, drop_at_pos if count > 1 else Vector3.INF)


# Server only: place one drop on the floor under `at` and announce it.
# anchor: the wreck, when `at` is one of several spots fanned out around it.
func _spawn(item: LootItem, at: Vector3, dropper_peer: int = 0, anchor: Vector3 = Vector3.INF) -> void:
	if item == null or item.resource_path.is_empty():
		return
	# Settle onto the floor under the wreck instead of hanging in the air (and never onto a
	# ceiling above it - see LootPickup.floor_point).
	var world_mask: int = 1 << (Utilities.GROUP_LAYER_SCOPE["world"]["layer"] - 1)
	var floor_at := LootPickup.floor_point(get_viewport().world_3d.direct_space_state, world_mask, at, anchor)
	if floor_at != Vector3.INF:
		at = floor_at # pickups sit ON the floor; the visual is 0.31 up
	elif at.y < HealthNode.FALL_DEATH_Y:
		return # died in the void: nothing to land on, nobody could reach it
	# Over the cap, the oldest goes.
	while _loot.size() >= int(_level().cap):
		collect(_loot.keys()[0], 0)
	var id := _next_loot_id
	_next_loot_id += 1
	_make(id, item, at, dropper_peer)
	for peer_id in _match._ready_peers:
		if peer_id != 1:
			_spawn_event.rpc_id(peer_id, id, item.resource_path, at)
	get_tree().create_timer(item.lifetime).timeout.connect(func(): collect(id, 0))


func _make(id: int, item: LootItem, at: Vector3, dropper_peer: int = 0) -> void:
	var pickup: LootPickup = LOOT_SCENE.instantiate()
	pickup.loot_id = id
	pickup.item = item
	pickup.dropped_by = dropper_peer
	pickup.position = at
	_loot[id] = pickup
	add_child(pickup)


@rpc("authority", "call_remote", "reliable", 2)
func _spawn_event(id: int, item_path: String, at: Vector3) -> void:
	var item := load(item_path) as LootItem
	if item and not _loot.has(id):
		_make(id, item, at)


# Server only. A late joiner is told about the drops already on the floor.
func sync_to(peer_id: int) -> void:
	for loot_id in _loot:
		var existing: LootPickup = _loot[loot_id]
		if is_instance_valid(existing):
			_spawn_event.rpc_id(peer_id, loot_id, existing.item.resource_path, existing.global_position)


# Server only. taker_peer 0 = expired / evicted rather than picked up.
func collect(id: int, taker_peer: int) -> void:
	if not _loot.has(id):
		return
	_remove(id, taker_peer)
	for peer_id in _match._ready_peers:
		if peer_id != 1:
			_remove_event.rpc_id(peer_id, id, taker_peer)


@rpc("authority", "call_remote", "reliable", 2)
func _remove_event(id: int, taker_peer: int) -> void:
	_remove(id, taker_peer)


func _remove(id: int, taker_peer: int) -> void:
	var pickup: LootPickup = _loot.get(id)
	_loot.erase(id)
	if not is_instance_valid(pickup):
		return
	# Only the taker hears the pickup sound.
	if taker_peer != 0 and taker_peer == multiplayer.get_unique_id() and pickup.item.pickup_sound:
		Utilities.play_sound(pickup.item.pickup_sound, pickup.global_position, 3)
	pickup.queue_free()

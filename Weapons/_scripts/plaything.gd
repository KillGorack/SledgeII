extends RigidBody3D
class_name Plaything

# Base for tossed game objects (object_handler.gd's dice, anything later).
# Everything extending this joins the "playthings" group and shares ONE cap
# PER TEAM, MAX_PLAYTHINGS, across all kinds: once the server has more than
# that alive for a team, that team's oldest are removed. Deliberately not in the "Projectile" group - that
# one belongs to collision_handler.gd and feeds the radar.
#
# Subclasses implement destroy_self() (and must call super._ready() from
# their own _ready()). Call enforce_cap() once a new one is live on the server.

const PLAYTHINGS_GROUP := "playthings"
# Per team, across all kinds of plaything that team has out.
const MAX_PLAYTHINGS := 10

# Whose cap this counts toward. Set by the spawner before the node enters the tree.
var team: String = ""
var spawned_msec := 0
var destroying := false


func _ready() -> void:
	add_to_group(PLAYTHINGS_GROUP)
	spawned_msec = Time.get_ticks_msec()


# Override. Must set destroying = true and be safe to call twice.
func destroy_self() -> void:
	queue_free()


# Server only: remove this team's oldest playthings beyond the cap.
func enforce_cap() -> void:
	var live: Array = []
	for node in get_tree().get_nodes_in_group(PLAYTHINGS_GROUP):
		if node is Plaything and is_instance_valid(node) and node.is_multiplayer_authority() and not node.destroying and node.team == team:
			live.append(node)
	var excess := live.size() - MAX_PLAYTHINGS
	if excess <= 0:
		return
	live.sort_custom(func(a: Plaything, b: Plaything): return a.spawned_msec < b.spawned_msec)
	for i in excess:
		live[i].destroy_self()

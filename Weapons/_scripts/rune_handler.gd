extends ThrownObject
class_name RuneObject

# Easter egg: a Diablo II rune stone, lobbed like the D20. Each shot rolls ONE
# rune, weighted roughly like D2 drop rates (El common ... Zod almost never).
#
# The roll is seeded by the projectile's net_id so every peer picks the same
# rune with no extra networking (a predicted shot swaps once the server hands
# it its real id - see object_handler.gd::net_id). The glb models ship with no
# textures, so the stone / glyph materials are applied here.

const STONE_MAT := preload("res://Game_Objects/Easter_Eggs/DII/rune_stone.tres")
const GLYPH_MAT := preload("res://Game_Objects/Easter_Eggs/DII/rune_glyph.tres")
# Longest face of the stone, metres.
const TARGET_SIZE := 0.4

# name -> [model, relative drop weight]. Drop chance (%) per the Diablo II rune table.
const RUNES := {
	"el": [preload("res://Game_Objects/Easter_Eggs/DII/el.glb"), 50.0570],
	"eld": [preload("res://Game_Objects/Easter_Eggs/DII/eld.glb"), 35.7067],
	"tir": [preload("res://Game_Objects/Easter_Eggs/DII/tir.glb"), 25.2019],
	"nef": [preload("res://Game_Objects/Easter_Eggs/DII/nef.glb"), 17.3264],
	"eth": [preload("res://Game_Objects/Easter_Eggs/DII/eth.glb"), 18.1371],
	"ith": [preload("res://Game_Objects/Easter_Eggs/DII/ith.glb"), 12.3528],
	"tal": [preload("res://Game_Objects/Easter_Eggs/DII/tal.glb"), 15.2770],
	"ral": [preload("res://Game_Objects/Easter_Eggs/DII/ral.glb"), 10.3674],
	"ort": [preload("res://Game_Objects/Easter_Eggs/DII/ort.glb"), 10.8664],
	"thul": [preload("res://Game_Objects/Easter_Eggs/DII/thul.glb"), 7.3346],
	"amn": [preload("res://Game_Objects/Easter_Eggs/DII/amn.glb"), 6.7373],
	"sol": [preload("res://Game_Objects/Easter_Eggs/DII/sol.glb"), 4.5255],
	"shael": [preload("res://Game_Objects/Easter_Eggs/DII/shael.glb"), 3.5940],
	"dol": [preload("res://Game_Objects/Easter_Eggs/DII/dol.glb"), 2.4055],
	"hel": [preload("res://Game_Objects/Easter_Eggs/DII/hel.glb"), 1.8576],
	"io": [preload("res://Game_Objects/Easter_Eggs/DII/io.glb"), 1.2409],
	"lum": [preload("res://Game_Objects/Easter_Eggs/DII/lum.glb"), 0.9323],
	"ko": [preload("res://Game_Objects/Easter_Eggs/DII/ko.glb"), 0.6222],
	"fal": [preload("res://Game_Objects/Easter_Eggs/DII/fal.glb"), 0.4701],
	"lem": [preload("res://Game_Objects/Easter_Eggs/DII/lem.glb"), 0.3136],
	"pul": [preload("res://Game_Objects/Easter_Eggs/DII/pul.glb"), 0.2361],
	"um": [preload("res://Game_Objects/Easter_Eggs/DII/um.glb"), 0.1574],
	"mal": [preload("res://Game_Objects/Easter_Eggs/DII/mal.glb"), 0.1352],
	"ist": [preload("res://Game_Objects/Easter_Eggs/DII/ist.glb"), 0.0901],
	"gul": [preload("res://Game_Objects/Easter_Eggs/DII/gul.glb"), 0.0011],
	"vex": [preload("res://Game_Objects/Easter_Eggs/DII/vex.glb"), 0.0008],
	"ohm": [preload("res://Game_Objects/Easter_Eggs/DII/ohm.glb"), 0.0011],
	"lo": [preload("res://Game_Objects/Easter_Eggs/DII/lo.glb"), 0.0004],
	"sur": [preload("res://Game_Objects/Easter_Eggs/DII/sur.glb"), 0.0004],
	"ber": [preload("res://Game_Objects/Easter_Eggs/DII/ber.glb"), 0.0002],
	"jah": [preload("res://Game_Objects/Easter_Eggs/DII/jah.glb"), 0.0002],
	"cham": [preload("res://Game_Objects/Easter_Eggs/DII/cham.glb"), 0.0001],
	"zod": [preload("res://Game_Objects/Easter_Eggs/DII/zod.glb"), 0.00003],
}

var rune_name := ""
var _model: Node3D = null


func _ready() -> void:
	_pick_rune()
	_build_model()
	super._ready()


func _net_id_assigned() -> void:
	# A predicted shot gets its real id after spawning: re-roll to match the server.
	if is_inside_tree():
		_pick_rune()
		_build_model()


func _pick_rune() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(net_id * 7919 + 104729)
	var total := 0.0
	for key in RUNES:
		total += float(RUNES[key][1])
	var roll := rng.randf() * total
	for key in RUNES:
		roll -= float(RUNES[key][1])
		if roll <= 0.0:
			rune_name = key
			return
	rune_name = "el"


func _build_model() -> void:
	if _model:
		_model.queue_free()
		_model = null
	_model = (RUNES[rune_name][0] as PackedScene).instantiate()
	add_child(_model)
	var bounds := _skin_and_measure(_model, Transform3D.IDENTITY)
	var longest := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	var s := TARGET_SIZE / maxf(longest, 0.001)
	_model.scale = Vector3.ONE * s
	_model.position = -bounds.get_center() * s
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node:
		var box := BoxShape3D.new()
		box.size = bounds.size * s
		shape_node.shape = box


# Applies the stone / glyph materials and returns the combined bounds.
func _skin_and_measure(node: Node, xf: Transform3D) -> AABB:
	var result := AABB()
	var first := true
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			for i in mi.mesh.get_surface_count():
				var base := mi.mesh.surface_get_material(i)
				var is_stone := base != null and base.resource_name.contains("Stone")
				mi.set_surface_override_material(i, STONE_MAT if is_stone else GLYPH_MAT)
			result = xf * mi.get_aabb()
			first = false
	for child in node.get_children():
		var child_xf := xf
		if child is Node3D:
			child_xf = xf * (child as Node3D).transform
		var b := _skin_and_measure(child, child_xf)
		if b.size != Vector3.ZERO:
			result = b if first else result.merge(b)
			first = false
	return result

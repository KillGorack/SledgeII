extends Resource
class_name CraftDef

# One selectable craft. Everything shared (physics, HUD, weapons, networking)
# lives in Crafts/Scenes/craft.tscn; a CraftDef only says what to put on it -
# see craft_builder.gd, which derives the collider, suspension and floor
# sensor from the model's own geometry at spawn, so there's nothing to hand-place.

@export var id: StringName
@export var display_name: String
@export_multiline var description: String
# glb with Body / Turret / Barrel meshes, origin at the turret pivot, nose on -Z
@export var model: PackedScene
@export var stats: CraftStats

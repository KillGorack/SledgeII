extends Resource
class_name RadarTargetDef

# One row of radar_controller.gd's target_defs table: any node in group_name
# gets a blip this size/shape. color is used as-is unless use_team_color is
# on, in which case radar_controller.gd looks up the target's own team
# (directly on the node, or on a child "weapon_node" - see
# radar_controller.gd::_team_of) and colors it with that instead - check this
# for anything whose color should track team (crafts, base guns, ...).
# Recon stations are the one thing this table can't drive: their color is
# capture state (captured_color), not "this node's own team", so
# radar_controller.gd keeps that as a separate hardcoded case regardless of
# this flag.
enum Shape { SQUARE, DOT }

@export var group_name: String = ""
@export var color: Color = Color.WHITE
@export var use_team_color: bool = false
@export var size: Vector2 = Vector2(4, 4)
@export var shape: Shape = Shape.SQUARE

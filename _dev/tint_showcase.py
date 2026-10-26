# Multiplies a tint color over each tank's baked gray texture in ShowCase.blend (re-runnable: it edits its own "Tint" node).
#   blender -b ShowCase.blend --python tint_showcase.py -- <out.blend> [preview.png]
# Colors are the game's team colors blended 45% toward white, same as craft_builder.gd's TINT_STRENGTH.
import bpy, sys
args = sys.argv[sys.argv.index("--")+1:]
out = args[0]
preview = args[1] if len(args) > 1 else None
TEAM = {"red": (0.9, 0.15, 0.15), "green": (0.2, 0.85, 0.25), "blue": (0.2, 0.55, 1.0), "gray": (0.6, 0.6, 0.6)}
STRENGTH = 0.45
TANK_TINTS = {"Vanguard": "green", "Devastator": "red", "Chameleon": "blue", "Mag Rider": "blue"}  # others stay gray

def tint_color(name):
    r, g, b = TEAM[name]
    return (1 + (r - 1) * STRENGTH, 1 + (g - 1) * STRENGTH, 1 + (b - 1) * STRENGTH, 1.0)

for tank, team in TANK_TINTS.items():
    for part in bpy.data.objects[tank].children:
        if part.type != 'MESH':
            continue
        for mat in part.data.materials:
            nt = mat.node_tree
            node = nt.nodes.get("Tint")
            if node is None:
                tex = next(n for n in nt.nodes if n.type == 'TEX_IMAGE')
                bsdf = nt.nodes["Principled BSDF"]
                node = nt.nodes.new("ShaderNodeMix")
                node.name = node.label = "Tint"
                node.data_type = 'RGBA'; node.blend_type = 'MULTIPLY'
                node.inputs[0].default_value = 1.0
                node.location = (tex.location.x + 300, tex.location.y)
                nt.links.new(tex.outputs["Color"], node.inputs[6])
                nt.links.new(node.outputs[2], bsdf.inputs["Base Color"])
            node.inputs[7].default_value = tint_color(team)
    print("TINTED", tank, team)
if preview:
    sc = bpy.context.scene
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.light = 'FLAT'; sc.display.shading.color_type = 'TEXTURE'
    sc.render.resolution_x, sc.render.resolution_y = 1400, 700
    sc.render.filepath = preview
    bpy.ops.render.render(write_still=True)
    sc.render.engine = 'BLENDER_EEVEE'
bpy.ops.wm.save_as_mainfile(filepath=out)
print("TINT OK")

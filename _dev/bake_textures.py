# Bakes a game-exported tank glb's original per-face textures onto a cleaned .blend's UV layouts.
#   blender -b clean.blend --python bake_textures.py -- <original.glb> <out_dir> <out.blend> <size> <Prefix> [Part ...]
# Textures are baked neutral gray and packed into the .blend (add --color to keep hues).
# Parts default to Body Turret Barrel (pass e.g. Turret.001 if that is what the object is called). Each gets <out_dir>/<Prefix>_<Part>_baked.png and a material using it.
# The original glb is assumed to be a Crafts/Models export (rot +90 Z, x1.5) - that is undone to match the .blend.
import bpy, math, mathutils, sys
args = sys.argv[sys.argv.index("--")+1:]
glb, out_dir, out_blend, size, prefix = args[:5]
parts = args[5:] or ["Body", "Turret", "Barrel"]
size = int(size)
GRAY = "--color" not in args  # pass --color to keep the original hues
parts = [p for p in parts if p != "--color"]

before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=glb)
new = [o for o in bpy.data.objects if o not in before]
sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 1
b = sc.render.bake
b.use_selected_to_active = True; b.cage_extrusion = 0.03; b.max_ray_distance = 0.0
b.margin = 6; b.margin_type = 'EXTEND'
b.use_pass_direct = False; b.use_pass_indirect = False; b.use_pass_color = True

fix = mathutils.Matrix.Scale(1/1.5, 4) @ mathutils.Matrix.Rotation(math.radians(-90), 4, 'Z')
for part_arg in parts:
    # Blender suffixes (Turret.001) are fine on input; outputs and the saved object use the plain name
    part = part_arg.split(".")[0]
    clean = bpy.data.objects[part_arg]
    src = [o for o in new if o.type == 'MESH' and o.name.split(".")[0].lower() == part.lower()][0]
    src.parent = None
    src.data.transform(fix @ src.matrix_world)
    src.matrix_world = mathutils.Matrix.Identity(4)
    bpy.context.view_layer.update()
    img = bpy.data.images.new(f"{prefix}_{part}_baked", size, size, alpha=True)
    mat = bpy.data.materials.new(f"{prefix}_{part}")
    mat.use_nodes = True
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img; tex.interpolation = 'Closest'
    nt.links.new(tex.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
    nt.nodes.active = tex
    clean.data.materials.clear(); clean.data.materials.append(mat)
    for o in (src, clean):
        o.hide_render = False; o.hide_viewport = False; o.hide_set(False)
    bpy.ops.object.select_all(action='DESELECT')
    src.select_set(True); clean.select_set(True)
    bpy.context.view_layer.objects.active = clean
    bpy.ops.object.bake(type='DIFFUSE')
    clean.name = part
    if GRAY:
        # Neutral gray: the game tints per team at spawn, so the baked art carries no hue of its own
        import numpy as np
        px = np.empty(size * size * 4, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(-1, 4)
        lum = px[:, 0] * 0.2126 + px[:, 1] * 0.7152 + px[:, 2] * 0.0722
        px[:, 0] = px[:, 1] = px[:, 2] = lum
        img.pixels.foreach_set(px.reshape(-1))
    img.filepath_raw = f"{out_dir}/{prefix}_{part}_baked.png"; img.file_format = 'PNG'; img.save()
    img.pack()  # the .blend carries its own textures
    src.hide_set(True)
    print("BAKED", part, clean.dimensions, src.dimensions)
for o in new:
    bpy.data.objects.remove(o)
bpy.ops.wm.save_as_mainfile(filepath=out_blend)
print("BAKED OK")

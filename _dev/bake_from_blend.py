# Same bake as bake_textures.py, but the textured original comes from another .blend instead of an exported glb
# (used for the Mag Rider, whose original only survives inside ShowCase.blend).
#   blender -b clean.blend --python bake_from_blend.py -- <source.blend> <out_dir> <out.blend> <size> <Prefix> <CleanObj=SourceObj> [...] [--color]
# The source objects' own transforms (ShowCase parents and offsets) are discarded; only their mesh data and materials are used.
import bpy, sys
args = sys.argv[sys.argv.index("--")+1:]
src_blend, out_dir, out_blend, size, prefix = args[:5]
GRAY = "--color" not in args
pairs = [a.split("=") for a in args[5:] if "=" in a]
size = int(size)
# ShowCase meshes are in the raw Tanarus units, 16x the size of the cleaned .blend models (ShowCase scales its root down)
SRC_SCALE = 1 / 16

with bpy.data.libraries.load(src_blend, link=False) as (data_from, data_to):
    data_to.objects = [src for _, src in pairs]
sc = bpy.context.scene
for o in data_to.objects:
    sc.collection.objects.link(o)
    o.parent = None
    o.matrix_world.identity()
    o.scale = (SRC_SCALE,) * 3
    o.hide_render = False; o.hide_viewport = False
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 1
b = sc.render.bake
b.use_selected_to_active = True; b.cage_extrusion = 0.03; b.max_ray_distance = 0.0
b.margin = 6; b.margin_type = 'EXTEND'
b.use_pass_direct = False; b.use_pass_indirect = False; b.use_pass_color = True

for (clean_name, src_name), src in zip(pairs, data_to.objects):
    clean = bpy.data.objects[clean_name]
    part = clean_name.split(".")[0]
    bpy.context.view_layer.update()
    img = bpy.data.images.new(f"{prefix}_{part}_baked", size, size, alpha=True)
    mat = bpy.data.materials.new(f"{prefix}_{part}")
    mat.use_nodes = True
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img; tex.interpolation = 'Closest'
    nt.links.new(tex.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
    nt.nodes.active = tex
    clean.data.materials.clear(); clean.data.materials.append(mat)
    clean.hide_render = False; clean.hide_viewport = False; clean.hide_set(False)
    bpy.ops.object.select_all(action='DESELECT')
    src.select_set(True); clean.select_set(True)
    bpy.context.view_layer.objects.active = clean
    bpy.ops.object.bake(type='DIFFUSE')
    if GRAY:
        import numpy as np
        px = np.empty(size * size * 4, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(-1, 4)
        lum = px[:, 0] * 0.2126 + px[:, 1] * 0.7152 + px[:, 2] * 0.0722
        px[:, 0] = px[:, 1] = px[:, 2] = lum
        img.pixels.foreach_set(px.reshape(-1))
    img.filepath_raw = f"{out_dir}/{prefix}_{part}_baked.png"; img.file_format = 'PNG'; img.save()
    img.pack()
    src.hide_set(True)
    print("BAKED", part, clean.dimensions, src.dimensions)
for o in data_to.objects:
    bpy.data.objects.remove(o)
bpy.ops.wm.save_as_mainfile(filepath=out_blend)
print("BAKED OK")

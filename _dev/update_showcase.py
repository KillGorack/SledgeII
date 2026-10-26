# Replaces every tank in ShowCase.blend with the cleaned, baked parts from the per-tank .blend files.
#   blender -b ShowCase.blend --python update_showcase.py -- <folder with the tank .blends> <out.blend> [preview.png]
# ShowCase works in raw Tanarus units (root empty scaled down), 16x the clean models, so parts are scaled up on the way in.
import bpy, sys, os, mathutils
args = sys.argv[sys.argv.index("--")+1:]
folder, out = args[0], args[1]
preview = args[2] if len(args) > 2 else None
SCALE = 16.0
TANKS = {  # ShowCase empty -> source file
    "Lightning": "Lightning.blend",
    "Vanguard": "vanguard.blend",
    "Chameleon": "chameleon.blend",
    "Devastator": "devastator.blend",
    "Mag Rider": "MagRider_baked.blend",
}
sc = bpy.context.scene
for tank, fname in TANKS.items():
    empty = bpy.data.objects[tank]
    for old in [o for o in empty.children_recursive if o.type == 'MESH']:
        bpy.data.objects.remove(old)
    path = os.path.join(folder, fname)
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        dst.objects = [n for n in src.objects]
    for o in dst.objects:
        if o.type != 'MESH':
            bpy.data.objects.remove(o); continue
        part = o.name.split(".")[0].capitalize()
        o.name = f"{tank}_{part}"
        sc.collection.objects.link(o)
        # fold in any object scale the source left un-applied (devastator.blend's Barrel had 0.062)
        fold = mathutils.Matrix.Diagonal((*o.scale, 1.0))
        o.data.transform(fold)
        if fold.determinant() < 0:
            o.data.flip_normals()  # mirrored parts (scale -1) would otherwise come out inside-out
        o.parent = empty
        o.location = (0, 0, 0); o.rotation_euler = (0, 0, 0)
        o.scale = (SCALE,) * 3
        for img in {n.image for m in o.data.materials if m and m.node_tree for n in m.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image}:
            if not img.packed_file:
                try: img.pack()
                except Exception: print("WARN could not pack", img.name)
    print("UPDATED", tank, [o.name for o in empty.children])
bpy.ops.outliner.orphans_purge(do_recursive=True)
if preview:
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.light = 'FLAT'; sc.display.shading.color_type = 'TEXTURE'
    sc.render.resolution_x, sc.render.resolution_y = 1400, 700
    sc.render.filepath = preview
    bpy.ops.render.render(write_still=True)
    sc.render.engine = 'BLENDER_EEVEE'
bpy.ops.wm.save_as_mainfile(filepath=out)
print("SHOWCASE OK")

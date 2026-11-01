# blender -b <tree>.blend --python _dev/export_tree_glb.py -- <out.glb> <height_in_metres>
# Exports a tree for Creative levels: meshes only, uniformly scaled so the whole tree is the given height,
# with the trunk's base on the origin (Godot y = 0 is the ground the tree stands on) and centred on the trunk.
# Scale is baked into the mesh data, as export_craft_glb.py does, so the Godot scene needs no scale of its own.
import bpy, sys, mathutils
out = sys.argv[sys.argv.index("--") + 1]
height = float(sys.argv[sys.argv.index("--") + 2])
TEXTURE_MAX = 512   # the game's trees don't need the 2K wood texture
for o in list(bpy.data.objects):
    if o.type != 'MESH':
        bpy.data.objects.remove(o)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
points = [o.matrix_world @ v.co for o in meshes for v in o.data.vertices]
low = mathutils.Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
high = mathutils.Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
factor = height / (high.z - low.z)
# centre on the trunk if there is one (a lopsided canopy shouldn't shift the base), else the whole tree
trunk = next((o for o in meshes if o.name.lower().startswith("trunk")), None)
if trunk:
    tp = [trunk.matrix_world @ v.co for v in trunk.data.vertices]
    centre = mathutils.Vector(((min(p.x for p in tp) + max(p.x for p in tp)) / 2, (min(p.y for p in tp) + max(p.y for p in tp)) / 2, 0))
else:
    centre = mathutils.Vector(((low.x + high.x) / 2, (low.y + high.y) / 2, 0))
matrix = mathutils.Matrix.Diagonal((factor, factor, factor, 1.0)) @ mathutils.Matrix.Translation((-centre.x, -centre.y, -low.z))
for o in meshes:
    o.data.transform(matrix @ o.matrix_world)
    o.matrix_world = mathutils.Matrix.Identity(4)
    o.name = o.name.split(".")[0].capitalize()
for image in bpy.data.images:
    if max(image.size) > TEXTURE_MAX:
        image.scale(TEXTURE_MAX, TEXTURE_MAX)
    image.pack()
bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_yup=True, export_apply=False, export_cameras=False, export_lights=False)
print("TREE", out, "scale factor %.3f" % factor, "width %.2f x %.2f" % ((high.x - low.x) * factor, (high.y - low.y) * factor))

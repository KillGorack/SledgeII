import bpy, sys
SCALE=1.5
out=sys.argv[sys.argv.index("--")+1]
for o in list(bpy.data.objects):
    if o.type not in ('MESH',): bpy.data.objects.remove(o)
bpy.ops.object.select_all(action='DESELECT')
for o in bpy.data.objects:
    o.select_set(True)
bpy.context.view_layer.objects.active=bpy.data.objects[0]
import math, mathutils
for o in bpy.data.objects: o.name = o.name.split(".")[0].capitalize()
# bake uniform scale (about origin) and a +90deg Z spin into the mesh data: Blender +X is the nose,
# Godot's craft faces -Z (= Blender +Y after the y-up export). Object scale (Devastator has 0.06) is folded in too.
for o in bpy.data.objects:
    m = mathutils.Matrix.Rotation(math.radians(90),4,'Z') @ mathutils.Matrix.Diagonal((o.scale.x*SCALE,o.scale.y*SCALE,o.scale.z*SCALE,1.0))
    o.data.transform(m)
    if m.determinant() < 0:
        o.data.flip_normals()  # mirrored parts (scale -1) would otherwise come out inside-out
    o.scale=(1,1,1); o.rotation_euler=(0,0,0)
# ensure nearest filtering
for m in bpy.data.materials:
    if m.use_nodes:
        for n in m.node_tree.nodes:
            if n.type=='TEX_IMAGE': n.interpolation='Closest'
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_yup=True, export_apply=False, export_cameras=False, export_lights=False)

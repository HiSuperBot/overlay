"""Build the two face-only CC0 avatars in an isolated Blender background process."""
from pathlib import Path
import json
import os
import math
import sys
import subprocess
import bpy
import numpy as np
from mathutils import Vector, Matrix, geometry
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[3]
ASSETS = ROOT / 'assets/avatars'
CACHE = ASSETS / '.cache'
OUTPUT = ROOT / 'apps/ios/Overlay/Resources/Avatars'
SOURCE = ASSETS / 'source'
SOURCE.mkdir(exist_ok=True)
OUTPUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(CACHE / 'mpfb2-2.0.18/src'))
# Adapt the extension's path provider only inside this disposable Python process.
bpy.utils.extension_path_user = lambda package, **kwargs: str(CACHE / 'runtime')
import mpfb
mpfb.get_preference = lambda name: {
    'mpfb_second_root': str(CACHE / 'system'),
    'mpfb_user_data': str(CACHE / 'runtime'),
    'mh_user_data': '',
}.get(name, False)
mpfb.register()
from mpfb.services import HumanService, TargetService, FaceService, ExportService

ROTATE = Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0)))


def activate(obj):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def group_center(obj, name):
    index = obj.vertex_groups[name].index
    points = [v.co for v in obj.data.vertices if any(g.group == index for g in v.groups)]
    return sum(points, Vector()) / len(points)


def crop(obj, keep):
    activate(obj)
    for v in obj.data.vertices:
        v.select = not keep(v)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.delete(type='VERT')
    bpy.ops.object.mode_set(mode='OBJECT')


def image_copy(path, name, work):
    image = bpy.data.images.load(str(path), check_existing=True)
    if max(image.size) > 2048:
        ratio = 2048 / max(image.size)
        image.scale(round(image.size[0] * ratio), round(image.size[1] * ratio))
    image.filepath_raw = str(work / f'{name}.png')
    image.file_format = 'PNG'
    image.save()
    return image


def texture_material(name, path, work, roughness=0.5, alpha=False, skin=False):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = nodes.get('Principled BSDF')
    bsdf.inputs['Roughness'].default_value = roughness
    bsdf.inputs['Metallic'].default_value = 0
    image = image_copy(path, name + '_color', work)
    tex = nodes.new('ShaderNodeTexImage'); tex.image = image
    links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    if alpha:
        links.new(tex.outputs['Alpha'], bsdf.inputs['Alpha'])
        material.surface_render_method = 'DITHERED'
    if skin:
        # Core skins supply albedo only. These subtle pore normals/roughness are authored derivatives,
        # not scanned or measured maps. The texture budget includes all three channels.
        w, h = image.size
        rng = np.random.default_rng(1849)
        noise = rng.normal(0, 0.013, (h, w)).astype(np.float32)
        nx = (noise - np.roll(noise, 1, axis=1)) * 0.25
        ny = (noise - np.roll(noise, 1, axis=0)) * 0.25
        normal = np.stack((nx + 0.5, ny + 0.5, np.ones_like(noise), np.ones_like(noise)), axis=-1)
        rough = np.clip(roughness + noise, 0.35, 0.65)
        maps = [('normal', normal), ('roughness', np.stack((rough, rough, rough, np.ones_like(rough)), axis=-1))]
        for channel, pixels in maps:
            generated = bpy.data.images.new(f'{name}_{channel}', width=w, height=h, alpha=True)
            generated.colorspace_settings.name = 'Non-Color'
            generated.pixels.foreach_set(pixels.ravel())
            generated.filepath_raw = str(work / f'{name}_{channel}.png')
            generated.file_format = 'PNG'; generated.save()
            node = nodes.new('ShaderNodeTexImage'); node.image = generated
            if channel == 'normal':
                normal_node = nodes.new('ShaderNodeNormalMap')
                links.new(node.outputs['Color'], normal_node.inputs['Color'])
                links.new(normal_node.outputs['Normal'], bsdf.inputs['Normal'])
            else: links.new(node.outputs['Color'], bsdf.inputs['Roughness'])
    return material


def set_material(obj, material):
    obj.data.materials.clear(); obj.data.materials.append(material)
    for p in obj.data.polygons: p.use_smooth = True


def transformed(obj, origin):
    coords = [v.co.copy() for v in obj.data.vertices]
    keys = [(key, [v.co.copy() for v in key.data]) for key in obj.data.shape_keys.key_blocks] if obj.data.shape_keys else []
    for key, original in keys:
        for v, co in zip(key.data, original): v.co = ROTATE @ (co - origin)
    for v, co in zip(obj.data.vertices, coords): v.co = ROTATE @ (co - origin)
    obj.parent = None
    obj.matrix_world = Matrix.Identity(4)
    for m in list(obj.modifiers): obj.modifiers.remove(m)
    for g in list(obj.vertex_groups): obj.vertex_groups.remove(g)



def reduce_surface(obj, ratio):
    # Transfer all deltas through a fixed neutral-surface correspondence after decimation.
    # Every expression consequently shares the exact exported topology.
    obj.data.calc_loop_triangles()
    triangles = [tuple(t.vertices) for t in obj.data.loop_triangles]
    basis = [v.co.copy() for v in obj.data.vertices]
    shapes = [(key.name, [v.co.copy() for v in key.data]) for key in obj.data.shape_keys.key_blocks if key.name != 'Basis']
    tree = BVHTree.FromPolygons(basis, triangles, all_triangles=True)
    reduced = obj.copy(); reduced.data = obj.data.copy()
    bpy.context.collection.objects.link(reduced)
    reduced.shape_key_clear()
    activate(reduced)
    modifier = reduced.modifiers.new('Mobile surface budget', 'DECIMATE'); modifier.ratio = ratio
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    correspondences = []
    for vertex in reduced.data.vertices:
        position, _, index, _ = tree.find_nearest(vertex.co)
        a, b, c = triangles[index]
        weights = geometry.barycentric_transform(position, basis[a], basis[b], basis[c],
            Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1)))
        if not all(math.isfinite(w) and -0.001 <= w <= 1.001 for w in weights):
            nearest = min(range(3), key=lambda i: (basis[(a,b,c)[i]] - position).length_squared)
            weights = Vector(tuple(1.0 if i == nearest else 0.0 for i in range(3)))
        else:
            weights = Vector(tuple(max(0, min(1, w)) for w in weights))
            weights /= sum(weights)
        correspondences.append(((a, b, c), weights))
    reduced.shape_key_add(name='Basis')
    for name, coordinates in shapes:
        key = reduced.shape_key_add(name=name, from_mix=False); key.value = 0
        for vertex, (indices, weights) in zip(key.data, correspondences):
            vertex.co += sum(((coordinates[i] - basis[i]) * w for i, w in zip(indices, weights)), Vector())
    bpy.data.objects.remove(obj, do_unlink=True)
    return reduced


def build(identifier, label, gender, race, skin_name, eye_color):
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
    bpy.data.orphans_purge(do_recursive=True)
    work = CACHE / identifier; work.mkdir(exist_ok=True)
    macro = TargetService.get_default_macro_info_dict()
    macro.update(gender=gender, age=0.45, race=race)
    human = HumanService.create_human(feet_on_ground=False, macro_detail_dict=macro)
    TargetService.bake_targets(human)
    left = group_center(human, 'joint-l-eye')
    right = group_center(human, 'joint-r-eye')
    origin = (left + right) / 2
    parts = {}
    entries = [
        ('Eyes', 'eyes/high-poly/high-poly.mhclo'),
        ('Eyebrows', 'eyebrows/eyebrow001/eyebrow001.mhclo'),
        ('Eyelashes', 'eyelashes/eyelashes01/eyelashes01.mhclo'),
        ('Teeth', 'teeth/teeth_base/teeth_base.mhclo'),
        ('Tongue', 'tongue/tongue01/tongue01.mhclo'),
    ]
    for kind, path in entries:
        parts[kind] = HumanService.add_mhclo_asset(str(CACHE / 'system' / path), human,
            asset_type=kind, subdiv_levels=0, set_up_rigging=False)
    targets = sorted((CACHE / 'expressions/targets/faceunits').glob('*.target'))
    for target in targets: TargetService.load_target(human, str(target), name=target.stem)
    FaceService.interpolate_targets(human)
    body_group = human.vertex_groups['body'].index
    crop(human, lambda v: v.co.z > origin.z - 0.12 and v.co.z < origin.z + 0.125 and v.co.y < origin.y + 0.06 and any(g.group == body_group for g in v.groups))
    for m in list(human.modifiers): human.modifiers.remove(m)
    subdiv = human.modifiers.new('Surface refinement', 'SUBSURF'); subdiv.levels = subdiv.render_levels = 1
    ExportService.bake_modifiers_remove_helpers(human, bake_subdiv=True, remove_helpers=False, also_proxy=False)
    human = reduce_surface(human, 0.72)
    human.name = 'FaceSkin'
    skin_path = next((CACHE / 'system/skins' / skin_name).glob('*diffuse*.png'))
    set_material(human, texture_material('Skin', skin_path, work, skin=True))
    set_material(parts['Eyebrows'], texture_material('Brows', CACHE / 'system/eyebrows/eyebrow001/eyebrow001.png', work, alpha=True))
    set_material(parts['Eyelashes'], texture_material('Lashes', CACHE / 'system/eyelashes/eyelashes01/eyelashes01.png', work, alpha=True))
    set_material(parts['Teeth'], texture_material('Teeth', CACHE / 'system/teeth/teeth_base/teeth.png', work, roughness=0.28))
    set_material(parts['Tongue'], texture_material('Mouth', CACHE / 'system/tongue/tongue01/tongue01_diffuse.png', work, roughness=0.4))
    eyes = parts.pop('Eyes')
    eyes.shape_key_clear()
    set_material(eyes, texture_material('Eyes', CACHE / f'system/eyes/materials/{eye_color}_eye.png', work, roughness=0.12))
    for name, positive in [('LeftEye', True), ('RightEye', False)]:
        obj = eyes.copy(); obj.data = eyes.data.copy(); bpy.context.collection.objects.link(obj)
        obj.name = name
        crop(obj, lambda v: (v.co.x >= 0) == positive)
        parts[name] = obj
    bpy.data.objects.remove(eyes, do_unlink=True)
    for name, obj in parts.items(): obj.name = name
    # A closed, dark oral cavity prevents the camera's real mouth showing through the lip opening.
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, location=(0, 0, 0))
    cavity = bpy.context.object; cavity.name = 'OralCavity'
    for v in cavity.data.vertices:
        v.co = Vector((v.co.x * 0.038, v.co.y * 0.018 + origin.y + 0.018, v.co.z * 0.024 + origin.z - 0.055))
    cavity.shape_key_add(name='Basis')
    jaw = cavity.shape_key_add(name='jawOpen', from_mix=False); jaw.value = 0
    for v in jaw.data:
        v.co.z -= 0.025 * max(0, min(1, (origin.z - 0.035 - v.co.z) / 0.04))
    material = bpy.data.materials.new('OralCavity'); material.use_nodes = True
    material.node_tree.nodes.get('Principled BSDF').inputs['Base Color'].default_value = (0.045, 0.008, 0.012, 1)
    material.node_tree.nodes.get('Principled BSDF').inputs['Roughness'].default_value = 0.75
    set_material(cavity, material)
    parts['OralCavity'] = cavity
    objects = [human] + list(parts.values())
    for obj in objects:
        if obj.data.shape_keys:
            for key in obj.data.shape_keys.key_blocks: key.value = 0
        transformed(obj, origin)
        if obj.data.shape_keys:
            basis = obj.data.shape_keys.key_blocks['Basis']
            for key in obj.data.shape_keys.key_blocks:
                for v, base in zip(key.data, basis.data):
                    if not all(math.isfinite(c) for c in v.co) or (v.co - base.co).length > 0.12:
                        raise RuntimeError(f'Invalid expression delta: {obj.name}/{key.name}')
    left = ROTATE @ (left - origin); right = ROTATE @ (right - origin)
    # Put each eyeball's pivot at its anatomical center so its separate gaze rotation is local.
    for name, center in [('LeftEye', left), ('RightEye', right)]:
        obj = parts[name]
        for v in obj.data.vertices: v.co -= center
        obj.location = center
    face_vertices = [v.co for v in human.data.vertices if -0.11 < v.co.y < 0.075 and v.co.z > -0.035]
    fitting = dict(leftEye=list(left), rightEye=list(right),
                   faceWidth=max(v.x for v in face_vertices) - min(v.x for v in face_vertices),
                   faceHeight=0.075 - min(v.co.y for v in human.data.vertices))
    triangles = sum(sum(len(p.vertices) - 2 for p in obj.data.polygons) for obj in objects)
    print('TRIANGLES', [(o.name, sum(len(p.vertices)-2 for p in o.data.polygons)) for o in objects], flush=True)
    if triangles > 30000: raise RuntimeError(f'{identifier}: {triangles} triangles exceeds budget')
    bpy.context.scene.unit_settings.system = 'METRIC'; bpy.context.scene.unit_settings.scale_length = 1
    for obj in objects: obj.select_set(True)
    bpy.context.view_layer.objects.active = human
    bpy.ops.wm.usd_export(filepath=str(work / 'avatar.usda'), selected_objects_only=True,
        export_shapekeys=True, export_armatures=True, export_animation=False,
        export_materials=True, export_textures_mode='NEW', generate_preview_surface=True,
        relative_paths=True, triangulate_meshes=True, convert_orientation=False,
        convert_scene_units='METERS', meters_per_unit=1.0, export_subdivision='IGNORE',
        export_cameras=False, export_lights=False, root_prim_path='/Avatar')
    usd = work / 'avatar.usda'
    text = usd.read_text().replace('upAxis = "Z"', 'upAxis = "Y"')
    usd.write_text(text)
    subprocess.run(['/usr/bin/usdcat', str(usd), '-o', str(work / 'avatar.usdc')], check=True)
    subprocess.run(['/usr/bin/usdzip', '--asset', str(work / 'avatar.usdc'), str(OUTPUT / f'{identifier}.usdz')], check=True)
    # Pack all maps in the editable source, independent of the download cache.
    for image in bpy.data.images:
        if image.source == 'FILE' and image.filepath: image.pack()
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / f'{label.replace(" ", "")}.blend'), compress=True)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'; scene.cycles.samples = 12
    scene.cycles.use_denoising = True
    scene.render.resolution_x = scene.render.resolution_y = 256
    scene.render.resolution_percentage = 100
    scene.world.color = (0.18, 0.18, 0.18)
    bpy.ops.object.camera_add(location=(0, 0.005, 0.65))
    camera = bpy.context.object
    forward = camera.location.normalized()
    right = Vector((0, 1, 0)).cross(forward).normalized()
    up = forward.cross(right)
    camera.rotation_euler = Matrix((right, up, forward)).transposed().to_euler()
    camera.data.type = 'ORTHO'; camera.data.ortho_scale = 0.31; scene.camera = camera
    for location, power, size in [((-0.2, 0.2, 0.35), 4, 0.3), ((0.2, 0.05, 0.2), 2, 0.2)]:
        bpy.ops.object.light_add(type='AREA', location=location)
        light = bpy.context.object; light.data.energy = power; light.data.shape = 'DISK'; light.data.size = size
        light.rotation_euler = (-light.location).to_track_quat('-Z', 'Y').to_euler()
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = str(OUTPUT / f'{identifier}.png')
    bpy.ops.render.render(write_still=True)
    expression_map = {t.stem: dict(source=t.stem, gain=1.08 if t.stem.startswith('eyeBlink') else 1.04 if t.stem=='jawOpen' else 1) for t in targets}
    report = dict(id=identifier, triangles=triangles, expressionNames=[t.stem for t in targets], fitting=fitting)
    (SOURCE / f'{identifier}.json').write_text(json.dumps(report, indent=2) + '\n')
    print('AVATAR_READY', json.dumps(report), flush=True)
    return dict(id=identifier, name=label, file=f'{identifier}.usdz', thumbnail=f'{identifier}.png',
                expressions=expression_map, fitting=fitting, leftEyeEntity='LeftEye', rightEyeEntity='RightEye')

catalog = [
    build('human-a', 'Human A', 0.9, dict(asian=0.8, caucasian=0.15, african=0.05), 'young_asian_male', 'brown'),
    build('human-b', 'Human B', 0.1, dict(asian=0.1, caucasian=0.75, african=0.15), 'young_caucasian_female', 'green'),
]
(OUTPUT / 'catalog.json').write_text(json.dumps(catalog, indent=2) + '\n')

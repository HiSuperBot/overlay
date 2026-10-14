"""Validate shipped USDZ data without launching an iOS app or a Blender scene."""
from pathlib import Path
import json
import math
import re
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
AVATARS = ROOT / 'apps/ios/Overlay/Resources/Avatars'
SOURCE = ROOT / 'assets/avatars/source'


def vectors(text):
    return [tuple(float(x) for x in match.split(',')) for match in re.findall(r'\(([^()]+)\)', text)]


def mesh_blocks(text):
    for match in re.finditer(r'def Mesh "[^"]+"\s*(?:\([^)]*\)\s*)?\{', text):
        start = match.end(); level = 1; end = start
        while level and end < len(text):
            if text[end] == '{': level += 1
            elif text[end] == '}': level -= 1
            end += 1
        assert not level, 'Malformed mesh block'
        yield text[start:end - 1]


catalog = json.loads((AVATARS / 'catalog.json').read_text())
assert {a['id'] for a in catalog} == {'human-a', 'human-b'}
for avatar in catalog:
    filename = AVATARS / avatar['file']
    report = json.loads((SOURCE / (avatar['id'] + '.json')).read_text())
    assert (AVATARS / avatar['thumbnail']).is_file()
    with zipfile.ZipFile(filename) as package:
        assert package.infolist()[0].filename.endswith(('.usdc', '.usda'))
        for member in package.infolist():
            assert member.compress_type == zipfile.ZIP_STORED, 'USDZ entries must be uncompressed'
            assert not Path(member.filename).is_absolute() and '..' not in Path(member.filename).parts
            if member.filename.endswith('.png'):
                png = package.read(member)
                assert png[:8] == b'\x89PNG\r\n\x1a\n'
                width, height = struct.unpack('>II', png[16:24])
                assert 0 < width <= 2048 and 0 < height <= 2048, member.filename
        with filename.open('rb') as file:
            for member in package.infolist():
                file.seek(member.header_offset + 26)
                name_length, extra_length = struct.unpack('<HH', file.read(4))
                assert (member.header_offset + 30 + name_length + extra_length) % 64 == 0
    result = subprocess.run(['/usr/bin/usdchecker', str(filename)], capture_output=True, text=True, check=True)
    assert 'Success!' in result.stdout, result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='overlay-usd-') as temporary:
        output = Path(temporary) / 'avatar.usda'
        subprocess.run(['/usr/bin/usdcat', str(filename), '-o', str(output)], check=True)
        text = output.read_text()
    assert re.search(r'metersPerUnit = 1\b', text) and 'upAxis = "Y"' in text
    for eye in (avatar['leftEyeEntity'], avatar['rightEyeEntity']):
        assert re.search(r'def Xform "' + re.escape(eye) + '"', text), 'Missing eye pivot'
    triangles = 0
    complete_face = None
    for block in mesh_blocks(text):
        counts = re.search(r'int\[\] faceVertexCounts = \[([^]]+)\]', block)
        triangles += sum(int(x.strip()) - 2 for x in counts[1].split(','))
        points = re.search(r'point3f\[\] points = \[([^]]+)\]', block)
        coords = vectors(points[1])
        assert all(len(v) == 3 and all(math.isfinite(x) and abs(x) < 0.5 for x in v) for v in coords)
        names = re.search(r'uniform token\[\] skel:blendShapes = \[([^]]+)\]', block)
        if names and set(re.findall('"([^"]+)"', names[1])) == set(avatar['expressions']):
            complete_face = coords
    assert complete_face and 0 < triangles <= 30000
    assert triangles == report['triangles'], (triangles, report['triangles'])
    assert min(v[1] for v in complete_face) < -0.05 and max(v[1] for v in complete_face) > 0.05
    assert max(v[2] for v in complete_face) > 0.02, '+Z must face the viewer'
    assert len(avatar['expressions']) == 52 and set(avatar['expressions']) == set(report['expressionNames'])
    for binding in avatar['expressions'].values():
        assert binding['source'] in avatar['expressions'] and 0.5 <= binding['gain'] <= 1.5
    for match in re.finditer(r'float\[\] blendShapeWeights = \[([^]]+)\]', text):
        assert all(float(x.strip()) == 0 for x in match[1].split(',')), 'Non-neutral default pose'
    for match in re.finditer(r'vector3f\[\] offsets = \[([^]]+)\]', text):
        for delta in vectors(match[1]):
            assert all(math.isfinite(x) for x in delta) and sum(x*x for x in delta) <= 0.12**2
    assert 'inputs:normal.connect' in text and 'inputs:roughness.connect' in text
    for path in re.findall(r'asset inputs:file = @([^@]+)@', text):
        assert path.removeprefix('./') in package.namelist(), 'Missing texture dependency'
    fitting = avatar['fitting']
    assert fitting == report['fitting']
    assert 0.035 < math.dist(fitting['leftEye'], fitting['rightEye']) < 0.09
    print(f"PASS: {avatar['name']}: {triangles:,} triangles, 52 expressions, meters/+Y/+Z, textures <=2K")

"""Fetch and verify the pinned inputs; leave downloaded tools and archives out of Git."""
from pathlib import Path
import hashlib
import json
import tarfile
import urllib.request
import zipfile

ASSETS = Path(__file__).resolve().parents[1]
CACHE = ASSETS / '.cache'
CACHE.mkdir(exist_ok=True)
for source in json.loads((ASSETS / 'sources.json').read_text()):
    archive = CACHE / source['file']
    if not archive.exists():
        temporary = archive.with_suffix(archive.suffix + '.download')
        print('Downloading ' + source['file'], flush=True)
        urllib.request.urlretrieve(source['url'], temporary)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != source['sha256']:
        raise RuntimeError('Source digest mismatch: ' + archive.name)
    if archive.suffix == '.zip':
        destination = CACHE / ('system' if archive.name == 'system.zip' else 'expressions')
        with zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                if Path(name).is_absolute() or '..' in Path(name).parts: raise RuntimeError(name)
            package.extractall(destination)
    else:
        with tarfile.open(archive) as package:
            for item in package:
                if Path(item.name).is_absolute() or '..' in Path(item.name).parts or item.issym() or item.islnk():
                    raise RuntimeError(item.name)
                package.extract(item, CACHE)
    print('Verified ' + archive.name)

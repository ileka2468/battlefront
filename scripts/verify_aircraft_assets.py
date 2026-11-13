"""Verify bundled aircraft models against the viewer manifest and retained credits."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import struct


ROOT = Path(__file__).resolve().parents[1]
KNOWN_F117 = 'f3ba4b1e0d6cbb2d33cae2bbd950a5fb77822a2beee2d3b071ab9053174bf859'


def glb(data):
    magic, version, length, json_length, json_type = struct.unpack_from('<4s4I', data)
    assert (magic, version, length, json_type) == (b'glTF', 2, len(data), 0x4E4F534A)
    info = json.loads(data[20:20 + json_length])
    bin_length, bin_type = struct.unpack_from('<2I', data, 20 + json_length)
    assert bin_type == 0x004E4942 and 28 + json_length + bin_length == len(data)
    assert info['asset']['version'] == '2.0' and info['meshes']
    assert all('uri' not in b for b in info.get('buffers', [])), 'Model fetches an external buffer'
    assert all(i.get('uri', 'data:').startswith('data:') for i in info.get('images', [])), 'Remote image prerequisite'
    for view in info.get('bufferViews', []):
        assert view['buffer'] == 0 and view.get('byteOffset', 0) + view['byteLength'] <= bin_length
    return info


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--ledger', type=Path, default=ROOT / 'web/models/vendor')
    cli.add_argument('--asset-dir', type=Path, default=ROOT / 'web/models/vendor')
    cli.add_argument('--expect-original', action='store_true')
    args = cli.parse_args()
    manifest = json.loads((args.ledger / 'manifest.json').read_text(encoding='utf-8'))
    credits = (args.ledger / 'credits.html').read_text(encoding='utf-8')
    for family, entry in manifest.items():
        match = re.fullmatch(r'/models/vendor/([a-z0-9-]+\.glb)', entry['file'])
        assert match, (family, entry['file'])
        glb((args.asset_dir / match[1]).read_bytes())

    if args.expect_original:
        assert 'F-117' not in manifest and 'karelkiers' not in credits
        print(f'BASELINE: {len(manifest)} validated models; F-117 absent from manifest and credits')
    else:
        row = manifest['F-117']
        data = (args.asset_dir / 'f-117.glb').read_bytes()
        info = glb(data)
        metadata = info['asset']['extras']
        assert metadata['source'] == row['source'] and metadata['author'].startswith(row['author'] + ' ')
        assert row['license'] == 'CC-BY-4.0' and row['licenseUrl'] in credits
        assert row['source'] in credits and row['authorUrl'] in credits
        assert sha256(data).hexdigest() == KNOWN_F117
        triangles = sum(info['accessors'][p['indices']]['count'] // 3 for m in info['meshes'] for p in m['primitives'])
        assert triangles == row['triangles'] == 1_376 and len(info['images']) == 6 and row['turn'] == -90
        profiles = (ROOT / 'web/airframes.js').read_text(encoding='utf-8').split('const profiles = {', 1)[1].split('const names =', 1)[0]
        gaps = sorted(set(re.findall(r'^\s+"([^"]+)":', profiles, re.M)).difference(manifest))
        # A project-owned original may replace the representative J-20. Never
        # mistake the separately supplied game extraction for that GLB.
        if 'J-20' in manifest:
            j20 = manifest['J-20']
            assert j20['author'] == 'Battlefront project' and j20['file'].endswith('/j-20-battlefront.glb')
        assert 'Su-34' not in manifest
        print(f'MODIFIED: {len(manifest)} validated models; F-117 byte-identical, 1376 triangles, 6 embedded images, attributed CC BY 4.0')
        print('Representative geometry remains for: ' + ', '.join(gaps))


if __name__ == '__main__':
    main()

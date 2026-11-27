#!/usr/bin/env python3
"""Write mods/state.toml for a web build.

usage: mod_state.py <build/web-name/mods> <disc data-track sha256>

Turns off, among default-on features:
  - diagnostics recording and widescreen (no log sink, 4:3 canvas);
  - every feature of a package whose targets name a disc_sha256 this disc
    does not have (the runtime refuses to start with such a package enabled).
"""
import pathlib
import sys
import tomllib


def main(mods_dir, disc_sha):
    off, skipped = [], []
    for manifest in sorted(pathlib.Path(mods_dir, 'bundled').glob('*/*/manifest.toml')):
        m = tomllib.loads(manifest.read_text())
        pid = m.get('id', manifest.parent.parent.name)
        shas = [t['disc_sha256'].lower() for t in m.get('target', []) if t.get('disc_sha256')]
        mismatch = bool(shas) and disc_sha.lower() not in shas
        for feat in m.get('feature', []):
            if not feat.get('default_enabled'):
                continue
            fid = feat['id']
            if mismatch or pid.endswith('.diagnostics') or fid == 'widescreen':
                off.append((pid, fid))
        if mismatch:
            skipped.append(pid)
    lines = ['format_version = 2', '']
    for pid, fid in off:
        lines += ['[[feature]]', f'package_id = "{pid}"', f'id = "{fid}"', 'enabled = false', '']
    pathlib.Path(mods_dir, 'state.toml').write_text('\n'.join(lines))
    if skipped:
        print('   disc differs from the reference dump; mods off: ' + ', '.join(skipped))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

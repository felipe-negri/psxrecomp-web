#!/usr/bin/env python3
"""Split a single-file multi-track cue into one file per track (Redump layout).

usage: split_cue.py <dir containing game.cue>

chdman writes every track into one .bin; game projects verify the data track
alone (Redump hashes "Track 1"), so each track gets its own file, cut at the
next track's INDEX 00 (pregap stays with the track it precedes).
Single-track or already split cues are left alone.
"""
import os
import re
import sys

SECTOR = 2352


def msf(text):
    m, s, f = (int(x) for x in text.split(':'))
    return (m * 60 + s) * 75 + f


def fmt(lba):
    return f'{lba // 4500:02d}:{lba // 75 % 60:02d}:{lba % 75:02d}'


def main(folder):
    cue_path = os.path.join(folder, 'game.cue')
    lines = open(cue_path).read().splitlines()
    files = [l for l in lines if l.strip().startswith('FILE')]
    tracks = []
    for line in lines:
        s = line.strip()
        if s.startswith('TRACK'):
            _, num, mode = s.split()
            tracks.append({'num': int(num), 'mode': mode, 'index': {}})
        elif s.startswith('INDEX') and tracks:
            _, idx, pos = s.split()
            tracks[-1]['index'][int(idx)] = msf(pos)
    if len(files) != 1 or len(tracks) < 2:
        return
    src = os.path.join(folder, re.search(r'"(.+)"', files[0]).group(1))
    total = os.path.getsize(src) // SECTOR
    starts = [t['index'].get(0, t['index'][1]) for t in tracks]
    out = []
    with open(src, 'rb') as f:
        for i, t in enumerate(tracks):
            begin, end = starts[i], starts[i + 1] if i + 1 < len(tracks) else total
            name = f'game (Track {t["num"]}).bin'
            f.seek(begin * SECTOR)
            with open(os.path.join(folder, name), 'wb') as o:
                left = (end - begin) * SECTOR
                while left:
                    chunk = f.read(min(left, 1 << 24))
                    o.write(chunk)
                    left -= len(chunk)
            out += [f'FILE "{name}" BINARY', f'  TRACK {t["num"]:02d} {t["mode"]}']
            for idx, pos in sorted(t['index'].items()):
                out.append(f'    INDEX {idx:02d} {fmt(pos - begin)}')
    os.remove(src)
    open(cue_path, 'w').write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main(sys.argv[1])

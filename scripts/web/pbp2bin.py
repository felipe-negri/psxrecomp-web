#!/usr/bin/env python3
"""Unpack an unencrypted PS1 EBOOT.PBP (POPS) into a raw 2352-byte .bin + .cue.

usage: pbp2bin.py <game.pbp> <out.bin> [disc number, default 1]

Only the first (data) track is written; PBPs keep CD audio tracks as ATRAC3,
which psxrecomp's title projects do not use. PSN images with DRM are refused.
"""
import struct
import sys
import zlib

BLOCK = 16 * 2352


def bcd(v):
    return (v >> 4) * 10 + (v & 15)


def main(src, out, disc=1):
    with open(src, 'rb') as f:
        data = f.read()
    assert data[:4] == b'\0PBP', 'not a PBP file'
    psar = struct.unpack_from('<8I', data, 8)[7]
    if data[psar:psar + 10] == b'PSTITLEIMG':
        starts = [o for o in struct.unpack_from('<5I', data, psar + 0x200) if o]
        assert disc <= len(starts), f'PBP has {len(starts)} disc(s)'
        img = psar + starts[disc - 1]
    else:
        assert disc == 1, 'single-disc PBP'
        img = psar
    assert data[img:img + 12] == b'PSISOIMG0000', 'unsupported or encrypted PBP'

    # TOC (Q-subchannel style, 10-byte entries): point 0xA2 holds the lead-out.
    sectors = None
    for i in range(0x800, 0x800 + 10 * 102, 10):
        e = data[img + i:img + i + 10]
        if e[2] == 0xA2:
            sectors = (bcd(e[7]) * 60 + bcd(e[8])) * 75 + bcd(e[9]) - 150
            break
    assert sectors, 'no lead-out in TOC'

    base = img + 0x100000
    written = 0
    with open(out, 'wb') as o:
        for i in range(img + 0x4000, img + 0x100000, 32):
            off, length = struct.unpack_from('<IH', data, i)
            if length == 0 or written >= sectors * 2352:
                break
            raw = data[base + off:base + off + length]
            block = raw if length == BLOCK else zlib.decompress(raw, -15)
            take = min(len(block), sectors * 2352 - written)
            o.write(block[:take])
            written += take
    assert written == sectors * 2352, f'short image: {written} of {sectors * 2352} bytes'
    name = out.rsplit('/', 1)[-1]
    with open(out.rsplit('.', 1)[0] + '.cue', 'w') as c:
        c.write(f'FILE "{name}" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1)

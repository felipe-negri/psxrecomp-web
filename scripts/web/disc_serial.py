#!/usr/bin/env python3
"""Print a PS1 disc's serial (SCUS-94423) from SYSTEM.CNF. usage: disc_serial.py <track1.bin>"""
import re
import sys


def main(path):
    with open(path, 'rb') as f:
        head = f.read(16 * 2352 + 2352)
        raw = head[0:12] == b'\x00' + b'\xff' * 10 + b'\x00'
        size, off = (2352, 24) if raw else (2048, 0)

        def sector(lba):
            f.seek(lba * size + off)
            return f.read(2048)

        pvd = sector(16)
        assert pvd[1:6] == b'CD001', 'no ISO9660 volume descriptor'
        root_lba = int.from_bytes(pvd[156 + 2:156 + 6], 'little')
        root_len = int.from_bytes(pvd[156 + 10:156 + 14], 'little')
        data = b''.join(sector(root_lba + i) for i in range((root_len + 2047) // 2048))
        i = 0
        while i < len(data):
            n = data[i]
            if n == 0:
                i = (i // 2048 + 1) * 2048
                continue
            name = data[i + 33:i + 33 + data[i + 32]].decode('ascii', 'replace')
            if name.upper().startswith('SYSTEM.CNF'):
                lba = int.from_bytes(data[i + 2:i + 6], 'little')
                text = sector(lba).decode('ascii', 'replace')
                m = re.search(r'BOOT\s*=\s*cdrom:\\?([A-Z]{4})_(\d{3})\.(\d{2})', text, re.I)
                assert m, 'no BOOT line in SYSTEM.CNF'
                print(f'{m.group(1).upper()}-{m.group(2)}{m.group(3)}')
                return
            i += n
        raise SystemExit('SYSTEM.CNF not found')


if __name__ == '__main__':
    main(sys.argv[1])

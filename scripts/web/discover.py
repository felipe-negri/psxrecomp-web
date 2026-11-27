#!/usr/bin/env python3
"""Headless discovery run for a generic (auto-scaffolded) PS1 project.

usage: discover.py <runtime exe> <game.toml> <disc.cue> <work dir> <port> <seconds> <seed>

Starts the native discovery runtime (RelWithDebInfo: TCP debug server on),
drives pad 1 with seeded pseudo-random play (Start/X often so menus advance,
held directions, the other buttons now and then), and at the end:
  - writes interpreted entry PCs inside the boot EXE to <work>/misses.txt
    (they become recompiler seeds), and
  - quits cleanly so the runtime flushes <work>/overlay_captures.json
    (code loaded from disc, compiled later with compile_overlays --static).
Prints one JSON summary line.
"""
import json
import os
import random
import socket
import subprocess
import sys
import time

EXE, TOML, CUE, WORK, PORT, SECS, SEED = sys.argv[1:8]
PORT, SECS = int(PORT), float(SECS)
rng = random.Random(int(SEED))

# PS1 pad bits (active low in set_input): select, l3, r3, start, up, right, down, left,
# l2, r2, l1, r1, triangle, circle, cross, square.
BIT = {'select': 0, 'start': 3, 'up': 4, 'right': 5, 'down': 6, 'left': 7, 'l2': 8, 'r2': 9,
       'l1': 10, 'r1': 11, 'triangle': 12, 'circle': 13, 'cross': 14, 'square': 15}


def mask(*names):
    m = 0xFFFF
    for n in names:
        m &= ~(1 << BIT[n])
    return m


class Conn:
    """One request per connection: the server may close idle sockets."""
    def __init__(self):
        for _ in range(120):
            try:
                self.cmd(cmd='ping')
                return
            except (OSError, ValueError):
                time.sleep(1)
        raise SystemExit('debug server did not come up')

    def cmd(self, **kw):
        with socket.create_connection(('127.0.0.1', PORT), timeout=60) as s:
            s.sendall((json.dumps(kw) + '\n').encode())
            buf = b''
            while not buf.endswith(b'\n'):
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf or b'{}')


os.makedirs(WORK, exist_ok=True)
env = dict(os.environ, PSX_INTERNAL_RESOLUTION='native', PSX_SUPERSAMPLE='1', SDL_AUDIODRIVER='dummy',
           PSX_OVERLAY_CAPTURES=os.path.join(WORK, 'overlay_captures.json'))
proc = subprocess.Popen([EXE, '--game', TOML, '--disc', CUE, '--renderer', 'software', '--no-launcher', '--headless',
                         '--debug-port', str(PORT)], cwd=WORK, env=env,
                        stdout=open(os.path.join(WORK, 'runtime.log'), 'w'), stderr=subprocess.STDOUT)
c = Conn()
c.cmd(cmd='set_input', buttons=0xFFFF, pad_type=1)
end = time.time() + SECS
dirs = ['up', 'down', 'left', 'right']
while time.time() < end and proc.poll() is None:
    r = rng.random()
    if r < 0.25:
        b = mask('start')
    elif r < 0.55:
        b = mask('cross')
    elif r < 0.85:
        b = mask(rng.choice(dirs), *rng.sample(['cross', 'square', 'circle'], k=rng.randint(0, 1)))
    else:
        b = mask(rng.choice(['triangle', 'circle', 'square', 'l1', 'r1', 'l2', 'r2']))
    c.cmd(cmd='set_input', buttons=b)
    time.sleep(rng.uniform(0.15, 1.2))
    c.cmd(cmd='set_input', buttons=0xFFFF)
    time.sleep(rng.uniform(0.05, 0.4))

summary = {'seed': int(SEED), 'alive': proc.poll() is None}
if proc.poll() is None:
    stats = c.cmd(cmd='dirty_ram_stats', per_pc=1)
    rows = stats.get('per_pc') or stats.get('pcs') or []
    summary['frame'] = c.cmd(cmd='frame').get('frame')
    summary['interp_pcs'] = len(rows)
    summary['interp_insns'] = sum(int(r.get('insns', 0)) for r in rows)
    with open(os.path.join(WORK, 'dirty_ram_stats.json'), 'w') as f:
        json.dump(stats, f)
    try:
        c.cmd(cmd='quit')
    except OSError:
        pass
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
summary['exit'] = proc.returncode
summary['captures'] = os.path.exists(os.path.join(WORK, 'overlay_captures.json'))
print(json.dumps(summary))

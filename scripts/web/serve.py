#!/usr/bin/env python3
"""Serve a web build with the headers the PS1 runtime needs.

usage: serve.py <build/web-<name> dir> [port]

Cross-origin isolation (COOP/COEP) enables SharedArrayBuffer for pthreads;
HEAD and Range let the disc stream in 1 MiB chunks.
"""
import http.server
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
TYPES = {'.js': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html',
         '.json': 'application/json', '.txt': 'text/plain', '.toml': 'text/plain'}


class Handler(http.server.BaseHTTPRequestHandler):
    def resolve(self):
        rel = os.path.normpath(self.path.split('?')[0].lstrip('/')) or 'index.html'
        rel = re.sub(r'%([0-9A-Fa-f]{2})', lambda m: chr(int(m.group(1), 16)), rel)
        path = os.path.join(ROOT, rel)
        if os.path.isdir(path):
            path = os.path.join(path, 'index.html')
        if not path.startswith(ROOT) or not os.path.isfile(path):
            return None
        return path

    def head(self, path, length, status=200, extra=()):
        self.send_response(status)
        self.send_header('Content-Type', TYPES.get(os.path.splitext(path)[1], 'application/octet-stream'))
        self.send_header('Content-Length', str(length))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('Cache-Control', 'no-cache')
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()

    def serve(self, body):
        path = self.resolve()
        if not path:
            self.send_error(404)
            return
        size = os.path.getsize(path)
        m = re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if m:
            start = int(m.group(1))
            end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            self.head(path, end - start + 1, 206, [('Content-Range', f'bytes {start}-{end}/{size}')])
            if body:
                with open(path, 'rb') as f:
                    f.seek(start)
                    self.wfile.write(f.read(end - start + 1))
            return
        self.head(path, size)
        if body:
            with open(path, 'rb') as f:
                while chunk := f.read(1 << 20):
                    self.wfile.write(chunk)

    def do_GET(self):
        self.serve(True)

    def do_HEAD(self):
        self.serve(False)

    def log_message(self, fmt, *args):
        pass


http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
